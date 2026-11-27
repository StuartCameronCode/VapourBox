/// vspipe for tests that run it directly, without the worker (task #124).
///
/// On Windows, Defender's real-time protection sometimes suspends vspipe's
/// last thread in `ExitProcess`. vspipe has finished its work and printed
/// its final line, but the process never ends and its pipes stay open
/// (task #122, docs/reports/task-122-vspipe-exit-hang). The worker guards
/// against this in `worker/src/vspipe_exit.rs`. A test that ran vspipe with
/// `Process.run` waited until package:test's timeout instead: the
/// DCTFilter stress test, 13 vspipes in a row, timed out on about one
/// Windows nightly leg in three.
///
/// [runVspipe] applies the worker's rule. After a final line (R78's `main`
/// prints one just before it returns), vspipe gets the same grace
/// (`VAPOURBOX_VSPIPE_EXIT_GRACE_SECS`, default 30 s, 0 = forever) to exit.
/// After that, [describeHang] records its stacks (cdb on Windows shows the
/// suspended thread) and the process is killed. If it finished cleanly, the
/// run counts as it would have. That is not a retry: the graph ran once,
/// and only the wait for a finished process is bounded.
///
/// Without a final line nothing is assumed. Past [timeout] the process is
/// described and killed, and a [BoundedTimeout] names it, as `runBounded`
/// does. `-i` (info) runs print no final line, so only that limit applies
/// to them.
///
/// The final-line rule is a twin of `vspipe_exit::final_kind`, pinned by
/// `vspipe_process_test.dart` (docs/TWINS.md).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vapourbox/services/process_tree.dart';

import 'bounded_process.dart';

/// The worker's `vspipe_exit::DEFAULT_GRACE`.
const vspipeDefaultExitGrace = Duration(seconds: 30);

/// The worker's `vspipe_exit::GRACE_ENV`.
const vspipeExitGraceEnv = 'VAPOURBOX_VSPIPE_EXIT_GRACE_SECS';

/// How long a killed vspipe may take to be gone (the worker's `KILL_WAIT`).
const _killWait = Duration(seconds: 10);

/// What a final line says.
enum VspipeFinalKind { output, error }

/// The error lines R78's `main` returns 1 after: the worker's
/// `ERROR_PREFIXES`, in the same order.
const vspipeFinalErrorPrefixes = [
  'Script evaluation failed:',
  'Failed to retrieve output node',
  'Cannot output clips with varying dimensions',
  "Error: can't apply selected header type to video",
  "Error: can't apply apply selected header type to audio",
  'Error: can only apply y4m headers to',
  'Error: no y4m identifier exists for current format',
  'Error: fwrite() call failed when writing initial header',
  'Error: failed to write timecodes file header',
  'Error: failed to write JSON file header',
  'Error: failed to finalize JSON file',
  'Error: cannot create valid w64 header',
  'Error: cannot create valid wav header',
  'Failed to initialize VSScript',
  'Failed to get VapourSynth API pointer',
  'Failed to create core',
];

final _outputSummary = RegExp(r'^Output \d+ (frames|samples) in [\d.]+ seconds');

/// [line] of vspipe's stderr is one its `main` prints just before
/// returning: `Output N frames in …`, or one of [vspipeFinalErrorPrefixes].
VspipeFinalKind? vspipeFinalKind(String line) {
  final l = line.replaceAll(RegExp(r'[\r\n]+$'), '');
  if (_outputSummary.hasMatch(l)) return VspipeFinalKind.output;
  return vspipeFinalErrorPrefixes.any(l.startsWith) ? VspipeFinalKind.error : null;
}

/// The grace a vspipe gets after its final line, from [vspipeExitGraceEnv];
/// null waits forever (the variable set to 0).
Duration? vspipeExitGrace([Map<String, String>? environment]) {
  final raw = (environment ?? Platform.environment)[vspipeExitGraceEnv];
  final secs = raw == null ? null : int.tryParse(raw.trim());
  if (secs == null) return vspipeDefaultExitGrace;
  return secs == 0 ? null : Duration(seconds: secs);
}

/// A finished [runVspipe].
class VspipeRun {
  VspipeRun({
    required this.result,
    required this.elapsed,
    this.finalLine,
    this.sawError = false,
    this.exitStuck = false,
    this.hang = '',
  });

  /// As `Process.run` returns it. [ProcessResult.exitCode] is vspipe's own,
  /// or, when [exitStuck], 0 if it [finishedCleanly] and 1 if not.
  final ProcessResult result;

  /// From start until the process was gone (or stopped).
  final Duration elapsed;

  /// The final line vspipe printed, if any.
  final String? finalLine;

  /// An `Error:` line came before the final line: a frame failed, so the
  /// output was not all written, whatever `Output N frames` says.
  final bool sawError;

  /// vspipe printed its final line but had not exited after the grace, and
  /// was stopped (task #122).
  final bool exitStuck;

  /// [describeHang]'s report, taken before a stuck vspipe was killed.
  final String hang;

