import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decides whether a schema element tagged with `sinceAppVersion` (on
/// [FilterSchema] or [ParameterDefinition]) should show a "NEW" badge.
///
/// The rule: something is new if it was added in a version released *after*
/// the last version the user actually updated **from** — and it stays
/// flagged as new across every launch of the current version, only moving
/// forward the next time the app itself updates. That needs two separate
/// pieces of stored state, not one:
///
/// - `lastRunAppVersion` — whatever version ran last launch, checked on
///   every launch purely to detect the *moment* an update happened.
/// - `lastSeenAppVersion` — the actual comparison baseline used by [isNew].
///   It only advances at that moment, to the version being left behind, and
///   is otherwise left untouched — which is what makes badges survive many
///   launches of the same version instead of clearing after one.
///
/// A fresh install (or an upgrade from a build that predates this tracking,
/// which looks the same — no `lastRunAppVersion` stored yet) flags nothing as
/// new: both markers are seeded to the current version, so there's no earlier
/// baseline to diff against yet.
class WhatsNewService {
  static final WhatsNewService instance = WhatsNewService._();
  WhatsNewService._();

  static const String _baselineKey = 'lastSeenAppVersion';
  static const String _lastRunVersionKey = 'lastRunAppVersion';

  /// The comparison baseline for this session — the version the user last
  /// updated from, held steady until the next real update. Null when there's
  /// nothing to compare against yet.
  String? _lastSeenVersion;
  bool _loaded = false;

  /// Detect whether the app itself changed version since the last launch,
  /// and advance the badge baseline exactly then. Safe to call again; only
  /// the first call touches storage.
  Future<void> initialize() async {
    if (_loaded) return;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final prefs = await SharedPreferences.getInstance();

      final lastRunVersion = prefs.getString(_lastRunVersionKey);
      final storedBaseline = prefs.getString(_baselineKey);

      if (lastRunVersion == null) {
        // Nothing to diff against yet — seed both markers to now.
        _lastSeenVersion = currentVersion;
        await prefs.setString(_baselineKey, currentVersion);
      } else if (lastRunVersion != currentVersion) {
        // The version actually changed since the last launch: this is the
        // one moment the baseline moves, to whatever was running just
        // before — so anything newer than that keeps showing as new on
        // every launch of the new version, until this happens again.
        _lastSeenVersion = lastRunVersion;
        await prefs.setString(_baselineKey, lastRunVersion);
      } else {
        // Same version as last launch — leave the baseline alone so badges
        // persist instead of clearing after a single run.
        _lastSeenVersion = storedBaseline;
      }

      await prefs.setString(_lastRunVersionKey, currentVersion);
    } catch (_) {
      // Version info or storage being unavailable shouldn't stop the app
      // starting — just don't badge anything this session.
      _lastSeenVersion = null;
    }
    _loaded = true;
  }

  /// Whether a property/filter tagged `sinceAppVersion: since` should show a
  /// "NEW" badge right now. False for anything untagged, and false when
  /// there's no baseline yet to compare against.
  bool isNew(String? since) {
    if (since == null || _lastSeenVersion == null) return false;
    return _compareVersions(since, _lastSeenVersion!) > 0;
  }

  /// Reset to the unloaded default. Tests only — the singleton outlives a
  /// single test case otherwise.
  @visibleForTesting
  void resetForTesting() {
    _lastSeenVersion = null;
    _loaded = false;
  }
}

/// Compare two dotted version strings numerically ("1.10.0" > "1.9.0").
/// Returns positive if [a] > [b], negative if [a] < [b], zero if equal.
/// Non-numeric or differing-length components degrade to a component-wise
/// best effort rather than throwing.
int _compareVersions(String a, String b) {
  final partsA = a.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();
  final partsB = b.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();

  final length = partsA.length > partsB.length ? partsA.length : partsB.length;
  for (var i = 0; i < length; i++) {
    final na = i < partsA.length ? partsA[i] : 0;
    final nb = i < partsB.length ? partsB[i] : 0;
    if (na != nb) return na < nb ? -1 : 1;
  }
  return 0;
}
