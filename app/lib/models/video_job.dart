import 'package:json_annotation/json_annotation.dart';
import 'package:uuid/uuid.dart';

import 'qtgmc_parameters.dart';
import 'encoding_settings.dart';
import 'processing_pipeline.dart';
import 'subtitle_parameters.dart';

part 'video_job.g.dart';

/// Represents a complete video processing job.
@JsonSerializable(explicitToJson: true)
class VideoJob {
  final String id;
  final String inputPath;
  final String outputPath;

  /// Legacy QTGMC-only parameters (for backwards compatibility).
  final QTGMCParameters qtgmcParameters;

  /// Full processing pipeline (new multi-pass system).
  final ProcessingPipeline? processingPipeline;

  final EncodingSettings encodingSettings;
  final FieldOrder? detectedFieldOrder;
  final int? totalFrames;
  final double? inputFrameRate;

  /// Start frame for partial export (inclusive). Null means start from beginning.
  final int? startFrame;

  /// End frame for partial export (inclusive). Null means export to end.
  final int? endFrame;

  /// Subtitle generation settings (runs post-encode).
  final SubtitleSettingsDto? subtitleSettings;

  /// When true, skip video processing and only generate subtitles from input.
  final bool subtitleOnly;

  /// Input sample aspect ratio (e.g. "10:11"). Null means 1:1 (square pixels).
  final String? inputSar;

  /// Input video dimensions and pixel format (for pipe source).
  final int? inputWidth;
  final int? inputHeight;
  final String? inputPixelFormat;

  /// Source colour tags, re-declared on the output by the worker. The Y4M pipe
  /// strips them as it strips SAR, so without these every output is untagged
  /// and read as BT.601 limited.
  final String? inputColorMatrix;
  final String? inputColorPrimaries;
  final String? inputColorTransfer;
  final String? inputColorRange;

  /// A subtitle file to burn into the picture, per job. Deliberately not an
  /// encoding setting: a path baked into settings would apply one file's
  /// subtitles to every video in a batch.
  final String? burnInSubtitlePath;

  /// Per-video pitch factor file for the Stabilize pass in "From File" mode
  /// (issue #150). On the job rather than in the pipeline, because pipelines
  /// are saved into presets shared by every video in the queue.
  final String? pitchFactorsPath;

  VideoJob({
    String? id,
    required this.inputPath,
    required this.outputPath,
    QTGMCParameters? qtgmcParameters,
    this.processingPipeline,
    EncodingSettings? encodingSettings,
    this.detectedFieldOrder,
    this.totalFrames,
    this.inputFrameRate,
    this.startFrame,
    this.endFrame,
    this.subtitleSettings,
    this.subtitleOnly = false,
    this.inputSar,
    this.inputWidth,
    this.inputHeight,
    this.inputPixelFormat,
    this.inputColorMatrix,
    this.inputColorPrimaries,
    this.inputColorTransfer,
    this.inputColorRange,
    this.burnInSubtitlePath,
    this.pitchFactorsPath,
  })  : id = id ?? const Uuid().v4(),
        qtgmcParameters = qtgmcParameters ?? QTGMCParameters(),
        encodingSettings = encodingSettings ?? EncodingSettings();

  /// Get the effective processing pipeline.
  /// Uses processingPipeline if set, otherwise creates one from legacy qtgmcParameters.
  ProcessingPipeline get effectivePipeline =>
      processingPipeline ?? ProcessingPipeline.fromLegacy(qtgmcParameters);

  factory VideoJob.fromJson(Map<String, dynamic> json) =>
      _$VideoJobFromJson(json);
  Map<String, dynamic> toJson() => _$VideoJobToJson(this);

