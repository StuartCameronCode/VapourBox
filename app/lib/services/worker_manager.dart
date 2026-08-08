import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/progress_info.dart';
import '../models/video_job.dart';
import 'process_tree.dart';
import 'temp_directory_service.dart';
import 'tool_locator.dart';

/// Manages the worker process lifecycle and IPC.
class WorkerManager {
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  /// Pending completion result from stdout (emitted after process exits).
  CompletionResult? _pendingCompletion;

  /// Last error message received (used to populate CompletionResult).
  String? _lastErrorMessage;

  /// Whether a completion has already been emitted for the current job.
  ///
  /// Exactly one completion event per job, no more and no less. Cancelling
  /// emits immediately and the process exit would otherwise emit again; a
  /// missing `complete` message would otherwise emit nothing at all and leave
  /// the UI on "processing" forever with the worker already gone — which is
  /// indistinguishable from the hang reported in #50.
  bool _completionEmitted = false;

  /// Which job the manager is currently running.
  ///
  /// Incremented by every [startJob]. Anything asynchronous that outlives a job
  /// — the exit handler, the tail of [cancel] — captures this and does nothing
  /// if it no longer matches, because by then it would be acting on someone
  /// else's job.
  ///
  /// This matters because cancelling now waits for the worker to genuinely exit,
  /// which can take seconds. Cancellation emits a completion, the queue advances
  /// and starts the next job on that event, and the tail of the *cancelling*
  /// call then ran `_cleanup()` — nulling `_process` and cancelling the new job's
  /// stdout subscription. The job ran to completion with nobody listening, so the
  /// progress dialog span forever with no updates.
  int _generation = 0;

  /// Whether the job identified by [_generation] is being cancelled.
  ///
  /// The exit handler is registered on `exitCode` before [cancel] awaits it, so
  /// it reports first. Without this it describes a deliberate cancellation as
  /// "Worker exited with code 143".
  bool _cancelRequested = false;

  /// Stream of progress updates from the worker.
  final _progressController = StreamController<ProgressInfo>.broadcast();
  Stream<ProgressInfo> get progressStream => _progressController.stream;

  /// Stream of log messages from the worker.
  final _logController = StreamController<LogMessage>.broadcast();
  Stream<LogMessage> get logStream => _logController.stream;

  /// Stream of completion events.
  final _completionController = StreamController<CompletionResult>.broadcast();
  Stream<CompletionResult> get completionStream => _completionController.stream;

  /// Whether the worker is currently running.
  bool get isRunning => _process != null;

  /// Starts a deinterlacing job.
  ///
  /// Creates a temporary JSON config file and spawns the worker process.
  Future<void> startJob(VideoJob job) async {
    if (_process != null) {
      throw StateError('Worker is already running');
    }

    _completionEmitted = false;
    _cancelRequested = false;
    final generation = ++_generation;

    final toolLocator = ToolLocator.instance;
    final workerPath = toolLocator.workerPath;
    if (workerPath == null) {
      throw Exception('Worker executable not found');
    }

    // Write job config to temp file
    final configFile = File(
      await TempDirectoryService.instance.filePath('vapourbox_job_${job.id}.json'),
    );
    await configFile.writeAsString(jsonEncode(job.toJson()));

    try {
      // Start worker process
      _process = await Process.start(
        workerPath,
        ['--config', configFile.path],
        environment: toolLocator.workerEnvironment,
        workingDirectory: File(workerPath).parent.path,
      );

      // Listen to stdout for JSON messages
      _stdoutSubscription = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStdoutLine);

      // Listen to stderr for error output
      _stderrSubscription = _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStderrLine);

