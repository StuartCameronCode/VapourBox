import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/deblock_parameters.dart';
import '../../viewmodels/main_viewmodel.dart';

/// Settings panel for the deblock pass.
class DeblockSettingsPanel extends StatelessWidget {
  const DeblockSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.restorationPipeline.deblock;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Deblock Settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Remove compression block artifacts',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 16),

            // Method selection
            Text('Method', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            DropdownButtonFormField<DeblockMethod>(
              value: params.method,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: DeblockMethod.values.map((method) {
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
            if (params.method == DeblockMethod.deblockQed)
              _buildQedSettings(context, viewModel, params)
            else
              _buildSimpleSettings(context, viewModel, params),
          ],
        );
      },
    );
  }

  Widget _buildQedSettings(BuildContext context, MainViewModel viewModel, DeblockParameters params) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Quant1 (edge strength)
        Text('Edge Strength: ${params.quant1}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.quant1.toDouble(),
          min: 0,
          max: 60,
          divisions: 60,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(quant1: value.round()));
          },
        ),

        // Quant2 (non-edge strength)
        Text('Non-Edge Strength: ${params.quant2}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.quant2.toDouble(),
          min: 0,
          max: 60,
          divisions: 60,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(quant2: value.round()));
          },
        ),

        // Advanced settings
        ExpansionTile(
          title: const Text('Advanced'),
          tilePadding: EdgeInsets.zero,
          children: [
            const SizedBox(height: 8),
            Text('Analyze Offset 1: ${params.aOffset1}',
                style: Theme.of(context).textTheme.labelLarge),
            Slider(
              value: params.aOffset1.toDouble(),
              min: -2,
              max: 6,
              divisions: 8,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(aOffset1: value.round()));
              },
            ),

            Text('Analyze Offset 2: ${params.aOffset2}',
                style: Theme.of(context).textTheme.labelLarge),
            Slider(
              value: params.aOffset2.toDouble(),
              min: -2,
              max: 6,
              divisions: 8,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(aOffset2: value.round()));
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSimpleSettings(BuildContext context, MainViewModel viewModel, DeblockParameters params) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Quant (strength)
        Text('Strength: ${params.quant1}',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: params.quant1.toDouble(),
          min: 0,
          max: 60,
          divisions: 60,
          onChanged: (value) {
            _updateParams(viewModel, params.copyWith(quant1: value.round()));
          },
        ),
      ],
    );
  }

  void _updateParams(MainViewModel viewModel, DeblockParameters params) {
    viewModel.updateRestorationPipeline(
      viewModel.restorationPipeline.copyWith(deblock: params),
    );
  }
}
