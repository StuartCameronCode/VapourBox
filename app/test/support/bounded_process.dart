/// Subprocesses with a time limit, for the heavy tests (task #99).
///
/// `Process.run` waits forever. In the output conformance matrix a measuring
/// ffprobe or a hung job ran into the test's own 3-minute timeout, which
/// names nothing, kills nothing, and leaves the stuck process tree running
/// beside the next case. [runBounded] kills the process (and its group) at
/// its limit and throws a [BoundedTimeout] naming the command; before the
/// kill, [describeHang] records where each process of the tree is stuck
/// (macOS `sample`, Linux `gdb` when present), so a hang in CI says which
/// process hung and in what.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vapourbox/services/process_tree.dart';

/// A [runBounded] process that outlived its limit. [hang] is what
/// [describeHang] found before it was killed.
class BoundedTimeout implements Exception {
  BoundedTimeout(this.label, this.limit, this.command, this.hang, [this.stderrTail = '']);

  final String label;
  final Duration limit;
  final String command;
  final String hang;

  /// The last lines the process wrote to stderr before it was killed.
  final String stderrTail;

  @override
  String toString() => '$label: still running after ${limit.inSeconds} s, killed: '
      '$command${stderrTail.isEmpty ? '' : '\nits stderr ended:\n$stderrTail'}'
      '${hang.isEmpty ? '' : '\n$hang'}';
}

/// Runs [executable] like `Process.run`, but kills it after [timeout] and
/// throws a [BoundedTimeout] naming [label] and the command. `stdout` is a
/// [String] (UTF-8) unless [binaryStdout], then a [Uint8List].
///
/// The default limit is generous on purpose: the heavy tests measure small
/// files, so a bounded run only trips on a hang, never on a slow machine.
Future<ProcessResult> runBounded(
  String executable,
  List<String> arguments, {
  required String label,
  Duration timeout = const Duration(seconds: 120),
  Map<String, String>? environment,
  String? workingDirectory,
  bool binaryStdout = false,
}) async {
  final process = await Process.start(executable, arguments,
      environment: environment, workingDirectory: workingDirectory);
  final out = BytesBuilder(copy: false);
  final err = BytesBuilder(copy: false);
  final outDone = process.stdout.listen(out.add).asFuture<void>();
  final errDone = process.stderr.listen(err.add).asFuture<void>();
  final int code;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    final hang = await describeHang(process.pid);
    await ProcessTree.killTree(process, ProcessSignal.sigkill);
    final lines = utf8.decode(err.toBytes(), allowMalformed: true).trimRight().split('\n');
    throw BoundedTimeout(label, timeout, _command(executable, arguments), hang,
        lines.sublist(lines.length > 20 ? lines.length - 20 : 0).join('\n'));
  }
  await Future.wait([outDone, errDone]);
  final stdoutBytes = out.takeBytes();
  return ProcessResult(
    process.pid,
    code,
    binaryStdout ? stdoutBytes : utf8.decode(stdoutBytes, allowMalformed: true),
    utf8.decode(err.takeBytes(), allowMalformed: true),
  );
}

String _command(String exe, List<String> args) =>
    [exe, ...args].map((a) => a.contains(' ') ? "'$a'" : a).join(' ');

/// [pid] and every process under it, as `(pid, command)`, parents first.
/// Empty on Windows (no `ps`).
Future<List<(int, String)>> processTree(int pid) async {
  if (Platform.isWindows) return [];
  final ps = await Process.run('ps', ['-A', '-o', 'pid=,ppid=,command=']);
  if (ps.exitCode != 0) return [];
  final children = <int, List<int>>{};
  final command = <int, String>{};
  for (final line in (ps.stdout as String).split('\n')) {
    final m = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$').firstMatch(line);
    if (m == null) continue;
    final p = int.parse(m.group(1)!), pp = int.parse(m.group(2)!);
    command[p] = m.group(3)!;
    children.putIfAbsent(pp, () => []).add(p);
  }
  if (!command.containsKey(pid)) return [];
  final out = <(int, String)>[];
  final queue = [pid];
  while (queue.isNotEmpty) {
    final p = queue.removeAt(0);
    out.add((p, command[p] ?? '?'));
    queue.addAll(children[p] ?? const []);
  }
  return out;
}

/// Where each process under [pid] is stuck, for a hang's report: the tree
/// (`ps`), then each process's threads' stacks: macOS `sample <pid> 2`,
/// Linux `gdb -batch -ex 'thread apply all bt'` when gdb is installed.
/// Nothing on Windows. Never throws: a report that fails says why.
Future<String> describeHang(int pid,
    {int maxLinesEach = 120,
    Duration budget = const Duration(seconds: 20),
    Duration perProcess = const Duration(seconds: 10)}) async {
  try {
    final tree = await processTree(pid);
    if (tree.isEmpty) return '';
    final b = StringBuffer('process tree at the timeout:\n');
    for (final (p, c) in tree) {
      b.writeln('  $p  ${c.length > 300 ? '${c.substring(0, 300)}…' : c}');
    }
    // The whole report has [budget]: a hung job's is taken inside the 30 s
    // between the job's limit and the case's (conformance_timeouts_test).
    final deadline = DateTime.now().add(budget);
    for (final (p, c) in tree) {
      final name = c.split(' ').first.split('/').last;
      final left = deadline.difference(DateTime.now());
      if (left < const Duration(seconds: 3)) {
        b.writeln('--- $p $name: not sampled (the ${budget.inSeconds} s budget was used) ---');
        continue;
      }
      final List<String> cmd;
      if (Platform.isMacOS) {
        cmd = ['sample', '$p', '2', '-mayDie'];
      } else if (Platform.isLinux) {
        cmd = ['gdb', '-batch', '-p', '$p', '-ex', 'thread apply all bt'];
      } else {
        continue;
      }
      final String text;
      try {
        text = await _runKilledAt(cmd, left < perProcess ? left : perProcess);
      } on ProcessException {
        b.writeln('(no ${cmd.first}: no stacks)');
        break;
      }
      final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      // `sample`'s call graph starts at "Call graph:"; its header is noise.
      final start = lines.indexWhere((l) => l.startsWith('Call graph:'));
      final body = start < 0 ? lines : lines.sublist(start);
      b.writeln('--- $p $name ---');
      b.writeln((body.length > maxLinesEach ? [...body.take(maxLinesEach), '…'] : body)
          .join('\n'));
    }
    return b.toString();
  } catch (e) {
    return '(could not describe the hang: $e)';
  }
}

/// [cmd]'s stdout and stderr, the process killed if it outlives [limit]
/// (a `sample` or `gdb` that hangs must not hold the report).
Future<String> _runKilledAt(List<String> cmd, Duration limit) async {
  final proc = await Process.start(cmd.first, cmd.sublist(1));
  final out = StringBuffer();
  final a = proc.stdout.transform(utf8.decoder).listen(out.write).asFuture<void>();
  final e = proc.stderr.transform(utf8.decoder).listen(out.write).asFuture<void>();
  try {
    await proc.exitCode.timeout(limit);
  } on TimeoutException {
    proc.kill(ProcessSignal.sigkill);
    out.writeln('(${cmd.first} killed after ${limit.inSeconds} s)');
  }
  await Future.wait([a, e]).timeout(const Duration(seconds: 2), onTimeout: () => []);
  return out.toString();
}
