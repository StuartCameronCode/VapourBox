import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/encoding_settings.dart';

/// The output and encoding settings (codec, container, quality, audio, colour
/// format, output folder, filename pattern, custom arguments …), remembered
/// between launches (issue #264).
///
/// They used to live only in `MainViewModel`'s memory, so every launch
/// started from `const EncodingSettings()` and a chosen folder or codec was
/// lost on restart. Stored as `EncodingSettings.toJson()` in
/// shared_preferences under `encodingSettings`, written by the view model on
/// every change (`updateEncodingSettings`, `loadPreset`). Every field is kept,
/// custom FFmpeg arguments and custom VapourSynth included (the user's
/// decision in task #135).
///
/// Call [initialize] once at startup, before the view model is created, so it
/// starts from the saved settings.
class EncodingSettingsStore {
  static final EncodingSettingsStore instance = EncodingSettingsStore._();
  EncodingSettingsStore._();

  static const String prefsKey = 'encodingSettings';

  EncodingSettings _initial = const EncodingSettings();
  bool _loaded = false;

  /// The settings saved by the last session, or the defaults when there are
  /// none, they can't be read, or [initialize] hasn't run.
  EncodingSettings get initial => _initial;

  /// Load the saved settings. Safe to call again; only the first call reads
  /// storage. Never throws: unreadable or unrecognised settings (corrupt
  /// JSON, a codec a newer version saved) fall back to the defaults rather
  /// than stop the app starting.
  Future<void> initialize() async {
    if (_loaded) return;
    _initial = const EncodingSettings();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) _initial = decode(raw);
    } catch (_) {
      // Defaults.
    }
    _loaded = true;
  }

  /// [raw] as settings, or the defaults if it is not a valid saved value.
  static EncodingSettings decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return EncodingSettings.fromJson(json);
    } catch (_) {
      // Fall through to the defaults.
    }
    return const EncodingSettings();
  }

  /// Remember [settings] for the next launch. A failure to write keeps the
  /// in-memory settings for this session and is otherwise ignored.
  ///
  /// [initial] is left alone: it is what this session started from, read
  /// once at startup.
  Future<void> save(EncodingSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(settings.toJson()));
    } catch (_) {
      // Keep the in-memory settings for this session.
    }
  }

  /// Reset to the unloaded default. Tests only — the singleton outlives a
  /// single test case otherwise.
  @visibleForTesting
  void resetForTesting() {
    _initial = const EncodingSettings();
    _loaded = false;
  }
}
