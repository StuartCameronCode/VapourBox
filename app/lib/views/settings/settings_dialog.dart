import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/encoding_settings.dart';
import '../../models/video_job.dart';
import '../../viewmodels/main_viewmodel.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 600,
          maxHeight: 700,
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color:
                        Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    'Settings',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Tab bar
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Input'),
                Tab(text: 'Output'),
              ],
            ),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: const [
                  _InputSettingsTab(),
                  _OutputSettingsTab(),
                ],
              ),
            ),

            // Footer
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color:
                        Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputSettingsTab extends StatelessWidget {
  const _InputSettingsTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Field Order
            _buildSection(
              context,
              title: 'Field Order',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    title: const Text('Auto-detect field order'),
                    subtitle: const Text('Use detected field order from video'),
                    value: viewModel.autoFieldOrder,
                    onChanged: (value) {
                      viewModel.setAutoFieldOrder(value);
                    },
                  ),
                  if (!viewModel.autoFieldOrder) ...[
                    const SizedBox(height: 8),
                    SegmentedButton<FieldOrder>(
                      segments: const [
                        ButtonSegment(
                          value: FieldOrder.topFieldFirst,
                          label: Text('TFF (Top Field First)'),
                        ),
                        ButtonSegment(
                          value: FieldOrder.bottomFieldFirst,
                          label: Text('BFF (Bottom Field First)'),
                        ),
                      ],
                      selected: {viewModel.manualFieldOrder},
                      onSelectionChanged: (value) {
                        viewModel.setManualFieldOrder(value.first);
                      },
                    ),
                  ],
                  if (viewModel.videoInfo?.fieldOrder != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Detected: ${viewModel.videoInfo!.fieldOrderDescription}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

class _OutputSettingsTab extends StatefulWidget {
  const _OutputSettingsTab();

  @override
  State<_OutputSettingsTab> createState() => _OutputSettingsTabState();
}

class _OutputSettingsTabState extends State<_OutputSettingsTab> {
  late TextEditingController _filenamePatternController;

  @override
  void initState() {
    super.initState();
    _filenamePatternController = TextEditingController();
  }

  @override
  void dispose() {
    _filenamePatternController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final settings = viewModel.encodingSettings;

        // Update controller if value changed externally
        if (_filenamePatternController.text != settings.filenamePattern) {
          _filenamePatternController.text = settings.filenamePattern;
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Output Directory
            _buildSection(
              context,
              title: 'Output Directory',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            settings.outputDirectory ?? 'Same as input file',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  fontFamily: 'monospace',
                                  fontStyle: settings.outputDirectory == null
                                      ? FontStyle.italic
                                      : FontStyle.normal,
                                ),
                          ),
                        ),
                        if (settings.outputDirectory != null)
                          IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              viewModel.updateEncodingSettings(
                                settings.copyWith(clearOutputDirectory: true),
                              );
                            },
                            tooltip: 'Use same directory as input',
                          ),
                        IconButton(
                          icon: const Icon(Icons.folder_open),
                          onPressed: () => _selectOutputDirectory(viewModel, settings),
                          tooltip: 'Choose directory',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Filename Pattern
            _buildSection(
              context,
              title: 'Output Filename Pattern',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _filenamePatternController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '{input_filename}_processed',
                    ),
                    onChanged: (value) {
                      if (value.isNotEmpty) {
                        viewModel.updateEncodingSettings(
                          settings.copyWith(filenamePattern: value),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Available placeholders:',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '{input_filename} - Original filename\n'
                    '{date} - Current date (YYYY-MM-DD)\n'
                    '{time} - Current time (HH-MM-SS)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                  if (viewModel.inputPath != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.preview,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Preview: ${viewModel.outputPath ?? ""}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                  ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Container Format
            _buildSection(
              context,
              title: 'Container Format',
              child: SegmentedButton<ContainerFormat>(
                segments: ContainerFormat.values.map((format) {
                  return ButtonSegment(
                    value: format,
                    label: Text(format.name.toUpperCase()),
                  );
                }).toList(),
                selected: {settings.container},
                onSelectionChanged: (value) {
                  final newContainer = value.first;
                  // If current codec isn't supported by new container, switch to first supported codec
                  var newCodec = settings.codec;
                  if (!newCodec.supportsContainer(newContainer)) {
                    newCodec = newContainer.supportedCodecs.first;
                  }
                  viewModel.updateEncodingSettings(
                      settings.copyWith(container: newContainer, codec: newCodec));
                },
              ),
            ),

            const SizedBox(height: 24),

            // Output path
            _buildSection(
              context,
              title: 'Output File',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (viewModel.outputPath != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              viewModel.outputPath!,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(fontFamily: 'monospace'),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.folder_open),
                            onPressed: () => _showInFolder(viewModel.outputPath!),
                            tooltip: 'Show in folder',
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    Text(
                      'Output path will be set when you select an input file',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
                          ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Video Codec (filtered by container)
            _buildSection(
              context,
              title: 'Video Codec',
              child: Column(
                children: VideoCodec.values.map((codec) {
                  final isSupported = codec.supportsContainer(settings.container);
                  return RadioListTile<VideoCodec>(
                    title: Text(
                      codec.displayName,
                      style: isSupported ? null : TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38),
                      ),
                    ),
                    subtitle: Text(
                      isSupported ? codec.description : 'Not supported in ${settings.container.name.toUpperCase()}',
                      style: isSupported ? null : TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38),
                      ),
                    ),
                    value: codec,
                    groupValue: settings.codec,
                    onChanged: isSupported ? (value) {
                      if (value != null) {
                        viewModel.updateEncodingSettings(
                            settings.copyWith(codec: value));
                      }
                    } : null,
                  );
                }).toList(),
              ),
            ),

            const SizedBox(height: 24),

            // Quality (not applicable for lossless codecs)
            if (!settings.codec.isFFV1)
              _buildSection(
                context,
                title: 'Quality',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Slider(
                      value: settings.quality.toDouble(),
                      min: 0,
                      max: 51,
                      divisions: 51,
                      label: settings.qualityDescription,
                      onChanged: (value) {
                        viewModel.updateEncodingSettings(
                            settings.copyWith(quality: value.round()));
                      },
                    ),
                    Text(
                      settings.qualityDescription,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      'Lower values = higher quality, larger file',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
                          ),
                    ),
                  ],
                ),
              ),

            // Note for lossless codec
            if (settings.codec.isFFV1)
              _buildSection(
                context,
                title: 'Quality',
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'FFV1 is a lossless codec. No quality setting is needed.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 24),

            // Audio
            _buildSection(
              context,
              title: 'Audio',
              child: SwitchListTile(
                title: const Text('Copy audio stream'),
                subtitle: const Text('Include original audio in output'),
                value: settings.copyAudio,
                onChanged: (value) {
                  viewModel.updateEncodingSettings(
                      settings.copyWith(copyAudio: value));
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _selectOutputDirectory(MainViewModel viewModel, EncodingSettings settings) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Output Directory',
      initialDirectory: settings.outputDirectory,
    );

    if (result != null) {
      viewModel.updateEncodingSettings(
        settings.copyWith(outputDirectory: result),
      );
    }
  }

  void _showInFolder(String path) {
    if (Platform.isMacOS) {
      Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      Process.run('explorer', ['/select,', path]);
    }
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}
