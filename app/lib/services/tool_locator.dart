import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'dependency_manager.dart';
import 'temp_directory_service.dart';

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
  /// Includes PYTHONHOME, PYTHONPATH, VAPOURSYNTH_EXTRA_PLUGIN_PATH, PATH, etc.
  ///
  /// The temp variables are applied per call rather than baked into the cached
  /// map, so changing the temp directory in Settings takes effect immediately.
  /// They point the worker's `env::temp_dir()` — and ffmpeg's and vspipe's — at
  /// the configured directory: TMPDIR for Unix, TMP/TEMP for Windows.
  Map<String, String> get workerEnvironment {
    final env = Map<String, String>.from(
      _workerEnvironment ?? Platform.environment,
    );
    final tempPath = TempDirectoryService.instance.effectivePath;
    env['TMPDIR'] = tempPath;
    env['TMP'] = tempPath;
    env['TEMP'] = tempPath;
    return env;
  }

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
        print('ToolLocator: deps directory: $_depsDir');
      } else {
        print('ToolLocator: deps directory does not exist: ${depsDirectory.path}');
      }
    } catch (e) {
      print('ToolLocator: failed to resolve deps directory: $e');
    }

    // Resolve tool paths
    _ffmpegPath = _resolveFfmpeg();
    _ffprobePath = _resolveFfprobe();
    _workerPath = _resolveWorker();
    _workerEnvironment = await _buildWorkerEnvironment();

    print('ToolLocator: ffmpeg=${_ffmpegPath != null ? "found" : "NOT FOUND"}');
    print('ToolLocator: ffprobe=${_ffprobePath != null ? "found" : "NOT FOUND"}');
    print('ToolLocator: worker=${_workerPath != null ? "found" : "NOT FOUND"}');

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
    // Explicit override, mirroring VAPOURBOX_DEPS_DIR above. Under `flutter
    // test` the resolved executable is the test runner, not the app bundle, so
    // neither the production nor the dev path below can find the worker — which
    // left WorkerManager, and therefore the whole cancel/restart flow, with no
    // way to be tested against a real worker at all.
    final override = Platform.environment['VAPOURBOX_WORKER'];
    if (override != null && override.isNotEmpty && File(override).existsSync()) {
      return override;
    }

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
      } else if (Platform.isLinux) {
        // app/build/linux/x64/debug/bundle/ — 6 levels up
        devPaths = [
          path.join(exeDir, '..', '..', '..', '..', '..', '..', 'worker', 'target', 'release', workerExe),
          path.join(exeDir, '..', '..', '..', '..', '..', '..', 'worker', 'target', 'debug', workerExe),
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
      env['VAPOURSYNTH_EXTRA_PLUGIN_PATH'] = path.join(_depsDir!, 'vapoursynth', 'vs-plugins');

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

      // The platform dir carries the R78 `vapoursynth` package (libs, vsscript
      // and the extension module), so it must be importable: vsscript's config
      // is keyed by the libvsscript path the module reports, and that has to be
      // the same file vspipe-bin loads.
      env['PYTHONPATH'] =
          [_depsDir!, path.join(_depsDir!, 'python-packages')].join(':');
      env['PYTHONNOUSERSITE'] = '1';
      // No VAPOURSYNTH_EXTRA_PLUGIN_PATH here: the plugins sit at
      // <libdir>/plugins, which R78 autoloads. Setting it as well loads every
      // plugin twice. Windows still needs it — its plugins are in vs-plugins.
      env['XDG_CONFIG_HOME'] = path.join(_depsDir!, 'config');

      final paths = <String>[];
      if (await bundledPython.exists()) {
        paths.add(path.join(_depsDir!, 'python', 'bin'));
      }
      paths.add(path.join(_depsDir!, 'vapoursynth'));
      paths.add(path.join(_depsDir!, 'ffmpeg'));
      env['PATH'] = '${paths.join(':')}:${env['PATH'] ?? ''}';

      // Include both vapoursynth and python/lib for DYLD_LIBRARY_PATH
      // (matches Rust worker's build_environment)
      final dyldPaths = [
        path.join(_depsDir!, 'vapoursynth'),
        path.join(_depsDir!, 'python', 'lib'),
      ];
      final existingDyld = env['DYLD_LIBRARY_PATH'] ?? '';
      env['DYLD_LIBRARY_PATH'] = existingDyld.isEmpty
          ? dyldPaths.join(':')
          : '${dyldPaths.join(':')}:$existingDyld';
    } else if (Platform.isLinux) {
      final bundledPython = Directory(path.join(_depsDir!, 'python'));
      if (await bundledPython.exists()) {
        env['PYTHONHOME'] = path.join(_depsDir!, 'python');
      }

      // The platform dir carries the R78 `vapoursynth` package (libs, vsscript
      // and the extension module), so it must be importable: vsscript's config
      // is keyed by the libvsscript path the module reports, and that has to be
      // the same file vspipe-bin loads.
      env['PYTHONPATH'] =
          [_depsDir!, path.join(_depsDir!, 'python-packages')].join(':');
      env['PYTHONNOUSERSITE'] = '1';
      // No VAPOURSYNTH_EXTRA_PLUGIN_PATH here: the plugins sit at
      // <libdir>/plugins, which R78 autoloads. Setting it as well loads every
      // plugin twice. Windows still needs it — its plugins are in vs-plugins.
      env['XDG_CONFIG_HOME'] = path.join(_depsDir!, 'config');

      final paths = <String>[];
      if (await bundledPython.exists()) {
        paths.add(path.join(_depsDir!, 'python', 'bin'));
      }
      paths.add(path.join(_depsDir!, 'vapoursynth'));
      paths.add(path.join(_depsDir!, 'ffmpeg'));
      env['PATH'] = '${paths.join(':')}:${env['PATH'] ?? ''}';

      // LD_LIBRARY_PATH for VapourSynth, Python, and extra libs
      final ldPaths = [
        path.join(_depsDir!, 'vapoursynth'),
        path.join(_depsDir!, 'python', 'lib'),
        path.join(_depsDir!, 'lib'),
      ];
      final existingLd = env['LD_LIBRARY_PATH'] ?? '';
      env['LD_LIBRARY_PATH'] = existingLd.isEmpty
          ? ldPaths.join(':')
          : '${ldPaths.join(':')}:$existingLd';
    }

    return env;
  }
}
