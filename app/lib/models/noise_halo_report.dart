/// What `vapourbox-worker --detect-noise-halo` measured in a source: how noisy
/// it is and how strongly its edges ring (`worker/src/noise_halo.rs`, app
/// 1.7.0). Measured in the background when a video is loaded; the pass list
/// uses it only to badge Noise Reduction or Dehalo as recommended
/// ([relevanceFor]). Nothing is ever changed because of it.
///
/// The thresholds are decided by the worker, once: [noiseHigh] and [haloHigh]
/// are its verdicts, and the app never re-derives them from the numbers.
/// Calibration: docs/reports/2026-11-noise-halo-scores/.
library;

class NoiseHaloReport {
  /// Noise sigma in 8-bit levels (motion-compensated frame difference), null
  /// when it could not be measured.
  final double? noise;

  /// Halo score: ringing beside step edges, % of the step. Null with too few
  /// edges to judge.
  final double? halo;

  final int haloEdges;
  final int usablePairs;

  /// Whether each is high enough to recommend its pass.
  final bool noiseHigh;
  final bool haloHigh;

  /// Why the measurement failed; every verdict is false then.
  final String? error;

  const NoiseHaloReport({
    this.noise,
    this.halo,
    this.haloEdges = 0,
    this.usablePairs = 0,
    this.noiseHigh = false,
    this.haloHigh = false,
    this.error,
  });

  const NoiseHaloReport.failed(String this.error)
      : noise = null,
        halo = null,
        haloEdges = 0,
        usablePairs = 0,
        noiseHigh = false,
        haloHigh = false;

  factory NoiseHaloReport.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    if (error != null) return NoiseHaloReport.failed('$error');
    return NoiseHaloReport(
      noise: (json['noise'] as num?)?.toDouble(),
      halo: (json['halo'] as num?)?.toDouble(),
      haloEdges: (json['haloEdges'] as num?)?.toInt() ?? 0,
      usablePairs: (json['usablePairs'] as num?)?.toInt() ?? 0,
      noiseHigh: json['noiseHigh'] == true,
      haloHigh: json['haloHigh'] == true,
    );
  }
}
