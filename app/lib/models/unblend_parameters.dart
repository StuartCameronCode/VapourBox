import 'package:json_annotation/json_annotation.dart';

import 'frame_rate_parameters.dart';
import 'qtgmc_parameters.dart';

part 'unblend_parameters.g.dart';

/// Unblend (SRestore): recover the original frames of a frame-rate
/// conversion done by blending — a film shown on PAL through a standards
/// converter, or a PAL programme converted to NTSC. Runs right after
/// Deinterlace (docs/reports/2026-11-srestore).
///
/// Its target is the rate the footage was made at, and the worker refuses one
/// it cannot reach (anything not below the rate at the pass); the panel says
/// so with the same wording ([unblendTargetProblem]).
@JsonSerializable()
class UnblendParameters {
  final bool enabled;

  /// The rate the original frames ran at.
  final FrameRateTarget target;

  /// The rate for [FrameRateTarget.custom]; made exact by the worker, as for
  /// the Frame Rate pass.
  final double customFps;

  const UnblendParameters({
    this.enabled = false,
    this.target = FrameRateTarget.film23976,
    this.customFps = 24.0,
  });

  UnblendParameters copyWith({
    bool? enabled,
    FrameRateTarget? target,
    double? customFps,
  }) {
    return UnblendParameters(
      enabled: enabled ?? this.enabled,
      target: target ?? this.target,
      customFps: customFps ?? this.customFps,
    );
  }

  /// The target in frames per second, as the worker reads it
  /// ([frameRateTargetFps]).
  double get targetFps => frameRateTargetFps(target, customFps);

  String get summary {
    if (!enabled) return 'Off';
    if (target != FrameRateTarget.custom) return 'To ${target.displayName}';
    final fps = customFps == customFps.roundToDouble()
        ? customFps.toInt().toString()
        : customFps.toString();
    return 'To $fps fps';
  }

  factory UnblendParameters.fromJson(Map<String, dynamic> json) =>
      _$UnblendParametersFromJson(json);
  Map<String, dynamic> toJson() => _$UnblendParametersToJson(this);
}

/// The rate the Unblend pass converts from: the source's, as changed by the
/// Deinterlace pass ahead of it. Mirrors the worker's `FrameMap`s for that
/// pass (`deinterlace_frame_map`): double rate doubles it, IVTC keeps
/// cycle-1 of every cycle. Soft Telecine decimates only a source decoded at a
/// pulldown rate ([softTelecineDecimates], `VideoInfo.softTelecineDecimates`);
/// at the film rate it keeps every frame, as the worker's map does.
double unblendInputFps(QTGMCParameters deinterlace, double sourceFps,
    {bool softTelecineDecimates = true}) {
  if (!deinterlace.enabled) return sourceFps;
  switch (deinterlace.method) {
    case DeinterlaceMethod.qtgmc:
    case DeinterlaceMethod.bwdif:
      return (deinterlace.fpsDivisor ?? 1) == 1 ? sourceFps * 2 : sourceFps;
    case DeinterlaceMethod.softTelecine:
      if (!softTelecineDecimates) return sourceFps;
      return sourceFps * 4 / 5;
    case DeinterlaceMethod.ivtc:
      final cycle = (deinterlace.ivtcCycle ?? 5).clamp(2, 1000);
      return sourceFps * (cycle - 1) / cycle;
  }
}

/// The rate the Frame Rate pass receives: the source's, as changed by
/// Deinterlace ([unblendInputFps]) and then Unblend, the only passes ahead of
/// it that change the rate. Mirrors the worker's
/// `rate_before(PassType::FrameRate)`.
double frameRateInputFps(
    QTGMCParameters deinterlace, UnblendParameters unblend, double sourceFps,
    {bool softTelecineDecimates = true}) {
  final afterDeinterlace = unblendInputFps(deinterlace, sourceFps,
      softTelecineDecimates: softTelecineDecimates);
  return unblend.enabled ? unblend.targetFps : afterDeinterlace;
}

/// Why Unblend can't recover [targetFps] from a pass running at [inputFps],
/// or `null` when it plausibly can. The worker makes the exact decision (it
/// also refuses a few ratios srestore would only approximate) and refuses the
/// job with the same opening words; this is the panel's early warning.
String? unblendTargetProblem(double targetFps, double inputFps) {
  if (inputFps <= 0) return null;
  if (targetFps < inputFps - 1e-6 && targetFps * 5 >= inputFps) return null;
  String fmt(double v) {
    final s = v.toStringAsFixed(3);
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  return "Unblend can't recover ${fmt(targetFps)} fps from ${fmt(inputFps)} fps. "
      'It can only lower the frame rate (to at least a fifth of it), and only '
      'to rates it can reach exactly. Pick the rate the footage was made at: '
      '23.976, 24 or 25 fps for film or PAL programmes, 29.97 for NTSC.';
}
