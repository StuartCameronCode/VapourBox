import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/progress_info.dart';
import '../models/video_job.dart';

/// Manages the worker process lifecycle and IPC.
class WorkerManager {
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

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

    final workerPath = await _findWorker();
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
        environment: await _getEnvironment(),
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
        _cleanup();

        // Clean up config file
        configFile.delete().catchError((_) => configFile);

        if (exitCode != 0 && !_completionController.isClosed) {
          _completionController.add(CompletionResult(
            success: false,
            errorMessage: 'Worker exited with code $exitCode',
          ));
        }
      });
    } catch (e) {
      await configFile.delete().catchError((_) => configFile);
      _cleanup();
      rethrow;
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
        _logController.add(LogMessage(
          level: LogLevel.error,
          message: message.message ?? 'Unknown error',
        ));
      } else if (message.isComplete) {
        _completionController.add(CompletionResult(
          success: message.success ?? false,
          outputPath: message.outputPath,
        ));
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
  }

  Future<String?> _findWorker() async {
    // Check bundled location first
    final bundledPath = await _getBundledWorkerPath();
    if (bundledPath != null && await File(bundledPath).exists()) {
      return bundledPath;
    }

    // Development: check relative to executable
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final workerExe = 'vapourbox-worker${Platform.isWindows ? '.exe' : ''}';

    List<String> devPaths;
    if (Platform.isWindows) {
      // Windows: app/build/windows/x64/runner/Debug/ - 6 levels to project root
      devPaths = [
        '$exeDir/$workerExe',
        '$exeDir/../../../../../../worker/target/release/$workerExe',
        '$exeDir/../../../../../../worker/target/debug/$workerExe',
      ];
    } else if (Platform.isMacOS) {
      // macOS: app/build/macos/Build/Products/Debug/vapourbox.app/Contents/MacOS - 9 levels to project root
      devPaths = [
        '$exeDir/$workerExe',
        '$exeDir/../../../../../../../../../worker/target/release/$workerExe',
        '$exeDir/../../../../../../../../../worker/target/debug/$workerExe',
      ];
    } else {
      devPaths = ['$exeDir/$workerExe'];
    }

    for (final path in devPaths) {
      final file = File(path);
      if (await file.exists()) {
        return file.absolute.path;
      }
    }

    return null;
  }

  Future<String?> _getBundledWorkerPath() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;

    if (Platform.isWindows) {
      return '$exeDir\\vapourbox-worker.exe';
    } else if (Platform.isMacOS) {
      // In .app bundle: Contents/MacOS/vapourbox-worker
      return '$exeDir/vapourbox-worker';
    }

    return null;
  }

  Future<Map<String, String>> _getEnvironment() async {
    final env = Map<String, String>.from(Platform.environment);
    final depsDir = await _findDepsDir();

    if (depsDir == null) {
      // No deps found, return unchanged environment
      return env;
    }

    if (Platform.isWindows) {
      // VapourSynth portable bundles Python 3.8
      env['PYTHONHOME'] = '$depsDir\\vapoursynth';
      env['PYTHONPATH'] = '$depsDir\\vapoursynth\\Lib\\site-packages';

      // Add to PATH
      final paths = [
        '$depsDir\\vapoursynth',
        '$depsDir\\ffmpeg',
      ];
      env['PATH'] = '${paths.join(';')};${env['PATH'] ?? ''}';

      // VapourSynth plugin path
      env['VAPOURSYNTH_PLUGIN_PATH'] = '$depsDir\\vapoursynth\\vs-plugins';
    } else if (Platform.isMacOS) {
      // Check if we have a bundled Python framework (production) or use Homebrew (development)
      final bundledPython = Directory('$depsDir/python');
      if (await bundledPython.exists()) {
        env['PYTHONHOME'] = '$depsDir/python';
      }
      // Don't set PYTHONHOME for development - use system Python from Homebrew

      // Python packages path
      env['PYTHONPATH'] = '$depsDir/python-packages';

      // VapourSynth plugins
      env['VAPOURSYNTH_PLUGIN_PATH'] = '$depsDir/vapoursynth/plugins';

      // Add to PATH
      final paths = [
        '$depsDir/vapoursynth',
        '$depsDir/ffmpeg',
      ];
      // Only add bundled Python to PATH if it exists
      if (await bundledPython.exists()) {
        paths.insert(0, '$depsDir/python/bin');
      }
      env['PATH'] = '${paths.join(':')}:${env['PATH'] ?? ''}';

      // Set DYLD_LIBRARY_PATH for VapourSynth libraries
      env['DYLD_LIBRARY_PATH'] = '$depsDir/vapoursynth:${env['DYLD_LIBRARY_PATH'] ?? ''}';
    }

    return env;
  }

  Future<String?> _findDepsDir() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;

    if (Platform.isWindows) {
      // Production: deps folder next to executable
      final prodDeps = Directory('$exeDir\\deps');
      if (await prodDeps.exists()) {
        return prodDeps.path;
      }

      // Development: go up to project root and find deps/windows-x64
      // From app/build/windows/x64/runner/Debug/ up 6 levels
      final devDeps = Directory('$exeDir\\..\\..\\..\\..\\..\\..\\deps\\windows-x64');
      if (await devDeps.exists()) {
        return devDeps.absolute.path;
      }
    } else if (Platform.isMacOS) {
      // Production: in app bundle Contents
      final contentsDir = '$exeDir/..';
      final prodPython = Directory('$contentsDir/Frameworks/Python.framework');
      if (await prodPython.exists()) {
        return contentsDir;
      }

      // Development: go up to project root and find deps/macos-arm64 or macos-x64
      // From app/build/macos/Build/Products/Debug/vapourbox.app/Contents/MacOS up 9 levels
      final devDepsArm = Directory('$exeDir/../../../../../../../../../deps/macos-arm64');
      if (await devDepsArm.exists()) {
        return devDepsArm.absolute.path;
      }
      final devDepsX64 = Directory('$exeDir/../../../../../../../../../deps/macos-x64');
      if (await devDepsX64.exists()) {
        return devDepsX64.absolute.path;
      }
    }

    return null;
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
