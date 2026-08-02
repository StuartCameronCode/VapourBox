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

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/aspect_ratio';

/// An anamorphic source, made at run time: 720x576 tagged 16:11, i.e. a PAL
/// widescreen DVD. The committed fixtures are all square-pixel, and this bug
/// only shows up on non-square ones.
late String _anamorphic;
const _srcWidth = 720;
const _srcHeight = 576;
const _srcSar = 16 / 11;

Future<({int width, int height, String sar, String dar})> _encode(
  String name,
  CropResizeParameters cropResize,
) async {
  final job = VideoJob(
    id: const Uuid().v4(),
    inputPath: _anamorphic,
    outputPath: '$_outDir/$name.mkv',
    processingPipeline: ProcessingPipeline(
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
    inputSar: '16:11',
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
}
