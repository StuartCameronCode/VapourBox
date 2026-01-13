import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/crop_resize_parameters.dart';
import '../../viewmodels/main_viewmodel.dart';

/// Settings panel for the crop/resize pass.
class CropResizeSettingsPanel extends StatelessWidget {
  const CropResizeSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.restorationPipeline.cropResize;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Crop / Resize Settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Crop borders and resize output',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 16),

            // Preset
            Text('Preset', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            DropdownButtonFormField<CropResizePreset>(
              value: params.preset,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: CropResizePreset.values.map((preset) {
                return DropdownMenuItem(
                  value: preset,
                  child: Text(_getPresetDisplayName(preset)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  final newParams = CropResizeParameters.fromPreset(value);
                  _updateParams(viewModel, newParams);
                }
              },
            ),
            const SizedBox(height: 4),
            Text(
              _getPresetDescription(params.preset),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),

            if (params.enabled) ...[
              const SizedBox(height: 16),

              // Crop settings
              ExpansionTile(
                title: const Text('Crop'),
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: params.cropEnabled,
                children: [
                  SwitchListTile(
                    title: const Text('Enable Crop'),
                    contentPadding: EdgeInsets.zero,
                    value: params.cropEnabled,
                    onChanged: (value) {
                      _updateParams(viewModel, params.copyWith(
                        cropEnabled: value,
                        preset: CropResizePreset.custom,
                      ));
                    },
                  ),

                  if (params.cropEnabled) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _buildCropField(context, 'Left', params.cropLeft, (v) {
                            _updateParams(viewModel, params.copyWith(
                              cropLeft: v,
                              preset: CropResizePreset.custom,
                            ));
                          }),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildCropField(context, 'Right', params.cropRight, (v) {
                            _updateParams(viewModel, params.copyWith(
                              cropRight: v,
                              preset: CropResizePreset.custom,
                            ));
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _buildCropField(context, 'Top', params.cropTop, (v) {
                            _updateParams(viewModel, params.copyWith(
                              cropTop: v,
                              preset: CropResizePreset.custom,
                            ));
                          }),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildCropField(context, 'Bottom', params.cropBottom, (v) {
                            _updateParams(viewModel, params.copyWith(
                              cropBottom: v,
                              preset: CropResizePreset.custom,
                            ));
                          }),
                        ),
                      ],
                    ),
                  ],
                ],
              ),

              // Resize settings
              ExpansionTile(
                title: const Text('Resize'),
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: params.resizeEnabled,
                children: [
                  SwitchListTile(
                    title: const Text('Enable Resize'),
                    contentPadding: EdgeInsets.zero,
                    value: params.resizeEnabled,
                    onChanged: (value) {
                      _updateParams(viewModel, params.copyWith(
                        resizeEnabled: value,
                        preset: CropResizePreset.custom,
                      ));
                    },
                  ),

                  if (params.resizeEnabled) ...[
                    const SizedBox(height: 8),

                    // Target dimensions
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            initialValue: params.targetWidth?.toString() ?? '',
                            decoration: const InputDecoration(
                              labelText: 'Width',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (value) {
                              final width = int.tryParse(value);
                              _updateParams(viewModel, params.copyWith(
                                targetWidth: width,
                                preset: CropResizePreset.custom,
                              ));
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            initialValue: params.targetHeight?.toString() ?? '',
                            decoration: const InputDecoration(
                              labelText: 'Height',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (value) {
                              final height = int.tryParse(value);
                              _updateParams(viewModel, params.copyWith(
                                targetHeight: height,
                                preset: CropResizePreset.custom,
                              ));
                            },
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    SwitchListTile(
                      title: const Text('Maintain Aspect Ratio'),
                      contentPadding: EdgeInsets.zero,
                      value: params.maintainAspect,
                      onChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          maintainAspect: value,
                          preset: CropResizePreset.custom,
                        ));
                      },
                    ),

                    // Resize kernel
                    const SizedBox(height: 8),
                    Text('Resize Algorithm', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<ResizeKernel>(
                      value: params.kernel,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items: const [
                        DropdownMenuItem(value: ResizeKernel.spline36, child: Text('Spline36 (Recommended)')),
                        DropdownMenuItem(value: ResizeKernel.lanczos, child: Text('Lanczos')),
                        DropdownMenuItem(value: ResizeKernel.bicubic, child: Text('Bicubic')),
                        DropdownMenuItem(value: ResizeKernel.bilinear, child: Text('Bilinear')),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          _updateParams(viewModel, params.copyWith(
                            kernel: value,
                            preset: CropResizePreset.custom,
                          ));
                        }
                      },
                    ),
                  ],
                ],
              ),

              // Upscale settings
              ExpansionTile(
                title: const Text('Integer Upscale'),
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: params.useIntegerUpscale,
                children: [
                  SwitchListTile(
                    title: const Text('Use Integer Upscale'),
                    subtitle: const Text('Use NNEDI3 for 2x/4x upscaling'),
                    contentPadding: EdgeInsets.zero,
                    value: params.useIntegerUpscale,
                    onChanged: (value) {
                      _updateParams(viewModel, params.copyWith(
                        useIntegerUpscale: value,
                        preset: CropResizePreset.custom,
                      ));
                    },
                  ),

                  if (params.useIntegerUpscale) ...[
                    const SizedBox(height: 8),

                    Text('Upscale Factor', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 2, label: Text('2x')),
                        ButtonSegment(value: 4, label: Text('4x')),
                      ],
                      selected: {params.upscaleFactor},
                      onSelectionChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          upscaleFactor: value.first,
                          preset: CropResizePreset.custom,
                        ));
                      },
                    ),

