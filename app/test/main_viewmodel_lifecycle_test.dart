// The queue state machine, driven end to end against a fake runner.
//
// This file exists because three fixes for the same hang shipped without ever
// being exercised. `MainViewModel` constructed its own `WorkerManager`, so the
// state machine could not be driven from a test at all; every fix rested on
// reading the code, and two were "verified" by tests that only read source text.
//
// What makes the hang possible is that two independent latches gate everything —
// `_state` and `_isQueueProcessing` — and both are retired only by a
// `CompletionResult`. If that event does not arrive, `canProcess` stays false,
// `startQueueProcessing` returns at its guard, and the UI spins with Start and
// Cancel both disabled. So the important cases below are the ones where an event
// is missing or unattributable, not the happy path.

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/progress_info.dart';
import 'package:vapourbox/models/queue_item.dart';
import 'package:vapourbox/services/worker_manager.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

import 'fakes/fake_job_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeJobRunner runner;
  late MainViewModel vm;

  /// A queue with [n] items sitting at `ready`.
  ///
  /// Analysis fails without real files, which the viewmodel tolerates — items
  /// still end up `ready`, which is all these tests need.
  Future<void> seedQueue(int n) async {
    await vm.addMultipleToQueue([
      for (var i = 0; i < n; i++) '/tmp/vapourbox_test_$i.mkv',
    ]);
    for (final item in vm.queue) {
      item.status = QueueItemStatus.ready;
    }
  }

  setUp(() {
    runner = FakeJobRunner();
    vm = MainViewModel(runner: runner);
  });

  tearDown(() => vm.dispose());

  test('a successful job leaves the queue idle and the item completed',
      () async {
    await seedQueue(1);
    await vm.startQueueProcessing();
    expect(runner.started, hasLength(1));

    await runner.succeed();

    expect(vm.queue.single.status, QueueItemStatus.completed);
    expect(vm.isQueueProcessing, isFalse);
    expect(vm.state, ProcessingState.completed);
  });

  test('cancelling stops the queue and allows a new run — the reported symptom',
      () async {
    await seedQueue(1);
    await vm.startQueueProcessing();
    expect(vm.isProcessing, isTrue);

    await vm.cancelProcessing();

    expect(vm.queue.single.status, QueueItemStatus.cancelled,
        reason: 'a cancelled item must not read as failed; the queue treats '
            'those completely differently');
    expect(vm.isQueueProcessing, isFalse);
    expect(vm.state, ProcessingState.idle,
        reason: 'stuck anywhere else and Start is disabled forever');

    // The actual complaint: the next conversion never ran.
    expect(vm.canProcess, isTrue);
    await vm.startQueueProcessing();
    expect(runner.started, hasLength(2),
        reason: 'the second job must actually start');
    expect(vm.isProcessing, isTrue);
  });

  test('cancelling recovers even when the runner reports nothing at all',
      () async {
    // Exactly the shipped bug: WorkerManager.cancel() returned early with a null
    // process and emitted no completion, leaving `_state` latched at
    // `cancelling` — which is neither `idle` nor in `canCancel`, so Start and
    // Cancel were both disabled with no way back.
    runner.emitNothingOnCancel = true;
    await seedQueue(1);
    await vm.startQueueProcessing();

    await vm.cancelProcessing();

    expect(vm.state, ProcessingState.idle,
        reason: 'a missing completion must cost a mislabelled item, not a dead '
            'window');
    expect(vm.isQueueProcessing, isFalse);
    expect(vm.canProcess, isTrue);
  });

  test('no queue item is left stranded in `processing`', () async {
    // `processing` is neither canProcess nor canReprocess, so an item left in it
    // is skipped by startQueueProcessing's reset loop and can never run again.
    runner.emitNothingOnCancel = true;
    await seedQueue(2);
    await vm.startQueueProcessing();

    await vm.cancelProcessing();

    expect(
      vm.queue.where((q) => q.status == QueueItemStatus.processing),
      isEmpty,
      reason: 'an item stuck at processing poisons the queue permanently',
    );
    expect(vm.queueReadyCount, greaterThan(0));
  });

  test('an unattributable completion stands the queue down rather than latching',
      () async {
    await seedQueue(1);
    await vm.startQueueProcessing();

    // Two completions for one job: the second arrives with the index already
    // reset. It used to be dropped silently, stranding both latches.
    await runner.succeed();
    await runner.complete(const CompletionResult(
      success: false,
      errorMessage: 'late straggler',
    ));

    expect(vm.isQueueProcessing, isFalse);
    expect(vm.state.isActive, isFalse,
        reason: 'a late or unattributable event must never leave the UI active');
  });

  test('a genuine failure is still recorded as failed, not swallowed', () async {
    await seedQueue(1);
    await vm.startQueueProcessing();

    await runner.fail(error: 'ffmpeg exited with -22');

    expect(vm.queue.single.status, QueueItemStatus.failed,
        reason: 'a crash reported as a cancellation would hide real breakage');
    expect(vm.isQueueProcessing, isFalse);
  });

  test('a failure mid-queue continues to the next item', () async {
    await seedQueue(2);
    await vm.startQueueProcessing();

    await runner.fail();

    expect(runner.started, hasLength(2),
        reason: 'cancel stops the queue, but a failure carries on');
    expect(vm.queue.first.status, QueueItemStatus.failed);
  });

  test('a runner that cannot start does not leave the queue active', () async {
    runner.failToStart = true;
    await seedQueue(1);

    await vm.startQueueProcessing();

    expect(vm.isQueueProcessing, isFalse,
        reason: 'startJob threw, so nothing will ever report a completion');
    expect(vm.state.isActive, isFalse);
  });
}
