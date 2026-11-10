import 'dart:io';

/// Per-video pitch factor files for the Stabilize pass ("From File" mode,
/// issue #150).
///
/// A factor file belongs to one film, so it is picked up per video: a
/// sidecar next to the video is found automatically when the video is added
/// to the queue, which makes a batch of reels work without choosing a file
/// for each. The worker does the authoritative parsing (and reports a bad line
/// by number); [inspect] is only a quick summary for the settings panel.
class PitchFactorFile {
  PitchFactorFile._();

  /// File extensions offered by the file picker.
  static const pickerExtensions = ['txt', 'csv', 'log'];

  /// Sidecar names tried, in order, for `/dir/reel1.mp4`:
  /// `reel1.mp4.pitch.txt`, `reel1.pitch.txt`, `reel1_pitch.txt`.
  static List<String> sidecarCandidates(String videoPath) {
    final dot = videoPath.lastIndexOf('.');
    final sep = videoPath.lastIndexOf(RegExp(r'[/\\]'));
    final stem = dot > sep ? videoPath.substring(0, dot) : videoPath;
    return [
      '$videoPath.pitch.txt',
      '$stem.pitch.txt',
      '${stem}_pitch.txt',
    ];
  }

  /// The first existing sidecar for [videoPath], or null.
  static String? findSidecar(String videoPath) {
    for (final candidate in sidecarCandidates(videoPath)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// A quick look at [path]: how many factors it holds, or why it can't be
  /// used. Mirrors the worker's rules (comments, blank lines, bare factors or
  /// `frame,factor`).
  static Future<PitchFactorFileInfo> inspect(String path) async {
    final String text;
    try {
      text = await File(path).readAsString();
    } catch (e) {
      return PitchFactorFileInfo.error('Cannot read the file');
    }
    return parse(text);
  }

  /// Summarise factor-file [text]. See [inspect].
  static PitchFactorFileInfo parse(String text) {
    var bare = 0;
    var maxFrame = -1;
    var indexed = 0;
    final lines = text.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].split('#').first.trim().replaceFirst('﻿', '');
      if (line.isEmpty) continue;
      final fields = line.split(RegExp(r'[,;\s]+')).where((f) => f.isNotEmpty).toList();
      final factorText = fields.length == 1 ? fields[0] : (fields.length == 2 ? fields[1] : null);
      final factor = factorText == null ? null : double.tryParse(factorText);
      if (factor == null || !factor.isFinite || factor <= 0) {
        return PitchFactorFileInfo.error('Line ${i + 1} is not a valid factor');
      }
      if (fields.length == 1) {
        bare++;
      } else {
        final frame = int.tryParse(fields[0]);
        if (frame == null || frame < 0) {
          return PitchFactorFileInfo.error('Line ${i + 1} has an invalid frame number');
        }
        indexed++;
        if (frame > maxFrame) maxFrame = frame;
      }
    }
    if (bare > 0 && indexed > 0) {
      return PitchFactorFileInfo.error('Mixes bare factors and "frame,factor" lines');
    }
    final count = bare > 0 ? bare : maxFrame + 1;
    if (count <= 0) return PitchFactorFileInfo.error('Contains no factors');
    return PitchFactorFileInfo(count);
  }
}

/// Result of [PitchFactorFile.inspect].
class PitchFactorFileInfo {
  /// Number of frames covered, or null when [error] is set.
  final int? frameCount;
  final String? error;

  const PitchFactorFileInfo(int this.frameCount) : error = null;
  const PitchFactorFileInfo.error(String this.error) : frameCount = null;

  bool get isValid => error == null;

  /// One-line status for the settings panel, given the video's frame count.
  String describe(int? videoFrames) {
    if (!isValid) return error!;
    final n = frameCount!;
    if (videoFrames == null || videoFrames <= 0) return '$n factors';
    if (n == videoFrames) return '$n factors — one per frame';
    if (n < videoFrames) {
      return '$n factors for $videoFrames frames — frames past the end are left uncorrected';
    }
    return '$n factors for $videoFrames frames — the extra factors are ignored';
  }
}
