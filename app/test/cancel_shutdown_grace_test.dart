// The cancel grace period and the worker's cancellation poll interval are a
// cross-file coupling, and getting it wrong is silent.
//
// SIGTERM does not tear the pipeline down by itself: the worker's signal handler
// only sets an atomic flag, and the actual teardown (killing vspipe and ffmpeg,
// then reaping them) happens the next time the progress loop comes round —
// `progress_interval` later, at most.
//
// The app used to wait exactly 500ms before SIGKILL, which is precisely that
// poll interval, so the worker essentially never reached the check in time.
// SIGKILL cannot be caught, so `PipelineExecutor::terminate()` and its `Drop`
// never ran and vspipe/ffmpeg were reparented to init — left encoding a job the
// user had cancelled, still writing to the output file, while the UI reported
// "Job cancelled by user". Observed in the wild: three orphaned processes at
// ~670% CPU eleven minutes after the cancel, output past 320MB.
//
// Nothing else catches this. The app reports a successful cancellation either
// way, so the bug is invisible from inside the app — you have to look at the
// process table. Hence a direct assertion that the two values stay in step.
//
// This is the same class of guard as `test_native_formats_match_pipe_source`
// (Rust `NATIVE_FORMATS` vs Python `_FORMAT_MAP`).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory(p.join(dir.path, 'worker')).existsSync() &&
        Directory(p.join(dir.path, 'app')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not locate the repo root from ${Directory.current}');
    }
    dir = parent;
  }
}

void main() {
  group('cancel shutdown grace', () {
    late String root;

    setUpAll(() => root = _repoRoot());

    test('the app gives the worker longer than its cancellation poll interval',
        () {
      final rs = File(p.join(root, 'worker', 'src', 'pipeline_executor.rs'))
          .readAsStringSync();
      final dart = File(p.join(
              root, 'app', 'lib', 'services', 'worker_manager.dart'))
          .readAsStringSync();

      final pollMatch = RegExp(
        r'let\s+progress_interval\s*=\s*Duration::from_millis\((\d+)\)',
      ).firstMatch(rs);
      expect(pollMatch, isNotNull,
          reason: 'could not find progress_interval in pipeline_executor.rs — '
              'if it was renamed, update this test rather than deleting it');
      final pollMs = int.parse(pollMatch!.group(1)!);

      final graceMatch = RegExp(
        r'_shutdownGrace\s*=\s*Duration\(seconds:\s*(\d+)\)',
      ).firstMatch(dart);
      expect(graceMatch, isNotNull,
          reason: 'could not find _shutdownGrace in worker_manager.dart');
      final graceMs = int.parse(graceMatch!.group(1)!) * 1000;

      // The worker needs at least one full poll to notice the flag, then has to
      // kill three children and reap them. A grace equal to (or barely above)
      // the poll interval is the bug this test exists for, so require real
      // headroom rather than a strict >.
      expect(
        graceMs,
        greaterThanOrEqualTo(pollMs * 4),
        reason: 'the cancel grace ($graceMs ms) must comfortably exceed the '
            "worker's $pollMs ms cancellation poll, or SIGKILL wins the race "
            'and vspipe/ffmpeg are orphaned mid-encode',
      );
    });

    test('cancel waits for the process to exit instead of sleeping', () {
      final dart = File(p.join(
              root, 'app', 'lib', 'services', 'worker_manager.dart'))
          .readAsStringSync();
      final cancelStart = dart.indexOf('Future<void> cancel()');
      expect(cancelStart, greaterThan(-1));
      // Read the whole method, not up to the first `_cleanup()`. cancel() now
      // has an early branch for "nothing to kill" which cleans up before the
      // await, so anchoring on the first occurrence pointed at that instead —
      // a false failure with the behaviour perfectly correct.
      final body =
          dart.substring(cancelStart, dart.indexOf('\n  }\n', cancelStart));

      // It must observe the exit, not assume it after a fixed delay.
      expect(body, contains('exitCode'),
          reason: 'cancel() must await the process exit; a fixed delay is what '
              'orphaned the pipeline');
      expect(body.contains('Future.delayed'), isFalse,
          reason: 'cancel() must not gate the force-kill on a fixed delay — '
              'wait on exitCode with a timeout instead');
    });
  });
}
