import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/frame_math.dart';

void main() {
  group('FrameMath', () {
    test('maps endpoints to first and last frame', () {
      expect(FrameMath.frameForPosition(0.0, 1000), 0);
      expect(FrameMath.frameForPosition(1.0, 1000), 999);
    });

    test('rounds to the nearest frame', () {
      // 0.5 of a 1001-frame clip (last index 1000) -> 500
      expect(FrameMath.frameForPosition(0.5, 1001), 500);
    });

    test('clamps out-of-range positions', () {
      expect(FrameMath.frameForPosition(-0.2, 500), 0);
      expect(FrameMath.frameForPosition(1.5, 500), 499);
    });

    test('degenerate clips never divide by zero', () {
      expect(FrameMath.frameForPosition(0.7, 0), 0);
      expect(FrameMath.frameForPosition(0.7, 1), 0);
      expect(FrameMath.positionForFrame(5, 0), 0.0);
      expect(FrameMath.positionForFrame(5, 1), 0.0);
    });

    test('position <-> frame round-trips without drift', () {
      // Stepping frame-by-frame must be stable: frame -> position -> frame == frame.
      const total = 2500;
      for (final frame in [0, 1, 2, 1249, 1250, 2498, 2499]) {
        final pos = FrameMath.positionForFrame(frame, total);
        expect(FrameMath.frameForPosition(pos, total), frame,
            reason: 'round-trip should be stable for frame $frame');
      }
    });
  });
}
