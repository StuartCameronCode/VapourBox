import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rhttp/rhttp.dart';
import 'package:path/path.dart' as path;

import 'temp_directory_service.dart';

/// Status of the dependency installation.
enum DependencyStatus {
  /// Dependencies are installed and up-to-date
  installed,

  /// Dependencies are not installed
  missing,

  /// Dependencies are installed but older than this app expects
  outdated,

  /// Installed deps are NEWER than the version this app was built against.
  ///
  /// Treated as usable, not as something to "fix": replacing them would be a
  /// silent downgrade, and the newer bundle is the one the user deliberately
  /// installed (or that a newer app left behind). It has not been tested with
  /// this app version though, so the user is told once rather than left to
  /// discover an incompatibility as a job failure.
  newerThanExpected,

  /// Dependencies are installed but SHA256 doesn't match (corrupted)
  corrupted,

  /// Installed and complete, but the binaries refuse to execute — on macOS this
  /// is almost always com.apple.quarantine, which the OS enforces by SIGKILLing
  /// the process. Re-downloading cannot fix it, so this must NOT be treated as
  /// missing/outdated or the app would loop on the download.
  blocked,

  /// Currently checking status
  checking,
}

/// Progress information for dependency download.
class DownloadProgress {
  final int bytesReceived;
  final int totalBytes;
  final String? currentFile;
  final String status;

  DownloadProgress({
    required this.bytesReceived,
    required this.totalBytes,
    required this.status,
    this.currentFile,
  });

  double get progress => totalBytes > 0 ? bytesReceived / totalBytes : 0.0;
  String get progressPercent => '${(progress * 100).toStringAsFixed(1)}%';
}

/// An install failure that already knows what to tell the user.
///
/// The download dialog used to print one fixed line — "Please check your
/// internet connection and try again" — under whatever went wrong. That is
/// wrong for everything past the download, and issue #87 is the case that
/// showed it: a rename refused by a held file handle is not a network problem,
/// and the advice sent the reporter auditing folder permissions instead.
///
/// [remedy] may be empty, meaning [message] already says what to do (the macOS
/// quarantine text carries its own `xattr` command, for instance).
class DependencyInstallException implements Exception {
  final String message;
  final String remedy;

  DependencyInstallException(this.message, {required this.remedy});

  @override
  String toString() => message;
}

/// Metadata about dependencies from the bundled version file.
class DepsVersionInfo {
  final String version;
  final String releaseTag;
  final String? releaseDate;
  final Map<String, PlatformDepsInfo> platforms;
  final String githubRepo;

  DepsVersionInfo({
    required this.version,
    required this.releaseTag,
    this.releaseDate,
    required this.platforms,
    required this.githubRepo,
  });

  factory DepsVersionInfo.fromJson(Map<String, dynamic> json) {
    final platforms = <String, PlatformDepsInfo>{};
    final platformsJson = json['platforms'] as Map<String, dynamic>? ?? {};
    for (final entry in platformsJson.entries) {
      platforms[entry.key] = PlatformDepsInfo.fromJson(
        entry.value as Map<String, dynamic>,
      );
    }

    return DepsVersionInfo(
      version: json['version'] as String,
      releaseTag: json['releaseTag'] as String? ?? 'deps-v${json['version']}',
      releaseDate: json['releaseDate'] as String?,
      platforms: platforms,
      githubRepo: json['githubRepo'] as String? ?? 'StuartCameronCode/VapourBox',
    );
  }

  /// The deps version expected for a platform. Platforms may override the
  /// global version (e.g. when only one platform's deps change), so the app
  /// can re-fetch just that platform without disturbing the others.
  String versionFor(String platform) => platforms[platform]?.version ?? version;

  /// The release tag a platform's zip lives under (per-platform override, else
  /// the global tag).
  String releaseTagFor(String platform) =>
      platforms[platform]?.releaseTag ?? releaseTag;

  /// The zip filename for a platform. Derived from version + platform unless a
  /// per-platform override supplies one explicitly (legacy/committed pointer).
  String filenameFor(String platform) =>
      platforms[platform]?.filename ??
      'VapourBox-deps-${versionFor(platform)}-$platform.zip';

  /// Get the download URL for a specific platform's deps zip.
  String getDownloadUrl(String platform) =>
      'https://github.com/$githubRepo/releases/download/${releaseTagFor(platform)}/${filenameFor(platform)}';

  /// URL of the integrity sidecar uploaded next to the zip (same release). It
  /// carries the expected sha256/size, so those don't need to be baked into the
  /// app and re-filled on every deps rebuild.
  String getManifestUrl(String platform) =>
      '${getDownloadUrl(platform)}.sha256.json';
}

/// Optional per-platform overrides in the (slim) deps-version pointer.
///
/// The committed `deps-version.json` is now just `{version, releaseTag,
/// githubRepo}` — filename is derived and the sha256/size live in the release
/// sidecar. This block only exists when a platform pins its own version/tag (or
/// an explicit filename); any of these may be absent.
class PlatformDepsInfo {
  final String? filename;

