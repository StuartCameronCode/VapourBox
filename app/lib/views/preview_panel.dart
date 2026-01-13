import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/main_viewmodel.dart';
import '../widgets/before_after_comparison.dart';

class PreviewPanel extends StatelessWidget {
  const PreviewPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        return Column(
          children: [
            // Preview comparison area
            Expanded(
              child: _buildPreviewComparison(context, viewModel),
            ),

            // Thumbnail scrubber
            _buildScrubber(context, viewModel),
          ],
        );
      },
    );
  }

  Widget _buildPreviewComparison(BuildContext context, MainViewModel viewModel) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: BeforeAfterComparisonWidget(
        beforeImage: viewModel.currentFrame,
        afterImage: viewModel.processedPreview ?? viewModel.currentFrame,
        isBeforeLoading: viewModel.isAnalyzing,
        isAfterLoading: viewModel.isGeneratingPreview,
      ),
    );
  }

  Widget _buildScrubber(BuildContext context, MainViewModel viewModel) {
    final colorScheme = Theme.of(context).colorScheme;
    final thumbnails = viewModel.thumbnails;
    final zoom = viewModel.timelineZoom;
    final isZoomed = zoom > 1.0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Time display and zoom controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Current time
              Text(
                _formatTime(viewModel.scrubberPosition * viewModel.videoDuration),
                style: Theme.of(context).textTheme.bodySmall,
              ),

              // Zoom controls
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isZoomed) ...[
                    // Show visible range when zoomed
                    Text(
                      '${_formatTime(viewModel.visibleStartTime)} - ${_formatTime(viewModel.visibleEndTime)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // Zoom level indicator
                  if (isZoomed)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${zoom.toStringAsFixed(1)}x',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  // Zoom out button
                  IconButton(
                    icon: const Icon(Icons.remove, size: 18),
                    onPressed: zoom > 1.0 ? viewModel.zoomOut : null,
                    tooltip: 'Zoom out',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(28, 28),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                  // Zoom in button
                  IconButton(
                    icon: const Icon(Icons.add, size: 18),
                    onPressed: zoom < 16.0 ? viewModel.zoomIn : null,
                    tooltip: 'Zoom in',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(28, 28),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                  if (isZoomed)
                    IconButton(
                      icon: const Icon(Icons.zoom_out_map, size: 18),
                      onPressed: viewModel.resetTimelineZoom,
                      tooltip: 'Reset zoom',
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(28, 28),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                ],
              ),

              // Total duration
              Text(
                _formatTime(viewModel.videoDuration),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Thumbnail strip with slider
          Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                // Mouse wheel zoom
                if (event.scrollDelta.dy < 0) {
                  viewModel.zoomIn();
                } else if (event.scrollDelta.dy > 0) {
                  viewModel.zoomOut();
                }
              }
            },
            child: SizedBox(
              height: 60,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final timelineWidth = constraints.maxWidth;

                  // Calculate playhead position within visible range
                  double playheadPosition;
                  if (isZoomed) {
                    // Map scrubber position to visible range
                    final viewStart = viewModel.timelineViewStart;
                    final viewEnd = viewModel.timelineViewEnd;
                    final normalizedPos =
                        (viewModel.scrubberPosition - viewStart) /
                            (viewEnd - viewStart);
                    playheadPosition =
                        (normalizedPos * timelineWidth).clamp(0.0, timelineWidth);
                  } else {
                    playheadPosition =
                        viewModel.scrubberPosition * timelineWidth;
                  }

                  return Stack(
                    children: [
                      // Thumbnail strip background
                      if (thumbnails.isNotEmpty)
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Row(
                              children: thumbnails.map((thumb) {
                                return Expanded(
                                  child: Image.memory(
                                    thumb,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        )
                      else
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Center(
                              child: Text(
                                viewModel.isAnalyzing ||
                                        viewModel.isLoadingZoomedThumbnails
                                    ? 'Generating thumbnails...'
                                    : 'No thumbnails',
                                style: TextStyle(
                                  color:
                                      colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                          ),
                        ),

                      // Loading overlay when regenerating thumbnails
                      if (viewModel.isLoadingZoomedThumbnails &&
                          thumbnails.isNotEmpty)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          ),
                        ),

                      // Semi-transparent overlay for contrast
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.1),
                                Colors.black.withValues(alpha: 0.3),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Playhead indicator (only show if within visible range when zoomed)
                      if (!isZoomed ||
                          (viewModel.scrubberPosition >=
                                  viewModel.timelineViewStart &&
                              viewModel.scrubberPosition <=
                                  viewModel.timelineViewEnd))
                        Positioned(
                          left: playheadPosition - 1.5,
                          top: 0,
                          bottom: 0,
                          child: Container(
                            width: 3,
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ),

                      // Gesture detector for scrubbing and panning
                      Positioned.fill(
                        child: GestureDetector(
                          onHorizontalDragUpdate: (details) {
                            if (isZoomed) {
                              // Pan the timeline when zoomed
                              final panDelta =
                                  -details.delta.dx / timelineWidth /
                                      viewModel.timelineZoom;
                              viewModel.panTimeline(panDelta);
                            } else {
                              // Normal scrubbing
                              final position =
                                  details.localPosition.dx / timelineWidth;
                              viewModel.setScrubberPosition(position);
                            }
                          },
                          onTapDown: (details) {
                            final tapPosition =
                                details.localPosition.dx / timelineWidth;

                            if (isZoomed) {
                              // Map tap position to actual video position
                              final viewStart = viewModel.timelineViewStart;
                              final viewEnd = viewModel.timelineViewEnd;
                              final actualPosition = viewStart +
                                  tapPosition * (viewEnd - viewStart);
                              viewModel.setScrubberPosition(actualPosition);
                            } else {
                              viewModel.setScrubberPosition(tapPosition);
                            }
                          },
                          child: Container(
                            color: Colors.transparent,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Slider for fine control
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 8,
              ),
            ),
            child: Slider(
              value: viewModel.scrubberPosition,
              onChanged: (value) => viewModel.setScrubberPosition(value),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '0:00';

    final totalSecs = seconds.toInt();
    final minutes = totalSecs ~/ 60;
    final secs = totalSecs % 60;

    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }
}
