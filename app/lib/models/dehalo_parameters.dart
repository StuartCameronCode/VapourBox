import 'package:json_annotation/json_annotation.dart';

part 'dehalo_parameters.g.dart';

/// Dehalo method options.
@JsonEnum(valueField: 'value')
enum DehaloMethod {
  @JsonValue('DeHalo_alpha')
  dehaloAlpha('DeHalo_alpha', 'DeHalo Alpha'),
  @JsonValue('FineDehalo')
  fineDehalo('FineDehalo', 'Fine Dehalo'),
  @JsonValue('YAHR')
  yahr('YAHR', 'YAHR');

  const DehaloMethod(this.value, this.displayName);
  final String value;
  final String displayName;

  String get description {
    switch (this) {
      case DehaloMethod.dehaloAlpha:
        return 'General purpose dehalo, good for most sources';
      case DehaloMethod.fineDehalo:
        return 'More precise, better edge preservation';
      case DehaloMethod.yahr:
        return 'Yet Another Halo Remover - fast and effective';
    }
  }
}

/// Parameters for the dehalo pass.
/// Removes halo artifacts around edges.
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

  /// Dark halo removal strength (0.0-1.0).
  final double darkStr;

  /// Bright halo removal strength (0.0-1.0).
  final double brightStr;

  // --- FineDehalo specific ---

  /// Low threshold for halo mask.
  final int lowThreshold;

  /// High threshold for halo mask.
  final int highThreshold;

  // --- YAHR specific ---

  /// Blur amount for YAHR (1-3).
  final int yahrBlur;

  /// Processing depth for YAHR.
  final int yahrDepth;

  const DehaloParameters({
    this.enabled = false,
    this.method = DehaloMethod.dehaloAlpha,
    this.rx = 2.0,
    this.ry = 2.0,
    this.darkStr = 1.0,
    this.brightStr = 1.0,
    this.lowThreshold = 50,
    this.highThreshold = 100,
    this.yahrBlur = 2,
    this.yahrDepth = 32,
  });

  DehaloParameters copyWith({
    bool? enabled,
    DehaloMethod? method,
    double? rx,
    double? ry,
    double? darkStr,
    double? brightStr,
    int? lowThreshold,
    int? highThreshold,
    int? yahrBlur,
    int? yahrDepth,
  }) {
    return DehaloParameters(
      enabled: enabled ?? this.enabled,
      method: method ?? this.method,
      rx: rx ?? this.rx,
      ry: ry ?? this.ry,
      darkStr: darkStr ?? this.darkStr,
      brightStr: brightStr ?? this.brightStr,
      lowThreshold: lowThreshold ?? this.lowThreshold,
      highThreshold: highThreshold ?? this.highThreshold,
      yahrBlur: yahrBlur ?? this.yahrBlur,
      yahrDepth: yahrDepth ?? this.yahrDepth,
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