  /// vspipe's own verdict: an `Output` line and no error before it.
  bool get finishedCleanly =>
      finalLine != null && vspipeFinalKind(finalLine!) == VspipeFinalKind.output && !sawError;

  /// vspipe's `Output N frames in X seconds` line, if it printed one.
  String? get outputSummary =>
      finalLine != null && vspipeFinalKind(finalLine!) == VspipeFinalKind.output
          ? finalLine!.trim()
          : null;
}

/// cdb's `Suspend: N` for the stuck thread, when the stacks show one
/// (non-invasive attach adds 1, so 2 means suspended once).
String _suspendNote(String hang) {
  final m = RegExp(r'Suspend: (\d+)').firstMatch(hang);
  return m == null ? '' : '; cdb: Suspend: ${m.group(1)}';
}

/// Runs vspipe, applying the worker's exit rule (see the library comment).
///
/// [stdin], when given, is written to vspipe's stdin after both output
/// pipes are being read, and never awaited (CLAUDE.md, "Feeding a test
/// clip to vspipe's stdin"). stdout is a [String] (UTF-8) unless
/// [binaryStdout], then a [Uint8List]. [onStderrLine] sees each stderr line
/// as it arrives. [grace] overrides [vspipeExitGrace].
Future<VspipeRun> runVspipe(
  String vspipe,
  List<String> arguments, {
  required String label,
  Map<String, String>? environment,
  Duration timeout = const Duration(minutes: 10),
  List<int>? stdin,
  bool binaryStdout = false,
  Duration? grace,
  void Function(String line)? onStderrLine,
}) async {
  final exitGrace = grace ?? vspipeExitGrace(environment);
  final watch = Stopwatch()..start();
  final process = await Process.start(vspipe, arguments, environment: environment);
  final out = BytesBuilder(copy: false);
  final err = StringBuffer();
  String? finalLine;
  var sawError = false;
  final stuck = Completer<void>();
  Timer? graceTimer;

  final outDone = process.stdout.listen(out.add).asFuture<void>();
  final errDone = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen((line) {
    err.writeln(line);
    onStderrLine?.call(line);
    final kind = vspipeFinalKind(line);
    if (kind == null) {
      if (line.startsWith('Error:')) sawError = true;
      return;
    }
    finalLine = line.trim();
    if (exitGrace != null && graceTimer == null) {
      graceTimer = Timer(exitGrace, () {
        if (!stuck.isCompleted) stuck.complete();
      });
    }
  }).asFuture<void>();

  if (stdin != null) {
    unawaited(() async {
      try {
        process.stdin.add(stdin);
        await process.stdin.close();
      } catch (_) {
        // Broken pipe: vspipe read what it needed and exited.
      }
    }());
  }

  const exited = 0, stopped = 1, timedOut = 2;
  final which = await Future.any<int>([
    process.exitCode.then((_) => exited),
    stuck.future.then((_) => stopped),
    Future<int>.delayed(timeout, () => timedOut),
  ]);
  graceTimer?.cancel();

  Future<void> drain() => Future.wait([outDone, errDone])
      .timeout(const Duration(seconds: 5), onTimeout: () => []);

  Object stdoutOf() {
    final bytes = out.takeBytes();
    return binaryStdout ? bytes : utf8.decode(bytes, allowMalformed: true);
  }

  if (which == exited) {
    final code = await process.exitCode;
    await drain();
    watch.stop();
    return VspipeRun(
      result: ProcessResult(process.pid, code, stdoutOf(), err.toString()),
      elapsed: watch.elapsed,
      finalLine: finalLine,
      sawError: sawError,
    );
  }

  final hang = await describeHang(process.pid);
  await ProcessTree.killTree(process, ProcessSignal.sigkill);
  final gone = await process.exitCode
      .then((_) => true)
      .timeout(_killWait, onTimeout: () => false);
  await drain();
  watch.stop();

  if (which == timedOut) {
    final lines = err.toString().trimRight().split('\n');
    throw BoundedTimeout(
        label,
        timeout,
        [vspipe, ...arguments].join(' '),
        '${gone ? '' : '(the killed process was still there after '
            '${_killWait.inSeconds} s)\n'}$hang',
        lines.sublist(lines.length > 20 ? lines.length - 20 : 0).join('\n'));
  }

  final clean = finalLine != null &&
      vspipeFinalKind(finalLine!) == VspipeFinalKind.output &&
      !sawError;
  final note = '$label: vspipe printed its final line ("$finalLine") but had '
      'not exited after ${exitGrace!.inSeconds} s, so it was stopped (on '
      'Windows, Defender suspends it in ExitProcess: task #122)${_suspendNote(hang)}'
      '${gone ? '' : '; the killed process was still there after ${_killWait.inSeconds} s'}';
  // ignore: avoid_print
  print(note);
  return VspipeRun(
    result: ProcessResult(process.pid, clean && gone ? 0 : 1, stdoutOf(),
        '$err$note\n${clean ? '' : hang}'),
    elapsed: watch.elapsed,
    finalLine: finalLine,
    sawError: sawError,
    exitStuck: true,
    hang: hang,
  );
}
