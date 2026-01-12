import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/main_viewmodel.dart';

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
      child: Row(
        children: [
          // Original frame
          Expanded(
            child: _buildPreviewPane(
              context,
              title: 'Original',
              imageData: viewModel.currentFrame,
              isLoading: viewModel.isAnalyzing,
            ),
          ),

          const SizedBox(width: 16),

          // Processed preview
          Expanded(
            child: _buildPreviewPane(
              context,
              title: 'Processed',
              imageData: viewModel.processedPreview,
              isLoading: viewModel.isGeneratingPreview,
              fallbackImage: viewModel.currentFrame,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewPane(
    BuildContext context, {
    required String title,
    required Uint8List? imageData,
    required bool isLoading,
    Uint8List? fallbackImage,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              if (isLoading) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),

        // Image container
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border.all(
                color: colorScheme.outline.withValues(alpha: 0.2),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Image or placeholder
                  if (imageData != null)
                    Image.memory(
                      imageData,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    )
                  else if (fallbackImage != null)
                    Opacity(
                      opacity: 0.5,
                      child: Image.memory(
                        fallbackImage,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    )
                  else
                    Center(
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
                    ),

                  // Loading overlay
                  if (isLoading)
                    Container(
                      color: colorScheme.surface.withValues(alpha: 0.7),
                      child: const Center(
                        child: CircularProgressIndicator(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildScrubber(BuildContext context, MainViewModel viewModel) {
    final colorScheme = Theme.of(context).colorScheme;
    final thumbnails = viewModel.thumbnails;

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
          // Time display
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatTime(viewModel.scrubberPosition * viewModel.videoDuration),
                style: Theme.of(context).textTheme.bodySmall,
              ),
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
          SizedBox(
            height: 60,
            child: Stack(
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
                          viewModel.isAnalyzing
                              ? 'Generating thumbnails...'
                              : 'No thumbnails',
                          style: TextStyle(
                            color: colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
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

                // Playhead indicator
                Positioned(
                  left: (MediaQuery.of(context).size.width - 64) *
                          viewModel.scrubberPosition -
                      1,
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

                // Gesture detector for scrubbing
                Positioned.fill(
                  child: GestureDetector(
                    onHorizontalDragUpdate: (details) {
                      final box = context.findRenderObject() as RenderBox?;
                      if (box != null) {
                        final width = box.size.width - 32; // Account for padding
                        final position =
                            (details.localPosition.dx - 16) / width;
                        viewModel.setScrubberPosition(position);
                      }
                    },
                    onTapDown: (details) {
                      final box = context.findRenderObject() as RenderBox?;
                      if (box != null) {
                        final width = box.size.width - 32;
                        final position =
                            (details.localPosition.dx - 16) / width;
                        viewModel.setScrubberPosition(position);
                      }
                    },
                    child: Container(
                      color: Colors.transparent,
                    ),
                  ),
                ),
              ],
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