                    const SizedBox(height: 8),

                    Text('Upscale Method', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<UpscaleMethod>(
                      value: params.upscaleMethod,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items: const [
                        DropdownMenuItem(value: UpscaleMethod.nnedi3Rpow2, child: Text('NNEDI3 (Best Quality)')),
                        DropdownMenuItem(value: UpscaleMethod.eedi3Rpow2, child: Text('EEDI3')),
                        DropdownMenuItem(value: UpscaleMethod.spline36, child: Text('Spline36 (Fastest)')),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          _updateParams(viewModel, params.copyWith(
                            upscaleMethod: value,
                            preset: CropResizePreset.custom,
                          ));
                        }
                      },
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildCropField(BuildContext context, String label, int value, ValueChanged<int> onChanged) {
    return TextFormField(
      initialValue: value.toString(),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        suffixText: 'px',
      ),
      keyboardType: TextInputType.number,
      onChanged: (text) {
        final v = int.tryParse(text) ?? 0;
        onChanged(v);
      },
    );
  }

  String _getPresetDisplayName(CropResizePreset preset) {
    switch (preset) {
      case CropResizePreset.off:
        return 'Off';
      case CropResizePreset.removeOverscan:
        return 'Remove Overscan';
      case CropResizePreset.resize720p:
        return 'Resize to 720p';
      case CropResizePreset.resize1080p:
        return 'Resize to 1080p';
      case CropResizePreset.resize4k:
        return 'Upscale to 4K';
      case CropResizePreset.custom:
        return 'Custom';
    }
  }

  String _getPresetDescription(CropResizePreset preset) {
    switch (preset) {
      case CropResizePreset.off:
        return 'No cropping or resizing';
      case CropResizePreset.removeOverscan:
        return 'Crop 8px from each edge';
      case CropResizePreset.resize720p:
        return 'Resize to 1280x720';
      case CropResizePreset.resize1080p:
        return 'Resize to 1920x1080';
      case CropResizePreset.resize4k:
        return '2x upscale using NNEDI3';
      case CropResizePreset.custom:
        return 'Custom crop/resize settings';
    }
  }

  void _updateParams(MainViewModel viewModel, CropResizeParameters params) {
    viewModel.updateRestorationPipeline(
      viewModel.restorationPipeline.copyWith(cropResize: params),
    );
  }
}
