import 'package:json_annotation/json_annotation.dart';

part 'deband_parameters.g.dart';

/// Parameters for the debanding pass using f3kdb.
/// Removes banding artifacts (color gradients with visible steps).
@JsonSerializable()
class DebandParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Banding detection range (8-128, default 15).
  /// Higher values detect wider bands.
  final int range;

  /// Luma debanding strength (0-64, default 32).
  final int y;

  /// Chroma blue debanding strength (0-64, default 32).
  final int cb;

  /// Chroma red debanding strength (0-64, default 32).
  final int cr;

  /// Dither grain amount (0-64, default 24).
  /// Adds noise to mask remaining banding.
  final int grainY;

  /// Chroma dither grain (0-64, default 24).
  final int grainC;

  /// Use dynamic grain (changes per frame).
  final bool dynamicGrain;

  /// Output bit depth (8, 10, 16).
  final int outputDepth;

  const DebandParameters({
    this.enabled = false,
    this.range = 15,
    this.y = 32,
    this.cb = 32,
    this.cr = 32,
    this.grainY = 24,
    this.grainC = 24,
    this.dynamicGrain = true,
    this.outputDepth = 16,
  });

  DebandParameters copyWith({
    bool? enabled,
    int? range,
    int? y,
    int? cb,
    int? cr,
    int? grainY,
    int? grainC,
    bool? dynamicGrain,
    int? outputDepth,
  }) {
    return DebandParameters(
      enabled: enabled ?? this.enabled,
      range: range ?? this.range,
      y: y ?? this.y,
      cb: cb ?? this.cb,
      cr: cr ?? this.cr,
      grainY: grainY ?? this.grainY,
      grainC: grainC ?? this.grainC,
      dynamicGrain: dynamicGrain ?? this.dynamicGrain,
      outputDepth: outputDepth ?? this.outputDepth,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    return 'f3kdb ($y/$cb/$cr)';
  }

  factory DebandParameters.fromJson(Map<String, dynamic> json) =>
      _$DebandParametersFromJson(json);
  Map<String, dynamic> toJson() => _$DebandParametersToJson(this);
}
