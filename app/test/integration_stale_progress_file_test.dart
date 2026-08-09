// A leftover progress file must not convince the worker the encode is done.
//
// The worker polls `${TMPDIR}/vb_progress_${job.id}` for ffmpeg's progress, and
// `job.id` is the queue item's id — identical every time that item is re-run. On
// the way out, ffmpeg writes `progress=end`, so a cancelled run leaves one
// behind. The next run's loop polls immediately, before its own ffmpeg has
// opened and truncated the file, reads the previous run's tail, concludes the
// encode has already finished, breaks out on the first iteration, and then
// blocks forever in `decoder.wait()` while the pipeline encodes at full speed
// behind it.
//
// The user-visible result is a job that never reports progress and never
// completes: the app sits on "processing" with a spinner. Four fixes were made
// in the app for that symptom before the cause was found here, because the app
// was behaving correctly throughout — the worker genuinely never reported
// anything.
//
// It never reproduced under test because every test generated a fresh job id, so
// the file never pre-existed. This test seeds it deliberately, which is the only
// way to make the failure deterministic — in the wild it is a race between the
// first poll and ffmpeg's truncate, which is why it came and went.
@Tags(['heavy'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

void main() {
  setUpAll(() async => WorkerHarness.ensureReady());

  test('a stale progress=end does not abort the next run', () async {
    final jobId = const Uuid().v4();

    // Exactly what a cancelled run leaves behind: real progress lines followed
    // by the terminating `progress=end`.
    final stale = File(p.join(Directory.systemTemp.path, 'vb_progress_$jobId'));
    await stale.writeAsString([
      'frame=1200',
      'fps=48.0',
      'out_time_ms=48000000',
      'dup_frames=0',
      'drop_frames=0',
      'speed=1.9x',
      'progress=end',
      '',
    ].join('\n'));
    expect(await stale.exists(), isTrue);
    addTearDown(() async {
      if (await stale.exists()) await stale.delete();
    });

    final job = VideoJob(
      id: jobId, // the same id as the "previous run", as a re-run would be
      inputPath: WorkerHarness.inputFile,
      outputPath: p.join(WorkerHarness.outputDir, 'stale_progress.mkv'),
      processingPipeline: const ProcessingPipeline(
        deinterlace:
            QTGMCParameters(enabled: true, preset: QTGMCPreset.fast, tff: true),
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.h264,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.passthrough,
      ),
    );

    final result = await WorkerHarness.runJob(
      job.toJson(),
      label: 'stale progress file',
      timeout: const Duration(minutes: 3),
    );

    // Before the fix this timed out: the worker broke out of its progress loop
    // on the first iteration and sat in decoder.wait() forever.
    expect(result.success, isTrue,
        reason: 'the worker did not complete with a stale progress file '
            'present.\n${result.error}\n'
            '${result.logs.length > 20 ? result.logs.sublist(result.logs.length - 20).join('\n') : result.logs.join('\n')}');

    final out = File(result.outputPath!);
    expect(await out.exists(), isTrue, reason: 'no output produced');
    expect(await out.length(), greaterThan(0));

    // And it must have actually encoded, not just exited cleanly.
    final v = await WorkerHarness.firstStream(result.outputPath!,
        selector: 'v:0', entries: ['codec_name', 'width', 'height']);
    expect(v, isNotNull, reason: 'output has no video stream');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('progress is still reported when a stale file is present', () async {
    // The completion check above can pass on a short clip even if progress was
    // never reported. Progress reaching the app is the actual symptom, so assert
    // it directly.
    final jobId = const Uuid().v4();
    final stale = File(p.join(Directory.systemTemp.path, 'vb_progress_$jobId'));
    await stale.writeAsString('frame=999\nprogress=end\n');
    addTearDown(() async {
      if (await stale.exists()) await stale.delete();
    });

    final job = VideoJob(
      id: jobId,
      inputPath: WorkerHarness.inputFile,
      outputPath: p.join(WorkerHarness.outputDir, 'stale_progress_events.mkv'),
      processingPipeline: const ProcessingPipeline(
        deinterlace: QTGMCParameters(
            enabled: true, preset: QTGMCPreset.slow, tff: true),
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.h264,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.passthrough,
      ),
    );

    final result = await WorkerHarness.runJob(job.toJson(),
        label: 'stale progress, events', timeout: const Duration(minutes: 3));

    expect(result.success, isTrue, reason: result.error ?? 'job failed');
    final progressLines = result.logs
        .where((l) => l.contains('"type":"progress"') || l.contains('Progress:'))
        .length;
    expect(progressLines, greaterThan(0),
        reason: 'the job completed but never reported progress — the loop still '
            'exited early and the UI would show nothing');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
