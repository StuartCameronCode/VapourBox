import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/restoration_pipeline.dart';
import '../../viewmodels/main_viewmodel.dart';
import 'pass_list_item.dart';

/// Panel showing the list of restoration passes that can be enabled/disabled.
class PassListPanel extends StatelessWidget {
  const PassListPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final pipeline = viewModel.restorationPipeline;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Pass list header
            Text(
              'Restoration Pipeline',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),

            // List of passes
            PassListItem(
              passType: PassType.deinterlace,
              title: 'Deinterlace',
              subtitle: _getDeinterlaceSummary(pipeline),
              isEnabled: pipeline.deinterlace.enabled,
              isSelected: viewModel.selectedPass == PassType.deinterlace,
              onToggle: (enabled) => viewModel.togglePass(PassType.deinterlace, enabled),
              onTap: () => viewModel.selectPass(PassType.deinterlace),
            ),

            PassListItem(
              passType: PassType.noiseReduction,
              title: 'Noise Reduction',
              subtitle: pipeline.noiseReduction.summary,
              isEnabled: pipeline.noiseReduction.enabled,
              isSelected: viewModel.selectedPass == PassType.noiseReduction,
              onToggle: (enabled) => viewModel.togglePass(PassType.noiseReduction, enabled),
              onTap: () => viewModel.selectPass(PassType.noiseReduction),
            ),

            PassListItem(
              passType: PassType.dehalo,
              title: 'Dehalo',
              subtitle: pipeline.dehalo.summary,
              isEnabled: pipeline.dehalo.enabled,
              isSelected: viewModel.selectedPass == PassType.dehalo,
              onToggle: (enabled) => viewModel.togglePass(PassType.dehalo, enabled),
              onTap: () => viewModel.selectPass(PassType.dehalo),
            ),

            PassListItem(
              passType: PassType.deblock,
              title: 'Deblock',
              subtitle: pipeline.deblock.summary,
              isEnabled: pipeline.deblock.enabled,
              isSelected: viewModel.selectedPass == PassType.deblock,
              onToggle: (enabled) => viewModel.togglePass(PassType.deblock, enabled),
              onTap: () => viewModel.selectPass(PassType.deblock),
            ),

            PassListItem(
              passType: PassType.deband,
              title: 'Deband',
              subtitle: pipeline.deband.summary,
              isEnabled: pipeline.deband.enabled,
              isSelected: viewModel.selectedPass == PassType.deband,
              onToggle: (enabled) => viewModel.togglePass(PassType.deband, enabled),
              onTap: () => viewModel.selectPass(PassType.deband),
            ),

            PassListItem(
              passType: PassType.sharpen,
              title: 'Sharpen',
              subtitle: pipeline.sharpen.summary,
              isEnabled: pipeline.sharpen.enabled,
              isSelected: viewModel.selectedPass == PassType.sharpen,
              onToggle: (enabled) => viewModel.togglePass(PassType.sharpen, enabled),
              onTap: () => viewModel.selectPass(PassType.sharpen),
            ),

            PassListItem(
              passType: PassType.chromaFixes,
              title: 'Chroma Fixes',
              subtitle: pipeline.chromaFixes.summary,
              isEnabled: pipeline.chromaFixes.enabled,
              isSelected: viewModel.selectedPass == PassType.chromaFixes,
              onToggle: (enabled) => viewModel.togglePass(PassType.chromaFixes, enabled),
              onTap: () => viewModel.selectPass(PassType.chromaFixes),
            ),

            PassListItem(
              passType: PassType.colorCorrection,
              title: 'Color Correction',
              subtitle: pipeline.colorCorrection.summary,
              isEnabled: pipeline.colorCorrection.enabled,
              isSelected: viewModel.selectedPass == PassType.colorCorrection,
              onToggle: (enabled) => viewModel.togglePass(PassType.colorCorrection, enabled),
              onTap: () => viewModel.selectPass(PassType.colorCorrection),
            ),

            PassListItem(
              passType: PassType.cropResize,
              title: 'Crop / Resize',
              subtitle: pipeline.cropResize.summary,
              isEnabled: pipeline.cropResize.enabled,
              isSelected: viewModel.selectedPass == PassType.cropResize,
              onToggle: (enabled) => viewModel.togglePass(PassType.cropResize, enabled),
              onTap: () => viewModel.selectPass(PassType.cropResize),
            ),

            const SizedBox(height: 16),

            // Pass count summary
            Text(
              '${pipeline.enabledPassCount} pass${pipeline.enabledPassCount == 1 ? '' : 'es'} enabled',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
          ],
        );
      },
    );
  }

  String _getDeinterlaceSummary(RestorationPipeline pipeline) {
    if (!pipeline.deinterlace.enabled) return 'Off';
    return pipeline.deinterlace.preset.displayName;
  }
}
