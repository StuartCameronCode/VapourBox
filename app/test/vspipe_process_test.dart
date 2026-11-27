// Task #124: tests that run vspipe directly go through runVspipe
// (test/support/vspipe_process.dart), which applies the worker's exit rule
// (task #122): a vspipe that printed its final line but does not exit is
// stopped after the grace, and counts as vspipe's final line says.
//
// The final-line rule is a twin of `vspipe_exit::final_kind`; the first
// group pins it to the Rust. The second runs runVspipe against stand-ins
// for vspipe: shell scripts that print a final line and then hold their
// pipes. Not on Windows, for the reason vspipe_exit_guard_test.dart gives
// (a batch file's child keeps the pipes after cmd.exe is killed); the
// nightly's Windows legs run the real thing.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/bounded_process.dart';
import 'support/vspipe_process.dart';

String _repo() => Directory.current.path.endsWith('app')
    ? Directory.current.parent.path
    : Directory.current.path;

void main() {
  group('the final-line rule is the worker\'s', () {
    final rust = File(p.join(_repo(), 'worker', 'src', 'vspipe_exit.rs'))
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

    test('the same error prefixes, in the same order', () {
      final list = RegExp(r'const ERROR_PREFIXES: &\[&str\] = &\[(.*?)\];', dotAll: true)
          .firstMatch(rust);
      expect(list, isNotNull, reason: 'ERROR_PREFIXES not found in vspipe_exit.rs');
      final prefixes = [
        for (final m in RegExp(r'"((?:[^"\\]|\\.)*)"').allMatches(list!.group(1)!))
          m.group(1)!.replaceAll(r'\"', '"'),
      ];
      expect(vspipeFinalErrorPrefixes, prefixes);
    });

    test('the same grace, environment variable and default', () {
      expect(rust, contains('pub const GRACE_ENV: &str = "$vspipeExitGraceEnv";'));
      expect(rust, contains('pub const DEFAULT_GRACE: Duration = '
          'Duration::from_secs(${vspipeDefaultExitGrace.inSeconds});'));
    });

    test('lines classified as the Rust tests classify them', () {
      const output = {
        'Output 1 frames in 0.05 seconds (19.61 fps)',
        'Output 20000 frames in 3.21 seconds (6230.53 fps)\r',
        'Output 48000 samples in 0.10 seconds (480000.00 sps)',
        'Output 5 frames in 1 seconds',
      };
      const neither = {
        'Output frames in 0.05 seconds',
        'Output 1 frames in seconds',
        'Output 1 frames',
        'Frame: 3/20',
        "Error: Failed to retrieve frame 3 with error: boom",
        ' Output 1 frames in 0.05 seconds',
        'Script evaluation failed',
      };
      for (final l in output) {
        expect(vspipeFinalKind(l), VspipeFinalKind.output, reason: l);
      }
      for (final l in neither) {
        expect(vspipeFinalKind(l), isNull, reason: l);
      }
      for (final prefix in vspipeFinalErrorPrefixes) {
        expect(vspipeFinalKind('$prefix and the rest'), VspipeFinalKind.error, reason: prefix);
      }
      // The Rust's own cases, where it lists them.
      for (final m in RegExp(r'final_kind\("((?:[^"\\]|\\.)*)"\),\s*Some\(FinalKind::(Output|Error)\)')
          .allMatches(rust)) {
        final line = m.group(1)!.replaceAll(r'\r', '\r').replaceAll(r'\n', '\n').replaceAll(r'\"', '"');
        expect(vspipeFinalKind(line),
            m.group(2) == 'Output' ? VspipeFinalKind.output : VspipeFinalKind.error,
            reason: line);
      }
      for (final m in RegExp(r'final_kind\("((?:[^"\\]|\\.)*)"\),\s*None').allMatches(rust)) {
        final line = m.group(1)!.replaceAll(r'\"', '"');
        expect(vspipeFinalKind(line), isNull, reason: line);
      }
    });

    test('the grace comes from the environment as the worker reads it', () {
      expect(vspipeExitGrace({}), vspipeDefaultExitGrace);
      expect(vspipeExitGrace({vspipeExitGraceEnv: '5'}), const Duration(seconds: 5));
      expect(vspipeExitGrace({vspipeExitGraceEnv: '0'}), isNull);
      expect(vspipeExitGrace({vspipeExitGraceEnv: 'x'}), vspipeDefaultExitGrace);
    });
  });

  group('runVspipe', () {
    late Directory dir;

    setUpAll(() => dir = Directory.systemTemp.createTempSync('vb_vspipe_process_'));
    tearDownAll(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    // A stand-in vspipe: [body], then (when [hang]) a `sleep` that keeps
    // its stdout and stderr, as a vspipe stuck in ExitProcess does.
    Future<String> standIn(String name, String body, {bool hang = true}) async {
      final f = File(p.join(dir.path, name));
      f.writeAsStringSync('#!/bin/sh\n$body\n${hang ? 'exec sleep 600\n' : ''}');
      await Process.run('chmod', ['+x', f.path]);
      return f.path;
    }

    const grace = Duration(seconds: 2);

    test('a vspipe that finished cleanly but does not exit is stopped and passes',
        () async {
      final exe = await standIn('clean', r'''
printf 'payload'
echo 'Frame: 5/5' >&2
echo 'Output 5 frames in 0.10 seconds (50.00 fps)' >&2''');
      final watch = Stopwatch()..start();
      final run = await runVspipe(exe, [], label: 'clean', grace: grace);
      expect(run.exitStuck, isTrue);
      expect(run.finishedCleanly, isTrue);
      expect(run.result.exitCode, 0);
      expect(run.result.stdout, 'payload');
      expect(run.outputSummary, startsWith('Output 5 frames in'));
      expect(run.result.stderr, contains('task #122'));
      expect(watch.elapsed, greaterThanOrEqualTo(grace));
      expect(watch.elapsed, lessThan(const Duration(seconds: 60)));
    }, skip: Platform.isWindows ? 'see the header' : false);

    test('one whose frame failed before its Output line fails', () async {
      final exe = await standIn('frame-error', r'''
echo 'Error: Failed to retrieve frame 3 with error: boom' >&2
echo 'Output 5 frames in 0.10 seconds (50.00 fps)' >&2''');
      final run = await runVspipe(exe, [], label: 'frame error', grace: grace);
      expect(run.exitStuck, isTrue);
      expect(run.finishedCleanly, isFalse);
      expect(run.result.exitCode, isNot(0));
      expect(run.result.stderr, contains('Failed to retrieve frame 3'));
    }, skip: Platform.isWindows ? 'see the header' : false);

    test('one stuck after a final error line fails', () async {
      final exe = await standIn('script-error', r'''
echo 'Script evaluation failed:' >&2
echo 'Python exception: boom' >&2''');
      final run = await runVspipe(exe, [], label: 'script error', grace: grace);
      expect(run.exitStuck, isTrue);
      expect(run.result.exitCode, isNot(0));
      expect(run.result.stderr, contains('Python exception: boom'));
    }, skip: Platform.isWindows ? 'see the header' : false);

    test('one that never prints a final line is killed at its limit, named',
        () async {
      final exe = await standIn('mid-graph', r'''echo 'Frame: 2/5' >&2''');
      await expectLater(
        runVspipe(exe, [], label: 'mid-graph hang', grace: grace,
            timeout: const Duration(seconds: 4)),
        throwsA(isA<BoundedTimeout>()
            .having((e) => e.label, 'label', 'mid-graph hang')
            .having((e) => e.stderrTail, 'stderr', contains('Frame: 2/5'))),
      );
    }, skip: Platform.isWindows ? 'see the header' : false);

    test('the limit does not cut short the grace after a final line', () async {
      // Finished just inside its limit, then stuck: the #122 case, not a hang.
      final exe = await standIn('late-final', r'''
echo 'Output 5 frames in 0.10 seconds (50.00 fps)' >&2''');
      final run = await runVspipe(exe, [], label: 'late final', grace: grace,
          timeout: const Duration(seconds: 1));
      expect(run.exitStuck, isTrue);
      expect(run.result.exitCode, 0);
    }, skip: Platform.isWindows ? 'see the header' : false);

    test('a vspipe that exits is returned as it exited, stdin fed, stdout binary',
        () async {
      final exe = await standIn('exits', r'''
cat
echo 'Output 1 frames in 0.01 seconds (100.00 fps)' >&2
exit 3''', hang: false);
      final run = await runVspipe(exe, [],
          label: 'exits', grace: grace, stdin: [1, 2, 3], binaryStdout: true);
      expect(run.exitStuck, isFalse);
      expect(run.result.exitCode, 3);
      expect(run.result.stdout, Uint8List.fromList([1, 2, 3]));
    }, skip: Platform.isWindows ? 'see the header' : false);
  });

  test('tests run vspipe through runVspipe, never Process.run (task #124)', () {
    // A Process.run / Process.start whose first argument names vspipe.
    final direct = RegExp(r'Process\.(run|start)\(\s*\w*[vV]spipe\w*\s*,');
    final offenders = <String>[];
    for (final f in Directory(p.join(_repo(), 'app', 'test'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (p.basename(f.path) == 'vspipe_process.dart') continue;
      final text = f.readAsStringSync();
      for (final m in direct.allMatches(text)) {
        final line = '\n'.allMatches(text.substring(0, m.start)).length + 1;
        offenders.add('${p.relative(f.path, from: _repo())}:$line');
      }
    }
    expect(offenders, isEmpty,
        reason: 'use runVspipe (test/support/vspipe_process.dart): a vspipe '
            'Defender suspends in its exit holds Process.run forever (task #122)');
  });
}
