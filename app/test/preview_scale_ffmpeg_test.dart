// Every preview `scale` filter the worker can build runs in the bundled
// ffmpeg (task #73).
//
// The preview converts an untagged Y4M pipe to RGB with
// `scale=in_color_matrix=<m>:…` (`preview_scale_filter` in
// worker/src/pipeline_executor.rs). FFmpeg 9's scale knows only some matrix
// names, and has no conversion at all for ycgco, bt2020c, smpte2085,
// chroma-derived-* and ictcp, so a source tagged with one failed its preview.
// `ColorMetadata::swscale_matrix` maps those; this runs every row of
// Tests/TestResources/preview_scale_cases.json (which both the Rust and
// WorkerHarness.previewScaleFilter reproduce) through this platform's
// bundled ffmpeg, on an untagged Y4M frame like the preview's, and wants a
// picture. The Rust test's pinned name list is from one build; this checks
// the build each platform ships.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/worker_harness.dart';

void main() {
  setUpAll(WorkerHarness.ensureReady);

  test('every case of preview_scale_cases.json converts in the bundled ffmpeg',
      () async {
    final table = jsonDecode(File(p.join(WorkerHarness.repoRoot,
                'Tests/TestResources/preview_scale_cases.json'))
            .readAsStringSync()) as Map<String, dynamic>;
    final filters = {
      for (final c in (table['cases'] as List).cast<Map<String, dynamic>>())
        c['filter'] as String,
    };
    final dir = await Directory.systemTemp.createTemp('vb_scale_cases');
    try {
      // One untagged Y4M frame: the preview's pipe carries no colour tags.
      final y4m = p.join(dir.path, 'in.y4m');
      final made = await Process.run(
          WorkerHarness.ffmpegPath,
          [
            '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=s=32x16',
            '-frames:v', '1', '-pix_fmt', 'yuv420p', y4m,
          ],
          environment: WorkerHarness.ffmpegEnv);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      final failures = <String>[];
      for (final f in filters) {
        final out = p.join(dir.path, 'out.png');
        final r = await Process.run(
            WorkerHarness.ffmpegPath,
            [
              '-v', 'error', '-y', '-f', 'yuv4mpegpipe', '-i', y4m,
              '-frames:v', '1', '-vf', f, '-f', 'image2pipe', '-vcodec', 'png',
              out,
            ],
            environment: WorkerHarness.ffmpegEnv);
        if (r.exitCode != 0 || !File(out).existsSync()) {
          failures.add('$f: ${(r.stderr as String).trim()}');
        }
        if (File(out).existsSync()) File(out).deleteSync();
      }
      expect(failures, isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
