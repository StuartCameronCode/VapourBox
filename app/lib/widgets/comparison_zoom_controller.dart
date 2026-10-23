/// What a [ComparisonZoomController] drives — implemented by the before/after
/// comparison's state.
abstract interface class ComparisonZoomTarget {
  /// Shows the frame at actual pixels: one stored pixel per screen pixel.
  void showActualSize();

  /// Fits the whole frame to the panel.
  void fit();
}

/// Lets the main window's keyboard shortcuts zoom the preview comparison
/// (issue #8), the way a ScrollController lets code outside a scroll view
/// scroll it. Calls do nothing while no comparison is on screen.
class ComparisonZoomController {
  ComparisonZoomTarget? _target;

  void attach(ComparisonZoomTarget target) => _target = target;

  /// Detaches [target], unless another comparison has attached since.
  void detach(ComparisonZoomTarget target) {
    if (identical(_target, target)) _target = null;
  }

  void showActualSize() => _target?.showActualSize();

  void fit() => _target?.fit();
}
