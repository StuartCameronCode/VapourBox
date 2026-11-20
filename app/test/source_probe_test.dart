// Task #85: when the worker's `--probe-source` (or `--complete-source`)
// fails, it prints `{"error": …}` on stdout and logs why on stderr (task
// #83: each ffprobe run it retried). The app used to drop both. These tests
// read that answer: the parser on every platform, and a fake worker process
// where a shell script can stand in for it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/models/source_model.dart';
import 'package:vapourbox/services/temp_directory_service.dart';
import 'package:vapourbox/services/timestamp_continuity_service.dart';

const _reason = 'could not count the frames of small_clip.mp4: ffprobe\'s '
    'video-start probe failed (exit code 1)';
const _retries = [
  'the video-start probe failed (attempt 1 of 3): exit code 1',
  'the video-start probe failed (attempt 2 of 3): exit code 1',
];

const _modelLine = '{"schema":${SourceModel.schema},"identity":{"path":"/v/a.mp4"},'
    '"formatName":"mov,mp4","video":{"width":720,"height":576,"frameRate":25.0,'
    '"frameCount":100},"audioStreams":[]}';

void main() {
  group('SourceProbe.fromWorkerOutput', () {
    test('a model on exit 0 is the answer', () {
      final r = SourceProbe.fromWorkerOutput(0, '$_modelLine\n', '');
      expect(r.ok, isTrue);
      expect(r.model!.frameCount, 100);
      expect(r.error, isNull);
    });

    test('the worker\'s {"error"} is the reason, with its stderr in order', () {
      final r = SourceProbe.fromWorkerOutput(
          1, '{"error": "$_reason"}\n', '${_retries.join('\n')}\n');
      expect(r.ok, isFalse);
      expect(r.model, isNull);
      expect(r.error, _reason);
      expect(r.log, _retries);
    });

    test('CRLF output reads the same', () {
      final r = SourceProbe.fromWorkerOutput(
          1, '{"error": "$_reason"}\r\n', '${_retries.join('\r\n')}\r\n');
      expect(r.error, _reason);
      expect(r.log, _retries);
    });

    test('stderr is capped to its last lines', () {
      final lines = [for (var i = 0; i < 50; i++) 'line $i'];
      final r = SourceProbe.fromWorkerOutput(1, '', lines.join('\n'));
      expect(r.log, hasLength(SourceProbe.maxLogLines));
      expect(r.log.last, 'line 49');
      expect(r.log.first, 'line ${50 - SourceProbe.maxLogLines}');
    });

    test('no reason on stdout gives one that says so', () {
      final r = SourceProbe.fromWorkerOutput(3, 'panicked\nnot json {', '');
      expect(r.ok, isFalse);
      expect(r.error, 'the worker exited with 3 and gave no reason');
    });

    test('a model with a non-zero exit is not accepted', () {
      final r = SourceProbe.fromWorkerOutput(1, '$_modelLine\n', '');
      expect(r.ok, isFalse);
      expect(r.model, isNull);
      expect(r.error, isNotNull);
    });
  });

  group('a fake worker', () {
    late Directory dir;

    setUpAll(() async {
      await TempDirectoryService.instance.initialize();
    });

    setUp(() {
      dir = Directory.systemTemp.createTempSync('source_probe_test');
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// A worker that logs [_retries] on stderr, prints [_reason] as its
    /// answer and exits 1, whatever it is asked.
    String fakeWorker() {
      final f = File(p.join(dir.path, 'fake-worker'));
      f.writeAsStringSync('#!/bin/sh\n'
          '${[for (final l in _retries) "echo '$l' >&2"].join('\n')}\n'
          'echo \'{"error": "${_reason.replaceAll("'", "'\\''")}"}\'\n'
          'exit 1\n');
      Process.runSync('chmod', ['+x', f.path]);
      return f.path;
    }

    test('--probe-source: the reason and the worker\'s lines come back', () async {
      final service = TimestampContinuityService(workerPath: fakeWorker());
      final r = await service.probeSource('/v/small_clip.mp4', deferScan: true);
      expect(r.ok, isFalse);
      expect(r.error, _reason);
      expect(r.log, _retries);
    }, skip: Platform.isWindows ? 'a #!/bin/sh worker (the parser test covers Windows)' : false);

    test('--complete-source: the reason and the worker\'s lines come back', () async {
      final service = TimestampContinuityService(workerPath: fakeWorker());
      final model = SourceModel.parse(_modelLine)!;
      final task = service.completeSource(model);
      expect(await task.result, isNull);
      expect(task.error, _reason);
      expect(task.log, _retries);
    }, skip: Platform.isWindows ? 'a #!/bin/sh worker (the parser test covers Windows)' : false);

    test('no worker is a reason too', () async {
      final service = TimestampContinuityService(
          workerPath: p.join(dir.path, 'no-such-worker'));
      final r = await service.probeSource('/v/a.mp4');
      expect(r.ok, isFalse);
      expect(r.error, contains('could not be run'));
    });
  });
}
