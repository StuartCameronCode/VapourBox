import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'addon_manager.dart';
import 'dependency_manager.dart';
import 'whisper_addon_manager.dart';

/// One optional third-party download: something VapourBox can use but does not
/// ship, because of its size or its licence. Shown on Settings → Add-ons and
/// in the prompt a feature raises when it needs one.
class AddonInfo {
  final String id;

  /// What the user knows it by.
  final String name;

  /// The feature that uses it, grouping the Settings list ("Subtitles").
  final String feature;
  final String description;

  /// SPDX-style licence name, and where to read it.
  final String licence;
  final String? licenceUrl;

  /// A restriction the user must be told before downloading, in one sentence
  /// ("Free for non-commercial use only."). Null when the licence has none.
  final String? usageNote;

  /// Who made it, as upstream states it.
  final String credit;

  /// The heading of its entry in `licenses/NOTICES.txt` (and the start of its
  /// About-dialog tile). `addon_service_test.dart` checks that entry states
  /// the same licence and credit as this, so the Settings page cannot drift
  /// from the notices.
  final String noticeName;

  /// Where it comes from.
  final String sourceUrl;

  /// Bytes downloaded to install it on this platform.
  final int downloadBytes;

  /// Add-ons it cannot work without, installed first. Removing one of those
  /// removes this too.
  final List<String> requires;

  /// Why it cannot be used on this platform, or null if it can.
  final String? unavailableReason;

  const AddonInfo({
    required this.id,
    required this.name,
    required this.feature,
    required this.description,
    required this.licence,
    this.licenceUrl,
    this.usageNote,
    required this.credit,
    required this.noticeName,
    required this.sourceUrl,
    required this.downloadBytes,
    this.requires = const [],
    this.unavailableReason,
  });
}

/// How one add-on is installed, recognised and removed under the add-ons
/// directory. Each must install atomically enough that [isInstalled] is never
/// true for a partial install.
abstract class AddonInstaller {
  AddonInfo get info;
  bool isInstalled(Directory addonsDir);
  Future<void> install(Directory addonsDir, AddonManager downloader);
  Future<void> remove(Directory addonsDir);
}

/// Every optional download, in one place: what exists, what is installed,
/// installing (with the add-ons it requires) and removing (with the add-ons
/// that require it). The Settings → Add-ons page and the prompts features
/// raise ([AddonPrompt]) both go through this, so they cannot disagree.
class AddonService extends ChangeNotifier {
  static final AddonService instance = AddonService._();
  AddonService._() : _downloader = AddonManager();

  /// A service over [installers] in [addonsDir], downloading with
  /// [downloader] — for tests.
  @visibleForTesting
  AddonService.forTest({
    required List<AddonInstaller> installers,
    required Directory addonsDir,
    AddonManager? downloader,
  })  : _downloader = downloader ?? AddonManager(),
        _addonsDirOverride = addonsDir {
    _setInstallers(installers);
  }

  final AddonManager _downloader;
  Directory? _addonsDirOverride;
  final Map<String, AddonInstaller> _installers = {};
  final Set<String> _installed = {};
  Future<void>? _loading;
  StreamSubscription<AddonDownloadProgress>? _progressSub;

  /// The add-on being installed now, its progress (0–1, or null while it is
  /// unknown) and status line.
  String? installingId;
  double? progress;
  String status = '';

  void _setInstallers(List<AddonInstaller> installers) {
    _installers
      ..clear()
      ..addEntries(installers.map((i) => MapEntry(i.info.id, i)));
  }

