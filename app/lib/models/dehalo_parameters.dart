import 'package:json_annotation/json_annotation.dart';

part 'dehalo_parameters.g.dart';

/// Dehalo method options.
@JsonEnum(valueField: 'value')
enum DehaloMethod {
  @JsonValue('DeHalo_alpha')
  dehaloAlpha('DeHalo_alpha', 'DeHalo Alpha'),
  @JsonValue('FineDehalo')
  fineDehalo('FineDehalo', 'Fine Dehalo'),
  @JsonValue('FineDehalo2')
  fineDehalo2('FineDehalo2', 'Fine Dehalo 2'),
  @JsonValue('YAHR')
  yahr('YAHR', 'YAHR'),
  @JsonValue('EdgeCleaner')
  edgeCleaner('EdgeCleaner', 'Edge Cleaner'),
  @JsonValue('Vinverse')
  vinverse('Vinverse', 'Vinverse (de-ghost)'),
  @JsonValue('Vinverse2')
  vinverse2('Vinverse2', 'Vinverse 2 (de-ghost)');

  const DehaloMethod(this.value, this.displayName);
  final String value;
  final String displayName;

  String get description {
    switch (this) {
      case DehaloMethod.dehaloAlpha:
        return 'General purpose dehalo, good for most sources';
      case DehaloMethod.fineDehalo:
        return 'More precise, better edge preservation';
      case DehaloMethod.fineDehalo2:
        return 'Removes the ringing left on sharp edges — run after Fine Dehalo';
      case DehaloMethod.yahr:
        return 'Yet Another Halo Remover - fast and effective';
      case DehaloMethod.edgeCleaner:
        return 'Cleans edge noise and weak halos (aWarpSharp2)';
      case DehaloMethod.vinverse:
        return 'Removes comb/ghost residue left by deinterlacing';
      case DehaloMethod.vinverse2:
        return 'Like Vinverse but keeps more vertical detail';
    }
  }
}

