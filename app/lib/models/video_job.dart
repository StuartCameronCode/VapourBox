import 'package:json_annotation/json_annotation.dart';
import 'package:uuid/uuid.dart';

import 'qtgmc_parameters.dart';
import 'encoding_settings.dart';
import 'restoration_pipeline.dart';

part 'video_job.g.dart';

/// Represents a complete video processing job.
@JsonSerializable(explicitToJson: true)
class VideoJob {
  final String id;
  final String inputPath;
  final String outputPath;

  /// Legacy QTGMC-only parameters (for backwards compatibility).
  final QTGMCParameters qtgmcParameters;

  /// Full restoration pipeline (new multi-pass system).
  final RestorationPipeline? restorationPipeline;

  final EncodingSettings encodingSettings;
  final FieldOrder? detectedFieldOrder;
  final int? totalFrames;
  final double? inputFrameRate;

  /// Start frame for partial export (inclusive). Null means start from beginning.
  final int? startFrame;

  /// End frame for partial export (inclusive). Null means export to end.
  final int? endFrame;

  VideoJob({
    String? id,
    required this.inputPath,
    required this.outputPath,
    QTGMCParameters? qtgmcParameters,
    this.restorationPipeline,
    EncodingSettings? encodingSettings,
    this.detectedFieldOrder,
    this.totalFrames,
    this.inputFrameRate,
    this.startFrame,
    this.endFrame,
  })  : id = id ?? const Uuid().v4(),
        qtgmcParameters = qtgmcParameters ?? QTGMCParameters(),
        encodingSettings = encodingSettings ?? EncodingSettings();

  /// Get the effective restoration pipeline.
  /// Uses restorationPipeline if set, otherwise creates one from legacy qtgmcParameters.
  RestorationPipeline get effectivePipeline =>
      restorationPipeline ?? RestorationPipeline.fromLegacy(qtgmcParameters);

  factory VideoJob.fromJson(Map<String, dynamic> json) =>
      _$VideoJobFromJson(json);
  Map<String, dynamic> toJson() => _$VideoJobToJson(this);

  VideoJob copyWith({
    String? id,
    String? inputPath,
    String? outputPath,
    QTGMCParameters? qtgmcParameters,
    RestorationPipeline? restorationPipeline,
    EncodingSettings? encodingSettings,
    FieldOrder? detectedFieldOrder,
    int? totalFrames,
    double? inputFrameRate,
    int? startFrame,
    int? endFrame,
  }) {
    return VideoJob(
      id: id ?? this.id,
      inputPath: inputPath ?? this.inputPath,
      outputPath: outputPath ?? this.outputPath,
      qtgmcParameters: qtgmcParameters ?? this.qtgmcParameters,
      restorationPipeline: restorationPipeline ?? this.restorationPipeline,
      encodingSettings: encodingSettings ?? this.encodingSettings,
      detectedFieldOrder: detectedFieldOrder ?? this.detectedFieldOrder,
      totalFrames: totalFrames ?? this.totalFrames,
      inputFrameRate: inputFrameRate ?? this.inputFrameRate,
      startFrame: startFrame ?? this.startFrame,
      endFrame: endFrame ?? this.endFrame,
    );
  }
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
  proresProxy('prores_ks -profile:v 0', 'ProRes Proxy'),
  proresLT('prores_ks -profile:v 1', 'ProRes LT'),
  prores422('prores_ks -profile:v 2', 'ProRes 422'),
  proresHQ('prores_ks -profile:v 3', 'ProRes 422 HQ');

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
      case VideoCodec.proresProxy:
        return 'Lightweight proxy editing';
      case VideoCodec.proresLT:
        return 'Offline editing quality';
      case VideoCodec.prores422:
        return 'Broadcast quality';
      case VideoCodec.proresHQ:
        return 'Highest ProRes quality';
    }
  }

  bool get isProRes => value.startsWith('prores_ks');
  bool get isFFV1 => this == VideoCodec.ffv1;

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
    if (isFFV1) return 'Lossless';
    return 'Software';
  }

  ContainerFormat get preferredContainer {
    if (isProRes) return ContainerFormat.mov;
    if (isFFV1) return ContainerFormat.avi;
    return ContainerFormat.mp4;
  }

  /// Check if this codec is supported by the given container.
  bool supportsContainer(ContainerFormat container) {
    switch (container) {
      case ContainerFormat.mp4:
        // MP4 supports H.264, H.265 (software and hardware)
        return isH264 || isH265;
      case ContainerFormat.mov:
        // MOV supports H.264, H.265, ProRes
        return isH264 || isH265 || isProRes;
      case ContainerFormat.mkv:
        // MKV supports H.264, H.265, FFV1
        return isH264 || isH265 || isFFV1;
      case ContainerFormat.avi:
        // AVI supports FFV1, H.264 (uncommon)
        return isFFV1 || isH264;
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
    // VideoToolbox, ProRes, FFV1 don't have presets
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
