// RemoveDirt (the SpotLess pass's removeDirt method) gives the same picture
// every run (task #57).
//
// removedirt.RestoreMotionBlocks v1.1 registers itself fmParallel but shares
// one RemoveDirt object, whose block buffers every frame writes, between all
// the frames of an instance (upstream pinterf/RemoveDirt#5). Frames processed
// together overwrite each other's, so the output changed from run to run (28
// different results in 30 runs of 24 frames at 8 threads). templates/
// removedirt.py gives each frame an instance to itself. This runs the template's
// remove_dirt() on a real picture, five fresh graphs at 8 threads, and wants
// one result, equal to the single-threaded one. The bare plugin's spread is
// printed beside it as the control: when the bundle carries upstream's fix it
// drops to one, and the wrapper can go.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/worker_harness.dart';

const _check = r'''
import ctypes, hashlib, json, os, subprocess, sys, tempfile
import vapoursynth as vs
core = vs.core
sys.path.insert(0, sys.argv[1])
import removedirt

W, H, N = 352, 240, 24
raw = os.path.join(tempfile.mkdtemp(), 'src.yuv')
subprocess.run([os.environ['VAPOURBOX_FFMPEG'], '-hide_banner', '-loglevel', 'error', '-y',
                '-i', sys.argv[2], '-frames:v', str(N), '-vf', 'scale=%d:%d' % (W, H),
                '-pix_fmt', 'yuv420p', '-f', 'rawvideo', raw], check=True)


def source():
    blank = core.std.BlankClip(width=W, height=H, format=vs.YUV420P8, length=N,
                               fpsnum=30000, fpsden=1001)
    size = W * H * 3 // 2

    def fill(n, f):
        o = f.copy()
        with open(raw, 'rb') as fh:
            fh.seek(n * size)
            data = fh.read(size)
        off = 0
        for plane in range(3):
            w, h = (W, H) if plane == 0 else (W // 2, H // 2)
            base = ctypes.cast(o.get_write_ptr(plane), ctypes.c_void_p).value
            stride = o.get_stride(plane)
            for y in range(h):
                ctypes.memmove(base + y * stride, data[off:off + w], w)
                off += w
        return o
    return core.std.ModifyFrame(blank, blank, fill)


def bare(c):
    cl = core.zsmooth.Clense(c)
    sel = core.removedirt.SCSelect(c, core.zsmooth.ForwardClense(c), core.zsmooth.BackwardClense(c), cl)
    rep = core.zsmooth.Repair(sel, c, mode=[16])
    return core.removedirt.RestoreMotionBlocks(rep, c, gmthreshold=70, noise=50, noisy=12, dist=1,
                                               tolerance=12, dmode=2, pthreshold=4, cthreshold=4)


def digest(clip):
    m = hashlib.md5()
    for f in clip.frames(prefetch=16):
        for plane in range(f.format.num_planes):
            m.update(bytes(f[plane]))
    return m.hexdigest()


core.num_threads = 1
single = digest(removedirt.remove_dirt(source()))
core.num_threads = 8
wrapped = [digest(removedirt.remove_dirt(source())) for _ in range(5)]
plain = [digest(bare(source())) for _ in range(5)]
print(json.dumps({'single': single, 'wrapped': wrapped, 'bare': plain}))
''';

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  test('remove_dirt gives the single-threaded picture at 8 threads, every run', () async {
    final script = File(p.join(Directory.systemTemp.path, 'vb_removedirt_$pid.py'));
    await script.writeAsString(_check);
    try {
      final r = await Process.run(
        WorkerHarness.pythonPath,
        [
          script.path,
          p.join(WorkerHarness.repoRoot, 'worker', 'templates'),
          p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'interlaced_test.avi'),
        ],
        environment: {...WorkerHarness.workerEnv, 'VAPOURBOX_FFMPEG': WorkerHarness.ffmpegPath},
      );
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      final out = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
      final wrapped = (out['wrapped'] as List).cast<String>();
      final bare = (out['bare'] as List).cast<String>();
      // ignore: avoid_print
      print('  remove_dirt: ${wrapped.toSet().length} result(s) in ${wrapped.length} runs; '
          'the bare plugin (control): ${bare.toSet().length}');
      expect(wrapped.toSet(), {out['single']},
          reason: 'remove_dirt differs between runs, or from its single-threaded result: '
              'RestoreMotionBlocks shares its block buffers between frames (task #57)');
    } finally {
      if (script.existsSync()) script.deleteSync();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
