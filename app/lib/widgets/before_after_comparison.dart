import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_shortcut.dart';
import '../services/image_dimensions.dart';
import 'comparison_zoom_controller.dart';

/// A widget that displays a before/after comparison with a draggable divider.
///
/// The before image is shown on the left of the divider, and the after image
/// is shown on the right. The divider can be dragged to compare different
/// portions of the images.
///
/// Supports pinch-to-zoom, scroll wheel zoom, pan when zoomed, and
/// double-tap to reset. The Fit / 1:1 controls in the bottom-left corner
/// switch between fitting the frame to the panel and showing it at actual
/// pixels — one stored pixel per physical screen pixel (issue #8).
class BeforeAfterComparisonWidget extends StatefulWidget {
  /// The "before" image data (shown on the left).
  final Uint8List? beforeImage;

  /// The "after" image data (shown on the right).
  final Uint8List? afterImage;

  /// Initial divider position (0.0 to 1.0, default 0.5).
  final double initialDividerPosition;

  /// Whether the before image is loading.
  final bool isBeforeLoading;

  /// Whether the after image is loading.
  final bool isAfterLoading;

  /// Display aspect ratio for SAR correction (e.g. 16/9 for anamorphic DVD).
  /// When null, the image's native pixel aspect ratio is used (square pixels).
  final double? displayAspectRatio;

  /// Lets keyboard shortcuts drive Fit / 1:1 from outside the widget.
  final ComparisonZoomController? zoomController;

  const BeforeAfterComparisonWidget({
    super.key,
    this.beforeImage,
    this.afterImage,
    this.initialDividerPosition = 0.5,
    this.isBeforeLoading = false,
    this.isAfterLoading = false,
    this.displayAspectRatio,
    this.zoomController,
  });

  @override
  State<BeforeAfterComparisonWidget> createState() =>
      _BeforeAfterComparisonWidgetState();
}

