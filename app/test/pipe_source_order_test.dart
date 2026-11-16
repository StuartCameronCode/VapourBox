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
}
