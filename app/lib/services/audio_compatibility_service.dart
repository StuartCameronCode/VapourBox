import 'dart:convert';
import 'dart:io';

import '../models/encoding_settings.dart';
import '../models/output_capabilities_table.dart';
import '../models/video_job.dart';
import 'tool_locator.dart';

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
  AudioCompatibilityService();

  /// Audio codecs (ffprobe `codec_name`) each container's FFmpeg muxer accepts
  /// for `-c:a copy` — what the bundled FFmpeg actually does, not what a
  /// player is guaranteed to open — from the output capability table
  /// (`audioCopy` in `Tests/TestResources/output_capabilities.json`, task
  /// #49), which the worker reads too and refuses the same copies with.
  /// Anything missing is blocked before the job starts (issue #118: `mp2`
  /// was missing everywhere, so VHS/DVD MPEG audio could not be passed
  /// through at all). `output_capabilities_test.dart` checks every entry,
  /// both ways, against the bundled FFmpeg.

  /// Every codec any container accepts — the set the test sweeps.
  static Set<String> get knownCodecs =>
      {for (final codecs in outputAudioCopy.values) ...codecs};

  /// Why a copy of [codec] can't go into [container], or null when it can.
  /// The same words as the worker's refusal (`audio_copy_problem`). With
  /// [videoCodec], the "save as" list names only containers that also offer
  /// that video codec (task #132), as the worker's does for the job's codec.
  static String? copyProblem(String codec, ContainerFormat container,
      {VideoCodec? videoCodec}) {
    if (container.copies(codec)) return null;
    final others = ContainerFormat.values
        .where((k) => k != container && k.copies(codec))
        .where((k) => videoCodec == null || videoCodec.supportsContainer(k))
        .map((k) => k.shortName);
    final message = outputAudioCopyMessage
        .replaceAll('{codec}', codec.toUpperCase())
        .replaceAll('{container}', container.shortName);
    return others.isEmpty
        ? message.replaceAll(', or save as {containers}', '')
        : message.replaceAll('{containers}', joinOr(others));
  }

  /// Suggested fallback codec for each container.
  static const Map<ContainerFormat, String> _fallbackCodecs = {
    ContainerFormat.mp4: 'aac',
    ContainerFormat.mkv: 'aac',
    ContainerFormat.mov: 'aac',
    ContainerFormat.avi: 'mp3',
  };

  /// Get audio information from a video file.
  Future<AudioInfo> getAudioInfo(String videoPath) async {
    final ffprobe = ToolLocator.instance.ffprobePath;
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
  bool isCodecCompatible(String codec, ContainerFormat container) =>
      container.copies(codec);

  /// The containers that can take a copy of [codec] and are offered for
  /// [videoCodec] (task #132): the audio copy table and the video verdict
  /// together, so a container switch never makes a pair the worker refuses
  /// (AV1 in MOV/AVI, v210 or ProRes in MP4) or one the app doesn't offer.
  static List<ContainerFormat> compatibleContainers(
          String codec, VideoCodec videoCodec) =>
      ContainerFormat.values
          .where((k) => k.copies(codec) && videoCodec.supportsContainer(k))
          .toList();

  /// Get the suggested fallback codec for a container.
  String getSuggestedCodec(ContainerFormat container) {
    return _fallbackCodecs[container] ?? 'aac';
  }

  /// Check audio compatibility for an export operation.
  ///
  /// Returns a result indicating whether the input audio codec is compatible
  /// with the selected output container, and provides alternatives if not:
  /// containers that hold both the copied sound and [videoCodec].
  Future<AudioCompatibilityResult> checkCompatibility({
    required String inputPath,
    required ContainerFormat outputContainer,
    required AudioMode audioMode,
    required VideoCodec videoCodec,
  }) async {
    final audioInfo = await getAudioInfo(inputPath);
    return resultFor(
      audioInfo: audioInfo,
      outputContainer: outputContainer,
      audioMode: audioMode,
      videoCodec: videoCodec,
    );
  }

  /// [checkCompatibility] for an already probed [audioInfo].
  static AudioCompatibilityResult resultFor({
    required AudioInfo audioInfo,
    required ContainerFormat outputContainer,
    required AudioMode audioMode,
    required VideoCodec videoCodec,
  }) {
    final suggested = _fallbackCodecs[outputContainer] ?? 'aac';
    // If no audio, audio disabled, or re-encoding audio, always compatible
    if (!audioInfo.hasAudio || audioMode != AudioMode.passthrough) {
      return AudioCompatibilityResult(
        audioInfo: audioInfo,
        container: outputContainer,
        isCompatible: true,
        compatibleContainers: ContainerFormat.values
            .where(videoCodec.supportsContainer)
            .toList(),
        suggestedCodec: suggested,
      );
    }

    final codec = audioInfo.codec!;
    return AudioCompatibilityResult(
      audioInfo: audioInfo,
      container: outputContainer,
      isCompatible: outputContainer.copies(codec),
      incompatibilityReason:
          copyProblem(codec, outputContainer, videoCodec: videoCodec),
      compatibleContainers: compatibleContainers(codec, videoCodec),
      suggestedCodec: suggested,
    );
  }

  int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}
