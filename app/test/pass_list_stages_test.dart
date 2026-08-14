// The pass list is grouped into stage headers, and the grouping is a pure
// relabelling of an order that must not change: the rows appear in the order the
// passes actually run.
//
// Two silent failures live here. A PassType missing from `stages` simply does
// not render — no error, the pass is just unreachable and its settings
// uneditable. And reordering the rows would tell the user the pipeline runs in
// an order it does not, which is worse than useless when the whole point of the
// panel is to show the pipeline.
//
// Run with: flutter test test/pass_list_stages_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/views/pass_list/pass_list_panel.dart';

void main() {
  final flattened = [
    for (final stage in PassListPanel.stages) ...stage.passes,
  ];

  test('every pass appears in a stage', () {
    expect(flattened.toSet(), PassType.values.toSet(),
        reason: 'a PassType missing from PassListPanel.stages does not render '
            'at all — add it to a stage when adding the pass');
  });

  test('no pass appears twice', () {
    expect(flattened.length, flattened.toSet().length);
    expect(flattened.length, PassType.values.length);
  });

  test('rows stay in pipeline order', () {
    // Deliberately a literal list, not derived from PassType.values — the enum
    // declares colorCorrection before chromaFixes while the pipeline applies
    // them the other way round, so the enum is not the authority here. If this
    // fails, confirm against script_generator.rs before changing it.
    expect(flattened, [
      PassType.deinterlace,
      PassType.descratch,
      PassType.spotless,
      PassType.noiseReduction,
      PassType.chromaDenoise,
      PassType.dehalo,
      PassType.deblock,
      PassType.deband,
      PassType.sharpen,
      PassType.chromaFixes,
      PassType.colorCorrection,
      PassType.cropResize,
      PassType.subtitles,
    ]);
  });

  test('every stage has a title and at least one pass', () {
    for (final stage in PassListPanel.stages) {
      expect(stage.title.trim(), isNotEmpty);
      expect(stage.passes, isNotEmpty,
          reason: 'an empty stage renders a header over nothing');
    }
  });
}