  /// Optional per-platform version override. When set, this platform's deps are
  /// versioned independently of the global `version` (see [DepsVersionInfo.versionFor]).
  final String? version;

  /// Optional per-platform release tag override (the release the zip lives in).
  final String? releaseTag;

  PlatformDepsInfo({
    this.filename,
    this.version,
    this.releaseTag,
  });

  factory PlatformDepsInfo.fromJson(Map<String, dynamic> json) {
    return PlatformDepsInfo(
      filename: json['filename'] as String?,
      version: json['version'] as String?,
      releaseTag: json['releaseTag'] as String?,
    );
  }
}

/// Installed dependency version info.
class InstalledDepsInfo {
  final String version;
  final DateTime? installedAt;

  InstalledDepsInfo({
    required this.version,
    this.installedAt,
  });

  factory InstalledDepsInfo.fromJson(Map<String, dynamic> json) {
    return InstalledDepsInfo(
      version: json['version'] as String,
      installedAt: json['installedAt'] != null
          ? DateTime.tryParse(json['installedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'installedAt': installedAt?.toIso8601String(),
    };
  }
}

/// Manages dependency checking, downloading, and installation.
class DependencyManager {
  static final DependencyManager instance = DependencyManager._();
  DependencyManager._();

  DepsVersionInfo? _expectedVersion;
  final _statusController = StreamController<DependencyStatus>.broadcast();
  final _progressController = StreamController<DownloadProgress>.broadcast();

  /// Stream of dependency status changes.
  Stream<DependencyStatus> get statusStream => _statusController.stream;

  /// Stream of download progress updates.
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  /// Get the current platform identifier.
  String get platformId {
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isMacOS) {
      // Check architecture
      final result = Process.runSync('uname', ['-m']);
      final arch = result.stdout.toString().trim();
      return arch == 'arm64' ? 'macos-arm64' : 'macos-x64';
    }
    if (Platform.isLinux) {
      final result = Process.runSync('uname', ['-m']);
      final arch = result.stdout.toString().trim();
      return arch == 'aarch64' ? 'linux-arm64' : 'linux-x64';
    }
    throw UnsupportedError('Unsupported platform');
  }

  /// Get the dependencies directory path.
  Future<Directory> getDepsDirectory() async {
    // Explicit override (used by `flutter test` in CI, where the executable is
    // the test runner, not the app bundle). Points directly at a platform deps
    // dir, e.g. /path/to/deps/macos-arm64.
    final override = Platform.environment['VAPOURBOX_DEPS_DIR'];
    if (override != null && override.isNotEmpty) {
      final overrideDir = Directory(override);
      if (await overrideDir.exists()) {
        return overrideDir;
      }
    }

    final executablePath = Platform.resolvedExecutable;
    final appDir = path.dirname(executablePath);

    if (Platform.isWindows) {
      // Production: deps folder next to executable
      final prodDeps = Directory(path.join(appDir, 'deps', 'windows-x64'));
      if (await prodDeps.exists()) {
        return prodDeps;
      }

      // Development only: search upward for project deps
      // This is restricted to debug builds for security - release builds
      // should only check known, trusted paths.
      if (kDebugMode) {
        // From app/build/windows/x64/runner/Debug/ up 6 levels to project root
        final devDeps = Directory(path.join(appDir, '..', '..', '..', '..', '..', '..', 'deps', 'windows-x64'));
        if (await devDeps.exists()) {
          final resolved = Directory(await devDeps.resolveSymbolicLinks());
          print('DependencyManager: Found dev deps at ${resolved.path}');
          return resolved;
        }
      }

      // Fall back to production path (will trigger download)
      return prodDeps;
    } else if (Platform.isMacOS) {
      // Development only: check relative paths to project root
      if (kDebugMode) {
        // From app/build/macos/Build/Products/Debug/vapourbox.app/Contents/MacOS up 9 levels
        final devDepsArm = Directory(path.join(appDir, '..', '..', '..', '..', '..', '..', '..', '..', '..', 'deps', 'macos-arm64'));
        if (await devDepsArm.exists()) {
          return Directory(await devDepsArm.resolveSymbolicLinks());
        }
        final devDepsX64 = Directory(path.join(appDir, '..', '..', '..', '..', '..', '..', '..', '..', '..', 'deps', 'macos-x64'));
        if (await devDepsX64.exists()) {
          return Directory(await devDepsX64.resolveSymbolicLinks());
        }
      }

      // Production: check Application Support (where downloaded deps go)
      final home = Platform.environment['HOME'];
      if (home != null) {
        final appSupportDeps = Directory(path.join(
          home, 'Library', 'Application Support', 'VapourBox', 'deps', platformId
        ));
        if (await appSupportDeps.exists()) {
          return appSupportDeps;
        }
      }

      // Fall back to Application Support (will trigger download)
      final home2 = Platform.environment['HOME'] ?? '/tmp';
      return Directory(path.join(
        home2, 'Library', 'Application Support', 'VapourBox', 'deps', platformId
      ));
    } else if (Platform.isLinux) {
      // Development only: check relative paths to project root
      if (kDebugMode) {
        // From app/build/linux/x64/debug/bundle/ up 6 levels
        final devDeps = Directory(path.join(appDir, '..', '..', '..', '..', '..', '..', 'deps', platformId));
        if (await devDeps.exists()) {
          return Directory(await devDeps.resolveSymbolicLinks());
        }
      }

      // Production: check XDG_DATA_HOME or ~/.local/share
      final xdgDataHome = Platform.environment['XDG_DATA_HOME'];
      final home = Platform.environment['HOME'] ?? '/tmp';
      final dataDir = xdgDataHome != null
          ? path.join(xdgDataHome, 'VapourBox', 'deps', platformId)
          : path.join(home, '.local', 'share', 'VapourBox', 'deps', platformId);
      final linuxDeps = Directory(dataDir);
      if (await linuxDeps.exists()) {
        return linuxDeps;
      }

      // Fall back to XDG path (will trigger download)
      return linuxDeps;
    }

    throw UnsupportedError('Unsupported platform');
  }

  /// Get the version file path within deps directory.
  Future<File> _getInstalledVersionFile({Directory? depsDirOverride}) async {
    final depsDir = depsDirOverride ?? await getDepsDirectory();
    return File(path.join(depsDir.path, 'version.json'));
  }

  /// Load the expected dependency version from bundled assets.
  Future<DepsVersionInfo> getExpectedVersion() async {
    if (_expectedVersion != null) return _expectedVersion!;

    final jsonString = await rootBundle.loadString('assets/deps-version.json');
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    _expectedVersion = DepsVersionInfo.fromJson(json);
    return _expectedVersion!;
  }

  /// Get the installed dependency version, or null if not installed.
  Future<InstalledDepsInfo?> getInstalledVersion() async {
    final versionFile = await _getInstalledVersionFile();

    if (!await versionFile.exists()) {
      return null;
    }

    try {
      final content = await versionFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return InstalledDepsInfo.fromJson(json);
    } catch (e) {
      print('DependencyManager: Failed to read installed version: $e');
      return null;
    }
  }

  /// Check if dependencies are installed and up-to-date.
  Future<DependencyStatus> checkDependencies() async {
    _statusController.add(DependencyStatus.checking);

    try {
      final expected = await getExpectedVersion();
      final installed = await getInstalledVersion();
      final depsDir = await getDepsDirectory();

      // Check if deps directory exists
      if (!await depsDir.exists()) {
        print('DependencyManager: Deps directory missing: ${depsDir.path}');
        return DependencyStatus.missing;
      }

      // Check if version file exists
      if (installed == null) {
        print('DependencyManager: Version file missing');
        return DependencyStatus.missing;
      }

      // Check version match (per-platform: a platform may pin its own version).
      // Direction matters. Older than expected is an upgrade; newer is not a
      // fault at all, and treating it as one downgraded a deliberately newer
      // bundle back to the released one — destructively, since installing wipes
      // and replaces.
      final expectedVersion = expected.versionFor(platformId);
      if (installed.version != expectedVersion) {
        final order = compareVersions(installed.version, expectedVersion);
        if (order > 0) {
          print(
              'DependencyManager: Installed deps ${installed.version} are newer '
              'than the expected $expectedVersion — keeping them, untested with '
              'this app version');
          return DependencyStatus.newerThanExpected;
        }
        print(
            'DependencyManager: Version mismatch - installed: ${installed.version}, expected: $expectedVersion');
        return DependencyStatus.outdated;
      }

      // Verify critical files exist
      final criticalFiles = _getCriticalFiles();
      for (final file in criticalFiles) {
        final filePath = path.join(depsDir.path, file);
        if (!await File(filePath).exists() &&
            !await Directory(filePath).exists()) {
          print('DependencyManager: Missing critical file: $file');
          return DependencyStatus.corrupted;
        }
      }

      // Present and complete is not the same as usable — see
      // executabilityProblem(). Checking here as well as after install matters:
      // the install that quarantined them may have been several launches ago.
      final problem = await executabilityProblem();
      if (problem != null) {
        print('DependencyManager: Dependencies present but unusable: $problem');
        return DependencyStatus.blocked;
      }

      print('DependencyManager: Dependencies OK (v${installed.version})');
      return DependencyStatus.installed;
    } catch (e) {
      print('DependencyManager: Check failed: $e');
      return DependencyStatus.missing;
    }
  }

  /// Why the installed dependencies can't be executed, or null if they can.
  ///
  /// Checking that files *exist* is not enough: macOS refuses to execute a
  /// quarantined binary, killing it with SIGKILL, so a complete and correct
  /// install can still be unusable. That surfaced as "ffmpeg exited with signal
  /// 9" at job time, an error naming neither the cause nor the fix (issue #50).
  ///
  /// ffmpeg stands in for the rest: quarantine is applied to everything that was
  /// extracted, so if ffmpeg runs, its siblings will too.
  ///
  /// [depsDirOverride] exists so tests can point this at a deliberately broken
  /// install; production callers leave it unset.
  Future<String?> executabilityProblem({Directory? depsDirOverride}) async {
    final depsDir = depsDirOverride ?? await getDepsDirectory();
    final ffmpeg = File(path.join(
        depsDir.path, 'ffmpeg', Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg'));
    if (!await ffmpeg.exists()) return null; // absence is the caller's business

    try {
      final result = await Process.run(ffmpeg.path, ['-version']);
      if (result.exitCode == 0) return null;

      // SIGKILL (-9, or 137 through a shell) is the quarantine signature.
      final killed = result.exitCode == -9 || result.exitCode == 137;
      if (Platform.isMacOS && killed && await _isQuarantined(ffmpeg.path)) {
        return 'macOS has quarantined the downloaded dependencies, so it kills '
            'them on launch. Clear the flag and restart VapourBox:\n\n'
            'xattr -cr "${depsDir.path}"';
      }
      return 'The bundled ffmpeg would not run (exit ${result.exitCode}). '
          '${result.stderr}'.trim();
    } catch (e) {
      return 'The bundled ffmpeg could not be launched: $e';
    }
  }

  /// Whether [filePath] still carries com.apple.quarantine.
  Future<bool> _isQuarantined(String filePath) async {
    try {
      final result = await Process.run('xattr', [filePath]);
      return (result.stdout as String).contains('com.apple.quarantine');
    } catch (_) {
      return false;
    }
  }

  /// Compare two dotted version strings numerically.
  ///
  /// Returns <0 if [a] is older than [b], 0 if equal, >0 if newer. A plain
  /// string compare is wrong here — "1.10.0" sorts before "1.9.0" — and these
  /// values decide whether the app replaces an install. Non-numeric or
  /// differing-length components degrade to a component-wise best effort rather
  /// than throwing, because an unparseable version must not crash startup.
  @visibleForTesting
  static int compareVersions(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
      final na = i < pa.length ? int.tryParse(pa[i].trim()) ?? 0 : 0;
      final nb = i < pb.length ? int.tryParse(pb[i].trim()) ?? 0 : 0;
      if (na != nb) return na < nb ? -1 : 1;
    }
    return 0;
  }

  /// Get list of critical files that must exist.
  ///
  /// Includes at least one file that exists ONLY in the R78 layout. vspipe,
  /// the plugin directory and ffmpeg are all present in the pre-R78 bundle
  /// too, so on their own they cannot tell a current install from a stale one
  /// carrying a newer version.json — and a stale tree passes every other check
  /// while failing at job time. libvapoursynthfilters arrived with R78 (it is
  /// where every core filter now lives) and __init__.py only exists because we
  /// ship VapourSynth as a Python package, so either one is a reliable marker.
  List<String> _getCriticalFiles() {
    if (Platform.isWindows) {
      return [
        'vapoursynth/Lib/site-packages/vapoursynth/vspipe.exe',
        'vapoursynth/Lib/site-packages/vapoursynth/libvapoursynthfilters.dll',
        'vapoursynth/vs-plugins',
        'ffmpeg/ffmpeg.exe',
      ];
    } else if (Platform.isMacOS || Platform.isLinux) {
      final filters = Platform.isMacOS
          ? 'vapoursynth/libvapoursynthfilters.dylib'
          : 'vapoursynth/libvapoursynthfilters.so';
      return [
        'vapoursynth/vspipe',
        filters,
        'vapoursynth/__init__.py',
        'vapoursynth/plugins',
        'ffmpeg/ffmpeg',
      ];
    }
    return [];
  }

  /// Download and install dependencies.
  ///
  /// Returns a stream of progress updates. The future completes when
  /// installation is done or fails.
  Future<void> downloadAndInstall() async {
    final expected = await getExpectedVersion();

    // Construct download URL from release tag (filename is derived).
    final downloadUrl = expected.getDownloadUrl(platformId);
    final filename = expected.filenameFor(platformId);

    print('DependencyManager: Downloading from $downloadUrl');

    _progressController.add(DownloadProgress(
      bytesReceived: 0,
      totalBytes: 0,
      status: 'Connecting...',
    ));

    // Fetch the integrity sidecar (sha256) uploaded next to the zip. Verification
    // is best-effort: if the sidecar is missing/unreadable we still install (the
    // download is over HTTPS), matching prior behaviour when no hash was set.
    final expectedSha256 =
        await _fetchExpectedSha256(expected.getManifestUrl(platformId));

    // The zip is downloaded into a stable cache path rather than a throwaway
    // temp directory, and kept if anything after the download fails. Everything
    // past this point — extraction, verification, the swap — can fail for
    // reasons that have nothing to do with the bytes we just fetched (issue
    // #87), and making the user re-fetch ~200 MB to retry a rename is a poor
    // trade for the disk the zip occupies until the install succeeds.
    final tempFile = File(await _cachedDownloadPath(filename));

    try {
      // Reuse the cached zip only when the sidecar gave us a hash to check it
      // against. Without one an interrupted download is indistinguishable from
      // a complete one, and extracting a truncated zip would report a corrupt
      // bundle rather than the missing bytes.
      var reusable = false;
      if (await tempFile.exists()) {
        if (expectedSha256 != null) {
          _progressController.add(DownloadProgress(
            bytesReceived: 0,
            totalBytes: 0,
            status: 'Checking the downloaded file...',
          ));
          reusable = await _sha256OfFile(tempFile) == expectedSha256;
          print('DependencyManager: cached download ${reusable ? 'matches the '
              'expected hash - skipping the download' : 'does not match the '
              'expected hash - downloading again'}');
        }
        if (!reusable) {
          await tempFile.delete().catchError((_) => tempFile);
        }
      }

      if (!reusable) {
        await _downloadFile(
          downloadUrl,
          tempFile,
          expectedSha256: expectedSha256,
        );
      }

      // Extract. _extractZip emits per-file extraction progress; this initial
      // event (0/0 -> indeterminate) covers the synchronous decode that precedes
      // the first file write.
      _progressController.add(DownloadProgress(
        bytesReceived: 0,
        totalBytes: 0,
        status: 'Extracting...',
      ));

      final downloadedBytes = await tempFile.length();

      // Build the new install alongside the current one and swap it in, rather
      // than deleting the current one and extracting over the top. The old path
      // left the user with nothing between the delete and the last file
      // written: a crash, a quit, a full disk or a flat battery in that window
      // meant a mandatory full re-download, and on macOS it unlinked files the
      // running app may still have had open.
      //
      // Costs roughly twice the bundle size on disk while it runs. The staging
      // and retired directories are siblings of the deps directory, so both
      // renames stay on one filesystem and the swap is as close to atomic as
      // the platform allows.
      final depsDir = await getDepsDirectory();
      final staging = Directory('${depsDir.path}.new');
      final retired = Directory('${depsDir.path}.old');
      for (final d in [staging, retired]) {
        // Retried: a leftover .new from a failed swap can still be held open by
        // whatever blocked that swap, and an unguarded delete here would fail
        // the next attempt with a second, different error.
        if (await d.exists()) {
          await retryTransientFsOperation(() => d.delete(recursive: true),
              what: 'remove ${d.path}', onRetry: _reportInstallWait);
        }
      }

      // Staging only earns its cost when there is an install to protect. On a
      // first install there is none, so extract straight into place and skip
      // the swap entirely — which is what issue #87 needs: the rename is the
      // fragile step, and on Windows it is refused outright (errno 5) while
      // anything at all holds a handle on a file in the tree, which on that
      // platform routinely means a scanner or the search indexer working
      // through the ~200 MB we have just written.
      //
      // Safe to extract in place because version.json is still written last:
      // an interrupted first install leaves a tree with no version file, which
      // the next startup reads as missing rather than as installed.
      final hadPrevious = await depsDir.exists();
      final target = hadPrevious ? staging : depsDir;

      await _extractZip(tempFile, targetOverride: target);

      // Prove the install is actually usable before declaring success. The
      // quarantine strip above can fail — silently, and it cannot succeed at all
      // from a sandboxed process — leaving a complete install whose binaries
      // macOS kills on sight. Reporting "Complete" then would hand the user an
      // "ffmpeg exited with signal 9" hours later instead of the real problem
      // now (issue #50).
      //
      // Checked against the staged copy, so a bundle that fails here is thrown
      // away with the existing install still in place.
      //
      // Windows runs it *after* the swap instead (below). The quarantine case
      // this guards is macOS-only, so on Windows all it can report is a generic
      // "would not run" — while executing a freshly written, unsigned 100 MB
      // binary is exactly what makes a scanner open the tree we are about to
      // rename. See the rollback below for how a genuine failure is handled.
      if (!Platform.isWindows) {
        _reportInstallStep('Checking the new components...');
        final problem = await executabilityProblem(depsDirOverride: target);
        if (problem != null) {
          await target.delete(recursive: true).catchError((_) => target);
          throw DependencyInstallException(problem, remedy: '');
        }
      }

      // Write version file (per-platform version, so the next check matches).
      // Still the last thing written into the tree, so a staged directory that
      // never gets swapped in can never look complete.
      await _writeInstalledVersion(expected.versionFor(platformId),
          depsDirOverride: target);

      // Swap. If the second rename fails we have already moved the old install
      // aside, so put it back rather than leaving the user with no deps at all.
      //
      // Both renames are retried. A directory rename on Windows fails with
      // "Access is denied" (errno 5) whenever any descendant is open — a
      // transient condition, and one the user cannot do anything about, but it
      // lands at the very end of a ~200 MB download, so a single attempt costs
      // them the whole thing (issue #87).
      if (hadPrevious) {
        _reportInstallStep('Installing...');
        await retryTransientFsOperation(() => depsDir.rename(retired.path),
            what: 'move the existing install aside',
            onRetry: _reportInstallWait);
        try {
          await retryTransientFsOperation(() => staging.rename(depsDir.path),
              what: 'move the new install into place',
              onRetry: _reportInstallWait);
        } catch (_) {
          // Best-effort: if putting the old tree back also fails the user is
          // left with no deps and re-downloads next launch, which is recoverable
          // — reporting why the swap failed is the more useful error.
          await retryTransientFsOperation(() => retired.rename(depsDir.path),
                  what: 'restore the previous install')
              .catchError((_) => depsDir);
          rethrow;
        }
      }

      // Windows' half of the executability check, against the live install.
      // Restores the previous bundle if the new one will not run, so a blocked
      // download can never leave the user worse off than before it.
      if (Platform.isWindows) {
        _reportInstallStep('Checking the new components...');
        final problem = await executabilityProblem(depsDirOverride: depsDir);
        if (problem != null) {
          // All best-effort: whatever happens to the trees, the error the user
          // needs is why the new bundle would not run.
          if (hadPrevious) {
            try {
              await retryTransientFsOperation(
                  () => depsDir.rename(staging.path),
                  what: 'move the failed install aside');
              await retryTransientFsOperation(
                  () => retired.rename(depsDir.path),
                  what: 'restore the previous install');
              unawaited(
                  staging.delete(recursive: true).catchError((_) => staging));
            } catch (e) {
              print('DependencyManager: could not restore the previous '
                  'install after a failed one: $e');
            }
          } else {
            await depsDir.delete(recursive: true).catchError((_) => depsDir);
          }
          throw DependencyInstallException(problem, remedy: '');
        }
      }

      // Best-effort: the install is already live, so failing to remove the old
      // copy costs disk space, not correctness.
      if (hadPrevious) {
        unawaited(retired.delete(recursive: true).catchError((_) => retired));
      }

      _progressController.add(DownloadProgress(
        bytesReceived: downloadedBytes,
        totalBytes: downloadedBytes,
        status: 'Complete',
      ));

      print('DependencyManager: Installation complete');

      // Only now is the zip dead weight. On any failure above it is deliberately
      // left in place so Retry can skip the download.
      await tempFile.delete().catchError((_) => tempFile);
    } catch (e) {
      print('DependencyManager: install failed ($e) - keeping the downloaded '
          'zip at ${tempFile.path} so a retry can reuse it');
      rethrow;
    }
  }

  /// What to suggest the user try, given the error that ended the install.
  ///
  /// One fixed line of connection advice was actively misleading for anything
  /// that failed after the download (issue #87), which is most of the install.
  /// Errors carrying their own advice are honoured; everything else is
  /// classified by what the filesystem actually said, and only a genuinely
  /// unrecognised failure falls back to the connection line.
  ///
  /// Windows error codes are the discriminating ones and are not
  /// interchangeable: **5** (access denied) and **32** (sharing violation) mean
  /// something holds the files open, **112** means the disk is full, **183**
  /// means the destination is already there. See
  /// [retryTransientFsOperation] for how 5 was pinned down.
  static String remedyFor(Object error) {
    if (error is DependencyInstallException) return error.remedy;

    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      final noSpace = Platform.isWindows ? code == 112 : code == 28;
      if (noSpace) {
        return 'There is not enough free disk space to install the '
            'components. Free some space and try again.';
      }
      if (error is PathAccessException || code == 5 || code == 32) {
        if (Platform.isWindows) {
          return 'Another program is holding the downloaded files open, which '
              'stops VapourBox from moving them into place. This is usually '
              'antivirus or file indexing, and is not a permissions problem.\n\n'
              'Close any Explorer windows showing the VapourBox folder, then '
              'try again. If it keeps happening, add the VapourBox folder to '
              'your antivirus exclusions, or move VapourBox out of Downloads '
              'and out of any synced folder (OneDrive, Dropbox).';
        }
        return 'VapourBox could not write to its components folder. Check that '
            'you have permission to write there and that the disk is not full, '
            'then try again.';
      }
      return 'VapourBox could not finish writing its components. Check the '
          'free disk space and that the folder is writable, then try again.';
    }

    return 'Please check your internet connection and try again.';
  }

  /// Where the downloaded bundle is cached between attempts.
  ///
  /// A fixed name under the (user-configurable) temp directory, so a retry can
  /// find it. Anything else in there is another version's leftovers and is
  /// pruned, which is what stops the cache growing without bound.
  Future<String> _cachedDownloadPath(String filename) async {
    final dir = Directory(path.join(
        (await TempDirectoryService.instance.resolve()).path,
        'vapourbox-deps-cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    try {
      await for (final entry in dir.list()) {
        if (entry is File && path.basename(entry.path) != filename) {
          await entry.delete().catchError((_) => entry);
        }
      }
    } catch (e) {
      print('DependencyManager: could not prune the download cache ($e)');
    }
    return path.join(dir.path, filename);
  }

  /// Lowercase hex sha256 of [file], in the same form the sidecar publishes.
  Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Progress event for a step of the install that has no measurable size.
  ///
  /// Emitted with 0/0 so the dialog shows an indeterminate bar: the swap really
  /// has no fraction to report, and leaving the previous step's full bar on
  /// screen made the install phase look finished when it had not started.
  void _reportInstallStep(String status) {
    _progressController.add(
        DownloadProgress(bytesReceived: 0, totalBytes: 0, status: status));
  }

  /// Progress event for a retried filesystem step.
  ///
  /// Without this the retry budget is a silent stall on a dialog that still
  /// reads "Extracting... 100%", which is indistinguishable from a hang — and
  /// the machines that need the retries are the ones that wait longest.
  void _reportInstallWait(int attempt, Object error) {
    _reportInstallStep('Waiting for another program to release the new '
        'files... (attempt $attempt)');
  }

  /// Run [operation], retrying while it fails for a reason that may clear on
  /// its own.
  ///
  /// Exists for the install swap. Windows refuses to rename or delete a
  /// directory while **any** descendant is open — measured: an open read handle
  /// on one file, or a child process whose working directory is inside the
  /// tree, is enough, and both surface as `PathAccessException … errno = 5`.
  /// (A running .exe inside the tree is *not* enough, and a destination that
  /// already exists gives errno 183 instead, so those two can be told apart
  /// from a genuine permissions fault.) Immediately after extracting a ~200 MB
  /// bundle there is usually something holding one — a scanner, the search
  /// indexer, Explorer building a thumbnail — for a few hundred milliseconds.
  ///
  /// A single attempt therefore threw away the entire download, every time, for
  /// the user who reported issue #87. Waiting a few seconds costs nothing on a
  /// machine where the first attempt succeeds.
  ///
  /// `PathExistsException` and `PathNotFoundException` are not transient — the
  /// destination will not stop existing, and a missing source will not appear —
  /// so they are rethrown immediately rather than burning the whole budget.
  /// [onRetry] is called with the attempt number that just failed and its
  /// error, so the caller can tell the user something is being waited on
  /// rather than leaving the dialog on a stalled bar.
  @visibleForTesting
  static Future<T> retryTransientFsOperation<T>(
    Future<T> Function() operation, {
    int attempts = 12,
    Duration firstDelay = const Duration(milliseconds: 50),
    Duration maxDelay = const Duration(seconds: 1),
    String? what,
    void Function(int attempt, Object error)? onRetry,
  }) async {
    var delay = firstDelay;
    for (var attempt = 1;; attempt++) {
      try {
        return await operation();
      } on PathExistsException {
        rethrow;
      } on PathNotFoundException {
        rethrow;
      } on FileSystemException catch (e) {
        if (attempt >= attempts) {
          print('DependencyManager: gave up after $attempt attempts to '
              '${what ?? 'complete a filesystem operation'}: $e');
          rethrow;
        }
        print('DependencyManager: attempt $attempt to '
            '${what ?? 'complete a filesystem operation'} failed ($e) - '
            'retrying in ${delay.inMilliseconds}ms');
        onRetry?.call(attempt, e);
        await Future<void>.delayed(delay);
        delay = delay * 2 > maxDelay ? maxDelay : delay * 2;
      }
    }
  }

  /// Fetch the expected sha256 from the integrity sidecar uploaded next to the
  /// zip. Returns null if the sidecar can't be fetched or parsed, in which case
  /// the caller installs without hash verification (best-effort, HTTPS-trusted).
  Future<String?> _fetchExpectedSha256(String url) async {
    try {
      final client = await RhttpClient.create(
        settings: const ClientSettings(throwOnStatusCode: false),
      );
      try {
        final response = await client.get(url);
        if (response.statusCode != 200) {
          print(
              'DependencyManager: manifest fetch HTTP ${response.statusCode} ($url) - skipping hash check');
          return null;
        }
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final sha = json['sha256'] as String?;
        if (sha == null || sha.isEmpty) {
          print('DependencyManager: manifest has no sha256 - skipping hash check');
          return null;
        }
        return sha;
      } finally {
        client.dispose();
      }
    } catch (e) {
      print('DependencyManager: manifest fetch/parse failed ($e) - skipping hash check');
      return null;
    }
  }

  /// Download a file with progress reporting.
  Future<void> _downloadFile(
    String url,
    File destination, {
    int? expectedSize,
    String? expectedSha256,
  }) async {
    final digestSink = AccumulatorSink<Digest>();
    final sha256Sink = sha256.startChunkedConversion(digestSink);
    final totalBytes = expectedSize ?? 0;

    try {
      // Use rhttp streaming download with progress
      final response = await Rhttp.getStream(
        url,
        onReceiveProgress: (bytesReceived, contentLength) {
          _progressController.add(DownloadProgress(
            bytesReceived: bytesReceived,
            totalBytes: contentLength > 0 ? contentLength : totalBytes,
            status: 'Downloading...',
          ));
        },
      );

      // Check status code
      if (response.statusCode != 200) {
        throw HttpException(
          'Download failed: HTTP ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }

      // Stream to file while computing SHA256
      final sink = destination.openWrite();

      await for (final chunk in response.body) {
        sink.add(chunk);
        sha256Sink.add(chunk);
      }

      await sink.close();
      sha256Sink.close();

      // Verify SHA256 if provided
      if (expectedSha256 != null) {
        final actualSha256 = digestSink.events.first.toString();
        if (actualSha256 != expectedSha256) {
          await destination.delete();
          throw StateError(
            'SHA256 mismatch: expected $expectedSha256, got $actualSha256',
          );
        }
      }
    } on RhttpException catch (e) {
      throw HttpException('Download failed: $e', uri: Uri.parse(url));
    }
  }

  /// Extract a zip file to the deps directory.
  Future<void> _extractZip(File zipFile, {Directory? targetOverride}) async {
    final depsDir = targetOverride ?? await getDepsDirectory();

    // Create parent directory if needed
    final parentDir = depsDir.parent;
    if (!await parentDir.exists()) {
      await parentDir.create(recursive: true);
    }

    // Remove existing deps directory
    if (await depsDir.exists()) {
      await depsDir.delete(recursive: true);
    }

    await depsDir.create(recursive: true);

    // Read and extract zip
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Total uncompressed size, for extraction progress. Extraction (many file
    // writes + chmod) is slow on Linux, so report progress rather than leaving
    // the dialog frozen on "Extracting...".
    var totalBytes = 0;
    for (final file in archive) {
      if (file.isFile) totalBytes += file.size;
    }

    var extracted = 0;
    var lastEmitted = -1;
    const emitEvery = 2 * 1024 * 1024; // throttle UI updates to ~every 2 MB

    void emitExtractProgress() {
      _progressController.add(DownloadProgress(
        bytesReceived: extracted,
        totalBytes: totalBytes,
        status: 'Extracting...',
      ));
    }

    emitExtractProgress();

    for (final file in archive) {
      final filePath = path.join(depsDir.path, file.name);

      if (file.isFile) {
        final outFile = File(filePath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);

        // Set executable permission on Unix
        if (!Platform.isWindows && _isExecutable(file.name)) {
          await Process.run('chmod', ['+x', filePath]);
        }

        extracted += file.size;
        if (extracted - lastEmitted >= emitEvery) {
          lastEmitted = extracted;
          emitExtractProgress();
        }
      } else {
        await Directory(filePath).create(recursive: true);
      }
    }

    // Final 100% extraction tick.
    extracted = totalBytes;
    emitExtractProgress();

    // On macOS, remove quarantine attribute and re-sign binaries for Gatekeeper
    if (Platform.isMacOS) {
      await _removeQuarantine(depsDir.path);
      await _codesignBinaries(depsDir.path);
    }
  }

  /// Remove quarantine extended attribute on macOS.
  /// This allows downloaded binaries to run without Gatekeeper blocking them.
  Future<void> _removeQuarantine(String directoryPath) async {
    try {
      final result = await Process.run('xattr', ['-cr', directoryPath]);
      if (result.exitCode == 0) {
        print('DependencyManager: Removed quarantine attribute from $directoryPath');
      } else {
        print('DependencyManager: xattr warning: ${result.stderr}');
      }
    } catch (e) {
      // xattr should always be available on macOS, but don't fail if it isn't
      print('DependencyManager: Could not remove quarantine: $e');
    }
  }

  /// Ad-hoc codesign all Mach-O binaries and dylibs after extraction.
  /// On macOS Sequoia+, unsigned binaries may be blocked even after quarantine
  /// removal. Re-signing ensures Gatekeeper allows execution.
  Future<void> _codesignBinaries(String directoryPath) async {
    try {
      // Sign all dylibs and .so files (shared libraries)
      final libResult = await Process.run('/bin/sh', [
        '-c',
        'find "\$1" -type f \\( -name "*.dylib" -o -name "*.so" \\) '
            '-exec codesign --force --sign - {} \\; 2>&1',
        '--',
        directoryPath,
      ]);
      if (libResult.exitCode != 0) {
        print('DependencyManager: codesign libs warning: ${libResult.stdout}');
      }

      // Sign known executable binaries
      final executables = [
        path.join(directoryPath, 'ffmpeg', 'ffmpeg'),
        path.join(directoryPath, 'ffmpeg', 'ffprobe'),
        path.join(directoryPath, 'vapoursynth', 'vspipe-bin'),
      ];
      for (final exe in executables) {
        if (await File(exe).exists()) {
          await Process.run('codesign', ['--force', '--sign', '-', exe]);
        }
      }

      print('DependencyManager: Codesigned binaries in $directoryPath');
    } catch (e) {
      print('DependencyManager: Could not codesign binaries: $e');
    }
  }

  /// Check if a file should be executable.
  bool _isExecutable(String fileName) {
    final name = path.basename(fileName).toLowerCase();
    return name == 'ffmpeg' ||
        name == 'ffprobe' ||
        name == 'vspipe' ||
        name.endsWith('.sh') ||
        !name.contains('.');
  }

  /// Write the installed version file.
  Future<void> _writeInstalledVersion(String version,
      {Directory? depsDirOverride}) async {
    final versionFile =
        await _getInstalledVersionFile(depsDirOverride: depsDirOverride);
    final info = InstalledDepsInfo(
      version: version,
      installedAt: DateTime.now(),
    );
    await versionFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(info.toJson()),
    );
  }

  /// Dispose of resources.
  void dispose() {
    _statusController.close();
    _progressController.close();
  }
}

/// Accumulator sink for collecting digest events.
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];

  @override
  void add(T event) => events.add(event);

  @override
  void close() {}
}
