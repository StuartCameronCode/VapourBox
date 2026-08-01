import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/encoding_settings.dart';
import '../models/progress_info.dart';
import '../models/queue_item.dart';
import '../services/audio_compatibility_service.dart';
import '../services/preset_service.dart';
import '../viewmodels/main_viewmodel.dart';
import '../services/disc_detector.dart';
import 'about_dialog.dart' as about;
import 'audio_compatibility_dialog.dart';
import 'drop_zone.dart';
import 'dvd_title_picker.dart';
import 'overwrite_warning_dialog.dart';
import 'pass_list/pass_list_panel.dart';
import 'preview_panel.dart';
import 'progress_panel.dart';
import 'queue_panel.dart';
import 'settings/settings_dialog.dart';
import '../widgets/resizable_split.dart';

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
              } else if (value.startsWith('update:')) {
                final presetId = value.substring(7);
                final preset = viewModel.availablePresets.where((p) => p.id == presetId).firstOrNull;
                if (preset != null && !preset.isBuiltIn && context.mounted) {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Update Preset'),
                      content: Text('Update "${preset.name}" with current settings?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Update'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await viewModel.updatePreset(preset);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Preset "${preset.name}" updated')),
                      );
                    }
                  }
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
                              icon: const Icon(Icons.sync, size: 18),
                              tooltip: 'Update with current settings',
                              onPressed: () {
                                Navigator.pop(context, 'update:${p.id}');
                              },
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

          // Open Disc button
          IconButton(
            icon: const Icon(Icons.album),
            tooltip: 'Open DVD',
            onPressed: viewModel.isProcessing
                ? null
                : () => _openDvd(context, viewModel),
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

          // Show Close button when completed/failed, otherwise Clear + Go
          if (viewModel.state == ProcessingState.completed ||
              viewModel.state == ProcessingState.failed) ...[
            FilledButton.icon(
              icon: const Icon(Icons.close),
              label: const Text('Close'),
              onPressed: () => viewModel.reset(),
            ),
          ] else ...[
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
                  : null,
            ),
          ],
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

    // Preview | info panel, with a divider the user can drag. Before it's
    // dragged the preview takes 60% of the width, as the old 3:2 flex did.
    return LayoutBuilder(
      builder: (context, constraints) {
        return ResizableSplit(
          axis: Axis.horizontal,
          storageKey: 'main.preview',
          initialFirstSize: constraints.maxWidth * 0.6,
          minFirstSize: 320,
          minSecondSize: 320,
          first: const PreviewPanel(),
          second: _buildInfoPanel(context, viewModel),
        );
      },
    );
  }

  // Queue sizing. The queue starts just tall enough for the files actually in
  // it — one file shouldn't leave a mostly-empty panel — and stops growing at
  // [_queueMaxAutoHeight], after which the list scrolls. Dragging the divider
  // overrides this; double-clicking it hands the queue back to auto-sizing.
  static const double _queueHeaderHeight = 37;
  static const double _queueRowHeight = 54;
  static const double _queueMinHeight = 72;
  static const double _queueMaxAutoHeight = 260;

  double _queueAutoHeight(int itemCount) {
    final wanted = _queueHeaderHeight + _queueRowHeight * itemCount;
    return wanted.clamp(_queueMinHeight, _queueMaxAutoHeight);
  }

  Widget _buildInfoPanel(BuildContext context, MainViewModel viewModel) {
    return ResizableSplit(
      axis: Axis.vertical,
      storageKey: 'main.queue',
      initialFirstSize: _queueAutoHeight(viewModel.queue.length),
      minFirstSize: _queueMinHeight,
      minSecondSize: 200,
      first: const QueuePanel(),
      second: Column(
        children: [
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

          // Scrollable pass list — each pass expands inline to show its settings
          const Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: PassListPanel(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(BuildContext context, MainViewModel viewModel) {
    String statusText = 'Ready';
    bool isClickable = false;

    if (viewModel.isExtracting) {
      final extracting = viewModel.queue.where(
        (q) => q.status == QueueItemStatus.extracting,
      ).first;
      final pct = (extracting.extractionProgress * 100).round();
      statusText = 'Extracting DVD title... $pct%';
    } else if (viewModel.isAnalyzing) {
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
          if (viewModel.isProcessing || viewModel.isGeneratingPreview || viewModel.isExtracting) ...[
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

  Future<void> _openDvd(BuildContext context, MainViewModel viewModel) async {
    final discs = await viewModel.detectDiscs();

    if (!context.mounted) return;

    if (discs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No DVD discs detected'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    String mountPoint;
    if (discs.length == 1) {
      mountPoint = discs.first.mountPoint;
    } else {
      final disc = await showDialog<DvdDisc>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select DVD'),
          content: SizedBox(
            width: 300,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: discs.length,
              itemBuilder: (context, index) {
                final disc = discs[index];
                return ListTile(
                  leading: const Icon(Icons.album),
                  title: Text(disc.volumeLabel),
                  subtitle: Text(disc.mountPoint),
                  onTap: () => Navigator.pop(context, disc),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      if (disc == null || !context.mounted) return;
      mountPoint = disc.mountPoint;
    }

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Reading DVD structure...'),
          ],
        ),
      ),
    );

    try {
      final dvdInfo = await viewModel.getDvdInfo(mountPoint);

      if (!context.mounted) return;
      Navigator.of(context).pop(); // Close loading dialog

      final result = await DvdTitlePicker.show(
        context: context,
        dvdInfo: dvdInfo,
      );

      if (result != null) {
        viewModel.addDvdTitle(
          dvdInfo: dvdInfo,
          titleIndex: result.titleIndex,
          startChapter: result.startChapter,
          endChapter: result.endChapter,
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to read DVD: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
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

              final description = descriptionController.text.trim().isNotEmpty
                  ? descriptionController.text.trim()
                  : null;

              // Check for existing preset with same name
              final existing = PresetService.instance.findByName(name);
              if (existing != null && !existing.isBuiltIn && context.mounted) {
                final overwrite = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Overwrite Preset'),
                    content: Text('A preset named "$name" already exists. Overwrite it?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Overwrite'),
                      ),
                    ],
                  ),
                );
                if (overwrite != true) return;
                // Update existing preset
                await viewModel.updatePreset(existing.copyWith(
                  description: description,
                ));
              } else {
                await viewModel.saveAsPreset(name, description: description);
              }

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

    // Only check audio compatibility if audio passthrough is enabled
    if (viewModel.encodingSettings.audioMode != AudioMode.passthrough) {
      viewModel.startProcessing();
      return;
    }

    // Check audio compatibility
    final service = AudioCompatibilityService();
    final compatibility = await service.checkCompatibility(
      inputPath: viewModel.inputPath!,
      outputContainer: viewModel.encodingSettings.container,
      audioMode: viewModel.encodingSettings.audioMode,
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
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.values.firstWhere(
              (c) => c.value == compatibility.suggestedCodec,
              orElse: () => AudioCodec.aac,
            ),
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