class _BeforeAfterComparisonWidgetState
    extends State<BeforeAfterComparisonWidget>
    with SingleTickerProviderStateMixin
    implements ComparisonZoomTarget {
  late double _dividerPosition;

  // Zoom and pan state
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  // Animation for smooth reset
  late final AnimationController _resetController;
  Animation<double>? _scaleAnimation;
  Animation<Offset>? _offsetAnimation;

  // Trackpad pan-zoom gesture tracking
  double _panZoomStartScale = 1.0;
  bool _isPanZooming = false;

  // Middle-click drag panning
  bool _isMiddleDragging = false;

  static const double _minScale = 1.0;
  static const double _maxScale = 10.0;

  // Actual-pixels (1:1) mode. While it is on, the scale is recomputed from
  // the layout on every build, so resizing the panel or the frame changing
  // size keeps it at 1:1 rather than at whatever scale that used to be.
  bool _actualSize = false;

  /// The scale (relative to fit) that shows the frame at 1:1 in the current
  /// layout, or null with no decodable frame.
  double? _actualSizeTarget;

  Size _viewport = Size.zero;

  /// Fractional physical-pixel position of the viewport's origin, so the
  /// frame can be put on the screen's pixel grid at 1:1.
  Offset _originPhase = Offset.zero;
  final GlobalKey _viewportKey = GlobalKey();

  Uint8List? _sizedBytes;
  Size? _sizedResult;

  @override
  void initState() {
    super.initState();
    widget.zoomController?.attach(this);
    _dividerPosition = widget.initialDividerPosition;
    _resetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        setState(() {
          if (_scaleAnimation != null) _scale = _scaleAnimation!.value;
          if (_offsetAnimation != null) _offset = _offsetAnimation!.value;
        });
      });
  }

  @override
  void didUpdateWidget(BeforeAfterComparisonWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoomController != widget.zoomController) {
      oldWidget.zoomController?.detach(this);
      widget.zoomController?.attach(this);
    }
  }

  @override
  void dispose() {
    widget.zoomController?.detach(this);
    _resetController.dispose();
    super.dispose();
  }

  void _animateTo(double scale, Offset offset) {
    _scaleAnimation = Tween<double>(begin: _scale, end: scale)
        .animate(CurvedAnimation(parent: _resetController, curve: Curves.easeOut));
    _offsetAnimation = Tween<Offset>(begin: _offset, end: offset)
        .animate(CurvedAnimation(parent: _resetController, curve: Curves.easeOut));
    _resetController.forward(from: 0);
  }

  bool get _isAtFit => !_actualSize && _scale == 1.0 && _offset == Offset.zero;

  void _resetZoom() {
    if (_isAtFit) return;
    setState(() => _actualSize = false);
    _animateTo(1.0, Offset.zero);
  }

  @override
  void fit() => _resetZoom();

  /// Zooms to 1:1 about the centre of the panel, so whatever is in the middle
  /// of the view stays there.
  @override
  void showActualSize() {
    final target = _actualSizeTarget;
    if (target == null || _actualSize) return;
    setState(() => _actualSize = true);
    _animateTo(
      target,
      _clampOffset(_offset * (target / _scale), _viewport, target),
    );
  }

  /// Pixel size of the frame the 1:1 scale is measured against: the
  /// processed frame, which is what is being inspected, else the source.
  Size? get _imagePixels {
    final bytes = widget.afterImage ?? widget.beforeImage;
    if (!identical(bytes, _sizedBytes)) {
      _sizedBytes = bytes;
      _sizedResult = bytes == null ? null : encodedImageSize(bytes);
    }
    return _sizedResult;
  }

  /// The frame's size on screen at scale 1 — fitted into [box], with the
  /// display aspect ratio applied — in logical pixels.
  Size? _fittedSize(Size box) {
    final pixels = _imagePixels;
    if (pixels == null || box.isEmpty) return null;
    final aspect = widget.displayAspectRatio ?? pixels.width / pixels.height;
    final width = math.min(box.width, box.height * aspect);
    return Size(width, width / aspect);
  }

  /// The scale at which each stored row of the frame covers exactly one
  /// physical row of the screen. Measured on height so an anamorphic frame
  /// keeps its lines exact; its columns are stretched by the pixel aspect
  /// ratio, as they are at any zoom. For square pixels it is 1:1 both ways.
  double? _actualSizeScale(Size box, double devicePixelRatio) {
    final pixels = _imagePixels;
    final fitted = _fittedSize(box);
    if (pixels == null || fitted == null) return null;
    return pixels.height / devicePixelRatio / fitted.height;
  }

  double get _lowerScale =>
      math.min(_minScale, _actualSizeTarget ?? _minScale);
  double get _upperScale =>
      math.max(_maxScale, _actualSizeTarget ?? _maxScale);

  /// At 1:1 each frame pixel must land on exactly one screen pixel, so the
  /// frame's top-left corner is moved onto the physical pixel grid. Off it,
  /// nearest-neighbour sampling repeats or drops a row or column at
  /// intervals, which is exactly the detail 1:1 exists to show.
  Offset _snapToPixelGrid(Size box, double devicePixelRatio) {
    final fitted = _fittedSize(box);
    if (fitted == null) return _offset;
    final left = box.width / 2 + _offset.dx - fitted.width * _scale / 2;
    final top = box.height / 2 + _offset.dy - fitted.height * _scale / 2;
    double nudge(double local, double phase) {
      final physical = local * devicePixelRatio + phase;
      return (physical.roundToDouble() - physical) / devicePixelRatio;
    }

    return _offset +
        Offset(nudge(left, _originPhase.dx), nudge(top, _originPhase.dy));
  }

  /// Measures where the viewport sits on the physical pixel grid once laid
  /// out, rebuilding if that changed — which takes one frame to settle.
  void _trackOriginPhase(double devicePixelRatio) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _viewportKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final origin = box.localToGlobal(Offset.zero) * devicePixelRatio;
      final phase = Offset(
        origin.dx - origin.dx.floorToDouble(),
        origin.dy - origin.dy.floorToDouble(),
      );
      if ((phase - _originPhase).distance > 1e-3) {
        setState(() => _originPhase = phase);
      }
    });
  }

  /// Clamp offset so the image doesn't scroll beyond its edges.
  Offset _clampOffset(Offset offset, Size size, [double? scale]) {
    final s = scale ?? _scale;
    if (s <= 1.0) return Offset.zero;
    // With Transform(alignment: center), the image expands equally in all
    // directions. The maximum pan in each axis is half the overflow.
    final double maxDx = (size.width * (s - 1)) / 2;
    final double maxDy = (size.height * (s - 1)) / 2;
    return Offset(
      offset.dx.clamp(-maxDx, maxDx),
      offset.dy.clamp(-maxDy, maxDy),
    );
  }

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is PointerScaleEvent) {
      // Trackpad pinch-to-zoom (native trackpad)
      _zoomAtPoint(event.localPosition, event.scale, size);
    } else if (event is PointerScrollEvent) {
      final bool ctrlHeld =
          HardwareKeyboard.instance.logicalKeysPressed.contains(
                LogicalKeyboardKey.controlLeft) ||
          HardwareKeyboard.instance.logicalKeysPressed.contains(
                LogicalKeyboardKey.controlRight);

      if (ctrlHeld) {
        // Ctrl+scroll = zoom (Mac trackpad pinch via RDP sends this)
        final double zoomFactor = event.scrollDelta.dy < 0 ? 1.1 : 0.9;
        _zoomAtPoint(event.localPosition, zoomFactor, size);
      } else if (_scale > 1.0) {
        // When zoomed in, scroll events pan the image
        setState(() {
          _offset = _clampOffset(
            _offset - Offset(event.scrollDelta.dx, event.scrollDelta.dy),
            size,
          );
        });
      } else {
        // At 1x, scroll wheel zooms (scroll up = zoom in)
        final double zoomFactor = event.scrollDelta.dy < 0 ? 1.1 : 0.9;
        _zoomAtPoint(event.localPosition, zoomFactor, size);
      }
    }
  }

  void _zoomAtPoint(Offset focalPoint, double scaleFactor, Size size) {
    setState(() {
      final double oldScale = _scale;
      _scale = (_scale * scaleFactor).clamp(_lowerScale, _upperScale);
      if (_scale == oldScale) return;
      _actualSize = false;

      // Adjust offset so the focal point stays visually fixed.
      // The center of the widget is the Transform alignment point.
      final Offset center = Offset(size.width / 2, size.height / 2);
      _offset = _offset + (center - focalPoint) * (_scale - oldScale);
      _offset = _clampOffset(_offset, size);
    });
  }

  void _handlePanZoomStart(PointerPanZoomStartEvent event) {
    _panZoomStartScale = _scale;
    _isPanZooming = true;
  }

  void _handlePanZoomUpdate(PointerPanZoomUpdateEvent event, Size size) {
    setState(() {
      // Apply cumulative scale from the gesture relative to starting scale
      final double newScale =
          (_panZoomStartScale * event.scale).clamp(_lowerScale, _upperScale);

      if (newScale != _scale) {
        _actualSize = false;
        // Zoom changed — adjust offset to keep focal point stable
        final Offset center = Offset(size.width / 2, size.height / 2);
        _offset = _offset + (center - event.localPosition) * (newScale - _scale);
        _scale = newScale;
      }

      // Apply pan delta from the trackpad
      if (event.panDelta != Offset.zero) {
        _offset = _offset + event.panDelta;
      }

      _offset = _clampOffset(_offset, size);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.2),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
            _viewport = size;
            _actualSizeTarget = _actualSizeScale(size, devicePixelRatio);

            // Hold 1:1 through layout changes, and draw it on the pixel grid.
            var drawnOffset = _offset;
            if (_actualSize && !_resetController.isAnimating) {
              final target = _actualSizeTarget;
              if (target == null) {
                _actualSize = false;
              } else {
                _scale = target;
                _offset = _clampOffset(_offset, size);
                drawnOffset = _snapToPixelGrid(size, devicePixelRatio);
                _trackOriginPhase(devicePixelRatio);
              }
            }

            return Listener(
              key: _viewportKey,
              onPointerSignal: (event) => _handlePointerSignal(event, size),
              onPointerPanZoomStart: _handlePanZoomStart,
              onPointerPanZoomUpdate: (event) =>
                  _handlePanZoomUpdate(event, size),
              onPointerPanZoomEnd: (_) => _isPanZooming = false,
              onPointerDown: (event) {
                if (event.buttons == kMiddleMouseButton) {
                  _isMiddleDragging = true;
                }
              },
              onPointerMove: (event) {
                if (_isMiddleDragging && _scale > 1.0) {
                  setState(() {
                    _offset = _clampOffset(
                      _offset + event.delta,
                      size,
                    );
                  });
                }
              },
              onPointerUp: (event) {
                _isMiddleDragging = false;
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // After image (full width, shown on right side)
                  Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..translate(drawnOffset.dx, drawnOffset.dy)
                      ..scale(_scale, _scale),
                    child: _buildImageLayer(
                      imageData: widget.afterImage,
                      isLoading: widget.isAfterLoading,
                      colorScheme: colorScheme,
                      label: 'Processed',
                    ),
                  ),

                  // Before image (clipped to left of divider)
                  // Clip stays in screen space so the split aligns with the divider
                  ClipRect(
                    clipper: _SplitClipper(dividerPosition: _dividerPosition),
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..translate(drawnOffset.dx, drawnOffset.dy)
                        ..scale(_scale, _scale),
                      child: _buildImageLayer(
                        imageData: widget.beforeImage,
                        isLoading: widget.isBeforeLoading,
                        colorScheme: colorScheme,
                        label: 'Original',
                      ),
                    ),
                  ),

                  // Labels
                  Positioned(
                    left: 12,
                    top: 12,
                    child: _buildLabel('Original', colorScheme),
                  ),
                  Positioned(
                    right: 12,
                    top: 12,
                    child: _buildLabel('Processed', colorScheme),
                  ),

                  // Divider line
                  Positioned(
                    left: constraints.maxWidth * _dividerPosition - 1.5,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Divider handle
                  Positioned(
                    left: constraints.maxWidth * _dividerPosition - 20,
                    top: (constraints.maxHeight - 40) / 2,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.drag_handle,
                        color: Colors.black54,
                        size: 20,
                      ),
                    ),
                  ),

                  // Gesture detector for dragging divider and double-tap reset
                  Positioned.fill(
                    child: GestureDetector(
                      onHorizontalDragUpdate: (details) {
                        if (_isPanZooming || _isMiddleDragging) return;
                        setState(() {
                          _dividerPosition +=
                              details.delta.dx / constraints.maxWidth;
                          _dividerPosition = _dividerPosition.clamp(0.05, 0.95);
                        });
                      },
                      onTapDown: (details) {
                        setState(() {
                          _dividerPosition =
                              details.localPosition.dx / constraints.maxWidth;
                          _dividerPosition = _dividerPosition.clamp(0.05, 0.95);
                        });
                      },
                      onDoubleTap: _resetZoom,
                      child: Container(
                        color: Colors.transparent,
                      ),
                    ),
                  ),

                  // Zoom controls (bottom-left)
                  if (widget.beforeImage != null || widget.afterImage != null)
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: _buildZoomControls(),
                    ),

                  // Loading overlay
                  if (widget.isBeforeLoading || widget.isAfterLoading)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surface.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Processing...',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildImageLayer({
    required Uint8List? imageData,
    required bool isLoading,
    required ColorScheme colorScheme,
    required String label,
  }) {
    if (imageData != null) {
      // For non-square pixels (anamorphic DVD etc.), the image's pixel
      // dimensions don't match the intended display aspect ratio.
      // FittedBox scales its child uniformly to fit the parent while
      // preserving the SizedBox's aspect ratio — works even under the
      // tight constraints from StackFit.expand.
      if (widget.displayAspectRatio != null) {
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: widget.displayAspectRatio! * 1000,
            height: 1000,
            child: Image.memory(
              imageData,
              fit: BoxFit.fill,
              gaplessPlayback: true,
              filterQuality: FilterQuality.none,
            ),
          ),
        );
      }

      // Square pixels: contain maintains the image's native aspect ratio.
      return Image.memory(
        imageData,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.none,
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image,
            size: 48,
            color: colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 8),
          Text(
            'No preview',
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  /// Fit | 1:1 | zoom readout. The readout is a percentage of actual pixels,
  /// so 100% always means 1:1; it falls back to a multiple of fit when the
  /// frame's size can't be read. Every control is always present — disabled
  /// rather than removed — so nothing moves under the pointer.
  Widget _buildZoomControls() {
    final target = _actualSizeTarget;
    final readout = target != null
        ? '${(_scale / target * 100).round()}%'
        : '${_scale.toStringAsFixed(1)}x';

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _zoomButton(
            'Fit',
            tooltip: AppShortcut.previewFit
                .tooltipFor('Fit the whole frame in the panel'),
            selected: _isAtFit,
            onPressed: _isAtFit ? null : _resetZoom,
          ),
          _zoomButton(
            '1:1',
            tooltip: AppShortcut.previewActualSize.tooltipFor(
                'Actual pixels — one video pixel per screen pixel'),
            selected: _actualSize,
            onPressed:
                target == null || _actualSize ? null : showActualSize,
          ),
          Container(
            constraints: const BoxConstraints(minWidth: 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            child: Text(
              readout,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _zoomButton(
    String text, {
    required String tooltip,
    required bool selected,
    required VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            constraints: const BoxConstraints(minWidth: 36),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            alignment: Alignment.center,
            decoration: selected
                ? BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  )
                : null,
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white
                    .withValues(alpha: selected || onPressed != null ? 1 : 0.5),
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Custom clipper that clips the widget to show only the left portion
/// up to the divider position.
class _SplitClipper extends CustomClipper<Rect> {
  final double dividerPosition;

  _SplitClipper({required this.dividerPosition});

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * dividerPosition, size.height);
  }

  @override
  bool shouldReclip(_SplitClipper oldClipper) {
    return oldClipper.dividerPosition != dividerPosition;
  }
}
