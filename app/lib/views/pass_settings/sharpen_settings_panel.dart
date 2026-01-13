import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sharpen_parameters.dart';
import '../../viewmodels/main_viewmodel.dart';

/// Settings panel for the sharpen pass.
class SharpenSettingsPanel extends StatelessWidget {
  const SharpenSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.restorationPipeline.sharpen;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Sharpen Settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Sharpen edges and enhance detail',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 16),

            // Method selection
            Text('Method', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            DropdownButtonFormField<SharpenMethod>(
              value: params.method,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: SharpenMethod.values.map((method) {
                return DropdownMenuItem(
                  value: method,
                  child: Text(method.displayName),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  _updateParams(viewModel, params.copyWith(method: value));
                }
              },
            ),
            const SizedBox(height: 4),
            Text(
              params.method.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),

            const SizedBox(height: 16),

            // Method-specific settings
            if (params.method == SharpenMethod.lsfmod)
              _buildLsfmodSettings(context, viewModel, params)
            else
              _buildCasSettings(context, viewModel, params),
          ],
        );
      },
    );
  }

  Widget _buildLsfmodSettings(BuildContext context, MainViewModel viewModel, SharpenParameters params) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Strength
        Text('Strength: ${params.strength}%',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.strength.toDouble(),
          min: 0,
          max: 200,
          divisions: 40,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(strength: value.round()));
          },
        ),

        const SizedBox(height: 8),

        // Advanced settings
        ExpansionTile(
          title: const Text('Overshoot Control'),
          tilePadding: EdgeInsets.zero,
          children: [
            const SizedBox(height: 8),

            // Overshoot (bright edges)
            Text('Bright Edge Limit: ${params.overshoot}',
                style: Theme.of(context).textTheme.labelLarge),
            Slider(
              value: params.overshoot.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(overshoot: value.round()));
              },
            ),

            // Undershoot (dark edges)
            Text('Dark Edge Limit: ${params.undershoot}',
                style: Theme.of(context).textTheme.labelLarge),
            Slider(
              value: params.undershoot.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(undershoot: value.round()));
              },
            ),

            // Soft edge threshold
            Text('Soft Edge Handling: ${params.softEdge}',
                style: Theme.of(context).textTheme.labelLarge),
            Slider(
              value: params.softEdge.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(softEdge: value.round()));
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCasSettings(BuildContext context, MainViewModel viewModel, SharpenParameters params) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // CAS Sharpness
        Text('Sharpness: ${(params.casSharpness * 100).round()}%',
            style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          'Higher values increase edge contrast',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
        ),
        Slider(
          value: params.casSharpness,
          min: 0.0,
          max: 1.0,
          divisions: 20,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(casSharpness: value));
          },
        ),
      ],
    );
  }

  void _updateParams(MainViewModel viewModel, SharpenParameters params) {
    viewModel.updateRestorationPipeline(
      viewModel.restorationPipeline.copyWith(sharpen: params),
    );
  }
}
