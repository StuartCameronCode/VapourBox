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
  BoundedTimeout(this.label, this.limit, this.command, this.hang);

  final String label;
  final Duration limit;
  final String command;
  final String hang;

  @override
  String toString() => '$label: still running after ${limit.inSeconds} s, killed: '
      '$command${hang.isEmpty ? '' : '\n$hang'}';
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
  bool binaryStdout = false,
}) async {
  final process = await Process.start(executable, arguments, environment: environment);
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
    throw BoundedTimeout(label, timeout, _command(executable, arguments), hang);
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
Future<String> describeHang(int pid, {int maxLinesEach = 120}) async {
  try {
    final tree = await processTree(pid);
    if (tree.isEmpty) return '';
    final b = StringBuffer('process tree at the timeout:\n');
    for (final (p, c) in tree) {
      b.writeln('  $p  ${c.length > 300 ? '${c.substring(0, 300)}…' : c}');
    }
    for (final (p, c) in tree) {
      final name = c.split(' ').first.split('/').last;
      ProcessResult? r;
      if (Platform.isMacOS) {
        r = await Process.run('sample', ['$p', '2', '-mayDie'])
            .timeout(const Duration(seconds: 30));
      } else if (Platform.isLinux) {
        try {
          r = await Process.run('gdb', ['-batch', '-p', '$p', '-ex', 'thread apply all bt'])
              .timeout(const Duration(seconds: 60));
        } on ProcessException {
          b.writeln('(no gdb: no stacks)');
          break;
        }
      }
      if (r == null) continue;
      final lines = '${r.stdout}${r.stderr}'.split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
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
