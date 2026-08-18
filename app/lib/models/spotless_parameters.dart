import 'package:json_annotation/json_annotation.dart';

part 'spotless_parameters.g.dart';

/// Which spot remover to run.
enum SpotLessMethod {
  @JsonValue('spotless')
  spotless('SpotLess'),
  @JsonValue('removeDirt')
  removeDirt('RemoveDirt (fast)');

  const SpotLessMethod(this.displayName);
  final String displayName;
}

/// Parameters for the SpotLess pass.
/// Removes dust, dirt, and temporal spots using motion-compensated median.
@JsonSerializable()
class SpotLessParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Which spot remover to run.
  final SpotLessMethod method;

  /// RemoveDirt tuning.
  final int rdGmthreshold;
  final int rdNoise;
  final int rdNoisy;
  final int rdDist;
  final bool rdPostDenoise;

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
    this.method = SpotLessMethod.spotless,
    this.rdGmthreshold = 70,
    this.rdNoise = 50,
    this.rdNoisy = 12,
    this.rdDist = 1,
    this.rdPostDenoise = false,
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
    SpotLessMethod? method,
    int? rdNoise,
    int? rdNoisy,
    int? rdGmthreshold,
    int? rdDist,
    bool? rdPostDenoise,
  }) {
    return SpotLessParameters(
      enabled: enabled ?? this.enabled,
      chroma: chroma ?? this.chroma,
      rec: rec ?? this.rec,
      blksize: blksize ?? this.blksize,
      overlap: overlap ?? this.overlap,
      pel: pel ?? this.pel,
      method: method ?? this.method,
      rdNoise: rdNoise ?? this.rdNoise,
      rdNoisy: rdNoisy ?? this.rdNoisy,
      rdGmthreshold: rdGmthreshold ?? this.rdGmthreshold,
      rdDist: rdDist ?? this.rdDist,
      rdPostDenoise: rdPostDenoise ?? this.rdPostDenoise,
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
