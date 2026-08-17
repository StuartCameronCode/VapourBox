import 'package:json_annotation/json_annotation.dart';

part 'edge_repair_parameters.g.dart';

/// Edge Repair — rebuild the dirty rows and columns at the frame border.
///
/// Widths are always even. The bundled FillBorders is pinned to v2, which is
/// bit-identical to v4 at even widths and differs only at odd ones, where it
/// leaves subsampled chroma unrepaired. Crop already steps by 2 for the same
/// chroma-alignment reason.
@JsonSerializable()
class EdgeRepairParameters {
  final bool enabled;
  final int left;
  final int right;
  final int top;
  final int bottom;
  final String mode;

  const EdgeRepairParameters({
    this.enabled = false,
    this.left = 0,
    this.right = 0,
    this.top = 0,
    this.bottom = 0,
    this.mode = 'fillmargins',
  });

  static int even(int value) => (value.clamp(0, 64) ~/ 2) * 2;

  /// Enabled with every edge zero is not doing anything, and the row should
  /// not claim otherwise.
  bool get hasEffect =>
      enabled && [left, right, top, bottom].any((v) => even(v) > 0);

  EdgeRepairParameters copyWith({
    bool? enabled,
    int? left,
    int? right,
    int? top,
    int? bottom,
    String? mode,
  }) =>
      EdgeRepairParameters(
        enabled: enabled ?? this.enabled,
        left: left ?? this.left,
        right: right ?? this.right,
        top: top ?? this.top,
        bottom: bottom ?? this.bottom,
        mode: mode ?? this.mode,
      );

  String get summary {
    if (!hasEffect) return 'Off';
    return 'L${even(left)} R${even(right)} T${even(top)} B${even(bottom)}';
  }

  factory EdgeRepairParameters.fromJson(Map<String, dynamic> json) =>
      _$EdgeRepairParametersFromJson(json);
  Map<String, dynamic> toJson() => _$EdgeRepairParametersToJson(this);
}
