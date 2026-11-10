import 'package:json_annotation/json_annotation.dart';

part 'stabilize_parameters.g.dart';

/// How the per-frame vertical pitch factor is obtained (issue #150).
@JsonEnum(valueField: 'value')
enum PitchMode {
  off('off', 'Off'),
  auto('auto', 'Auto'),
  file('file', 'From File');

  const PitchMode(this.value, this.displayName);
  final String value;
  final String displayName;

  static PitchMode fromValue(String? value) =>
      PitchMode.values.firstWhere((m) => m.value == value, orElse: () => PitchMode.off);
}

/// What fills the rows a pitch correction moves in from outside the frame.
/// (The weave correction's edges are [StabilizeParameters.mirror]'s business.)
@JsonEnum(valueField: 'value')
enum EdgeFill {
  extend('extend'),
  black('black');

  const EdgeFill(this.value);
  final String value;

  static EdgeFill fromValue(String? value) =>
      EdgeFill.values.firstWhere((m) => m.value == value, orElse: () => EdgeFill.extend);
}

/// Parameters for the stabilisation pass.
///
/// Two independent corrections. **Weave** cancels global shake — telecine
/// weave, jittery film scans, handheld camcorder footage — while leaving
/// deliberate camera movement alone. **Pitch** (issue #150) evens out
/// frame-height "breathing" from film slipping in a pull-through scanner's
/// gate. The pass shifts and resamples the picture within the frame, so it
/// runs last before framing: a crop can then remove the edges it exposes.
///
/// The frame count is unchanged, which is what keeps this an ordinary pass
/// rather than one of the frame-rate-changing filters.
///
/// The pitch factor *file* is not here: it belongs to one video, while a
/// pipeline is saved into presets shared by every video in the queue. It
/// travels on the job instead (`VideoJob.pitchFactorsPath`).
@JsonSerializable()
class StabilizeParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Remove weave / shake. On by default, so a pipeline saved before this
  /// switch existed keeps doing what it did.
  final bool weave;

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

  /// Pitch correction source. Off by default.
  @JsonKey(unknownEnumValue: PitchMode.off)
  final PitchMode pitchMode;

  /// Largest pitch correction, in percent of the frame height.
  final double maxPitchDeviation;

  /// Auto pitch: frames each side a frame is compared with.
  final int smoothingRadius;

  /// File pitch: the file lists the stretch to apply, not the measured height.
  final bool invertFactors;

  /// What fills rows exposed by the pitch correction.
  @JsonKey(unknownEnumValue: EdgeFill.extend)
  final EdgeFill pitchEdgeFill;

  const StabilizeParameters({
    this.enabled = false,
    this.weave = true,
    this.dxmax = 4,
    this.dymax = 4,
    this.mirror = 0,
    this.pitchMode = PitchMode.off,
    this.maxPitchDeviation = 1.0,
    this.smoothingRadius = 10,
    this.invertFactors = false,
    this.pitchEdgeFill = EdgeFill.extend,
  });

  StabilizeParameters copyWith({
    bool? enabled,
    bool? weave,
    int? dxmax,
    int? dymax,
    int? mirror,
    PitchMode? pitchMode,
    double? maxPitchDeviation,
    int? smoothingRadius,
    bool? invertFactors,
    EdgeFill? pitchEdgeFill,
  }) =>
      StabilizeParameters(
        enabled: enabled ?? this.enabled,
        weave: weave ?? this.weave,
        dxmax: dxmax ?? this.dxmax,
        dymax: dymax ?? this.dymax,
        mirror: mirror ?? this.mirror,
        pitchMode: pitchMode ?? this.pitchMode,
        maxPitchDeviation: maxPitchDeviation ?? this.maxPitchDeviation,
        smoothingRadius: smoothingRadius ?? this.smoothingRadius,
        invertFactors: invertFactors ?? this.invertFactors,
        pitchEdgeFill: pitchEdgeFill ?? this.pitchEdgeFill,
      );

  /// Whether pitch correction reads a per-video factor file.
  bool get usesFactorFile => enabled && pitchMode == PitchMode.file;

  /// Short summary for the pass list row.
  String get summary {
    if (!enabled) return 'Off';
    final parts = <String>[
      if (weave) 'Up to ${dxmax}x$dymax px',
      if (pitchMode == PitchMode.auto) 'pitch auto',
      if (pitchMode == PitchMode.file) 'pitch from file',
    ];
    return parts.isEmpty ? 'Nothing selected' : parts.join(', ');
  }

  factory StabilizeParameters.fromJson(Map<String, dynamic> json) =>
      _$StabilizeParametersFromJson(json);
  Map<String, dynamic> toJson() => _$StabilizeParametersToJson(this);
}
