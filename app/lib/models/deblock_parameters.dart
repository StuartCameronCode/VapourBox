import 'package:json_annotation/json_annotation.dart';

part 'deblock_parameters.g.dart';

/// Deblocking method options.
@JsonEnum(valueField: 'value')
enum DeblockMethod {
  @JsonValue('Deblock_QED')
  deblockQed('Deblock_QED', 'Deblock QED'),
  @JsonValue('Deblock')
  deblock('Deblock', 'Deblock'),
  @JsonValue('DCTFilter')
  dctFilter('DCTFilter', 'DCTFilter');

  const DeblockMethod(this.value, this.displayName);
  final String value;
  final String displayName;

  String get description {
    switch (this) {
      case DeblockMethod.deblockQed:
        return 'Quality Enhanced Deblocking - good for DVDs';
      case DeblockMethod.deblock:
        return 'Simple deblocking filter';
      case DeblockMethod.dctFilter:
        return 'Attenuates high DCT frequency bands — targets ringing and '
            'mosquito noise rather than block edges';
    }
  }
}

/// Parameters for the deblocking pass.
/// Removes block artifacts from compressed video.
@JsonSerializable()
class DeblockParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Deblocking method to use.
  final DeblockMethod method;

  // --- Deblock_QED parameters ---

  /// Quant1: Strength for edges (0-60, default 24).
  final int quant1;

  /// Quant2: Strength for non-edges (0-60, default 26).
  final int quant2;

  /// Analyze planes (0=auto, 1=Y only, 2=UV only, 3=all).
  final int aOffset1;

  /// Analyze planes offset 2.
  final int aOffset2;

  // --- DCTFilter parameters ---

  /// Lowest frequency band left untouched (0-7). Everything above is attenuated.
  final int dctCutoff;

  /// How hard the bands above the cutoff are attenuated (0.0-1.0).
  final double dctStrength;

  /// Planes to filter: 0 luma only, 1 chroma only, 2 both.
  final int dctPlanes;

  const DeblockParameters({
    this.enabled = false,
    this.method = DeblockMethod.deblockQed,
    this.quant1 = 24,
    this.quant2 = 26,
    this.aOffset1 = 1,
    this.aOffset2 = 1,
    this.dctCutoff = 5,
    this.dctStrength = 0.6,
    this.dctPlanes = 0,
  });

  DeblockParameters copyWith({
    bool? enabled,
    DeblockMethod? method,
    int? quant1,
    int? quant2,
    int? aOffset1,
    int? aOffset2,
    int? dctCutoff,
    double? dctStrength,
    int? dctPlanes,
  }) {
    return DeblockParameters(
      enabled: enabled ?? this.enabled,
      method: method ?? this.method,
      quant1: quant1 ?? this.quant1,
      quant2: quant2 ?? this.quant2,
      aOffset1: aOffset1 ?? this.aOffset1,
      aOffset2: aOffset2 ?? this.aOffset2,
      dctCutoff: dctCutoff ?? this.dctCutoff,
      dctStrength: dctStrength ?? this.dctStrength,
      dctPlanes: dctPlanes ?? this.dctPlanes,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    if (method == DeblockMethod.deblockQed) {
      return 'QED ($quant1/$quant2)';
    } else {
      return 'Deblock ($quant1)';
    }
  }

  factory DeblockParameters.fromJson(Map<String, dynamic> json) =>
      _$DeblockParametersFromJson(json);
  Map<String, dynamic> toJson() => _$DeblockParametersToJson(this);
}
