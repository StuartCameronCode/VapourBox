import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/progress_info.dart';
import '../models/video_job.dart';
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

    final toolLocator = ToolLocator.instance;
    final workerPath = toolLocator.workerPath;
    if (workerPath == null) {
      throw Exception('Worker executable not found');
    }

    // Write job config to temp file
    final tempDir = Directory.systemTemp;
    final configFile = File('${tempDir.path}/vapourbox_job_${job.id}.json');
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
        // Clean up config file
        configFile.delete().catchError((_) => configFile);

        // Emit completion result after process has fully exited
        if (!_completionController.isClosed) {
          if (_pendingCompletion != null) {
            // Use the completion result from stdout
            _completionController.add(_pendingCompletion!);
          } else if (exitCode != 0) {
            // Process exited with error before sending completion
            _completionController.add(CompletionResult(
              success: false,
              errorMessage: 'Worker exited with code $exitCode',
            ));
          }
        }

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

  /// Cancels the current job.
  Future<void> cancel() async {
    if (_process == null) return;

    // Send SIGTERM on Unix, taskkill on Windows
    if (Platform.isWindows) {
      // On Windows, we need to kill the process tree
      await Process.run('taskkill', ['/PID', '${_process!.pid}', '/T', '/F']);
    } else {
      _process!.kill(ProcessSignal.sigterm);
    }

    // Give it a moment to clean up
    await Future.delayed(const Duration(milliseconds: 500));

    // Force kill if still running
    if (_process != null) {
      _process!.kill(ProcessSignal.sigkill);
    }

    _cleanup();

    _completionController.add(CompletionResult(
      success: false,
      errorMessage: 'Job cancelled by user',
      cancelled: true,
    ));
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
