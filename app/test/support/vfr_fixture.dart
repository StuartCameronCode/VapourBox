// ignore_for_file: avoid_print — diagnostics go to the test log.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'worker_harness.dart';

/// A variable-frame-rate source with known ground truth (issue #137).
///
/// A smooth pan across a still picture (the first frame of `small_clip.mp4`,
/// enlarged), 2 px right and 1 px down per frame at 29.97 fps for 300 frames:
/// [groundTruth]. Real footage won't do as ground truth here — `small_clip`
/// itself repeats frames, so its "dropped" frame can equal the one before it.
///
/// [path] is the same pan with every third frame dropped from frame 150 on and
/// the survivors' timestamps kept — the shape of a phone slowing to 20 fps when
/// the scene gets dark. Every dropped frame is in [groundTruth] at its index:
/// what a gap slot should look like.
///
/// Built with the bundled ffmpeg on first use rather than committed, so it is
/// always exactly this recipe.
class VfrFixture {
  /// Stored frames: 150, then two of every three of the next 149.
  static const storedFrames = 250;

  /// Grid slots at 29.97: frames 0..298 (299 is itself a dropped frame).
  static const slots = 299;

  static const fps = 29.97;
  static const width = 320;
  static const height = 240;

  /// Whether slot [i] is a gap: a frame the fixture dropped.
  static bool isGap(int i) => i >= 150 && i % 3 == 2;

  static Directory get _dir => Directory(p.join(WorkerHarness.outputDir, 'vfr'));

  static String get groundTruth => p.join(_dir.path, 'vfr_ground_truth.mkv');

  static String? _path;

  static Future<void> _ffmpeg(List<String> args, String what) async {
    final r = await Process.run(WorkerHarness.ffmpegPath, ['-y', '-v', 'error', ...args],
        environment: WorkerHarness.ffmpegEnv);
    if (r.exitCode != 0) throw Exception('building the VFR fixture ($what): ${r.stderr}');
  }

  static Future<String> path() async {
    if (_path != null && File(_path!).existsSync()) return _path!;
    await _dir.create(recursive: true);
    final still = p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'small_clip.mp4');
    // Lossless, so the ground truth is exactly the pan.
    await _ffmpeg([
      '-i', still,
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=10',
      '-filter_complex',
      '[0:v]trim=end_frame=1,scale=1280:960,loop=loop=299:size=1:start=0,'
          "crop=w=$width:h=$height:x='n*2':y='n',setpts=N/(30000/1001)/TB,"
          'format=yuv420p[v]',
      '-map', '[v]', '-map', '1:a',
      '-r', '30000/1001', '-frames:v', '300',
      '-c:v', 'ffv1', '-c:a', 'pcm_s16le',
      groundTruth,
    ], 'ground truth');
    final out = p.join(_dir.path, 'vfr_source.mp4');
    await _ffmpeg([
      '-i', groundTruth,
      '-vf', "select='lt(n\\,150)+not(eq(mod(n\\,3)\\,2))'",
      '-fps_mode', 'vfr',
      '-c:v', 'libx264', '-crf', '10', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac',
      out,
    ], 'VFR source');
    final stream = await WorkerHarness.firstStream(out,
        selector: 'v:0',
        entries: ['nb_frames', 'r_frame_rate', 'avg_frame_rate']);
    final stored = int.tryParse(stream?['nb_frames']?.toString() ?? '');
    if (stored != storedFrames) {
      throw StateError('VFR fixture has $stored stored frames, not $storedFrames '
          '— the recipe changed');
    }
    print('  VFR fixture: $out (r_frame_rate ${stream?['r_frame_rate']}, '
        'avg ${stream?['avg_frame_rate']})');
    return _path = out;
  }
}
