// Tests for the preview timeline's zoom/pan arithmetic (issue #102).
//
// The property that matters is that zooming keeps the anchor — the point
// under the cursor, or the playhead — where it is on screen. The old zoom
// recentred the view on the anchor instead, so every wheel notch jumped the
// strip sideways.
//
// Run with: flutter test test/timeline_math_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/timeline_math.dart';

void main() {
  group('TimelineMath.viewStartForAnchor', () {
    test('keeps the anchor at the same screen fraction', () {
      // Zooms wide enough that a centred anchor never hits the clamp.
      for (final zoom in [2.0, 4.0, 16.0]) {
        for (final fraction in [0.1, 0.25, 0.5, 0.9]) {
          const anchor = 0.5;
          final start = TimelineMath.viewStartForAnchor(
            zoom: zoom,
            anchor: anchor,
            anchorFraction: fraction,
          );
          expect(
            TimelineMath.fractionInView(anchor, start, zoom),
            closeTo(fraction, 1e-9),
            reason: 'zoom $zoom, fraction $fraction',
          );
        }
      }
    });

    test('never runs the view off either end', () {
      for (final anchor in [0.0, 0.01, 0.99, 1.0]) {
        for (final fraction in [0.0, 0.5, 1.0]) {
          final start = TimelineMath.viewStartForAnchor(
            zoom: 4.0,
            anchor: anchor,
            anchorFraction: fraction,
          );
          expect(start, greaterThanOrEqualTo(0.0));
          expect(start, lessThanOrEqualTo(TimelineMath.maxViewStart(4.0)));
        }
      }
    });

    test('at 1x the view is the whole video', () {
      expect(
        TimelineMath.viewStartForAnchor(
            zoom: 1.0, anchor: 0.7, anchorFraction: 0.2),
        0.0,
      );
    });
  });

  group('TimelineMath.clampZoom', () {
    test('clamps to the supported range', () {
      expect(TimelineMath.clampZoom(0.2), TimelineMath.minZoom);
      expect(TimelineMath.clampZoom(100), TimelineMath.maxZoom);
    });

    test('stepping in then out lands back on exactly 1x', () {
      var zoom = 1.0;
      for (var i = 0; i < 5; i++) {
        zoom = TimelineMath.clampZoom(zoom * TimelineMath.stepFactor);
      }
      for (var i = 0; i < 5; i++) {
        zoom = TimelineMath.clampZoom(zoom / TimelineMath.stepFactor);
      }
      expect(zoom, 1.0);
    });
  });

  group('TimelineMath.viewStartToReveal', () {
    test('leaves the view alone when the position is visible', () {
      expect(TimelineMath.viewStartToReveal(0.3, 0.25, 4.0), 0.25);
    });

    test('centres on a position that has left the view', () {
      final start = TimelineMath.viewStartToReveal(0.8, 0.0, 4.0);
      expect(TimelineMath.fractionInView(0.8, start, 4.0), closeTo(0.5, 1e-9));
    });
  });
}
