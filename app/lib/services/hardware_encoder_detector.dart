import 'dart:io';

import '../models/video_job.dart';

/// Detects available hardware video encoders by probing the bundled FFmpeg.
class HardwareEncoderDetector {
  HardwareEncoderDetector._();

  static final HardwareEncoderDetector instance = HardwareEncoderDetector._();

  final Set<String> _availableEncoders = {};
  bool _initialized = false;

  /// Initialize by probing FFmpeg for available encoders.
  Future<void> initialize() async {
    if (_initialized) return;

    final ffmpegPath = _findFfmpegPath();
    if (ffmpegPath == null) {
      _initialized = true;
      return;
    }

    try {
      final result = await Process.run(
        ffmpegPath,
        ['-encoders', '-hide_banner'],
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      );

      if (result.exitCode == 0) {
        final output = result.stdout as String;
        for (final line in output.split('\n')) {
          final trimmed = line.trim();
          // Encoder lines start with a flags field like "V....D" followed by the encoder name
          if (trimmed.startsWith('V')) {
            final parts = trimmed.split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              _availableEncoders.add(parts[1]);
            }
          }
        }
      }
    } catch (e) {
      // FFmpeg not available or failed - hardware encoders won't be shown
    }

    _initialized = true;
  }

  /// Whether a codec is available on this system.
  /// Software codecs, ProRes, and FFV1 are always available.
  /// Hardware codecs require detection.
  bool isAvailable(VideoCodec codec) {
    if (!codec.isHardwareEncoder) return true;

    // Map Dart enum value to the FFmpeg encoder name used in -encoders output
    const encoderNames = {
      'h264_nvenc': 'h264_nvenc',
      'hevc_nvenc': 'hevc_nvenc',
      'h264_qsv': 'h264_qsv',
      'hevc_qsv': 'hevc_qsv',
      'h264_videotoolbox': 'h264_videotoolbox',
      'hevc_videotoolbox': 'hevc_videotoolbox',
      'h264_amf': 'h264_amf',
      'hevc_amf': 'hevc_amf',
    };

    final encoderName = encoderNames[codec.value];
    if (encoderName == null) return false;
    return _availableEncoders.contains(encoderName);
  }

  /// Get all available codecs (software + detected hardware).
  List<VideoCodec> get availableCodecs {
    return VideoCodec.values.where((c) => isAvailable(c)).toList();
  }

  /// Find the bundled FFmpeg path.
  String? _findFfmpegPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;

    String candidate;
    if (Platform.isWindows) {
      candidate = '$exeDir\\deps\\ffmpeg\\ffmpeg.exe';
    } else if (Platform.isMacOS) {
      candidate = '$exeDir/../Helpers/ffmpeg';
    } else {
      return null;
    }

    if (File(candidate).existsSync()) {
      return candidate;
    }

    // Fallback: try system PATH
    try {
      final result = Process.runSync(
        Platform.isWindows ? 'where' : 'which',
        ['ffmpeg'],
      );
      if (result.exitCode == 0) {
        return (result.stdout as String).trim().split('\n').first;
      }
    } catch (e) {
      // Ignore
    }

    return null;
  }
}
