// Basic smoke tests for VapourBox models
//
// For full widget tests, the app requires window_manager which needs
// a desktop environment. These tests focus on the model layer.

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/restoration_pipeline.dart';
import 'package:vapourbox/models/video_job.dart';

void main() {
  group('VapourBox Models Smoke Test', () {
    test('VideoJob creates with required fields', () {
      final job = VideoJob(
        id: 'test-id',
        inputPath: '/path/to/input.avi',
        outputPath: '/path/to/output.mp4',
        qtgmcParameters: const QTGMCParameters(),
        restorationPipeline: const RestorationPipeline(),
        encodingSettings: const EncodingSettings(),
      );

      expect(job.id, 'test-id');
      expect(job.inputPath, '/path/to/input.avi');
      expect(job.outputPath, '/path/to/output.mp4');
    });

    test('QTGMCParameters has sensible defaults', () {
      const params = QTGMCParameters();

      expect(params.enabled, true);
      expect(params.preset, QTGMCPreset.slower);
      expect(params.fpsDivisor, 1);
    });

    test('QTGMCPreset has display names', () {
      expect(QTGMCPreset.placebo.displayName, 'Placebo');
      expect(QTGMCPreset.verySlow.displayName, 'Very Slow');
      expect(QTGMCPreset.slower.displayName, 'Slower');
      expect(QTGMCPreset.medium.displayName, 'Medium');
      expect(QTGMCPreset.fast.displayName, 'Fast');
      expect(QTGMCPreset.draft.displayName, 'Draft');
    });

    test('RestorationPipeline tracks enabled passes', () {
      const pipeline = RestorationPipeline(
        deinterlace: QTGMCParameters(enabled: true),
      );

      expect(pipeline.isPassEnabled(PassType.deinterlace), true);
      expect(pipeline.isPassEnabled(PassType.dehalo), false);
      expect(pipeline.isPassEnabled(PassType.deband), false);
    });

    test('RestorationPipeline counts enabled passes', () {
      const pipeline = RestorationPipeline(
        deinterlace: QTGMCParameters(enabled: true),
      );

      // Only deinterlace is enabled by default
      expect(pipeline.enabledPassCount, 1);
    });

    test('EncodingSettings has codec options', () {
      const settings = EncodingSettings(
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        quality: 18,
      );

      expect(settings.codec, VideoCodec.h264);
      expect(settings.container, ContainerFormat.mp4);
      expect(settings.quality, 18);
    });

    test('VideoJob serializes to JSON', () {
      final job = VideoJob(
        id: 'test-id',
        inputPath: '/input.avi',
        outputPath: '/output.mp4',
        qtgmcParameters: const QTGMCParameters(),
        restorationPipeline: const RestorationPipeline(),
        encodingSettings: const EncodingSettings(),
      );

      final json = job.toJson();

      expect(json['id'], 'test-id');
      expect(json['inputPath'], '/input.avi');
      expect(json['outputPath'], '/output.mp4');
      expect(json['qtgmcParameters'], isA<Map>());
      expect(json['encodingSettings'], isA<Map>());
    });

    test('PassType has display names and descriptions', () {
      expect(PassType.deinterlace.displayName, 'Deinterlace');
      expect(PassType.noiseReduction.displayName, 'Noise Reduction');
      expect(PassType.dehalo.displayName, 'Dehalo');

      expect(PassType.deinterlace.description, contains('QTGMC'));
      expect(PassType.noiseReduction.description, contains('noise'));
    });
  });
}
