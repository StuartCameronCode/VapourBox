/// Full-encode smoke tests for the pipeline passes that previously had no
/// integration coverage: descratch, spotless, and subtitles.
///
/// These run the worker end-to-end (vspipe | ffmpeg) and confirm the pass loads
/// its plugin / add-on and produces a valid output video — complementing the
/// cheaper script-generation assertions in integration_filter_parameters_test.
///
/// Run headless via CI: flutter test test/integration_new_passes_test.dart
/// Heavy (full-encode) — tagged so it runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/chroma_denoise_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/descratch_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/spotless_parameters.dart';
import 'package:vapourbox/models/subtitle_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/new_passes';

VideoJob _baseJob(
  String name, {
  ProcessingPipeline? pipeline,
  SubtitleSettingsDto? subtitleSettings,
}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: WorkerHarness.inputFile,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: pipeline ??
          const ProcessingPipeline(
            deinterlace: QTGMCParameters(preset: QTGMCPreset.fast, tff: true, fpsDivisor: 2),
          ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.h264,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.passthrough,
      ),
      subtitleSettings: subtitleSettings,
    );

/// Assert the worker produced a playable video with a video stream.
Future<void> _expectValidVideo(JobResult result) async {
  // Include the tail of the worker log — "ffmpeg exited with -22" on its own
  // says nothing about which arguments were rejected.
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '${result.error}\n--- worker log (tail) ---\n${tail.join('\n')}');
  expect(File(result.outputPath!).existsSync(), isTrue,
      reason: 'output file should exist');
  final v = await WorkerHarness.firstStream(result.outputPath!,
      selector: 'v:0', entries: ['codec_name', 'width', 'height']);
  expect(v, isNotNull, reason: 'output should contain a video stream');
  print('  output video: ${v?['codec_name']} ${v?['width']}x${v?['height']}');
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  group('New pipeline passes (full encode)', () {
    test('descratch: DeScratch runs end-to-end', () async {
      final job = _baseJob(
        'descratch',
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(preset: QTGMCPreset.fast, tff: true, fpsDivisor: 2),
          descratch: DeScratchParameters(enabled: true, mindif: 6, maxgap: 4),
        ),
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: 'descratch');
      await _expectValidVideo(result);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('spotless: SpotLess runs end-to-end', () async {
      final job = _baseJob(
        'spotless',
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(preset: QTGMCPreset.fast, tff: true, fpsDivisor: 2),
          spotless: SpotLessParameters(enabled: true, blksize: 8, overlap: 4, pel: 1),
        ),
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: 'spotless');
      await _expectValidVideo(result);
    }, timeout: const Timeout(Duration(minutes: 5)));

    // Subtitles run a separate whisper pass after encode. We assert the pass
    // integrates without breaking the pipeline (valid output video). SRT content
    // depends on speech in the input audio, so we don't assert on it here.
    test('subtitles: whisper pass runs end-to-end', () async {
      final job = _baseJob(
        'subtitles',
        subtitleSettings: SubtitleSettingsDto.fromSubtitleParameters(
          const SubtitleParameters(
            enabled: true,
            model: WhisperModel.small,
            output: SubtitleOutput.srtFile,
          ),
        ),
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: 'subtitles');
      await _expectValidVideo(result);
    },
        timeout: const Timeout(Duration(minutes: 8)),
        skip: WorkerHarness.whisperAvailable
            ? false
            : 'whisper add-on not present (set VAPOURBOX_ADDONS_DIR or install the add-on)');

    // Issue #37: QTGMC with EZ Denoise + the knlmeanscl denoiser must never
    // crash the job. KNLMeansCL is OpenCL-only; on a headless CI runner (no
    // usable OpenCL device) the worker's knlm probe fails and the denoiser is
    // downgraded to dfttest, so the encode still succeeds. Before the fix this
    // crashed with a missing-namespace error (x64/Windows) or CL_INVALID_VALUE
    // (where the plugin is present but no GPU). We assert valid output — i.e.
    // the job completes via knlmeanscl OR the dfttest fallback, never crashing.
    test('knlmeanscl denoiser never crashes (runs or falls back to dfttest)', () async {
      final job = _baseJob(
        'knlmeanscl_fallback',
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
            ezDenoise: 1.5,
            denoiser: 'knlmeanscl',
          ),
        ),
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: 'knlmeanscl_fallback');
      await _expectValidVideo(result);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  // ===========================================================================
  // Issue #49: deinterlace working format, end-to-end.
  //
  // The script-generation assertions live in integration_qtgmc_parameters_test;
  // these confirm the converted pipeline actually runs through vspipe | ffmpeg
  // and — critically — that the working format never leaks into the encode.
  //
  // These use the 4:2:0 fixture rather than the shared 4:2:2 interlaced_test.avi:
  // the chroma upsample is a deliberate no-op on 4:2:2 sources, so 4:2:2 would
  // not exercise the path at all.
  // ===========================================================================
  group('Deinterlace working format (issue #49, full encode)', () {
    final yuv420Input = p.join(
        WorkerHarness.repoRoot, 'Tests', 'TestResources', 'pal-dvbt-fieldcoded-25i.ts');

    VideoJob job420(
      String name, {
      bool? chromaUpsampleFix,
      bool? highPrecision,
      String? chromaEdi,
    }) =>
        VideoJob(
          id: const Uuid().v4(),
          inputPath: yuv420Input,
          outputPath: '$_outDir/$name.mkv',
          // Supply the probe results the app always sends. ffprobe reports
          // nb_frames=N/A for MPEG-TS, and the worker falls back to
          // total_frames=1 / 720x480 / 29.97 when these are absent — which
          // silently produces a one-frame output.
          totalFrames: 126,
          inputFrameRate: 25.0,
          inputWidth: 720,
          inputHeight: 576,
          inputPixelFormat: 'yuv420p',
          processingPipeline: ProcessingPipeline(
            deinterlace: QTGMCParameters(
              preset: QTGMCPreset.fast,
              tff: true,
              fpsDivisor: 2,
              chromaUpsampleFix: chromaUpsampleFix,
              highPrecision: highPrecision,
              chromaEdi: chromaEdi,
            ),
          ),
          encodingSettings: const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.none,
          ),
          // Keep the encodes short — this group runs five of them.
          startFrame: 0,
          endFrame: 40,
        );

    Future<String> runAndGetPixFmt(String name, JobResult result) async {
      await _expectValidVideo(result);
      final v = await WorkerHarness.firstStream(result.outputPath!,
          selector: 'v:0', entries: ['pix_fmt']);
      print('  $name pix_fmt: ${v?['pix_fmt']}');
      return v?['pix_fmt'] as String;
    }

    setUpAll(() {
      expect(File(yuv420Input).existsSync(), isTrue,
          reason: '4:2:0 interlaced fixture missing: $yuv420Input');
    });

    // The working format (4:2:2 and/or 16-bit) must be restored before the
    // encode, so all three variants must produce the same output pixel format.
    test('working format never leaks into the encoded output', () async {
      final off = await runAndGetPixFmt(
          'deint_wf_off',
          await WorkerHarness.runJob(
              job420('deint_wf_off', chromaUpsampleFix: false, highPrecision: false)
                  .toJson(),
              label: 'deint_wf_off'));

      // Both options are opt-in, so the chroma variant must ask for it.
      final chroma = await runAndGetPixFmt(
          'deint_wf_chroma',
          await WorkerHarness.runJob(
              job420('deint_wf_chroma', chromaUpsampleFix: true).toJson(),
              label: 'deint_wf_chroma'));

      final bits = await runAndGetPixFmt(
          'deint_wf_16bit',
          await WorkerHarness.runJob(
              job420('deint_wf_16bit', highPrecision: true).toJson(),
              label: 'deint_wf_16bit'));

      expect(chroma, off,
          reason: 'the 4:2:2 working format must be restored before encode');
      expect(bits, off,
          reason: 'the 16-bit working format must be dithered back before encode');
    }, timeout: const Timeout(Duration(minutes: 15)));

    // havsfunc implements only ChromaEdi '' / 'nnedi3' / 'bob'. 'Blend' used to
    // reach QTGMC and corrupt chroma; it is now dropped, so the run must be
    // identical to one with no ChromaEdi set at all.
    test('unsupported ChromaEdi value is dropped, not passed to QTGMC', () async {
      final blend = await WorkerHarness.runJob(
          job420('deint_chromaedi_blend', chromaEdi: 'Blend').toJson(),
          label: 'chromaedi_blend');
      await _expectValidVideo(blend);

      final none = await WorkerHarness.runJob(
          job420('deint_chromaedi_none').toJson(),
          label: 'chromaedi_none');
      await _expectValidVideo(none);

      final blendHash = await WorkerHarness.frameHash(blend.outputPath!);
      final noneHash = await WorkerHarness.frameHash(none.outputPath!);
      expect(blendHash, noneHash,
          reason: 'ChromaEdi="Blend" must be dropped, producing the default pipeline');
      print('  frame hash matches: $blendHash');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  // Issue #50: the dehalo pass gained four havsfunc methods (FineDehalo2,
  // EdgeCleaner, Vinverse, Vinverse2). Script generation is asserted in the
  // Rust suite; what matters here is that each one actually loads its plugins
  // and produces frames — EdgeCleaner needs aWarpSharp2 + RemoveGrain, and the
  // Vinverse variants are pure std but easy to get wrong on chroma.
  group('dehalo methods (full encode)', () {
    Future<void> runMethod(DehaloMethod method, DehaloParameters params) async {
      final label = 'dehalo_${method.value.toLowerCase()}';
      final job = _baseJob(
        label,
        pipeline: ProcessingPipeline(
          deinterlace: const QTGMCParameters(
              preset: QTGMCPreset.fast, tff: true, fpsDivisor: 2),
          dehalo: params,
        ),
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: label);
      await _expectValidVideo(result);
    }

    test('FineDehalo2 runs end-to-end', () async {
      await runMethod(DehaloMethod.fineDehalo2,
          const DehaloParameters(enabled: true, method: DehaloMethod.fineDehalo2));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('EdgeCleaner runs end-to-end', () async {
      await runMethod(
          DehaloMethod.edgeCleaner,
          const DehaloParameters(
            enabled: true,
            method: DehaloMethod.edgeCleaner,
            edgeStrength: 15,
            edgeSmallMode: 1,
          ));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Vinverse runs end-to-end, with and without chroma', () async {
      await runMethod(
          DehaloMethod.vinverse,
          const DehaloParameters(
            enabled: true,
            method: DehaloMethod.vinverse,
            vinverseStrength: 3.0,
            vinverseAmount: 200,
            vinverseChroma: false,
          ));
      await runMethod(
          DehaloMethod.vinverse2,
          const DehaloParameters(
            enabled: true,
            method: DehaloMethod.vinverse2,
            vinverseChroma: true,
          ));
    }, timeout: const Timeout(Duration(minutes: 8)));

    test('DeHalo_alpha and FineDehalo advanced parameters run end-to-end', () async {
      await runMethod(
          DehaloMethod.dehaloAlpha,
          const DehaloParameters(
            enabled: true,
            method: DehaloMethod.dehaloAlpha,
            darkStr: 1.4,
            lowSens: 35,
            highSens: 65,
            superSample: 2.0,
          ));
      await runMethod(
          DehaloMethod.fineDehalo,
          const DehaloParameters(
            enabled: true,
            method: DehaloMethod.fineDehalo,
            limitLow: 60,
            limitHigh: 120,
            contra: 1.2,
            excludeCloseEdges: false,
            edgeProc: 0.5,
          ));
    }, timeout: const Timeout(Duration(minutes: 8)));
  });

  // Issue #50: CCD (chroma denoise) via the zsmooth plugin. This is the first
  // pass to depend on that plugin, so the encode is also the check that the
  // binary is present and loads in the bundled VapourSynth.
  group('chroma denoise / CCD (full encode)', () {
    test('CCD runs end-to-end, spatially and temporally', () async {
      final spatial = _baseJob(
        'ccd_spatial',
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(preset: QTGMCPreset.fast, tff: true, fpsDivisor: 2),
          chromaDenoise: ChromaDenoiseParameters(enabled: true, threshold: 10),
        ),
      );
      await _expectValidVideo(
          await WorkerHarness.runJob(spatial.toJson(), label: 'ccd_spatial'));

      final temporal = _baseJob(
        'ccd_temporal',
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(preset: QTGMCPreset.fast, tff: true, fpsDivisor: 2),
          chromaDenoise: ChromaDenoiseParameters(
            enabled: true,
            threshold: 8,
            temporalRadius: 2,
            pointsHigh: true,
          ),
        ),
      );
      await _expectValidVideo(
          await WorkerHarness.runJob(temporal.toJson(), label: 'ccd_temporal'));
    }, timeout: const Timeout(Duration(minutes: 10)));

    // CCD only touches chroma, so luma must come out bit-identical while chroma
    // moves. This is also what distinguishes "the filter ran" from "the filter
    // was silently skipped".
    test('CCD changes chroma and leaves luma alone', () async {
      Future<({double y, double u, double v})> run(
          String label, ChromaDenoiseParameters params) async {
        final job = VideoJob(
          id: const Uuid().v4(),
          inputPath: WorkerHarness.inputFile,
          outputPath: '$_outDir/$label.mkv',
          processingPipeline: ProcessingPipeline(
            deinterlace: const QTGMCParameters(enabled: false),
            chromaDenoise: params,
          ),
          encodingSettings: const EncodingSettings(
            // Lossless, so the measurement reflects the filter not the encoder.
            codec: VideoCodec.ffv1,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.none,
          ),
          inputWidth: 720,
          inputHeight: 576,
          inputFrameRate: 25.0,
          startFrame: 0,
          endFrame: 4,
        );
        final result = await WorkerHarness.runJob(job.toJson(), label: label);
        await _expectValidVideo(result);
        final avg = await WorkerHarness.frameAverages(result.outputPath!);
        print('  $label: Y=${avg.y.toStringAsFixed(3)} '
            'U=${avg.u.toStringAsFixed(3)} V=${avg.v.toStringAsFixed(3)}');
        return avg;
      }

      final off = await run('ccd_off', const ChromaDenoiseParameters());
      // A high threshold guarantees a measurable change on any source.
      final on = await run('ccd_on',
          const ChromaDenoiseParameters(enabled: true, threshold: 40));

      expect(on.y, closeTo(off.y, 0.001), reason: 'CCD must not touch luma');
      final chromaMoved = (on.u - off.u).abs() > 0.01 || (on.v - off.v).abs() > 0.01;
      expect(chromaMoved, isTrue,
          reason: 'CCD should have changed chroma; it may not have run at all');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
