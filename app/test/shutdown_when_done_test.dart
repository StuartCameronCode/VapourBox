// "Shut down computer when the queue finishes" (issue #123).
//
// A shutdown is the one thing VapourBox does that the user cannot undo, so what
// matters most here is when it does NOT happen: a cancelled run, a run the user
// has come back to, a check that failed. All against fakes — nothing here can
// reach a real shutdown.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/models/progress_info.dart';
import 'package:vapourbox/models/queue_item.dart';
import 'package:vapourbox/services/failure_log_writer.dart';
import 'package:vapourbox/services/system_shutdown.dart';
import 'package:vapourbox/services/worker_manager.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

import 'fakes/fake_job_runner.dart';
import 'fakes/fake_system_shutdown.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MainViewModel', () {
    late FakeJobRunner runner;
    late FakeSystemShutdown shutdown;
    late MainViewModel vm;
    late Directory dir;

    Future<void> startQueue(int n) async {
      await vm.addMultipleToQueue([
        for (var i = 0; i < n; i++) '${dir.path}/video_$i.mkv',
      ]);
      for (final item in vm.queue) {
        item.status = QueueItemStatus.ready;
      }
      await vm.startQueueProcessing();
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('vapourbox_shutdown_test');
      runner = FakeJobRunner();
      shutdown = FakeSystemShutdown();
      vm = MainViewModel(runner: runner, systemShutdown: shutdown);
    });

    tearDown(() async {
      vm.dispose();
      await dir.delete(recursive: true);
    });

    List<File> errorLogs() => dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.error.log'))
        .toList();

    test('a shutdown writes each failed video\'s own log beside its output',
        () async {
      await startQueue(2);
      await vm.setShutdownWhenDone(true);
      await runner.emitLog('first video: vspipe exited with signal 4',
          level: LogLevel.error);
      await runner.fail(error: 'Illegal instruction');
      await runner.emitLog('second video: all fine');
      await runner.succeed();

      await vm.shutDownNow();

      final failed = vm.queue.first;
      final logFile = File(FailureLogWriter.logPathFor(failed.outputPath));
      expect(errorLogs().map((f) => f.path), [logFile.path],
          reason: 'only the failed video gets one');
      final text = logFile.readAsStringSync();
      expect(text, contains('Illegal instruction'));
      expect(text, contains('signal 4'));
      expect(text, isNot(contains('second video')),
          reason: 'another video\'s lines would be misleading');
      expect(shutdown.shutDownCount, 1);
    });

    test('no failure log without a shutdown, or without a failure', () async {
      await startQueue(1);
      await vm.setShutdownWhenDone(true);
      await runner.fail();
      vm.cancelShutdown();
      expect(errorLogs(), isEmpty,
          reason: 'a cancelled shutdown means the user is here to read it');

      vm.reset();
      await vm.startQueueProcessing();
      await vm.setShutdownWhenDone(true);
      await runner.succeed();
      await vm.shutDownNow();
      expect(errorLogs(), isEmpty);
    });

    test('arming checks first, and the queue finishing starts a countdown, '
        'not a shutdown', () async {
      await startQueue(1);
      expect(await vm.setShutdownWhenDone(true), isNull);
      expect(shutdown.checkCount, 1);
      expect(vm.shutdownWhenDone, isTrue);

      await runner.succeed();

      expect(vm.shutdownSecondsLeft,
          MainViewModel.shutdownCountdown.inSeconds);
      expect(shutdown.shutDownCount, 0,
          reason: 'the user must get the countdown to stop it');
    });

    test('the countdown ticks down', () async {
      await startQueue(1);
      await vm.setShutdownWhenDone(true);
      await runner.succeed();

      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(vm.shutdownSecondsLeft,
          MainViewModel.shutdownCountdown.inSeconds - 1);
    });

    test('a queue that ends with failures still counts down', () async {
      await startQueue(2);
      await vm.setShutdownWhenDone(true);
      await runner.fail();
      await runner.succeed();

      expect(vm.shutdownSecondsLeft, isNotNull,
          reason: 'an overnight run with one bad file must still shut down');
    });

    test('Cancel Shutdown stops it for good', () async {
      await startQueue(1);
      await vm.setShutdownWhenDone(true);
      await runner.succeed();

      vm.cancelShutdown();
      await vm.shutDownNow();

      expect(vm.shutdownSecondsLeft, isNull);
      expect(shutdown.shutDownCount, 0,
          reason: 'shutDownNow after a cancel has nothing pending to act on');
    });

    test('Shut Down Now shuts down, and a refusal is reported', () async {
      shutdown.shutDownProblem = 'an app has unsaved changes';
      await startQueue(1);
      await vm.setShutdownWhenDone(true);
      await runner.succeed();

      await vm.shutDownNow();

      expect(shutdown.shutDownCount, 1);
      expect(vm.shutdownError, contains('unsaved changes'));
    });

    test('a failed check leaves the option off', () async {
      shutdown.checkProblem = 'not allowed';
      await startQueue(1);

      expect(await vm.setShutdownWhenDone(true), 'not allowed');
      expect(vm.shutdownWhenDone, isFalse);

      await runner.succeed();
      expect(vm.shutdownSecondsLeft, isNull);
    });

    test('cancelling the queue disarms it, so the next run cannot shut down',
        () async {
      await startQueue(1);
      await vm.setShutdownWhenDone(true);

      await vm.cancelProcessing();
      expect(vm.shutdownWhenDone, isFalse);
      expect(vm.shutdownSecondsLeft, isNull);

      await vm.startQueueProcessing();
      await runner.succeed();
      expect(vm.shutdownSecondsLeft, isNull,
          reason: 'the option is invisible while idle, so it must not carry '
              'over to a run the user did not arm');
    });

    test('a finished run disarms it too', () async {
      await startQueue(1);
      await vm.setShutdownWhenDone(true);
      await runner.succeed();
      vm.cancelShutdown();

      expect(vm.shutdownWhenDone, isFalse);
    });

    test('Done cancels a pending shutdown', () async {
      await startQueue(1);
      await vm.setShutdownWhenDone(true);
      await runner.succeed();

      vm.reset();

      expect(vm.shutdownSecondsLeft, isNull);
    });

    test('it cannot be armed while nothing is running', () async {
      expect(await vm.setShutdownWhenDone(true), isNull);
      expect(vm.shutdownWhenDone, isFalse);
      expect(shutdown.checkCount, 0);
    });
  });

  group('FailureLogWriter', () {
    late Directory dir;
    setUp(() async =>
        dir = await Directory.systemTemp.createTemp('vapourbox_failure_log'));
    tearDown(() => dir.delete(recursive: true));

    test('falls back to the source folder when the output folder is unwritable',
        () async {
      final written = await FailureLogWriter.write(
        inputPath: '${dir.path}/clip.mov',
        outputPath: '${dir.path}/missing-folder/clip_processed.mkv',
        errorMessage: 'disk full',
        messages: [LogMessage(level: LogLevel.error, message: 'boom')],
      );
      expect(written, p.join(dir.path, 'clip_processed.error.log'));
      expect(File(written!).readAsStringSync(), contains('[ERROR] boom'));
    });

    test('returns null rather than throwing when nowhere is writable',
        () async {
      final written = await FailureLogWriter.write(
        inputPath: '${dir.path}/nope/clip.mov',
        outputPath: '${dir.path}/nope/clip.mkv',
        errorMessage: null,
        messages: const [],
      );
      expect(written, isNull);
    });
  });

  group('PlatformSystemShutdown', () {
    late List<List<String>> calls;

    PlatformSystemShutdown on(String os,
        {int exitCode = 0, String stdout = '', String stderr = ''}) {
      calls = [];
      return PlatformSystemShutdown(
        operatingSystem: os,
        run: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(0, exitCode, stdout, stderr);
        },
      );
    }

    test('never forces a shutdown', () async {
      for (final os in ['macos', 'windows', 'linux']) {
        await on(os).shutDown();
        expect(calls.single, isNot(contains('/f')), reason: os);
        expect(calls.single, isNot(contains('--force')), reason: os);
      }
    });

    test('Windows uses a zero timeout, since any other implies /f', () async {
      await on('windows').shutDown();
      expect(calls.single, ['shutdown', '/s', '/t', '0']);
    });

    test('Linux never waits on a password prompt', () async {
      await on('linux').shutDown();
      expect(calls.single, contains('--no-ask-password'));
    });

    test('macOS goes through System Events', () async {
      await on('macos').shutDown();
      expect(calls.single.first, 'osascript');
      expect(calls.single.last, contains('System Events'));
    });

    test('macOS explains a denied Automation permission', () async {
      final problem = await on('macos',
              exitCode: 1,
              stderr: 'execution error: Not authorized to send Apple events '
                  'to System Events. (-1743)')
          .check();
      expect(problem, contains('Privacy & Security'));
    });

    test('Linux arms only when logind says yes outright', () async {
      expect(await on('linux', stdout: 's "yes"').check(), isNull);
      expect(await on('linux', stdout: 's "challenge"').check(),
          contains('password'));
      expect(await on('linux', stdout: 's "no"').check(), isNotNull);
      expect(await on('linux', stdout: 's "na"').check(), isNotNull);
    });

    test('a missing tool is reported, not thrown', () async {
      final shutdown = PlatformSystemShutdown(
        operatingSystem: 'linux',
        run: (exe, args) async => throw ProcessException(exe, args, 'nope'),
      );
      expect(await shutdown.check(), contains('systemd-logind'));
      expect(await shutdown.shutDown(), contains('Could not run'));
    });

    test('other platforms are unsupported', () async {
      final shutdown = on('android');
      expect(shutdown.isSupported, isFalse);
      expect(await shutdown.check(), isNotNull);
    });
  });
}
