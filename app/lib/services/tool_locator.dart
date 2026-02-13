import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'dependency_manager.dart';

/// Centralized service for locating bundled external tools (ffmpeg, ffprobe,
/// vspipe, vapourbox-worker) and the platform deps directory.
///
/// All consumers use this singleton instead of independently resolving paths.
/// No system PATH fallbacks — always uses bundled tools.
class ToolLocator {
  ToolLocator._();

  static final ToolLocator instance = ToolLocator._();

  bool _initialized = false;

  /// Resolved platform-specific deps directory (e.g. `deps/windows-x64/`).
  String? _depsDir;

  /// Resolved tool paths.
  String? _ffmpegPath;
  String? _ffprobePath;
  String? _workerPath;

  /// Cached environment variables for spawning the worker.
  Map<String, String>? _workerEnvironment;

  /// The deps directory path, or null if not found.
  String? get depsDir => _depsDir;

  /// Path to the bundled ffmpeg executable, or null if not found.
  String? get ffmpegPath => _ffmpegPath;

  /// Path to the bundled ffprobe executable, or null if not found.
  String? get ffprobePath => _ffprobePath;

  /// Path to the vapourbox-worker executable, or null if not found.
  String? get workerPath => _workerPath;

  /// Environment variables for spawning worker/tool processes.
  /// Includes PYTHONHOME, PYTHONPATH, VAPOURSYNTH_PLUGIN_PATH, PATH, etc.
  Map<String, String> get workerEnvironment =>
      _workerEnvironment ?? Map<String, String>.from(Platform.environment);

  /// The current platform identifier (e.g. `windows-x64`, `macos-arm64`).
  String get platformId => DependencyManager.instance.platformId;

  /// Initialize the tool locator. Call once at startup after deps are confirmed
  /// installed.
  Future<void> initialize() async {
    if (_initialized) return;

    // Resolve deps directory via DependencyManager
    try {
      final depsDirectory = await DependencyManager.instance.getDepsDirectory();
      if (await depsDirectory.exists()) {
        _depsDir = depsDirectory.path;
      }
    } catch (_) {
      // Unsupported platform or other error
    }

    // Resolve tool paths
    _ffmpegPath = _resolveFfmpeg();
    _ffprobePath = _resolveFfprobe();
    _workerPath = _resolveWorker();
    _workerEnvironment = await _buildWorkerEnvironment();

    _initialized = true;
  }

  /// Resolve the ffmpeg executable path within the deps directory.
  String? _resolveFfmpeg() {
    if (_depsDir == null) return null;
    final ext = Platform.isWindows ? '.exe' : '';
    final p = path.join(_depsDir!, 'ffmpeg', 'ffmpeg$ext');
    return File(p).existsSync() ? p : null;
  }

  /// Resolve the ffprobe executable path within the deps directory.
  String? _resolveFfprobe() {
    if (_depsDir == null) return null;
    final ext = Platform.isWindows ? '.exe' : '';
    final p = path.join(_depsDir!, 'ffmpeg', 'ffprobe$ext');
    return File(p).existsSync() ? p : null;
  }

  /// Resolve the vapourbox-worker executable path.
  String? _resolveWorker() {
    final exeDir = path.dirname(Platform.resolvedExecutable);
    final ext = Platform.isWindows ? '.exe' : '';
    final workerExe = 'vapourbox-worker$ext';

    // Production: next to the Flutter executable
    final bundled = path.join(exeDir, workerExe);
    if (File(bundled).existsSync()) return bundled;

    // Development: relative to project root
    if (kDebugMode) {
      List<String> devPaths;
      if (Platform.isWindows) {
        // app/build/windows/x64/runner/Debug/ — 6 levels up
        devPaths = [
          path.join(exeDir, '..', '..', '..', '..', '..', '..', 'worker', 'target', 'release', workerExe),
          path.join(exeDir, '..', '..', '..', '..', '..', '..', 'worker', 'target', 'debug', workerExe),
        ];
      } else if (Platform.isMacOS) {
        // app/build/macos/Build/Products/Debug/vapourbox.app/Contents/MacOS — 9 levels up
        devPaths = [
          path.join(exeDir, '..', '..', '..', '..', '..', '..', '..', '..', '..', 'worker', 'target', 'release', workerExe),
          path.join(exeDir, '..', '..', '..', '..', '..', '..', '..', '..', '..', 'worker', 'target', 'debug', workerExe),
        ];
      } else {
        devPaths = [];
      }

      for (final p in devPaths) {
        final file = File(p);
        if (file.existsSync()) {
          return file.absolute.path;
        }
      }
    }

    return null;
  }

  /// Build the environment variable map for spawning the worker.
  Future<Map<String, String>> _buildWorkerEnvironment() async {
    final env = Map<String, String>.from(Platform.environment);
    if (_depsDir == null) return env;

    if (Platform.isWindows) {
      env['PYTHONHOME'] = path.join(_depsDir!, 'vapoursynth');
      env['PYTHONPATH'] = path.join(_depsDir!, 'vapoursynth', 'Lib', 'site-packages');
      env['VAPOURSYNTH_PLUGIN_PATH'] = path.join(_depsDir!, 'vapoursynth', 'vs-plugins');

      final paths = [
        path.join(_depsDir!, 'vapoursynth'),
        path.join(_depsDir!, 'ffmpeg'),
      ];
      env['PATH'] = '${paths.join(';')};${env['PATH'] ?? ''}';
    } else if (Platform.isMacOS) {
      final bundledPython = Directory(path.join(_depsDir!, 'python'));
      if (await bundledPython.exists()) {
        env['PYTHONHOME'] = path.join(_depsDir!, 'python');
      }

      env['PYTHONPATH'] = path.join(_depsDir!, 'python-packages');
      env['VAPOURSYNTH_PLUGIN_PATH'] = path.join(_depsDir!, 'vapoursynth', 'plugins');

      final paths = <String>[];
      if (await bundledPython.exists()) {
        paths.add(path.join(_depsDir!, 'python', 'bin'));
      }
      paths.add(path.join(_depsDir!, 'vapoursynth'));
      paths.add(path.join(_depsDir!, 'ffmpeg'));
      env['PATH'] = '${paths.join(':')}:${env['PATH'] ?? ''}';

      env['DYLD_LIBRARY_PATH'] = '${path.join(_depsDir!, 'vapoursynth')}:${env['DYLD_LIBRARY_PATH'] ?? ''}';
    }

    return env;
  }
}
