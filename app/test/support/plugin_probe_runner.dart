// Runs Scripts/probe-plugin-formats.py for plugin_format_contracts_test
// (--quick, push gate) and plugin_format_probe_test (full, nightly).
//
// The probe prints one stderr line per call as it finishes (cells, refused,
// seconds); they are printed here as they arrive, so every CI log carries
// per-call timings, passing or not. --budget stops it 90 s before the test's
// own timeout and makes it say which calls were still running and which never
// started (task #75: a timeout used to leave nothing to tell a hang from
// slowness).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'worker_harness.dart';

class ProbeRun {
  ProbeRun(this.exitCode, this.stdout, this.stderr, this.elapsed);

  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration elapsed;

  /// The failure reason: the --check differences, then the probe's log.
  String get report => '$stdout\n$stderr';
}

/// Runs the probe with [args] (plus --ffmpeg and --budget) under the bundle's
/// Python. [timeout] is the calling test's timeout.
Future<ProbeRun> runPluginProbe(List<String> args, {required Duration timeout}) async {
  final budget = timeout - const Duration(seconds: 90);
  final sw = Stopwatch()..start();
  final proc = await Process.start(
    WorkerHarness.pythonPath,
    [
      p.join(WorkerHarness.repoRoot, 'Scripts', 'probe-plugin-formats.py'),
      ...args,
      '--ffmpeg', WorkerHarness.ffmpegPath,
      '--budget', '${budget.inSeconds}',
    ],
    environment: {
      ...WorkerHarness.workerEnv,
      'VAPOURBOX_FFMPEG': WorkerHarness.ffmpegPath,
      'VAPOURBOX_PLATFORM': WorkerHarness.platform,
    },
  );
  final out = StringBuffer();
  final err = StringBuffer();
  final outDone = proc.stdout.transform(utf8.decoder).listen(out.write).asFuture<void>();
  final errDone = proc.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    err.writeln(line);
    // ignore: avoid_print
    print('  probe ${(sw.elapsed.inMilliseconds / 1000).toStringAsFixed(0).padLeft(5)} s | $line');
  }).asFuture<void>();
  // A backstop only: --budget ends the probe first.
  final code = await proc.exitCode.timeout(budget + const Duration(seconds: 45), onTimeout: () {
    proc.kill(ProcessSignal.sigkill);
    err.writeln('killed: the probe outlived its --budget');
    return -1;
  });
  await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 10), onTimeout: () => []);
  // ignore: avoid_print
  print('  probe finished: exit $code after ${sw.elapsed.inSeconds} s');
  return ProbeRun(code, out.toString(), err.toString(), sw.elapsed);
}
