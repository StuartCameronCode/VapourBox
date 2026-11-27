// pipe_source's reader serves the frame it was asked for, whatever order
// VapourSynth asks in (task #58).
//
// vspipe requests a new frame each time any frame completes, so one early
// frame whose callback runs late lets the rest of the clip be read past it.
// Measured under load: frames 6 and 7 served after frame 99 was read, and the
// old reader, which kept only the 40 frames behind the last one read, served
// them as whatever frame it had read last (2-4 wrong outputs in 160 plain
// runs; docs/reports/task-58-output-conformance-findings). This drives
// `_PipeReader` directly, with a fake pipe of numbered frames, in that order,
// so it fails deterministically on the old reader. It needs the bundle's
// Python (vapoursynth imports), as plugin_format_contracts_test does.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/vspipe_process.dart';
import 'support/worker_harness.dart';

const _script = r'''
import io, json, sys
sys.path.insert(0, sys.argv[1])
import vapoursynth as vs
import pipe_source

W, H, N = 16, 16, 100
FRAME = W * H * 3 // 2


def reader(window=40):
    r = pipe_source._PipeReader(W, H, vs.YUV420P8, cache_frames=window)
    r._pipe = io.BytesIO(b''.join(bytes([n]) * FRAME for n in range(N)))
    return r


def tag(r, n):
    try:
        return r._frame_data(n)[0]
    except vs.Error as e:
        return 'raised' if 'left the cache' in str(e) else str(e)


out = {}

# Run-ahead: 0..2, then 8..99 (to the end of the pipe), then 3..7.
r = reader()
order = [0, 1, 2] + list(range(8, N)) + list(range(3, 8))
out['runahead'] = [[n, tag(r, n)] for n in order]

# The ModifyFrame callback itself, for a late frame.
r = reader()
for n in [0, 1, 2] + list(range(8, N)):
    tag(r, n)
blank = vs.core.std.BlankClip(width=W, height=H, format=vs.YUV420P8, length=1).get_frame(0)
f = r.fill_frame(5, blank)
out['callback'] = [f[p][0, 0] for p in range(3)]

# A frame left behind the temporal window after everything was served.
r = reader()
for n in range(N):
    tag(r, n)
out['behindWindow'] = tag(r, 10)
out['insideWindow'] = tag(r, 70)

# Past the end of the stream: the last real frame (for VDecimate).
out['pastEnd'] = tag(r, N + 5)

# Frames never asked for, past the memory cap: given up, and raising if
# they are asked for after all.
r = reader()
r._cap = 50
for n in (0, 1, 2, 99):
    tag(r, n)
out['abandoned'] = tag(r, 3)
out['keptNearEnd'] = tag(r, 60)

# Task #120: output frame 0 in flight, outputs 1..61 requested and done,
# serving 0..70; then 0 asked for again by output 0's own late request.
def tracked(window=42):
    r = reader(window)
    r.output_requested(0)
    for m in range(1, 62):
        r.output_requested(m)
        for n in range(max(0, m - 8), min(N, m + 10)):
            tag(r, n)
        r.output_done(m)
    return r

r = tracked()
out['lateOutput'] = [tag(r, n) for n in range(0, 9)]
out['lateOutputKept'] = len(r._cache)
r.output_done(0)
for m in range(62, N):
    r.output_requested(m)
    tag(r, min(N - 1, m + 9))
    r.output_done(m)
out['afterDone'] = tag(r, 0)
out['afterDoneKept'] = len(r._cache)

# The same order without tracking: today's rule, which raised on Windows.
r = reader(42)
for n in range(0, 71):
    tag(r, n)
out['untracked'] = tag(r, 0)

# Past the memory cap a frame held for an output in flight still goes, and
# asking for it raises rather than serving another picture.
r = reader(42)
r._cap = 60
r.output_requested(0)
for n in range(0, N):
    tag(r, n)
out['pastCap'] = tag(r, 0)

print(json.dumps(out))
''';

