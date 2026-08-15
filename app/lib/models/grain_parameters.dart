import 'package:json_annotation/json_annotation.dart';

part 'grain_parameters.g.dart';

/// Grain generation method.
enum GrainMethod {
  @JsonValue('addGrain')
  addGrain('AddGrain'),
  @JsonValue('grainFactory3')
  grainFactory3('GrainFactory3');

  const GrainMethod(this.displayName);
  final String displayName;
}

/// Parameters for the film grain pass.
///
/// Re-adds grain after denoising so a cleaned picture does not look plastic,
/// and masks the banding a shallow gradient shows once the noise that was
/// dithering it is gone.
///
/// Runs last of the video passes: grain added before a resize is resampled
/// away, and before a deband is smoothed away.
@JsonSerializable()
class GrainParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Which method to use.
  final GrainMethod method;

  /// Luma grain strength as a variance — the noise standard deviation is its
  /// square root, so 4 gives a subtle sigma of 2.
  ///
  /// `var` is a Dart keyword, so the field is named `var_` and the wire name is
  /// pinned explicitly; without the JsonKey the worker would never see it.
  @JsonKey(name: 'var')
  final double var_;

  /// Chroma grain strength, same units. 0 leaves chroma untouched.
  final double uvar;

  /// Spatial correlation, which makes the grain coarser. Also reduces its
  /// amplitude, so raising it usually means raising strength too.
  final double corr;

  /// Hold the same pattern on every frame. Off by default: static grain over
  /// moving video reads as dirt on the lens.
  final bool constant;

  /// Grain strength in the shadows (GrainFactory3).
  final double g1str;

  /// Grain strength in the midtones (GrainFactory3).
  final double g2str;

  /// Grain strength in the highlights (GrainFactory3).
  final double g3str;

  /// Damps GrainFactory3's animation. It cannot stop it — that filter is always
  /// animated and offers no way to hold the pattern still.
  final int tempAvg;

  const GrainParameters({
    this.enabled = false,
    this.method = GrainMethod.addGrain,
    this.var_ = 4.0,
    this.uvar = 0.0,
    this.corr = 0.0,
    this.constant = false,
    this.g1str = 4.0,
    this.g2str = 3.0,
    this.g3str = 2.0,
    this.tempAvg = 0,
  });

  GrainParameters copyWith({
    bool? enabled,
    GrainMethod? method,
    double? var_,
    double? uvar,
    double? corr,
    bool? constant,
    double? g1str,
    double? g2str,
    double? g3str,
    int? tempAvg,
  }) =>
      GrainParameters(
        enabled: enabled ?? this.enabled,
        method: method ?? this.method,
        var_: var_ ?? this.var_,
        uvar: uvar ?? this.uvar,
        corr: corr ?? this.corr,
        constant: constant ?? this.constant,
        g1str: g1str ?? this.g1str,
        g2str: g2str ?? this.g2str,
        g3str: g3str ?? this.g3str,
        tempAvg: tempAvg ?? this.tempAvg,
      );

  /// Whether the pass would actually change the picture. Zero strength is a
  /// no-op, and the row should say so rather than claim a pass is running.
  bool get hasEffect {
    if (!enabled) return false;
    return method == GrainMethod.addGrain
        ? var_ > 0 || uvar > 0
        : g1str > 0 || g2str > 0 || g3str > 0;
  }

  /// Short summary for the pass list row.
  String get summary {
    if (!enabled) return 'Off';
    if (!hasEffect) return 'No grain selected';
    if (method == GrainMethod.grainFactory3) {
      return 'Film stock (${g1str.toStringAsFixed(0)}/'
          '${g2str.toStringAsFixed(0)}/${g3str.toStringAsFixed(0)})';
    }
    final animated = constant ? 'static' : 'animated';
    return 'Strength ${var_.toStringAsFixed(1)}, $animated';
  }

  factory GrainParameters.fromJson(Map<String, dynamic> json) =>
      _$GrainParametersFromJson(json);
  Map<String, dynamic> toJson() => _$GrainParametersToJson(this);
}
