import 'package:json_annotation/json_annotation.dart';

part 'descale_parameters.g.dart';

/// The resampling kernel a studio upscaled with.
enum DescaleKernel {
  @JsonValue('bilinear')
  bilinear('Bilinear'),
  @JsonValue('bicubic')
  bicubic('Bicubic'),
  @JsonValue('lanczos')
  lanczos('Lanczos'),
  @JsonValue('spline16')
  spline16('Spline16'),
  @JsonValue('spline36')
  spline36('Spline36'),
  @JsonValue('spline64')
  spline64('Spline64');

  const DescaleKernel(this.displayName);
  final String displayName;
}

/// How the studio's resampler treated pixels past the frame edge.
enum DescaleBorder {
  @JsonValue('mirror')
  mirror,
  @JsonValue('zero')
  zero,
  @JsonValue('extend')
  extend,
}

/// Descale — undo a studio's upscale, then upscale again cleanly (luma only;
/// the output keeps the source's size).
@JsonSerializable()
class DescaleParameters {
  final bool enabled;

  /// The height the picture was drawn at.
  final int nativeHeight;

  /// The width it was drawn at; 0 derives it from the source's shape.
  final int nativeWidth;

  final DescaleKernel kernel;
  final double bicubicB;
  final double bicubicC;
  final int lanczosTaps;
  final DescaleBorder border;

  /// Keep the source where re-applying the kernel does not reproduce it
  /// (credits, text and overlays drawn at full resolution).
  final bool protectDetail;

  /// How far (8-bit levels) the re-applied kernel may miss before a pixel
  /// counts as full-resolution detail.
  final double detailThreshold;

  const DescaleParameters({
    this.enabled = false,
    this.nativeHeight = 720,
    this.nativeWidth = 0,
    this.kernel = DescaleKernel.bicubic,
    this.bicubicB = 0.0,
    this.bicubicC = 0.5,
    this.lanczosTaps = 3,
    this.border = DescaleBorder.mirror,
    this.protectDetail = true,
    this.detailThreshold = 4.0,
  });

  DescaleParameters copyWith({
    bool? enabled,
    int? nativeHeight,
    int? nativeWidth,
    DescaleKernel? kernel,
    double? bicubicB,
    double? bicubicC,
    int? lanczosTaps,
    DescaleBorder? border,
    bool? protectDetail,
    double? detailThreshold,
  }) =>
      DescaleParameters(
        enabled: enabled ?? this.enabled,
        nativeHeight: nativeHeight ?? this.nativeHeight,
        nativeWidth: nativeWidth ?? this.nativeWidth,
        kernel: kernel ?? this.kernel,
        bicubicB: bicubicB ?? this.bicubicB,
        bicubicC: bicubicC ?? this.bicubicC,
        lanczosTaps: lanczosTaps ?? this.lanczosTaps,
        border: border ?? this.border,
        protectDetail: protectDetail ?? this.protectDetail,
        detailThreshold: detailThreshold ?? this.detailThreshold,
      );

  String get summary => enabled ? '${nativeHeight}p ${kernel.displayName}' : 'Off';

  factory DescaleParameters.fromJson(Map<String, dynamic> json) =>
      _$DescaleParametersFromJson(json);
  Map<String, dynamic> toJson() => _$DescaleParametersToJson(this);
}