      // Wait for process to exit
      _process!.exitCode.then((exitCode) {
        // Clean up config file — safe regardless of whose job this is.
        configFile.delete().catchError((_) => configFile);

        // A newer job has since started; reporting its completion or tearing
        // down its plumbing here would strand it silently.
        if (generation != _generation) return;

        // The worker sends a `complete` message on both success and failure, so
        // _pendingCompletion is normally set. If it isn't, the exit still has to
        // be reported — see [_completionEmitted].
        _emitCompletion(_pendingCompletion ??
            CompletionResult(
              success: false,
              cancelled: _cancelRequested,
              errorMessage: _cancelRequested
                  ? 'Job cancelled by user'
                  : _lastErrorMessage ??
                      (exitCode == 0
                          ? 'Worker exited without reporting a result'
                          : 'Worker exited with code $exitCode'),
            ));

        _cleanup();
      });
    } catch (e) {
      await configFile.delete().catchError((_) => configFile);
      _cleanup();
      rethrow;
    }
  }

  /// Probe GPU capabilities by running the worker with `--probe-opencl` and
  /// parsing its JSON output (`{"opencl": bool, "knlm": bool}`).
  ///
  /// - `opencl`: a usable OpenCL device for the QTGMC NNEDI3CL path.
  /// - `knlm`: the knlmeanscl denoiser specifically (a DISTINCT probe —
  ///   KNLMeansCL can fail where NNEDI3CL succeeds).
  ///
  /// Both default to `false` if the worker can't be found, fails, or doesn't
  /// report the field — callers treat that as "warn the user", the safe default.
  static Future<({bool opencl, bool knlm})> probeGpuCapabilities() async {
    final toolLocator = ToolLocator.instance;
    final workerPath = toolLocator.workerPath;
    if (workerPath == null) return (opencl: false, knlm: false);

    try {
      final result = await Process.run(
        workerPath,
        ['--probe-opencl'],
        environment: toolLocator.workerEnvironment,
        workingDirectory: File(workerPath).parent.path,
      );
      if (result.exitCode != 0) return (opencl: false, knlm: false);
      // The worker prints a single JSON line; tolerate extra log lines.
      for (final line in const LineSplitter().convert(result.stdout.toString())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map && decoded['opencl'] is bool) {
            return (
              opencl: decoded['opencl'] as bool,
              knlm: decoded['knlm'] == true,
            );
          }
        } catch (_) {
          // Not the JSON line; keep scanning.
        }
      }
      return (opencl: false, knlm: false);
    } catch (_) {
      return (opencl: false, knlm: false);
    }
  }

  /// How long to let the worker shut itself down before forcing it.
  ///
  /// This MUST comfortably exceed the worker's cancellation poll interval
  /// (`progress_interval`, 500ms in `pipeline_executor.rs`), because SIGTERM
  /// only sets an atomic flag there — the actual teardown happens the next time
  /// the progress loop comes round, and only then does it get to kill vspipe
  /// and ffmpeg and reap them.
  ///
  /// It used to be exactly 500ms, i.e. precisely the poll interval, so the
  /// worker essentially never won the race: it was SIGKILLed before reaching the
  /// check. SIGKILL cannot be caught, so `PipelineExecutor::terminate()` (and its
  /// `Drop`) never ran and vspipe/ffmpeg were reparented to init — left encoding
  /// a cancelled job at full tilt, still writing to the output file, while the UI
  /// reported "Job cancelled by user". Observed in the wild: three orphans at
  /// ~670% CPU eleven minutes after a cancel, output past 320MB.
  static const Duration _shutdownGrace = Duration(seconds: 5);

  /// How long to wait for a SIGKILLed process to actually disappear.
  static const Duration _forceKillGrace = Duration(seconds: 3);

  /// Cancels the current job.
  ///
  /// Waits for the worker to genuinely exit rather than assuming it has, so its
  /// children are torn down by the worker itself. Only escalates to SIGKILL if
  /// it is still alive after [_shutdownGrace].
  Future<void> cancel() async {
    // Hold a local reference: `_cleanup()` nulls the field, and the old code
    // tested `_process != null` *before* that ran, so its "force kill if still
    // running" check was never actually false.
    final process = _process;
    if (process == null) return;
    // Which job this call is cancelling. Everything after the await below is
    // conditional on it still being the current one.
    final generation = _generation;
    _cancelRequested = true;

    if (Platform.isWindows) {
      // No SIGTERM on Windows, and Process.kill maps to TerminateProcess, which
      // does not touch children. taskkill /T walks the tree, so nothing is
      // orphaned; /F is unavoidable there.
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      // Signal the whole process group. The worker still tears its own pipeline
      // down when it gets the chance, but that only covers the children it
      // tracks, and it cannot run at all if it is forced below — so do not rely
      // on it alone. See ProcessTree.
      ProcessTree.killTree(process);
    }

    // Wait for the process to actually exit. `exitCode` completes once it has
    // been reaped, so this is a real observation rather than a guess.
    var exited = true;
    try {
      await process.exitCode.timeout(_shutdownGrace);
    } on TimeoutException {
      exited = false;
    }

    if (!exited) {
      // Genuinely wedged. Forcing it here orphans the children — the same
      // failure described above — but by now the alternative is a job that
      // never stops at all, so take the lesser problem and say so.
      ProcessTree.killTree(process, ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(_forceKillGrace);
      } on TimeoutException {
        // Nothing further we can do from here.
      }
    }

    // Waiting above can take seconds, and cancelling emits a completion that
    // the queue acts on by starting the next job. If that has happened, this
    // call must not touch anything: `_cleanup()` would null `_process` and
    // cancel the new job's stdout subscription, leaving it running with nobody
    // listening and the progress dialog spinning forever.
    if (generation != _generation) return;

    _cleanup();

    _emitCompletion(CompletionResult(
      success: false,
      errorMessage: exited
          ? 'Job cancelled by user'
          : 'Job cancelled by user (the worker had to be forced, so stray '
              'ffmpeg/vspipe processes may still be running)',
      cancelled: true,
    ));
  }

  /// Emit [result] unless this job has already reported one.
  void _emitCompletion(CompletionResult result) {
    if (_completionEmitted || _completionController.isClosed) return;
    _completionEmitted = true;
    _completionController.add(result);
  }

  void _handleStdoutLine(String line) {
    if (line.trim().isEmpty) return;

    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      final message = WorkerMessage.fromJson(json);

      if (message.isProgress) {
        final progress = message.toProgressInfo();
        if (progress != null) {
          _progressController.add(progress);
        }
      } else if (message.isLog) {
        _logController.add(LogMessage(
          level: LogLevel.fromString(message.level ?? 'info'),
          message: message.message ?? '',
        ));
      } else if (message.isError) {
        _lastErrorMessage = message.message ?? 'Unknown error';
        _logController.add(LogMessage(
          level: LogLevel.error,
          message: _lastErrorMessage!,
        ));
      } else if (message.isComplete) {
        // Store completion result - will be emitted after process exits
        _pendingCompletion = CompletionResult(
          success: message.success ?? false,
          outputPath: message.outputPath,
          errorMessage: (message.success != true) ? _lastErrorMessage : null,
        );
      }
    } catch (e) {
      // Not JSON, treat as log message
      _logController.add(LogMessage(
        level: LogLevel.debug,
        message: line,
      ));
    }
  }

  void _handleStderrLine(String line) {
    if (line.trim().isEmpty) return;

    _logController.add(LogMessage(
      level: LogLevel.warning,
      message: line,
    ));
  }

  void _cleanup() {
    _stdoutSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription?.cancel();
    _stderrSubscription = null;
    _process = null;
    _pendingCompletion = null;
    _lastErrorMessage = null;
  }

  /// Disposes of resources.
  void dispose() {
    cancel();
    _progressController.close();
    _logController.close();
    _completionController.close();
  }
}

/// A log message from the worker.
class LogMessage {
  final LogLevel level;
  final String message;
  final DateTime timestamp;

  LogMessage({
    required this.level,
    required this.message,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Result of a completed job.
class CompletionResult {
  final bool success;
  final String? outputPath;
  final String? errorMessage;
  final bool cancelled;

  const CompletionResult({
    required this.success,
    this.outputPath,
    this.errorMessage,
    this.cancelled = false,
  });
}
