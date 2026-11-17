// Task #55: the deferred timestamp-reset scan through the real worker, as
// analysis runs it: `--probe-source --defer-scan`, then `--complete-source`
// with progress, then the join given that model (so the worker does not read
// the source a second time to find the reset).
//
// The view model's gating is covered with fakes in
// timestamp_continuity_deferred_test.dart; this checks the worker calls.
@Tags(['heavy'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:vapourbox/services/temp_directory_service.dart';
import 'package:vapourbox/services/timestamp_continuity_service.dart';

import 'support/worker_harness.dart';

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

void main() {
  late TimestampContinuityService service;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await TempDirectoryService.instance.initialize();
    service = TimestampContinuityService(
        workerPath: WorkerHarness.workerPath, environment: WorkerHarness.workerEnv);
  });

  for (final (file, resetAt) in [('seek_reset_dvd_pal.mpg', 150), ('seek_reset_h264.ts', 150)]) {
    test('$file: deferred, completed with progress, joined from the model\'s scan', () async {
      final source = _resource(file);
      final deferred = await service.probeSource(source, deferScan: true);
      expect(deferred, isNotNull);
      expect(deferred!.continuityDeferred, isTrue);
      expect(deferred.continuity, isNull);

      final progress = <double>[];
      final completed =
          await service.completeSource(deferred, onProgress: progress.add).result;
      expect(completed, isNotNull);
      expect(completed!.continuityDeferred, isFalse);
      expect(completed.continuity!.videoResetPictures, [resetAt]);
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      final full = await service.probeSource(source);
      expect(completed.toJson(), full!.toJson(),
          reason: 'completing the deferred model gives the model probed in one go');

      final r = await service.prepare(source, const Uuid().v4(),
          scanned: completed.continuity, model: completed);
      expect(r.error, isNull);
      expect(r.proxy, isNotNull);
      addTearDown(r.proxy!.delete);
      final copy = await service.probeSource(r.proxy!.path);
      expect(copy!.frameCount, 300, reason: 'the copy counts both segments');
      expect(copy.continuity!.needsCopy, isFalse);
    });
  }

  test('a scan stopped part way completes with nothing', () async {
    final deferred =
        await service.probeSource(_resource('seek_reset_dvd_pal.mpg'), deferScan: true);
    final task = service.completeSource(deferred!);
    task.cancel();
    expect(await task.result, isNull);
  });

  test('a format without a scan has nothing to defer', () async {
    final m = await service.probeSource(_resource('small_clip.mp4'), deferScan: true);
    expect(m!.continuityDeferred, isFalse);
    expect(m.continuity!.needsCopy, isFalse);
  });
}