  /// Read the catalogue and check what is installed. Safe to call repeatedly.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (_installers.isEmpty) {
      final platform = DependencyManager.instance.platformId;
      final whisper = WhisperAddonManager(
        jsonDecode(await rootBundle.loadString('assets/whisper-addon.json'))
            as Map<String, dynamic>,
        platform,
      );
      _setInstallers([
        ...whisper.installers(),
        AnimeJanaiInstaller(
          jsonDecode(await rootBundle.loadString('assets/animejanai-addon.json'))
              as Map<String, dynamic>,
          platform,
        ),
      ]);
    }
    await refresh();
  }

  /// Re-check what is installed (the user may have deleted files).
  Future<void> refresh() async {
    final dir = await addonsDir();
    _installed
      ..clear()
      ..addAll(_installers.values.where((i) => i.isInstalled(dir)).map((i) => i.info.id));
    notifyListeners();
  }

  /// Every add-on, in catalogue order.
  List<AddonInfo> get catalog => _installers.values.map((i) => i.info).toList();

  AddonInfo? info(String id) => _installers[id]?.info;

  /// Whether [id] is installed, as of the last [refresh]. False before [load].
  bool isInstalled(String id) => _installed.contains(id);

  /// [ids] and everything they require that is not installed, requirements
  /// first.
  List<String> missing(Iterable<String> ids) {
    final out = <String>[];
    void visit(String id) {
      final installer = _installers[id];
      if (installer == null) throw ArgumentError('Unknown add-on: $id');
      for (final r in installer.info.requires) {
        visit(r);
      }
      if (!isInstalled(id) && !out.contains(id)) out.add(id);
    }

    ids.forEach(visit);
    return out;
  }

  /// Everything installed that would stop working if [id] were removed.
  List<String> dependants(String id) => _installers.values
      .where((i) => i.info.requires.contains(id) && isInstalled(i.info.id))
      .expand((i) => [...dependants(i.info.id), i.info.id])
      .toSet()
      .toList();

  int downloadBytes(Iterable<String> ids) =>
      ids.fold(0, (sum, id) => sum + (_installers[id]?.info.downloadBytes ?? 0));

  /// Install [id] and whatever it requires. Returns false if cancelled;
  /// throws on failure, leaving whatever had finished installed.
  Future<bool> install(String id) async {
    await load();
    if (installingId != null) throw StateError('Already installing $installingId');
    final dir = await addonsDir();
    try {
      for (final next in missing([id])) {
        final installer = _installers[next]!;
        if (installer.info.unavailableReason != null) {
          throw StateError(installer.info.unavailableReason!);
        }
        installingId = next;
        progress = null;
        status = 'Downloading ${installer.info.name}…';
        notifyListeners();
        _progressSub?.cancel();
        _progressSub = _downloader.progressStream.listen((p) {
          progress = p.totalBytes > 0 ? p.progress : null;
          notifyListeners();
        });
        await dir.create(recursive: true);
        await installer.install(dir, _downloader);
        if (_downloader.isCancelled) return false;
        _installed.add(next);
      }
      return true;
    } finally {
      await _progressSub?.cancel();
      _progressSub = null;
      installingId = null;
      progress = null;
      status = '';
      await refresh();
    }
  }

  /// Stop the current download. A partial download is kept for resuming.
  void cancel() => _downloader.cancelDownload();

  /// Remove [id] and everything that requires it.
  Future<void> remove(String id) async {
    final dir = await addonsDir();
    for (final d in [...dependants(id), id]) {
      await _installers[d]!.remove(dir);
    }
    await refresh();
  }

  /// The add-ons directory — the same one the worker reads
  /// (`DependencyLocator::addons_dir`): beside the executable on Windows,
  /// Application Support on macOS, `$XDG_DATA_HOME` on Linux, and in a debug
  /// build the nearest `addons/` above the executable.
  Future<Directory> addonsDir() async {
    final override = _addonsDirOverride;
    if (override != null) return override;
    final appDir = path.dirname(Platform.resolvedExecutable);
    if (kDebugMode) {
      var current = Directory(appDir);
      for (var i = 0; i < 12; i++) {
        final candidate = Directory(path.join(current.path, 'addons'));
        if (await candidate.exists()) return _addonsDirOverride = candidate;
        final parent = current.parent;
        if (parent.path == current.path) break;
        current = parent;
      }
    }
    final home = Platform.environment['HOME'] ?? '/tmp';
    if (Platform.isWindows) return Directory(path.join(appDir, 'addons'));
    if (Platform.isMacOS) {
      return Directory(
          path.join(home, 'Library', 'Application Support', 'VapourBox', 'addons'));
    }
    final dataDir =
        Platform.environment['XDG_DATA_HOME'] ?? path.join(home, '.local', 'share');
    return Directory(path.join(dataDir, 'VapourBox', 'addons'));
  }
}

/// AnimeJaNai's add-on id.
const animeJanaiAddonId = 'animejanai';

