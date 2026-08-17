import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the filter panels show their advanced controls.
///
/// This is one app-wide setting rather than per-panel state, and that is the
/// point: advanced mode is the lever that keeps the pass list usable as the
/// filter set grows, so it has to be worth hiding things behind. When each
/// panel kept its own flag it reset on every collapse, which meant an expert
/// re-flipped it constantly and nothing could be hidden aggressively enough to
/// matter.
///
/// Two things sit behind it — advanced-only [UiSection]s, and now advanced-only
/// [MethodDefinition]s, so a filter can offer four methods to everyone and
/// sixteen to someone who has asked for them.
///
/// Listeners rebuild on change, so the panels are `Consumer`/`watch` users; the
/// choice is persisted in shared_preferences under `showAdvancedOptions`.
/// Call [initialize] once at startup so the first panel build already has the
/// saved value and doesn't flash from simple to advanced.
class AdvancedModeService extends ChangeNotifier {
  static final AdvancedModeService instance = AdvancedModeService._();
  AdvancedModeService._();

  static const String _prefsKey = 'showAdvancedOptions';

  bool _enabled = false;
  bool _loaded = false;

  /// Whether advanced controls are shown. Defaults to off — the app's audience
  /// arrives with a tape, not a filter preference.
  bool get enabled => _enabled;

  /// Load the saved choice. Safe to call again; only the first call reads
  /// storage.
  Future<void> initialize() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefsKey) ?? false;
    } catch (_) {
      // Unreadable preferences shouldn't stop the app starting, and simple
      // mode is the safe default to fall back to.
      _enabled = false;
    }
    _loaded = true;
  }

  /// Turn advanced controls on or off everywhere, and remember the choice.
  Future<void> setEnabled(bool value) async {
    if (_enabled == value && _loaded) return;

    _enabled = value;
    _loaded = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (_) {
      // Keep the in-memory choice for this session even if it can't be saved.
    }
  }

  /// Reset to the unloaded default. Tests only — the singleton outlives a
  /// single test case otherwise.
  @visibleForTesting
  void resetForTesting() {
    _enabled = false;
    _loaded = false;
  }
}
