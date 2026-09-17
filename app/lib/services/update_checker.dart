import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rhttp/rhttp.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Information about an available update.
class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String releaseUrl;
  final String? releaseNotes;
  final DateTime? publishedAt;

  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUrl,
    this.releaseNotes,
    this.publishedAt,
  });

  bool get isUpdateAvailable => _compareVersions(latestVersion, currentVersion) > 0;
}

/// One entry in the app's release history, for the Settings "Changes" tab.
///
/// Deliberately lightweight — no `body` here. The releases list endpoint does
/// return each release's full body, but fetching every past release's notes
/// just to populate a sidebar of version numbers is wasted bandwidth against
/// GitHub's rate limit; [UpdateChecker.fetchReleaseNotes] pulls a given
/// version's notes only once the user actually selects it.
class AppRelease {
  /// The raw GitHub tag, e.g. `"v1.2.0"`.
  final String tagName;

  /// [tagName] with the leading `v` stripped, e.g. `"1.2.0"` — comparable
  /// against [WhatsNewService.isNew] and `pubspec.yaml`'s version.
  final String version;

  /// The release's title, if it has one distinct from the tag.
  final String? name;

  final String htmlUrl;
  final DateTime? publishedAt;

  const AppRelease({
    required this.tagName,
    required this.version,
    this.name,
    required this.htmlUrl,
    this.publishedAt,
  });
}

/// Service for checking GitHub releases for updates, and for browsing the
/// app's full release history (Settings → Changes).
class UpdateChecker {
  static const _prefsKeyCheckForUpdates = 'check_for_updates';
  static const _githubRepo = 'StuartCameronCode/VapourBox';
  static const _apiBase = 'https://api.github.com/repos/$_githubRepo';
  static const _apiUrl = '$_apiBase/releases/latest';

  /// App release tags only — `vX.Y.Z` exactly. The repo also carries
  /// `deps-vX.Y.Z` and `whisper-vX.Y.Z` tags for its two other release
  /// trains, which must not show up as app versions.
  static final RegExp _appVersionTag = RegExp(r'^v\d+\.\d+\.\d+$');

  static UpdateChecker? _instance;
  static UpdateChecker get instance => _instance ??= UpdateChecker._();

  UpdateChecker._();

  /// Whether update checks are enabled.
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKeyCheckForUpdates) ?? true; // Default to enabled
  }

  /// Enable or disable update checks.
  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKeyCheckForUpdates, enabled);
  }

  /// Check for updates from GitHub releases.
  /// Returns null if no update is available or if check fails.
  Future<UpdateInfo?> checkForUpdates() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final json = await _getJson(_apiUrl);
      if (json is! Map<String, dynamic>) return null;

      final tagName = json['tag_name'] as String?;
      final htmlUrl = json['html_url'] as String?;
      final body = json['body'] as String?;
      final publishedAtStr = json['published_at'] as String?;

      if (tagName == null || htmlUrl == null) {
        debugPrint('UpdateChecker: Invalid response from GitHub API');
        return null;
      }

      // Parse version from tag (remove 'v' prefix if present)
      final latestVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;

      final updateInfo = UpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        releaseUrl: htmlUrl,
        releaseNotes: body,
        publishedAt: publishedAtStr != null ? DateTime.tryParse(publishedAtStr) : null,
      );

      if (updateInfo.isUpdateAvailable) {
        debugPrint('UpdateChecker: Update available: $currentVersion -> $latestVersion');
        return updateInfo;
      } else {
        debugPrint('UpdateChecker: No update available (current: $currentVersion, latest: $latestVersion)');
        return null;
      }
    } catch (e) {
      debugPrint('UpdateChecker: Error checking for updates: $e');
      return null;
    }
  }

  /// The app's full release history, newest first, for Settings → Changes.
  /// Returns null on failure (network, rate limit, malformed response) so the
  /// caller can distinguish "couldn't load" from "no releases exist".
  Future<List<AppRelease>?> listReleases() async {
    try {
      final json = await _getJson('$_apiBase/releases?per_page=100');
      if (json is! List) return null;

      final releases = <AppRelease>[];
      for (final entry in json) {
        if (entry is! Map) continue;
        final tagName = entry['tag_name'] as String?;
        final htmlUrl = entry['html_url'] as String?;
        if (tagName == null || htmlUrl == null) continue;
        if (!_appVersionTag.hasMatch(tagName)) continue;
        if (entry['draft'] == true || entry['prerelease'] == true) continue;

        final publishedAtStr = entry['published_at'] as String?;
        releases.add(AppRelease(
          tagName: tagName,
          version: tagName.substring(1),
          name: entry['name'] as String?,
          htmlUrl: htmlUrl,
          publishedAt: publishedAtStr != null ? DateTime.tryParse(publishedAtStr) : null,
        ));
      }
      return releases;
    } catch (e) {
      debugPrint('UpdateChecker: Error listing releases: $e');
      return null;
    }
  }

  /// A single release's notes, fetched lazily — only called once the user
  /// actually selects that version in the Changes tab. Returns null on
  /// failure or when the release has no body.
  Future<String?> fetchReleaseNotes(String tagName) async {
    try {
      final json = await _getJson('$_apiBase/releases/tags/$tagName');
      if (json is! Map<String, dynamic>) return null;
      final body = json['body'] as String?;
      return (body == null || body.trim().isEmpty) ? null : body;
    } catch (e) {
      debugPrint('UpdateChecker: Error fetching release notes for $tagName: $e');
      return null;
    }
  }

  /// GET a GitHub API URL and decode the JSON body. Returns null on any
  /// non-200 response or transport failure — every caller here treats that
  /// the same way (fail soft, nothing loads), so the error handling lives
  /// once rather than once per endpoint.
  Future<dynamic> _getJson(String url) async {
    try {
      final client = await RhttpClient.create(
        settings: const ClientSettings(throwOnStatusCode: false),
      );
      try {
        final response = await client.get(
          url,
          headers: HttpHeaders.rawMap({
            'User-Agent': 'VapourBox-UpdateChecker/1.0',
            'Accept': 'application/vnd.github.v3+json',
          }),
        );
        if (response.statusCode != 200) {
          debugPrint('UpdateChecker: GitHub API returned ${response.statusCode} for $url');
          return null;
        }
        return jsonDecode(response.body);
      } finally {
        client.dispose();
      }
    } catch (e) {
      debugPrint('UpdateChecker: request to $url failed: $e');
      return null;
    }
  }
}

/// Compare two semantic version strings.
/// Returns positive if v1 > v2, negative if v1 < v2, zero if equal.
int _compareVersions(String v1, String v2) {
  final parts1 = v1.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final parts2 = v2.split('.').map((p) => int.tryParse(p) ?? 0).toList();

  // Pad shorter version with zeros
  while (parts1.length < parts2.length) {
    parts1.add(0);
  }
  while (parts2.length < parts1.length) {
    parts2.add(0);
  }

  for (var i = 0; i < parts1.length; i++) {
    if (parts1[i] > parts2[i]) return 1;
    if (parts1[i] < parts2[i]) return -1;
  }

  return 0;
}
