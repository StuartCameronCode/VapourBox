/// Which Noise Reduction Strength suits a source's measured noise (issue #177).
///
/// Advisory only, like everything that reads [NoiseHaloReport]: the panel
/// shows a line of text and nothing is ever changed because of it. It speaks
/// only when the worker has already judged the source noisy
/// ([NoiseHaloReport.noiseHigh]): a low score is not evidence (codec-skipped
/// blocks read noiseless), so it says nothing rather than suggest Light.
///
/// The thresholds are noise scores (the worker's sigma, in 8-bit levels)
/// halfway between the noise levels each step was measured best at, on the
/// worker's own reading of those fixtures. They are pinned to
/// docs/reports/issue-177-strength-mapping/data/steps.json (`noiseHint`) by
/// `strength_presets_test.dart`.
library;

import 'filter_schema.dart';
import 'noise_halo_report.dart';

/// The lowest noise score at which each step is suggested, strongest first.
/// Below the first, a noisy source is suggested Medium.
const strengthNoiseThresholds = <(String, double)>[
  ('Very strong', 7.0),
  ('Strong', 4.7),
];

/// The Strength step to suggest for [report], or null to say nothing.
String? suggestedStrength(NoiseHaloReport? report) {
  final noise = report?.noise;
  if (report == null || report.error != null || !report.noiseHigh || noise == null) {
    return null;
  }
  for (final (step, threshold) in strengthNoiseThresholds) {
    if (noise >= threshold) return step;
  }
  return 'Medium';
}

/// The Noise Reduction panel's line about the measured noise, or null.
///
/// [enabled]: the pass is switched on (advice attaches to enabled passes
/// only). [hasStrength]: the selected method offers a Strength control (the
/// simple-mode methods; an advanced-only method has its own controls).
String? noiseStrengthNotice(NoiseHaloReport? report,
    {required bool enabled, required bool hasStrength}) {
  if (!enabled || !hasStrength) return null;
  final step = suggestedStrength(report);
  if (step == null) return null;
  return 'Measured noise in this video: about ${report!.noise!.toStringAsFixed(1)} '
      'levels. Strength "$step" usually suits that much. Check the preview at 1:1, '
      'since a stronger setting also softens fine texture.';
}

/// Whether [schema] offers a Strength selector for [method]: a parameter
/// preset labelled "Strength" whose `visibleWhen` names that method.
bool hasStrengthFor(FilterSchema schema, Object? method) =>
    schema.parameterPresets?.values.any((p) {
      if (p.label != 'Strength') return false;
      final m = p.visibleWhen?['method'];
      return m is List ? m.contains(method) : m == method;
    }) ??
    false;
