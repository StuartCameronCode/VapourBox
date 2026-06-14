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
import 'package:uuid/uuid.dart';

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
  expect(result.success, isTrue, reason: result.error);
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
  });
}
