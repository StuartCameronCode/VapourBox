import 'package:json_annotation/json_annotation.dart';

part 'qtgmc_parameters.g.dart';

/// QTGMC quality/speed presets.
@JsonEnum()
enum QTGMCPreset {
  @JsonValue('Placebo')
  placebo,
  @JsonValue('Very Slow')
  verySlow,
  @JsonValue('Slower')
  slower,
  @JsonValue('Slow')
  slow,
  @JsonValue('Medium')
  medium,
  @JsonValue('Fast')
  fast,
  @JsonValue('Faster')
  faster,
  @JsonValue('Very Fast')
  veryFast,
  @JsonValue('Super Fast')
  superFast,
  @JsonValue('Ultra Fast')
  ultraFast,
  @JsonValue('Draft')
  draft;

  String get displayName {
    switch (this) {
      case QTGMCPreset.placebo:
        return 'Placebo';
      case QTGMCPreset.verySlow:
        return 'Very Slow';
      case QTGMCPreset.slower:
        return 'Slower';
      case QTGMCPreset.slow:
        return 'Slow';
      case QTGMCPreset.medium:
        return 'Medium';
      case QTGMCPreset.fast:
        return 'Fast';
      case QTGMCPreset.faster:
        return 'Faster';
      case QTGMCPreset.veryFast:
        return 'Very Fast';
      case QTGMCPreset.superFast:
        return 'Super Fast';
      case QTGMCPreset.ultraFast:
        return 'Ultra Fast';
      case QTGMCPreset.draft:
        return 'Draft';
    }
  }

  String get description {
    switch (this) {
      case QTGMCPreset.placebo:
        return 'Highest quality, very slow';
      case QTGMCPreset.verySlow:
        return 'Excellent quality, slow';
      case QTGMCPreset.slower:
        return 'Very high quality (recommended)';
      case QTGMCPreset.slow:
        return 'High quality, moderate speed';
      case QTGMCPreset.medium:
        return 'Good quality, faster';
      case QTGMCPreset.fast:
        return 'Fair quality, fast';
      case QTGMCPreset.faster:
        return 'Lower quality, very fast';
      case QTGMCPreset.veryFast:
        return 'Basic quality, very fast';
      case QTGMCPreset.superFast:
        return 'Minimal quality, fastest';
      case QTGMCPreset.ultraFast:
        return 'Lowest quality (uses yadif)';
      case QTGMCPreset.draft:
        return 'Testing only';
    }
  }
}

