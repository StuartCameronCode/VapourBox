import 'package:json_annotation/json_annotation.dart';

part 'stabilize_parameters.g.dart';

/// Parameters for the stabilisation pass.
///
/// Cancels global shake — telecine weave, jittery film scans, handheld
/// camcorder footage — while leaving deliberate camera movement alone. It shifts
/// the picture within the frame, so it runs last before framing: a crop can then
/// remove the edges it exposes.
///
/// The frame count is unchanged, which is what keeps this an ordinary pass
/// rather than one of the frame-rate-changing filters.
@JsonSerializable()
class StabilizeParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Maximum horizontal correction in pixels.
  final int dxmax;

  /// Maximum vertical correction in pixels.
  final int dymax;

  /// How to fill the edges the shift exposes: 0 none (left black), 1 top and
  /// bottom, 2 left and right, 3 all four.
  ///
  /// The bundled havsfunc signature is `Stab(clp, dxmax, dymax, mirror)` —
  /// there is no `range` argument, whatever other implementations take.
  final int mirror;

  const StabilizeParameters({
    this.enabled = false,
    this.dxmax = 4,
    this.dymax = 4,
    this.mirror = 0,
  });

  StabilizeParameters copyWith({
    bool? enabled,
    int? dxmax,
    int? dymax,
    int? mirror,
  }) =>
      StabilizeParameters(
        enabled: enabled ?? this.enabled,
        dxmax: dxmax ?? this.dxmax,
        dymax: dymax ?? this.dymax,
        mirror: mirror ?? this.mirror,
      );

  /// Short summary for the pass list row.
  String get summary => enabled ? 'Up to ${dxmax}x$dymax px' : 'Off';

  factory StabilizeParameters.fromJson(Map<String, dynamic> json) =>
      _$StabilizeParametersFromJson(json);
  Map<String, dynamic> toJson() => _$StabilizeParametersToJson(this);
}
