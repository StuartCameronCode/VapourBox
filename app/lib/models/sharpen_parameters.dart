import 'package:json_annotation/json_annotation.dart';

part 'sharpen_parameters.g.dart';

/// Sharpening method options.
@JsonEnum(valueField: 'value')
enum SharpenMethod {
  @JsonValue('LSFmod')
  lsfmod('LSFmod', 'LSFmod'),
  @JsonValue('CAS')
  cas('CAS', 'Contrast Adaptive Sharpening'),
  @JsonValue('AWarpSharp2')
  aWarpSharp2('AWarpSharp2', 'aWarpSharp2');

  const SharpenMethod(this.value, this.displayName);
  final String value;
  final String displayName;

  String get description {
    switch (this) {
      case SharpenMethod.lsfmod:
        return 'Limited sharpening with overshoot control';
      case SharpenMethod.cas:
        return 'AMD Contrast Adaptive Sharpening';
      case SharpenMethod.aWarpSharp2:
        return 'Warps pixels toward edges instead of raising contrast, so it '
            'adds no halos';
    }
  }
}

/// Parameters for the sharpening pass.
@JsonSerializable()
class SharpenParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Sharpening method to use.
  final SharpenMethod method;

  // --- LSFmod parameters ---

  /// Overall sharpening strength (0-200, default 100).
  final int strength;

  /// Overshoot limiting for bright edges (0-100).
  final int overshoot;

  /// Undershoot limiting for dark edges (0-100).
  final int undershoot;

  /// Edge detection threshold (soft edge handling).
  final int softEdge;

  // --- CAS parameters ---

  /// CAS sharpening amount (0.0-1.0).
  final double casSharpness;

  // --- aWarpSharp2 parameters ---

  /// How far pixels may be warped (0-255). The main strength control.
  final int warpDepth;

  /// Edge mask threshold (0-255). Lower finds more edges to warp toward.
  final int warpThresh;

  /// Mask blur passes (0-3). More blur warps more smoothly.
  final int warpBlur;

  /// Blur kernel: 0 = radius 6 box (per-pass), 1 = radius 2 box.
  final int warpType;

  const SharpenParameters({
    this.enabled = false,
    this.method = SharpenMethod.lsfmod,
    this.strength = 100,
    this.overshoot = 1,
    this.undershoot = 1,
    this.softEdge = 0,
    this.casSharpness = 0.5,
    this.warpDepth = 16,
    this.warpThresh = 128,
    this.warpBlur = 2,
    this.warpType = 0,
  });

  SharpenParameters copyWith({
    bool? enabled,
    SharpenMethod? method,
    int? strength,
    int? overshoot,
    int? undershoot,
    int? softEdge,
    double? casSharpness,
    int? warpDepth,
    int? warpThresh,
    int? warpBlur,
    int? warpType,
  }) {
    return SharpenParameters(
      enabled: enabled ?? this.enabled,
      method: method ?? this.method,
      strength: strength ?? this.strength,
      overshoot: overshoot ?? this.overshoot,
      undershoot: undershoot ?? this.undershoot,
      softEdge: softEdge ?? this.softEdge,
      casSharpness: casSharpness ?? this.casSharpness,
      warpDepth: warpDepth ?? this.warpDepth,
      warpThresh: warpThresh ?? this.warpThresh,
      warpBlur: warpBlur ?? this.warpBlur,
      warpType: warpType ?? this.warpType,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    if (method == SharpenMethod.lsfmod) {
      return 'LSFmod ($strength%)';
    } else {
      return 'CAS (${(casSharpness * 100).round()}%)';
    }
  }

  factory SharpenParameters.fromJson(Map<String, dynamic> json) =>
      _$SharpenParametersFromJson(json);
  Map<String, dynamic> toJson() => _$SharpenParametersToJson(this);
}
