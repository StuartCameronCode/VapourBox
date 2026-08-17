import 'package:json_annotation/json_annotation.dart';

part 'frame_rate_parameters.g.dart';

/// A target frame rate, named after the standard rather than the number.
///
/// Named targets rather than a free-text number, deliberately: this pass exists
/// for standards conversion, and offering an arbitrary rate invites using it to
/// "smooth" a master, which invents frames that were never photographed.
enum FrameRateTarget {
  @JsonValue('pal25')
  pal25('PAL / SECAM (25 fps)', 25, 1),
  @JsonValue('ntsc2997')
  ntsc2997('NTSC (29.97 fps)', 30000, 1001),
  @JsonValue('film23976')
  film23976('Film (23.976 fps)', 24000, 1001),
  @JsonValue('film24')
  film24('Film (24 fps)', 24, 1),
  @JsonValue('pal50')
  pal50('PAL double rate (50 fps)', 50, 1),
  @JsonValue('ntsc5994')
  ntsc5994('NTSC double rate (59.94 fps)', 60000, 1001);

  const FrameRateTarget(this.displayName, this.num, this.den);
  final String displayName;
  final int num;
  final int den;

  double get fps => num / den;
}

/// How the new frames are produced.
enum FrameRateMethod {
  @JsonValue('flowFps')
  flowFps('Motion interpolation'),
  @JsonValue('duplicate')
  duplicate('Repeat frames');

  const FrameRateMethod(this.displayName);
  final String displayName;
}

/// Frame rate conversion (MVTools FlowFPS).
@JsonSerializable()
class FrameRateParameters {
  final bool enabled;
  final FrameRateTarget target;
  final FrameRateMethod method;

  /// Motion-estimation block size.
  final int blockSize;

  /// Block overlap; the worker clamps it to what mvtools accepts.
  final int overlap;

  /// Source rate, filled in from the detected video info. The worker needs it
  /// to report a correct frame map — without it the progress total and the
  /// preview index would disagree with what the encoder receives.
  final int? sourceFpsNum;
  final int? sourceFpsDen;

  const FrameRateParameters({
    this.enabled = false,
    this.target = FrameRateTarget.pal25,
    this.method = FrameRateMethod.flowFps,
    this.blockSize = 16,
    this.overlap = 8,
    this.sourceFpsNum,
    this.sourceFpsDen,
  });

  FrameRateParameters copyWith({
    bool? enabled,
    FrameRateTarget? target,
    FrameRateMethod? method,
    int? blockSize,
    int? overlap,
    int? sourceFpsNum,
    int? sourceFpsDen,
  }) {
    return FrameRateParameters(
      enabled: enabled ?? this.enabled,
      target: target ?? this.target,
      method: method ?? this.method,
      blockSize: blockSize ?? this.blockSize,
      overlap: overlap ?? this.overlap,
      sourceFpsNum: sourceFpsNum ?? this.sourceFpsNum,
      sourceFpsDen: sourceFpsDen ?? this.sourceFpsDen,
    );
  }

  String get summary => enabled ? target.displayName : 'Off';

  factory FrameRateParameters.fromJson(Map<String, dynamic> json) =>
      _$FrameRateParametersFromJson(json);
  Map<String, dynamic> toJson() => _$FrameRateParametersToJson(this);
}
