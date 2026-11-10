/// Full-encode tests for the aspect-ratio controls (issue #50).
///
/// These assert on the *output metadata*, which is the only place the bug was
/// visible: SAR used to be dropped whenever a resize ran, so an anamorphic
/// source came out geometrically wrong with no error anywhere. Script-generation
/// tests can't see that — it happens in the ffmpeg arguments — so this suite
/// probes the encoded file's sample and display aspect ratios.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/geometry_parameters.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/preview_frame_info.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/image_dimensions.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart'
    show processedDisplayAspect;

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/aspect_ratio';

/// An anamorphic source, made at run time: 720x576 tagged 16:11, i.e. a PAL
/// widescreen DVD. The committed fixtures are all square-pixel, and this bug
/// only shows up on non-square ones.
late String _anamorphic;
const _srcWidth = 720;
const _srcHeight = 576;
const _srcSar = 16 / 11;

/// The issue #149 source: 720x576 PAL 4:3 (16:15 pixels), a flat mid-grey so
/// the picture's extent inside the bars can be measured.
late String _pal43;

VideoJob _job(
  String name,
  CropResizeParameters cropResize, {
  required String input,
  required String inputSar,
  ProcessingPipeline? pipeline,
}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: pipeline ??
          ProcessingPipeline(
            deinterlace: const QTGMCParameters(enabled: false),
            cropResize: cropResize,
          ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.h264,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      inputWidth: _srcWidth,
      inputHeight: _srcHeight,
      inputFrameRate: 25.0,
      inputPixelFormat: 'yuv420p',
      inputSar: inputSar,
    );

/// Preview one frame the way the app does, returning the PNG, what the
/// worker reported for it, and the display aspect the app draws it at.
Future<({Uint8List png, PreviewFrameInfo info, double? aspect})> _preview(
  String name,
  CropResizeParameters cropResize, {
  required String input,
  required String inputSar,
  ProcessingPipeline? pipeline,
}) async {
  final job = _job(name, cropResize,
      input: input, inputSar: inputSar, pipeline: pipeline);
  final result =
      await WorkerHarness.runPreview(job.toJson(), frame: 2, label: name);
  expect(result.success, isTrue, reason: '$name: $result');
  final info = PreviewFrameInfo.parse(result.logs);
  expect(info, isNotNull, reason: '$name: no PREVIEW_INFO line');
  final aspect = processedDisplayAspect(result.png, info);
  print('  $name (preview): ${encodedImageSize(result.png!)} '
      'SAR=${info!.outputSar} DAR=${info.outputDar} -> drawn at $aspect');
  return (png: result.png!, info: info, aspect: aspect);
}

/// Columns of the middle row that are picture rather than black bars.
Future<int> _pictureWidth(Uint8List rgb24, int width, int height) async {
  final row = (height ~/ 2) * width * 3;
  var count = 0;
  for (var x = 0; x < width; x++) {
    final i = row + x * 3;
    if (rgb24[i] + rgb24[i + 1] + rgb24[i + 2] > 3 * 64) count++;
  }
  return count;
}

Future<({int width, int height, String sar, String dar})> _encode(
  String name,
  CropResizeParameters cropResize, {
  String? input,
  String inputSar = '16:11',
  ProcessingPipeline? pipeline,
}) async {
  final job = VideoJob(
    id: const Uuid().v4(),
    inputPath: input ?? _anamorphic,
    outputPath: '$_outDir/$name.mkv',
    processingPipeline: pipeline ??
        ProcessingPipeline(
          deinterlace: const QTGMCParameters(enabled: false),
          cropResize: cropResize,
        ),
    encodingSettings: const EncodingSettings(
      codec: VideoCodec.h264,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none,
    ),
    inputWidth: _srcWidth,
    inputHeight: _srcHeight,
    inputFrameRate: 25.0,
    inputSar: inputSar,
    startFrame: 0,
    endFrame: 4,
  );

  final result = await WorkerHarness.runJob(job.toJson(), label: name);
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '${result.error}\n--- worker log (tail) ---\n${tail.join('\n')}');

  final v = await WorkerHarness.firstStream(result.outputPath!,
      selector: 'v:0',
      entries: ['width', 'height', 'sample_aspect_ratio', 'display_aspect_ratio']);
  expect(v, isNotNull);
  final out = (
    width: int.parse(v!['width'].toString()),
    height: int.parse(v['height'].toString()),
    sar: v['sample_aspect_ratio']?.toString() ?? '1:1',
    dar: v['display_aspect_ratio']?.toString() ?? '',
  );
  print('  $name: ${out.width}x${out.height} SAR=${out.sar} DAR=${out.dar}');
  return out;
}

