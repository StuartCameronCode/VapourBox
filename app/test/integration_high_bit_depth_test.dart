/// Full-encode regression test for IVTC on a >8-bit source.
///
/// vivtc.VFM only accepts 8-bit YUV/GRAY, so IVTC on a 10-bit source such as
/// ProRes 422 (yuv422p10le) previously failed at vspipe evaluation with
/// "VFM: input clip must be constant format YUV420P8, ...". The fix runs field
/// matching on an 8-bit metrics copy while emitting the full-depth pixels via
/// VFM's clip2 parameter. This test runs the worker end-to-end on the committed
/// 10-bit ProRes fixture and asserts a valid output — it fails on the pre-fix
/// pipeline (the encode aborts) and passes with the guard in place.
///
/// The fixture (Tests/TestResources/prores422_10bit_telecine.mov) is produced
/// by Tests/TestResources/generate_prores422_10bit_test.sh.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/high_bit_depth';
String get _proResFixture =>
    '${WorkerHarness.repoRoot}/Tests/TestResources/prores422_10bit_telecine.mov';

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  group('IVTC on high-bit-depth source (full encode)', () {
    test('IVTC runs end-to-end on 10-bit ProRes 422 (yuv422p10le)', () async {
      expect(File(_proResFixture).existsSync(), isTrue,
          reason: 'fixture missing — run generate_prores422_10bit_test.sh');

      // Probe the fixture the way the app does before building a job, so the
      // worker's pipe decoder gets the right dimensions/format. Confirm it is
      // genuinely a >8-bit source (otherwise the test would not exercise the
      // VFM 8-bit guard).
      final src = await WorkerHarness.firstStream(_proResFixture,
          selector: 'v:0',
          entries: ['pix_fmt', 'width', 'height', 'nb_read_frames'],
          countFrames: true);
      expect(src, isNotNull);
      final pixFmt = src!['pix_fmt'] as String;
      print('  fixture: $pixFmt ${src['width']}x${src['height']} '
          '${src['nb_read_frames']} frames');
      expect(pixFmt, contains('10'),
          reason: 'fixture must be >8-bit to exercise the VFM guard');

      final frames = int.parse(src['nb_read_frames'] as String);
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: _proResFixture,
        outputPath: '$_outDir/ivtc_10bit.mkv',
        processingPipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
            enabled: true,
            method: DeinterlaceMethod.ivtc,
            tff: true,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.h264,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
        ),
        detectedFieldOrder: FieldOrder.topFieldFirst,
        totalFrames: frames,
        inputFrameRate: 29.97,
        inputWidth: int.parse(src['width'].toString()),
        inputHeight: int.parse(src['height'].toString()),
        inputPixelFormat: pixFmt,
      );

      final result =
          await WorkerHarness.runJob(job.toJson(), label: 'ivtc_10bit');
      expect(result.success, isTrue, reason: result.error);
      expect(File(result.outputPath!).existsSync(), isTrue,
          reason: 'output file should exist');

      final out = await WorkerHarness.firstStream(result.outputPath!,
          selector: 'v:0', entries: ['codec_name', 'width', 'height']);
      expect(out, isNotNull, reason: 'output should contain a video stream');
      print('  output video: ${out?['codec_name']} '
          '${out?['width']}x${out?['height']}');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
