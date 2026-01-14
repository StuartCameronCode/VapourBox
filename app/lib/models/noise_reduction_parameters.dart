import 'package:json_annotation/json_annotation.dart';

part 'noise_reduction_parameters.g.dart';

/// Noise reduction method options.
enum NoiseReductionMethod {
  @JsonValue('smDegrain')
  smDegrain('SMDegrain'),
  @JsonValue('mcTemporalDenoise')
  mcTemporalDenoise('MCTemporalDenoise'),
  @JsonValue('qtgmcBuiltin')
  qtgmcBuiltin('QTGMC Built-in');

  const NoiseReductionMethod(this.displayName);
  final String displayName;
}

/// Noise reduction preset levels.
enum NoiseReductionPreset {
  @JsonValue('off')
  off,
  @JsonValue('light')
  light,
  @JsonValue('moderate')
  moderate,
  @JsonValue('heavy')
  heavy,
  @JsonValue('custom')
  custom,
}

/// Parameters for the noise reduction pass.
@JsonSerializable()
class NoiseReductionParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Preset level for simple mode.
  final NoiseReductionPreset preset;

  /// Which noise reduction method to use.
  final NoiseReductionMethod method;

  // --- SMDegrain Parameters ---

  /// Temporal radius (1-6). Higher = more temporal smoothing.
  final int smDegrainTr;

  /// SAD threshold for luma. Higher = more denoising.
  final int smDegrainThSAD;

  /// SAD threshold for chroma. Higher = more chroma denoising.
  final int smDegrainThSADC;

  /// Refine motion vectors for better accuracy.
  final bool smDegrainRefine;

  /// Prefilter mode (0-4). Higher = stronger prefiltering.
  final int smDegrainPrefilter;

  // --- MCTemporalDenoise Parameters ---

  /// Denoise strength/sigma.
  final double mcTemporalSigma;

  /// Temporal radius for MCTemporalDenoise.
  final int mcTemporalRadius;

  /// Profile setting for MCTemporalDenoise.
  final String mcTemporalProfile;

  // --- QTGMC Built-in Parameters ---
  // These are passed through to QTGMC's noise settings

  /// EZDenoise strength (0.0 to 5.0+).
  final double qtgmcEzDenoise;

  /// EZKeepGrain amount (0.0 to 1.0).
  final double qtgmcEzKeepGrain;

  const NoiseReductionParameters({
    this.enabled = false,
    this.preset = NoiseReductionPreset.off,
    this.method = NoiseReductionMethod.smDegrain,
    // SMDegrain defaults
    this.smDegrainTr = 2,
    this.smDegrainThSAD = 300,
    this.smDegrainThSADC = 150,
    this.smDegrainRefine = true,
    this.smDegrainPrefilter = 2,
    // MCTemporalDenoise defaults
    this.mcTemporalSigma = 4.0,
    this.mcTemporalRadius = 2,
    this.mcTemporalProfile = 'fast',
    // QTGMC built-in defaults
    this.qtgmcEzDenoise = 0.0,
    this.qtgmcEzKeepGrain = 0.0,
  });

  /// Create parameters from a preset.
  factory NoiseReductionParameters.fromPreset(NoiseReductionPreset preset) {
    switch (preset) {
      case NoiseReductionPreset.off:
        return const NoiseReductionParameters(
          enabled: false,
          preset: NoiseReductionPreset.off,
        );
      case NoiseReductionPreset.light:
        return const NoiseReductionParameters(
          enabled: true,
          preset: NoiseReductionPreset.light,
          method: NoiseReductionMethod.smDegrain,
          smDegrainTr: 1,
          smDegrainThSAD: 200,
          smDegrainThSADC: 100,
        );
      case NoiseReductionPreset.moderate:
        return const NoiseReductionParameters(
          enabled: true,
          preset: NoiseReductionPreset.moderate,
          method: NoiseReductionMethod.smDegrain,
          smDegrainTr: 2,
          smDegrainThSAD: 300,
          smDegrainThSADC: 150,
        );
      case NoiseReductionPreset.heavy:
        return const NoiseReductionParameters(
          enabled: true,
          preset: NoiseReductionPreset.heavy,
          method: NoiseReductionMethod.smDegrain,
          smDegrainTr: 3,
          smDegrainThSAD: 500,
          smDegrainThSADC: 250,
        );
      case NoiseReductionPreset.custom:
        return const NoiseReductionParameters(
          enabled: true,
          preset: NoiseReductionPreset.custom,
        );
    }
  }

  NoiseReductionParameters copyWith({
    bool? enabled,
    NoiseReductionPreset? preset,
    NoiseReductionMethod? method,
    int? smDegrainTr,
    int? smDegrainThSAD,
    int? smDegrainThSADC,
    bool? smDegrainRefine,
    int? smDegrainPrefilter,
    double? mcTemporalSigma,
    int? mcTemporalRadius,
    String? mcTemporalProfile,
    double? qtgmcEzDenoise,
    double? qtgmcEzKeepGrain,
  }) {
    return NoiseReductionParameters(
      enabled: enabled ?? this.enabled,
      preset: preset ?? this.preset,
      method: method ?? this.method,
      smDegrainTr: smDegrainTr ?? this.smDegrainTr,
      smDegrainThSAD: smDegrainThSAD ?? this.smDegrainThSAD,
      smDegrainThSADC: smDegrainThSADC ?? this.smDegrainThSADC,
      smDegrainRefine: smDegrainRefine ?? this.smDegrainRefine,
      smDegrainPrefilter: smDegrainPrefilter ?? this.smDegrainPrefilter,
      mcTemporalSigma: mcTemporalSigma ?? this.mcTemporalSigma,
      mcTemporalRadius: mcTemporalRadius ?? this.mcTemporalRadius,
      mcTemporalProfile: mcTemporalProfile ?? this.mcTemporalProfile,
      qtgmcEzDenoise: qtgmcEzDenoise ?? this.qtgmcEzDenoise,
      qtgmcEzKeepGrain: qtgmcEzKeepGrain ?? this.qtgmcEzKeepGrain,
    );
  }

  /// Get a human-readable summary of the current settings.
  String get summary {
    if (!enabled) return 'Off';
    // Handle preset-based summary (but treat 'off' as custom when enabled)
    if (preset != NoiseReductionPreset.custom && preset != NoiseReductionPreset.off) {
      return preset.name[0].toUpperCase() + preset.name.substring(1);
    }
    return method.displayName;
  }

  factory NoiseReductionParameters.fromJson(Map<String, dynamic> json) =>
      _$NoiseReductionParametersFromJson(json);

  Map<String, dynamic> toJson() => _$NoiseReductionParametersToJson(this);
}
