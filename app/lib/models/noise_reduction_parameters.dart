import 'package:json_annotation/json_annotation.dart';

part 'noise_reduction_parameters.g.dart';

/// Noise reduction method options.
enum NoiseReductionMethod {
  @JsonValue('smDegrain')
  smDegrain('SMDegrain'),
  @JsonValue('mcTemporalDenoise')
  mcTemporalDenoise('MCTemporalDenoise'),
  @JsonValue('mcDegrainSharp')
  mcDegrainSharp('MCDegrainSharp'),
  @JsonValue('qtgmcBuiltin')
  qtgmcBuiltin('QTGMC Built-in'),
  // These three JsonValues are the wire format to the worker and must match
  // serde's camelCase spelling of the Rust variants exactly. A mismatch does
  // not error — serde falls back to the default — so the job would silently run
  // SMDegrain instead. Pinned on the Rust side by
  // test_method_wire_names_match_the_dart_enum.
  @JsonValue('dfTtest')
  dfttest('DFTTest'),
  @JsonValue('fft3dFilter')
  fft3dFilter('FFT3DFilter'),
  @JsonValue('tTempSmooth')
  tTempSmooth('TTempSmooth'),
  @JsonValue('fluxSmoothT')
  fluxSmoothT('FluxSmoothT'),
  @JsonValue('fluxSmoothSt')
  fluxSmoothSt('FluxSmoothST'),
  @JsonValue('stPresso')
  stPresso('STPresso'),
  @JsonValue('ctmf')
  ctmf('CTMF'),
  @JsonValue('mClean')
  mClean('mClean'),
  @JsonValue('temporalDegrain2')
  temporalDegrain2('TemporalDegrain2');

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

  /// Restore fine detail the denoiser removed. Brackets the denoise rather
  /// than following it, so it is a checkbox here and not a Sharpen method.
  final bool contraSharpen;

  // mClean
  final int mcleanStrength;
  final int mcleanSharp;
  final int mcleanRn;
  final int mcleanThsad;
  final bool mcleanChroma;

  // TemporalDegrain2
  final int td2DegrainTr;
  final int td2GrainLevel;
  final int td2PostFft;
  final double td2PostSigma;
  final int td2PostMix;
  final bool td2ChromaMotion;

  /// ContraSharpening's Repair mode; 13 is havsfunc's own default.
  final int contraSharpenRep;

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

  // --- MCDegrainSharp Parameters ---

  /// Number of neighbouring frames on each side to degrain against (1-3).
  final int mcdsFrames;

  /// Blur strength for the poorly-matched areas (0.0-1.58).
  final double mcdsBlur;

  /// Sharpening strength for the well-matched areas (0.0-1.0).
  final double mcdsSharp;

  /// Run the motion search on the blurred clip, which finds steadier vectors on
  /// noisy sources.
  final bool mcdsBlurSearch;

  /// Block SAD threshold. Low staggers the denoising, high brings ghosting.
  final int mcdsThSad;

  /// Planes to process (0 luma, 1 U, 2 V, 3 both chroma, 4 all).
  final int mcdsPlane;

  // --- QTGMC Built-in Parameters ---
  // These are passed through to QTGMC's noise settings

  /// EZDenoise strength (0.0 to 5.0+).
  final double qtgmcEzDenoise;

  /// EZKeepGrain amount (0.0 to 1.0).
  final double qtgmcEzKeepGrain;

  // --- DFTTest Parameters ---

  /// Denoising strength. DFTTest's own default is 8.0.
  final double dfttestSigma;

  /// Temporal window in frames; forced odd by the worker. 1 is purely spatial.
  final int dfttestTbsize;

  /// Spatial block size. Larger separates frequencies better but is slower.
  final int dfttestSbsize;

  // --- FFT3DFilter Parameters ---

  /// Denoising strength.
  final double fft3dSigma;

  /// Temporal window in frames (1-5). 1 is purely spatial.
  final int fft3dBt;

  /// Post-denoise sharpening (0.0-1.0), omitted at 0.
  final double fft3dSharpen;

  // --- TTempSmooth Parameters ---

  /// Temporal radius (1-7).
  final int ttempMaxr;

  /// Per-pixel difference threshold, above which a pixel is left alone.
  final int ttempThresh;

  /// Motion-difference threshold; the worker holds it below [ttempThresh].
  final int ttempMdiff;

  /// Weighting strength (1-8). Higher weights the current frame more.
  final int ttempStrength;

  // --- FluxSmooth Parameters ---

  /// Temporal threshold: a pixel is averaged only where its neighbours in time
  /// bracket it in value. Higher smooths more and risks motion. -1 disables.
  final int fluxTemporalThreshold;

  /// Spatial threshold for the ST variant. -1 disables the spatial half.
  final int fluxSpatialThreshold;

  // --- STPresso Parameters ---

  /// How far a pixel may move, in 8-bit levels. The whole point of the filter.
  final int stpressoLimit;

