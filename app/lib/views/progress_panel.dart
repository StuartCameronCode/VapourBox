import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/progress_info.dart';
import '../services/worker_manager.dart';
import '../viewmodels/main_viewmodel.dart';

class ProgressPanel extends StatelessWidget {
  const ProgressPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final progress = viewModel.currentProgress;
        final state = viewModel.state;

        return Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Status icon
              _buildStatusIcon(context, state),

              const SizedBox(height: 24),

              // Status text
              Text(
                _getStatusText(state, progress),
                style: Theme.of(context).textTheme.headlineSmall,
              ),

              const SizedBox(height: 32),

              // Progress bar
              if (state == ProcessingState.processing ||
                  state == ProcessingState.preparingJob) ...[
                SizedBox(
                  width: 400,
                  child: LinearProgressIndicator(
                    value: (progress != null && progress.isIndeterminate)
                        ? null
                        : progress?.progress,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),

                const SizedBox(height: 16),

                // Progress details
                if (progress != null)
                  _buildProgressDetails(context, progress)
                else
                  Text(
                    'Preparing...',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
              ],

              // Completion message
              if (state == ProcessingState.completed) ...[
                const SizedBox(height: 16),
                Text(
                  viewModel.completionLabel,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    viewModel.outputPath ?? '',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                        ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Show in Folder'),
                      onPressed: () => _showInFolder(viewModel.outputPath),
                    ),
                    const SizedBox(width: 16),
                    FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Done'),
                      onPressed: () => viewModel.reset(),
                    ),
                  ],
                ),
              ],

              // Error message
              if (state == ProcessingState.failed) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Processing failed',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onErrorContainer,
                            ),
                      ),
                      if (viewModel.logMessages.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          viewModel.logMessages.last.message,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer,
                                  ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try Again'),
                  onPressed: () => viewModel.retryFailed(),
                ),
              ],

              // Cancel button during processing
              if (state.canCancel) ...[
                const SizedBox(height: 32),
                TextButton.icon(
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel'),
                  onPressed: () => _confirmCancel(context, viewModel),
                ),
              ],

              // Log viewer
              if (viewModel.logMessages.isNotEmpty &&
                  (state == ProcessingState.processing ||
                      state == ProcessingState.failed)) ...[
                const SizedBox(height: 32),
                _buildLogViewer(context, viewModel),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatusIcon(BuildContext context, ProcessingState state) {
    final colorScheme = Theme.of(context).colorScheme;

    switch (state) {
      case ProcessingState.preparingJob:
      case ProcessingState.processing:
        return SizedBox(
          width: 64,
          height: 64,
          child: CircularProgressIndicator(
            strokeWidth: 4,
            color: colorScheme.primary,
          ),
        );

      case ProcessingState.cancelling:
        return Icon(
          Icons.cancel_outlined,
          size: 64,
          color: colorScheme.outline,
        );

      case ProcessingState.completed:
        return Icon(
          Icons.check_circle,
          size: 64,
          color: colorScheme.primary,
        );

      case ProcessingState.failed:
        return Icon(
          Icons.error,
          size: 64,
          color: colorScheme.error,
        );

      case ProcessingState.idle:
        return Icon(
          Icons.play_circle,
          size: 64,
          color: colorScheme.outline,
        );
    }
  }

  String _getStatusText(ProcessingState state, ProgressInfo? progress) {
    switch (state) {
      case ProcessingState.preparingJob:
        return 'Preparing job...';
      case ProcessingState.processing:
        if (progress != null) {
          if (progress.isSubtitlePhase) return 'Generating Subtitles';
          if (progress.isEmbeddingPhase) return 'Embedding Subtitles';
        }
        return 'Processing';
      case ProcessingState.cancelling:
        return 'Cancelling...';
      case ProcessingState.completed:
        return 'Complete!';
      case ProcessingState.failed:
        return 'Failed';
      case ProcessingState.idle:
        return 'Ready';
    }
  }

  Widget _buildProgressDetails(BuildContext context, ProgressInfo progress) {
    // Subtitle generation phase: show percentage only
    if (progress.isSubtitlePhase) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildDetailChip(
            context,
            icon: Icons.subtitles,
            value: 'Generating subtitles... ${progress.percentComplete}%',
          ),
        ],
      );
    }

    // Embedding phase: show text only (indeterminate)
    if (progress.isEmbeddingPhase) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildDetailChip(
            context,
            icon: Icons.subtitles,
            value: 'Embedding subtitles...',
          ),
        ],
      );
    }

    // Encoding phase: full details
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildDetailChip(
          context,
          icon: Icons.percent,
          value: '${progress.percentComplete}%',
        ),
        const SizedBox(width: 24),
        _buildDetailChip(
          context,
          icon: Icons.speed,
          value: progress.fpsFormatted,
        ),
        const SizedBox(width: 24),
        _buildDetailChip(
          context,
          icon: Icons.timer,
          value: 'ETA: ${progress.etaFormatted}',
        ),
        const SizedBox(width: 24),
        _buildDetailChip(
          context,
          icon: Icons.movie,
          value: '${progress.frame} / ${progress.totalFrames}',
        ),
      ],
    );
  }

  Widget _buildDetailChip(
    BuildContext context, {
    required IconData icon,
    required String value,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _buildLogViewer(BuildContext context, MainViewModel viewModel) {
    return Expanded(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Log',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy logs to clipboard',
                  onPressed: () => _copyLogs(context, viewModel),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                reverse: true,
                itemCount: viewModel.logMessages.length,
                itemBuilder: (context, index) {
                  final message = viewModel
                      .logMessages[viewModel.logMessages.length - 1 - index];
                  return _buildLogEntry(context, message);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _copyLogs(BuildContext context, MainViewModel viewModel) {
    final logText = viewModel.logMessages
        .map((m) => '[${m.level.name.toUpperCase()}] ${m.message}')
        .join('\n');
    Clipboard.setData(ClipboardData(text: logText));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Logs copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Widget _buildLogEntry(BuildContext context, LogMessage message) {
    Color textColor;
    switch (message.level) {
      case LogLevel.error:
        textColor = Theme.of(context).colorScheme.error;
        break;
      case LogLevel.warning:
        textColor = Colors.orange;
        break;
      case LogLevel.info:
        textColor = Theme.of(context).colorScheme.onSurface;
        break;
      case LogLevel.debug:
        textColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        message.message,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: textColor,
            ),
      ),
    );
  }

  void _confirmCancel(BuildContext context, MainViewModel viewModel) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Processing?'),
        content: const Text('Are you sure you want to cancel? The current video will stop processing.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Continue Processing'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              viewModel.cancelProcessing();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showInFolder(String? path) async {
    if (path == null || path.isEmpty) return;

    final file = File(path);
    if (!await file.exists()) return;

    if (Platform.isWindows) {
      // Windows: use explorer.exe /select,<path>
      final windowsPath = path.replaceAll('/', '\\');
      await Process.run('cmd', ['/c', 'explorer', '/select,', windowsPath]);
    } else if (Platform.isMacOS) {
      // macOS: use open -R <path> to reveal in Finder
      await Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      // Linux: try xdg-open on the parent directory
      final parent = file.parent.path;
      await Process.run('xdg-open', [parent]);
    }
  }
}
