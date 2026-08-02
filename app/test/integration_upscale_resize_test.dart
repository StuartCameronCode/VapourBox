/// Full-encode tests for the upscale and resize pass (issue #50).
///
/// The Rust suite asserts what the generated script says; these assert that the
/// script runs and produces the geometry it claims. That matters most for the
/// EEDI3 path, which until now was a "fall back to spline36 for now" placeholder
/// and so had never actually invoked eedi3m.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/upscale_resize';

/// Source geometry, so the expected output size is derived rather than assumed.
late int _srcWidth;
late int _srcHeight;

VideoJob _job(String name, CropResizeParameters cropResize) => VideoJob(
      id: const Uuid().v4(),
      inputPath: WorkerHarness.inputFile,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: ProcessingPipeline(
        // Deinterlace off: this test is about geometry, and QTGMC would be the
        // slowest part of it by far.
        deinterlace: const QTGMCParameters(enabled: false),
        cropResize: cropResize,
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.h264,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      // The worker forces the decoder to these dimensions, falling back to
      // 720x480 when they are absent — which would silently rescale the source
      // and make an "is the output exactly 2x?" assertion meaningless.
      inputWidth: _srcWidth,
      inputHeight: _srcHeight,
      inputFrameRate: 25.0,
      startFrame: 0,
      endFrame: 4,
    );

Future<void> _expectSize(String name, CropResizeParameters cropResize,
    {required int width, required int height}) async {
  final result = await WorkerHarness.runJob(_job(name, cropResize).toJson(), label: name);
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '${result.error}\n--- worker log (tail) ---\n${tail.join('\n')}');
  final v = await WorkerHarness.firstStream(result.outputPath!,
      selector: 'v:0', entries: ['codec_name', 'width', 'height']);
  expect(v, isNotNull, reason: 'output should contain a video stream');
  print('  $name output: ${v?['codec_name']} ${v?['width']}x${v?['height']}');
  expect(int.parse(v!['width'].toString()), width);
  expect(int.parse(v['height'].toString()), height);
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    final src = await WorkerHarness.firstStream(WorkerHarness.inputFile,
        selector: 'v:0', entries: ['width', 'height']);
    _srcWidth = int.parse(src!['width'].toString());
    _srcHeight = int.parse(src['height'].toString());
    print('  source: ${_srcWidth}x$_srcHeight');
  });

  group('integer upscale (full encode)', () {
    test('NNEDI3 2x doubles both axes, with granular controls set', () async {
      await _expectSize(
        'upscale_nnedi3_2x',
        const CropResizeParameters(
          enabled: true,
          useIntegerUpscale: true,
          upscaleMethod: UpscaleMethod.nnedi3Rpow2,
          upscaleFactor: 2,
          upscaleNsize: 4,
          upscaleNeurons: 2,
          upscaleQual: 2,
          upscaleEtype: 1,
          upscalePscrn: 0,
        ),
        width: _srcWidth * 2,
        height: _srcHeight * 2,
      );
    }, timeout: const Timeout(Duration(minutes: 8)));

    // The whole point of this change: EEDI3 used to be a silent Spline36.
    test('EEDI3 2x runs eedi3m and doubles both axes', () async {
      await _expectSize(
        'upscale_eedi3_2x',
        const CropResizeParameters(
          enabled: true,
          useIntegerUpscale: true,
          upscaleMethod: UpscaleMethod.eedi3Rpow2,
          upscaleFactor: 2,
          upscaleAlpha: 0.4,
          upscaleBeta: 0.3,
          upscaleGamma: 40.0,
          upscaleNrad: 3,
          upscaleMdis: 30,
        ),
        width: _srcWidth * 2,
        height: _srcHeight * 2,
      );
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('Spline36 integer upscale doubles both axes', () async {
      await _expectSize(
        'upscale_spline36_2x',
        const CropResizeParameters(
          enabled: true,
          useIntegerUpscale: true,
          upscaleMethod: UpscaleMethod.spline36,
          upscaleFactor: 2,
        ),
        width: _srcWidth * 2,
        height: _srcHeight * 2,
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('resize kernels (full encode)', () {
    // Every kernel in the widened list has to actually resolve to a
    // core.resize function that accepts the arguments we hand it.
    for (final kernel in [
      ResizeKernel.point,
      ResizeKernel.bilinear,
      ResizeKernel.bicubic,
      ResizeKernel.lanczos,
      ResizeKernel.spline16,
      ResizeKernel.spline36,
      ResizeKernel.spline64,
    ]) {
      test('${kernel.name} downscales to 352x288', () async {
        await _expectSize(
          'resize_${kernel.name}',
          CropResizeParameters(
            enabled: true,
            resizeEnabled: true,
            targetWidth: 352,
            targetHeight: 288,
            maintainAspect: false,
            kernel: kernel,
            // Kernel tuning is only read by the kernel it belongs to; setting
            // both proves the other is not passed on.
            bicubicB: 0.33,
            bicubicC: 0.33,
            lanczosTaps: 4,
          ),
          width: 352,
          height: 288,
        );
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  });
}
