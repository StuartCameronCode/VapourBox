// The worker must shut its pipeline down on SIGTERM, and do it quickly.
//
// `WorkerManager.cancel()` sends SIGTERM and then waits for the worker to exit
// rather than forcing it after a fixed delay. That is only correct if the worker
// really does tear down vspipe and ffmpeg and exit well inside the grace period,
// so this test pins that contract: SIGTERM a running job, then assert it exits
// in under `WorkerManager._shutdownGrace` with none of its children left behind.
//
// What this test does NOT do — and it is worth being exact, because the comment
// it replaced claimed otherwise — is reproduce the orphaning bug itself. Killing
// the worker with SIGKILL here still leaves no survivors: the children's stderr
// pipes close with it and they die on EPIPE the next time they write. The
// reported incident escaped that because the job was reading a large file off a
// NAS, so the children sat blocked on I/O for minutes without writing anything,
// long enough to be noticed at ~670% CPU.
//
// So the regression guard for the fix itself is `cancel_shutdown_grace_test`,
// which fails against the old code. This test guards the assumption that fix
// rests on. Do not weaken it into a "cancel returns without error" check.
//
// POSIX only — Windows has no SIGTERM, and the app uses `taskkill /T` there,
// which kills the tree outright.
@Tags(['heavy'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

/// PIDs of live processes whose executable path sits under [dir].
Future<List<int>> _processesUnder(String dir) async {
  final ps = await Process.run('ps', ['-Ao', 'pid=,command=']);
  final out = <int>[];
  for (final line in const LineSplitter().convert(ps.stdout.toString())) {
    final trimmed = line.trimLeft();
    final sp = trimmed.indexOf(' ');
    if (sp <= 0) continue;
    final pid = int.tryParse(trimmed.substring(0, sp));
    if (pid == null) continue;
    final cmd = trimmed.substring(sp + 1);
    // Match only the executable path, not an argument that happens to name the
    // deps dir (the job config and output paths can both mention it).
    if (cmd.startsWith(dir)) out.add(pid);
  }
  return out;
}

void main() {
  group('cancelling a job', () {
    late String longInput;

    setUpAll(() async {
      await WorkerHarness.ensureReady();
      await Directory(WorkerHarness.outputDir).create(recursive: true);

      // The committed fixtures are only a few seconds long — short enough that
      // QTGMC can finish before the cancel lands, which would satisfy every
      // assertion below for the wrong reason. Build a source with minutes of
      // work left in it, so the `exitCode != 0` guard genuinely means "still
      // encoding when we cancelled it".
      longInput = p.join(WorkerHarness.outputDir, 'cancel_long_source.avi');
      if (!File(longInput).existsSync()) {
        final gen = await Process.run(WorkerHarness.ffmpegPath, [
          '-f', 'lavfi',
          '-i', 'testsrc2=duration=60:size=720x576:rate=25',
          '-vf', 'interlace',
          '-c:v', 'ffv1', '-flags', '+ilme+ildct',
          '-y', longInput,
        ]);
        expect(gen.exitCode, 0, reason: 'could not build the test source: ${gen.stderr}');
      }
    });

    test('SIGTERM stops the worker and leaves no orphaned children', () async {
      final depsDir = WorkerHarness.depsDir;
      final outPath =
          p.join(WorkerHarness.outputDir, 'test_cancel_orphans.mkv');

      // A deliberately slow preset on a long source, so there is plenty of work
      // outstanding at the moment we cancel.
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: longInput,
        outputPath: outPath,
        processingPipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
            enabled: true,
            preset: QTGMCPreset.slower,
            tff: true,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.h264,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.passthrough,
        ),
      );

      final configFile =
          File(p.join(Directory.systemTemp.path, 'vb_cancel_orphans.json'));
      await configFile.writeAsString(jsonEncode(job.toJson()));
      addTearDown(() async {
        if (await configFile.exists()) await configFile.delete();
        final o = File(outPath);
        if (await o.exists()) await o.delete();
      });

      final before = await _processesUnder(depsDir);

      final proc = await Process.start(
        WorkerHarness.workerPath,
        ['--config', configFile.path],
        environment: WorkerHarness.workerEnv,
        workingDirectory: File(WorkerHarness.workerPath).parent.path,
      );
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();

      // Wait until the pipeline is genuinely up, so we are not cancelling before
      // any children exist — that would pass trivially.
      var spawned = <int>[];
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        spawned = (await _processesUnder(depsDir))
            .where((pid) => !before.contains(pid))
            .toList();
        if (spawned.length >= 2) break; // vspipe + at least one ffmpeg
      }
      expect(spawned.length, greaterThanOrEqualTo(2),
          reason: 'the pipeline never started, so this would prove nothing');

      // The app's cancel: SIGTERM, then wait for a real exit.
      final sw = Stopwatch()..start();
      proc.kill(ProcessSignal.sigterm);
      final code = await proc.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      sw.stop();

      expect(code, isNot(-1),
          reason: 'the worker ignored SIGTERM entirely');
      // If the encode had simply finished, there would be nothing left to
      // orphan and the check below would pass for the wrong reason. A cancelled
      // worker exits 130 (or dies by signal); a completed one exits 0.
      expect(code, isNot(0),
          reason: 'the job completed before the cancel landed, so this run '
              'proves nothing about orphaned children — lengthen the source');

      // Children are reaped by the worker as it goes down; allow a moment for
      // the process table to settle.
      List<int> leftovers = [];
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final now = await _processesUnder(depsDir);
        leftovers = spawned.where(now.contains).toList();
        if (leftovers.isEmpty) break;
      }

      // If this fails, kill them — a failing test must not leave the machine
      // pinned at full CPU, which is the very problem under test.
      if (leftovers.isNotEmpty) {
        for (final pid in leftovers) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      }

      expect(leftovers, isEmpty,
          reason: 'vspipe/ffmpeg outlived a SIGTERMed worker; cancel() relies '
              'on the worker reaping them, so this breaks the fix');

      // The worker should go down well inside the app's 5s grace.
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'worker took ${sw.elapsed.inMilliseconds}ms to shut down, '
              'which does not fit inside WorkerManager._shutdownGrace');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
