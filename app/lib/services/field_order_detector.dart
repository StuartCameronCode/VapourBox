import 'dart:convert';
import 'dart:io';

import '../models/video_job.dart';
import 'tool_locator.dart';

/// Detects field order (TFF/BFF) from video files using ffprobe.
class FieldOrderDetector {
  FieldOrderDetector();

  /// Detects the field order of a video file.
  ///
  /// Returns [FieldOrder.topFieldFirst], [FieldOrder.bottomFieldFirst], or [FieldOrder.progressive]
  /// based on the video metadata. Returns null if detection fails.
  Future<FieldOrder?> detect(String videoPath) async {
    final ffprobe = ToolLocator.instance.ffprobePath;
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
    final ffprobe = ToolLocator.instance.ffprobePath;
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

      // Detect scan type (telecine vs interlaced vs progressive)
      final scanType = await _detectScanType(
        videoPath, videoStream, fieldOrder, frameRate,
      );

      return VideoInfo(
        width: width ?? 0,
        height: height ?? 0,
        frameRate: frameRate ?? 0,
        duration: duration ?? 0,
        frameCount: frameCount ?? _estimateFrameCount(duration, frameRate),
        codec: codec ?? 'unknown',
        pixelFormat: pixelFormat ?? 'unknown',
        fieldOrder: fieldOrder,
        scanType: scanType,
        hasAudio: audioStream != null,
      );
    } catch (e) {
      return null;
    }
  }

  /// Detect whether the video is telecine, interlaced, or progressive.
  ///
  /// Telecine detection uses ffprobe frame analysis to check for repeat_pict
  /// flags that indicate soft telecine (3:2 pulldown). Also uses heuristics
  /// based on codec type and frame rate.
  Future<ScanType> _detectScanType(
    String videoPath,
    Map<String, dynamic> videoStream,
    FieldOrder? fieldOrder,
    double? frameRate,
  ) async {
    // Progressive content
    if (fieldOrder == FieldOrder.progressive) {
      return ScanType.progressive;
    }

    final codec = videoStream['codec_name'] as String? ?? '';
    final codecLower = codec.toLowerCase();

    // Check for soft telecine via frame analysis (repeat_pict flags)
    final hasTelecine = await _detectSoftTelecine(videoPath);
    if (hasTelecine) {
      return ScanType.telecine;
    }

    // Heuristic: MPEG-2 at ~29.97fps with progressive field_order is likely telecine
    if (codecLower == 'mpeg2video' && frameRate != null) {
      final streamFieldOrder = videoStream['field_order'] as String? ?? '';
      if (streamFieldOrder.toLowerCase() == 'progressive' &&
          frameRate > 29.0 && frameRate < 30.0) {
        return ScanType.telecine;
      }
    }

    // If we have a detected field order (TFF/BFF), it's interlaced
    if (fieldOrder == FieldOrder.topFieldFirst ||
        fieldOrder == FieldOrder.bottomFieldFirst) {
      return ScanType.interlaced;
    }

    return ScanType.unknown;
  }

  /// Check for soft telecine by analyzing frame repeat_pict flags.
  ///
  /// Soft telecine uses repeat_pict to indicate which fields should be
  /// repeated to create 3:2 pulldown. A pattern of alternating 0 and 1
  /// values in repeat_pict strongly indicates telecine.
  Future<bool> _detectSoftTelecine(String videoPath) async {
    final ffprobe = ToolLocator.instance.ffprobePath;
    if (ffprobe == null) return false;

    try {
      final result = await Process.run(
        ffprobe,
        [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_frames',
          '-select_streams', 'v:0',
          '-read_intervals', '%+#30', // Sample first ~30 frames
          videoPath,
        ],
        // Timeout to avoid hanging on large files
      ).timeout(const Duration(seconds: 15), onTimeout: () {
        return ProcessResult(0, 1, '', 'timeout');
      });

      if (result.exitCode != 0) return false;

      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final frames = json['frames'] as List<dynamic>?;
      if (frames == null || frames.length < 10) return false;

      // Count frames with repeat_pict > 0
      int repeatCount = 0;
      int totalFrames = 0;

      for (final frame in frames) {
        final f = frame as Map<String, dynamic>;
        if (f['media_type'] != 'video') continue;
        totalFrames++;

        final repeatPict = f['repeat_pict'] as int? ?? 0;
        if (repeatPict > 0) {
          repeatCount++;
        }
      }

      // In 3:2 pulldown, approximately 2 out of every 5 frames have repeat_pict=1
      // So ~40% of frames should have repeat_pict > 0
      if (totalFrames >= 10) {
        final ratio = repeatCount / totalFrames;
        if (ratio > 0.25 && ratio < 0.55) {
          return true;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
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

/// Detected scan type of the video content.
enum ScanType {
  /// Standard interlaced content (e.g., 50i/60i broadcast).
  interlaced,
  /// Telecined content (film with 3:2 pulldown, e.g., NTSC DVD).
  telecine,
  /// Progressive content (no interlacing).
  progressive,
  /// Could not determine scan type.
  unknown;

  String get displayName {
    switch (this) {
      case ScanType.interlaced:
        return 'Interlaced';
      case ScanType.telecine:
        return 'Telecine (3:2 pulldown)';
      case ScanType.progressive:
        return 'Progressive';
      case ScanType.unknown:
        return 'Unknown';
    }
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
  final ScanType scanType;
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
    this.scanType = ScanType.unknown,
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
