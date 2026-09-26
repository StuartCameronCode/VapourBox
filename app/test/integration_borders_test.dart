/// Full-encode tests for Add Borders (issue #86).
///
/// Two things only a real encode can show. The picture must be *bordered*, not
/// rescaled to fill the canvas, so the pixels inside the bars have to be the
/// source's own. And the bars must be the right level in the clip's own format:
/// Pad to Fill used to leave AddBorders at its default fill, luma 0, which is
/// below video black on a limited-range source. Both are checked at 8-bit and
/// 10-bit, since a level that is right at one depth and wrong at the other is
/// exactly the class of bug these tests exist for.
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

String get _outDir => '${WorkerHarness.outputDir}/borders';

const _w = 720;
const _h = 576;

/// A flat mid-grey 720x576 source in [pixFmt], untagged. Flat so that "is this
/// pixel picture or bar" has one unambiguous answer anywhere in the frame.
Future<String> _fixture(String pixFmt) async {
  final path = '$_outDir/src_grey_$pixFmt.mkv';
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi',
      '-i', 'color=c=0x808080:size=${_w}x$_h:rate=25:duration=0.4',
      '-c:v', 'ffv1', '-pix_fmt', pixFmt,
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0, reason: 'fixture: ${result.stderr}');
  return path;
}

Map<String, dynamic> _job(String name, String input, String pixFmt,
    CropResizeParameters cropResize) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: input,
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
    inputWidth: _w,
    inputHeight: _h,
    inputPixelFormat: pixFmt,
    inputFrameRate: 25.0,
    startFrame: 0,
    endFrame: 4,
  ).toJson();
}

/// Crop 8px off every side, then border back out to the full 720x576.
CropResizeParameters _cropAndBorder({
  BorderColor color = BorderColor.black,
  String? custom,
}) =>
    CropResizeParameters(
      enabled: true,
      cropEnabled: true,
      cropLeft: 8,
      cropRight: 8,
      cropTop: 8,
      cropBottom: 8,
      padEnabled: true,
      padWidth: _w,
      padHeight: _h,
      padColor: color,
      padCustomColor: custom,
    );

/// One decoded frame's planes, in the file's own format.
class _Planes {
  final int width;
  final int height;
  final int bytesPerSample;
  final int chromaShiftW;
  final Uint8List raw;

  _Planes(this.width, this.height, this.bytesPerSample, this.chromaShiftW, this.raw);

  int _at(int offset) => bytesPerSample == 1
      ? raw[offset]
      : raw[offset] | (raw[offset + 1] << 8);

  int y(int row, int col) => _at((row * width + col) * bytesPerSample);

  /// Chroma for 4:2:0 / 4:2:2, addressed in luma coordinates.
  int u(int row, int col, {required bool verticallySubsampled}) {
    final cw = width >> chromaShiftW;
    final r = verticallySubsampled ? row >> 1 : row;
    final base = width * height;
    return _at((base + r * cw + (col >> chromaShiftW)) * bytesPerSample);
  }

  int v(int row, int col, {required bool verticallySubsampled}) {
    final cw = width >> chromaShiftW;
    final ch = verticallySubsampled ? height >> 1 : height;
    final r = verticallySubsampled ? row >> 1 : row;
    final base = width * height + cw * ch;
    return _at((base + r * cw + (col >> chromaShiftW)) * bytesPerSample);
  }
}

Future<_Planes> _firstFrame(String path, String pixFmt) async {
  final stream = await WorkerHarness.firstStream(path,
      selector: 'v:0', entries: ['width', 'height', 'pix_fmt']);
  expect(stream, isNotNull);
  expect(stream!['pix_fmt'], pixFmt, reason: 'output format must be the source\'s');
  final width = int.parse(stream['width'].toString());
  final height = int.parse(stream['height'].toString());

  final raw = File('$path.frame0.raw');
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-y', '-v', 'error', '-i', path, '-frames:v', '1', '-f', 'rawvideo', raw.path],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'decoding $path: ${r.stderr}');
  final bytes = await raw.readAsBytes();
  await raw.delete();
  return _Planes(width, height, pixFmt.contains('10') ? 2 : 1, 1, bytes);
}

Future<String> _encode(String name, String input, String pixFmt,
    CropResizeParameters params) async {
  final result = await WorkerHarness.runJob(_job(name, input, pixFmt, params), label: name);
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '${result.error}\n--- worker log (tail) ---\n${tail.join('\n')}');
  return result.outputPath!;
}

