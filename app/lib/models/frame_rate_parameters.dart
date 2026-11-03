import 'package:json_annotation/json_annotation.dart';

part 'frame_rate_parameters.g.dart';

/// A target frame rate: a broadcast standard, or [custom] for any rate the
/// user types in (issue #129). The worker turns the rate into the exact
/// fraction it runs at (`custom_fps_fraction`), so only it holds the numbers.
enum FrameRateTarget {
  @JsonValue('pal25')
  pal25('PAL / SECAM (25 fps)'),
  @JsonValue('ntsc2997')
  ntsc2997('NTSC (29.97 fps)'),
  @JsonValue('film23976')
  film23976('Film (23.976 fps)'),
  @JsonValue('film24')
  film24('Film (24 fps)'),
  @JsonValue('pal50')
  pal50('PAL double rate (50 fps)'),
  @JsonValue('ntsc5994')
  ntsc5994('NTSC double rate (59.94 fps)'),
  @JsonValue('custom')
  custom('Custom');

  const FrameRateTarget(this.displayName);
  final String displayName;
}

/// How the new frames are produced.
enum FrameRateMethod {
  @JsonValue('flowFps')
  flowFps('Motion interpolation'),
  @JsonValue('rife')
  rife('AI interpolation (RIFE)'),
  @JsonValue('duplicate')
  duplicate('Repeat frames');

  const FrameRateMethod(this.displayName);
  final String displayName;
}

/// Frame rate conversion (MVTools FlowFPS, RIFE, or frame repetition).
@JsonSerializable()
class FrameRateParameters {
  final bool enabled;
  final FrameRateTarget target;
  final FrameRateMethod method;

  /// The rate for [FrameRateTarget.custom], in frames per second. The worker
  /// clamps it to 1–240 and reads NTSC decimals (59.94) as n×1000/1001.
  final double customFps;

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
    this.customFps = 48.0,
    this.blockSize = 16,
    this.overlap = 8,
    this.sourceFpsNum,
    this.sourceFpsDen,
  });

  FrameRateParameters copyWith({
    bool? enabled,
    FrameRateTarget? target,
    FrameRateMethod? method,
    double? customFps,
    int? blockSize,
    int? overlap,
    int? sourceFpsNum,
    int? sourceFpsDen,
  }) {
    return FrameRateParameters(
      enabled: enabled ?? this.enabled,
      target: target ?? this.target,
      method: method ?? this.method,
      customFps: customFps ?? this.customFps,
      blockSize: blockSize ?? this.blockSize,
      overlap: overlap ?? this.overlap,
      sourceFpsNum: sourceFpsNum ?? this.sourceFpsNum,
      sourceFpsDen: sourceFpsDen ?? this.sourceFpsDen,
    );
  }

  String get summary {
    if (!enabled) return 'Off';
    if (target != FrameRateTarget.custom) return target.displayName;
    // 48.0 reads as "48", 59.94 as "59.94".
    final fps = customFps == customFps.roundToDouble()
        ? customFps.toInt().toString()
        : customFps.toString();
    return 'Custom ($fps fps)';
  }

  factory FrameRateParameters.fromJson(Map<String, dynamic> json) =>
      _$FrameRateParametersFromJson(json);
  Map<String, dynamic> toJson() => _$FrameRateParametersToJson(this);
}
