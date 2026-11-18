// Task #42: the encode and the preview come from one template, and two
// settings that used to fail or be ignored now run end to end.
//
//   * QTGMC's Block Size: the template passed `Blocksize=`, which havsfunc's
//     QTGMC does not take (it is `BlockSize`), so every encode with the
//     setting failed.
//   * MCTemporalDenoise's profile: the preview template had lost `settings=`,
//     so the preview showed havsfunc's default profile whatever was chosen.
//
// Both are set to non-default values; the encode must succeed and the
// preview must show the encode's frame. A preview at another profile must
// not, or the comparison could not tell the profiles apart.
@Tags(['heavy'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

// Real film with grain and motion (the colourisation fixture): 640x480,
// 24 fps, 120 frames. A still picture gives every temporal denoiser
// profile the same output, which proves nothing.
String get _fixture => p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'colorize_test.mp4');
String get _dir => p.join(WorkerHarness.outputDir, 'template_parity');
const _start = 40, _end = 59;

Map<String, dynamic> _job(String name, {required String profile, bool trimmed = true}) => VideoJob(
      id: const Uuid().v4(),
      inputPath: _fixture,
      outputPath: p.join(_dir, '$name.mkv'),
      processingPipeline: ProcessingPipeline(
        deinterlace: const QTGMCParameters(
          enabled: true,
          preset: QTGMCPreset.fast,
          tff: true,
          // Single rate, so encode frame k is source frame start + k.
          fpsDivisor: 2,
          blockSize: 32,
        ),
        noiseReduction: NoiseReductionParameters(
          enabled: true,
          method: NoiseReductionMethod.mcTemporalDenoise,
          mcTemporalProfile: profile,
        ),
      ),
      encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
      inputWidth: 640,
      inputHeight: 480,
      inputPixelFormat: 'yuv420p',
      inputFrameRate: 24,
      totalFrames: trimmed ? _end - _start + 1 : 120,
      startFrame: trimmed ? _start : null,
      endFrame: trimmed ? _end : null,
    ).toJson();

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
  });

  test('QTGMC Block Size and the MCTD profile encode, and the preview shows the encode', () async {
    final r = await WorkerHarness.runJob(_job('high', profile: 'high'), label: 'parity encode',
        timeout: const Duration(minutes: 20));
    expect(r.success, isTrue, reason: '${r.error}\n${r.logs.reversed.take(30).toList().reversed.join('\n')}');
    final out = r.outputPath ?? p.join(_dir, 'high.mkv');

    // Far enough from the trim's ends that the encode's temporal neighbours
    // are the preview's.
    for (final frame in [_start + 8, _start + 12]) {
      // Converted to RGB as the preview converts its picture (task #67).
      final encoded =
          await WorkerHarness.previewFrameRgb24(out, frame - _start, label: 'parity_enc');
      Future<double> previewDiff(String profile) async {
        final pv = await WorkerHarness.runPreview(_job('pv_$profile', profile: profile, trimmed: false),
            frame: frame);
        expect(pv.success, isTrue, reason: '${pv.error}\n${pv.logs}');
        final rgb = await WorkerHarness.imageToRgb24(pv.png!, label: 'parity_pv_$profile');
        return WorkerHarness.meanAbsDiff(rgb, encoded);
      }

      final same = await previewDiff('high');
      final other = await previewDiff('low');
      // ignore: avoid_print
      print('  frame $frame: preview vs encode $same (high), $other (low)');
      expect(same, lessThan(0.5), reason: 'the preview shows a different picture from the encode');
      expect(other, greaterThan(same * 4),
          reason: 'a preview at another profile should differ, or the comparison proves nothing');
    }
  });
}
