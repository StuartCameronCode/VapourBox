import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Where VapourBox puts its scratch files — generated `.vpy` scripts, job
/// config JSON, preview frames, progress files and extracted DVD titles.
///
/// The system temp directory is the default. A user whose system temp lives on
/// a small or slow volume (or a RAM disk that can't hold a DVD rip) can point
/// this elsewhere; [setOverride] with null goes back to the system default.
///
/// The worker and the tools it spawns pick this up through `TMPDIR`/`TMP`/
/// `TEMP`, which [ToolLocator.workerEnvironment] sets from [effectivePath] —
/// that's what redirects the Rust side's `env::temp_dir()` calls, so there is
/// no separate path to keep in sync.
class TempDirectoryService {
  static final TempDirectoryService instance = TempDirectoryService._();
  TempDirectoryService._();

  static const String _prefsKey = 'tempDirectoryOverride';

  String? _override;
  bool _loaded = false;

  /// The user's chosen directory, or null when using the system default.
  String? get override => _override;

  /// The system temp directory, shown in the UI as the default.
  String get systemDefault => Directory.systemTemp.path;

  /// Directory scratch files should go in: the override when set, otherwise
  /// the system temp directory.
  String get effectivePath => _override ?? systemDefault;

  /// Load the saved override. Call once at startup, before anything writes a
  /// temp file. Safe to call again; only the first call reads storage.
  Future<void> initialize() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefsKey);
      _override = (stored != null && stored.isNotEmpty) ? stored : null;
    } catch (_) {
      // Unreadable preferences shouldn't stop the app starting — the system
      // default is a working fallback.
      _override = null;
    }
    _loaded = true;
  }

  /// Set the override directory, or pass null to go back to the system
  /// default. Throws if the directory can't be created or written to, so the
  /// caller can report it rather than storing a path that fails at job time.
  Future<void> setOverride(String? directory) async {
    final trimmed = directory?.trim();
    final value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;

    if (value != null) {
      await _verifyWritable(Directory(value));
    }

    _override = value;
    _loaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, value);
      }
    } catch (_) {
      // Keep the in-memory choice for this session even if it can't be saved.
    }
  }

  /// The directory to write into, created if missing.
  ///
  /// Falls back to the system temp directory if the override has become
  /// unusable — an external drive unplugged since it was chosen, say. A job
  /// running in the wrong temp directory beats a job that can't run at all.
  Future<Directory> resolve() async {
    final chosen = Directory(effectivePath);
    try {
      if (!await chosen.exists()) {
        await chosen.create(recursive: true);
      }
      return chosen;
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  /// Creates a uniquely-named directory under [resolve], like
  /// `Directory.systemTemp.createTemp`.
  Future<Directory> createTemp(String prefix) async {
    final parent = await resolve();
    return parent.createTemp(prefix);
  }

  /// Builds a path for a scratch file inside the temp directory, creating the
  /// directory if needed.
  Future<String> filePath(String filename) async {
    final dir = await resolve();
    return '${dir.path}${Platform.pathSeparator}$filename';
  }

  /// Throws if [dir] can't be created or written to.
  Future<void> _verifyWritable(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // Existence isn't enough — a read-only volume passes that and then fails
    // at job time, which is far harder to diagnose.
    final probe = File(
      '${dir.path}${Platform.pathSeparator}.vapourbox_write_test_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await probe.writeAsString('');
    await probe.delete();
  }
}
