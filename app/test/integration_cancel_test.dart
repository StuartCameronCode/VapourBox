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
// Two of these tests are POSIX only and say so where they are skipped: SIGTERM
// semantics and process-group leadership have no Windows equivalent. The orphan
// checks DO run on Windows, where the tree is killed with `taskkill /T` — they
// have to, because that is the platform whose teardown had no coverage at all,
// and the one where preview cancellation was leaking vspipe and ffmpeg.
@Tags(['heavy'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/services/process_tree.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

/// Every path a deps binary can legitimately be executed from.
///
/// The prefix match below has to allow for the deps directory being reached by
/// more than one name. On Linux the worker does not search upward from the
/// executable at all (`dependency_locator.rs`, which restricts that to
/// non-Linux debug builds), so it resolves deps through
/// `$XDG_DATA_HOME`/`~/.local/share/VapourBox/deps` — which CI *symlinks* to the
/// checkout. `ps` then reports the symlinked path while the test holds the
/// workspace one, they share no prefix, and the child count comes back zero:
/// the test fails claiming the pipeline never started when it started fine.
List<String> _depsRoots(String dir) {
  final roots = <String>{dir};

  try {
    roots.add(Directory(dir).resolveSymbolicLinksSync());
  } on FileSystemException {
    // Not resolvable — the literal path is still worth matching.
  }

  // The Linux production location, with the platform suffix carried over.
  final platform = p.basename(dir);
  final xdg = Platform.environment['XDG_DATA_HOME'];
  final home = Platform.environment['HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    roots.add(p.join(xdg, 'VapourBox', 'deps', platform));
  } else if (home != null && home.isNotEmpty) {
    roots.add(p.join(home, '.local', 'share', 'VapourBox', 'deps', platform));
  }

  return roots.toList();
}

/// PIDs of live processes whose executable path sits under [dir].
///
/// Cross-platform: `ps` reports the command line on Unix, and `Get-CimInstance
/// Win32_Process` the executable path on Windows, where `ps` does not exist at
/// all — which used to make every orphan assertion here unrunnable on the one
/// platform whose teardown path was untested.
Future<List<int>> _processesUnder(String dir) async {
  final roots = _depsRoots(dir);
  bool underDeps(String command) => roots.any(command.startsWith);

  final out = <int>[];

  if (Platform.isWindows) {
    final ps = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r'Get-CimInstance Win32_Process | ForEach-Object '
          r'{ "$($_.ProcessId)`t$($_.ExecutablePath)" }',
    ]);
    for (final line in const LineSplitter().convert(ps.stdout.toString())) {
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final pid = int.tryParse(line.substring(0, tab).trim());
      if (pid == null) continue;
      // Win32 reports a backslash path; the deps roots use whatever separator
      // the harness built them with, so compare on one form.
      final exe = line.substring(tab + 1).trim().replaceAll(r'\', '/');
      if (exe.isEmpty) continue;
      if (underDeps(exe) || roots.any((r) => exe.startsWith(r.replaceAll(r'\', '/')))) {
        out.add(pid);
      }
    }
    return out;
  }

  final ps = await Process.run('ps', ['-Ao', 'pid=,command=']);
  for (final line in const LineSplitter().convert(ps.stdout.toString())) {
    final trimmed = line.trimLeft();
    final sp = trimmed.indexOf(' ');
    if (sp <= 0) continue;
    final pid = int.tryParse(trimmed.substring(0, sp));
    if (pid == null) continue;
    final cmd = trimmed.substring(sp + 1);
    // Match only the executable path, not an argument that happens to name the
    // deps dir (the job config and output paths can both mention it).
    if (underDeps(cmd)) out.add(pid);
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

    test('SIGTERM stops the worker and leaves no orphaned children', skip: Platform.isWindows
        ? 'POSIX only: Windows has no SIGTERM, and Process.kill maps to '
            'TerminateProcess. The app kills the tree with taskkill /T there, '
            'which the preview-orphan test below covers.'
        : null, () async {
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

    test('the worker leads its own process group, so the tree can be signalled',
        skip: Platform.isWindows
            ? 'POSIX only: Windows has no process groups. The equivalent there '
                'is taskkill /T walking the child tree, asserted by the '
                'orphan tests rather than by a pgid.'
            : null, () async {
      // ProcessTree.killTree() signals -pid, which only reaches the pipeline if
      // the worker made itself a group leader (setpgid in worker/src/main.rs).
      // If that call is ever removed the kill silently degrades to pid-only and
      // strays come back — with no visible symptom until a source is slow
      // enough that the children do not happen to die on EPIPE.
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: longInput,
        outputPath: p.join(WorkerHarness.outputDir, 'unused_group.mkv'),
        processingPipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
              enabled: true, preset: QTGMCPreset.slower, tff: true),
        ),
        encodingSettings: const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.passthrough),
      );
      final cfg = File(p.join(Directory.systemTemp.path, 'vb_group.json'));
      await cfg.writeAsString(jsonEncode(job.toJson()));
      addTearDown(() async {
        if (await cfg.exists()) await cfg.delete();
      });

      final proc = await Process.start(
        WorkerHarness.workerPath,
        ['--config', cfg.path],
        environment: WorkerHarness.workerEnv,
        workingDirectory: File(WorkerHarness.workerPath).parent.path,
      );
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();

      var pgid = '';
      var kids = <String>[];
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final pg =
            await Process.run('ps', ['-o', 'pgid=', '-p', '${proc.pid}']);
        pgid = pg.stdout.toString().trim();
        if (pgid != '${proc.pid}') continue;
        final r = await Process.run('pgrep', ['-g', '${proc.pid}']);
        kids = r.stdout
            .toString()
            .trim()
            .split('\n')
            .where((s) => s.isNotEmpty && s != '${proc.pid}')
            .toList();
        if (kids.isNotEmpty) break;
      }

      expect(pgid, '${proc.pid}',
          reason: 'the worker is not its own process-group leader, so '
              'ProcessTree.killTree() cannot reach vspipe/ffmpeg');
      expect(kids, isNotEmpty,
          reason: 'no children joined the group — nothing to prove');

      // Stop them first: a child that dies on EPIPE would pass regardless, and
      // that incidental cascade is precisely what must not be relied on.
      for (final k in kids) {
        Process.killPid(int.parse(k), ProcessSignal.sigstop);
      }
      expect(Process.killPid(-proc.pid, ProcessSignal.sigterm), isTrue,
          reason: 'a negative pid must reach the group');
      await Future<void>.delayed(const Duration(seconds: 1));
      for (final k in kids) {
        Process.killPid(int.parse(k), ProcessSignal.sigcont);
      }

      var alive = <String>[];
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        alive = [];
        for (final k in kids) {
          final r = await Process.run('ps', ['-o', 'pid=', '-p', k]);
          if (r.stdout.toString().trim().isNotEmpty) alive.add(k);
        }
        if (alive.isEmpty) break;
      }
      for (final k in alive) {
        Process.killPid(int.parse(k), ProcessSignal.sigkill);
      }
      expect(alive, isEmpty,
          reason: 'the group signal did not reach the children even though they '
              'were stopped and so could not have died on EPIPE');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('rapid seeks leave nothing behind', () async {
      // Scrubbing spawns a preview per movement and cancels the previous one.
      // The old code tracked a single _previewProcess assigned *after* await
      // Process.start returned, so a seek arriving in that window cancelled the
      // wrong reference and the in-flight worker was lost — untracked and never
      // killed. Ten seeks in quick succession is the shape that produced "a
      // bunch of vspipe and ffmpeg processes".
      final depsDir = WorkerHarness.depsDir;
      final before = await _processesUnder(depsDir);

      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: longInput,
        outputPath: p.join(WorkerHarness.outputDir, 'unused_seek.mkv'),
        processingPipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
              enabled: true, preset: QTGMCPreset.slower, tff: true),
        ),
        encodingSettings: const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.passthrough),
      );
      final cfg = File(p.join(Directory.systemTemp.path, 'vb_seek.json'));
      await cfg.writeAsString(jsonEncode(job.toJson()));
      addTearDown(() async {
        if (await cfg.exists()) await cfg.delete();
      });

      // Mimic the scrubber: start a preview, and before it can finish, start
      // the next one and tear the previous down the way the app now does.
      final started = <Process>[];
      Process? current;
      for (var i = 0; i < 10; i++) {
        if (current != null) {
          await ProcessTree.killTree(current);
          unawaited(ProcessTree.waitForExit(current));
        }
        current = await Process.start(
          WorkerHarness.workerPath,
          ['--config', cfg.path, '--preview', '--frame', '${300 + i * 40}'],
          environment: WorkerHarness.workerEnv,
          workingDirectory: File(WorkerHarness.workerPath).parent.path,
        );
        current.stdout.drain<void>();
        current.stderr.drain<void>();
        started.add(current);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await ProcessTree.killTree(current!);
      await ProcessTree.waitForExit(current);

      // Everything the burst spawned must be gone.
      var strays = <int>[];
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        strays = (await _processesUnder(depsDir))
            .where((pid) => !before.contains(pid))
            .toList();
        if (strays.isEmpty) break;
      }
      for (final pid in strays) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
      expect(strays, isEmpty,
          reason: '${strays.length} worker/vspipe/ffmpeg processes survived a '
              'burst of ${started.length} seeks');
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('killing a preview leaves no orphaned children', () async {
      // Seeking the preview scrubber cancels the in-flight preview and starts
      // another, so this path runs far more often than a job cancel does.
      final depsDir = WorkerHarness.depsDir;
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: longInput,
        outputPath: p.join(WorkerHarness.outputDir, 'unused_preview.mkv'),
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
          File(p.join(Directory.systemTemp.path, 'vb_preview_orphans.json'));
      await configFile.writeAsString(jsonEncode(job.toJson()));
      addTearDown(() async {
        if (await configFile.exists()) await configFile.delete();
      });

      final before = await _processesUnder(depsDir);

      final proc = await Process.start(
        WorkerHarness.workerPath,
        ['--config', configFile.path, '--preview', '--frame', '900'],
        environment: WorkerHarness.workerEnv,
        workingDirectory: File(WorkerHarness.workerPath).parent.path,
      );
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();

      var spawned = <int>[];
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        spawned = (await _processesUnder(depsDir))
            .where((pid) => !before.contains(pid))
            .toList();
        if (spawned.length >= 2) break;
      }
      expect(spawned.length, greaterThanOrEqualTo(2),
          reason: 'the preview pipeline never started, so this proves nothing');

      // Exactly what PreviewGenerator.cancelPreviewGeneration() does — which is
      // killTree, not proc.kill(). This line used to claim the former while
      // doing the latter, and that gap is the whole reason the Windows preview
      // leak survived: leader-only kills happen to work on Unix (the children
      // take EPIPE) so the test passed, while on Windows nothing reached the
      // children and no assertion here could tell.
      await ProcessTree.killTree(proc);
      await proc.exitCode.timeout(const Duration(seconds: 15),
          onTimeout: () { proc.kill(ProcessSignal.sigkill); return -1; });

      List<int> leftovers = [];
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final now = await _processesUnder(depsDir);
        leftovers = spawned.where(now.contains).toList();
        if (leftovers.isEmpty) break;
      }
      if (leftovers.isNotEmpty) {
        for (final pid in leftovers) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      }
      expect(leftovers, isEmpty,
          reason: 'vspipe/ffmpeg outlived the preview worker. Seeking the '
              'scrubber cancels a preview on every move, so these accumulate');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