// Output frame 0 reads source frame 0 at once and again only once heavy[0],
// a second or so of C filtering, is ready: by then vspipe has run every other
// output frame and the reader has read the whole clip. The pipe node's cache
// holds one frame, so the second request reaches the reader, as it does when
// VapourSynth's cache has dropped a served frame (task #120). The old reader
// raised "frame 0 was asked for after it left the cache" every time.
const _lateOutputScript = r'''
import os, sys
import vapoursynth as vs
core = vs.core
sys.path.insert(0, os.environ['VB_PIPE_SOURCE_DIR'])
import pipe_source

_orig = pipe_source._PipeReader._frame_data
def _frame_data(self, n):
    if n < self._next - self._window:
        sys.stderr.write(f"LATE_REQUEST {n} read_to={self._next - 1}\n")
    return _orig(self, n)
pipe_source._PipeReader._frame_data = _frame_data

W, H, N = 64, 48, 120
src = pipe_source.create_pipe_clip(W, H, N, 25, 1, 'yuv420p', cache_frames=40)
core.std.SetVideoCache(src, mode=1, fixedsize=1, maxsize=1)
slow = core.std.BlankClip(width=2048, height=2048, format=vs.GRAYS, length=1)
for _ in range(40):
    slow = core.std.BoxBlur(slow, hradius=40, vradius=40)
heavy = slow + core.std.BlankClip(width=2048, height=2048, format=vs.GRAYS, length=N - 1)
late = core.std.FrameEval(src, lambda n, f: src, prop_src=heavy)
out = pipe_source.track_output(core.std.Merge(src, late))
out.set_output()
''';

