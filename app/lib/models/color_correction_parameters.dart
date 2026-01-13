import 'package:json_annotation/json_annotation.dart';

part 'color_correction_parameters.g.dart';

/// Color correction preset options.
enum ColorCorrectionPreset {
  @JsonValue('off')
  off,
  @JsonValue('broadcastSafe')
  broadcastSafe,
  @JsonValue('enhanceColors')
  enhanceColors,
  @JsonValue('desaturate')
  desaturate,
  @JsonValue('custom')
  custom,
}

/// Parameters for the color correction pass.
/// Uses adjust.Tweak and SmoothLevels from havsfunc.
@JsonSerializable()
class ColorCorrectionParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Preset level for simple mode.
  final ColorCorrectionPreset preset;

  // --- Tweak Parameters (from adjust.py) ---

  /// Brightness adjustment (-255 to 255).
  final double brightness;

  /// Contrast adjustment (0.0 to 10.0, 1.0 = no change).
  final double contrast;

  /// Hue rotation in degrees (-180 to 180).
  final double hue;

  /// Saturation adjustment (0.0 to 10.0, 1.0 = no change).
  final double saturation;

  /// Coring - clamp output to TV range (16-235).
  final bool coring;

  // --- SmoothLevels Parameters ---

  /// Whether to apply levels adjustment.
  final bool applyLevels;

  /// Input black level (0-255).
  final int inputLow;

  /// Input white level (0-255).
  final int inputHigh;

  /// Output black level (0-255).
  final int outputLow;

  /// Output white level (0-255).
  final int outputHigh;

  /// Gamma adjustment (0.1 to 10.0, 1.0 = no change).
  final double gamma;

  const ColorCorrectionParameters({
    this.enabled = false,
    this.preset = ColorCorrectionPreset.off,
    // Tweak defaults
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.hue = 0.0,
    this.saturation = 1.0,
    this.coring = false,
    // Levels defaults
    this.applyLevels = false,
    this.inputLow = 0,
    this.inputHigh = 255,
    this.outputLow = 0,
    this.outputHigh = 255,
    this.gamma = 1.0,
  });

  /// Create parameters from a preset.
  factory ColorCorrectionParameters.fromPreset(ColorCorrectionPreset preset) {
    switch (preset) {
      case ColorCorrectionPreset.off:
        return const ColorCorrectionParameters(
          enabled: false,
          preset: ColorCorrectionPreset.off,
        );
      case ColorCorrectionPreset.broadcastSafe:
        return const ColorCorrectionParameters(
          enabled: true,
          preset: ColorCorrectionPreset.broadcastSafe,
          coring: true,
          applyLevels: true,
          inputLow: 16,
          inputHigh: 235,
          outputLow: 16,
          outputHigh: 235,
        );
      case ColorCorrectionPreset.enhanceColors:
        return const ColorCorrectionParameters(
          enabled: true,
          preset: ColorCorrectionPreset.enhanceColors,
          contrast: 1.1,
          saturation: 1.15,
          applyLevels: true,
          inputLow: 8,
          inputHigh: 247,
          gamma: 0.95,
        );
      case ColorCorrectionPreset.desaturate:
        return const ColorCorrectionParameters(
          enabled: true,
          preset: ColorCorrectionPreset.desaturate,
          saturation: 0.0,
        );
      case ColorCorrectionPreset.custom:
        return const ColorCorrectionParameters(
          enabled: true,
          preset: ColorCorrectionPreset.custom,
        );
    }
  }

  ColorCorrectionParameters copyWith({
    bool? enabled,
    ColorCorrectionPreset? preset,
    double? brightness,
    double? contrast,
    double? hue,
    double? saturation,
    bool? coring,
    bool? applyLevels,
    int? inputLow,
    int? inputHigh,
    int? outputLow,
    int? outputHigh,
    double? gamma,
  }) {
    return ColorCorrectionParameters(
      enabled: enabled ?? this.enabled,
      preset: preset ?? this.preset,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      hue: hue ?? this.hue,
      saturation: saturation ?? this.saturation,
      coring: coring ?? this.coring,
      applyLevels: applyLevels ?? this.applyLevels,
      inputLow: inputLow ?? this.inputLow,
      inputHigh: inputHigh ?? this.inputHigh,
      outputLow: outputLow ?? this.outputLow,
      outputHigh: outputHigh ?? this.outputHigh,
      gamma: gamma ?? this.gamma,
    );
  }

  /// Get a human-readable summary of the current settings.
  String get summary {
    if (!enabled) return 'Off';
    if (preset != ColorCorrectionPreset.custom) {
      switch (preset) {
        case ColorCorrectionPreset.broadcastSafe:
          return 'Broadcast Safe';
        case ColorCorrectionPreset.enhanceColors:
          return 'Enhance Colors';
        case ColorCorrectionPreset.desaturate:
          return 'Desaturate';
        default:
          return preset.name;
      }
    }
    final parts = <String>[];
    if (brightness != 0) parts.add('B:${brightness.toStringAsFixed(0)}');
    if (contrast != 1) parts.add('C:${contrast.toStringAsFixed(1)}');
    if (saturation != 1) parts.add('S:${saturation.toStringAsFixed(1)}');
    return parts.isEmpty ? 'Custom' : parts.join(' ');
  }

  factory ColorCorrectionParameters.fromJson(Map<String, dynamic> json) =>
      _$ColorCorrectionParametersFromJson(json);

  Map<String, dynamic> toJson() => _$ColorCorrectionParametersToJson(this);
}
