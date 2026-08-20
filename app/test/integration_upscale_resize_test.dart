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
import 'dart:typed_data';

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

/// A lossless job with the source's real pixel format, for comparisons where
/// the encoder must not be part of what is measured.
///
/// The plain [_job] above encodes H.264 and leaves `inputPixelFormat` unset, so
/// the decoder normalises to yuv420p. Fine for "is the output 640x480", useless
/// for "is this the same picture" — the codec and the chroma round-trip would
/// both land in the difference.
VideoJob _losslessJob(
  String name,
  CropResizeParameters cropResize, {
  int startFrame = 0,
  int endFrame = 6,
}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: WorkerHarness.inputFile,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        cropResize: cropResize,
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      inputWidth: _srcWidth,
      inputHeight: _srcHeight,
      inputPixelFormat: 'yuv422p',
      inputFrameRate: 25.0,
      totalFrames: endFrame - startFrame + 1,
      startFrame: startFrame,
      endFrame: endFrame,
    );

/// Crop a packed rgb24 frame, in Dart.
///
/// The reference a crop is judged against is built by cropping the pipeline's
/// OWN uncropped output rather than by asking ffmpeg to crop the source, and
/// that is not incidental: `interlaced_test.avi` declares 79 frames but only 75
/// decode — it carries null frames, which the decoder's default CFR mode expands
/// onto the 25 fps grid. So `select=eq(n,N)` on the source counts decoded frames
/// while the pipeline counts timeline positions, and the two diverge wherever a
/// null frame sits. Comparing pipeline output against pipeline output uses one
/// decoder, one indexing scheme, and isolates the crop itself.
Uint8List _cropRgb24(
  Uint8List src, {
  required int srcWidth,
  required int x,
  required int y,
  required int width,
  required int height,
}) {
  final srcHeight = src.length ~/ (srcWidth * 3);
  expect(x + width, lessThanOrEqualTo(srcWidth), reason: 'crop past right edge');
  expect(y + height, lessThanOrEqualTo(srcHeight), reason: 'crop past bottom');
  final out = Uint8List(width * height * 3);
  for (var row = 0; row < height; row++) {
    final from = ((y + row) * srcWidth + x) * 3;
    out.setRange(row * width * 3, (row + 1) * width * 3, src, from);
  }
  return out;
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

  group('cropping', () {
    // Crop was exercised by the pipeline tests but nothing asserted the size it
    // produced — they ran a crop and checked the job succeeded, which passes
    // just as happily on a crop that did nothing.
    test('an asymmetric crop removes exactly the requested edges', () async {
      // Deliberately asymmetric on both axes. A symmetric crop cannot tell a
      // correct implementation from one that swaps left/right or top/bottom,
      // and a size-only assertion cannot tell either regardless.
      const l = 16, r = 8, t = 12, b = 4;
      const w = 720 - l - r; // 696
      const h = 576 - t - b; // 560

      await _expectSize(
        'crop_asymmetric',
        const CropResizeParameters(
          enabled: true,
          cropEnabled: true,
          cropLeft: l,
          cropRight: r,
          cropTop: t,
          cropBottom: b,
        ),
        width: w,
        height: h,
      );
    });

    test('the crop is taken from the right offset, not just the right size',
        () async {
      // A size assertion cannot tell a correct crop from one that swaps left
      // with right or top with bottom — both produce exactly the requested
      // dimensions. This compares the pixels.
      const l = 16, r = 8, t = 12, b = 4;
      const w = 720 - l - r, h = 576 - t - b;
      const frame = 3;

      final uncropped = await WorkerHarness.runJob(
          _losslessJob('crop_none', const CropResizeParameters(enabled: false))
              .toJson(),
          label: 'crop_none');
      expect(uncropped.success, isTrue, reason: uncropped.error);

      final cropped = await WorkerHarness.runJob(
          _losslessJob(
            'crop_offset',
            const CropResizeParameters(
              enabled: true,
              cropEnabled: true,
              cropLeft: l,
              cropRight: r,
              cropTop: t,
              cropBottom: b,
            ),
          ).toJson(),
          label: 'crop_offset');
      expect(cropped.success, isTrue, reason: cropped.error);

      final full = await WorkerHarness.frameRgb24(uncropped.outputPath!, frame,
          label: 'full');
      final actual = await WorkerHarness.frameRgb24(cropped.outputPath!, frame,
          label: 'cropped');

      double diffAt(int x, int y) => WorkerHarness.meanAbsDiff(
            actual,
            _cropRgb24(full,
                srcWidth: 720, x: x, y: y, width: w, height: h),
          );

      // The requested offset, and the two a swap would produce.
      final correct = diffAt(l, t);
      final swappedH = diffAt(r, t);
      final swappedV = diffAt(l, b);
      print('  crop offset diffs — correct ($l,$t): '
          '${correct.toStringAsFixed(2)}, '
          'left/right swapped ($r,$t): ${swappedH.toStringAsFixed(2)}, '
          'top/bottom swapped ($l,$b): ${swappedV.toStringAsFixed(2)}');

      // Not zero, and it cannot be: the two frames are converted to rgb24 at
      // different widths, so chroma interpolation at the edges of a 4:2:2 clip
      // differs slightly between them. Measured ~1.1 against ~10 and ~16 for
      // the swaps, so the margin below carries the assertion and the absolute
      // bound is only a backstop.
      expect(correct, lessThan(3.0),
          reason: 'the cropped output should be the region at ($l, $t) of the '
              'uncropped output, to within the rgb conversion');
      expect(correct * 3, lessThan(swappedH),
          reason: 'the crop matches the left/right-swapped offset almost as '
              'well as the requested one, so the horizontal edges are suspect');
      expect(correct * 3, lessThan(swappedV),
          reason: 'the crop matches the top/bottom-swapped offset almost as '
              'well as the requested one, so the vertical edges are suspect');
    });

    test('crop composes with resize, in that order', () async {
      // Crop first, then scale the cropped picture to the target — so the
      // target size is what comes out, whatever the crop was. If the order were
      // reversed the crop would eat into the target and the output would be
      // smaller than asked for.
      await _expectSize(
        'crop_then_resize',
        const CropResizeParameters(
          enabled: true,
          cropEnabled: true,
          cropLeft: 16,
          cropRight: 16,
          cropTop: 8,
          cropBottom: 8,
          resizeEnabled: true,
          targetWidth: 640,
          targetHeight: 480,
          maintainAspect: false,
          kernel: ResizeKernel.spline36,
        ),
        width: 640,
        height: 480,
      );
    });
  });

  group('the preview shows the same geometry as the render', () {
    // The analogue of the frame-mapping preview test in
    // integration_frame_mapping_test.dart: crop and resize are computed inside
    // the .vpy, and the encode and the preview are separate scripts. A pass
    // that reached one template and not the other renders a preview at a
    // different size or framing than the file the user gets — silently, since
    // both are individually valid pictures. The output-format block was in the
    // encode template only for exactly this reason once already.
    Future<void> expectPreviewMatchesRender(
      String name,
      CropResizeParameters cropResize, {
      required int width,
      required int height,
      int sourceFrame = 3,
    }) async {
      final job = _losslessJob(name, cropResize);
      final result = await WorkerHarness.runJob(job.toJson(), label: name);
      expect(result.success, isTrue, reason: result.error);

      final v = await WorkerHarness.firstStream(result.outputPath!,
          selector: 'v:0', entries: ['width', 'height']);
      expect(int.parse(v!['width'].toString()), width);
      expect(int.parse(v['height'].toString()), height);

      final pv = await WorkerHarness.runPreview(job.toJson(),
          frame: sourceFrame, label: '$name-pv');
      expect(pv.success, isTrue, reason: pv.toString());
      final preview =
          await WorkerHarness.imageToRgb24(pv.png!, label: '$name-pv');

      // No geometry pass changes the frame count, so the preview of source
      // frame N is output frame N. meanAbsDiff throws on a size mismatch, which
      // is the assertion that matters most here — a preview at a different
      // resolution is the failure this test exists to catch, and it surfaces as
      // a buffer-length difference rather than a pixel difference.
      final rendered = await WorkerHarness.frameRgb24(
          result.outputPath!, sourceFrame,
          label: '$name-out');
      final diff = WorkerHarness.meanAbsDiff(preview, rendered);
      print('  $name: preview vs render meanAbsDiff ${diff.toStringAsFixed(2)} '
          'at ${width}x$height');
      expect(diff, lessThan(2.0),
          reason: 'the preview and the render disagree about the picture at '
              'the same frame, despite agreeing on the size');
    }

    test('a crop reaches the preview path', () async {
      await expectPreviewMatchesRender(
        'pv_crop',
        const CropResizeParameters(
          enabled: true,
          cropEnabled: true,
          cropLeft: 16,
          cropRight: 8,
          cropTop: 12,
          cropBottom: 4,
        ),
        width: 696,
        height: 560,
      );
    });

    test('a resize reaches the preview path', () async {
      await expectPreviewMatchesRender(
        'pv_resize',
        const CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 512,
          targetHeight: 384,
          maintainAspect: false,
          kernel: ResizeKernel.spline36,
        ),
        width: 512,
        height: 384,
      );
    });

    test('crop and resize together reach the preview path', () async {
      await expectPreviewMatchesRender(
        'pv_crop_resize',
        const CropResizeParameters(
          enabled: true,
          cropEnabled: true,
          cropLeft: 16,
          cropRight: 16,
          cropTop: 8,
          cropBottom: 8,
          resizeEnabled: true,
          targetWidth: 640,
          targetHeight: 480,
          maintainAspect: false,
          kernel: ResizeKernel.spline36,
        ),
        width: 640,
        height: 480,
      );
    });
  });
}