  VideoJob copyWith({
    String? id,
    String? inputPath,
    String? outputPath,
    QTGMCParameters? qtgmcParameters,
    ProcessingPipeline? processingPipeline,
    EncodingSettings? encodingSettings,
    FieldOrder? detectedFieldOrder,
    int? totalFrames,
    double? inputFrameRate,
    int? startFrame,
    int? endFrame,
    SubtitleSettingsDto? subtitleSettings,
    bool? subtitleOnly,
    String? inputSar,
    int? inputWidth,
    int? inputHeight,
    String? inputPixelFormat,
    String? inputColorMatrix,
    String? inputColorPrimaries,
    String? inputColorTransfer,
    String? inputColorRange,
    String? burnInSubtitlePath,
    String? pitchFactorsPath,
  }) {
    return VideoJob(
      id: id ?? this.id,
      inputPath: inputPath ?? this.inputPath,
      outputPath: outputPath ?? this.outputPath,
      qtgmcParameters: qtgmcParameters ?? this.qtgmcParameters,
      processingPipeline: processingPipeline ?? this.processingPipeline,
      encodingSettings: encodingSettings ?? this.encodingSettings,
      detectedFieldOrder: detectedFieldOrder ?? this.detectedFieldOrder,
      totalFrames: totalFrames ?? this.totalFrames,
      inputFrameRate: inputFrameRate ?? this.inputFrameRate,
      startFrame: startFrame ?? this.startFrame,
      endFrame: endFrame ?? this.endFrame,
      subtitleSettings: subtitleSettings ?? this.subtitleSettings,
      subtitleOnly: subtitleOnly ?? this.subtitleOnly,
      inputSar: inputSar ?? this.inputSar,
      inputWidth: inputWidth ?? this.inputWidth,
      inputHeight: inputHeight ?? this.inputHeight,
      inputPixelFormat: inputPixelFormat ?? this.inputPixelFormat,
      inputColorMatrix: inputColorMatrix ?? this.inputColorMatrix,
      inputColorPrimaries: inputColorPrimaries ?? this.inputColorPrimaries,
      inputColorTransfer: inputColorTransfer ?? this.inputColorTransfer,
      inputColorRange: inputColorRange ?? this.inputColorRange,
      burnInSubtitlePath: burnInSubtitlePath ?? this.burnInSubtitlePath,
      pitchFactorsPath: pitchFactorsPath ?? this.pitchFactorsPath,
    );
  }
}

/// DTO for subtitle settings sent to the worker.
@JsonSerializable()
class SubtitleSettingsDto {
  final bool enabled;
  final String model;
  final String output;
  final String? language;

  const SubtitleSettingsDto({
    required this.enabled,
    this.model = 'base',
    this.output = 'srt_file',
    this.language,
  });

  factory SubtitleSettingsDto.fromSubtitleParameters(SubtitleParameters params) {
    return SubtitleSettingsDto(
      enabled: params.enabled,
      model: params.model.value,
      output: params.output.value,
      language: params.language,
    );
  }

  factory SubtitleSettingsDto.fromJson(Map<String, dynamic> json) =>
      _$SubtitleSettingsDtoFromJson(json);
  Map<String, dynamic> toJson() => _$SubtitleSettingsDtoToJson(this);
}

/// Supported video codecs.
@JsonEnum(valueField: 'value')
enum VideoCodec {
  // Software encoders
  h264('libx264', 'H.264'),
  h265('libx265', 'H.265 (HEVC)'),

  // NVIDIA NVENC
  h264Nvenc('h264_nvenc', 'H.264 (NVENC)'),
  h265Nvenc('hevc_nvenc', 'H.265 (NVENC)'),

  // Intel QSV
  h264Qsv('h264_qsv', 'H.264 (Intel QSV)'),
  h265Qsv('hevc_qsv', 'H.265 (Intel QSV)'),

  // Apple VideoToolbox
  h264Videotoolbox('h264_videotoolbox', 'H.264 (VideoToolbox)'),
  h265Videotoolbox('hevc_videotoolbox', 'H.265 (VideoToolbox)'),

  // AMD AMF
  h264Amf('h264_amf', 'H.264 (AMD AMF)'),
  h265Amf('hevc_amf', 'H.265 (AMD AMF)'),

  // Lossless / ProRes
  ffv1('ffv1', 'FFV1 (Lossless)'),
  huffyuv('huffyuv', 'HuffYUV (Lossless)'),
  ffvhuff('ffvhuff', 'FFVHuff (Lossless)'),
  proresProxy('prores_ks -profile:v 0', 'ProRes Proxy'),
  proresLT('prores_ks -profile:v 1', 'ProRes LT'),
  prores422('prores_ks -profile:v 2', 'ProRes 422'),
  proresHQ('prores_ks -profile:v 3', 'ProRes 422 HQ'),
  prores4444('prores_ks -profile:v 4', 'ProRes 4444'),
  prores4444Xq('prores_ks -profile:v 5', 'ProRes 4444 XQ'),

  // Uncompressed
  v210('v210', 'Uncompressed 10-bit 4:2:2 (v210)');

  const VideoCodec(this.value, this.displayName);

  final String value;
  final String displayName;