/// Display aspect as a number, from the stored size and the SAR.
double _displayAspect(({int width, int height, String sar, String dar}) out) {
  final parts = out.sar.split(':');
  final sar = parts.length == 2 && double.parse(parts[1]) != 0
      ? double.parse(parts[0]) / double.parse(parts[1])
      : 1.0;
  return out.width * sar / out.height;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);

    _anamorphic = '$_outDir/src_anamorphic_16x11.mkv';
    final result = await Process.run(
      WorkerHarness.ffmpegPath,
      [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi',
        '-i', 'testsrc=size=${_srcWidth}x$_srcHeight:rate=25:duration=0.4',
        '-c:v', 'ffv1', '-pix_fmt', 'yuv420p',
        // 16:11 pixels: PAL widescreen. 720 * 16/11 / 576 = 1.818 ≈ 16:9.
        '-vf', 'setsar=16/11',
        _anamorphic,
      ],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(result.exitCode, 0, reason: 'fixture: ${result.stderr}');
    final src = await WorkerHarness.firstStream(_anamorphic,
        selector: 'v:0', entries: ['sample_aspect_ratio']);
    expect(src?['sample_aspect_ratio'], '16:11',
        reason: 'fixture must be anamorphic to exercise this at all');

    _pal43 = '$_outDir/src_pal_4x3_16x15.mkv';
    final pal = await Process.run(
      WorkerHarness.ffmpegPath,
      [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi',
        '-i', 'color=c=0x808080:size=${_srcWidth}x$_srcHeight:rate=25:duration=0.4',
        '-c:v', 'ffv1', '-pix_fmt', 'yuv420p',
        // 16:15 pixels: PAL 4:3. 720 * 16/15 / 576 = 4:3.
        '-vf', 'setsar=16/15',
        _pal43,
      ],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(pal.exitCode, 0, reason: 'fixture: ${pal.stderr}');
  });

  group('aspect ratio (full encode)', () {
    // The bug: with a resize active the SAR was never re-applied, so a 16:9
    // anamorphic source came out as a 5:4 picture.
    test('resizing keeps the source pixel aspect', () async {
      final out = await _encode(
        'aspect_preserve_resize',
        const CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 1440,
          maintainAspect: true,
        ),
      );
      expect(out.sar, '16:11', reason: 'SAR must survive a resize');
      expect(_displayAspect(out), closeTo(_srcWidth * _srcSar / _srcHeight, 0.02),
          reason: 'the picture should still be the shape it was');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('squaring the pixels resamples to the display shape', () async {
      final out = await _encode(
        'aspect_square_no_resize',
        const CropResizeParameters(
          enabled: true,
          pixelAspect: PixelAspectMode.square,
        ),
      );
      // Height kept, width widened to the display shape, pixels now square.
      expect(out.height, _srcHeight);
      expect(out.width, closeTo(_srcWidth * _srcSar, 2));
      expect(out.sar, anyOf('1:1', ''),
          reason: 'squared output must not carry a non-square SAR');
      expect(_displayAspect(out), closeTo(_srcWidth * _srcSar / _srcHeight, 0.02));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('squaring while resizing fits the box by display shape', () async {
      final out = await _encode(
        'aspect_square_resize',
        const CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 1280,
          maintainAspect: true,
          pixelAspect: PixelAspectMode.square,
        ),
      );
      expect(out.width, 1280);
      // 1280 wide at the source's 1.818 display aspect is ~704 high — not the
      // 1024 that fitting by stored 720x576 would have produced.
      expect(out.height, closeTo(1280 / (_srcWidth * _srcSar / _srcHeight), 2));
      expect(_displayAspect(out), closeTo(_srcWidth * _srcSar / _srcHeight, 0.02));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a forced display aspect overrides the source', () async {
      final out = await _encode(
        'aspect_forced_dar',
        const CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 1024,
          maintainAspect: true,
          displayAspect: '4:3',
        ),
      );
      // Declared as a DAR, so ffmpeg derives whatever SAR the frame needs.
      expect(_displayAspect(out), closeTo(4 / 3, 0.02));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a custom pixel aspect is stamped verbatim', () async {
      final out = await _encode(
        'aspect_custom_sar',
        const CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 720,
          maintainAspect: true,
          pixelAspect: PixelAspectMode.custom,
          customSar: '64:45',
        ),
      );
      expect(out.sar, '64:45');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('padding fills the target box exactly', () async {
      final out = await _encode(
        'aspect_padded',
        const CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 1280,
          targetHeight: 1024,
          maintainAspect: true,
          pixelAspect: PixelAspectMode.square,
          padToAspect: true,
        ),
      );
      // Fitting 1.818:1 inside 1280x1024 leaves the picture short vertically;
      // padding takes it back out to the full box.
      expect(out.width, 1280);
      expect(out.height, 1024);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  // Issue #149: a 720x576 PAL 4:3 capture resized to 1440x1080 and given
  // borders out to 1920x1080 previewed squashed, because the processed frame
  // was drawn at the source's 4:3. The preview now reports the aspect the
  // encode declares, and is fitted with the same SAR.
  group('preview aspect (issue #149)', () {
    CropResizeParameters reporter(PixelAspectMode mode) => CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 1440,
          targetHeight: 1080,
          maintainAspect: true,
          pixelAspect: mode,
          padEnabled: true,
          padWidth: 1920,
          padHeight: 1080,
        );

    test('square pixels: drawn 16:9, picture fitted like the encode', () async {
      final params = reporter(PixelAspectMode.square);
      final preview = await _preview('preview_149_square', params,
          input: _pal43, inputSar: '16:15');
      expect(encodedImageSize(preview.png), const Size(1920, 1080));
      expect(preview.info.outputSar, isNull);
      expect(preview.info.outputDar, isNull);
      expect(preview.aspect, closeTo(16 / 9, 1e-6),
          reason: 'the processed frame must not be drawn at the source\'s 4:3');

      // The picture inside the bars is the width the encode makes it: 4:3
      // at 1080 tall is 1440. Without the source SAR in the preview job it
      // was fitted as 1350.
      final out = await _encode('aspect_149_square', params,
          input: _pal43, inputSar: '16:15');
      expect((out.width, out.height), (1920, 1080));
      final encoded = await _pictureWidth(
          await WorkerHarness.frameRgb24(
              '$_outDir/aspect_149_square.mkv', 0, label: 'enc149'),
          1920, 1080);
      final previewed = await _pictureWidth(
          await WorkerHarness.imageToRgb24(preview.png, label: 'pv149'),
          1920, 1080);
      print('  picture width: encode $encoded, preview $previewed');
      expect(encoded, closeTo(1440, 4));
      expect(previewed, closeTo(encoded, 4));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('preserve: drawn at the SAR the encode stamps', () async {
      final params = reporter(PixelAspectMode.preserve);
      final preview = await _preview('preview_149_preserve', params,
          input: _pal43, inputSar: '16:15');
      expect(preview.info.outputSar, closeTo(16 / 15, 1e-9));
      final out = await _encode('aspect_149_preserve', params,
          input: _pal43, inputSar: '16:15');
      expect(preview.aspect, closeTo(_displayAspect(out), 0.01),
          reason: 'the preview must be drawn at the encode\'s display aspect');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a forced display aspect is reported as a DAR', () async {
      final preview = await _preview(
        'preview_149_dar',
        const CropResizeParameters(enabled: true, displayAspect: '16:9'),
        input: _pal43,
        inputSar: '16:15',
      );
      expect(preview.info.outputDar, closeTo(16 / 9, 1e-9));
      expect(preview.aspect, closeTo(16 / 9, 1e-9));
    }, timeout: const Timeout(Duration(minutes: 5)));

    // The everyday case, and the one the fix could break: an anamorphic
    // source that no pass reshapes. Before #149 both sides were drawn at the
    // source's aspect without asking; now the processed side relies on the
    // worker's report, so it must come out the source's shape.
    test('an anamorphic source only denoised keeps its shape', () async {
      final pipeline = ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        noiseReduction:
            NoiseReductionParameters.fromPreset(NoiseReductionPreset.light),
      );
      const none = CropResizeParameters();
      final preview = await _preview('preview_149_denoise', none,
          input: _anamorphic, inputSar: '16:11', pipeline: pipeline);
      expect(encodedImageSize(preview.png), Size(_srcWidth.toDouble(), _srcHeight.toDouble()));
      expect(preview.info.outputSar, closeTo(16 / 11, 1e-9));
      final out = await _encode('aspect_149_denoise', none,
          input: _anamorphic, inputSar: '16:11', pipeline: pipeline);
      const source = _srcWidth * _srcSar / _srcHeight;
      expect(_displayAspect(out), closeTo(source, 0.01));
      expect(preview.aspect, closeTo(source, 0.01),
          reason: 'with nothing reshaping it the processed frame must be '
              'drawn at the source\'s display aspect, as it was before #149');
    }, timeout: const Timeout(Duration(minutes: 5)));

    // A quarter turn swaps the stored width and height and inverts the SAR:
    // 720x576 at 16:15 (4:3) becomes 576x720 at 15:16 (3:4).
    test('a rotated anamorphic source is drawn at the encode\'s shape',
        () async {
      final pipeline = ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        geometry:
            const GeometryParameters(enabled: true, rotation: Rotation.cw90),
      );
      const none = CropResizeParameters();
      final preview = await _preview('preview_149_rotate', none,
          input: _pal43, inputSar: '16:15', pipeline: pipeline);
      expect(encodedImageSize(preview.png), Size(_srcHeight.toDouble(), _srcWidth.toDouble()));
      expect(preview.info.outputSar, closeTo(15 / 16, 1e-9));
      final out = await _encode('aspect_149_rotate', none,
          input: _pal43, inputSar: '16:15', pipeline: pipeline);
      expect((out.width, out.height), (_srcHeight, _srcWidth));
      expect(_displayAspect(out), closeTo(3 / 4, 0.01));
      expect(preview.aspect, closeTo(_displayAspect(out), 0.01));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
