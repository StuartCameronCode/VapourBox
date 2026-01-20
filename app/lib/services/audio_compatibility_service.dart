import 'dart:convert';
import 'dart:io';

import '../models/video_job.dart';

/// Audio stream information from ffprobe.
class AudioInfo {
  final String? codec;
  final int? sampleRate;
  final int? channels;
  final int? bitrate;

  const AudioInfo({
    this.codec,
    this.sampleRate,
    this.channels,
    this.bitrate,
  });

  bool get hasAudio => codec != null;

  /// Get human-readable description of the audio.
  String get description {
    if (!hasAudio) return 'No audio';
    final parts = <String>[codec!.toUpperCase()];
    if (sampleRate != null) {
      parts.add('${(sampleRate! / 1000).toStringAsFixed(1)} kHz');
    }
    if (channels != null) {
      parts.add(channels == 1 ? 'Mono' : channels == 2 ? 'Stereo' : '$channels ch');
    }
    if (bitrate != null && bitrate! > 0) {
      parts.add('${(bitrate! / 1000).round()} kbps');
    }
    return parts.join(', ');
  }
}

/// Result of audio compatibility check.
class AudioCompatibilityResult {
  final AudioInfo audioInfo;
  final ContainerFormat container;
  final bool isCompatible;
  final String? incompatibilityReason;
  final List<ContainerFormat> compatibleContainers;
  final String suggestedCodec;

  const AudioCompatibilityResult({
    required this.audioInfo,
    required this.container,
    required this.isCompatible,
    this.incompatibilityReason,
    required this.compatibleContainers,
    required this.suggestedCodec,
  });
}

/// Service for checking audio codec compatibility with output containers.
class AudioCompatibilityService {
  /// Path to ffprobe executable.
  final String? ffprobePath;

  AudioCompatibilityService({this.ffprobePath});

  /// Audio codecs compatible with each container format.
  /// Based on common FFmpeg muxer support.
  static const Map<ContainerFormat, Set<String>> _containerCodecSupport = {
    ContainerFormat.mp4: {
      'aac', 'mp3', 'ac3', 'eac3', 'alac', 'opus', 'flac',
    },
    ContainerFormat.mkv: {
      'aac', 'mp3', 'ac3', 'eac3', 'dts', 'truehd', 'flac', 'opus', 'vorbis',
      'pcm_s16le', 'pcm_s24le', 'pcm_s32le', 'pcm_f32le',
      'alac', 'wavpack',
    },
    ContainerFormat.mov: {
      'aac', 'mp3', 'ac3', 'eac3', 'alac', 'pcm_s16le', 'pcm_s24le',
      'pcm_s16be', 'pcm_s24be',
    },
    ContainerFormat.avi: {
      'mp3', 'ac3', 'pcm_s16le', 'pcm_u8',
    },
  };

  /// Suggested fallback codec for each container.
  static const Map<ContainerFormat, String> _fallbackCodecs = {
    ContainerFormat.mp4: 'aac',
    ContainerFormat.mkv: 'aac',
    ContainerFormat.mov: 'aac',
    ContainerFormat.avi: 'mp3',
  };

  /// Get audio information from a video file.
  Future<AudioInfo> getAudioInfo(String videoPath) async {
    final ffprobe = await _findFfprobe();
    if (ffprobe == null) {
      return const AudioInfo();
    }

    try {
      final result = await Process.run(
        ffprobe,
        [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_streams',
          '-select_streams', 'a:0',
          videoPath,
        ],
      );

      if (result.exitCode != 0) {
        return const AudioInfo();
      }

      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final streams = json['streams'] as List<dynamic>?;

      if (streams == null || streams.isEmpty) {
        return const AudioInfo();
      }

      final audioStream = streams[0] as Map<String, dynamic>;

      return AudioInfo(
        codec: audioStream['codec_name'] as String?,
        sampleRate: _parseInt(audioStream['sample_rate']),
        channels: audioStream['channels'] as int?,
        bitrate: _parseInt(audioStream['bit_rate']),
      );
    } catch (e) {
      return const AudioInfo();
    }
  }

  /// Check if an audio codec is compatible with a container format.
  bool isCodecCompatible(String codec, ContainerFormat container) {
    final supported = _containerCodecSupport[container] ?? {};
    return supported.contains(codec.toLowerCase());
  }

  /// Get all containers that support the given audio codec.
  List<ContainerFormat> getCompatibleContainers(String codec) {
    final result = <ContainerFormat>[];
    for (final container in ContainerFormat.values) {
      if (isCodecCompatible(codec, container)) {
        result.add(container);
      }
    }
    return result;
  }

  /// Get the suggested fallback codec for a container.
  String getSuggestedCodec(ContainerFormat container) {
    return _fallbackCodecs[container] ?? 'aac';
  }

  /// Check audio compatibility for an export operation.
  ///
  /// Returns a result indicating whether the input audio codec is compatible
  /// with the selected output container, and provides alternatives if not.
  Future<AudioCompatibilityResult> checkCompatibility({
    required String inputPath,
    required ContainerFormat outputContainer,
    required bool audioCopy,
  }) async {
    final audioInfo = await getAudioInfo(inputPath);

    // If no audio or not copying audio, always compatible
    if (!audioInfo.hasAudio || !audioCopy) {
      return AudioCompatibilityResult(
        audioInfo: audioInfo,
        container: outputContainer,
        isCompatible: true,
        compatibleContainers: ContainerFormat.values.toList(),
        suggestedCodec: getSuggestedCodec(outputContainer),
      );
    }

    final codec = audioInfo.codec!;
    final isCompatible = isCodecCompatible(codec, outputContainer);
    final compatibleContainers = getCompatibleContainers(codec);

    String? reason;
    if (!isCompatible) {
      reason = '${codec.toUpperCase()} audio is not supported in ${outputContainer.displayName} containers. '
          'The audio must be re-encoded or you can choose a different container format.';
    }

    return AudioCompatibilityResult(
      audioInfo: audioInfo,
      container: outputContainer,
      isCompatible: isCompatible,
      incompatibilityReason: reason,
      compatibleContainers: compatibleContainers,
      suggestedCodec: getSuggestedCodec(outputContainer),
    );
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
      // Try production path first
      final prodPath = '$exeDir\\deps\\ffmpeg\\ffprobe.exe';
      if (await File(prodPath).exists()) {
        return prodPath;
      }
      // Try development path
      final devPath = '$exeDir\\..\\..\\..\\..\\..\\..\\deps\\windows-x64\\ffmpeg\\ffprobe.exe';
      if (await File(devPath).exists()) {
        return devPath;
      }
    } else if (Platform.isMacOS) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      // In .app bundle: Contents/MacOS/../../Helpers/ffprobe
      return '$exeDir/../Helpers/ffprobe';
    }
    return null;
  }

  int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}
