import 'dart:io';

import '../models/video_job.dart';
import 'tool_locator.dart';

/// Detects available hardware video encoders by probing the bundled FFmpeg.
class HardwareEncoderDetector {
  HardwareEncoderDetector._();

  static final HardwareEncoderDetector instance = HardwareEncoderDetector._();

  final Set<String> _availableEncoders = {};
  bool _initialized = false;

  /// Initialize by probing FFmpeg for available encoders.
  Future<void> initialize() async {
    if (_initialized) return;

    final ffmpegPath = ToolLocator.instance.ffmpegPath;
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
      // FFmpeg not available or failed - hardware encoders won't be detected
    }

    final detected = VideoCodec.values.where((c) => c.isHardwareEncoder && isDetected(c)).map((c) => c.value);
    print('HardwareEncoderDetector: detected encoders: ${detected.isEmpty ? "none" : detected.join(", ")}');

    _initialized = true;
  }

  /// Whether a hardware codec was reported by ffmpeg's `-encoders` list.
  ///
  /// Note: ffmpeg reports all encoders *compiled into* the binary, not just
  /// those supported by the current hardware. A codec reported here may still
  /// fail at runtime if the required GPU/driver is not present.
  /// Returns true for non-hardware codecs (software, ProRes, FFV1).
  bool isDetected(VideoCodec codec) {
    if (!codec.isHardwareEncoder) return true;
    return _availableEncoders.contains(codec.value);
  }

}
