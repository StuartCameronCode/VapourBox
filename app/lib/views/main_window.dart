import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/progress_info.dart';
import '../viewmodels/main_viewmodel.dart';
import 'about_dialog.dart' as about;
import 'drop_zone.dart';
import 'pass_list/pass_list_panel.dart';
import 'pass_settings/pass_settings_container.dart';
import 'preview_panel.dart';
import 'progress_panel.dart';
import 'settings/settings_dialog.dart';

class MainWindow extends StatelessWidget {
  const MainWindow({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Consumer<MainViewModel>(
        builder: (context, viewModel, child) {
          return Column(
            children: [
              // Top toolbar
              _buildToolbar(context, viewModel),

              // Main content area
              Expanded(
                child: viewModel.inputPath == null
                    ? const DropZone()
                    : _buildMainContent(context, viewModel),
              ),

              // Bottom status bar
              _buildStatusBar(context, viewModel),
            ],
          );
        },
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, MainViewModel viewModel) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          // App title
          Text(
            'VapourBox',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),

          const Spacer(),

          // About button
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About',
            onPressed: () => _showAbout(context),
          ),

          // Settings button
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => _showSettings(context, viewModel),
          ),

          const SizedBox(width: 8),

          // Clear button (if file loaded)
          if (viewModel.inputPath != null)
            TextButton.icon(
              icon: const Icon(Icons.clear),
              label: const Text('Clear'),
              onPressed:
                  viewModel.isProcessing ? null : () => viewModel.clearInput(),
            ),

          const SizedBox(width: 8),

          // Go button
          FilledButton.icon(
            icon: viewModel.isProcessing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(viewModel.isProcessing ? 'Processing...' : 'Go'),
            onPressed: viewModel.canProcess
                ? () => viewModel.startProcessing()
                : viewModel.state.canCancel
                    ? () => viewModel.cancelProcessing()
                    : null,
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent(BuildContext context, MainViewModel viewModel) {
    if (viewModel.isProcessing ||
        viewModel.state == ProcessingState.completed ||
        viewModel.state == ProcessingState.failed) {
      return const ProgressPanel();
    }

    return Row(
      children: [
        // Preview panel (left side)
        const Expanded(
          flex: 3,
          child: PreviewPanel(),
        ),

        // Divider
        VerticalDivider(
          width: 1,
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
        ),

        // Info panel (right side)
        Expanded(
          flex: 2,
          child: _buildInfoPanel(context, viewModel),
        ),
      ],
    );
  }

  Widget _buildInfoPanel(BuildContext context, MainViewModel viewModel) {
    return Column(
      children: [
        // Fixed header with video info and output settings
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildVideoInfoSection(context, viewModel),
              const SizedBox(height: 12),
              // Output summary row
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Output: ${viewModel.encodingSettings.codec.displayName} → ${viewModel.encodingSettings.container.name.toUpperCase()}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showSettings(context, viewModel),
                    child: const Text('Edit'),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Scrollable pass list and settings
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Pass list panel
                const PassListPanel(),

                const Divider(height: 32),

                // Selected pass settings
                const PassSettingsContainer(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoInfoSection(BuildContext context, MainViewModel viewModel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Input',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        _buildInfoRow(
            context, 'File', viewModel.inputPath?.split('/').last ?? ''),

        if (viewModel.videoInfo != null) ...[
          _buildInfoRow(context, 'Resolution', viewModel.videoInfo!.resolution),
          _buildInfoRow(
              context, 'Frame Rate', viewModel.videoInfo!.frameRateFormatted),
          _buildInfoRow(
              context, 'Duration', viewModel.videoInfo!.durationFormatted),
          _buildInfoRow(context, 'Frames', '${viewModel.videoInfo!.frameCount}'),
          _buildInfoRow(context, 'Field Order',
              viewModel.videoInfo!.fieldOrderDescription),
        ],

        if (viewModel.isAnalyzing) ...[
          const SizedBox(height: 8),
          const Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text('Analyzing...'),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(BuildContext context, MainViewModel viewModel) {
    String statusText = 'Ready';
    bool isClickable = false;

    if (viewModel.isAnalyzing) {
      statusText = 'Analyzing video...';
    } else if (viewModel.isGeneratingPreview) {
      statusText = 'Generating preview... (click for log)';
      isClickable = true;
    } else if (viewModel.previewError != null) {
      statusText = 'Preview failed (click for details)';
      isClickable = true;
    } else if (viewModel.isProcessing) {
      final progress = viewModel.currentProgress;
      if (progress != null) {
        statusText =
            'Processing: ${progress.percentComplete}% - ${progress.fpsFormatted} - ETA: ${progress.etaFormatted}';
      } else {
        statusText = 'Processing...';
      }
    } else if (viewModel.state == ProcessingState.completed) {
      statusText = 'Complete!';
    } else if (viewModel.state == ProcessingState.failed) {
      statusText = 'Failed';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          if (viewModel.isProcessing || viewModel.isGeneratingPreview) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ],
          if (viewModel.previewError != null && !viewModel.isGeneratingPreview)
            Icon(
              Icons.error_outline,
              size: 16,
              color: Theme.of(context).colorScheme.error,
            ),
          if (viewModel.previewError != null && !viewModel.isGeneratingPreview)
            const SizedBox(width: 8),
          isClickable
              ? InkWell(
                  onTap: () => _showPreviewLog(context, viewModel),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: viewModel.previewError != null
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                )
              : Text(statusText),
          const Spacer(),
          if (viewModel.inputPath != null && viewModel.videoInfo != null)
            Text(
              viewModel.videoInfo!.resolution,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
        ],
      ),
    );
  }

  void _showPreviewLog(BuildContext context, MainViewModel viewModel) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.article_outlined),
            const SizedBox(width: 8),
            const Text('Preview Generation Log'),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 400,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (viewModel.previewError != null) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            viewModel.previewError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                const Text(
                  'Worker Output:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 200),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: viewModel.previewLog.isEmpty
                      ? const Center(child: Text('No log output yet'))
                      : SelectableText(
                          viewModel.previewLog.join('\n'),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              final fullLog = StringBuffer();
              if (viewModel.previewError != null) {
                fullLog.writeln('ERROR: ${viewModel.previewError}');
                fullLog.writeln('');
              }
              fullLog.writeln(viewModel.previewLog.join('\n'));
              Clipboard.setData(ClipboardData(text: fullLog.toString()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Log copied to clipboard'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy to Clipboard'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSettings(BuildContext context, MainViewModel viewModel) {
    showDialog(
      context: context,
      builder: (context) => ChangeNotifierProvider.value(
        value: viewModel,
        child: const SettingsDialog(),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const about.AboutDialog(),
    );
  }
}
