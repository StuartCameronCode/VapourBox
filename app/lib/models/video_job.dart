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
    );
  }
}

/// Supported video codecs.
@JsonEnum(valueField: 'value')
enum VideoCodec {
  h264('libx264', 'H.264'),
  h265('libx265', 'H.265 (HEVC)'),
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

  ContainerFormat get preferredContainer {
    if (isProRes) return ContainerFormat.mov;
    if (isFFV1) return ContainerFormat.avi;
    return ContainerFormat.mp4;
  }

  /// Check if this codec is supported by the given container.
  bool supportsContainer(ContainerFormat container) {
    switch (container) {
      case ContainerFormat.mp4:
        // MP4 supports H.264, H.265 only
        return this == VideoCodec.h264 || this == VideoCodec.h265;
      case ContainerFormat.mov:
        // MOV supports H.264, H.265, ProRes
        return this == VideoCodec.h264 ||
               this == VideoCodec.h265 ||
               isProRes;
      case ContainerFormat.mkv:
        // MKV supports H.264, H.265, FFV1
        return this == VideoCodec.h264 ||
               this == VideoCodec.h265 ||
               this == VideoCodec.ffv1;
      case ContainerFormat.avi:
        // AVI supports FFV1, H.264 (uncommon)
        return this == VideoCodec.ffv1 || this == VideoCodec.h264;
    }
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
