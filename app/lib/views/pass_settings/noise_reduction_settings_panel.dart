import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/noise_reduction_parameters.dart';
import '../../viewmodels/main_viewmodel.dart';

/// Settings panel for the noise reduction pass.
class NoiseReductionSettingsPanel extends StatelessWidget {
  const NoiseReductionSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.restorationPipeline.noiseReduction;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Noise Reduction Settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Reduce video noise and grain',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 16),

            // Preset
            Text('Preset', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<NoiseReductionPreset>(
              segments: const [
                ButtonSegment(value: NoiseReductionPreset.off, label: Text('Off')),
                ButtonSegment(value: NoiseReductionPreset.light, label: Text('Light')),
                ButtonSegment(value: NoiseReductionPreset.moderate, label: Text('Moderate')),
                ButtonSegment(value: NoiseReductionPreset.heavy, label: Text('Heavy')),
              ],
              selected: {params.preset},
              onSelectionChanged: (value) {
                final preset = value.first;
                final newParams = NoiseReductionParameters.fromPreset(preset);
                _updateParams(viewModel, newParams);
              },
            ),
            const SizedBox(height: 4),
            Text(
              _getPresetDescription(params.preset),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),

            // Show advanced options if enabled and using custom preset
            if (params.enabled) ...[
              const SizedBox(height: 16),

              // Method selection
              Text('Method', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              DropdownButtonFormField<NoiseReductionMethod>(
                value: params.method,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: const [
                  DropdownMenuItem(
                    value: NoiseReductionMethod.smDegrain,
                    child: Text('SMDegrain (Recommended)'),
                  ),
                  DropdownMenuItem(
                    value: NoiseReductionMethod.mcTemporalDenoise,
                    child: Text('MCTemporalDenoise'),
                  ),
                  DropdownMenuItem(
                    value: NoiseReductionMethod.qtgmcBuiltin,
                    child: Text('QTGMC Built-in'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    _updateParams(viewModel, params.copyWith(
                      method: value,
                      preset: NoiseReductionPreset.custom,
                    ));
                  }
                },
              ),

              const SizedBox(height: 8),

              // Advanced settings
              ExpansionTile(
                title: const Text('Advanced'),
                tilePadding: EdgeInsets.zero,
                children: [
                  const SizedBox(height: 8),
                  _buildMethodSettings(context, viewModel, params),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildMethodSettings(BuildContext context, MainViewModel viewModel, NoiseReductionParameters params) {
    switch (params.method) {
      case NoiseReductionMethod.smDegrain:
        return _buildSmDegrainSettings(context, viewModel, params);
      case NoiseReductionMethod.mcTemporalDenoise:
        return _buildMcTemporalSettings(context, viewModel, params);
      case NoiseReductionMethod.qtgmcBuiltin:
        return _buildQtgmcBuiltinSettings(context, viewModel, params);
    }
  }

  Widget _buildSmDegrainSettings(BuildContext context, MainViewModel viewModel, NoiseReductionParameters params) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Temporal Radius
        Text('Temporal Radius: ${params.smDegrainTr}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.smDegrainTr.toDouble(),
          min: 1,
          max: 6,
          divisions: 5,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(
              smDegrainTr: value.round(),
              preset: NoiseReductionPreset.custom,
            ));
          },
        ),

        // Threshold SAD (Luma)
        Text('Luma Threshold: ${params.smDegrainThSAD}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.smDegrainThSAD.toDouble(),
          min: 100,
          max: 800,
          divisions: 14,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(
              smDegrainThSAD: value.round(),
              preset: NoiseReductionPreset.custom,
            ));
          },
        ),

        // Threshold SAD (Chroma)
        Text('Chroma Threshold: ${params.smDegrainThSADC}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.smDegrainThSADC.toDouble(),
          min: 50,
          max: 400,
          divisions: 7,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(
              smDegrainThSADC: value.round(),
              preset: NoiseReductionPreset.custom,
            ));
          },
        ),

        SwitchListTile(
          title: const Text('Refine Motion'),
          contentPadding: EdgeInsets.zero,
          value: params.smDegrainRefine,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(
              smDegrainRefine: value,
              preset: NoiseReductionPreset.custom,
            ));
          },
        ),
      ],
    );
  }

  Widget _buildMcTemporalSettings(BuildContext context, MainViewModel viewModel, NoiseReductionParameters params) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sigma: ${params.mcTemporalSigma.toStringAsFixed(1)}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.mcTemporalSigma,
          min: 1.0,
          max: 10.0,
          divisions: 18,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(
              mcTemporalSigma: value,
              preset: NoiseReductionPreset.custom,
            ));
          },
        ),

        Text('Temporal Radius: ${params.mcTemporalRadius}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.mcTemporalRadius.toDouble(),
          min: 1,
          max: 4,
          divisions: 3,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(
              mcTemporalRadius: value.round(),
              preset: NoiseReductionPreset.custom,
            ));
          },
        ),
      ],
    );
  }

  Widget _buildQtgmcBuiltinSettings(BuildContext context, MainViewModel viewModel, NoiseReductionParameters params) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('EZDenoise: ${params.qtgmcEzDenoise.toStringAsFixed(1)}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.qtgmcEzDenoise,
          min: 0.0,
          max: 5.0,
          divisions: 50,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(
              qtgmcEzDenoise: value,
              preset: NoiseReductionPreset.custom,
            ));
          },
        ),

        Text('Keep Grain: ${params.qtgmcEzKeepGrain.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.qtgmcEzKeepGrain,
          min: 0.0,
          max: 1.0,
          divisions: 20,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(
              qtgmcEzKeepGrain: value,
              preset: NoiseReductionPreset.custom,
            ));
          },
        ),
      ],
    );
  }

  String _getPresetDescription(NoiseReductionPreset preset) {
    switch (preset) {
      case NoiseReductionPreset.off:
        return 'No noise reduction applied';
      case NoiseReductionPreset.light:
        return 'Subtle denoising, preserves detail';
      case NoiseReductionPreset.moderate:
        return 'Balanced noise reduction';
      case NoiseReductionPreset.heavy:
        return 'Strong denoising for noisy sources';
      case NoiseReductionPreset.custom:
        return 'Custom settings';
    }
  }

  void _updateParams(MainViewModel viewModel, NoiseReductionParameters params) {
    viewModel.updateRestorationPipeline(
      viewModel.restorationPipeline.copyWith(noiseReduction: params),
    );
  }
}
