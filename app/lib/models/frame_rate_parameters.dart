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

  /// The target in frames per second, as the worker will run it
  /// ([frameRateTargetFps]).
  double get targetFps => frameRateTargetFps(target, customFps);

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

/// The rate [target] stands for, in frames per second; for
/// [FrameRateTarget.custom], [customFps] read as the worker reads it
/// (`custom_fps_fraction`): clamped to 1–240, and an NTSC decimal (23.976,
/// 29.97, 47.952, 59.94) taken as n×1000/1001. Shared by the Frame Rate and
/// Unblend passes, whose custom rates the worker reads the same way.
double frameRateTargetFps(FrameRateTarget target, double customFps) {
  switch (target) {
    case FrameRateTarget.pal25:
      return 25;
    case FrameRateTarget.ntsc2997:
      return 30000 / 1001;
    case FrameRateTarget.film23976:
      return 24000 / 1001;
    case FrameRateTarget.film24:
      return 24;
    case FrameRateTarget.pal50:
      return 50;
    case FrameRateTarget.ntsc5994:
      return 60000 / 1001;
    case FrameRateTarget.custom:
      return customFpsValue(customFps);
  }
}

/// [fps] as the worker's `custom_fps_fraction` makes it exact.
double customFpsValue(double fps) {
  final v = fps.isFinite ? fps.clamp(1.0, 240.0).toDouble() : 48.0;
  final ntsc = v * 1.001;
  if ((v - v.roundToDouble()).abs() > 0.0015 &&
      (ntsc - ntsc.roundToDouble()).abs() < 0.0015) {
    return ntsc.roundToDouble() * 1000 / 1001;
  }
  return (v * 1000).roundToDouble() / 1000;
}

/// How a Frame Rate target compares with the rate the pass receives.
enum FrameRateCloseness {
  /// Nothing to convert (within 0.05%).
  equal,

  /// Within 5%: a real conversion, but motion looks no smoother.
  close,

  /// Anything else.
  far,
}

/// Compares [targetFps] with [inputFps], the rate at the pass
/// ([frameRateInputFps]). The one test behind both the panel's advice and the
/// starting target ([startingFrameRateTarget]), so the two can't disagree.
FrameRateCloseness frameRateCloseness(double targetFps, double inputFps) {
  if (!(inputFps > 0)) return FrameRateCloseness.far;
  final diff = (targetFps - inputFps).abs() / inputFps;
  if (diff < 0.0005) return FrameRateCloseness.equal;
  if (diff <= 0.05) return FrameRateCloseness.close;
  return FrameRateCloseness.far;
}

/// The target to start the Frame Rate pass at when it is switched on with a
/// video selected (task #139): about twice [inputFps], the rate the pass
/// receives — or `null` to leave [current] alone. Only a target equal or
/// close to the input rate is replaced (the pass would do nothing visible),
/// so a deliberate conversion (25 → 29.97, 50 → 25) is kept; and an input of
/// 45 fps or more is left alone, since doubling it is no sensible default.
/// The model's own default stays [FrameRateTarget.pal25].
FrameRateParameters? startingFrameRateTarget(
    FrameRateParameters current, double inputFps) {
  if (!(inputFps > 0) || inputFps >= 45) return null;
  if (frameRateCloseness(current.targetFps, inputFps) ==
      FrameRateCloseness.far) {
    return null;
  }
  bool near(double a, double b, double tolerance) =>
      (a - b).abs() / b < tolerance;
  if (near(inputFps, 25, 0.005)) {
    return current.copyWith(target: FrameRateTarget.pal50);
  }
  if (near(inputFps, 30000 / 1001, 0.0005)) {
    return current.copyWith(target: FrameRateTarget.ntsc5994);
  }
  if (near(inputFps, 24000 / 1001, 0.0005)) {
    // The worker reads 47.952 as 48000/1001 (custom_fps_fraction).
    return current.copyWith(target: FrameRateTarget.custom, customFps: 47.952);
  }
  final doubled = (inputFps * 2 * 1000).roundToDouble() / 1000;
  return current.copyWith(target: FrameRateTarget.custom, customFps: doubled);
}
