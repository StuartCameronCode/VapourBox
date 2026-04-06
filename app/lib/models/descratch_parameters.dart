import 'package:json_annotation/json_annotation.dart';

part 'descratch_parameters.g.dart';

/// Parameters for the DeScratch pass.
/// Removes vertical scratches from scanned film.
@JsonSerializable()
class DeScratchParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Minimum luma difference to detect a scratch (1-255).
  final int mindif;

  /// Maximum asymmetry of neighbor pixels (0-255).
  final int asym;

  /// Maximum vertical gap to close (0-255).
  final int maxgap;

  /// Maximum scratch width in pixels (1-15, odd).
  final int maxwidth;

  /// Minimum scratch width in pixels (1-15, odd).
  final int minwidth;

  /// Minimum scratch length in pixels.
  final int minlen;

  /// Maximum scratch length in pixels.
  final int maxlen;

  /// Maximum angle from vertical in degrees (0-90).
  final int maxangle;

  /// Vertical blur radius for analysis (1-200).
  final int blurlen;

  /// Percent of scratch detail to keep (0-100).
  final int keep;

  /// Border thickness for smooth transition (0-15).
  final int border;

  /// Luma mode: 0=off, 1=dark, 2=bright, 3=both.
  final int modeY;

  /// Chroma U mode: 0=off, 1=dark, 2=bright, 3=both.
  final int modeU;

  /// Chroma V mode: 0=off, 1=dark, 2=bright, 3=both.
  final int modeV;

  /// Minimum chroma difference (0 = use mindif value).
  final int mindifUV;

  const DeScratchParameters({
    this.enabled = false,
    this.mindif = 5,
    this.asym = 10,
    this.maxgap = 3,
    this.maxwidth = 3,
    this.minwidth = 1,
    this.minlen = 100,
    this.maxlen = 2048,
    this.maxangle = 5,
    this.blurlen = 15,
    this.keep = 100,
    this.border = 2,
    this.modeY = 1,
    this.modeU = 0,
    this.modeV = 0,
    this.mindifUV = 0,
  });

  DeScratchParameters copyWith({
    bool? enabled,
    int? mindif,
    int? asym,
    int? maxgap,
    int? maxwidth,
    int? minwidth,
    int? minlen,
    int? maxlen,
    int? maxangle,
    int? blurlen,
    int? keep,
    int? border,
    int? modeY,
    int? modeU,
    int? modeV,
    int? mindifUV,
  }) {
    return DeScratchParameters(
      enabled: enabled ?? this.enabled,
      mindif: mindif ?? this.mindif,
      asym: asym ?? this.asym,
      maxgap: maxgap ?? this.maxgap,
      maxwidth: maxwidth ?? this.maxwidth,
      minwidth: minwidth ?? this.minwidth,
      minlen: minlen ?? this.minlen,
      maxlen: maxlen ?? this.maxlen,
      maxangle: maxangle ?? this.maxangle,
      blurlen: blurlen ?? this.blurlen,
      keep: keep ?? this.keep,
      border: border ?? this.border,
      modeY: modeY ?? this.modeY,
      modeU: modeU ?? this.modeU,
      modeV: modeV ?? this.modeV,
      mindifUV: mindifUV ?? this.mindifUV,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    final modes = <String>[];
    if (modeY == 1) modes.add('Dark');
    if (modeY == 2) modes.add('Bright');
    if (modeY == 3) modes.add('Both');
    return 'DeScratch (${modes.isEmpty ? "Off" : modes.join("+")})';
  }

  factory DeScratchParameters.fromJson(Map<String, dynamic> json) =>
      _$DeScratchParametersFromJson(json);
  Map<String, dynamic> toJson() => _$DeScratchParametersToJson(this);
}
