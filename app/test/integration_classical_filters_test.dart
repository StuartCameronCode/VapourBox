/// End-to-end checks for the classical filters added with deps 1.16.0
/// (app 1.7.0): SangNom anti-aliasing, NLMeans on the CPU (vszip 24), and the
/// three vs-jetpack ports — vine dehalo, mpeg2stinx, and the IVTC fade fix.
///
/// Each runs the worker for real (vspipe | ffmpeg) and checks a valid output;
/// the fade fix and NLMeans are also checked by what they do to the picture.
/// The measurements behind these methods are in
/// docs/reports/2026-11-classical-filters.
///
/// Heavy (full-encode) — tagged so it runs in the nightly workflow.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/anti_alias_parameters.dart';
import 'package:vapourbox/models/deblock_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/classical_filters';

VideoJob _job(String name, ProcessingPipeline pipeline,
        {String? input, int? frames, double? fps, int? width, int? height}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input ?? WorkerHarness.inputFile,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: pipeline,
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      totalFrames: frames,
      inputFrameRate: fps,
      inputWidth: width,
      inputHeight: height,
      inputPixelFormat: input == null ? null : 'yuv420p',
    );

Future<void> _expectValidVideo(JobResult result) async {
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '${result.error}\n--- worker log (tail) ---\n${tail.join('\n')}');
  final v = await WorkerHarness.firstStream(result.outputPath!,
      selector: 'v:0', entries: ['codec_name', 'width', 'height']);
  expect(v, isNotNull, reason: 'output should contain a video stream');
}