/// All QTGMC parameters supported by the VapourSynth implementation.
@JsonSerializable()
class QTGMCParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  // === Preset ===
  final QTGMCPreset preset;

  // === Input/Output ===
  final int inputType;
  final bool? tff;
  final int fpsDivisor;

  // === Quality (Temporal Radius) ===
  final int? tr0;
  final int? tr1;
  final int? tr2;
  final int? rep0;
  final int rep1;
  final int? rep2;
  final bool repChroma;

  // === Interpolation ===
  final String? ediMode;
  final int? nnSize;
  final int? nnNeurons;
  final int ediQual;
  final int? ediMaxD;
  final String chromaEdi;

  // === Motion Analysis ===
  final int? blockSize;
  final int? overlap;
  final int? search;
  final int? searchParam;
  final int? pelSearch;
  final bool? chromaMotion;
  final bool trueMotion;
  final int? lambda;
  final int? lsad;
  final int? pNew;
  final int? pLevel;
  final bool globalMotion;
  final int dct;
  final int? subPel;
  final int subPelInterp;

  // === Motion Thresholds ===
  final int thSad1;
  final int thSad2;
  final int thScd1;
  final int thScd2;

  // === Sharpening ===
  final double? sharpness;
  final int? sMode;
  final int? slMode;
  final int? slRad;
  final int sOvs;
  final double svThin;
  final int? sbb;
  final int? srchClipPp;

  // === Noise Processing ===
  final int? noiseProcess;
  final double? ezDenoise;
  final double? ezKeepGrain;
  final String noisePreset;
  final String? denoiser;
  final int fftThreads;
  final bool? denoiseMc;
  final int? noiseTr;
  final double? sigma;
  final bool chromaNoise;
  final double showNoise;
  final double? grainRestore;
  final double? noiseRestore;
  final String? noiseDeint;
  final bool? stabilizeNoise;

  // === Source Matching ===
  final int sourceMatch;
  final String? matchPreset;
  final String? matchEdi;
  final String? matchPreset2;
  final String? matchEdi2;
  final int matchTr2;
  final double matchEnhance;
  final int lossless;

  // === Advanced ===
  final bool border;
  final bool? precise;
  final int forceTr;
  final double str;
  final double amp;
  final bool fastMa;
  final bool eSearchP;
  final bool refineMotion;

  // === GPU Acceleration ===
  final bool opencl;
  final int? device;

  const QTGMCParameters({
    this.enabled = true,
    this.preset = QTGMCPreset.slower,
    this.inputType = 0,
    this.tff,
    this.fpsDivisor = 1,
    this.tr0,
    this.tr1,
    this.tr2,
    this.rep0,
    this.rep1 = 0,
    this.rep2,
    this.repChroma = true,
    this.ediMode,
    this.nnSize,
    this.nnNeurons,
    this.ediQual = 1,
    this.ediMaxD,
    this.chromaEdi = '',
    this.blockSize,
    this.overlap,
    this.search,
    this.searchParam,
    this.pelSearch,
    this.chromaMotion,
    this.trueMotion = false,
    this.lambda,
    this.lsad,
    this.pNew,
    this.pLevel,
    this.globalMotion = true,
    this.dct = 0,
    this.subPel,
    this.subPelInterp = 2,
    this.thSad1 = 640,
    this.thSad2 = 256,
    this.thScd1 = 180,
    this.thScd2 = 98,
    this.sharpness,
    this.sMode,
    this.slMode,
    this.slRad,
    this.sOvs = 0,
    this.svThin = 0.0,
    this.sbb,
    this.srchClipPp,
    this.noiseProcess,
    this.ezDenoise,
    this.ezKeepGrain,
    this.noisePreset = 'Fast',
    this.denoiser,
    this.fftThreads = 1,
    this.denoiseMc,
    this.noiseTr,
    this.sigma,
    this.chromaNoise = false,
    this.showNoise = 0.0,
    this.grainRestore,
    this.noiseRestore,
    this.noiseDeint,
    this.stabilizeNoise,
    this.sourceMatch = 0,
    this.matchPreset,
    this.matchEdi,
    this.matchPreset2,
    this.matchEdi2,
    this.matchTr2 = 1,
    this.matchEnhance = 0.5,
    this.lossless = 0,
    this.border = false,
    this.precise,
    this.forceTr = 0,
    this.str = 2.0,
    this.amp = 0.0625,
    this.fastMa = false,
    this.eSearchP = false,
    this.refineMotion = false,
    this.opencl = false,
    this.device,
  });

  factory QTGMCParameters.fromJson(Map<String, dynamic> json) =>
      _$QTGMCParametersFromJson(json);
  Map<String, dynamic> toJson() => _$QTGMCParametersToJson(this);

  QTGMCParameters copyWith({
    bool? enabled,
    QTGMCPreset? preset,
    int? inputType,
    bool? tff,
    int? fpsDivisor,
    int? tr0,
    int? tr1,
    int? tr2,
    int? rep0,
    int? rep1,
    int? rep2,
    bool? repChroma,
    String? ediMode,
    int? nnSize,
    int? nnNeurons,
    int? ediQual,
    int? ediMaxD,
    String? chromaEdi,
    int? blockSize,
    int? overlap,
    int? search,
    int? searchParam,
    int? pelSearch,
    bool? chromaMotion,
    bool? trueMotion,
    int? lambda,
    int? lsad,
    int? pNew,
    int? pLevel,
    bool? globalMotion,
    int? dct,
    int? subPel,
    int? subPelInterp,
    int? thSad1,
    int? thSad2,
    int? thScd1,
    int? thScd2,
    double? sharpness,
    int? sMode,
    int? slMode,
    int? slRad,
    int? sOvs,
    double? svThin,
    int? sbb,
    int? srchClipPp,
    int? noiseProcess,
    double? ezDenoise,
    double? ezKeepGrain,
    String? noisePreset,
    String? denoiser,
    int? fftThreads,
    bool? denoiseMc,
    int? noiseTr,
    double? sigma,
    bool? chromaNoise,
    double? showNoise,
    double? grainRestore,
    double? noiseRestore,
    String? noiseDeint,
    bool? stabilizeNoise,
    int? sourceMatch,
    String? matchPreset,
    String? matchEdi,
    String? matchPreset2,
    String? matchEdi2,
    int? matchTr2,
    double? matchEnhance,
    int? lossless,
    bool? border,
    bool? precise,
    int? forceTr,
    double? str,
    double? amp,
    bool? fastMa,
    bool? eSearchP,
    bool? refineMotion,
    bool? opencl,
    int? device,
  }) {
    return QTGMCParameters(
      enabled: enabled ?? this.enabled,
      preset: preset ?? this.preset,
      inputType: inputType ?? this.inputType,
      tff: tff ?? this.tff,
      fpsDivisor: fpsDivisor ?? this.fpsDivisor,
      tr0: tr0 ?? this.tr0,
      tr1: tr1 ?? this.tr1,
      tr2: tr2 ?? this.tr2,
      rep0: rep0 ?? this.rep0,
      rep1: rep1 ?? this.rep1,
      rep2: rep2 ?? this.rep2,
      repChroma: repChroma ?? this.repChroma,
      ediMode: ediMode ?? this.ediMode,
      nnSize: nnSize ?? this.nnSize,
      nnNeurons: nnNeurons ?? this.nnNeurons,
      ediQual: ediQual ?? this.ediQual,
      ediMaxD: ediMaxD ?? this.ediMaxD,
      chromaEdi: chromaEdi ?? this.chromaEdi,
      blockSize: blockSize ?? this.blockSize,
      overlap: overlap ?? this.overlap,
      search: search ?? this.search,
      searchParam: searchParam ?? this.searchParam,
      pelSearch: pelSearch ?? this.pelSearch,
      chromaMotion: chromaMotion ?? this.chromaMotion,
      trueMotion: trueMotion ?? this.trueMotion,
      lambda: lambda ?? this.lambda,
      lsad: lsad ?? this.lsad,
      pNew: pNew ?? this.pNew,
      pLevel: pLevel ?? this.pLevel,
      globalMotion: globalMotion ?? this.globalMotion,
      dct: dct ?? this.dct,
      subPel: subPel ?? this.subPel,
      subPelInterp: subPelInterp ?? this.subPelInterp,
      thSad1: thSad1 ?? this.thSad1,
      thSad2: thSad2 ?? this.thSad2,
      thScd1: thScd1 ?? this.thScd1,
      thScd2: thScd2 ?? this.thScd2,
      sharpness: sharpness ?? this.sharpness,
      sMode: sMode ?? this.sMode,
      slMode: slMode ?? this.slMode,
      slRad: slRad ?? this.slRad,
      sOvs: sOvs ?? this.sOvs,
      svThin: svThin ?? this.svThin,
      sbb: sbb ?? this.sbb,
      srchClipPp: srchClipPp ?? this.srchClipPp,
      noiseProcess: noiseProcess ?? this.noiseProcess,
      ezDenoise: ezDenoise ?? this.ezDenoise,
      ezKeepGrain: ezKeepGrain ?? this.ezKeepGrain,
      noisePreset: noisePreset ?? this.noisePreset,
      denoiser: denoiser ?? this.denoiser,
      fftThreads: fftThreads ?? this.fftThreads,
      denoiseMc: denoiseMc ?? this.denoiseMc,
      noiseTr: noiseTr ?? this.noiseTr,
      sigma: sigma ?? this.sigma,
      chromaNoise: chromaNoise ?? this.chromaNoise,
      showNoise: showNoise ?? this.showNoise,
      grainRestore: grainRestore ?? this.grainRestore,
      noiseRestore: noiseRestore ?? this.noiseRestore,
      noiseDeint: noiseDeint ?? this.noiseDeint,
      stabilizeNoise: stabilizeNoise ?? this.stabilizeNoise,
      sourceMatch: sourceMatch ?? this.sourceMatch,
      matchPreset: matchPreset ?? this.matchPreset,
      matchEdi: matchEdi ?? this.matchEdi,
      matchPreset2: matchPreset2 ?? this.matchPreset2,
      matchEdi2: matchEdi2 ?? this.matchEdi2,
      matchTr2: matchTr2 ?? this.matchTr2,
      matchEnhance: matchEnhance ?? this.matchEnhance,
      lossless: lossless ?? this.lossless,
      border: border ?? this.border,
      precise: precise ?? this.precise,
      forceTr: forceTr ?? this.forceTr,
      str: str ?? this.str,
      amp: amp ?? this.amp,
      fastMa: fastMa ?? this.fastMa,
      eSearchP: eSearchP ?? this.eSearchP,
      refineMotion: refineMotion ?? this.refineMotion,
      opencl: opencl ?? this.opencl,
      device: device ?? this.device,
    );
  }
}