/// AnimeJaNai's models (see `worker/src/animejanai.rs`): upstream's
/// models-only zip, pinned by hash in `assets/animejanai-addon.json`, of which
/// only the ONNX models are kept, each checked against its own hash, into
/// `addons/animejanai/`. Built beside it and renamed into place, so a failed
/// or cancelled install never leaves a partial directory the worker would use.
class AnimeJanaiInstaller implements AddonInstaller {
  final Map<String, dynamic> manifest;
  final String platformId;

  AnimeJanaiInstaller(this.manifest, this.platformId);

  static const dirName = 'animejanai';

  /// The platforms that ship VSNCNN, which runs these models
  /// (`gpu_plugin::platform_ships_upscale`).
  static const platforms = {'macos-arm64', 'windows-x64', 'linux-x64'};

  Map<String, String> get _models =>
      (manifest['models'] as Map<String, dynamic>).cast<String, String>();

  @override
  AddonInfo get info {
    final archive = manifest['archive'] as Map<String, dynamic>;
    return AddonInfo(
      id: animeJanaiAddonId,
      name: 'AnimeJaNai upscaling models',
      feature: 'AI upscaling',
      description: 'Real-ESRGAN Compact models trained on HD anime, for Crop & '
          'Resize\'s AnimeJaNai upscaler: the HD V3 models in three sizes, '
          'each with a Sharp variant, and the SD V1 beta model.',
      licence: manifest['licence'] as String,
      licenceUrl: manifest['licenceUrl'] as String?,
      usageNote: 'Free for non-commercial use only.',
      credit: 'the-database (GitHub)',
      noticeName: 'AnimeJaNai models',
      sourceUrl: manifest['homepage'] as String,
      downloadBytes: archive['size'] as int,
      unavailableReason: platforms.contains(platformId)
          ? null
          : 'AnimeJaNai runs on the AI upscaler, which is not available on '
              'this platform.',
    );
  }

  @override
  bool isInstalled(Directory addonsDir) => _models.keys
      .every((m) => File(path.join(addonsDir.path, dirName, m)).existsSync());

  @override
  Future<void> install(Directory addonsDir, AddonManager downloader) async {
    final archive = manifest['archive'] as Map<String, dynamic>;
    final target = Directory(path.join(addonsDir.path, dirName));
    final staging = Directory('${target.path}.new');
    try {
      // Kept in the add-ons directory, not temp, so a cancelled download
      // resumes (AddonManager keeps the .partial beside it).
      final zip = File(path.join(addonsDir.path, '.animejanai-${manifest['version']}.zip'));
      await downloader.downloadFile(archive['url'] as String, zip,
          expectedSize: archive['size'] as int?,
          expectedSha256: archive['sha256'] as String?);
      if (downloader.isCancelled) return;

      if (await staging.exists()) await staging.delete(recursive: true);
      await extractModels(await zip.readAsBytes(), _models, staging);
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
      await zip.delete();
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// Write each of [models] (name → SHA-256) from the zip [zipBytes] into
  /// [into], refusing the lot if one is missing or does not match its hash.
  /// Anything else in the zip (upstream's .pth training checkpoints) is left
  /// out. Shared with the test harness, which installs the real download.
  static Future<void> extractModels(
      List<int> zipBytes, Map<String, String> models, Directory into) async {
    final entries = ZipDecoder().decodeBytes(zipBytes);
    final found = <String, List<int>>{};
    for (final MapEntry(key: name, value: hash) in models.entries) {
      final entry = entries.files.where((f) => f.isFile && path.basename(f.name) == name);
      if (entry.isEmpty) throw StateError('$name is missing from the AnimeJaNai download');
      final bytes = entry.first.content as List<int>;
      final actual = sha256.convert(bytes).toString();
      if (actual != hash) {
        throw StateError('$name does not match its expected hash ($actual)');
      }
      found[name] = bytes;
    }
    await into.create(recursive: true);
    for (final MapEntry(key: name, value: bytes) in found.entries) {
      await File(path.join(into.path, name)).writeAsBytes(bytes);
    }
  }

  @override
  Future<void> remove(Directory addonsDir) async {
    final dir = Directory(path.join(addonsDir.path, dirName));
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