/// Mean |even-row mean - odd-row mean| of an rgb24 frame, 0-255: how far the
/// two fields sit apart in brightness.
double _fieldGap(Uint8List rgb, int width) {
  final rows = rgb.length ~/ (width * 3);
  var even = 0.0, odd = 0.0;
  for (var y = 0; y < rows; y++) {
    var sum = 0;
    final start = y * width * 3;
    for (var i = start; i < start + width * 3; i++) {
      sum += rgb[i];
    }
    if (y.isEven) {
      even += sum;
    } else {
      odd += sum;
    }
  }
  final perRow = width * 3.0;
  return ((even / (rows / 2)) - (odd / (rows / 2))).abs() / perRow;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  const progressive = QTGMCParameters(enabled: false);

  group('deps 1.16.0 classical filters', () {
    test('anti-alias: SangNom runs end-to-end', () async {
      final result = await WorkerHarness.runJob(
          _job('aa_sangnom', const ProcessingPipeline(
            deinterlace: progressive,
            antiAlias: AntiAliasParameters(enabled: true, method: AntiAliasMethod.sangnom),
          )).toJson(),
          label: 'aa_sangnom');
      await _expectValidVideo(result);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('noise reduction: NLMeans (CPU) runs end-to-end without OpenCL',
        () async {
      // OpenCL switched off for the worker: the CPU method must not care.
      final result = await WorkerHarness.runJob(
          _job('nr_nlmeans_cpu', const ProcessingPipeline(
            deinterlace: progressive,
            noiseReduction: NoiseReductionParameters(
                enabled: true, method: NoiseReductionMethod.nlMeans, knlmH: 2.0),
          )).toJson(),
          label: 'nr_nlmeans_cpu',
          extraEnv: const {'VAPOURBOX_DISABLE_OPENCL': '1'});
      await _expectValidVideo(result);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('noise reduction: NLMeans (CPU) gives KNLMeansCL\'s picture', () async {
      final probe = await Process.run(WorkerHarness.workerPath, ['--probe-opencl'],
          environment: WorkerHarness.workerEnv,
          workingDirectory: File(WorkerHarness.workerPath).parent.path);
      if (probe.stdout.toString().contains('"knlmDevice":null')) {
        print('  skipped: no OpenCL device for the KNLMeansCL reference');
        return;
      }
      Future<Uint8List> frame(NoiseReductionMethod method) async {
        final r = await WorkerHarness.runPreview(
            _job('nlm_vs_knlm_${method.name}', ProcessingPipeline(
              deinterlace: progressive,
              noiseReduction: NoiseReductionParameters(
                  enabled: true, method: method, knlmH: 2.5, knlmD: 1),
            )).toJson(),
            frame: 10,
            label: 'nlm_${method.name}');
        expect(r.success, isTrue, reason: r.errorTail);
        return WorkerHarness.imageToRgb24(r.png!, label: 'nlm_${method.name}');
      }

      final cpu = await frame(NoiseReductionMethod.nlMeans);
      final gpu = await frame(NoiseReductionMethod.knlMeans);
      final diff = WorkerHarness.meanAbsDiff(cpu, gpu);
      print('  NLMeans (CPU) vs KNLMeansCL: mean |diff| $diff');
      // Same algorithm and arguments: identical to the level on the probe
      // (docs/reports/2026-11-classical-filters); the slack is GPU float order.
      expect(diff, lessThan(0.5));
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('dehalo: vine runs end-to-end', () async {
      final result = await WorkerHarness.runJob(
          _job('dehalo_vine', const ProcessingPipeline(
            deinterlace: progressive,
            dehalo: DehaloParameters(enabled: true, method: DehaloMethod.vine),
          )).toJson(),
          label: 'dehalo_vine');
      await _expectValidVideo(result);
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('deblock: mpeg2stinx runs end-to-end after IVTC', () async {
      final result = await WorkerHarness.runJob(
          _job('deblock_mpeg2stinx', const ProcessingPipeline(
            deinterlace: QTGMCParameters(
                enabled: true, method: DeinterlaceMethod.ivtc, tff: true),
            deblock: DeblockParameters(enabled: true, method: DeblockMethod.mpeg2stinx),
          )).toJson(),
          label: 'deblock_mpeg2stinx');
      await _expectValidVideo(result);
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('ivtc: the fade fix closes the gap between a fading frame\'s fields',
        () async {
      // A fade applied AFTER the fields were split (as one applied to
      // telecined video is): each field fades at its own time, so every frame
      // of the fade has a brighter and a darker field — the comb no field
      // match can remove. 320x240, 30 frames (brightened so the fade has
      // somewhere to go), fading to black over half a second.
      final fixture = p.join(_outDir, 'fade_after_split.mkv');
      final make = await Process.run(
        WorkerHarness.ffmpegPath,
        [
          '-y', '-v', 'error', '-i',
          p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'small_clip.mp4'),
          '-vf', 'select=between(n\\,1400\\,1429),setpts=N/30/TB,eq=brightness=0.35,separatefields,'
              'fade=t=out:st=0:d=0.5,weave=first_field=top,format=yuv420p',
          '-r', '30', '-c:v', 'ffv1', fixture,
        ],
        environment: WorkerHarness.ffmpegEnv,
      );
      expect(make.exitCode, 0, reason: make.stderr.toString());

      Future<double> gap(bool fix) async {
        final result = await WorkerHarness.runJob(
            _job(
              'ivtc_fades_$fix',
              ProcessingPipeline(
                deinterlace: QTGMCParameters(
                  enabled: true,
                  method: DeinterlaceMethod.ivtc,
                  tff: true,
                  ivtcFixFades: fix,
                ),
              ),
              input: fixture,
              frames: 30,
              fps: 30,
              width: 320,
              height: 240,
            ).toJson(),
            label: 'ivtc_fades_$fix');
        await _expectValidVideo(result);
        // Frames well inside the fade (before it reaches black).
        var total = 0.0;
        for (final i in [2, 4, 6, 8]) {
          total += _fieldGap(await WorkerHarness.frameRgb24(result.outputPath!, i), 320);
        }
        return total / 4;
      }

      final before = await gap(false);
      final after = await gap(true);
      print('  field brightness gap: without fix $before, with fix $after');
      expect(before, greaterThan(1.0), reason: 'the fixture has no fade comb');
      expect(after, lessThan(before * 0.25));
    }, timeout: const Timeout(Duration(minutes: 8)));
  });
}
