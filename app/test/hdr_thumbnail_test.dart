// HDR timeline thumbnails are scaled to an even height (task #86).
//
// The thumbnail is `scale=160:…` then, for an HDR source, the display tone
// map, whose first stage is zscale. `scale` keeps the source's pixel format,
// and zimg refuses a 4:2:0 frame with an odd dimension ("code 1027: image
// dimensions must be divisible by subsampling factor"), so with `-1` a 2.40:1
// source (160x67) or 720x480 (160x107) had no thumbnails at all. An SDR
// thumbnail goes straight to JPEG, which takes any height, and keeps `-1`.
//
// The first group pins the arguments; the second runs them through this
// platform's bundled ffmpeg on tiny 4:2:0 PQ and HLG sources whose 160-wide
// height is odd, and checks the old `-1` still fails there, so the fixture
// keeps proving the bug.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/models/hdr_display.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

import 'support/worker_harness.dart';

List<String> _vf(List<String> args) => args[args.indexOf('-vf') + 1].split(',');

void main() {
  final pq = HdrDisplay.toneMapFilter(
      matrix: 'bt2020nc', primaries: 'bt2020', transfer: 'smpte2084', range: 'tv')!;
  final hlg = HdrDisplay.toneMapFilter(
      matrix: 'bt2020nc', primaries: 'bt2020', transfer: 'arib-std-b67', range: 'tv')!;

  group('thumbnail arguments', () {
    test('SDR keeps scale=160:-1', () {
      expect(PreviewGenerator.thumbnailScale(toneMapped: false), 'scale=160:-1');
      final args = PreviewGenerator.thumbnailArgs(
          videoPath: 'in.mkv', time: 1, outputPath: 't.jpg');
      expect(_vf(args), ['scale=160:-1']);
    });

    test('HDR scales to an even height, directly before the tone map', () {
      expect(PreviewGenerator.thumbnailScale(toneMapped: true), 'scale=160:-2');
      for (final toneMap in [pq, hlg]) {
        final args = PreviewGenerator.thumbnailArgs(
            videoPath: 'in.mkv', time: 1, toneMap: toneMap, outputPath: 't.jpg');
        expect(args[args.indexOf('-vf') + 1], 'scale=160:-2,$toneMap');
      }
    });

    test('a trim stays ahead of the scale', () {
      // MPEG-TS/PS seek plan: trim to the moment, then scale, then tone map.
      const plan = SeekPlan(preroll: 1.82, containerStart: 1.4);
      final ts = PreviewGenerator.thumbnailArgs(
          videoPath: 'in.ts', time: 5, toneMap: pq, seekPlan: plan,
          outputPath: 't.jpg');
      final vf = ts[ts.indexOf('-vf') + 1];
      expect(vf, endsWith(',scale=160:-2,$pq'));
      expect(vf.indexOf('trim='), lessThan(vf.indexOf('scale=160:-2')));

      // A delayed AVI near its start: drop pictures by count, then scale.
      final avi = PreviewGenerator.thumbnailArgs(
          videoPath: 'in.avi', time: 0.2, toneMap: pq, frameRate: 25,
          decoderDelayFrames: 1, outputPath: 't.jpg');
      expect(avi[avi.indexOf('-vf') + 1], 'trim=start_frame=5,scale=160:-2,$pq');
    });
  });

  group('bundled ffmpeg', () {
    Directory? tempDir;


    setUpAll(() async {
      await WorkerHarness.ensureReady();
      tempDir = await Directory.systemTemp.createTemp('vb_hdr_thumb');
    });
    tearDownAll(() async {
      final d = tempDir;
      if (d != null && await d.exists()) await d.delete(recursive: true);
    });

    /// A 4:2:0 10-bit FFV1 source, [w]x[h], tagged HDR with [transfer].
    /// Made by scaling a larger picture: `testsrc2=s=WxH` rounds the size.
    Future<String> source(int w, int h, String transfer) async {
      final path = p.join(tempDir!.path, '${w}x${h}_$transfer.mkv');
      final r = await Process.run(
          WorkerHarness.ffmpegPath,
          [
            '-v', 'error', '-y', '-f', 'lavfi',
            '-i', 'testsrc2=s=320x240:d=0.2:r=10',
            '-vf', 'scale=$w:$h,format=yuv420p10le',
            '-c:v', 'ffv1',
            '-color_primaries', 'bt2020', '-color_trc', transfer,
            '-colorspace', 'bt2020nc', '-color_range', 'tv',
            path,
          ],
          environment: WorkerHarness.ffmpegEnv);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return path;
    }

    /// Runs [args]; the written JPEG's size, or null with ffmpeg's stderr.
    Future<({String? size, String stderr})> run(List<String> args) async {
      final out = args.last;
      if (File(out).existsSync()) File(out).deleteSync();
      final r = await Process.run(WorkerHarness.ffmpegPath, ['-v', 'error', ...args],
          environment: WorkerHarness.ffmpegEnv);
      if (r.exitCode != 0 || !File(out).existsSync()) {
        return (size: null, stderr: (r.stderr as String).trim());
      }
      final probe = await Process.run(
          WorkerHarness.ffprobePath,
          ['-v', 'error', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', out],
          environment: WorkerHarness.ffmpegEnv);
      return (size: (probe.stdout as String).trim(), stderr: '');
    }

    // 96x40 is 2.40:1 (1920x800, 3840x1600: 160x66.7) and 72x48 is 3:2
    // (720x480: 160x106.7). Both are mod 4, so the source itself is legal.
    for (final (w, h, transfer, even, odd) in [
      (96, 40, 'smpte2084', '160,66', '160,67'),
      (72, 48, 'smpte2084', '160,106', '160,107'),
      (96, 40, 'arib-std-b67', '160,66', '160,67'),
    ]) {
      test('${w}x$h 4:2:0 $transfer gets a thumbnail', () async {
        final src = await source(w, h, transfer);
        final toneMap = HdrDisplay.toneMapFilter(
            matrix: 'bt2020nc', primaries: 'bt2020', transfer: transfer, range: 'tv')!;
        final out = p.join(tempDir!.path, 'thumb.jpg');
        final args = PreviewGenerator.thumbnailArgs(
            videoPath: src, time: 0, toneMap: toneMap, outputPath: out);

        final fixed = await run(args);
        expect(fixed.size, even, reason: fixed.stderr);

        // The fixture still reproduces the bug: the old scale fails in zscale.
        final vf = args.indexOf('-vf') + 1;
        final old = [...args]
          ..[vf] = args[vf].replaceFirst('scale=160:-2', 'scale=160:-1');
        final broken = await run(old);
        expect(broken.size, isNull,
            reason: 'scale=160:-1 now tone-maps a $odd 4:2:0 frame: the '
                'fixture no longer reproduces task #86; drop this guard');
        expect(broken.stderr, contains('1027'));

        // SDR (no tone map) keeps the nearest height.
        final sdr = await run(PreviewGenerator.thumbnailArgs(
            videoPath: src, time: 0, outputPath: out));
        expect(sdr.size, odd, reason: sdr.stderr);
      });
    }
  });
}
