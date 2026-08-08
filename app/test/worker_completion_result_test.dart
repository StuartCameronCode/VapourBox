// What the worker's exit reports, and why a cancellation must win.
//
// The bug these pin was invisible from inside the app: every value was
// plausible, nothing threw, and the only symptom was the queue behaving as
// though a cancelled job had failed — marking the item failed, starting the next
// job, and leaving the UI on "processing" with a spinner and no progress.
//
// Two earlier attempts missed it. The first reasoned about process teardown and
// never touched the reporting. The second put `cancelled: _cancelRequested` in a
// `??` fallback behind `_pendingCompletion` — which the worker always sets,
// because it sends `complete(false)` on its way out of a cancellation too. So
// the flag was unreachable and the behaviour was unchanged.
//
// Hence a direct test of the decision rather than a scan of the source: the
// previous tests read the file, passed, and the bug shipped anyway.

import 'package:test/test.dart';
import 'package:vapourbox/services/worker_manager.dart';

void main() {
  group('completionFor', () {
    test('a cancelled job reports cancelled even though the worker sent complete',
        () {
      // Exactly the shipped case: SIGTERM, the worker emits complete(false) on
      // its way out, and _handleStdoutLine builds it with no cancelled flag.
      const pending = CompletionResult(success: false, errorMessage: 'whatever');

      final result = WorkerManager.completionFor(
        cancelRequested: true,
        pending: pending,
        lastError: null,
        exitCode: 130,
      );

      expect(result.cancelled, isTrue,
          reason: 'the queue stops only on cancelled; reported as a plain '
              'failure it marks the item failed and starts the next job');
      expect(result.success, isFalse);
    });

    test('a cancelled job reports cancelled when the worker sent nothing', () {
      final result = WorkerManager.completionFor(
        cancelRequested: true,
        pending: null,
        lastError: null,
        exitCode: 143,
      );
      expect(result.cancelled, isTrue);
    });

    test('a successful job is reported from the worker, untouched', () {
      const pending = CompletionResult(success: true, outputPath: '/tmp/out.mkv');
      final result = WorkerManager.completionFor(
        cancelRequested: false,
        pending: pending,
        lastError: null,
        exitCode: 0,
      );
      expect(result.success, isTrue);
      expect(result.cancelled, isFalse);
      expect(result.outputPath, '/tmp/out.mkv');
    });

    test('a genuine failure stays a failure, not a cancellation', () {
      const pending = CompletionResult(success: false, errorMessage: 'ffmpeg died');
      final result = WorkerManager.completionFor(
        cancelRequested: false,
        pending: pending,
        lastError: 'ffmpeg died',
        exitCode: 1,
      );
      expect(result.cancelled, isFalse,
          reason: 'a crash must not be swallowed as a cancellation — the queue '
              'would stop silently instead of recording the failure');
      expect(result.errorMessage, 'ffmpeg died');
    });

    test('an exit with no report at all is still reported', () {
      // The hang from #50: without this the UI waits forever on a dead worker.
      final result = WorkerManager.completionFor(
        cancelRequested: false,
        pending: null,
        lastError: null,
        exitCode: 3,
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('3'));
    });

    test('a clean exit with no report is distinguished from a crash', () {
      final result = WorkerManager.completionFor(
        cancelRequested: false,
        pending: null,
        lastError: null,
        exitCode: 0,
      );
      expect(result.errorMessage, contains('without reporting'));
    });
  });
}
