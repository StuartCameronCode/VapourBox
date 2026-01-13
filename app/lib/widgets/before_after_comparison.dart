import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A widget that displays a before/after comparison with a draggable divider.
///
/// The before image is shown on the left of the divider, and the after image
/// is shown on the right. The divider can be dragged to compare different
/// portions of the images.
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
    extends State<BeforeAfterComparisonWidget> {
  late double _dividerPosition;

  @override
  void initState() {
    super.initState();
    _dividerPosition = widget.initialDividerPosition;
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
            return Stack(
              fit: StackFit.expand,
              children: [
                // After image (full width, shown on right side)
                _buildImageLayer(
                  imageData: widget.afterImage,
                  isLoading: widget.isAfterLoading,
                  colorScheme: colorScheme,
                  label: 'Processed',
                ),

                // Before image (clipped to left of divider)
                ClipRect(
                  clipper: _SplitClipper(dividerPosition: _dividerPosition),
                  child: _buildImageLayer(
                    imageData: widget.beforeImage,
                    isLoading: widget.isBeforeLoading,
                    colorScheme: colorScheme,
                    label: 'Original',
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

                // Gesture detector for dragging
                Positioned.fill(
                  child: GestureDetector(
                    onHorizontalDragUpdate: (details) {
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
                    child: Container(
                      color: Colors.transparent,
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
