import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/qtgmc_parameters.dart';
import '../../viewmodels/main_viewmodel.dart';

/// Settings panel for the deinterlace (QTGMC) pass.
class DeinterlaceSettingsPanel extends StatelessWidget {
  const DeinterlaceSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.restorationPipeline.deinterlace;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Deinterlace Settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Remove interlacing artifacts using QTGMC',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 16),

            // Preset
            Text('Preset', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            DropdownButtonFormField<QTGMCPreset>(
              value: params.preset,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: QTGMCPreset.values.map((preset) {
                return DropdownMenuItem(
                  value: preset,
                  child: Text(preset.displayName),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  _updateParams(viewModel, params.copyWith(preset: value));
                }
              },
            ),
            const SizedBox(height: 4),
            Text(
              params.preset.description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),

            const SizedBox(height: 16),

            // Frame Rate Output
            Text('Frame Rate Output', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Double Rate')),
                ButtonSegment(value: 2, label: Text('Single Rate')),
              ],
              selected: {params.fpsDivisor},
              onSelectionChanged: (value) {
                _updateParams(viewModel, params.copyWith(fpsDivisor: value.first));
              },
            ),
            const SizedBox(height: 4),
            Text(
              params.fpsDivisor == 1
                  ? '50i → 50p (smooth motion)'
                  : '50i → 25p (smaller file)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),

            const SizedBox(height: 16),

            // GPU Acceleration
            SwitchListTile(
              title: const Text('OpenCL Acceleration'),
              subtitle: const Text('Use GPU for NNEDI3'),
              value: params.opencl,
              contentPadding: EdgeInsets.zero,
              onChanged: (value) {
                _updateParams(viewModel, params.copyWith(opencl: value));
              },
            ),

            const SizedBox(height: 8),

            // Advanced settings expansion
            ExpansionTile(
              title: const Text('Advanced'),
              tilePadding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 8),

                // Source Match
                Text('Source Match', style: Theme.of(context).textTheme.labelLarge),
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
                    _updateParams(viewModel, params.copyWith(sourceMatch: value.first));
                  },
                ),
                const SizedBox(height: 16),

                // Sharpness
                Text('Sharpness: ${(params.sharpness ?? 0.0).toStringAsFixed(1)}',
                    style: Theme.of(context).textTheme.labelLarge),
                Slider(
                  value: params.sharpness ?? 0.0,
                  min: 0.0,
                  max: 2.0,
                  divisions: 20,
                  onChanged: (value) {
                    _updateParams(viewModel, params.copyWith(sharpness: value));
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ],
        );
      },
    );
  }

  void _updateParams(MainViewModel viewModel, QTGMCParameters params) {
    viewModel.updateRestorationPipeline(
      viewModel.restorationPipeline.copyWith(deinterlace: params),
    );
  }
}
