import 'package:json_annotation/json_annotation.dart';

part 'geometry_parameters.g.dart';

/// Quarter-turn rotation, clockwise.
///
/// The JsonValues are the wire format to the worker and must match serde's
/// camelCase spelling of the Rust variants exactly.
enum Rotation {
  @JsonValue('none')
  none('None'),
  @JsonValue('cw90')
  cw90('90° clockwise'),
  @JsonValue('rotate180')
  rotate180('180°'),
  @JsonValue('ccw90')
  ccw90('90° anticlockwise');

  const Rotation(this.displayName);
  final String displayName;

  /// Whether this rotation exchanges width and height.
  bool get swapsAxes => this == Rotation.cw90 || this == Rotation.ccw90;
}

/// Parameters for the rotate/flip pass.
///
/// Ordinary geometry the app had no way to do: sideways phone footage, mirrored
/// camcorder captures, film scans that came off the scanner rotated. All of it
/// is `core.std`, so there is no plugin dependency and no bit-depth limit.
///
/// Runs before Crop/Resize, because a quarter turn swaps width and height and
/// every framing decision after it depends on which way round the frame is.
@JsonSerializable()
class GeometryParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Quarter-turn rotation.
  final Rotation rotation;

  /// Mirror left-to-right. Applied after the rotation.
  final bool flipHorizontal;

  /// Mirror top-to-bottom. Applied after the rotation.
  final bool flipVertical;

  const GeometryParameters({
    this.enabled = false,
    this.rotation = Rotation.none,
    this.flipHorizontal = false,
    this.flipVertical = false,
  });

  GeometryParameters copyWith({
    bool? enabled,
    Rotation? rotation,
    bool? flipHorizontal,
    bool? flipVertical,
  }) =>
      GeometryParameters(
        enabled: enabled ?? this.enabled,
        rotation: rotation ?? this.rotation,
        flipHorizontal: flipHorizontal ?? this.flipHorizontal,
        flipVertical: flipVertical ?? this.flipVertical,
      );

  /// Whether the pass would actually change anything. Enabled with nothing
  /// chosen is a no-op, and the pass list should say so rather than claim a
  /// pass is running.
  bool get hasEffect =>
      enabled && (rotation != Rotation.none || flipHorizontal || flipVertical);

  /// Whether this pass exchanges the frame's width and height.
  bool get swapsAxes => enabled && rotation.swapsAxes;

  /// Short summary for the pass list row.
  String get summary {
    if (!enabled) return 'Off';
    final parts = <String>[
      if (rotation != Rotation.none) rotation.displayName,
      if (flipHorizontal) 'flip H',
      if (flipVertical) 'flip V',
    ];
    return parts.isEmpty ? 'No change selected' : parts.join(', ');
  }

  factory GeometryParameters.fromJson(Map<String, dynamic> json) =>
      _$GeometryParametersFromJson(json);
  Map<String, dynamic> toJson() => _$GeometryParametersToJson(this);
}
