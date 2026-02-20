import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A widget that displays a before/after comparison with a draggable divider.
///
/// The before image is shown on the left of the divider, and the after image
/// is shown on the right. The divider can be dragged to compare different
/// portions of the images.
///
/// Supports pinch-to-zoom, scroll wheel zoom, pan when zoomed, and
/// double-tap to reset.
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

  const BeforeAfterComparisonWidget({
    super.key,
    this.beforeImage,
    this.afterImage,
    this.initialDividerPosition = 0.5,
    this.isBeforeLoading = false,
    this.isAfterLoading = false,
  });

  @override
  State<BeforeAfterComparisonWidget> createState() =>
      _BeforeAfterComparisonWidgetState();
}

class _BeforeAfterComparisonWidgetState
    extends State<BeforeAfterComparisonWidget>
    with SingleTickerProviderStateMixin {
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

  @override
  void initState() {
    super.initState();
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
  void dispose() {
    _resetController.dispose();
    super.dispose();
  }

  void _resetZoom() {
    if (_scale == 1.0 && _offset == Offset.zero) return;
    _scaleAnimation = Tween<double>(begin: _scale, end: 1.0)
        .animate(CurvedAnimation(parent: _resetController, curve: Curves.easeOut));
    _offsetAnimation = Tween<Offset>(begin: _offset, end: Offset.zero)
        .animate(CurvedAnimation(parent: _resetController, curve: Curves.easeOut));
    _resetController.forward(from: 0);
  }

  /// Clamp offset so the image doesn't scroll beyond its edges.
  Offset _clampOffset(Offset offset, Size size) {
    if (_scale <= 1.0) return Offset.zero;
    // With Transform(alignment: center), the image expands equally in all
    // directions. The maximum pan in each axis is half the overflow.
    final double maxDx = (size.width * (_scale - 1)) / 2;
    final double maxDy = (size.height * (_scale - 1)) / 2;
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
      _scale = (_scale * scaleFactor).clamp(_minScale, _maxScale);
      if (_scale == oldScale) return;

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
          (_panZoomStartScale * event.scale).clamp(_minScale, _maxScale);

      if (newScale != _scale) {
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

            return Listener(
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
                      ..translate(_offset.dx, _offset.dy)
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
                        ..translate(_offset.dx, _offset.dy)
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

                  // Zoom indicator (bottom-left)
                  if (_scale > 1.01)
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${_scale.toStringAsFixed(1)}x',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
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
      return Image.memory(
        imageData,
        fit: BoxFit.contain,
        gaplessPlayback: true,
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
