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

  /// Output directory. If null, uses the same directory as the input file.
  final String? outputDirectory;

  /// Filename pattern for output files. Supports placeholders:
  /// - {input_filename} - Original filename without extension
  /// - {date} - Current date (YYYY-MM-DD)
  /// - {time} - Current time (HH-MM-SS)
  final String filenamePattern;

  const EncodingSettings({
    this.codec = VideoCodec.h264,
    this.encoderPreset = 'medium',
    this.quality = 18,
    this.audioCopy = true,
    this.audioCodec = 'aac',
    this.audioBitrate = 192,
    this.customFfmpegArgs = '',
    this.container = ContainerFormat.mkv,
    this.outputDirectory,
    this.filenamePattern = '{input_filename}_processed',
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
    String? outputDirectory,
    bool clearOutputDirectory = false,
    String? filenamePattern,
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
      outputDirectory: clearOutputDirectory ? null : (outputDirectory ?? this.outputDirectory),
      filenamePattern: filenamePattern ?? this.filenamePattern,
    );
  }

  /// Generate the output filename from a pattern and input filename.
  String generateOutputFilename(String inputFilename) {
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr = '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}';

    return filenamePattern
        .replaceAll('{input_filename}', inputFilename)
        .replaceAll('{date}', dateStr)
        .replaceAll('{time}', timeStr);
  }
}
