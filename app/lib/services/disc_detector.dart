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

  /// Checks if a given path contains a VIDEO_TS directory (or IS a VIDEO_TS directory).
  /// Returns the parent path (mount point) if found, or null.
  static Future<String?> findVideoTsParent(String path) async {
    // Check if path itself is named VIDEO_TS
    final dirName = path.replaceAll('\\', '/').split('/').last.toUpperCase();
    if (dirName == 'VIDEO_TS') {
      final parent = Directory(path).parent.path;
      if (await File('$path/VIDEO_TS.IFO').exists() ||
          await File('$path/video_ts.ifo').exists()) {
        return parent;
      }
    }

    // Check if path contains VIDEO_TS
    final videoTsDir = Directory('$path/VIDEO_TS');
    if (await videoTsDir.exists()) {
      // Verify it has IFO files
      if (await File('$path/VIDEO_TS/VIDEO_TS.IFO').exists() ||
          await File('$path/VIDEO_TS/video_ts.ifo').exists()) {
        return path;
      }
    }

    return null;
  }
}
