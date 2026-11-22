// Task #101: DFTTest planned its FFTs with FFTW_PATIENT, which times
// candidate plans in each process, and plans round differently: a preview
// and its encode are two processes, so a DFTTest job could preview a picture
// the encode did not give. download-deps-* now apply
// patches/dfttest-bc5e018-fftw-estimate.patch (FFTW_ESTIMATE, one plan per
// machine) after task #98's. The push gate checks the plugin's marker and two
// processes (vapoursynth_integration_test.dart, "dfttest FFTW planning").
// This checks what the user sees, through the worker:
//
//   * six previews of the same frame (six fresh processes, so a per-process
//     plan would show) are identical, and
//   * the preview is the lossless encode's frame, sample for sample,
//
// for the Noise Reduction DFTTest method, QTGMC's dfttest denoiser, and
// TemporalDegrain2 with postFFT 3, whose spatial pass is FFT3DFilter: the
// mixed graph, where a PATIENT plan could have left wisdom an FFT3DFilter
// ESTIMATE request reused (task #80). Frames away from the trim's ends, so
// the preview's temporal neighbours are the encode's.
// docs/reports/task-101-dfttest-fftw-planning.
@Tags(['heavy'])
@Timeout(Duration(minutes: 30))
library;

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

import 'support/deps_version.dart';
import 'support/worker_harness.dart';

// Real film with grain and motion: 640x480, 24 fps, 120 frames, progressive.
String get _fixture =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'colorize_test.mp4');
String get _dir => p.join(WorkerHarness.outputDir, 'dfttest_determinism');
const _start = 40, _end = 59;
// The first deps release whose DFTTest plans with FFTW_ESTIMATE.
const _since = '1.18.0-rc4';
const _previews = 6;

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

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
  });

  const noDeint = QTGMCParameters(enabled: false);
  final cases = <String, _Case>{
    // The Noise Reduction DFTTest method at its defaults (3D plans).
    'nr_dfttest': (
      nr: NoiseReductionParameters(enabled: true, method: NoiseReductionMethod.dfttest),
      deint: noDeint,
      since: _since,
    ),
    // havsfunc's DFTTest call (NoiseTR 1: tbsize 3); single rate, so output
    // frame n is source frame n.
    'qtgmc_dfttest': (
      nr: NoiseReductionParameters(enabled: false),
      deint: const QTGMCParameters(
          enabled: true,
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
          noiseProcess: 1,
          denoiser: 'dfttest',
          noiseTr: 1),
      since: _since,
    ),
    // TemporalDegrain2: FFT3DFilter spatial pass + DFTTest post pass.
    'td2_postfft3': (
      nr: NoiseReductionParameters(
          enabled: true, method: NoiseReductionMethod.temporalDegrain2, td2PostFft: 3),
      deint: noDeint,
      since: _since,
    ),
  };

  for (final MapEntry(key: name, value: c) in cases.entries) {
    test('$name: previews repeat and match the encode (task #101)', () async {
      if (depsVersionBefore(WorkerHarness.depsDir, c.since)) {
        markTestSkipped('deps before ${c.since}: DFTTest plans with FFTW_PATIENT '
            '(task #101)');
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
        var repeat = 0;
        for (var run = 2; run <= _previews; run++) {
          final d = _maxAbsDiff(a, await preview(run));
          if (d > repeat) repeat = d;
        }
        final vsEncode = _maxAbsDiff(a, encoded);
        // ignore: avoid_print
        print('  $name frame $frame: $_previews previews max apart $repeat, '
            'preview vs encode max $vsEncode (mean ${WorkerHarness.meanAbsDiff(a, encoded)})');
        expect(repeat, 0, reason: '$_previews previews of frame $frame do not all agree');
        expect(vsEncode, 0, reason: 'the preview of frame $frame is not the encode\'s frame');
      }
    });
  }
}
