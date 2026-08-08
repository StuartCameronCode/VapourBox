// Cancelling must not tear down the job that replaced it.
//
// `cancel()` waits for the worker to genuinely exit, which can take seconds.
// Cancelling emits a completion, the queue acts on that by starting the next
// job, and the tail of the *cancelling* call then ran `_cleanup()` — nulling
// `_process` and cancelling the new job's stdout subscription. The new job ran
// to completion with nobody listening, so the progress dialog span forever with
// no updates. The same applies to the previous job's `exitCode` handler, which
// fires on its own schedule.
//
// Both are now conditional on the generation counter still matching. These tests
// pin that, because the symptom is a UI hang with no error anywhere: the worker
// is healthy, the encode is progressing, and nothing is listening.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('worker manager job scoping', () {
    late String source;

    setUpAll(() {
      // Normalise line endings. git checks this file out CRLF on Windows, and
      // every scan below is written against "\n" — so without this the whole
      // suite fails there and nowhere else. Same trap as test_92 in
      // filter_integration_test.rs; if you add an assertion here, do not embed
      // a bare "\n" without remembering this line exists.
      source = File('lib/services/worker_manager.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
    });

    test('the exit handler does nothing once a newer job has started', () {
      final start = source.indexOf('_process!.exitCode.then(');
      expect(start, greaterThan(-1), reason: 'exit handler not found');
      final body = source.substring(start, source.indexOf('} catch (e) {', start));

      expect(body, contains('if (generation != _generation) return;'),
          reason: 'the exit handler must bail out when superseded, or it emits '
              "a stale completion and calls _cleanup() on someone else's job");

      // The guard has to come before the teardown, not after it.
      final guardAt = body.indexOf('if (generation != _generation) return;');
      final cleanupAt = RegExp(r'^\s*_cleanup\(\);', multiLine: true)
          .firstMatch(body)!
          .start;
      expect(guardAt, lessThan(cleanupAt),
          reason: 'the guard must precede the _cleanup() call, or the damage is '
              'done before it is checked');
    });

    test('cancel does not clean up a job it did not start', () {
      final start = source.indexOf('Future<void> cancel() async {');
      expect(start, greaterThan(-1));
      final body = source.substring(start);
      final end = body.indexOf('\n  }\n');
      final cancelBody = body.substring(0, end);

      expect(cancelBody, contains('final generation = _generation;'),
          reason: 'cancel() must capture which job it is cancelling');
      expect(cancelBody, contains('if (generation != _generation) return;'),
          reason: 'cancel() waits for a real exit, so by the time it resumes the '
              'queue may have started the next job — it must not clean that up');
      // Match the call, not the word: cancel()'s own comments mention
      // _cleanup(), and comparing against prose proved nothing.
      final guardAt = cancelBody.indexOf('if (generation != _generation) return;');
      final cleanupAt = RegExp(r'^\s*_cleanup\(\);', multiLine: true)
          .firstMatch(cancelBody)!
          .start;
      expect(guardAt, lessThan(cleanupAt),
          reason: 'the guard must precede the _cleanup() call');
    });

    test('a cancelled job is reported as cancelled, not as an exit code', () {
      // The exit handler is registered on exitCode before cancel() awaits it, so
      // it reports first. Without _cancelRequested it describes a deliberate
      // cancellation as "Worker exited with code 143", and the UI cannot tell a
      // cancellation from a crash.
      final start = source.indexOf('_process!.exitCode.then(');
      final body = source.substring(start, source.indexOf('} catch (e) {', start));
      expect(body, contains('cancelled: _cancelRequested'),
          reason: 'the exit handler must mark a cancelled job as cancelled');
      expect(body, contains("_cancelRequested\n"),
          reason: 'and use it for the message too');
    });

    test('startJob resets both flags so state cannot leak between jobs', () {
      final start = source.indexOf('Future<void> startJob(');
      final body = source.substring(start, source.indexOf('_process = await Process.start', start));
      expect(body, contains('_completionEmitted = false;'));
      expect(body, contains('_cancelRequested = false;'),
          reason: 'a stale _cancelRequested would make the next job report '
              'itself cancelled the moment it finished');
      expect(body, contains('++_generation'),
          reason: 'each job needs its own generation, or the guards never fire');
    });
  });
}
