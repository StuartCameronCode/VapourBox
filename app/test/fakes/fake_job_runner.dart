import 'dart:async';

import 'package:vapourbox/models/progress_info.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/job_runner.dart';
import 'package:vapourbox/services/worker_manager.dart';

/// A [JobRunner] that runs nothing, so the queue state machine can be driven
/// deterministically.
///
/// The point is to make the *absence* of events testable. Three fixes for the
/// same hang shipped unverified because nothing could ask "what happens when the
/// completion never arrives?" — see [emitNothingOnCancel].
class FakeJobRunner implements JobRunner {
  final _progress = StreamController<ProgressInfo>.broadcast();
  final _log = StreamController<LogMessage>.broadcast();
  final _completion = StreamController<CompletionResult>.broadcast();

  /// Every job handed to [startJob], in order.
  final List<VideoJob> started = [];

  /// How many times [cancel] was called.
  int cancelCount = 0;

  /// Whether a job is notionally running.
  bool _running = false;

  /// Make [cancel] emit no completion at all.
  ///
  /// This is the shipped bug: `WorkerManager.cancel()` returned early when
  /// `_process` was null and reported nothing, while the viewmodel had already
  /// latched `_state = cancelling`. The UI then had Start and Cancel both
  /// disabled with no way back.
  bool emitNothingOnCancel = false;

  /// Make [startJob] throw, as it does when the worker binary is missing.
  bool failToStart = false;

  @override
  Stream<ProgressInfo> get progressStream => _progress.stream;

  @override
  Stream<LogMessage> get logStream => _log.stream;

  @override
  Stream<CompletionResult> get completionStream => _completion.stream;

  @override
  bool get isRunning => _running;

  @override
  Future<void> startJob(VideoJob job) async {
    if (failToStart) throw Exception('worker not found');
    started.add(job);
    _running = true;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    _running = false;
    if (emitNothingOnCancel) return;
    complete(const CompletionResult(
      success: false,
      cancelled: true,
      errorMessage: 'Job cancelled by user',
    ));
  }

  @override
  void dispose() {
    _progress.close();
    _log.close();
    _completion.close();
  }

  /// Emit a completion as the real runner would, and let the viewmodel's
  /// listener run before returning.
  Future<void> complete(CompletionResult result) async {
    _running = false;
    _completion.add(result);
    // Broadcast delivery is asynchronous; give the listener (and any
    // _processNextItem it triggers) a chance to run.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> succeed({String output = '/tmp/out.mkv'}) =>
      complete(CompletionResult(success: true, outputPath: output));

  Future<void> fail({String error = 'ffmpeg died'}) =>
      complete(CompletionResult(success: false, errorMessage: error));
}
