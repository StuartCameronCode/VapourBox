/// Pure conversions between a normalized scrubber position (0.0-1.0) and an
/// integer source frame index.
///
/// The scrubber gesture is naturally normalized, but the preview and the
/// step/jump seek controls operate on exact frames. Keeping these conversions
/// pure (and shared) means the rounding behaviour is unit-testable and a
/// position → frame → position round-trip is stable (no drift when stepping).
class FrameMath {
  /// Frame index for a normalized [position], given the [totalFrames] count.
  /// Returns 0 when the video has 0 or 1 frames.
  static int frameForPosition(double position, int totalFrames) {
    if (totalFrames <= 1) return 0;
    return (position.clamp(0.0, 1.0) * (totalFrames - 1)).round();
  }

  /// Normalized position for a [frame] index, given the [totalFrames] count.
  /// Returns 0.0 when the video has 0 or 1 frames.
  static double positionForFrame(int frame, int totalFrames) {
    if (totalFrames <= 1) return 0.0;
    return (frame / (totalFrames - 1)).clamp(0.0, 1.0);
  }
}
