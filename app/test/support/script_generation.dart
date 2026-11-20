// The worker's generated .vpy for a job, without running it: the
// script-only integration tests (integration_filter_parameters_test,
// integration_qtgmc_parameters_test) start a real job and stop it as soon as
// the script is written.
//
// One copy since task #84 (each test file had its own). It polls every 50 ms
// (it was 500 ms: ~80 tests in the pull-request gate waited ~0.25 s each for
// nothing) and stops waiting when the worker exits, so a job the worker
// refuses fails at once instead of after 30 s.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vapourbox/models/video_job.dart';

import 'worker_harness.dart';

Future<String> generateScriptViaWorker(VideoJob job,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final configFile = File('${Directory.systemTemp.path}/vapourbox_job_${job.id}.json');
  await configFile.writeAsString(jsonEncode(job.toJson()));
  final scriptPath = '${Directory.systemTemp.path}/${job.id}.vpy';

  final process = await Process.start(WorkerHarness.workerPath, ['--config', configFile.path],
      environment: WorkerHarness.workerEnv,
      workingDirectory: File(WorkerHarness.workerPath).parent.path);

  final logLines = <String>[];
  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .where((l) => l.trim().isNotEmpty)
      .forEach(logLines.add);
  final stderrDone = process.stderr.drain<void>();
  var exited = false;
  unawaited(process.exitCode.then((_) => exited = true));

  /// The script once written: fs::write creates the file before it fills
  /// it, so take it only when non-empty and unchanged across two reads.
  Future<String?> readScript() async {
    final f = File(scriptPath);
    if (!await f.exists()) return null;
    final a = await f.readAsString();
    if (a.isEmpty) return null;
    await Future.delayed(const Duration(milliseconds: 20));
    final b = await f.readAsString();
    return a == b ? a : null;
  }

  String? script;
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    script = await readScript();
    if (script != null) break;
    if (exited) {
      // It may have written the script just before exiting.
      script = await readScript();
      break;
    }
    await Future.delayed(const Duration(milliseconds: 50));
  }

  process.kill();
  await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
    Process.killPid(process.pid, ProcessSignal.sigkill);
    return -1;
  });
  // The worker's last lines (a refusal says why) arrive after it exits.
  await Future.wait([stdoutDone, stderrDone]).timeout(const Duration(seconds: 5),
      onTimeout: () => const []);
  await configFile.delete().catchError((_) => configFile);
  final sf = File(scriptPath);
  if (await sf.exists()) await sf.delete().catchError((_) => sf);

  if (script == null) {
    throw StateError('Script was not generated at $scriptPath\n'
        'Worker output:\n${logLines.join('\n')}');
  }
  return script;
}
