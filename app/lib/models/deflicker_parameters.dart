import 'package:json_annotation/json_annotation.dart';

part 'deflicker_parameters.g.dart';

/// Which deflicker to run.
enum DeflickerMethod {
  @JsonValue('global')
  global('Whole frame'),
  @JsonValue('local')
  local('Across the frame');

  const DeflickerMethod(this.displayName);
  final String displayName;
}

/// Deflicker — even out brightness pulsing between frames.
@JsonSerializable()
class DeflickerParameters {
  final bool enabled;
  final DeflickerMethod method;

  /// Global: how far the correction is applied, 0-1.
  final double strength;

  /// Global: frames either side used for the reference average.
  final int window;

  /// Local: 1-3.
  final int localStrength;

  /// Local: asymmetric fold — stronger, less conservative.
  final bool aggressive;

  const DeflickerParameters({
    this.enabled = false,
    this.method = DeflickerMethod.global,
    this.strength = 1.0,
    this.window = 5,
    this.localStrength = 2,
    this.aggressive = false,
  });

  DeflickerParameters copyWith({
    bool? enabled,
    DeflickerMethod? method,
    double? strength,
    int? window,
    int? localStrength,
    bool? aggressive,
  }) =>
      DeflickerParameters(
        enabled: enabled ?? this.enabled,
        method: method ?? this.method,
        strength: strength ?? this.strength,
        window: window ?? this.window,
        localStrength: localStrength ?? this.localStrength,
        aggressive: aggressive ?? this.aggressive,
      );

  String get summary => enabled ? method.displayName : 'Off';

  factory DeflickerParameters.fromJson(Map<String, dynamic> json) =>
      _$DeflickerParametersFromJson(json);
  Map<String, dynamic> toJson() => _$DeflickerParametersToJson(this);
}