// A frame stored off its chroma grid (task #97): FFmpeg's rawvideo carries
// chroma rounded up (63x33 4:2:0 -> 32x17), and the reader pads luma onto
// the grid by repeating its last column and row (each field's own last row
// with pad_fields). Every stored sample must come through as it is.
const _gridScript = r'''
import io, json, random, sys
sys.path.insert(0, sys.argv[1])
import vapoursynth as vs
import pipe_source

core = vs.core
out = {}
cases = [
    ('420h', 64, 33, vs.YUV420P8, 0, 1, False),
    ('420w', 63, 32, vs.YUV420P8, 1, 0, False),
    ('420wh10', 63, 33, vs.YUV420P10, 1, 1, False),
    ('422w', 63, 32, vs.YUV422P8, 1, 0, False),
    ('411w', 62, 32, vs.YUV411P8, 2, 0, False),
    ('420fields', 64, 33, vs.YUV420P8, 0, 1, True),
    ('ongrid', 64, 32, vs.YUV420P8, 0, 0, False),
]
for name, w, h, fmt_id, pr, pb, fields in cases:
    fmt = core.get_video_format(fmt_id)
    sw, sh = 1 << fmt.subsampling_w, 1 << fmt.subsampling_h
    cw, ch = -(-w // sw), -(-h // sh)
    peak = (1 << fmt.bits_per_sample) - 1
    rnd = random.Random(name)
    planes = [[[rnd.randint(0, peak) for _ in range(pw)] for _ in range(ph)]
              for pw, ph in [(w, h), (cw, ch), (cw, ch)]]
    data = b''.join(
        b''.join(v.to_bytes(fmt.bytes_per_sample, 'little') for row in pl for v in row)
        for pl in planes)
    r = pipe_source._PipeReader(w, h, fmt_id, 40, pr, pb, fields)
    r._pipe = io.BytesIO(data)
    blank = core.std.BlankClip(width=w + pr, height=h + pb, format=fmt_id, length=1).get_frame(0)
    f = r.fill_frame(0, blank)
    bad = []
    for p in range(3):
        a = f[p]
        pw, ph = (w + pr, h + pb) if p == 0 else (cw, ch)
        if (a.shape[1], a.shape[0]) != (pw, ph):
            bad.append('plane %d is %dx%d, not %dx%d' % (p, a.shape[1], a.shape[0], pw, ph))
            continue
        for y in range(ph):
            for x in range(pw):
                if p == 0:
                    sy = y if y < h else ((y - 2) if fields else h - 1)
                    while sy >= h:
                        sy -= 2
                    want = planes[0][sy][min(x, w - 1)]
                else:
                    want = planes[p][y][x]
                if a[y, x] != want:
                    bad.append('plane %d (%d,%d) %d != %d' % (p, x, y, a[y, x], want))
    out[name] = bad[:3]
print(json.dumps(out))
''';

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  test('pipe_source serves each frame it was asked for, in any order (task #58)', () async {
    final script = File(p.join(Directory.systemTemp.path, 'vb_pipe_order_$pid.py'));
    await script.writeAsString(_script);
    addTearDown(() {
      if (script.existsSync()) script.deleteSync();
    });
    final r = await Process.run(
      WorkerHarness.pythonPath,
      [script.path, p.join(WorkerHarness.repoRoot, 'worker', 'templates')],
      environment: WorkerHarness.workerEnv,
    );
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final out = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;

    for (final pair in (out['runahead'] as List).cast<List>()) {
      expect(pair[1], pair[0], reason: 'frame ${pair[0]} after a run-ahead to the end of the pipe');
    }
    expect(out['callback'], [5, 5, 5], reason: 'fill_frame writes frame 5 into every plane');
    expect(out['behindWindow'], 'raised',
        reason: 'a frame dropped behind the window raises; it never comes back as another picture');
    expect(out['insideWindow'], 70);
    expect(out['pastEnd'], 99, reason: 'past the end of the stream: the last real frame');
    expect(out['abandoned'], 'raised', reason: 'a frame given up at the memory cap raises');
    expect(out['keptNearEnd'], 60);
  });

  test('pipe_source keeps what an output frame still in flight can ask for again (task #120)',
      () async {
    final script = File(p.join(Directory.systemTemp.path, 'vb_pipe_late_$pid.py'));
    await script.writeAsString(_script);
    addTearDown(() {
      if (script.existsSync()) script.deleteSync();
    });
    final r = await Process.run(
      WorkerHarness.pythonPath,
      [script.path, p.join(WorkerHarness.repoRoot, 'worker', 'templates')],
      environment: WorkerHarness.workerEnv,
    );
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final out = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;

    // The nightly's order: read to 70, output 0 still in flight, frame 0 again.
    expect(out['untracked'], 'raised',
        reason: 'without tracking the window counts from the oldest frame not yet served');
    expect(out['lateOutput'], List.generate(9, (n) => n),
        reason: 'output 0 is in flight, so every frame it can reach is still there');
    expect(out['lateOutputKept'], lessThanOrEqualTo(80));
    expect(out['afterDone'], 'raised',
        reason: 'once output 0 is done its frames go, as before');
    expect(out['afterDoneKept'], lessThanOrEqualTo(42 + 20),
        reason: 'memory is bounded again once the late output completes');
    expect(out['pastCap'], 'raised',
        reason: 'the memory cap still drops a held frame, and asking for it raises');
  });

  test('a late output frame re-reads a served frame through vspipe (task #120)', () async {
    final deps = WorkerHarness.depsDir;
    final vspipe = p.join(
        deps,
        'vapoursynth',
        Platform.isWindows
            ? p.join('Lib', 'site-packages', 'vapoursynth', 'vspipe.exe')
            : 'vspipe');
    final script = File(p.join(Directory.systemTemp.path, 'vb_pipe_late_$pid.vpy'));
    await script.writeAsString(_lateOutputScript);
    addTearDown(() {
      if (script.existsSync()) script.deleteSync();
    });
    const w = 64, h = 48, n = 120, frame = w * h * 3 ~/ 2;
    final raw = Uint8List(frame * n);
    for (var i = 0; i < n; i++) {
      raw.fillRange(i * frame, (i + 1) * frame, i);
    }
    // runVspipe drains both pipes before writing (vspipe may stop reading
    // early on a failure, and an unread pipe deadlocks; CLAUDE.md, "Feeding
    // a test clip") and applies the worker's exit rule (task #124).
    final run = await runVspipe(vspipe, [script.path, '-c', 'y4m', '-'],
        label: 'vspipe, late output frame',
        environment: {
          ...WorkerHarness.workerEnv,
          'VB_PIPE_SOURCE_DIR': p.join(WorkerHarness.repoRoot, 'worker', 'templates'),
        },
        stdin: raw,
        binaryStdout: true,
        timeout: const Duration(minutes: 2));
    final code = run.result.exitCode;
    final y4m = run.result.stdout as Uint8List;
    final err = run.result.stderr as String;
    expect(code, 0, reason: err);
    expect(err, contains('LATE_REQUEST 0 '),
        reason: 'the late request has to arrive after the reader ran past the window, '
            'or this test proves nothing:\n$err');

    // Every output frame is its own source frame (Merge of a frame with itself).
    final marker = ascii.encode('FRAME\n');
    var at = y4m.indexOf(10) + 1; // after the stream header
    for (var i = 0; i < n; i++) {
      expect(y4m.sublist(at, at + marker.length), marker, reason: 'frame $i header');
      at += marker.length;
      final luma = y4m.sublist(at, at + w * h);
      expect(luma.every((v) => v == i), isTrue, reason: 'output frame $i is source frame $i');
      at += frame;
    }
    expect(at, y4m.length);
  });

  test('pipe_source reads a frame off its chroma grid and pads it (task #97)', () async {
    final script = File(p.join(Directory.systemTemp.path, 'vb_pipe_grid_$pid.py'));
    await script.writeAsString(_gridScript);
    addTearDown(() {
      if (script.existsSync()) script.deleteSync();
    });
    final r = await Process.run(
      WorkerHarness.pythonPath,
      [script.path, p.join(WorkerHarness.repoRoot, 'worker', 'templates')],
      environment: WorkerHarness.workerEnv,
    );
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final out = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
    expect(out.keys, containsAll(['420h', '420w', '420wh10', '422w', '411w', '420fields', 'ongrid']));
    out.forEach((name, bad) => expect(bad, isEmpty, reason: name));
  });
}
