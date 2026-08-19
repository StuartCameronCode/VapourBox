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
///
/// Mirrors `ChromaSubsampling` in `worker/src/models/video_job.rs` — the [value]
/// strings must match that enum's serde names.
@JsonEnum(valueField: 'value')
enum ChromaSubsampling {
  /// Keep original format (no conversion), bit depth included.
  original('original', 'Match source', null, null),
  /// Convert to 8-bit YUV420 for maximum compatibility (smaller files).
  yuv420('yuv420', '4:2:0 8-bit', 'most compatible', 8),
  /// Convert to 10-bit YUV420. The only 10-bit layout NVENC, QSV and AMF can
  /// encode, so it is the way to keep a 10-bit source's grading on a GPU
  /// encoder — 4:2:2 fails outright on most of them (issue #74).
  yuv420p10('yuv420p10', '4:2:0 10-bit', 'best 10-bit for GPU encoders', 10),
  /// Convert to 8-bit YUV422 for higher chroma quality.
  yuv422('yuv422', '4:2:2 8-bit', 'more colour detail', 8),
  /// Convert to 10-bit YUV422: keeps a 10-bit source's precision while
  /// normalizing chroma, and gives an 8-bit source headroom for gradients.
  yuv422p10('yuv422p10', '4:2:2 10-bit', 'keeps 10-bit precision', 10);

  const ChromaSubsampling(
      this.value, this.label, this.blurb, this.outputBitDepth);

  final String value;

  /// Short canonical name, e.g. "4:2:0 8-bit". The one piece of vocabulary the
  /// dropdown, the tooltip and the warnings all share, so they can't drift into
  /// describing the same option three different ways.
  final String label;

  /// Parenthetical hint shown after [label] in the dropdown, if any.
  final String? blurb;

  /// Bit depth the output is converted to, or null for [original], which does
  /// no conversion. Drives the "your source will be reduced" warning, so a new
  /// option gets the right warning without touching the UI.
  final int? outputBitDepth;

  String get displayName => blurb == null ? label : '$label ($blurb)';
}

/// Video encoding settings for FFmpeg output.
@JsonSerializable()
class EncodingSettings {
  final VideoCodec codec;
  final String encoderPreset;
  final int quality;

  /// Target video bitrate in kbps. Used by Intel-Mac VideoToolbox (which has no
  /// constant-quality mode), where the UI exposes a native bitrate control
  /// instead of the CRF slider. Null for all other encoders.
  final int? videoBitrateKbps;

  /// Audio handling mode.
  final AudioMode audioMode;

  /// Audio codec for re-encoding (when audioMode == convert).
  final AudioCodec audioCodec;

  /// Audio quality preset (when audioMode == convert and codec is lossy).
  final AudioQuality audioQuality;

  /// Output chroma subsampling format.
  final ChromaSubsampling chromaSubsampling;

  final String customFfmpegArgs;

  /// User-supplied VapourSynth, injected after every built-in pass. Same
  /// footing as customFfmpegArgs, and gated behind advanced mode.
  final String customVapoursynth;
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
    this.videoBitrateKbps,
    this.audioMode = AudioMode.passthrough,
    this.audioCodec = AudioCodec.aac,
    this.audioQuality = AudioQuality.high,
    this.chromaSubsampling = ChromaSubsampling.original,
    this.customFfmpegArgs = '',
    this.customVapoursynth = '',
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
    // NVENC uses CQ (constant quality) in VBR mode, not CRF
    final label = codec.isNvenc ? 'CQ' : 'CRF';
    if (quality <= 15) return 'Very High ($label $quality)';
    if (quality <= 20) return 'High ($label $quality)';
    if (quality <= 25) return 'Medium ($label $quality)';
    if (quality <= 30) return 'Low ($label $quality)';
    return 'Very Low ($label $quality)';
  }

  EncodingSettings copyWith({
    VideoCodec? codec,
    String? encoderPreset,
    int? quality,
    int? videoBitrateKbps,
    AudioMode? audioMode,
    AudioCodec? audioCodec,
    AudioQuality? audioQuality,
    ChromaSubsampling? chromaSubsampling,
    String? customFfmpegArgs,
    String? customVapoursynth,
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
      videoBitrateKbps: videoBitrateKbps ?? this.videoBitrateKbps,
      audioMode: effectiveAudioMode,
      audioCodec: audioCodec ?? this.audioCodec,
      audioQuality: audioQuality ?? this.audioQuality,
      chromaSubsampling: chromaSubsampling ?? this.chromaSubsampling,
      customFfmpegArgs: customFfmpegArgs ?? this.customFfmpegArgs,
      customVapoursynth: customVapoursynth ?? this.customVapoursynth,
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
