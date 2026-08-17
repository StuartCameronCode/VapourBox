import 'package:json_annotation/json_annotation.dart';

part 'anti_alias_parameters.g.dart';

/// Anti-aliasing method options.
///
/// The JsonValues are the wire format to the worker and must match serde's
/// camelCase spelling of the Rust variants exactly; a mismatch falls back to the
/// default rather than erroring.
enum AntiAliasMethod {
  @JsonValue('daa')
  daa('daa', 'daa'),
  @JsonValue('santiag')
  santiag('santiag', 'santiag');

  const AntiAliasMethod(this.value, this.displayName);
  final String value;
  final String displayName;
}

/// Parameters for the anti-aliasing pass.
///
/// Removes stair-stepping on diagonal edges, which deinterlacing and upscaling
/// both create. Runs before sharpening, because sharpening stair-stepped edges
/// makes the stepping more visible rather than less.
@JsonSerializable()
class AntiAliasParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Which method to use.
  final AntiAliasMethod method;

  /// Vertical strength for santiag (0 disables the vertical pass).
  final int santiagStrv;

  /// Horizontal strength for santiag (0 disables the horizontal pass).
  final int santiagStrh;

  /// Interpolator for santiag. Only `nnedi3` is bundled, so the worker pins it
  /// there regardless — havsfunc's other options would fail at script
  /// evaluation.
  final String santiagType;

  const AntiAliasParameters({
    this.enabled = false,
    this.method = AntiAliasMethod.daa,
    this.santiagStrv = 1,
    this.santiagStrh = 1,
    this.santiagType = 'nnedi3',
  });

  AntiAliasParameters copyWith({
    bool? enabled,
    AntiAliasMethod? method,
    int? santiagStrv,
    int? santiagStrh,
    String? santiagType,
  }) =>
      AntiAliasParameters(
        enabled: enabled ?? this.enabled,
        method: method ?? this.method,
        santiagStrv: santiagStrv ?? this.santiagStrv,
        santiagStrh: santiagStrh ?? this.santiagStrh,
        santiagType: santiagType ?? this.santiagType,
      );

  /// Short summary for the pass list row.
  String get summary {
    if (!enabled) return 'Off';
    if (method == AntiAliasMethod.santiag) {
      return 'santiag (H$santiagStrh / V$santiagStrv)';
    }
    return method.displayName;
  }

  factory AntiAliasParameters.fromJson(Map<String, dynamic> json) =>
      _$AntiAliasParametersFromJson(json);
  Map<String, dynamic> toJson() => _$AntiAliasParametersToJson(this);
}
