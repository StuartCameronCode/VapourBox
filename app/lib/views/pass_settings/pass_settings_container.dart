import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/dynamic_parameters.dart';
import '../../models/filter_registry.dart';
import '../../models/processing_pipeline.dart';
import '../../services/whisper_addon_manager.dart';
import '../../viewmodels/main_viewmodel.dart';
import '../settings/dynamic_filter_panel.dart';
import '../whisper_download_dialog.dart';

/// Container widget that shows the settings panel for the currently selected pass.
///
/// Uses schema-driven UI generation from FilterRegistry.
class PassSettingsContainer extends StatelessWidget {
  const PassSettingsContainer({super.key});

  /// Maps PassType to filter schema ID.
  static String _getFilterId(PassType passType) {
    switch (passType) {
      case PassType.deinterlace:
        return 'deinterlace';
      case PassType.descratch:
        return 'descratch';
      case PassType.noiseReduction:
        return 'noise_reduction';
      case PassType.dehalo:
        return 'dehalo';
      case PassType.deblock:
        return 'deblock';
      case PassType.deband:
        return 'deband';
      case PassType.sharpen:
        return 'sharpen';
      case PassType.colorCorrection:
        return 'color_correction';
      case PassType.chromaFixes:
        return 'chroma_fixes';
      case PassType.cropResize:
        return 'crop_resize';
      case PassType.subtitles:
        return 'subtitles';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final passType = viewModel.selectedPass;
        final filterId = _getFilterId(passType);
        final schema = FilterRegistry.instance.get(filterId);

        // If schema not found, show a fallback message
        if (schema == null) {
          return _buildFallbackPanel(context, passType);
        }

        // Use cached dynamic params from ViewModel (preserves null values)
        final params = viewModel.getDynamicParams(filterId);

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: SingleChildScrollView(
            key: ValueKey(filterId),
            child: DynamicFilterPanelCompact(
              schema: schema,
              params: params,
              onChanged: (newParams) {
                _handleParamChange(context, viewModel, filterId, params, newParams);
              },
            ),
          ),
        );
      },
    );
  }

  /// Handle parameter changes, with special model-download check for subtitles.
  void _handleParamChange(
    BuildContext context,
    MainViewModel viewModel,
    String filterId,
    DynamicParameters oldParams,
    DynamicParameters newParams,
  ) async {
    // When the subtitles model changes while subtitles is enabled,
    // check if the new model is downloaded.
    if (filterId == 'subtitles' &&
        newParams.enabled &&
        oldParams.values['model'] != newParams.values['model']) {
      final newModelId = newParams.values['model'] as String? ?? 'medium';
      final modelInstalled =
          await WhisperAddonManager.instance.isModelInstalled(newModelId);
      if (!modelInstalled) {
        if (!context.mounted) return;
        final confirmed =
            await WhisperConfirmDialog.show(context, modelId: newModelId);
        if (!confirmed) return;
        if (!context.mounted) return;
        final downloaded =
            await WhisperDownloadDialog.show(context, modelId: newModelId);
        if (!downloaded) return;
      }
    }
    viewModel.updateDynamicParams(filterId, newParams);
  }

  Widget _buildFallbackPanel(BuildContext context, PassType passType) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            'Filter schema not found',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Could not load settings for ${passType.displayName}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
