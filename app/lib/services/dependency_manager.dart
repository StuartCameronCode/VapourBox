import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rhttp/rhttp.dart';
import 'package:path/path.dart' as path;

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
      githubRepo: json['githubRepo'] as String? ?? 'StuartCameron/VapourBox',
    );
  }

  /// Get the download URL for a specific platform's deps zip.
  String getDownloadUrl(String platform) {
    final platformInfo = platforms[platform];
    if (platformInfo == null) {
      throw StateError('No dependency info for platform: $platform');
    }
    return 'https://github.com/$githubRepo/releases/download/$releaseTag/${platformInfo.filename}';
  }
}

/// Platform-specific dependency info.
class PlatformDepsInfo {
  final String filename;
  final String? sha256;
  final int? size;

  PlatformDepsInfo({
    required this.filename,
    this.sha256,
    this.size,
  });

  factory PlatformDepsInfo.fromJson(Map<String, dynamic> json) {
    return PlatformDepsInfo(
      filename: json['filename'] as String,
      sha256: json['sha256'] as String?,
      size: json['size'] as int?,
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
    throw UnsupportedError('Unsupported platform');
  }

  /// Get the dependencies directory path.
  Future<Directory> getDepsDirectory() async {
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

      // Check version match
      if (installed.version != expected.version) {
        print(
            'DependencyManager: Version mismatch - installed: ${installed.version}, expected: ${expected.version}');
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

      print('DependencyManager: Dependencies OK (v${installed.version})');
      return DependencyStatus.installed;
    } catch (e) {
      print('DependencyManager: Check failed: $e');
      return DependencyStatus.missing;
    }
  }

  /// Get list of critical files that must exist.
  List<String> _getCriticalFiles() {
    if (Platform.isWindows) {
      return [
        'vapoursynth/VSPipe.exe',
        'vapoursynth/vs-plugins',
        'ffmpeg/ffmpeg.exe',
      ];
    } else if (Platform.isMacOS) {
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
    final platformInfo = expected.platforms[platformId];

    if (platformInfo == null) {
      throw StateError('No dependency info for platform: $platformId');
    }

    // Construct download URL from release tag
    final downloadUrl = expected.getDownloadUrl(platformId);

    print('DependencyManager: Downloading from $downloadUrl');

    _progressController.add(DownloadProgress(
      bytesReceived: 0,
      totalBytes: platformInfo.size ?? 0,
      status: 'Connecting...',
    ));

    // Create temp file for download
    final tempDir = await Directory.systemTemp.createTemp('vapourbox_deps_');
    final tempFile = File(path.join(tempDir.path, platformInfo.filename));

    try {
      // Download with progress
      await _downloadFile(
        downloadUrl,
        tempFile,
        expectedSize: platformInfo.size,
        expectedSha256: platformInfo.sha256,
      );

      // Extract
      _progressController.add(DownloadProgress(
        bytesReceived: platformInfo.size ?? 0,
        totalBytes: platformInfo.size ?? 0,
        status: 'Extracting...',
      ));

      await _extractZip(tempFile);

      // Write version file
      await _writeInstalledVersion(expected.version);

      _progressController.add(DownloadProgress(
        bytesReceived: platformInfo.size ?? 0,
        totalBytes: platformInfo.size ?? 0,
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
      } else {
        await Directory(filePath).create(recursive: true);
      }
    }

    // On macOS, remove quarantine attribute to allow execution without Gatekeeper blocking
    if (Platform.isMacOS) {
      await _removeQuarantine(depsDir.path);
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
