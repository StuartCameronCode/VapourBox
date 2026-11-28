// Issue #253: Colour Correction's automatic white balance used to build a new
// expression for every frame, and on akarin (every bundle but macOS x64) each
// one was an LLVM compile, serialised under the GIL. It is now one expression
// that reads the chroma means PlaneStats stamps on each frame. Automatic
// levels is unchanged (a per-frame std.Levels), and runs here alongside it.
// docs/reports/issue-253-auto-colour-per-frame-expr compares the new code
// with the old on synthetic clips (identical at 8-12 bits; at 16 bits a few
// chroma planes in 1,000 one step apart); this checks the user's view through
// the worker on a real one:
//
//   * each filter changes the picture (against the same job with it off),
//   * the preview of a frame is the lossless encode's frame, sample for
//     sample, with both filters on at strengths below 1.
@Tags(['heavy'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/color_correction_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

// Camera footage with colour: 320x240, 29.97 fps, 8-bit 4:2:0, progressive.
String get _fixture =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'small_clip.mp4');
String get _dir => p.join(WorkerHarness.outputDir, 'auto_colour');
const _start = 300, _end = 339;

Map<String, dynamic> _job(String name, ColorCorrectionParameters cc,
        {bool trimmed = true}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: _fixture,
      outputPath: p.join(_dir, '$name.mkv'),
      processingPipeline: ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        colorCorrection: cc,
      ),
      encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
      inputWidth: 320,
      inputHeight: 240,
      inputPixelFormat: 'yuv420p',
      inputFrameRate: 29.97,
      startFrame: trimmed ? _start : null,
      endFrame: trimmed ? _end : null,
    ).toJson();

int _maxAbsDiff(Uint8List a, Uint8List b) {
  expect(a.length, b.length, reason: 'frame sizes differ');
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > worst) worst = d;
  }
  return worst;
}

Future<String> _encode(String name, ColorCorrectionParameters cc) async {
  final r = await WorkerHarness.runJob(_job(name, cc), label: '$name encode',
      timeout: const Duration(minutes: 5));
  expect(r.success, isTrue,
      reason: '${r.error}\n${r.logs.reversed.take(30).toList().reversed.join('\n')}');
  return r.outputPath ?? p.join(_dir, '$name.mkv');
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
  });

  // Enabled with nothing switched on: the pass's own reference.
  const off = ColorCorrectionParameters(enabled: true);
  const white = ColorCorrectionParameters(
      enabled: true, applyAutoWhiteBalance: true, autoWhiteBalanceStrength: 0.8);
  const levels = ColorCorrectionParameters(
      enabled: true, applyAutoLevels: true, autoLevelsStrength: 0.6);
  const both = ColorCorrectionParameters(
      enabled: true,
      applyAutoLevels: true,
      autoLevelsStrength: 0.6,
      applyAutoWhiteBalance: true,
      autoWhiteBalanceStrength: 0.8);

  test('each automatic filter changes the picture (issue #253)', () async {
    final reference = await _encode('off', off);
    for (final MapEntry(key: name, value: cc) in {'white': white, 'levels': levels}.entries) {
      final out = await _encode(name, cc);
      for (final frame in [5, 25]) {
        final a = await WorkerHarness.previewFrameRgb24(reference, frame, label: 'off_$frame');
        final b = await WorkerHarness.previewFrameRgb24(out, frame, label: '${name}_$frame');
        final mean = WorkerHarness.meanAbsDiff(a, b);
        // ignore: avoid_print
        print('  $name frame $frame: mean change ${mean.toStringAsFixed(2)} levels');
        expect(mean, greaterThan(0.2), reason: 'automatic $name changed nothing');
      }
    }
  });

  test('preview is the encode\'s frame, sample for sample (issue #253)', () async {
    final out = await _encode('both', both);
    for (final frame in [_start + 10, _start + 30]) {
      final encoded =
          await WorkerHarness.previewFrameRgb24(out, frame - _start, label: 'both_enc');
      final pv = await WorkerHarness.runPreview(_job('both_pv', both, trimmed: false),
          frame: frame);
      expect(pv.success, isTrue, reason: '${pv.error}\n${pv.logs}');
      final preview = await WorkerHarness.imageToRgb24(pv.png!, label: 'both_pv');
      final d = _maxAbsDiff(preview, encoded);
      // ignore: avoid_print
      print('  frame $frame: preview vs encode max $d');
      expect(d, 0, reason: 'the preview of frame $frame is not the encode\'s frame');
    }
  });
}
