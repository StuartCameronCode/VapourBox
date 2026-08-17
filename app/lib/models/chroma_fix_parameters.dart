import 'package:json_annotation/json_annotation.dart';

part 'chroma_fix_parameters.g.dart';

/// Chroma fix preset options.
enum ChromaFixPreset {
  @JsonValue('off')
  off,
  @JsonValue('vhsCleanup')
  vhsCleanup,
  @JsonValue('broadcastFix')
  broadcastFix,
  @JsonValue('analogRepair')
  analogRepair,
  @JsonValue('custom')
  custom,
}

/// Parameters for the chroma fix pass.
/// Includes FixChromaBleedingMod, LUTDeCrawl, and Vinverse filters.
@JsonSerializable()
class ChromaFixParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Preset level for simple mode.
  final ChromaFixPreset preset;

  // --- Chroma Shift (Y/C Delay) Parameters ---

  /// Whether to apply chroma shift (Y/C delay correction).
  final bool applyChromaShift;

  /// Horizontal chroma shift in luma pixels (negative = left, positive = right).
  final double chromaShiftH;

  /// Vertical chroma shift in luma pixels (negative = up, positive = down).
  final double chromaShiftV;

  // --- FixChromaBleedingMod Parameters ---

  /// Whether to apply chroma bleeding fix.
  final bool applyChromaBleedingFix;

  /// Chroma X offset correction.
  final int chromaBleedCx;

  /// Chroma Y offset correction.
  final int chromaBleedCy;

  /// Chroma blur strength (0.0 to 1.5+).
  final double chromaBleedCBlur;

  /// Fix strength (0.0 to 1.0).
  final double chromaBleedStrength;

  // --- LUTDeCrawl Parameters ---

  /// Whether to apply de-crawl (chroma crawl/dot crawl fix).
  final bool applyDeCrawl;

  /// Luma threshold for de-crawl.
  final int deCrawlYThresh;

  /// Chroma threshold for de-crawl.
  final int deCrawlCThresh;

  /// Maximum difference allowed.
  final int deCrawlMaxDiff;

  // --- LUTDeRainbow Parameters ---

  /// Whether to apply LUTDeRainbow (cross-luminance / rainbowing removal).
  ///
  /// Same 8-10 bit limit as LUTDeCrawl — havsfunc rejects anything above 10-bit
  /// outright, so the worker runs the pass at 10-bit and restores the source
  /// format afterwards.
  final bool applyDeRainbow;

  /// DeDot — temporal dot crawl / rainbow removal on both planes.
  final bool applyAutoChroma;
  final int autoChromaMaxShift;
  final double autoChromaAccuracy;
  final int autoChromaReferenceFrame;

  final bool applyDedot;
  final int dedotLuma2d;
  final int dedotLumaT;
  final int dedotChromaT1;
  final int dedotChromaT2;

  /// Chroma difference threshold for detecting rainbowing.
  final int deRainbowCThresh;

  /// Luma difference threshold. Areas moving more than this are left alone.
  final int deRainbowYThresh;

  /// Use the luma difference in the decision as well as chroma.
  final bool deRainbowUseLuma;

  /// Require both chroma planes to agree before treating a pixel.
  final bool deRainbowLinkUv;

  // --- Bifrost (temporal rainbow removal) ---

  /// Apply Bifrost. Where LUTDeRainbow decides within a frame, this compares
  /// across frames, so it catches rainbowing that shimmers rather than sits
  /// still. 8-bit only — the worker converts down and restores.
  final bool applyBifrost;

  /// Luma difference above which a block is treated as motion and left alone.
  final double bifrostLumaThresh;

  /// How many neighbouring blocks must agree before a pixel is treated.
  final int bifrostVariation;

  /// Treat the source as interlaced, comparing fields rather than frames.
  final bool bifrostInterlaced;

  // --- Vinverse Parameters ---

  /// Whether to apply Vinverse (inverted telecine/chroma fix).
  final bool applyVinverse;

  /// Spatial strength for Vinverse.
  final double vinverseSstr;

  /// Amount parameter for Vinverse (0-255).
  final int vinverseAmnt;

  const ChromaFixParameters({
    this.enabled = false,
    this.preset = ChromaFixPreset.off,
    // Chroma Shift defaults
    this.applyChromaShift = false,
    this.chromaShiftH = 0.0,
    this.chromaShiftV = 0.0,
    // FixChromaBleedingMod defaults
    this.applyChromaBleedingFix = false,
    this.chromaBleedCx = 4,
    this.chromaBleedCy = 4,
    this.chromaBleedCBlur = 0.7,
    this.chromaBleedStrength = 0.8,
    // LUTDeCrawl defaults
    this.applyDeCrawl = false,
    this.deCrawlYThresh = 10,
    this.deCrawlCThresh = 10,
    this.deCrawlMaxDiff = 50,
    // Vinverse defaults
    this.applyDeRainbow = false,
    this.applyAutoChroma = false,
    this.autoChromaMaxShift = 2,
    this.autoChromaAccuracy = 0.25,
    this.autoChromaReferenceFrame = 0,
    this.applyDedot = false,
    this.dedotLuma2d = 20,
    this.dedotLumaT = 20,
    this.dedotChromaT1 = 15,
    this.dedotChromaT2 = 5,
    this.deRainbowCThresh = 10,
    this.deRainbowYThresh = 10,
    this.deRainbowUseLuma = true,
    this.deRainbowLinkUv = true,
    this.applyBifrost = false,
    this.bifrostLumaThresh = 10.0,
    this.bifrostVariation = 5,
    this.bifrostInterlaced = true,
    this.applyVinverse = false,
    this.vinverseSstr = 2.7,
    this.vinverseAmnt = 255,
  });

  /// Create parameters from a preset.
  factory ChromaFixParameters.fromPreset(ChromaFixPreset preset) {
    switch (preset) {
      case ChromaFixPreset.off:
        return const ChromaFixParameters(
          enabled: false,
          preset: ChromaFixPreset.off,
        );
      case ChromaFixPreset.vhsCleanup:
        return const ChromaFixParameters(
          enabled: true,
          preset: ChromaFixPreset.vhsCleanup,
          applyChromaBleedingFix: true,
          chromaBleedCBlur: 0.8,
          chromaBleedStrength: 0.8,
          applyVinverse: true,
          vinverseSstr: 2.7,
        );
      case ChromaFixPreset.broadcastFix:
        return const ChromaFixParameters(
          enabled: true,
          preset: ChromaFixPreset.broadcastFix,
          applyDeCrawl: true,
          deCrawlYThresh: 12,
          deCrawlCThresh: 12,
        );
      case ChromaFixPreset.analogRepair:
        return const ChromaFixParameters(
          enabled: true,
          preset: ChromaFixPreset.analogRepair,
          applyChromaBleedingFix: true,
          chromaBleedCBlur: 1.0,
          chromaBleedStrength: 1.0,
          applyDeCrawl: true,
          applyVinverse: true,
        );
      case ChromaFixPreset.custom:
        return const ChromaFixParameters(
          enabled: true,
          preset: ChromaFixPreset.custom,
        );
    }
  }

  ChromaFixParameters copyWith({
    bool? enabled,
    ChromaFixPreset? preset,
    bool? applyChromaShift,
    double? chromaShiftH,
    double? chromaShiftV,
    bool? applyChromaBleedingFix,
    int? chromaBleedCx,
    int? chromaBleedCy,
    double? chromaBleedCBlur,
    double? chromaBleedStrength,
    bool? applyDeCrawl,
    int? deCrawlYThresh,
    int? deCrawlCThresh,
    int? deCrawlMaxDiff,
    bool? applyDeRainbow,
    int? deRainbowCThresh,
    int? deRainbowYThresh,
    bool? deRainbowUseLuma,
    bool? deRainbowLinkUv,
    bool? applyBifrost,
    double? bifrostLumaThresh,
    int? bifrostVariation,
    bool? bifrostInterlaced,
    bool? applyVinverse,
    double? vinverseSstr,
    int? vinverseAmnt,
  }) {
    return ChromaFixParameters(
      enabled: enabled ?? this.enabled,
      preset: preset ?? this.preset,
      applyChromaShift: applyChromaShift ?? this.applyChromaShift,
      chromaShiftH: chromaShiftH ?? this.chromaShiftH,
      chromaShiftV: chromaShiftV ?? this.chromaShiftV,
      applyChromaBleedingFix: applyChromaBleedingFix ?? this.applyChromaBleedingFix,
      chromaBleedCx: chromaBleedCx ?? this.chromaBleedCx,
      chromaBleedCy: chromaBleedCy ?? this.chromaBleedCy,
      chromaBleedCBlur: chromaBleedCBlur ?? this.chromaBleedCBlur,
      chromaBleedStrength: chromaBleedStrength ?? this.chromaBleedStrength,
      applyDeCrawl: applyDeCrawl ?? this.applyDeCrawl,
      deCrawlYThresh: deCrawlYThresh ?? this.deCrawlYThresh,
      deCrawlCThresh: deCrawlCThresh ?? this.deCrawlCThresh,
      deCrawlMaxDiff: deCrawlMaxDiff ?? this.deCrawlMaxDiff,
      applyDeRainbow: applyDeRainbow ?? this.applyDeRainbow,
      deRainbowCThresh: deRainbowCThresh ?? this.deRainbowCThresh,
      deRainbowYThresh: deRainbowYThresh ?? this.deRainbowYThresh,
      deRainbowUseLuma: deRainbowUseLuma ?? this.deRainbowUseLuma,
      deRainbowLinkUv: deRainbowLinkUv ?? this.deRainbowLinkUv,
      applyBifrost: applyBifrost ?? this.applyBifrost,
      bifrostLumaThresh: bifrostLumaThresh ?? this.bifrostLumaThresh,
      bifrostVariation: bifrostVariation ?? this.bifrostVariation,
      bifrostInterlaced: bifrostInterlaced ?? this.bifrostInterlaced,
      applyVinverse: applyVinverse ?? this.applyVinverse,
      vinverseSstr: vinverseSstr ?? this.vinverseSstr,
      vinverseAmnt: vinverseAmnt ?? this.vinverseAmnt,
    );
  }

  /// Get a human-readable summary of the current settings.
  String get summary {
    if (!enabled) return 'Off';
    if (preset != ChromaFixPreset.custom && preset != ChromaFixPreset.off) {
      switch (preset) {
        case ChromaFixPreset.vhsCleanup:
          return 'VHS Cleanup';
        case ChromaFixPreset.broadcastFix:
          return 'Broadcast Fix';
        case ChromaFixPreset.analogRepair:
          return 'Analog Repair';
        default:
          return preset.name;
      }
    }
    final fixes = <String>[];
    if (applyChromaShift) fixes.add('Shift');
    if (applyChromaBleedingFix) fixes.add('Bleed');
    if (applyDeCrawl) fixes.add('Crawl');
    if (applyVinverse) fixes.add('Vinv');
    return fixes.isEmpty ? 'Custom' : fixes.join('+');
  }

  factory ChromaFixParameters.fromJson(Map<String, dynamic> json) =>
      _$ChromaFixParametersFromJson(json);

  Map<String, dynamic> toJson() => _$ChromaFixParametersToJson(this);
}
