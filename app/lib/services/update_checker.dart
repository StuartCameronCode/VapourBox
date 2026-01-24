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

/// Service for checking GitHub releases for updates.
class UpdateChecker {
  static const _prefsKeyCheckForUpdates = 'check_for_updates';
  static const _githubRepo = 'StuartCameronCode/VapourBox';
  static const _apiUrl = 'https://api.github.com/repos/$_githubRepo/releases/latest';

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
      // Get current version
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // Fetch latest release from GitHub (User-Agent required by GitHub API)
      final client = await RhttpClient.create(
        settings: const ClientSettings(
          throwOnStatusCode: false,
        ),
      );

      try {
        final response = await client.get(
          _apiUrl,
          headers: HttpHeaders.rawMap({
            'User-Agent': 'VapourBox-UpdateChecker/1.0',
            'Accept': 'application/vnd.github.v3+json',
          }),
        );

        if (response.statusCode != 200) {
          debugPrint('UpdateChecker: GitHub API returned ${response.statusCode}');
          return null;
        }

        final json = jsonDecode(response.body) as Map<String, dynamic>;
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
      } finally {
        client.dispose();
      }
    } catch (e) {
      debugPrint('UpdateChecker: Error checking for updates: $e');
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
