import 'package:json_annotation/json_annotation.dart';

part 'chroma_denoise_parameters.g.dart';

/// Frame height CCD was designed for. Its automatic `scale` is derived from the
/// source height relative to this, and the plugin rejects a scale below 1.0 —
/// so a shorter source needs an explicit clamped scale or the job fails.
const int ccdReferenceHeight = 480;

/// Parameters for the chroma denoise pass.
///
/// CCD (Camcorder Colour Denoise) is a chroma-only denoiser, originally a
/// VirtualDub filter by Sergey Stolyarevsky, here via the zsmooth plugin. It is
/// the standard tool for the blotchy colour noise on VHS captures and old
/// camcorder footage, where luma is acceptable but chroma is a mess.
@JsonSerializable()
class ChromaDenoiseParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Euclidean RGB distance below which a neighbouring pixel joins the average.
  /// Higher denoises more.
  final double threshold;

  /// Temporal radius. 0 is spatial-only; higher pulls in neighbouring frames.
  final int temporalRadius;

  /// Use the near reference points of the sampling matrix.
  final bool pointsLow;

  /// Use the mid-distance reference points.
  final bool pointsMedium;

  /// Use the far reference points. Off by default (the plugin's own default).
  final bool pointsHigh;

  /// Sampling-radius multiplier. Null derives it from the frame height, the same
  /// rule the plugin uses, but clamped so short sources still run.
  final double? scale;

  const ChromaDenoiseParameters({
    this.enabled = false,
    this.threshold = 4.0,
    this.temporalRadius = 0,
    this.pointsLow = true,
    this.pointsMedium = true,
    this.pointsHigh = false,
    this.scale,
  });

  ChromaDenoiseParameters copyWith({
    bool? enabled,
    double? threshold,
    int? temporalRadius,
    bool? pointsLow,
    bool? pointsMedium,
    bool? pointsHigh,
    double? scale,
  }) {
    return ChromaDenoiseParameters(
      enabled: enabled ?? this.enabled,
      threshold: threshold ?? this.threshold,
      temporalRadius: temporalRadius ?? this.temporalRadius,
      pointsLow: pointsLow ?? this.pointsLow,
      pointsMedium: pointsMedium ?? this.pointsMedium,
      pointsHigh: pointsHigh ?? this.pointsHigh,
      scale: scale ?? this.scale,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    final parts = <String>['CCD ${threshold.toStringAsFixed(1)}'];
    if (temporalRadius > 0) parts.add('TR:$temporalRadius');
    return parts.join(' ');
  }

  factory ChromaDenoiseParameters.fromJson(Map<String, dynamic> json) =>
      _$ChromaDenoiseParametersFromJson(json);
  Map<String, dynamic> toJson() => _$ChromaDenoiseParametersToJson(this);
}
