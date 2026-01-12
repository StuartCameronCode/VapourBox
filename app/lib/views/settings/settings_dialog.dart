import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/encoding_settings.dart';
import '../../models/qtgmc_parameters.dart';
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
    _tabController = TabController(length: 3, vsync: this);
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
                Tab(text: 'QTGMC'),
                Tab(text: 'Encoding'),
                Tab(text: 'Input/Output'),
              ],
            ),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: const [
                  _QtgmcSettingsTab(),
                  _EncodingSettingsTab(),
                  _InputOutputSettingsTab(),
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

class _QtgmcSettingsTab extends StatelessWidget {
  const _QtgmcSettingsTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.qtgmcParams;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Preset
            _buildSection(
              context,
              title: 'Preset',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<QTGMCPreset>(
                    value: params.preset,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    items: QTGMCPreset.values.map((preset) {
                      return DropdownMenuItem(
                        value: preset,
                        child: Text(preset.displayName),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        viewModel.updateQtgmcParams(params.copyWith(preset: value));
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    params.preset.description,
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

            const SizedBox(height: 24),

            // Frame Rate
            _buildSection(
              context,
              title: 'Frame Rate Output',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                        value: 1,
                        label: Text('Double Rate'),
                      ),
                      ButtonSegment(
                        value: 2,
                        label: Text('Single Rate'),
                      ),
                    ],
                    selected: {params.fpsDivisor},
                    onSelectionChanged: (value) {
                      viewModel.updateQtgmcParams(
                          params.copyWith(fpsDivisor: value.first));
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    params.fpsDivisor == 1
                        ? 'Double rate: 50i → 50p (recommended for smooth motion)'
                        : 'Single rate: 50i → 25p (smaller file, film-like)',
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

            const SizedBox(height: 24),

            // GPU Acceleration
            _buildSection(
              context,
              title: 'GPU Acceleration',
              child: SwitchListTile(
                title: const Text('Use OpenCL'),
                subtitle: const Text('Enable GPU acceleration for NNEDI3'),
                value: params.opencl,
                onChanged: (value) {
                  viewModel.updateQtgmcParams(params.copyWith(opencl: value));
                },
              ),
            ),

            const SizedBox(height: 24),

            // Advanced section (collapsed by default)
            ExpansionTile(
              title: const Text('Advanced Settings'),
              children: [
                // Source Match
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Source Match'),
                      const SizedBox(height: 8),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 0, label: Text('Off')),
                          ButtonSegment(value: 1, label: Text('Basic')),
                          ButtonSegment(value: 2, label: Text('Refined')),
                          ButtonSegment(value: 3, label: Text('Full')),
                        ],
                        selected: {params.sourceMatch},
                        onSelectionChanged: (value) {
                          viewModel.updateQtgmcParams(
                              params.copyWith(sourceMatch: value.first));
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Higher values produce more accurate results but are slower',
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

                // Sharpness
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Sharpness'),
                      Slider(
                        value: params.sharpness ?? 0.0,
                        min: 0.0,
                        max: 2.0,
                        divisions: 20,
                        label: (params.sharpness ?? 0.0).toStringAsFixed(1),
                        onChanged: (value) {
                          viewModel.updateQtgmcParams(
                              params.copyWith(sharpness: value));
                        },
                      ),
                    ],
                  ),
                ),
              ],
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

class _EncodingSettingsTab extends StatelessWidget {
  const _EncodingSettingsTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final settings = viewModel.encodingSettings;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Video Codec
            _buildSection(
              context,
              title: 'Video Codec',
              child: Column(
                children: VideoCodec.values.map((codec) {
                  return RadioListTile<VideoCodec>(
                    title: Text(codec.displayName),
                    subtitle: Text(codec.description),
                    value: codec,
                    groupValue: settings.codec,
                    onChanged: (value) {
                      if (value != null) {
                        viewModel.updateEncodingSettings(
                            settings.copyWith(codec: value));
                      }
                    },
                  );
                }).toList(),
              ),
            ),

            const SizedBox(height: 24),

            // Quality
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

            const SizedBox(height: 24),

            // Container
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
                  viewModel.updateEncodingSettings(
                      settings.copyWith(container: value.first));
                },
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

class _InputOutputSettingsTab extends StatelessWidget {
  const _InputOutputSettingsTab();

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

            const SizedBox(height: 24),

            // Output path
            _buildSection(
              context,
              title: 'Output',
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
                            onPressed: () {
                              // Would open file picker to change output path
                            },
                            tooltip: 'Change output location',
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
