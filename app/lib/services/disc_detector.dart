import 'dart:io';

/// Represents a detected DVD disc.
class DvdDisc {
  /// Mount point path (e.g., /Volumes/MY_DVD or D:\)
  final String mountPoint;

  /// Volume label derived from mount point
  final String volumeLabel;

  const DvdDisc({required this.mountPoint, required this.volumeLabel});
}

/// Detects mounted DVDs by scanning for VIDEO_TS directories.
class DiscDetector {
  /// Scans for mounted DVD discs.
  ///
  /// On macOS: scans /Volumes/*/VIDEO_TS
  /// On Windows: checks drive letters D:\ through Z:\ for VIDEO_TS
  Future<List<DvdDisc>> detectDiscs() async {
    if (Platform.isMacOS) {
      return _detectMacOS();
    } else if (Platform.isWindows) {
      return _detectWindows();
    } else if (Platform.isLinux) {
      return _detectLinux();
    }
    return [];
  }

  Future<List<DvdDisc>> _detectMacOS() async {
    final discs = <DvdDisc>[];
    final volumesDir = Directory('/Volumes');
    if (!await volumesDir.exists()) return discs;

    await for (final entity in volumesDir.list()) {
      if (entity is Directory) {
        final videoTsDir = Directory('${entity.path}/VIDEO_TS');
        if (await videoTsDir.exists()) {
          final label = entity.path.split('/').last;
          discs.add(DvdDisc(
            mountPoint: entity.path,
            volumeLabel: label,
          ));
        }
      }
    }

    return discs;
  }

  Future<List<DvdDisc>> _detectWindows() async {
    final discs = <DvdDisc>[];

    // Check drive letters D: through Z:
    for (var code = 68; code <= 90; code++) {
      final letter = String.fromCharCode(code);
      final drivePath = '$letter:\\';
      final videoTsDir = Directory('$drivePath\\VIDEO_TS');

      try {
        if (await videoTsDir.exists()) {
          discs.add(DvdDisc(
            mountPoint: drivePath,
            volumeLabel: letter,
          ));
        }
      } catch (_) {
        // Drive not accessible, skip
      }
    }

    return discs;
  }

  Future<List<DvdDisc>> _detectLinux() async {
    final discs = <DvdDisc>[];
    final user = Platform.environment['USER'] ?? '';

    // Scan common Linux mount points for VIDEO_TS directories
    final mountDirs = <String>[
      '/media/$user',       // Ubuntu auto-mount
      '/run/media/$user',   // systemd auto-mount (Fedora/Arch)
      '/mnt',               // Manual mounts
    ];

    for (final mountDir in mountDirs) {
      final dir = Directory(mountDir);
      if (!await dir.exists()) continue;

      try {
        await for (final entity in dir.list()) {
          if (entity is Directory) {
            final videoTsDir = Directory('${entity.path}/VIDEO_TS');
            if (await videoTsDir.exists()) {
              final label = entity.path.split('/').last;
              discs.add(DvdDisc(
                mountPoint: entity.path,
                volumeLabel: label,
              ));
            }
          }
        }
      } catch (_) {
        // Directory not accessible, skip
      }
    }

    return discs;
  }

  /// Decides whether [path] is a ripped DVD, and if so returns the path to
  /// hand the worker's `--dvd-info` / `--dvd-extract`. Returns null for an
  /// ordinary folder, which the caller should scan for video files instead.
  ///
  /// Three shapes count as a DVD, in this order:
  ///
  /// 1. [path] **is** a `VIDEO_TS` directory holding an IFO — the disc root is
  ///    its parent.
  /// 2. [path] **contains** a `VIDEO_TS` directory holding an IFO — the usual
  ///    mounted disc or a rip that kept the wrapping directory.
  /// 3. [path] holds the VIDEO_TS *contents* directly (a "flat" rip, named
  ///    after the disc): an IFO **and** at least one `.VOB`.
  ///
  /// Case 3 demands a VOB where the first two do not, deliberately. A folder
  /// with a `VIDEO_TS` subdirectory is unambiguous, but a flat folder is
  /// ordinary until proven otherwise, and a stray IFO next to unrelated videos
  /// must not hijack the whole folder into the DVD flow. An IFO with no VOB is
  /// not extractable anyway.
  static Future<String?> findDvdRoot(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return null;

    // 1. The path itself is a VIDEO_TS directory.
    final dirName = path.replaceAll('\\', '/').split('/').last.toUpperCase();
    if (dirName == 'VIDEO_TS' && await _hasDvdIfo(dir)) {
      return dir.parent.path;
    }

    // 2. A VIDEO_TS subdirectory (matched case-insensitively, since only
    //    Windows and macOS resolve the case for us).
    final videoTs = await _findChildDirectory(dir, 'video_ts');
    if (videoTs != null && await _hasDvdIfo(videoTs)) {
      return path;
    }

    // 3. A flat rip: VIDEO_TS contents sitting directly in the folder.
    if (await _hasDvdIfo(dir) && await _hasVob(dir)) {
      return path;
    }

    return null;
  }

  /// Case-insensitive lookup of a child directory by [name] (already lowercase).
  static Future<Directory?> _findChildDirectory(
      Directory parent, String name) async {
    try {
      await for (final entity in parent.list(followLinks: false)) {
        if (entity is Directory &&
            entity.path.replaceAll('\\', '/').split('/').last.toLowerCase() ==
                name) {
          return entity;
        }
      }
    } catch (_) {
      // Unreadable directory — treat as not a DVD.
    }
    return null;
  }

  /// Whether [dir] directly contains `VIDEO_TS.IFO` or a `VTS_nn_0.IFO`.
  static Future<bool> _hasDvdIfo(Directory dir) =>
      _anyFile(dir, (name) => name == 'video_ts.ifo' || _vtsIfo.hasMatch(name));

  /// Whether [dir] directly contains any `.VOB`.
  static Future<bool> _hasVob(Directory dir) =>
      _anyFile(dir, (name) => name.endsWith('.vob'));

  static final RegExp _vtsIfo = RegExp(r'^vts_\d{2}_0\.ifo$');

  /// Whether any file directly in [dir] has a lowercased name matching [test].
  static Future<bool> _anyFile(
      Directory dir, bool Function(String name) test) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name =
            entity.path.replaceAll('\\', '/').split('/').last.toLowerCase();
        if (test(name)) return true;
      }
    } catch (_) {
      // Unreadable directory — treat as not a DVD.
    }
    return false;
  }
}
