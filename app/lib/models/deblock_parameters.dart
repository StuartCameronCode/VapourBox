import 'package:json_annotation/json_annotation.dart';

part 'deblock_parameters.g.dart';

/// Deblocking method options.
@JsonEnum(valueField: 'value')
enum DeblockMethod {
  @JsonValue('Deblock_QED')
  deblockQed('Deblock_QED', 'Deblock QED'),
  @JsonValue('Deblock')
  deblock('Deblock', 'Deblock');

  const DeblockMethod(this.value, this.displayName);
  final String value;
  final String displayName;

  String get description {
    switch (this) {
      case DeblockMethod.deblockQed:
        return 'Quality Enhanced Deblocking - good for DVDs';
      case DeblockMethod.deblock:
        return 'Simple deblocking filter';
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

  // --- Deblock parameters ---

  /// Block size (4 or 8).
  final int blockSize;

  /// Overlap amount (0-half of blockSize).
  final int overlap;

  const DeblockParameters({
    this.enabled = false,
    this.method = DeblockMethod.deblockQed,
    this.quant1 = 24,
    this.quant2 = 26,
    this.aOffset1 = 1,
    this.aOffset2 = 1,
    this.blockSize = 8,
    this.overlap = 4,
  });

  DeblockParameters copyWith({
    bool? enabled,
    DeblockMethod? method,
    int? quant1,
    int? quant2,
    int? aOffset1,
    int? aOffset2,
    int? blockSize,
    int? overlap,
  }) {
    return DeblockParameters(
      enabled: enabled ?? this.enabled,
      method: method ?? this.method,
      quant1: quant1 ?? this.quant1,
      quant2: quant2 ?? this.quant2,
      aOffset1: aOffset1 ?? this.aOffset1,
      aOffset2: aOffset2 ?? this.aOffset2,
      blockSize: blockSize ?? this.blockSize,
      overlap: overlap ?? this.overlap,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    if (method == DeblockMethod.deblockQed) {
      return 'QED ($quant1/$quant2)';
    } else {
      return 'Deblock (${blockSize}x$blockSize)';
    }
  }

  factory DeblockParameters.fromJson(Map<String, dynamic> json) =>
      _$DeblockParametersFromJson(json);
  Map<String, dynamic> toJson() => _$DeblockParametersToJson(this);
}