  String get description {
    switch (this) {
      case VideoCodec.h264:
        return 'Widely compatible, good compression';
      case VideoCodec.h265:
        return 'Better compression, less compatible';
      case VideoCodec.h264Nvenc:
        return 'NVIDIA GPU accelerated H.264';
      case VideoCodec.h265Nvenc:
        return 'NVIDIA GPU accelerated H.265';
      case VideoCodec.h264Qsv:
        return 'Intel GPU accelerated H.264';
      case VideoCodec.h265Qsv:
        return 'Intel GPU accelerated H.265';
      case VideoCodec.h264Videotoolbox:
        return 'Apple hardware accelerated H.264';
      case VideoCodec.h265Videotoolbox:
        return 'Apple hardware accelerated H.265';
      case VideoCodec.h264Amf:
        return 'AMD GPU accelerated H.264';
      case VideoCodec.h265Amf:
        return 'AMD GPU accelerated H.265';
      case VideoCodec.ffv1:
        return 'Lossless archival codec';
      case VideoCodec.huffyuv:
        return 'Fast lossless intermediate (YUV 4:2:2)';
      case VideoCodec.ffvhuff:
        return 'Fast lossless intermediate (flexible formats)';
      case VideoCodec.proresProxy:
        return 'Lightweight proxy editing';
      case VideoCodec.proresLT:
        return 'Offline editing quality';
      case VideoCodec.prores422:
        return 'Broadcast quality';
      case VideoCodec.proresHQ:
        return 'Highest 4:2:2 ProRes quality';
      case VideoCodec.prores4444:
        return 'Full 4:4:4 colour, for compositing';
      case VideoCodec.prores4444Xq:
        return 'Full 4:4:4 colour at the highest data rate';
      case VideoCodec.v210:
        return 'Uncompressed 10-bit 4:2:2 for editing (Premiere, Resolve). Very '
            'large: about 221 Mbit/s at 720x576 25p, 1.1 Gbit/s at 1080p25';
    }
  }

  bool get isProRes => value.startsWith('prores_ks');
  bool get isFFV1 => this == VideoCodec.ffv1;

  /// Whether this is a lossless codec (FFV1, HuffYUV, FFVHuff).
  bool get isLossless =>
      this == VideoCodec.ffv1 || this == VideoCodec.huffyuv || this == VideoCodec.ffvhuff;

  /// Whether a quality/bitrate control means anything for this codec.
  ///
  /// The worker decides quality per encoder family in
  /// `build_encoder_quality_args`, and two families read nothing from
  /// `EncodingSettings.quality`: the lossless codecs (there is no quality to
  /// set) and ProRes (the profile fixes it — the ProRes branch emits
  /// `-profile:v N` and returns). Showing a CRF slider for either is a control
  /// that responds and changes nothing, which is worse than showing none:
  /// ProRes used to present one labelled "High (CRF 18)".
  ///
  /// This lives on the model rather than inline in the settings dialog so it
  /// can be asserted across `VideoCodec.values` — a codec added later cannot
  /// quietly acquire a slider the worker ignores.
  bool get hasQualityControl => !isLossless && !isProRes && !isUncompressed;

  /// Whether this is an uncompressed codec (v210). Deliberately not part of
  /// [isLossless]: that family defaults to AVI and is grouped as "Lossless",
  /// while v210 is an editing intermediate that belongs in MOV. Mirrors
  /// `VideoCodec::is_uncompressed` in the worker.
  bool get isUncompressed => this == VideoCodec.v210;

  /// The ProRes profile number (`-profile:v N`, 0 Proxy .. 5 4444 XQ), read
  /// from the wire value the worker dispatches on, or null for any other
  /// codec. Mirrors `VideoCodec::prores_profile`.
  int? get proresProfile {
    if (!isProRes) return null;
    final m = RegExp(r'-profile:v (\d+)').firstMatch(value);
    return m == null ? null : int.parse(m.group(1)!);
  }

  /// The one output format this codec stores, whatever Color Format is
  /// selected, or null when the selection applies: 10-bit 4:2:2 for v210 and
  /// ProRes Proxy..HQ, 10-bit 4:4:4 for ProRes 4444/XQ (profile 4 and up).
  /// The worker converts to it in the script, field-aware. Mirrors
  /// `VideoCodec::fixed_output_format`.
  ChromaSubsampling? get fixedOutputFormat {
    if (isUncompressed) return ChromaSubsampling.yuv422p10;
    final profile = proresProfile;
    if (profile == null) return null;
    return profile >= 4 ? ChromaSubsampling.yuv444p10 : ChromaSubsampling.yuv422p10;
  }

  /// Whether this codec produces H.264 output (software or hardware).
  bool get isH264 => this == h264 || this == h264Nvenc || this == h264Qsv ||
      this == h264Videotoolbox || this == h264Amf;

  /// Whether this codec produces H.265 output (software or hardware).
  bool get isH265 => this == h265 || this == h265Nvenc || this == h265Qsv ||
      this == h265Videotoolbox || this == h265Amf;

  /// Whether this is an NVIDIA NVENC encoder.
  bool get isNvenc => this == h264Nvenc || this == h265Nvenc;

  /// Whether this is a hardware-accelerated encoder.
  bool get isHardwareEncoder => this == h264Nvenc || this == h265Nvenc ||
      this == h264Qsv || this == h265Qsv ||
      this == h264Videotoolbox || this == h265Videotoolbox ||
      this == h264Amf || this == h265Amf;

