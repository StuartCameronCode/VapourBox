import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'addon_manager.dart';

/// Manages Whisper add-on binary and model downloads.
class WhisperAddonManager {
  static final WhisperAddonManager instance = WhisperAddonManager._();
  WhisperAddonManager._();

  final AddonManager _addonManager = AddonManager();
  Map<String, dynamic>? _metadata;

  /// Stream of download progress updates.
  Stream<AddonDownloadProgress> get progressStream => _addonManager.progressStream;

  /// Load metadata from bundled asset.
  Future<Map<String, dynamic>> _getMetadata() async {
    if (_metadata != null) return _metadata!;
    final jsonString = await rootBundle.loadString('assets/whisper-addon.json');
    _metadata = jsonDecode(jsonString) as Map<String, dynamic>;
    return _metadata!;
  }

  /// Get the current platform identifier.
  String get _platformId {
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isMacOS) {
      final result = Process.runSync('uname', ['-m']);
      final arch = result.stdout.toString().trim();
      return arch == 'arm64' ? 'macos-arm64' : 'macos-x64';
    }
    throw UnsupportedError('Unsupported platform');
  }

  /// Get the whisper add-on directory.
  Future<Directory> getWhisperDir() async {
    final base = await _getAddonsBaseDir();
    return Directory(path.join(base.path, 'whisper'));
  }

  /// Get the add-ons base directory, mirroring deps directory location strategy.
  Future<Directory> _getAddonsBaseDir() async {
    final executablePath = Platform.resolvedExecutable;
    final appDir = path.dirname(executablePath);

    if (Platform.isWindows) {
      // Production: addons folder next to executable
      final prodAddons = Directory(path.join(appDir, 'addons'));
      if (kDebugMode) {
        // Development: search upward for project addons
        var current = Directory(appDir);
        for (var i = 0; i < 10; i++) {
          final addonsDir = Directory(path.join(current.path, 'addons'));
          if (await addonsDir.exists()) {
            return addonsDir;
          }
          final parent = current.parent;
          if (parent.path == current.path) break;
          current = parent;
        }
      }
      return prodAddons;
    } else if (Platform.isMacOS) {
      if (kDebugMode) {
        // Development: search upward for project addons
        var current = Directory(appDir);
        for (var i = 0; i < 12; i++) {
          final addonsDir = Directory(path.join(current.path, 'addons'));
          if (await addonsDir.exists()) {
            return addonsDir;
          }
          final parent = current.parent;
          if (parent.path == current.path) break;
          current = parent;
        }
      }

      // Production: Application Support
      final home = Platform.environment['HOME'] ?? '/tmp';
      return Directory(path.join(
        home, 'Library', 'Application Support', 'VapourBox', 'addons',
      ));
    }

    throw UnsupportedError('Unsupported platform');
  }

  /// Whether the whisper binary is installed.
  Future<bool> get isInstalled async {
    final binaryPath = await whisperBinaryPath;
    return File(binaryPath).existsSync();
  }

  /// Whether a specific model is installed.
  Future<bool> isModelInstalled(String modelId) async {
    final whisperDir = await getWhisperDir();
    return File(path.join(whisperDir.path, 'models', 'ggml-$modelId.bin')).existsSync();
  }

  /// Get path to the whisper binary.
  ///
  /// macOS: whisper/bin/whisper-cli (Homebrew bottle layout with lib/ sibling)
  /// Windows: whisper/whisper-cli.exe (flat zip layout)
  Future<String> get whisperBinaryPath async {
    final whisperDir = await getWhisperDir();
    if (Platform.isWindows) {
      return path.join(whisperDir.path, 'whisper-cli.exe');
    }
    return path.join(whisperDir.path, 'bin', 'whisper-cli');
  }

  /// Get path to a model file.
  Future<String> getModelPath(String modelId) async {
    final whisperDir = await getWhisperDir();
    return path.join(whisperDir.path, 'models', 'ggml-$modelId.bin');
  }

  /// Download and install the whisper binary.
  Future<void> downloadBinary() async {
    final metadata = await _getMetadata();
    final binaryInfo = metadata['binary'] as Map<String, dynamic>;
    final platforms = binaryInfo['platforms'] as Map<String, dynamic>;
    final platformInfo = platforms[_platformId] as Map<String, dynamic>;

    final url = platformInfo['url'] as String;
    final exeName = platformInfo['executable'] as String;
    final expectedSize = platformInfo['size'] as int?;
    final format = platformInfo['format'] as String? ?? 'zip';

    final whisperDir = await getWhisperDir();
    await whisperDir.create(recursive: true);

    final tempDir = await Directory.systemTemp.createTemp('vapourbox_whisper_');
    final tempFile = File(path.join(tempDir.path,
        format == 'homebrew-bottle' ? 'whisper.tar.gz' : 'whisper.zip'));

    try {
      // ghcr.io requires a bearer token (public, anonymous access)
      Map<String, String>? extraHeaders;
      if (url.contains('ghcr.io')) {
        extraHeaders = {'Authorization': 'Bearer QQ=='};
      }

      await _addonManager.downloadFile(url, tempFile,
          expectedSize: expectedSize, extraHeaders: extraHeaders);

      if (_addonManager.isCancelled) return;

      if (format == 'homebrew-bottle') {
        await _extractHomebrewBottle(tempFile, whisperDir, exeName);
      } else {
        await _extractZip(tempFile, whisperDir, exeName);
      }

      // On macOS, remove quarantine and codesign all binaries/dylibs
      if (Platform.isMacOS) {
        await Process.run('xattr', ['-cr', whisperDir.path]);
        // Sign all Mach-O binaries and dylibs
        final binDir = Directory(path.join(whisperDir.path, 'bin'));
        if (await binDir.exists()) {
          await for (final entity in binDir.list()) {
            if (entity is File) {
              await Process.run('codesign', ['--force', '--sign', '-', entity.path]);
            }
          }
        }
        final libDir = Directory(path.join(whisperDir.path, 'lib'));
        if (await libDir.exists()) {
          await for (final entity in libDir.list()) {
            if (entity is File && entity.path.endsWith('.dylib')) {
              await Process.run('codesign', ['--force', '--sign', '-', entity.path]);
            }
          }
        }
      }
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Extract a Homebrew bottle (tar.gz) into the whisper directory.
  ///
  /// Bottle structure: whisper-cpp/<version>/bin/whisper-cli
  ///                   whisper-cpp/<version>/lib/*.dylib
  /// We extract bin/ and lib/ into whisperDir, preserving the subdirectory structure
  /// so that @rpath (@loader_path/../lib) resolves correctly.
  Future<void> _extractHomebrewBottle(
      File tarGz, Directory whisperDir, String exeName) async {
    // Use system tar to extract (handles gzip + tar in one step)
    final result = await Process.run('tar', [
      'xzf', tarGz.path,
      '-C', whisperDir.path,
      '--strip-components', '2', // Strip whisper-cpp/<version>/ prefix
    ]);
    if (result.exitCode != 0) {
      throw StateError('Failed to extract bottle: ${result.stderr}');
    }

    // Set executable permissions on extracted binaries
    final binDir = Directory(path.join(whisperDir.path, 'bin'));
    if (await binDir.exists()) {
      await for (final entity in binDir.list()) {
        if (entity is File) {
          await Process.run('chmod', ['+x', entity.path]);
        }
      }
    }
  }

  /// Extract a zip archive (Windows binary release).
  Future<void> _extractZip(
      File zipFile, Directory whisperDir, String exeName) async {
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    for (final file in archive) {
      if (file.isFile) {
        final fileName = path.basename(file.name);
        if (fileName == exeName || fileName.endsWith('.dll') || fileName.endsWith('.dylib')) {
          final outFile = File(path.join(whisperDir.path, fileName));
          await outFile.writeAsBytes(file.content as List<int>);
        }
      }
    }
  }

  /// Download a whisper model.
  Future<void> downloadModel(String modelId) async {
    final metadata = await _getMetadata();
    final models = metadata['models'] as Map<String, dynamic>;
    final modelInfo = models[modelId] as Map<String, dynamic>;

    final url = modelInfo['url'] as String;
    final filename = modelInfo['filename'] as String;
    final expectedSize = modelInfo['size'] as int?;

    final whisperDir = await getWhisperDir();
    final modelsDir = Directory(path.join(whisperDir.path, 'models'));
    await modelsDir.create(recursive: true);

    final destination = File(path.join(modelsDir.path, filename));
    await _addonManager.downloadFile(url, destination, expectedSize: expectedSize);
  }

  /// Cancel the current download (preserves partial file for resume).
  void cancelDownload() {
    _addonManager.cancelDownload();
  }

  /// Whether the current download was cancelled.
  bool get isCancelled => _addonManager.isCancelled;

  /// Get the total download size for binary + model.
  Future<int> getDownloadSize(String modelId) async {
    final metadata = await _getMetadata();
    final binaryInfo = metadata['binary'] as Map<String, dynamic>;
    final platforms = binaryInfo['platforms'] as Map<String, dynamic>;
    final platformInfo = platforms[_platformId] as Map<String, dynamic>;
    final binarySize = platformInfo['size'] as int? ?? 0;

    final models = metadata['models'] as Map<String, dynamic>;
    final modelInfo = models[modelId] as Map<String, dynamic>;
    final modelSize = modelInfo['size'] as int? ?? 0;

    return binarySize + modelSize;
  }

  void dispose() {
    _addonManager.dispose();
  }
}
