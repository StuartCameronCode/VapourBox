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

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

print(json.dumps(out))
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