  /// The encoder family name for display purposes.
  String get encoderFamily {
    if (this == h264Nvenc || this == h265Nvenc) return 'NVIDIA NVENC';
    if (this == h264Qsv || this == h265Qsv) return 'Intel QSV';
    if (this == h264Videotoolbox || this == h265Videotoolbox) return 'Apple VideoToolbox';
    if (this == h264Amf || this == h265Amf) return 'AMD AMF';
    if (isProRes) return 'ProRes';
    if (isLossless) return 'Lossless';
    if (isUncompressed) return 'Uncompressed';
    return 'Software';
  }

  ContainerFormat get preferredContainer {
    if (isProRes || isUncompressed) return ContainerFormat.mov;
    if (isLossless) return ContainerFormat.avi;
    return ContainerFormat.mp4;
  }

  /// Check if this codec is supported by the given container.
  bool supportsContainer(ContainerFormat container) {
    switch (container) {
      case ContainerFormat.mp4:
        // MP4 supports H.264, H.265 (software and hardware)
        return isH264 || isH265;
      case ContainerFormat.mov:
        // MOV supports H.264, H.265, ProRes, v210
        return isH264 || isH265 || isProRes || isUncompressed;
      case ContainerFormat.mkv:
        // MKV supports H.264, H.265, lossless (FFV1/HuffYUV/FFVHuff), v210
        return isH264 || isH265 || isLossless || isUncompressed;
      case ContainerFormat.avi:
        // AVI supports lossless (FFV1/HuffYUV/FFVHuff), H.264 (uncommon) and
        // v210 — though AVI cannot say whether the picture is interlaced.
        // (MP4 has no tag for v210 at all: ffmpeg refuses the mux.)
        return isLossless || isH264 || isUncompressed;
    }
  }

  /// Available encoder presets for this codec family.
  List<String>? get availablePresets {
    if (this == h264 || this == h265) {
      return ['ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow', 'placebo'];
    }
    if (this == h264Nvenc || this == h265Nvenc) {
      return ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7'];
    }
    if (this == h264Qsv || this == h265Qsv) {
      return ['veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow'];
    }
    if (this == h264Amf || this == h265Amf) {
      return ['speed', 'balanced', 'quality'];
    }
    // VideoToolbox, ProRes, the lossless codecs and v210 don't have presets
    return null;
  }

  /// Default encoder preset for this codec family.
  String get defaultPreset {
    if (this == h264 || this == h265) return 'medium';
    if (this == h264Nvenc || this == h265Nvenc) return 'p4';
    if (this == h264Qsv || this == h265Qsv) return 'medium';
    if (this == h264Amf || this == h265Amf) return 'balanced';
    return 'medium';
  }
}

/// v210's data rate in bits per second for a frame size and rate.
///
/// v210 packs six pixels into 16 bytes, and each line is padded to a multiple
/// of 48 pixels (128 bytes): 720x576 at 25 fps is 221,184,000 bit/s, which is
/// what ffmpeg itself reports for the stream.
int v210BitsPerSecond(int width, int height, double fps) {
  final lineBytes = ((width + 47) ~/ 48) * 128;
  return (lineBytes * height * 8 * fps).round();
}

/// Output container formats.
@JsonEnum(valueField: 'value')
enum ContainerFormat {
  mp4('mp4', 'MP4'),
  mov('mov', 'QuickTime MOV'),
  mkv('mkv', 'Matroska MKV'),
  avi('avi', 'AVI');

  const ContainerFormat(this.value, this.displayName);

  final String value;
  final String displayName;

  String get extension => value;

  /// Get the list of codecs supported by this container.
  List<VideoCodec> get supportedCodecs {
    return VideoCodec.values
        .where((codec) => codec.supportsContainer(this))
        .toList();
  }
}

/// Video field order.
@JsonEnum(valueField: 'value')
enum FieldOrder {
  topFieldFirst('tff', 'Top Field First (TFF)'),
  bottomFieldFirst('bff', 'Bottom Field First (BFF)'),
  progressive('progressive', 'Progressive'),
  unknown('unknown', 'Unknown');

  const FieldOrder(this.value, this.displayName);

  final String value;
  final String displayName;

  /// Alias for topFieldFirst for convenience.
  static FieldOrder get tff => topFieldFirst;

  /// Alias for bottomFieldFirst for convenience.
  static FieldOrder get bff => bottomFieldFirst;

  bool? get tffValue {
    switch (this) {
      case FieldOrder.topFieldFirst:
        return true;
      case FieldOrder.bottomFieldFirst:
        return false;
      default:
        return null;
    }
  }
}
