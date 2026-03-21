// DVD information models for title enumeration.
// These match the Rust worker's JSON output.

/// Complete information about a DVD disc.
class DvdInfo {
  final String volumeLabel;
  final String devicePath;
  final List<DvdTitle> titles;

  const DvdInfo({
    required this.volumeLabel,
    required this.devicePath,
    required this.titles,
  });

  factory DvdInfo.fromJson(Map<String, dynamic> json) {
    return DvdInfo(
      volumeLabel: json['volumeLabel'] as String? ?? '',
      devicePath: json['devicePath'] as String? ?? '',
      titles: (json['titles'] as List?)
              ?.map((t) => DvdTitle.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// Information about a single DVD title.
class DvdTitle {
  final int index;
  final double durationSeconds;
  final List<DvdChapter> chapters;
  final List<DvdAudioTrack> audioTracks;
  final int width;
  final int height;
  final double frameRate;
  final String aspectRatio;
  final int angles;
  final int vtsNumber;

  const DvdTitle({
    required this.index,
    required this.durationSeconds,
    required this.chapters,
    required this.audioTracks,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.aspectRatio,
    required this.angles,
    required this.vtsNumber,
  });

  factory DvdTitle.fromJson(Map<String, dynamic> json) {
    return DvdTitle(
      index: json['index'] as int? ?? 0,
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 0.0,
      chapters: (json['chapters'] as List?)
              ?.map((c) => DvdChapter.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [],
      audioTracks: (json['audioTracks'] as List?)
              ?.map((a) => DvdAudioTrack.fromJson(a as Map<String, dynamic>))
              .toList() ??
          [],
      width: json['width'] as int? ?? 720,
      height: json['height'] as int? ?? 480,
      frameRate: (json['frameRate'] as num?)?.toDouble() ?? 29.97,
      aspectRatio: json['aspectRatio'] as String? ?? '4:3',
      angles: json['angles'] as int? ?? 1,
      vtsNumber: json['vtsNumber'] as int? ?? 1,
    );
  }

  /// Formatted duration string (e.g., "1:23:45").
  String get durationFormatted {
    final totalSecs = durationSeconds.toInt();
    final hours = totalSecs ~/ 3600;
    final minutes = (totalSecs % 3600) ~/ 60;
    final seconds = totalSecs % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// Resolution string (e.g., "720x480").
  String get resolution => '${width}x$height';

  /// Video system string (e.g., "NTSC" or "PAL").
  String get videoSystem => height <= 480 ? 'NTSC' : 'PAL';

  /// Audio summary string (e.g., "English AC3 5.1, French AC3 2.0").
  String get audioSummary {
    if (audioTracks.isEmpty) return 'No audio';
    return audioTracks.map((a) => a.summary).join(', ');
  }
}

/// Information about a single chapter within a title.
class DvdChapter {
  final int index;
  final double durationSeconds;

  const DvdChapter({
    required this.index,
    required this.durationSeconds,
  });

  factory DvdChapter.fromJson(Map<String, dynamic> json) {
    return DvdChapter(
      index: json['index'] as int? ?? 0,
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// Formatted duration string.
  String get durationFormatted {
    final totalSecs = durationSeconds.toInt();
    final minutes = totalSecs ~/ 60;
    final seconds = totalSecs % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

/// Information about an audio track.
class DvdAudioTrack {
  final int index;
  final String language;
  final String format;
  final int channels;
  final int sampleRate;

  const DvdAudioTrack({
    required this.index,
    required this.language,
    required this.format,
    required this.channels,
    required this.sampleRate,
  });

  factory DvdAudioTrack.fromJson(Map<String, dynamic> json) {
    return DvdAudioTrack(
      index: json['index'] as int? ?? 0,
      language: json['language'] as String? ?? 'und',
      format: json['format'] as String? ?? 'Unknown',
      channels: json['channels'] as int? ?? 2,
      sampleRate: json['sampleRate'] as int? ?? 48000,
    );
  }

  /// Channel layout string (e.g., "5.1", "2.0").
  String get channelLayout {
    switch (channels) {
      case 1:
        return '1.0';
      case 2:
        return '2.0';
      case 6:
        return '5.1';
      case 8:
        return '7.1';
      default:
        return '$channels ch';
    }
  }

  /// Summary string (e.g., "English AC3 5.1").
  String get summary => '$language $format $channelLayout';
}
