// Task #62: FFT3DFilter, and so the two Noise Reduction methods built on it,
// gave a different picture on every run, so the preview never showed exactly
// what the encode wrote. The bundle's FFT3DFilter is now built from source
// with patches/fft3dfilter-r2-determinism.patch; the push gate checks the
// plugin itself (vapoursynth_integration_test.dart, "fft3dfilter is
// deterministic"). This checks what the user sees, through the worker:
//
//   * two previews of the same frame are identical, and
//   * the preview is the lossless encode's frame, sample for sample,
//
// for the FFT3DFilter method (bt 3, where the parallel sigma race was) and
// TemporalDegrain2 with its FFT3D post pass, at frames away from the trim's
// ends so the preview's temporal neighbours are the encode's.
// docs/reports/task-62-fft3dfilter-determinism.
//
// Task #80: a preview and its encode are two processes, and FFT3DFilter's
// old default (measure=1) let FFTW time a different plan in each. The
// templates pass measure=0; havsfunc's QTGMC call passes nothing and relies
// on the patched default (deps 1.18.0-rc2 on), checked by the QTGMC case.
// docs/reports/task-80-fft3dfilter-fftw-estimate.
@Tags(['heavy'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

// Real film with grain and motion: 640x480, 24 fps, 120 frames, progressive.
String get _fixture =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'colorize_test.mp4');
String get _dir => p.join(WorkerHarness.outputDir, 'fft3dfilter_determinism');
const _start = 40, _end = 59;

typedef _Case = ({NoiseReductionParameters nr, QTGMCParameters deint, String since});

Map<String, dynamic> _job(String name, _Case c, {bool trimmed = true}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: _fixture,
      outputPath: p.join(_dir, '$name.mkv'),
      processingPipeline: ProcessingPipeline(
        deinterlace: c.deint,
        noiseReduction: c.nr,
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

int _maxAbsDiff(Uint8List a, Uint8List b) {
  expect(a.length, b.length, reason: 'frame sizes differ');
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > worst) worst = d;
  }
  return worst;
}

/// Whether the bundle is older than [version], pre-releases included
/// (`1.18.0-rc1` < `1.18.0-rc2` < `1.18.0`). deps <= 1.17.x ship an unpatched
/// FFT3DFilter (task #62); its default is measure=0 from 1.18.0-rc2 (task #80).
bool _bundleBefore(String version) {
  (List<int>, int) parse(String v) {
    final dash = v.indexOf('-');
    final nums = (dash < 0 ? v : v.substring(0, dash)).split('.').map(int.parse).toList();
    final rc = dash < 0
        ? 1 << 30
        : int.parse(RegExp(r'(\d+)$').firstMatch(v.substring(dash))!.group(1)!);
    return (nums, rc);
  }

  try {
    final (have, haveRc) = parse((jsonDecode(
            File(p.join(WorkerHarness.depsDir, 'version.json')).readAsStringSync())
        as Map<String, dynamic>)['version'] as String);
    final (want, wantRc) = parse(version);
    for (var i = 0; i < want.length; i++) {
      final v = i < have.length ? have[i] : 0;
      if (v != want[i]) return v < want[i];
    }
    return haveRc < wantRc;
  } catch (_) {
    return false;
  }
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
  });

  const noDeint = QTGMCParameters(enabled: false);
  final cases = <String, _Case>{
    'fft3d_bt3': (
      nr: NoiseReductionParameters(
          enabled: true, method: NoiseReductionMethod.fft3dFilter, fft3dSigma: 2.0, fft3dBt: 3),
      deint: noDeint,
      since: '1.18.0-rc1',
    ),
    'td2_postfft': (
      nr: NoiseReductionParameters(
          enabled: true, method: NoiseReductionMethod.temporalDegrain2, td2PostFft: 1),
      deint: noDeint,
      since: '1.18.0-rc1',
    ),
    // havsfunc's FFT3DFilter call (NoiseTR 1: bt 3) takes the plugin's
    // default; single rate, so output frame n is source frame n.
    'qtgmc_fft3dfilter': (
      nr: NoiseReductionParameters(enabled: false),
      deint: const QTGMCParameters(
          enabled: true,
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
          noiseProcess: 1,
          denoiser: 'fft3dfilter',
          noiseTr: 1),
      since: '1.18.0-rc2',
    ),
  };

  for (final MapEntry(key: name, value: c) in cases.entries) {
    test('$name: previews repeat and match the encode (tasks #62, #80)', () async {
      if (_bundleBefore(c.since)) {
        markTestSkipped('deps before ${c.since}: FFT3DFilter is unpatched (task #62) '
            'or its default is measure=1 (task #80)');
        return;
      }
      final r = await WorkerHarness.runJob(_job(name, c), label: '$name encode',
          timeout: const Duration(minutes: 20));
      expect(r.success, isTrue,
          reason: '${r.error}\n${r.logs.reversed.take(30).toList().reversed.join('\n')}');
      final out = r.outputPath ?? p.join(_dir, '$name.mkv');

      for (final frame in [_start + 8, _start + 12]) {
        // Converted to RGB as the preview converts its picture (task #67):
        // ffmpeg's default conversion of the same frame is not sample-exact.
        final encoded =
            await WorkerHarness.previewFrameRgb24(out, frame - _start, label: '${name}_enc');
        Future<Uint8List> preview(int run) async {
          final pv = await WorkerHarness.runPreview(_job('${name}_pv', c, trimmed: false),
              frame: frame);
          expect(pv.success, isTrue, reason: '${pv.error}\n${pv.logs}');
          return WorkerHarness.imageToRgb24(pv.png!, label: '${name}_pv$run');
        }

        final a = await preview(1);
        final b = await preview(2);
        final repeat = _maxAbsDiff(a, b);
        final vsEncode = _maxAbsDiff(a, encoded);
        // ignore: avoid_print
        print('  $name frame $frame: preview vs preview max $repeat, '
            'preview vs encode max $vsEncode (mean ${WorkerHarness.meanAbsDiff(a, encoded)})');
        expect(repeat, 0, reason: 'two previews of frame $frame differ');
        expect(vsEncode, 0, reason: 'the preview of frame $frame is not the encode\'s frame');
      }
    });
  }
}
