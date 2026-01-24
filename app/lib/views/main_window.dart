import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/processing_preset.dart';
import '../models/progress_info.dart';
import '../models/queue_item.dart';
import '../services/audio_compatibility_service.dart';
import '../viewmodels/main_viewmodel.dart';
import 'about_dialog.dart' as about;
import 'audio_compatibility_dialog.dart';
import 'drop_zone.dart';
import 'overwrite_warning_dialog.dart';
import 'pass_list/pass_list_panel.dart';
import 'pass_settings/pass_settings_container.dart';
import 'preview_panel.dart';
import 'progress_panel.dart';
import 'queue_panel.dart';
import 'settings/settings_dialog.dart';

class MainWindow extends StatelessWidget {
  const MainWindow({super.key});

  String _getGoButtonText(MainViewModel viewModel) {
    if (viewModel.isQueueProcessing) {
      final completed = viewModel.queueCompletedCount;
      final total = viewModel.queue.length;
      return 'Processing ${completed + 1}/$total...';
    }

    final readyCount = viewModel.queueReadyCount;
    if (readyCount > 1) {
      return 'Go ($readyCount)';
    }
    return 'Go';
  }

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
                child: viewModel.queue.isEmpty
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

          // Preset dropdown
          PopupMenuButton<String>(
            tooltip: 'Load or save presets',
            icon: const Icon(Icons.tune),
            onSelected: (value) async {
              if (value == 'save') {
                _showSavePresetDialog(context, viewModel);
              } else if (value.startsWith('load:')) {
                final presetId = value.substring(5);
                final preset = viewModel.availablePresets.where((p) => p.id == presetId).firstOrNull;
                if (preset != null) {
                  viewModel.loadPreset(preset);
                }
              } else if (value.startsWith('delete:')) {
                final presetId = value.substring(7);
                final preset = viewModel.availablePresets.where((p) => p.id == presetId).firstOrNull;
                if (preset != null && !preset.isBuiltIn) {
                  await viewModel.deletePreset(preset);
                }
              }
            },
            itemBuilder: (context) {
              final presets = viewModel.availablePresets;
              final builtIn = presets.where((p) => p.isBuiltIn).toList();
              final user = presets.where((p) => !p.isBuiltIn).toList();

              return [
                const PopupMenuItem<String>(
                  enabled: false,
                  child: Text('Built-in Presets', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                ...builtIn.map((p) => PopupMenuItem<String>(
                      value: 'load:${p.id}',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(p.name),
                        subtitle: p.description != null ? Text(p.description!, style: const TextStyle(fontSize: 11)) : null,
                      ),
                    )),
                if (user.isNotEmpty) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem<String>(
                    enabled: false,
                    child: Text('My Presets', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  ...user.map((p) => PopupMenuItem<String>(
                        value: 'load:${p.id}',
                        child: Row(
                          children: [
                            Expanded(
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(p.name),
                                subtitle: p.description != null ? Text(p.description!, style: const TextStyle(fontSize: 11)) : null,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 18),
                              onPressed: () {
                                Navigator.pop(context, 'delete:${p.id}');
                              },
                            ),
                          ],
                        ),
                      )),
                ],
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'save',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(Icons.save),
                    title: Text('Save Current Settings...'),
                  ),
                ),
              ];
            },
          ),

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

          // Clear button (if queue has items)
          if (viewModel.queue.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.clear),
              label: const Text('Clear'),
              onPressed:
                  viewModel.isProcessing ? null : () => viewModel.clearQueue(),
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
            label: Text(_getGoButtonText(viewModel)),
            onPressed: viewModel.canProcess
                ? () => _startProcessingWithCompatibilityCheck(context, viewModel)
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
        // Queue panel at top
        SizedBox(
          height: 180,
          child: const QueuePanel(),
        ),

        // Output settings row
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
              ),
            ),
          ),
          child: Row(
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

  Widget _buildStatusBar(BuildContext context, MainViewModel viewModel) {
    String statusText = 'Ready';
    bool isClickable = false;

    if (viewModel.isAnalyzing) {
      statusText = 'Analyzing videos...';
    } else if (viewModel.isGeneratingPreview) {
      statusText = 'Generating preview... (click for log)';
      isClickable = true;
    } else if (viewModel.previewError != null) {
      statusText = 'Preview failed (click for details)';
      isClickable = true;
    } else if (viewModel.isProcessing) {
      final progress = viewModel.currentProgress;
      final queueInfo = viewModel.isQueueProcessing
          ? ' (${viewModel.queueCompletedCount + 1}/${viewModel.queue.length})'
          : '';
      if (progress != null) {
        statusText =
            'Processing$queueInfo: ${progress.percentComplete}% - ${progress.fpsFormatted} - ETA: ${progress.etaFormatted}';
      } else {
        statusText = 'Processing$queueInfo...';
      }
    } else if (viewModel.state == ProcessingState.completed) {
      final completed = viewModel.queueCompletedCount;
      final total = viewModel.queue.length;
      statusText = total > 1 ? 'Complete! ($completed/$total processed)' : 'Complete!';
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
          if (viewModel.selectedItem != null && viewModel.selectedItem!.videoInfo != null)
            Text(
              viewModel.selectedItem!.videoInfo!.resolution,
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

  void _showSavePresetDialog(BuildContext context, MainViewModel viewModel) {
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Preset'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Preset Name',
                hintText: 'My Custom Preset',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'What is this preset for?',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;

              await viewModel.saveAsPreset(
                name,
                description: descriptionController.text.trim().isNotEmpty
                    ? descriptionController.text.trim()
                    : null,
              );

              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Preset "$name" saved')),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Check for overwrites and audio compatibility, then start processing.
  /// Shows warning dialogs as needed before starting.
  Future<void> _startProcessingWithCompatibilityCheck(
    BuildContext context,
    MainViewModel viewModel,
  ) async {
    // Check for existing output files that would be overwritten
    final existingFiles = await _getExistingOutputFiles(viewModel.queue);
    if (existingFiles.isNotEmpty) {
      if (!context.mounted) return;
      final shouldOverwrite = await OverwriteWarningDialog.show(
        context: context,
        existingFiles: existingFiles,
      );
      if (!shouldOverwrite) {
        return; // User cancelled
      }
    }

    // Only check audio compatibility if audio copy is enabled
    if (!viewModel.encodingSettings.audioCopy) {
      viewModel.startProcessing();
      return;
    }

    // Check audio compatibility
    final service = AudioCompatibilityService();
    final compatibility = await service.checkCompatibility(
      inputPath: viewModel.inputPath!,
      outputContainer: viewModel.encodingSettings.container,
      audioCopy: viewModel.encodingSettings.audioCopy,
    );

    // If compatible or no audio, proceed directly
    if (compatibility.isCompatible) {
      viewModel.startProcessing();
      return;
    }

    // Show dialog for user to choose
    if (!context.mounted) return;

    final result = await AudioCompatibilityDialog.show(
      context: context,
      compatibility: compatibility,
    );

    if (result == null || result.choice == AudioCompatibilityChoice.cancel) {
      // User cancelled
      return;
    }

    switch (result.choice) {
      case AudioCompatibilityChoice.reencode:
        // Update settings to re-encode audio
        viewModel.updateEncodingSettings(
          viewModel.encodingSettings.copyWith(
            audioCopy: false,
            audioCodec: compatibility.suggestedCodec,
          ),
        );
        break;

      case AudioCompatibilityChoice.changeContainer:
        // Update settings to use compatible container
        if (result.newContainer != null) {
          viewModel.updateEncodingSettings(
            viewModel.encodingSettings.copyWith(
              container: result.newContainer,
            ),
          );
        }
        break;

      case AudioCompatibilityChoice.cancel:
        return;
    }

    // Start processing with updated settings
    viewModel.startProcessing();
  }

  /// Returns list of output file paths that already exist.
  Future<List<String>> _getExistingOutputFiles(List<QueueItem> queue) async {
    final existingFiles = <String>[];
    for (final item in queue) {
      // Check items that will be processed (ready, failed, completed, cancelled)
      if (item.canProcess || item.canReprocess) {
        if (await File(item.outputPath).exists()) {
          existingFiles.add(item.outputPath);
        }
      }
    }
    return existingFiles;
  }
}
