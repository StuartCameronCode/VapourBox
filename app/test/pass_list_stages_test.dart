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
      PassType.antiAlias,
      PassType.sharpen,
      PassType.chromaFixes,
      PassType.colorCorrection,
      PassType.stabilize,
      PassType.geometry,
      PassType.cropResize,
      PassType.grain,
      PassType.subtitles,
    ]);
  });

  group('the placements that carry meaning', () {
    int indexOf(PassType p) => flattened.indexOf(p);

    test('anti-aliasing runs before sharpening', () {
      // Sharpening a stair-stepped edge makes the stepping more visible, not
      // less, so the order is not arbitrary. Mirrored in
      // ProcessingPipeline.enabledPasses and asserted end-to-end in the Rust
      // test_110.
      expect(indexOf(PassType.antiAlias),
          lessThan(indexOf(PassType.sharpen)));
    });

    test('rotation settles before any framing decision', () {
      // A quarter turn swaps width and height, so crop, resize and the aspect
      // declaration must all see the final shape.
      expect(indexOf(PassType.geometry),
          lessThan(indexOf(PassType.cropResize)));
      // And it must follow deinterlacing: fields run horizontally, so turning
      // a still-interlaced clip shears them.
      expect(indexOf(PassType.geometry),
          greaterThan(indexOf(PassType.deinterlace)));
    });

    test('stabilisation runs last before framing', () {
      // It shifts the picture within the frame and exposes thin empty edges, so
      // a crop afterwards can remove them.
      expect(indexOf(PassType.stabilize),
          lessThan(indexOf(PassType.cropResize)));
      expect(indexOf(PassType.stabilize),
          greaterThan(indexOf(PassType.colorCorrection)));
    });
  });

  test('grain is the last video pass', () {
    // Grain added before the resize is resampled away and before the deband is
    // smoothed away, so it has to follow both.
    expect(flattened.indexOf(PassType.grain),
        greaterThan(flattened.indexOf(PassType.cropResize)));
    expect(flattened.indexOf(PassType.grain),
        greaterThan(flattened.indexOf(PassType.deband)));
  });

  test('every stage has a title and at least one pass', () {
    for (final stage in PassListPanel.stages) {
      expect(stage.title.trim(), isNotEmpty);
      expect(stage.passes, isNotEmpty,
          reason: 'an empty stage renders a header over nothing');
    }
  });
}
