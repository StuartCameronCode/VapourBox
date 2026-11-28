// End to end, the Strength control does what its names say (issue #177): for
// every Noise Reduction and Sharpen method, an encode at "Very strong" moves
// the picture further from its input than one at "Light", and a Noise
// Reduction step at its own noise level gets closer to the clean source than
// the noisy input was.
//
// The values are the schemas' (pinned to the report by
// strength_presets_test.dart); this checks they act through the real worker.
// Fixture: 40 frames of small_clip.mp4 retimed to 25 fps, lossless, and a copy
// with sigma 6 noise from the worker's own Grain pass (as in the report).
//
// Run with: flutter test --tags heavy test/integration_strength_test.dart
@Tags(['heavy'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/models/grain_parameters.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _dir => p.join(WorkerHarness.outputDir, 'strength');
const _frames = 40;

FilterSchema _schema(String id) => FilterSchema.fromJson(
    jsonDecode(File('assets/filters/core/$id.json').readAsStringSync()) as Map<String, dynamic>);

Future<void> _ffmpeg(List<String> args) async {
  final r = await Process.run(WorkerHarness.ffmpegPath, ['-y', '-v', 'error', ...args],
      environment: WorkerHarness.ffmpegEnv);
  if (r.exitCode != 0) throw Exception('ffmpeg ${args.join(' ')}: ${r.stderr}');
}

/// Luma PSNR of [a] against [b] (dB).
Future<double> _psnrY(String a, String b) async {
  final r = await Process.run(
      WorkerHarness.ffmpegPath,
      ['-v', 'info', '-nostats', '-i', a, '-i', b, '-filter_complex', '[0:v][1:v]psnr', '-f', 'null', '-'],
      environment: WorkerHarness.ffmpegEnv);
  final m = RegExp(r'PSNR y:([\d.]+|inf)').firstMatch(r.stderr as String);
  if (m == null) throw Exception('psnr $a: ${r.stderr}');
  return m.group(1) == 'inf' ? 99 : double.parse(m.group(1)!);
}

Map<String, dynamic> _job(String input, String name, ProcessingPipeline pipeline,
        {bool interlaced = false}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: p.join(_dir, '$name.mkv'),
      processingPipeline: pipeline,
      encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
      inputWidth: interlaced ? 720 : 320,
      inputHeight: interlaced ? 576 : 240,
      inputPixelFormat: interlaced ? 'yuv422p' : 'yuv420p',
      inputFrameRate: 25,
      totalFrames: _frames,
      detectedFieldOrder: interlaced ? FieldOrder.topFieldFirst : null,
    ).toJson();

Future<String> _run(Map<String, dynamic> job, String label) async {
  final r = await WorkerHarness.runJob(job, label: label, timeout: const Duration(minutes: 5));
  expect(r.success, isTrue, reason: '$label: ${r.error}\n${r.logs.take(40).join('\n')}');
  return job['outputPath'] as String;
}

void main() {
  late String clean, noisy, vhsClean, vhsNoisy;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
    clean = p.join(_dir, 'clean.mkv');
    await _ffmpeg([
      '-ss', '20', '-i', p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'small_clip.mp4'),
      '-map', '0:v:0', '-frames:v', '$_frames', '-vf', 'setpts=N/25/TB', '-r', '25',
      '-an', '-c:v', 'ffv1', clean,
    ]);
    vhsClean = p.join(_dir, 'vhs_clean.mkv');
    await _ffmpeg([
      '-i', WorkerHarness.inputFile, '-map', '0:v:0', '-frames:v', '$_frames',
      '-vf', 'setpts=N/25/TB', '-r', '25', '-field_order', 'tt', '-an', '-c:v', 'ffv1', vhsClean,
    ]);
    const grain = GrainParameters(enabled: true, var_: 36, uvar: 9);
    noisy = await _run(
        _job(clean, 'noisy',
            const ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false), grain: grain)),
        'noisy fixture');
    vhsNoisy = await _run(
        _job(vhsClean, 'vhs_noisy',
            const ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false), grain: grain),
            interlaced: true),
        'vhs noisy fixture');
  });

  for (final filter in ['noise_reduction', 'sharpen']) {
    final schema = _schema(filter);
    for (final preset in schema.parameterPresets!.values.where((p) => p.label == 'Strength')) {
      final method = (preset.visibleWhen!['method'] as List).single as String;
      test('$filter $method: Very strong acts more than Light', () async {
        final qtgmc = method == 'qtgmc_builtin';
        final input = filter == 'sharpen' ? clean : (qtgmc ? vhsNoisy : noisy);
        final deint = qtgmc
            ? const QTGMCParameters(enabled: true, tff: true)
            : const QTGMCParameters(enabled: false);
        Future<String> encode(String? step) {
          final base = filter == 'noise_reduction'
              ? ParameterConverter.fromNoiseReduction(const NoiseReductionParameters(enabled: true))
              : ParameterConverter.fromSharpen(const SharpenParameters(enabled: true));
          final dyn = base.withValues({'method': method, ...?preset.options[step]});
          final pipeline = step == null
              ? ProcessingPipeline(deinterlace: deint)
              : filter == 'noise_reduction'
                  ? ProcessingPipeline(
                      deinterlace: deint, noiseReduction: ParameterConverter.toNoiseReduction(dyn))
                  : ProcessingPipeline(
                      deinterlace: deint, sharpen: ParameterConverter.toSharpen(dyn));
          return _run(_job(input, '${method}_${step ?? 'none'}', pipeline, interlaced: qtgmc),
              '$method $step');
        }

        // QTGMC's denoiser is measured against the same QTGMC with none.
        final reference = qtgmc ? await encode(null) : input;
        final light = await encode('Light');
        final very = await encode('Very strong');
        final lightFromInput = await _psnrY(light, reference);
        final veryFromInput = await _psnrY(very, reference);
        // ignore: avoid_print
        print('$filter $method: PSNR from input Light $lightFromInput, Very strong $veryFromInput');
        expect(veryFromInput, lessThan(lightFromInput - 0.5),
            reason: 'Very strong should change the picture clearly more than Light');

        if (filter == 'noise_reduction' && !qtgmc) {
          // At sigma 6 (Strong's own level) Strong is closer to clean than the input.
          final strong = await encode('Strong');
          expect(await _psnrY(strong, clean), greaterThan(await _psnrY(noisy, clean) + 1.0));
        }
      });
    }
  }
}
