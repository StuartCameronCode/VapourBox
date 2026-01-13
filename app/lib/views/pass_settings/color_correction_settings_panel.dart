import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/color_correction_parameters.dart';
import '../../viewmodels/main_viewmodel.dart';

/// Settings panel for the color correction pass.
class ColorCorrectionSettingsPanel extends StatelessWidget {
  const ColorCorrectionSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.restorationPipeline.colorCorrection;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Color Correction Settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Adjust brightness, contrast, and colors',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 16),

            // Preset
            Text('Preset', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            DropdownButtonFormField<ColorCorrectionPreset>(
              value: params.preset,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: ColorCorrectionPreset.values.map((preset) {
                return DropdownMenuItem(
                  value: preset,
                  child: Text(_getPresetDisplayName(preset)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  final newParams = ColorCorrectionParameters.fromPreset(value);
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

              // Basic adjustments
              Text('Brightness: ${params.brightness.toStringAsFixed(0)}',
                  style: Theme.of(context).textTheme.labelLarge),
              Slider(
                value: params.brightness,
                min: -50,
                max: 50,
                divisions: 100,
                onChanged: (value) {
                  _updateParams(viewModel, params.copyWith(
                    brightness: value,
                    preset: ColorCorrectionPreset.custom,
                  ));
                },
              ),

              Text('Contrast: ${params.contrast.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.labelLarge),
              Slider(
                value: params.contrast,
                min: 0.5,
                max: 2.0,
                divisions: 30,
                onChanged: (value) {
                  _updateParams(viewModel, params.copyWith(
                    contrast: value,
                    preset: ColorCorrectionPreset.custom,
                  ));
                },
              ),

              Text('Saturation: ${params.saturation.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.labelLarge),
              Slider(
                value: params.saturation,
                min: 0.0,
                max: 2.0,
                divisions: 40,
                onChanged: (value) {
                  _updateParams(viewModel, params.copyWith(
                    saturation: value,
                    preset: ColorCorrectionPreset.custom,
                  ));
                },
              ),

              Text('Hue: ${params.hue.toStringAsFixed(0)}°',
                  style: Theme.of(context).textTheme.labelLarge),
              Slider(
                value: params.hue,
                min: -180,
                max: 180,
                divisions: 72,
                onChanged: (value) {
                  _updateParams(viewModel, params.copyWith(
                    hue: value,
                    preset: ColorCorrectionPreset.custom,
                  ));
                },
              ),

              const SizedBox(height: 8),

              SwitchListTile(
                title: const Text('Clamp to TV Range'),
                subtitle: const Text('Limit output to 16-235'),
                contentPadding: EdgeInsets.zero,
                value: params.coring,
                onChanged: (value) {
                  _updateParams(viewModel, params.copyWith(
                    coring: value,
                    preset: ColorCorrectionPreset.custom,
                  ));
                },
              ),

              // Advanced - Levels
              ExpansionTile(
                title: const Text('Levels'),
                tilePadding: EdgeInsets.zero,
                children: [
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Apply Levels'),
                    contentPadding: EdgeInsets.zero,
                    value: params.applyLevels,
                    onChanged: (value) {
                      _updateParams(viewModel, params.copyWith(
                        applyLevels: value,
                        preset: ColorCorrectionPreset.custom,
                      ));
                    },
                  ),

                  if (params.applyLevels) ...[
                    Text('Input Low: ${params.inputLow}',
                        style: Theme.of(context).textTheme.labelLarge),
                    Slider(
                      value: params.inputLow.toDouble(),
                      min: 0,
                      max: 255,
                      divisions: 255,
                      onChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          inputLow: value.round(),
                          preset: ColorCorrectionPreset.custom,
                        ));
                      },
                    ),

                    Text('Input High: ${params.inputHigh}',
                        style: Theme.of(context).textTheme.labelLarge),
                    Slider(
                      value: params.inputHigh.toDouble(),
                      min: 0,
                      max: 255,
                      divisions: 255,
                      onChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          inputHigh: value.round(),
                          preset: ColorCorrectionPreset.custom,
                        ));
                      },
                    ),

                    Text('Gamma: ${params.gamma.toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.labelLarge),
                    Slider(
                      value: params.gamma,
                      min: 0.5,
                      max: 2.0,
                      divisions: 30,
                      onChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          gamma: value,
                          preset: ColorCorrectionPreset.custom,
                        ));
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

  String _getPresetDisplayName(ColorCorrectionPreset preset) {
    switch (preset) {
      case ColorCorrectionPreset.off:
        return 'Off';
      case ColorCorrectionPreset.broadcastSafe:
        return 'Broadcast Safe';
      case ColorCorrectionPreset.enhanceColors:
        return 'Enhance Colors';
      case ColorCorrectionPreset.desaturate:
        return 'Desaturate';
      case ColorCorrectionPreset.custom:
        return 'Custom';
    }
  }

  String _getPresetDescription(ColorCorrectionPreset preset) {
    switch (preset) {
      case ColorCorrectionPreset.off:
        return 'No color correction applied';
      case ColorCorrectionPreset.broadcastSafe:
        return 'Clamp levels to broadcast-safe range';
      case ColorCorrectionPreset.enhanceColors:
        return 'Boost contrast and saturation';
      case ColorCorrectionPreset.desaturate:
        return 'Convert to grayscale';
      case ColorCorrectionPreset.custom:
        return 'Custom color adjustments';
    }
  }

  void _updateParams(MainViewModel viewModel, ColorCorrectionParameters params) {
    viewModel.updateRestorationPipeline(
      viewModel.restorationPipeline.copyWith(colorCorrection: params),
    );
  }
}
