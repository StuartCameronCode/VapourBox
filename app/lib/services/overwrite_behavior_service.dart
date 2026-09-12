import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// What VapourBox should do when a job's output file already exists on disk
/// (issue #85).
enum OverwriteBehavior {
  /// Show [OverwriteWarningDialog] and let the user decide each time.
  ask,

  /// Overwrite the existing file without asking.
  overwrite,

  /// Write to a new, non-colliding filename instead of touching the existing
  /// file.
  rename;

  static OverwriteBehavior fromName(String? name) {
    return OverwriteBehavior.values.firstWhere(
      (behavior) => behavior.name == name,
      orElse: () => OverwriteBehavior.ask,
    );
  }

  String get label {
    switch (this) {
      case OverwriteBehavior.ask:
        return 'Ask every time';
      case OverwriteBehavior.overwrite:
        return 'Overwrite';
      case OverwriteBehavior.rename:
        return 'Rename the new file';
    }
  }

  String get description {
    switch (this) {
      case OverwriteBehavior.ask:
        return 'Show a warning and let you choose before each job starts';
      case OverwriteBehavior.overwrite:
        return 'Replace the existing file without asking';
      case OverwriteBehavior.rename:
        return 'Keep the existing file and add a number to the new one';
    }
  }
}

/// Default action for output files that already exist, configurable in
/// Settings -> General. Defaults to [OverwriteBehavior.ask], which preserves
/// the previous (only) behavior of always showing
/// `OverwriteWarningDialog`.
class OverwriteBehaviorService {
  static final OverwriteBehaviorService instance =
      OverwriteBehaviorService._();
  OverwriteBehaviorService._();

  static const String _prefsKey = 'overwriteBehavior';

  OverwriteBehavior _behavior = OverwriteBehavior.ask;
  bool _loaded = false;

  OverwriteBehavior get behavior => _behavior;

  /// Load the saved choice. Safe to call again; only the first call reads
  /// storage.
  Future<void> initialize() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _behavior = OverwriteBehavior.fromName(prefs.getString(_prefsKey));
    } catch (_) {
      // Unreadable preferences shouldn't stop the app starting - asking is
      // the safe default to fall back to.
      _behavior = OverwriteBehavior.ask;
    }
    _loaded = true;
  }

  Future<void> setBehavior(OverwriteBehavior value) async {
    _behavior = value;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, value.name);
    } catch (_) {
      // Keep the in-memory choice for this session even if it can't be saved.
    }
  }

  /// Returns [path] unchanged if nothing exists there yet, otherwise the
  /// first `name (2).ext`, `name (3).ext`, ... that doesn't.
  Future<String> uniquePath(String path) async {
    if (!await File(path).exists()) return path;

    final separator = path.lastIndexOf(RegExp(r'[\\/]'));
    final dir = separator >= 0 ? path.substring(0, separator + 1) : '';
    final name = separator >= 0 ? path.substring(separator + 1) : path;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';

    var counter = 2;
    while (true) {
      final candidate = '$dir$stem ($counter)$ext';
      if (!await File(candidate).exists()) return candidate;
      counter++;
    }
  }
}
