/// Pure arithmetic for the zoomable preview timeline.
///
/// Positions are normalized (0.0-1.0 across the whole video); the view is the
/// window `[viewStart, viewStart + 1 / zoom]` of that range. Kept pure so the
/// "the point under the cursor stays put" behaviour is unit-testable — a zoom
/// that recentred on the cursor instead made the strip jump on every wheel
/// notch (issue #102).
class TimelineMath {
  static const double minZoom = 1.0;
  static const double maxZoom = 16.0;

  /// Zoom factor applied by one press of the zoom buttons or hotkeys.
  static const double stepFactor = 1.5;

  /// Clamp [zoom] to the supported range, snapping values within rounding of
  /// 1x to exactly 1x so repeated multiply/divide steps land back on "not
  /// zoomed".
  static double clampZoom(double zoom) {
    final clamped = zoom.clamp(minZoom, maxZoom).toDouble();
    return (clamped - minZoom).abs() < 1e-6 ? minZoom : clamped;
  }

  /// The largest valid view start at [zoom].
  static double maxViewStart(double zoom) => 1.0 - 1.0 / zoom;

  /// View start at [zoom] that puts [anchor] (a normalized video position) at
  /// [anchorFraction] of the way across the timeline (0 = left edge,
  /// 1 = right edge), clamped so the view never runs off either end.
  static double viewStartForAnchor({
    required double zoom,
    required double anchor,
    required double anchorFraction,
  }) {
    final width = 1.0 / zoom;
    return (anchor - anchorFraction * width)
        .clamp(0.0, maxViewStart(zoom))
        .toDouble();
  }

  /// Where [position] falls across a view starting at [viewStart] at [zoom]:
  /// 0 at the left edge, 1 at the right, outside that range when off screen.
  static double fractionInView(double position, double viewStart, double zoom) =>
      (position - viewStart) * zoom;

  /// The view start that keeps [position] visible: unchanged if it already
  /// is, otherwise centred on it.
  static double viewStartToReveal(
      double position, double viewStart, double zoom) {
    final fraction = fractionInView(position, viewStart, zoom);
    if (fraction >= 0.0 && fraction <= 1.0) return viewStart;
    return viewStartForAnchor(
        zoom: zoom, anchor: position, anchorFraction: 0.5);
  }
}
