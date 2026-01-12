import 'package:json_annotation/json_annotation.dart';

import 'video_job.dart';

part 'encoding_settings.g.dart';

/// Video encoding settings for FFmpeg output.
@JsonSerializable()
class EncodingSettings {
  final VideoCodec codec;
  final String encoderPreset;
  final int quality;
  final bool audioCopy;
  final String audioCodec;
  final int audioBitrate;
  final String customFfmpegArgs;
  final ContainerFormat container;

  const EncodingSettings({
    this.codec = VideoCodec.h264,
    this.encoderPreset = 'medium',
    this.quality = 18,
    this.audioCopy = true,
    this.audioCodec = 'aac',
    this.audioBitrate = 192,
    this.customFfmpegArgs = '',
    this.container = ContainerFormat.mp4,
  });

  factory EncodingSettings.fromJson(Map<String, dynamic> json) =>
      _$EncodingSettingsFromJson(json);
  Map<String, dynamic> toJson() => _$EncodingSettingsToJson(this);

  /// Alias for audioCopy for clearer naming in UI.
  bool get copyAudio => audioCopy;

  /// Human-readable quality description.
  String get qualityDescription {
    if (quality <= 15) return 'Very High (CRF $quality)';
    if (quality <= 20) return 'High (CRF $quality)';
    if (quality <= 25) return 'Medium (CRF $quality)';
    if (quality <= 30) return 'Low (CRF $quality)';
    return 'Very Low (CRF $quality)';
  }

  EncodingSettings copyWith({
    VideoCodec? codec,
    String? encoderPreset,
    int? quality,
    bool? audioCopy,
    bool? copyAudio,
    String? audioCodec,
    int? audioBitrate,
    String? customFfmpegArgs,
    ContainerFormat? container,
  }) {
    return EncodingSettings(
      codec: codec ?? this.codec,
      encoderPreset: encoderPreset ?? this.encoderPreset,
      quality: quality ?? this.quality,
      audioCopy: audioCopy ?? copyAudio ?? this.audioCopy,
      audioCodec: audioCodec ?? this.audioCodec,
      audioBitrate: audioBitrate ?? this.audioBitrate,
      customFfmpegArgs: customFfmpegArgs ?? this.customFfmpegArgs,
      container: container ?? this.container,
    );
  }
}
