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
      case PassType.spotless:
        return 'spotless';
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildOpenCLWarning(context, viewModel, filterId, params),
                DynamicFilterPanelCompact(
                  schema: schema,
                  params: params,
                  onChanged: (newParams) {
                    _handleParamChange(context, viewModel, filterId, params, newParams);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Warning shown when the deinterlace pass uses an OpenCL-only option that
  /// won't run on this machine: the "knlmeanscl" denoiser (gated on the
  /// knlmeanscl-specific probe) or the QTGMC OpenCL toggle (gated on the
  /// NNEDI3CL probe). These are distinct capabilities — KNLMeansCL can fail
  /// where NNEDI3CL succeeds — so each uses its own probe result. The worker
  /// falls back automatically in both cases; this just tells the user why.
  /// Returns an empty widget when not applicable (incl. while probing).
  Widget _buildOpenCLWarning(
    BuildContext context,
    MainViewModel viewModel,
    String filterId,
    DynamicParameters params,
  ) {
    if (filterId != 'deinterlace') return const SizedBox.shrink();

    // knlmeanscl uses its own probe; the QTGMC OpenCL toggle uses the OpenCL
    // (NNEDI3CL) probe. `== false` excludes the still-probing null state.
    final knlmUnavailable =
        params.values['denoiser'] == 'knlmeanscl' && viewModel.knlmAvailable == false;
    final openclUnavailable =
        params.values['opencl'] == true && viewModel.openclAvailable == false;
    if (!knlmUnavailable && !openclUnavailable) return const SizedBox.shrink();

    final message = knlmUnavailable
        ? 'No usable OpenCL device for KNLMeansCL detected. The "knlmeanscl" '
            'denoiser will automatically fall back to dfttest on this machine.'
        : 'No OpenCL device detected. OpenCL acceleration will fall back to '
            'CPU NNEDI3.';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
              ),
            ),
          ],
        ),
      ),
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