/// Parameters for the dehalo pass.
/// Removes halo artifacts around edges, plus ringing and comb/ghost residue.
///
/// Nullable fields are omitted from the generated script when unset, so
/// havsfunc's own default applies. The non-nullable ones predate that and are
/// always passed — making them nullable would change existing output.
@JsonSerializable()
class DehaloParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Dehalo method to use.
  final DehaloMethod method;

  // --- DeHalo_alpha / FineDehalo parameters ---

  /// Horizontal radius for halo detection (1.0-3.0).
  final double rx;

  /// Vertical radius for halo detection (1.0-3.0).
  final double ry;

  /// Dark halo removal strength (0.0-2.0; above 1.0 overshoots).
  final double darkStr;

  /// Bright halo removal strength (0.0-2.0; above 1.0 overshoots).
  final double brightStr;

  // --- DeHalo_alpha specific ---

  /// Sensitivity to strong halos (havsfunc `lowsens`, 0-100).
  final int? lowSens;

  /// Sensitivity to weak halos (havsfunc `highsens`, 0-100).
  final int? highSens;

  /// Supersampling factor used while removing halos (havsfunc `ss`).
  final double? superSample;

  // --- FineDehalo specific ---

  /// Low threshold for halo mask.
  final int lowThreshold;

  /// High threshold for halo mask.
  final int highThreshold;

  /// Lower limit on how much of a halo may be removed (havsfunc `thlimi`).
  final int? limitLow;

  /// Upper limit on how much of a halo may be removed (havsfunc `thlima`).
  final int? limitHigh;

  /// Contra-sharpening strength applied after dehaloing (havsfunc `contra`).
  final double? contra;

  /// Exclude edges that are too close to each other (havsfunc `excl`).
  final bool? excludeCloseEdges;

  /// How much edge detail to add back (havsfunc `edgeproc`).
  final double? edgeProc;

  // --- YAHR specific ---

  /// Blur amount for YAHR (1-3).
  final int yahrBlur;

  /// Processing depth for YAHR.
  final int yahrDepth;

  // --- EdgeCleaner specific ---

  /// Edge denoising strength (havsfunc `strength`).
  final int? edgeStrength;

  /// Repair the aWarpSharped clip (havsfunc `rep`).
  final bool? edgeRepair;

  /// Repair mode (havsfunc `rmode`: 1 mild, 16/18 keep structure, 17 least halo).
  final int? edgeRepairMode;

  /// Small-particle (star) detection mode (havsfunc `smode`).
  final int? edgeSmallMode;

  /// Remove hot pixels (havsfunc `hot`).
  final bool? edgeHotPixels;

  // --- Vinverse / Vinverse2 specific ---

  /// Sharpening strength applied to the vertically blurred clip (`sstr`).
  final double? vinverseStrength;

  /// Maximum change per pixel (havsfunc `amnt`, 255 = unlimited).
  final int? vinverseAmount;

  /// Process chroma as well as luma (havsfunc `chroma`).
  final bool? vinverseChroma;

  const DehaloParameters({
    this.enabled = false,
    this.method = DehaloMethod.dehaloAlpha,
    this.rx = 2.0,
    this.ry = 2.0,
    this.darkStr = 1.0,
    this.brightStr = 1.0,
    this.lowSens,
    this.highSens,
    this.superSample,
    this.lowThreshold = 50,
    this.highThreshold = 100,
    this.limitLow,
    this.limitHigh,
    this.contra,
    this.excludeCloseEdges,
    this.edgeProc,
    this.yahrBlur = 2,
    this.yahrDepth = 32,
    this.edgeStrength,
    this.edgeRepair,
    this.edgeRepairMode,
    this.edgeSmallMode,
    this.edgeHotPixels,
    this.vinverseStrength,
    this.vinverseAmount,
    this.vinverseChroma,
  });

  DehaloParameters copyWith({
    bool? enabled,
    DehaloMethod? method,
    double? rx,
    double? ry,
    double? darkStr,
    double? brightStr,
    int? lowSens,
    int? highSens,
    double? superSample,
    int? lowThreshold,
    int? highThreshold,
    int? limitLow,
    int? limitHigh,
    double? contra,
    bool? excludeCloseEdges,
    double? edgeProc,
    int? yahrBlur,
    int? yahrDepth,
    int? edgeStrength,
    bool? edgeRepair,
    int? edgeRepairMode,
    int? edgeSmallMode,
    bool? edgeHotPixels,
    double? vinverseStrength,
    int? vinverseAmount,
    bool? vinverseChroma,
  }) {
    return DehaloParameters(
      enabled: enabled ?? this.enabled,
      method: method ?? this.method,
      rx: rx ?? this.rx,
      ry: ry ?? this.ry,
      darkStr: darkStr ?? this.darkStr,
      brightStr: brightStr ?? this.brightStr,
      lowSens: lowSens ?? this.lowSens,
      highSens: highSens ?? this.highSens,
      superSample: superSample ?? this.superSample,
      lowThreshold: lowThreshold ?? this.lowThreshold,
      highThreshold: highThreshold ?? this.highThreshold,
      limitLow: limitLow ?? this.limitLow,
      limitHigh: limitHigh ?? this.limitHigh,
      contra: contra ?? this.contra,
      excludeCloseEdges: excludeCloseEdges ?? this.excludeCloseEdges,
      edgeProc: edgeProc ?? this.edgeProc,
      yahrBlur: yahrBlur ?? this.yahrBlur,
      yahrDepth: yahrDepth ?? this.yahrDepth,
      edgeStrength: edgeStrength ?? this.edgeStrength,
      edgeRepair: edgeRepair ?? this.edgeRepair,
      edgeRepairMode: edgeRepairMode ?? this.edgeRepairMode,
      edgeSmallMode: edgeSmallMode ?? this.edgeSmallMode,
      edgeHotPixels: edgeHotPixels ?? this.edgeHotPixels,
      vinverseStrength: vinverseStrength ?? this.vinverseStrength,
      vinverseAmount: vinverseAmount ?? this.vinverseAmount,
      vinverseChroma: vinverseChroma ?? this.vinverseChroma,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    return method.displayName;
  }

  factory DehaloParameters.fromJson(Map<String, dynamic> json) =>
      _$DehaloParametersFromJson(json);
  Map<String, dynamic> toJson() => _$DehaloParametersToJson(this);
}