void main() {
  late String src8;
  late String src10;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    src8 = await _fixture('yuv420p');
    src10 = await _fixture('yuv422p10le');
  });

  group('Add Borders (full encode)', () {
    // [depth label, fixture, pix_fmt, vertically subsampled, scale from 8-bit]
    for (final (label, pixFmt, subV, scale) in [
      ('8-bit 4:2:0', 'yuv420p', true, 1),
      ('10-bit 4:2:2', 'yuv422p10le', false, 4),
    ]) {
      test('$label: crop then border back to the canvas, unscaled, in video black',
          () async {
        final input = pixFmt == 'yuv420p' ? src8 : src10;
        final out = await _encode('borders_black_$pixFmt', input, pixFmt, _cropAndBorder());
        final f = await _firstFrame(out, pixFmt);

        expect((f.width, f.height), (_w, _h), reason: 'output must be the canvas size');

        // Video black, scaled to the depth: 16/128 at 8-bit, 64/512 at 10-bit.
        // AddBorders' own default would have been luma 0.
        for (final (row, col) in [(0, 0), (7, 360), (300, 7), (568, 360), (300, 712)]) {
          expect(f.y(row, col), 16 * scale, reason: 'bar luma at ($row,$col)');
          expect(f.u(row, col, verticallySubsampled: subV), 128 * scale,
              reason: 'bar Cb at ($row,$col)');
          expect(f.v(row, col, verticallySubsampled: subV), 128 * scale,
              reason: 'bar Cr at ($row,$col)');
        }

        // The picture starts exactly 8px in and is the flat grey it was — a
        // rescale to fill the canvas would have left no bar at all.
        final grey = f.y(288, 360);
        expect(grey, isNot(16 * scale));
        for (final (row, col) in [(8, 360), (300, 8), (567, 360), (300, 711)]) {
          expect(f.y(row, col), grey, reason: 'picture luma at ($row,$col)');
        }
      }, timeout: const Timeout(Duration(minutes: 5)));
    }

    test('a custom colour is converted into the clip\'s format', () async {
      // White at 10-bit limited is Y=940 — not 1023, and not 235.
      final out = await _encode('borders_white_10bit', src10, 'yuv422p10le',
          _cropAndBorder(color: BorderColor.custom, custom: '#FFFFFF'));
      final f = await _firstFrame(out, 'yuv422p10le');
      expect(f.y(0, 0), 940);
      expect(f.u(0, 0, verticallySubsampled: false), 512);
      expect(f.v(0, 0, verticallySubsampled: false), 512);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Pad to Fill bars are video black too', () async {
      // 720x576 fitted into a 1024x576 box leaves 152px pillars each side.
      final out = await _encode(
        'borders_pad_to_fill',
        src8,
        'yuv420p',
        const CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 1024,
          targetHeight: 576,
          maintainAspect: true,
          padToAspect: true,
        ),
      );
      final f = await _firstFrame(out, 'yuv420p');
      expect((f.width, f.height), (1024, 576));
      expect(f.y(288, 0), 16, reason: 'was 0 before issue #86');
      expect(f.y(288, 1023), 16);
      expect(f.y(288, 512), isNot(16), reason: 'the picture itself');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a picture bigger than the canvas fails with a clear message', () async {
      final result = await WorkerHarness.runJob(
        _job('borders_too_big', src8, 'yuv420p', const CropResizeParameters(
          enabled: true,
          padEnabled: true,
          padWidth: 704,
          padHeight: 576,
        )),
        label: 'borders_too_big',
      );
      expect(result.success, isFalse,
          reason: 'silently producing the wrong frame size is the failure to avoid');
      final all = '${result.error}\n${result.logs.join('\n')}';
      expect(all, contains('larger than the 704x576 canvas'));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('the preview shows the bars too', () async {
      // Preview and encode are separate scripts; assert both.
      final preview = await WorkerHarness.runPreview(
          _job('borders_preview', src8, 'yuv420p', _cropAndBorder()),
          frame: 2);
      expect(preview.success, isTrue, reason: preview.error);
      final rgb = await WorkerHarness.imageToRgb24(preview.png!, label: 'borders');
      expect(rgb.length, _w * _h * 3, reason: 'preview must be the canvas size');
      // Video black decodes to RGB 0; the grey picture does not.
      expect(rgb.sublist(0, 3), [0, 0, 0]);
      final centre = (288 * _w + 360) * 3;
      expect(rgb[centre], greaterThan(64));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
