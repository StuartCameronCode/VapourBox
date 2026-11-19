// The CI crash-report step names vspipe R78's teardown race (task #68) for
// what it is, on both platforms, and names the faulting image of anything
// else (task #72).
//
// The macOS x64 push gate failed a random format-sweep row in about a quarter
// of its runs on deps 1.17.0-rc3 (5 of 20) with "vspipe exited with signal 4 (SIGILL)", which reads like a plugin
// using an instruction the runner lacks. It was the teardown race: vspipe's
// frameDoneCallback signalling a condition variable main had already freed,
// which macOS traps in _os_unfair_lock_unowned_abort (SIGILL); on Linux the
// same race is a SIGSEGV in outputFrame. The fixtures are those crashes as
// CI printed them (Tests/TestResources/crash_reports/README.md).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/worker_harness.dart';

void main() {
  final script = p.join(WorkerHarness.repoRoot, '.github', 'scripts', 'print-crash-reports.py');
  final fixtures = p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'crash_reports');

  // The system Python, as the workflows' crash-report step runs it; the script
  // needs nothing but the standard library.
  final python = Platform.isWindows ? 'python' : 'python3';

  Future<Map<String, List<String>>> classify(List<String> names) async {
    final r = await Process.run(
      python,
      ['-I', script, '--classify', ...names.map((n) => p.join(fixtures, n))],
    );
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    return {
      for (final line in (r.stdout as String).replaceAll('\r\n', '\n').trim().split('\n'))
        p.basename(line.split('\t').first): line.split('\t').sublist(1),
    };
  }

  test('the macOS SIGILL and the Linux SIGSEGV are both the teardown race', () async {
    final out = await classify([
      'macos-x64-vspipe-teardown-sigill.ips',
      'linux-vspipe-teardown-sigsegv.gdb.txt',
    ]);
    expect(out['macos-x64-vspipe-teardown-sigill.ips']![0], 'vspipe-teardown');
    expect(out['macos-x64-vspipe-teardown-sigill.ips']![1], contains('frameDoneCallback'));
    expect(out['linux-vspipe-teardown-sigsegv.gdb.txt']![0], 'vspipe-teardown');
    expect(out['linux-vspipe-teardown-sigsegv.gdb.txt']![1], contains('outputFrame'));
    expect(out['linux-vspipe-teardown-sigsegv.gdb.txt']![1], contains('vpy4_freeScript'),
        reason: "the race's other half: main is freeing the script");
  });

  test('a crash inside a plugin or driver is named by its image, not as the race', () async {
    final out = await classify(['macos-arm64-moltenvk-sigsegv.ips']);
    final verdict = out['macos-arm64-moltenvk-sigsegv.ips']![0];
    expect(verdict, isNot('vspipe-teardown'));
    expect(verdict, 'image:AppleParavirtGPUMetalIOGPUFamily');
  });

  test('an unreadable file is reported, never a failed step', () async {
    final missing = p.join(fixtures, 'does-not-exist.ips');
    final r = await Process.run(python, ['-I', script, '--classify', missing]);
    expect(r.exitCode, 0);
    expect(r.stdout as String, contains('unreadable'));
  });
}
