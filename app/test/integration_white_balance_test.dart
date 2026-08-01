/// Full-encode tests for the temperature/tint white balance (issue #50).
///
/// A "valid output" assertion would pass with the signs inverted, so these
/// measure the mean chroma of the encoded frames with ffmpeg's signalstats and
/// check it moved the way the control claims: warming lowers U (less blue) and
/// raises V (more red), a magenta tint raises both, and luma is untouched.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/color_correction_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/white_balance';

late int _srcWidth;
late int _srcHeight;

/// Encode a few frames with [color] applied and return the mean Y/U/V.
Future<({double y, double u, double v})> _encodeAndMeasure(
  String name,
  ColorCorrectionParameters color,
) async {
  final job = VideoJob(
    id: const Uuid().v4(),
    inputPath: WorkerHarness.inputFile,
    outputPath: '$_outDir/$name.mkv',
    processingPipeline: ProcessingPipeline(
      deinterlace: const QTGMCParameters(enabled: false),
      colorCorrection: color,
    ),
    encodingSettings: const EncodingSettings(
      // Lossless, so the measurement reflects the filter and not the encoder.
      codec: VideoCodec.ffv1,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none,
    ),
    inputWidth: _srcWidth,
    inputHeight: _srcHeight,
    inputFrameRate: 25.0,
    startFrame: 0,
    endFrame: 4,
  );

  final result = await WorkerHarness.runJob(job.toJson(), label: name);
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '${result.error}\n--- worker log (tail) ---\n${tail.join('\n')}');

  final avg = await WorkerHarness.frameAverages(result.outputPath!);
  print('  $name: Y=${avg.y.toStringAsFixed(2)} '
      'U=${avg.u.toStringAsFixed(2)} V=${avg.v.toStringAsFixed(2)}');
  return avg;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    final src = await WorkerHarness.firstStream(WorkerHarness.inputFile,
        selector: 'v:0', entries: ['width', 'height']);
    _srcWidth = int.parse(src!['width'].toString());
    _srcHeight = int.parse(src['height'].toString());
  });

  group('white balance (full encode)', () {
    test('temperature moves U and V in opposite directions', () async {
      // Colour correction enabled but neutral is the baseline: it proves the
      // pass itself is not shifting anything on its own.
      final neutral = await _encodeAndMeasure(
          'wb_neutral', const ColorCorrectionParameters(enabled: true));
      final warm = await _encodeAndMeasure('wb_warm',
          const ColorCorrectionParameters(enabled: true, temperature: 60));
      final cool = await _encodeAndMeasure('wb_cool',
          const ColorCorrectionParameters(enabled: true, temperature: -60));

      // 60 * 0.25 = 15 levels of shift, in opposite directions per plane.
      expect(warm.u, lessThan(neutral.u - 10), reason: 'warm should cut blue');
      expect(warm.v, greaterThan(neutral.v + 10), reason: 'warm should add red');
      expect(cool.u, greaterThan(neutral.u + 10), reason: 'cool should add blue');
      expect(cool.v, lessThan(neutral.v - 10), reason: 'cool should cut red');

      // Luma is written by an empty expression, i.e. copied verbatim.
      expect(warm.y, closeTo(neutral.y, 0.01));
      expect(cool.y, closeTo(neutral.y, 0.01));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('tint moves U and V the same way', () async {
      final neutral = await _encodeAndMeasure(
          'wb_neutral2', const ColorCorrectionParameters(enabled: true));
      final magenta = await _encodeAndMeasure(
          'wb_magenta', const ColorCorrectionParameters(enabled: true, tint: 60));
      final green = await _encodeAndMeasure(
          'wb_green', const ColorCorrectionParameters(enabled: true, tint: -60));

      expect(magenta.u, greaterThan(neutral.u + 10));
      expect(magenta.v, greaterThan(neutral.v + 10));
      expect(green.u, lessThan(neutral.u - 10));
      expect(green.v, lessThan(neutral.v - 10));
      expect(magenta.y, closeTo(neutral.y, 0.01));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('white balance composes with the brightness/contrast tweak', () async {
      // The two run as separate steps in one pass, so a mistake in the block
      // wiring shows up as one of them silently going missing.
      final tweakOnly = await _encodeAndMeasure('wb_tweak_only',
          const ColorCorrectionParameters(enabled: true, brightness: 20));
      final both = await _encodeAndMeasure(
          'wb_tweak_and_warm',
          const ColorCorrectionParameters(
              enabled: true, brightness: 20, temperature: 60));

      expect(both.y, closeTo(tweakOnly.y, 0.5),
          reason: 'brightness should still be applied');
      expect(both.u, lessThan(tweakOnly.u - 10),
          reason: 'white balance should still be applied');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
