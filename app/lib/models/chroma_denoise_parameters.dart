import 'package:json_annotation/json_annotation.dart';

part 'chroma_denoise_parameters.g.dart';

/// Which chroma denoiser to run.
///
/// The two are complementary rather than alternatives: CCD smooths blotches
/// that sit still, Cnr4 settles colour that swims between frames. Measured on
/// the bundled plugin, neither reaches what the other does.
enum ChromaDenoiseMethod {
  @JsonValue('ccd')
  ccd('CCD'),
  @JsonValue('cnr4')
  cnr4('Cnr4');

  const ChromaDenoiseMethod(this.displayName);
  final String displayName;
}

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

  /// Which denoiser to run.
  final ChromaDenoiseMethod method;

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

  // ---- Cnr4 ----------------------------------------------------------------
  /// How far chroma is pulled toward the temporal average. The plugin's own
  /// default is near the top of the range, so there is more room down than up.
  final int cnr4Strength;

  /// Movement tolerated before the filter stops correcting.
  final int cnr4Sense;

  /// Temporal radius, 1-8.
  final int cnr4Radius;

  /// Detail-retention mode, 0-3.
  final int cnr4Tmode;

  /// Weighting mode, 0-2.
  final int cnr4Wmode;

  const ChromaDenoiseParameters({
    this.enabled = false,
    this.method = ChromaDenoiseMethod.ccd,
    this.threshold = 4.0,
    this.temporalRadius = 0,
    this.pointsLow = true,
    this.pointsMedium = true,
    this.pointsHigh = false,
    this.scale,
    this.cnr4Strength = 192,
    this.cnr4Sense = 35,
    this.cnr4Radius = 2,
    this.cnr4Tmode = 0,
    this.cnr4Wmode = 0,
  });

  ChromaDenoiseParameters copyWith({
    bool? enabled,
    double? threshold,
    int? temporalRadius,
    bool? pointsLow,
    bool? pointsMedium,
    bool? pointsHigh,
    double? scale,
    ChromaDenoiseMethod? method,
    int? cnr4Strength,
    int? cnr4Sense,
    int? cnr4Radius,
    int? cnr4Tmode,
    int? cnr4Wmode,
  }) {
    return ChromaDenoiseParameters(
      enabled: enabled ?? this.enabled,
      method: method ?? this.method,
      threshold: threshold ?? this.threshold,
      temporalRadius: temporalRadius ?? this.temporalRadius,
      pointsLow: pointsLow ?? this.pointsLow,
      pointsMedium: pointsMedium ?? this.pointsMedium,
      pointsHigh: pointsHigh ?? this.pointsHigh,
      scale: scale ?? this.scale,
      cnr4Strength: cnr4Strength ?? this.cnr4Strength,
      cnr4Sense: cnr4Sense ?? this.cnr4Sense,
      cnr4Radius: cnr4Radius ?? this.cnr4Radius,
      cnr4Tmode: cnr4Tmode ?? this.cnr4Tmode,
      cnr4Wmode: cnr4Wmode ?? this.cnr4Wmode,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    if (method == ChromaDenoiseMethod.cnr4) {
      return 'Cnr4 $cnr4Strength · r$cnr4Radius';
    }
    final parts = <String>['CCD ${threshold.toStringAsFixed(1)}'];
    if (temporalRadius > 0) parts.add('TR:$temporalRadius');
    return parts.join(' ');
  }

  factory ChromaDenoiseParameters.fromJson(Map<String, dynamic> json) =>
      _$ChromaDenoiseParametersFromJson(json);
  Map<String, dynamic> toJson() => _$ChromaDenoiseParametersToJson(this);
}
