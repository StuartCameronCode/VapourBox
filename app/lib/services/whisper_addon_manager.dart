import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

import 'addon_manager.dart';
import 'addon_service.dart';
import 'temp_directory_service.dart';

/// The Whisper add-on, for subtitle generation: the whisper.cpp engine and its
/// language models, described by `assets/whisper-addon.json`, under
/// `addons/whisper/`. Each is an [AddonInstaller] for [AddonService]; every
/// model requires the engine.
class WhisperAddonManager {
  final Map<String, dynamic> metadata;
  final String platformId;

  WhisperAddonManager(this.metadata, this.platformId);

  static const dirName = 'whisper';

  /// The add-on id of a language model (`small`, `medium`, `large-v3-turbo`).
  static String modelAddonId(String modelId) => 'whisper-model-$modelId';

  static const engineAddonId = 'whisper';

  List<AddonInstaller> installers() => [
        _WhisperEngine(this),
        for (final id in (metadata['models'] as Map<String, dynamic>).keys)
          _WhisperModel(this, id),
      ];

  Map<String, dynamic> get _platformInfo =>
      ((metadata['binary'] as Map<String, dynamic>)['platforms']
          as Map<String, dynamic>)[platformId] as Map<String, dynamic>;
}

const _whisperCppCredit =
    'The ggml authors (project started by Georgi Gerganov)';

class _WhisperEngine implements AddonInstaller {
  final WhisperAddonManager whisper;
  _WhisperEngine(this.whisper);

  @override
  AddonInfo get info => AddonInfo(
        id: WhisperAddonManager.engineAddonId,
        name: 'Whisper speech recognition (whisper.cpp)',
        feature: 'Subtitles',
        description: 'The engine that transcribes speech for the Subtitles '
            'pass. Needs one of the language models below.',
        licence: 'MIT',
        credit: _whisperCppCredit,
        noticeName: 'whisper.cpp',
        sourceUrl: 'https://github.com/ggml-org/whisper.cpp',
        downloadBytes: whisper._platformInfo['size'] as int? ?? 0,
      );

  /// macOS/Linux: whisper/bin/whisper-cli (with lib/ beside bin/ on macOS);
  /// Windows: whisper/whisper-cli.exe — what `DependencyLocator::whisper_path`
  /// looks for.
  static String binaryPath(Directory addonsDir) {
    final dir = path.join(addonsDir.path, WhisperAddonManager.dirName);
    return Platform.isWindows
        ? path.join(dir, 'whisper-cli.exe')
        : path.join(dir, 'bin', 'whisper-cli');
  }

  @override
  bool isInstalled(Directory addonsDir) => File(binaryPath(addonsDir)).existsSync();

