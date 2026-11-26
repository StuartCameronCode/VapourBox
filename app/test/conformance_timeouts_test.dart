/// Time limits in the heavy tests (task #99), checked in the push gate.
///
///  - `runBounded` kills a process at its limit and names it, rather than
///    waiting forever as `Process.run` does.
///  - The output conformance matrix's job limit is below its case limit, so
///    a hung job is killed and reported with where it hung, not cut off by
///    the test's bare TimeoutException.
///  - Each test of `integration_reserved_colour_tags_test.dart` that runs
///    the worker, a detector or ffmpeg states its timeout: on the macOS x64
///    runner `--detect-native` took 23-30 s there and failed 8 nightly legs
///    at package:test's 30 s default. Its per-detect limit fits twice in it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:vapourbox/services/process_tree.dart';

import 'support/bounded_process.dart';

String _read(String name) =>
    File(p.join(Directory.current.path, 'test', name)).readAsStringSync().replaceAll('\r\n', '\n');

Duration _const(String source, String name) {
  final m = RegExp('const $name = (?:Timeout\\()?Duration\\((minutes|seconds): (\\d+)\\)')
      .firstMatch(source);
  expect(m, isNotNull, reason: 'no `const $name = Duration(...)`');
  final n = int.parse(m!.group(2)!);
  return m.group(1) == 'minutes' ? Duration(minutes: n) : Duration(seconds: n);
}

/// Each `test(` in [source] with its body, up to the next top-level `test(`
/// or `group(` at the same indent.
Iterable<(String, String)> _tests(String source) sync* {
  final starts = RegExp(r'^(\s*)test\(\s*(.)(.*?)\2', multiLine: true).allMatches(source).toList();
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1].start : source.length;
    yield (starts[i].group(3)!, source.substring(starts[i].start, end));
  }
}

void main() {
  test('runBounded kills a process at its limit and names it', () async {
    final (exe, args) = Platform.isWindows
        ? ('powershell', ['-NoProfile', '-Command', 'Start-Sleep -Seconds 30'])
        : ('sleep', ['30']);
    final watch = Stopwatch()..start();
    Object? error;
    try {
      await runBounded(exe, args, label: 'a sleep', timeout: const Duration(seconds: 1));
    } catch (e) {
      error = e;
    }
    expect(error, isA<BoundedTimeout>());
    expect('$error', contains('a sleep: still running after 1 s, killed'));
    expect('$error', contains(exe));
    expect(watch.elapsed, lessThan(const Duration(seconds: 25)),
        reason: 'it waited for the process instead of killing it');
  });

  test('runBounded returns what Process.run would', () async {
    final r = Platform.isWindows
        ? await runBounded('cmd', ['/c', 'echo hi'], label: 'echo')
        : await runBounded('sh', ['-c', 'echo hi; echo err >&2; exit 3'], label: 'echo');
    expect('${r.stdout}'.trim(), 'hi');
    if (!Platform.isWindows) {
      expect('${r.stderr}'.trim(), 'err');
      expect(r.exitCode, 3);
    }
  });

  test('describeHang names the tree and keeps to its budget', () async {
    // Windows lists the tree through Win32_Process (task #120); its stacks
    // need the SDK's cdb, which this test doesn't ask for.
    if (Platform.isWindows) {
      final proc = await Process.start(
          'powershell', ['-NoProfile', '-Command', 'Start-Sleep -Seconds 30']);
      try {
        await Future<void>.delayed(const Duration(seconds: 2));
        final report = await describeHang(proc.pid,
            budget: const Duration(seconds: 20), perProcess: const Duration(seconds: 15));
        expect(report, contains('process tree at the timeout'));
        expect(report, contains('Start-Sleep'));
      } finally {
        await ProcessTree.killTree(proc, ProcessSignal.sigkill);
      }
      return;
    }
    final proc = await Process.start('sh', ['-c', 'sleep 30 & sleep 30; wait']);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final watch = Stopwatch()..start();
      final report = await describeHang(proc.pid,
          budget: const Duration(seconds: 6), perProcess: const Duration(seconds: 4));
      expect(report, contains('process tree at the timeout'));
      expect(report, contains('sleep 30'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 15)),
          reason: 'the report outran its budget');
    } finally {
      await Process.run('pkill', ['-P', '${proc.pid}']); // the sleeps, first
      proc.kill(ProcessSignal.sigkill);
    }
  });

  test('a worker run killed at its timeout says where it was stuck (task #120)', () {
    // runJob always did; runPreview (the format sweep's every row) killed a
    // hung preview with nothing to show for it.
    final s = _read(p.join('support', 'worker_harness.dart'));
    expect('describeHang(process.pid)'.allMatches(s).length, greaterThanOrEqualTo(2));
    final preview = s.substring(s.indexOf('static Future<PreviewResult> runPreview('));
    final onTimeout = preview.substring(0, preview.indexOf('ProcessTree.killTree'));
    expect(onTimeout, contains('describeHang(process.pid)'),
        reason: 'runPreview takes the stacks before it kills the tree');
  });

  test('the conformance matrix kills a hung job before the case times out', () {
    final s = _read('integration_output_conformance_test.dart');
    final job = _const(s, 'jobTimeout'), kase = _const(s, 'caseTimeout');
    // The job's limit leaves time to sample the tree and print the evidence.
    expect(job + const Duration(seconds: 20), lessThan(kase));
    expect(s, contains('WorkerHarness.runJob(job, label: c.id, timeout: jobTimeout)'));
    expect(s, contains('timeout: const Timeout(caseTimeout)'));
    expect(s, isNot(contains('Process.run(')),
        reason: 'every subprocess of the matrix is bounded (runBounded)');
  });

  test('every reserved-colour-tags test that runs something states its timeout', () {
    final s = _read('integration_reserved_colour_tags_test.dart');
    final whole = _const(s, '_timeout'), detect = _const(s, '_detectLimit');
    expect(detect * 2, lessThan(whole), reason: 'each test runs two detects');
    var checked = 0;
    for (final (name, body) in _tests(s)) {
      if (!RegExp(r'_detect\(|runJob\(|runPreview\(|_ffmpeg\(').hasMatch(body)) continue;
      checked++;
      expect(body, contains('timeout: _timeout'), reason: '"$name" runs something with the 30 s default');
    }
    expect(checked, greaterThanOrEqualTo(7));
    expect(s, isNot(contains('Process.run(\n      WorkerHarness.workerPath')),
        reason: 'the detectors run bounded');
  });
}
