import 'package:json_annotation/json_annotation.dart';

part 'spotless_parameters.g.dart';

/// Parameters for the SpotLess pass.
/// Removes dust, dirt, and temporal spots using motion-compensated median.
@JsonSerializable()
class SpotLessParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Process chroma planes (default true).
  final bool chroma;

  /// Recalculate motion vectors for more precision (default false).
  final bool rec;

  /// Block size for motion analysis (default 16).
  final int blksize;

  /// Block overlap (default 8).
  final int overlap;

  /// Sub-pixel accuracy: 1=pixel, 2=half, 4=quarter (default 2).
  final int pel;

  const SpotLessParameters({
    this.enabled = false,
    this.chroma = true,
    this.rec = false,
    this.blksize = 16,
    this.overlap = 8,
    this.pel = 2,
  });

  SpotLessParameters copyWith({
    bool? enabled,
    bool? chroma,
    bool? rec,
    int? blksize,
    int? overlap,
    int? pel,
  }) {
    return SpotLessParameters(
      enabled: enabled ?? this.enabled,
      chroma: chroma ?? this.chroma,
      rec: rec ?? this.rec,
      blksize: blksize ?? this.blksize,
      overlap: overlap ?? this.overlap,
      pel: pel ?? this.pel,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    final parts = <String>[];
    if (rec) parts.add('Refined');
    if (!chroma) parts.add('Luma only');
    return parts.isEmpty ? 'SpotLess' : 'SpotLess (${parts.join(", ")})';
  }

  factory SpotLessParameters.fromJson(Map<String, dynamic> json) =>
      _$SpotLessParametersFromJson(json);
  Map<String, dynamic> toJson() => _$SpotLessParametersToJson(this);
}
