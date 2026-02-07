import 'package:json_annotation/json_annotation.dart';

import 'video_job.dart';

part 'encoding_settings.g.dart';

/// Audio handling mode for output.
@JsonEnum(valueField: 'value')
enum AudioMode {
  /// Copy audio stream without re-encoding.
  passthrough('passthrough', 'Passthrough'),
  /// Re-encode audio with selected codec and quality.
  convert('convert', 'Convert'),
  /// No audio in output.
  none('none', 'None');

  const AudioMode(this.value, this.displayName);

  final String value;
  final String displayName;
}

/// Audio codecs for re-encoding.
@JsonEnum(valueField: 'value')
enum AudioCodec {
  aac('aac', 'AAC'),
  mp3('libmp3lame', 'MP3'),
  ac3('ac3', 'AC-3 (Dolby Digital)'),
  flac('flac', 'FLAC (Lossless)'),
  opus('libopus', 'Opus'),
  pcm('pcm_s16le', 'PCM (Uncompressed)');

  const AudioCodec(this.value, this.displayName);

  final String value;
  final String displayName;

  /// Whether this is a lossless codec (no quality setting needed).
  bool get isLossless => this == AudioCodec.flac || this == AudioCodec.pcm;
}

/// Audio quality presets (bitrate in kbps).
@JsonEnum(valueField: 'value')
enum AudioQuality {
  low(96, 'Low (96 kbps)'),
  medium(128, 'Medium (128 kbps)'),
  high(192, 'High (192 kbps)'),
  veryHigh(256, 'Very High (256 kbps)');

  const AudioQuality(this.value, this.displayName);

  final int value;
  final String displayName;

  /// Bitrate in kbps.
  int get bitrate => value;
}

/// Output chroma subsampling format.
@JsonEnum(valueField: 'value')
enum ChromaSubsampling {
  /// Keep original format (no conversion).
  original('original', 'Default (keep original)'),
  /// Convert to YUV420 for maximum compatibility (smaller files).
  yuv420('yuv420', '4:2:0 (smaller, compatible)'),
  /// Convert to YUV422 for higher chroma quality.
  yuv422('yuv422', '4:2:2 (higher quality)');

  const ChromaSubsampling(this.value, this.displayName);

  final String value;
  final String displayName;
}

/// Video encoding settings for FFmpeg output.
@JsonSerializable()
class EncodingSettings {
  final VideoCodec codec;
  final String encoderPreset;
  final int quality;

  /// Audio handling mode.
  final AudioMode audioMode;

  /// Audio codec for re-encoding (when audioMode == convert).
  final AudioCodec audioCodec;

  /// Audio quality preset (when audioMode == convert and codec is lossy).
  final AudioQuality audioQuality;

  /// Output chroma subsampling format.
  final ChromaSubsampling chromaSubsampling;

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
    this.audioMode = AudioMode.passthrough,
    this.audioCodec = AudioCodec.aac,
    this.audioQuality = AudioQuality.high,
    this.chromaSubsampling = ChromaSubsampling.original,
    this.customFfmpegArgs = '',
    this.container = ContainerFormat.mkv,
    this.outputDirectory,
    this.filenamePattern = '{input_filename}_processed',
  });

  factory EncodingSettings.fromJson(Map<String, dynamic> json) {
    // Backward compatibility: convert old audioCopy boolean to audioMode
    if (json.containsKey('audioCopy') && !json.containsKey('audioMode')) {
      final audioCopy = json['audioCopy'] as bool? ?? true;
      json['audioMode'] = audioCopy ? 'passthrough' : 'convert';
    }
    // Backward compatibility: convert old string audioCodec to enum
    if (json.containsKey('audioCodec') && json['audioCodec'] is String) {
      final oldCodec = json['audioCodec'] as String;
      // Map old codec strings to new enum values
      const codecMap = {
        'aac': 'aac',
        'libmp3lame': 'libmp3lame',
        'mp3': 'libmp3lame',
        'ac3': 'ac3',
        'flac': 'flac',
        'libopus': 'libopus',
        'opus': 'libopus',
        'pcm_s16le': 'pcm_s16le',
      };
      json['audioCodec'] = codecMap[oldCodec] ?? 'aac';
    }
    // Backward compatibility: convert old audioBitrate to audioQuality
    if (json.containsKey('audioBitrate') && !json.containsKey('audioQuality')) {
      final bitrate = json['audioBitrate'] as int? ?? 192;
      if (bitrate <= 96) {
        json['audioQuality'] = 96;
      } else if (bitrate <= 128) {
        json['audioQuality'] = 128;
      } else if (bitrate <= 192) {
        json['audioQuality'] = 192;
      } else {
        json['audioQuality'] = 256;
      }
    }
    return _$EncodingSettingsFromJson(json);
  }

  Map<String, dynamic> toJson() => _$EncodingSettingsToJson(this);

  /// Backward compatibility: alias for audioMode == passthrough.
  @Deprecated('Use audioMode instead')
  bool get audioCopy => audioMode == AudioMode.passthrough;

  /// Backward compatibility: alias for audioMode == passthrough.
  @Deprecated('Use audioMode instead')
  bool get copyAudio => audioCopy;

  /// Human-readable quality description.
  String get qualityDescription {
    if (codec == VideoCodec.h264Videotoolbox || codec == VideoCodec.h265Videotoolbox) {
      // VideoToolbox: CRF is remapped to q:v (inverted scale) in the worker.
      // Show quality in user-friendly terms based on the CRF value.
      if (quality <= 15) return 'Very High (Quality $quality)';
      if (quality <= 20) return 'High (Quality $quality)';
      if (quality <= 25) return 'Medium (Quality $quality)';
      if (quality <= 30) return 'Low (Quality $quality)';
      return 'Very Low (Quality $quality)';
    }
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
    AudioMode? audioMode,
    AudioCodec? audioCodec,
    AudioQuality? audioQuality,
    ChromaSubsampling? chromaSubsampling,
    String? customFfmpegArgs,
    ContainerFormat? container,
    String? outputDirectory,
    bool clearOutputDirectory = false,
    String? filenamePattern,
    // Backward compatibility
    @Deprecated('Use audioMode instead') bool? copyAudio,
  }) {
    // Handle backward compatibility for copyAudio parameter
    var effectiveAudioMode = audioMode ?? this.audioMode;
    if (copyAudio != null && audioMode == null) {
      effectiveAudioMode = copyAudio ? AudioMode.passthrough : AudioMode.convert;
    }

    return EncodingSettings(
      codec: codec ?? this.codec,
      encoderPreset: encoderPreset ?? this.encoderPreset,
      quality: quality ?? this.quality,
      audioMode: effectiveAudioMode,
      audioCodec: audioCodec ?? this.audioCodec,
      audioQuality: audioQuality ?? this.audioQuality,
      chromaSubsampling: chromaSubsampling ?? this.chromaSubsampling,
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
