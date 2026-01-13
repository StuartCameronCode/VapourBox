import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/deband_parameters.dart';
import '../../viewmodels/main_viewmodel.dart';

/// Settings panel for the deband pass (f3kdb).
class DebandSettingsPanel extends StatelessWidget {
  const DebandSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.restorationPipeline.deband;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Deband Settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Remove color banding from gradients (f3kdb)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 16),

            // Range
            Text('Detection Range: ${params.range}',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              'Higher values detect wider bands',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            Slider(
              value: params.range.toDouble(),
              min: 8,
              max: 128,
              divisions: 24,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(range: value.round()));
              },
            ),

            const SizedBox(height: 8),

            // Luma strength
            Text('Luma Strength: ${params.y}',
                style: Theme.of(context).textTheme.labelLarge),
            Slider(
              value: params.y.toDouble(),
              min: 0,
              max: 64,
              divisions: 64,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(y: value.round()));
              },
            ),

            // Chroma strength
            Text('Chroma Blue Strength: ${params.cb}',
                style: Theme.of(context).textTheme.labelLarge),
            Slider(
              value: params.cb.toDouble(),
              min: 0,
              max: 64,
              divisions: 64,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(cb: value.round()));
              },
            ),

            Text('Chroma Red Strength: ${params.cr}',
                style: Theme.of(context).textTheme.labelLarge),
            Slider(
              value: params.cr.toDouble(),
              min: 0,
              max: 64,
              divisions: 64,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(cr: value.round()));
              },
            ),

            const SizedBox(height: 16),

            // Grain settings
            ExpansionTile(
              title: const Text('Dither Grain'),
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: true,
              children: [
                const SizedBox(height: 8),

                Text('Luma Grain: ${params.grainY}',
                    style: Theme.of(context).textTheme.labelLarge),
                Slider(
                  value: params.grainY.toDouble(),
                  min: 0,
                  max: 64,
                  divisions: 64,
                  onChanged: (value) {
                    _updateParams(viewModel, params.copyWith(grainY: value.round()));
                  },
                ),

                Text('Chroma Grain: ${params.grainC}',
                    style: Theme.of(context).textTheme.labelLarge),
                Slider(
                  value: params.grainC.toDouble(),
                  min: 0,
                  max: 64,
                  divisions: 64,
                  onChanged: (value) {
                    _updateParams(viewModel, params.copyWith(grainC: value.round()));
                  },
                ),

                SwitchListTile(
                  title: const Text('Dynamic Grain'),
                  subtitle: const Text('Grain changes per frame'),
                  contentPadding: EdgeInsets.zero,
                  value: params.dynamicGrain,
                  onChanged: (value) {
                    _updateParams(viewModel, params.copyWith(dynamicGrain: value));
                  },
                ),
              ],
            ),

            // Output depth
            ExpansionTile(
              title: const Text('Advanced'),
              tilePadding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 8),
                Text('Output Bit Depth', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 8, label: Text('8-bit')),
                    ButtonSegment(value: 10, label: Text('10-bit')),
                    ButtonSegment(value: 16, label: Text('16-bit')),
                  ],
                  selected: {params.outputDepth},
                  onSelectionChanged: (value) {
                    _updateParams(viewModel, params.copyWith(outputDepth: value.first));
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _updateParams(MainViewModel viewModel, DebandParameters params) {
    viewModel.updateRestorationPipeline(
      viewModel.restorationPipeline.copyWith(deband: params),
    );
  }
}
