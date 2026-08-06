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

  /// Dependencies are installed but wrong version
  outdated,

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
  Future<File> _getInstalledVersionFile() async {
    final depsDir = await getDepsDirectory();
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

      // Check version match (per-platform: a platform may pin its own version)
      final expectedVersion = expected.versionFor(platformId);
      if (installed.version != expectedVersion) {
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

  /// Get list of critical files that must exist.
  List<String> _getCriticalFiles() {
    if (Platform.isWindows) {
      return [
        'vapoursynth/Lib/site-packages/vapoursynth/vspipe.exe',
        'vapoursynth/vs-plugins',
        'ffmpeg/ffmpeg.exe',
      ];
    } else if (Platform.isMacOS || Platform.isLinux) {
      return [
        'vapoursynth/vspipe',
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

    // Create temp file for download
    final tempDir =
        await TempDirectoryService.instance.createTemp('vapourbox_deps_');
    final tempFile = File(path.join(tempDir.path, filename));

    try {
      // Download with progress
      await _downloadFile(
        downloadUrl,
        tempFile,
        expectedSha256: expectedSha256,
      );

      // Extract. _extractZip emits per-file extraction progress; this initial
      // event (0/0 -> indeterminate) covers the synchronous decode that precedes
      // the first file write.
      _progressController.add(DownloadProgress(
        bytesReceived: 0,
        totalBytes: 0,
        status: 'Extracting...',
      ));

      final downloadedBytes = await tempFile.length();

      await _extractZip(tempFile);

      // Prove the install is actually usable before declaring success. The
      // quarantine strip above can fail — silently, and it cannot succeed at all
      // from a sandboxed process — leaving a complete install whose binaries
      // macOS kills on sight. Reporting "Complete" then would hand the user an
      // "ffmpeg exited with signal 9" hours later instead of the real problem
      // now (issue #50).
      final problem = await executabilityProblem();
      if (problem != null) {
        throw Exception(problem);
      }

      // Write version file (per-platform version, so the next check matches)
      await _writeInstalledVersion(expected.versionFor(platformId));

      _progressController.add(DownloadProgress(
        bytesReceived: downloadedBytes,
        totalBytes: downloadedBytes,
        status: 'Complete',
      ));

      print('DependencyManager: Installation complete');
    } finally {
      // Cleanup temp files
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
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
  Future<void> _extractZip(File zipFile) async {
    final depsDir = await getDepsDirectory();

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
  Future<void> _writeInstalledVersion(String version) async {
    final versionFile = await _getInstalledVersionFile();
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