  /// Bias toward the original pixel (0-100). Higher keeps more of it.
  final int stpressoBias;

  /// Temporal threshold for the FluxSmoothT it runs internally.
  final int stpressoTthr;

  // --- CTMF Parameters ---

  /// Median window radius. Constant-time, so this costs almost nothing.
  final int ctmfRadius;

  /// Planes to filter: 0 luma only, 1 chroma only, 2 both.
  final int ctmfPlanes;

  const NoiseReductionParameters({
    this.enabled = false,
    this.contraSharpen = false,
    this.mcleanStrength = 20,
    this.mcleanSharp = 10,
    this.mcleanRn = 14,
    this.mcleanThsad = 400,
    this.mcleanChroma = true,
    this.td2DegrainTr = 1,
    this.td2GrainLevel = 2,
    this.td2PostFft = 0,
    this.td2PostSigma = 1.0,
    this.td2PostMix = 0,
    this.td2ChromaMotion = true,
    this.contraSharpenRep = 13,
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
    this.mcTemporalProfile = 'medium',
    // MCDegrainSharp defaults (Didée's published values)
    this.mcdsFrames = 2,
    this.mcdsBlur = 0.3,
    this.mcdsSharp = 0.3,
    this.mcdsBlurSearch = true,
    this.mcdsThSad = 400,
    this.mcdsPlane = 4,
    // QTGMC built-in defaults
    this.qtgmcEzDenoise = 0.0,
    this.qtgmcEzKeepGrain = 0.0,
    this.dfttestSigma = 8.0,
    this.dfttestTbsize = 3,
    this.dfttestSbsize = 16,
    this.fft3dSigma = 2.0,
    this.fft3dBt = 3,
    this.fft3dSharpen = 0.0,
    this.ttempMaxr = 3,
    this.ttempThresh = 4,
    this.ttempMdiff = 2,
    this.ttempStrength = 2,
    this.fluxTemporalThreshold = 7,
    this.fluxSpatialThreshold = 7,
    this.stpressoLimit = 3,
    this.stpressoBias = 24,
    this.stpressoTthr = 12,
    this.ctmfRadius = 2,
    this.ctmfPlanes = 2,
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
    int? mcdsFrames,
    double? mcdsBlur,
    double? mcdsSharp,
    bool? mcdsBlurSearch,
    int? mcdsThSad,
    int? mcdsPlane,
    double? qtgmcEzDenoise,
    double? qtgmcEzKeepGrain,
    double? dfttestSigma,
    int? dfttestTbsize,
    int? dfttestSbsize,
    double? fft3dSigma,
    int? fft3dBt,
    double? fft3dSharpen,
    int? ttempMaxr,
    int? ttempThresh,
    int? ttempMdiff,
    int? ttempStrength,
    int? fluxTemporalThreshold,
    int? fluxSpatialThreshold,
    int? stpressoLimit,
    int? stpressoBias,
    int? stpressoTthr,
    int? ctmfRadius,
    int? ctmfPlanes,
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
      mcdsFrames: mcdsFrames ?? this.mcdsFrames,
      mcdsBlur: mcdsBlur ?? this.mcdsBlur,
      mcdsSharp: mcdsSharp ?? this.mcdsSharp,
      mcdsBlurSearch: mcdsBlurSearch ?? this.mcdsBlurSearch,
      mcdsThSad: mcdsThSad ?? this.mcdsThSad,
      mcdsPlane: mcdsPlane ?? this.mcdsPlane,
      qtgmcEzDenoise: qtgmcEzDenoise ?? this.qtgmcEzDenoise,
      qtgmcEzKeepGrain: qtgmcEzKeepGrain ?? this.qtgmcEzKeepGrain,
      dfttestSigma: dfttestSigma ?? this.dfttestSigma,
      dfttestTbsize: dfttestTbsize ?? this.dfttestTbsize,
      dfttestSbsize: dfttestSbsize ?? this.dfttestSbsize,
      fft3dSigma: fft3dSigma ?? this.fft3dSigma,
      fft3dBt: fft3dBt ?? this.fft3dBt,
      fft3dSharpen: fft3dSharpen ?? this.fft3dSharpen,
      ttempMaxr: ttempMaxr ?? this.ttempMaxr,
      ttempThresh: ttempThresh ?? this.ttempThresh,
      ttempMdiff: ttempMdiff ?? this.ttempMdiff,
      ttempStrength: ttempStrength ?? this.ttempStrength,
      fluxTemporalThreshold:
          fluxTemporalThreshold ?? this.fluxTemporalThreshold,
      fluxSpatialThreshold: fluxSpatialThreshold ?? this.fluxSpatialThreshold,
      stpressoLimit: stpressoLimit ?? this.stpressoLimit,
      stpressoBias: stpressoBias ?? this.stpressoBias,
      stpressoTthr: stpressoTthr ?? this.stpressoTthr,
      ctmfRadius: ctmfRadius ?? this.ctmfRadius,
      ctmfPlanes: ctmfPlanes ?? this.ctmfPlanes,
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
