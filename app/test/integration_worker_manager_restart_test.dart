// WorkerManager must keep delivering progress after a cancel and restart.
//
// The viewmodel is exonerated for this: driven against a fake runner it relays
// progress perfectly across a cancel and a restart
// (`main_viewmodel_lifecycle_test`). The reported symptom — the second job runs
// but the UI never updates — therefore lives in WorkerManager's real process and
// stdout handling, which until now had no test at all, for the same structural
// reason the viewmodel had none: it could not be constructed with a reachable
// worker binary.
//
// Needs the real worker and deps, so it is heavy.
@Tags(['heavy'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/progress_info.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/tool_locator.dart';
import 'package:vapourbox/services/worker_manager.dart';

import 'support/worker_harness.dart';

void main() {
  late String longInput;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(WorkerHarness.outputDir).create(recursive: true);

    // ToolLocator resolves relative to the executable, which under `flutter
    // test` is the test runner. Point it at the real deps and worker.
    // (Set before initialize(); the values are cached.)
    longInput = p.join(WorkerHarness.outputDir, 'cancel_long_source.avi');
    if (!File(longInput).existsSync()) {
      final gen = await Process.run(WorkerHarness.ffmpegPath, [
        '-f', 'lavfi',
        '-i', 'testsrc2=duration=60:size=720x576:rate=25',
        '-vf', 'interlace',
        '-c:v', 'ffv1', '-flags', '+ilme+ildct',
        '-y', longInput,
      ]);
      expect(gen.exitCode, 0, reason: 'could not build the source: ${gen.stderr}');
    }
    await ToolLocator.instance.initialize();
  });

  VideoJob jobFor(String name) => VideoJob(
        id: const Uuid().v4(),
        inputPath: longInput,
        outputPath: p.join(WorkerHarness.outputDir, '$name.mkv'),
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

  /// Wait for [n] progress events, or give up.
  Future<List<ProgressInfo>> collectProgress(
    Stream<ProgressInfo> stream, {
    int n = 1,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final seen = <ProgressInfo>[];
    final done = Completer<void>();
    final sub = stream.listen((e) {
      seen.add(e);
      if (seen.length >= n && !done.isCompleted) done.complete();
    });
    await done.future.timeout(timeout, onTimeout: () {});
    await sub.cancel();
    return seen;
  }

  test('a restart that lands while cancel is still in flight still reports',
      () async {
    // The UI does not await cancelProcessing() (progress_panel.dart:440), so a
    // user who cancels and immediately starts again races the cancel. That path
    // is not covered by the awaited version below, and it is the one where
    // startJob can find _process still set and throw "Worker is already
    // running" — which surfaces as a job that never starts and a UI that never
    // updates.
    final wm = WorkerManager();
    addTearDown(wm.dispose);

    await wm.startJob(jobFor('inflight_first'));
    await collectProgress(wm.progressStream, n: 1);

    // Fire and forget, exactly as the button does.
    final cancelFuture = wm.cancel();

    // Restart as soon as the manager says it is free, without awaiting cancel.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (wm.isRunning && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    Object? startError;
    try {
      await wm.startJob(jobFor('inflight_second'));
    } catch (e) {
      startError = e;
    }
    expect(startError, isNull,
        reason: 'restarting while the cancel was still settling threw: '
            '$startError — the job never starts and the UI never updates');

    final progress = await collectProgress(wm.progressStream, n: 2);
    expect(progress, isNotEmpty,
        reason: 'the restarted job produced no progress');

    await cancelFuture;
    await wm.cancel();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('progress still flows after a cancel and a restart', () async {
    expect(ToolLocator.instance.workerPath, isNotNull,
        reason: 'set VAPOURBOX_WORKER (and VAPOURBOX_DEPS_DIR) for this test');

    final wm = WorkerManager();
    addTearDown(wm.dispose);

    // --- first job: prove progress flows at all ---
    final first = collectProgress(wm.progressStream, n: 2);
    await wm.startJob(jobFor('restart_first'));
    final firstProgress = await first;
    expect(firstProgress, isNotEmpty,
        reason: 'no progress from the first job — the harness itself is wrong');

    // --- cancel ---
    final cancelled = wm.completionStream.first;
    await wm.cancel();
    final result = await cancelled.timeout(const Duration(seconds: 20));
    expect(result.cancelled, isTrue, reason: 'a cancel must report as cancelled');
    expect(wm.isRunning, isFalse, reason: 'cancel must leave nothing running');

    // --- restart: this is the reported bug ---
    final second = collectProgress(wm.progressStream, n: 2);
    await wm.startJob(jobFor('restart_second'));
    final secondProgress = await second;

    expect(secondProgress, isNotEmpty,
        reason: 'the second job produced no progress events. The job runs, but '
            'nothing reaches the UI — the stdout subscription is not feeding '
            'the progress stream after a cancel.');

    await wm.cancel();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
