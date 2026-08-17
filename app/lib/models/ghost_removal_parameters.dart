import 'package:json_annotation/json_annotation.dart';

part 'ghost_removal_parameters.g.dart';

/// One ghost to cancel. The plugin rejects mode 0 and intensity 0 outright.
@JsonSerializable()
class GhostSpec {
  final int mode;
  final int shift;
  final int intensity;

  const GhostSpec({this.mode = 2, this.shift = 4, this.intensity = 20});

  bool get isUsable =>
      mode >= 1 && mode <= 4 && intensity != 0 && intensity >= -128 && intensity <= 127;

  GhostSpec copyWith({int? mode, int? shift, int? intensity}) => GhostSpec(
        mode: mode ?? this.mode,
        shift: shift ?? this.shift,
        intensity: intensity ?? this.intensity,
      );

  factory GhostSpec.fromJson(Map<String, dynamic> json) =>
      _$GhostSpecFromJson(json);
  Map<String, dynamic> toJson() => _$GhostSpecToJson(this);
}

/// Ghost Removal (LGhost) — cancel the displaced echo RF and cable
/// distribution leave behind.
@JsonSerializable()
class GhostRemovalParameters {
  final bool enabled;
  final List<GhostSpec> ghosts;

  const GhostRemovalParameters({this.enabled = false, this.ghosts = const []});

  List<GhostSpec> get usableGhosts =>
      ghosts.where((g) => g.isUsable).toList(growable: false);

  bool get hasEffect => enabled && usableGhosts.isNotEmpty;

  GhostRemovalParameters copyWith({bool? enabled, List<GhostSpec>? ghosts}) =>
      GhostRemovalParameters(
        enabled: enabled ?? this.enabled,
        ghosts: ghosts ?? this.ghosts,
      );

  String get summary {
    if (!hasEffect) return 'Off';
    final n = usableGhosts.length;
    return n == 1 ? '1 ghost' : '$n ghosts';
  }

  factory GhostRemovalParameters.fromJson(Map<String, dynamic> json) =>
      _$GhostRemovalParametersFromJson(json);
  Map<String, dynamic> toJson() => _$GhostRemovalParametersToJson(this);
}
