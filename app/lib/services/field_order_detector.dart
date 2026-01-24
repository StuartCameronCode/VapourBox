import 'dart:convert';
import 'dart:io';

import '../models/video_job.dart';

/// Detects field order (TFF/BFF) from video files using ffprobe.
class FieldOrderDetector {
  /// Path to ffprobe executable.
  final String? ffprobePath;

  FieldOrderDetector({this.ffprobePath});

  /// Detects the field order of a video file.
  ///
  /// Returns [FieldOrder.topFieldFirst], [FieldOrder.bottomFieldFirst], or [FieldOrder.progressive]
  /// based on the video metadata. Returns null if detection fails.
  Future<FieldOrder?> detect(String videoPath) async {
    final ffprobe = await _findFfprobe();
    if (ffprobe == null) {
      return null;
    }

    try {
      // Run ffprobe to get stream information
      final result = await Process.run(
        ffprobe,
        [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_streams',
          '-select_streams', 'v:0',
          videoPath,
        ],
      );

      if (result.exitCode != 0) {
        return null;
      }

      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final streams = json['streams'] as List<dynamic>?;

      if (streams == null || streams.isEmpty) {
        return null;
      }

      final videoStream = streams[0] as Map<String, dynamic>;

      // Check field_order tag
      final fieldOrder = videoStream['field_order'] as String?;
      if (fieldOrder != null) {
        switch (fieldOrder.toLowerCase()) {
          case 'tt':
          case 'tb':
            return FieldOrder.topFieldFirst;
          case 'bb':
          case 'bt':
            return FieldOrder.bottomFieldFirst;
          case 'progressive':
            return FieldOrder.progressive;
        }
      }

      // Fallback: check codec tags
      final codecTagString = videoStream['codec_tag_string'] as String?;
      if (codecTagString != null) {
        // DV codec usually indicates interlaced content
        if (codecTagString.toLowerCase().contains('dv')) {
          // DV is typically bottom-field-first for NTSC, TFF for PAL
          final frameRate = _parseFrameRate(videoStream['r_frame_rate'] as String?);
          if (frameRate != null && frameRate < 26) {
            // PAL (25fps) is typically TFF
            return FieldOrder.topFieldFirst;
          } else {
            // NTSC (29.97fps) is typically BFF
            return FieldOrder.bottomFieldFirst;
          }
        }
      }

      // Check if interlaced based on codec
      final codecName = videoStream['codec_name'] as String?;
      if (codecName != null && codecName.toLowerCase() == 'mpeg2video') {
        // MPEG-2 often has interlaced content, default to TFF
        return FieldOrder.topFieldFirst;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Gets detailed video information for display.
  Future<VideoInfo?> getVideoInfo(String videoPath) async {
    final ffprobe = await _findFfprobe();
    if (ffprobe == null) {
      return null;
    }

    try {
      final result = await Process.run(
        ffprobe,
        [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_streams',
          '-show_format',
          videoPath,
        ],
      );

      if (result.exitCode != 0) {
        return null;
      }

      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final streams = json['streams'] as List<dynamic>?;
      final format = json['format'] as Map<String, dynamic>?;

      if (streams == null || streams.isEmpty) {
        return null;
      }

      // Find video stream
      Map<String, dynamic>? videoStream;
      Map<String, dynamic>? audioStream;

      for (final stream in streams) {
        final s = stream as Map<String, dynamic>;
        final codecType = s['codec_type'] as String?;
        if (codecType == 'video' && videoStream == null) {
          videoStream = s;
        } else if (codecType == 'audio' && audioStream == null) {
          audioStream = s;
        }
      }

      if (videoStream == null) {
        return null;
      }

      final width = videoStream['width'] as int?;
      final height = videoStream['height'] as int?;
      final frameRate = _parseFrameRate(videoStream['r_frame_rate'] as String?);
      final duration = _parseDuration(format?['duration'] as String?);
      final frameCount = _parseFrameCount(videoStream['nb_frames'] as String?);
      final codec = videoStream['codec_name'] as String?;
      final pixelFormat = videoStream['pix_fmt'] as String?;
      final fieldOrder = await detect(videoPath);

      return VideoInfo(
        width: width ?? 0,
        height: height ?? 0,
        frameRate: frameRate ?? 0,
        duration: duration ?? 0,
        frameCount: frameCount ?? _estimateFrameCount(duration, frameRate),
        codec: codec ?? 'unknown',
        pixelFormat: pixelFormat ?? 'unknown',
        fieldOrder: fieldOrder,
        hasAudio: audioStream != null,
      );
    } catch (e) {
      return null;
    }
  }

  Future<String?> _findFfprobe() async {
    // Use provided path if available
    if (ffprobePath != null && await File(ffprobePath!).exists()) {
      return ffprobePath;
    }

    // Check bundled location
    final bundledPath = await _getBundledFfprobePath();
    if (bundledPath != null && await File(bundledPath).exists()) {
      return bundledPath;
    }

    // Try system PATH
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        ['ffprobe'],
      );
      if (result.exitCode == 0) {
        return (result.stdout as String).trim().split('\n').first;
      }
    } catch (e) {
      // Ignore
    }

    return null;
  }

  Future<String?> _getBundledFfprobePath() async {
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return '$exeDir\\deps\\ffmpeg\\ffprobe.exe';
    } else if (Platform.isMacOS) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      // In .app bundle: Contents/MacOS/../../Helpers/ffprobe
      return '$exeDir/../Helpers/ffprobe';
    }
    return null;
  }

  double? _parseFrameRate(String? rateStr) {
    if (rateStr == null) return null;

    final parts = rateStr.split('/');
    if (parts.length == 2) {
      final num = double.tryParse(parts[0]);
      final den = double.tryParse(parts[1]);
      if (num != null && den != null && den != 0) {
        return num / den;
      }
    }
    return double.tryParse(rateStr);
  }

  double? _parseDuration(String? durationStr) {
    if (durationStr == null) return null;
    return double.tryParse(durationStr);
  }

  int? _parseFrameCount(String? countStr) {
    if (countStr == null) return null;
    return int.tryParse(countStr);
  }

  int _estimateFrameCount(double? duration, double? frameRate) {
    if (duration == null || frameRate == null) return 0;
    return (duration * frameRate).round();
  }
}

/// Video file information.
class VideoInfo {
  final int width;
  final int height;
  final double frameRate;
  final double duration;
  final int frameCount;
  final String codec;
  final String pixelFormat;
  final FieldOrder? fieldOrder;
  final bool hasAudio;

  const VideoInfo({
    required this.width,
    required this.height,
    required this.frameRate,
    required this.duration,
    required this.frameCount,
    required this.codec,
    required this.pixelFormat,
    this.fieldOrder,
    required this.hasAudio,
  });

  String get resolution => '${width}x$height';

  String get frameRateFormatted => '${frameRate.toStringAsFixed(2)} fps';

  String get durationFormatted {
    final totalSecs = duration.toInt();
    final hours = totalSecs ~/ 3600;
    final minutes = (totalSecs % 3600) ~/ 60;
    final seconds = totalSecs % 60;

    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    } else {
      return '${seconds}s';
    }
  }

  String get fieldOrderDescription {
    switch (fieldOrder) {
      case FieldOrder.topFieldFirst:
        return 'Top Field First (interlaced)';
      case FieldOrder.bottomFieldFirst:
        return 'Bottom Field First (interlaced)';
      case FieldOrder.progressive:
        return 'Progressive';
      case FieldOrder.unknown:
      case null:
        return 'Unknown';
    }
  }
}
