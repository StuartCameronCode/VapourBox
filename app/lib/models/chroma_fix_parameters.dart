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

  // --- Vinverse Parameters ---

  /// Whether to apply Vinverse (inverted telecine/chroma fix).
  final bool applyVinverse;

  /// Spatial strength for Vinverse.
  final double vinverseSstr;

  /// Amount parameter for Vinverse (0-255).
  final int vinverseAmnt;

  /// Scale parameter for Vinverse.
  final int vinverseScl;

  const ChromaFixParameters({
    this.enabled = false,
    this.preset = ChromaFixPreset.off,
    // FixChromaBleedingMod defaults
    this.applyChromaBleedingFix = false,
    this.chromaBleedCx = 4,
    this.chromaBleedCy = 4,
    this.chromaBleedCBlur = 0.7,
    this.chromaBleedStrength = 1.0,
    // LUTDeCrawl defaults
    this.applyDeCrawl = false,
    this.deCrawlYThresh = 10,
    this.deCrawlCThresh = 10,
    this.deCrawlMaxDiff = 50,
    // Vinverse defaults
    this.applyVinverse = false,
    this.vinverseSstr = 2.7,
    this.vinverseAmnt = 255,
    this.vinverseScl = 12,
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
    bool? applyChromaBleedingFix,
    int? chromaBleedCx,
    int? chromaBleedCy,
    double? chromaBleedCBlur,
    double? chromaBleedStrength,
    bool? applyDeCrawl,
    int? deCrawlYThresh,
    int? deCrawlCThresh,
    int? deCrawlMaxDiff,
    bool? applyVinverse,
    double? vinverseSstr,
    int? vinverseAmnt,
    int? vinverseScl,
  }) {
    return ChromaFixParameters(
      enabled: enabled ?? this.enabled,
      preset: preset ?? this.preset,
      applyChromaBleedingFix: applyChromaBleedingFix ?? this.applyChromaBleedingFix,
      chromaBleedCx: chromaBleedCx ?? this.chromaBleedCx,
      chromaBleedCy: chromaBleedCy ?? this.chromaBleedCy,
      chromaBleedCBlur: chromaBleedCBlur ?? this.chromaBleedCBlur,
      chromaBleedStrength: chromaBleedStrength ?? this.chromaBleedStrength,
      applyDeCrawl: applyDeCrawl ?? this.applyDeCrawl,
      deCrawlYThresh: deCrawlYThresh ?? this.deCrawlYThresh,
      deCrawlCThresh: deCrawlCThresh ?? this.deCrawlCThresh,
      deCrawlMaxDiff: deCrawlMaxDiff ?? this.deCrawlMaxDiff,
      applyVinverse: applyVinverse ?? this.applyVinverse,
      vinverseSstr: vinverseSstr ?? this.vinverseSstr,
      vinverseAmnt: vinverseAmnt ?? this.vinverseAmnt,
      vinverseScl: vinverseScl ?? this.vinverseScl,
    );
  }

  /// Get a human-readable summary of the current settings.
  String get summary {
    if (!enabled) return 'Off';
    if (preset != ChromaFixPreset.custom) {
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
    if (applyChromaBleedingFix) fixes.add('Bleed');
    if (applyDeCrawl) fixes.add('Crawl');
    if (applyVinverse) fixes.add('Vinv');
    return fixes.isEmpty ? 'Custom' : fixes.join('+');
  }

  factory ChromaFixParameters.fromJson(Map<String, dynamic> json) =>
      _$ChromaFixParametersFromJson(json);

  Map<String, dynamic> toJson() => _$ChromaFixParametersToJson(this);
}
