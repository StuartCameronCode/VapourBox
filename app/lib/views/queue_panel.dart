import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/queue_item.dart';
import '../viewmodels/main_viewmodel.dart';

/// Panel showing the queue of videos to process.
class QueuePanel extends StatefulWidget {
  const QueuePanel({super.key});

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final queue = viewModel.queue;
        final selectedId = viewModel.selectedItemId;
        final colorScheme = Theme.of(context).colorScheme;

        return DropTarget(
          onDragEntered: (details) => setState(() => _isDragging = true),
          onDragExited: (details) => setState(() => _isDragging = false),
          onDragDone: (details) {
            setState(() => _isDragging = false);
            if (details.files.isNotEmpty) {
              final validPaths = details.files
                  .where((f) => _isVideoFile(f.path))
                  .map((f) => f.path)
                  .toList();
              if (validPaths.isNotEmpty) {
                viewModel.addMultipleToQueue(validPaths);
              }
            }
          },
          child: Container(
            decoration: BoxDecoration(
              color: _isDragging
                  ? colorScheme.primary.withValues(alpha: 0.1)
                  : null,
              border: Border(
                bottom: BorderSide(
                  color: _isDragging
                      ? colorScheme.primary
                      : colorScheme.outline.withValues(alpha: 0.2),
                  width: _isDragging ? 2 : 1,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                _buildHeader(context, viewModel, queue.length),

                // Queue list
                Expanded(
                  child: queue.isEmpty
                      ? _buildEmptyState(context)
                      : ListView.builder(
                          itemCount: queue.length,
                          itemBuilder: (context, index) {
                            final item = queue[index];
                            return _QueueItemTile(
                              item: item,
                              isSelected: item.id == selectedId,
                              onTap: () => viewModel.selectQueueItem(item.id),
                              onRemove: () => viewModel.removeFromQueue(item.id),
                              onRequeue: () => viewModel.requeueItem(item.id),
                              onInfo: () => _showVideoInfo(context, item),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _isVideoFile(String path) {
    final extensions = [
      '.avi', '.mov', '.mp4', '.mkv', '.mxf', '.m2v', '.mpg', '.mpeg',
      '.ts', '.vob', '.dv', '.mts', '.m2ts', '.wmv', '.webm', '.flv'
    ];
    final lowerPath = path.toLowerCase();
    return extensions.any((ext) => lowerPath.endsWith(ext));
  }

  Widget _buildHeader(BuildContext context, MainViewModel viewModel, int count) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.queue_play_next,
            size: 18,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            count == 0 ? 'Queue' : 'Queue ($count)',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const Spacer(),
          // Add button
          Tooltip(
            message: 'Add videos to queue',
            child: InkWell(
              onTap: () => _addVideos(context, viewModel),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.add,
                  size: 20,
                  color: colorScheme.primary,
                ),
              ),
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: 4),
            // Clear all button
            Tooltip(
              message: 'Clear all',
              child: InkWell(
                onTap: viewModel.isQueueProcessing ? null : () => viewModel.clearQueue(),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.clear_all,
                    size: 20,
                    color: viewModel.isQueueProcessing
                        ? colorScheme.onSurface.withValues(alpha: 0.3)
                        : colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isDragging ? Icons.file_download : Icons.video_library_outlined,
              size: 32,
              color: _isDragging
                  ? colorScheme.primary
                  : colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 8),
            Text(
              _isDragging ? 'Drop to add videos' : 'Drop videos here',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _isDragging
                        ? colorScheme.primary
                        : colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addVideos(BuildContext context, MainViewModel viewModel) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'avi', 'mov', 'mp4', 'mkv', 'mxf', 'm2v', 'mpg', 'mpeg',
        'ts', 'vob', 'dv', 'mts', 'm2ts', 'wmv', 'webm', 'flv'
      ],
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      final paths = result.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();
      if (paths.isNotEmpty) {
        viewModel.addMultipleToQueue(paths);
      }
    }
  }

  void _showVideoInfo(BuildContext context, QueueItem item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.displayName,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: 'File', value: item.filename),
            _InfoRow(label: 'Path', value: item.inputPath),
            if (item.videoInfo != null) ...[
              _InfoRow(label: 'Resolution', value: item.videoInfo!.resolution),
              _InfoRow(label: 'Frame Rate', value: item.videoInfo!.frameRateFormatted),
              _InfoRow(label: 'Duration', value: item.videoInfo!.durationFormatted),
              _InfoRow(label: 'Frames', value: '${item.videoInfo!.frameCount}'),
              _InfoRow(
                label: 'Field Order',
                value: item.videoInfo!.fieldOrderDescription,
              ),
            ],
            if (item.hasInOutRange)
              _InfoRow(label: 'Range', value: item.inOutRangeFormatted),
            _InfoRow(label: 'Status', value: _statusText(item.status)),
            if (item.errorMessage != null)
              _InfoRow(label: 'Error', value: item.errorMessage!),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _showInFolder(item.inputPath),
            icon: const Icon(Icons.folder_open),
            label: const Text('Show in Folder'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showInFolder(String path) {
    if (Platform.isMacOS) {
      Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      Process.run('explorer', ['/select,', path]);
    }
  }

  String _statusText(QueueItemStatus status) {
    switch (status) {
      case QueueItemStatus.pending:
        return 'Pending';
      case QueueItemStatus.analyzing:
        return 'Analyzing...';
      case QueueItemStatus.ready:
        return 'Ready';
      case QueueItemStatus.processing:
        return 'Processing...';
      case QueueItemStatus.completed:
        return 'Completed';
      case QueueItemStatus.failed:
        return 'Failed';
      case QueueItemStatus.cancelled:
        return 'Cancelled';
    }
  }
}

class _QueueItemTile extends StatelessWidget {
  final QueueItem item;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onRequeue;
  final VoidCallback onInfo;

  const _QueueItemTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
    required this.onRemove,
    required this.onRequeue,
    required this.onInfo,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? colorScheme.primaryContainer.withValues(alpha: 0.5)
              : null,
          border: Border(
            left: BorderSide(
              color: isSelected ? colorScheme.primary : Colors.transparent,
              width: 3,
            ),
            bottom: BorderSide(
              color: colorScheme.outline.withValues(alpha: 0.1),
            ),
          ),
        ),
        child: Row(
          children: [
            // Status icon
            _buildStatusIcon(context, item.status),
            const SizedBox(width: 8),

            // File info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Filename
                  Text(
                    item.displayName,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: isSelected ? FontWeight.bold : null,
                        ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  // Details row
                  Row(
                    children: [
                      if (item.resolution.isNotEmpty) ...[
                        Text(
                          item.resolution,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (item.durationFormatted.isNotEmpty) ...[
                        Text(
                          item.durationFormatted,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                        ),
                      ],
                      if (item.hasInOutRange) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            'Trimmed',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSecondaryContainer,
                                  fontSize: 10,
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Info button
            IconButton(
              icon: const Icon(Icons.info_outline, size: 18),
              onPressed: onInfo,
              tooltip: 'Video info',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                minimumSize: const Size(28, 28),
                padding: EdgeInsets.zero,
              ),
            ),

            // Requeue button (for completed, failed, or cancelled items)
            if (item.status == QueueItemStatus.completed ||
                item.status == QueueItemStatus.failed ||
                item.status == QueueItemStatus.cancelled)
              IconButton(
                icon: Icon(
                  Icons.replay,
                  size: 18,
                  color: colorScheme.primary,
                ),
                onPressed: onRequeue,
                tooltip: 'Reprocess',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  minimumSize: const Size(28, 28),
                  padding: EdgeInsets.zero,
                ),
              ),

            // Remove button (only if not processing)
            if (item.canRemove)
              IconButton(
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                onPressed: onRemove,
                tooltip: 'Remove from queue',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  minimumSize: const Size(28, 28),
                  padding: EdgeInsets.zero,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(BuildContext context, QueueItemStatus status) {
    switch (status) {
      case QueueItemStatus.pending:
        return Icon(
          Icons.schedule,
          size: 18,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
        );
      case QueueItemStatus.analyzing:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case QueueItemStatus.ready:
        return Icon(
          Icons.check_circle_outline,
          size: 18,
          color: Theme.of(context).colorScheme.primary,
        );
      case QueueItemStatus.processing:
        return SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.primary,
          ),
        );
      case QueueItemStatus.completed:
        return const Icon(
          Icons.check_circle,
          size: 18,
          color: Colors.green,
        );
      case QueueItemStatus.failed:
        return Icon(
          Icons.error_outline,
          size: 18,
          color: Theme.of(context).colorScheme.error,
        );
      case QueueItemStatus.cancelled:
        return Icon(
          Icons.cancel_outlined,
          size: 18,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
        );
    }
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