  @override
  Future<void> install(Directory addonsDir, AddonManager downloader) async {
    final info = whisper._platformInfo;
    final url = info['url'] as String;
    final exeName = info['executable'] as String;
    final format = info['format'] as String? ?? 'zip';
    final whisperDir = Directory(path.join(addonsDir.path, WhisperAddonManager.dirName));
    await whisperDir.create(recursive: true);

    final tempDir = await TempDirectoryService.instance.createTemp('vapourbox_whisper_');
    final tempFile = File(path.join(tempDir.path,
        (format == 'homebrew-bottle' || format == 'tar') ? 'whisper.tar.gz' : 'whisper.zip'));
    try {
      // ghcr.io requires a bearer token (public, anonymous access)
      final extraHeaders =
          url.contains('ghcr.io') ? {'Authorization': 'Bearer QQ=='} : null;
      await downloader.downloadFile(url, tempFile,
          expectedSize: info['size'] as int?,
          expectedSha256: info['sha256'] as String?,
          extraHeaders: extraHeaders);
      if (downloader.isCancelled) return;

      if (format == 'homebrew-bottle') {
        // Bottle layout: whisper-cpp/<version>/{bin,lib}/ — keep bin/ and lib/
        // side by side so @rpath (@loader_path/../lib) resolves.
        await _untar(tempFile, whisperDir, stripComponents: 2);
      } else if (format == 'tar') {
        // A static bin/whisper-cli, nothing to strip.
        await _untar(tempFile, whisperDir);
      } else {
        await _extractZip(tempFile, whisperDir, exeName);
      }

      if (Platform.isMacOS) {
        // Remove quarantine, and ad-hoc sign every binary and dylib.
        await Process.run('xattr', ['-cr', whisperDir.path]);
        for (final sub in ['bin', 'lib']) {
          final dir = Directory(path.join(whisperDir.path, sub));
          if (!await dir.exists()) continue;
          await for (final entity in dir.list()) {
            if (entity is File && (sub == 'bin' || entity.path.endsWith('.dylib'))) {
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

  Future<void> _untar(File tarGz, Directory whisperDir, {int stripComponents = 0}) async {
    final result = await Process.run('tar', [
      'xzf', tarGz.path,
      '-C', whisperDir.path,
      if (stripComponents > 0) ...['--strip-components', '$stripComponents'],
    ]);
    if (result.exitCode != 0) {
      throw StateError('Failed to extract whisper: ${result.stderr}');
    }
    final binDir = Directory(path.join(whisperDir.path, 'bin'));
    if (await binDir.exists()) {
      await for (final entity in binDir.list()) {
        if (entity is File) await Process.run('chmod', ['+x', entity.path]);
      }
    }
  }

  /// The Windows release zip: keep the executable and its DLLs, flattened.
  Future<void> _extractZip(File zipFile, Directory whisperDir, String exeName) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    for (final file in archive) {
      if (!file.isFile) continue;
      final fileName = path.basename(file.name);
      if (fileName == exeName || fileName.endsWith('.dll') || fileName.endsWith('.dylib')) {
        await File(path.join(whisperDir.path, fileName))
            .writeAsBytes(file.content as List<int>);
      }
    }
  }

  /// The engine and everything beside it except the models, which are
  /// removed as dependants first.
  @override
  Future<void> remove(Directory addonsDir) async {
    final dir = Directory(path.join(addonsDir.path, WhisperAddonManager.dirName));
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (path.basename(entity.path) != 'models') await entity.delete(recursive: true);
    }
  }
}

class _WhisperModel implements AddonInstaller {
  final WhisperAddonManager whisper;
  final String modelId;
  _WhisperModel(this.whisper, this.modelId);

  Map<String, dynamic> get _model =>
      (whisper.metadata['models'] as Map<String, dynamic>)[modelId] as Map<String, dynamic>;

  static const _labels = {
    'small': 'Small (fastest)',
    'medium': 'Medium',
    'large-v3-turbo': 'Large v3 Turbo (most accurate)',
  };

  @override
  AddonInfo get info => AddonInfo(
        id: WhisperAddonManager.modelAddonId(modelId),
        name: 'Whisper language model — ${_labels[modelId] ?? modelId}',
        feature: 'Subtitles',
        description: 'OpenAI\'s Whisper model in whisper.cpp\'s format, chosen '
            'in the Subtitles pass. Larger models are slower and more accurate.',
        licence: 'MIT',
        credit: 'OpenAI',
        noticeName: 'Whisper models',
        sourceUrl: 'https://huggingface.co/ggerganov/whisper.cpp',
        downloadBytes: _model['size'] as int? ?? 0,
        requires: const [WhisperAddonManager.engineAddonId],
      );

  File _file(Directory addonsDir) => File(path.join(addonsDir.path,
      WhisperAddonManager.dirName, 'models', _model['filename'] as String));

  @override
  bool isInstalled(Directory addonsDir) => _file(addonsDir).existsSync();

  @override
  Future<void> install(Directory addonsDir, AddonManager downloader) async {
    final file = _file(addonsDir);
    await file.parent.create(recursive: true);
    await downloader.downloadFile(_model['url'] as String, file,
        expectedSize: _model['size'] as int?);
  }

  @override
  Future<void> remove(Directory addonsDir) async {
    final file = _file(addonsDir);
    if (await file.exists()) await file.delete();
  }
}
