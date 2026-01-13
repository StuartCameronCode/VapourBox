import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/dehalo_parameters.dart';
import '../../viewmodels/main_viewmodel.dart';

/// Settings panel for the dehalo pass.
class DehaloSettingsPanel extends StatelessWidget {
  const DehaloSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.restorationPipeline.dehalo;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Dehalo Settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Remove halo artifacts around edges',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 16),

            // Method selection
            Text('Method', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            DropdownButtonFormField<DehaloMethod>(
              value: params.method,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: DehaloMethod.values.map((method) {
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
            if (params.method == DehaloMethod.yahr)
              _buildYahrSettings(context, viewModel, params)
            else
              _buildDehaloAlphaSettings(context, viewModel, params),
          ],
        );
      },
    );
  }

  Widget _buildDehaloAlphaSettings(BuildContext context, MainViewModel viewModel, DehaloParameters params) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Horizontal radius
        Text('Horizontal Radius: ${params.rx.toStringAsFixed(1)}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.rx,
          min: 1.0,
          max: 3.0,
          divisions: 20,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(rx: value));
          },
        ),

        // Vertical radius
        Text('Vertical Radius: ${params.ry.toStringAsFixed(1)}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.ry,
          min: 1.0,
          max: 3.0,
          divisions: 20,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(ry: value));
          },
        ),

        // Dark strength
        Text('Dark Halo Strength: ${params.darkStr.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.darkStr,
          min: 0.0,
          max: 1.0,
          divisions: 20,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(darkStr: value));
          },
        ),

        // Bright strength
        Text('Bright Halo Strength: ${params.brightStr.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.brightStr,
          min: 0.0,
          max: 1.0,
          divisions: 20,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(brightStr: value));
          },
        ),

        // FineDehalo-specific thresholds
        if (params.method == DehaloMethod.fineDehalo) ...[
          const SizedBox(height: 8),
          Text('Low Threshold: ${params.lowThreshold}',
              style: Theme.of(context).textTheme.labelLarge),
          Slider(
            value: params.lowThreshold.toDouble(),
            min: 0,
            max: 200,
            divisions: 40,
            onChanged: (value) {
              _updateParams(viewModel, params.copyWith(lowThreshold: value.round()));
            },
          ),

          Text('High Threshold: ${params.highThreshold}',
              style: Theme.of(context).textTheme.labelLarge),
          Slider(
            value: params.highThreshold.toDouble(),
            min: 0,
            max: 255,
            divisions: 51,
            onChanged: (value) {
              _updateParams(viewModel, params.copyWith(highThreshold: value.round()));
            },
          ),
        ],
      ],
    );
  }

  Widget _buildYahrSettings(BuildContext context, MainViewModel viewModel, DehaloParameters params) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Blur amount
        Text('Blur: ${params.yahrBlur}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.yahrBlur.toDouble(),
          min: 1,
          max: 3,
          divisions: 2,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(yahrBlur: value.round()));
          },
        ),

        // Depth
        Text('Depth: ${params.yahrDepth}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.yahrDepth.toDouble(),
          min: 8,
          max: 128,
          divisions: 15,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(yahrDepth: value.round()));
          },
        ),
      ],
    );
  }

  void _updateParams(MainViewModel viewModel, DehaloParameters params) {
    viewModel.updateRestorationPipeline(
      viewModel.restorationPipeline.copyWith(dehalo: params),
    );
  }
}
