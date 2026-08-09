import '../models/progress_info.dart';
import '../models/video_job.dart';
import 'worker_manager.dart' show CompletionResult, LogMessage;

/// What [MainViewModel] needs from the thing that runs jobs.
///
/// This exists as a seam for testing, and the reason is worth stating: three
/// separate fixes for the same cancellation hang shipped without ever being
/// exercised, because `MainViewModel` constructed its `WorkerManager` directly
/// and so the queue state machine could not be driven from a test at all. Every
/// fix rested on reading the code, and two of them were "verified" by tests that
/// only read the source text.
///
/// The interface is deliberately the *observed* surface — the streams the
/// viewmodel listens to and the three calls it makes — not everything
/// WorkerManager can do. Anything outside this (GPU probing, process groups)
/// stays on the concrete class.
abstract interface class JobRunner {
  /// Progress updates for the running job.
  Stream<ProgressInfo> get progressStream;

  /// Log lines from the worker.
  Stream<LogMessage> get logStream;

  /// Exactly one event per started job — see [startJob].
  Stream<CompletionResult> get completionStream;

  /// Whether a job is currently running.
  bool get isRunning;

  /// Starts [job].
  ///
  /// Implementations must emit exactly one [CompletionResult] for every call
  /// that returns normally: no more (the UI would act twice) and no fewer (the
  /// UI latches on `cancelling`/`processing` and never returns to idle, which is
  /// the hang this interface was introduced to make testable).
  Future<void> startJob(VideoJob job);

  /// Cancels the running job.
  ///
  /// Must still emit a completion when there is nothing to kill — the caller has
  /// already moved the UI into `cancelling` by the time this is called, so
  /// emitting nothing strands it there with Start and Cancel both disabled.
  Future<void> cancel();

  /// Releases resources.
  void dispose();
}
