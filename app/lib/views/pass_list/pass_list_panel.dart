import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/processing_pipeline.dart';
import '../../services/whisper_addon_manager.dart';
import '../../viewmodels/main_viewmodel.dart';
import '../pass_settings/pass_settings_inline.dart';
import '../whisper_download_dialog.dart';
import 'pass_list_item.dart';

/// Panel showing the list of processing passes that can be enabled/disabled.
///
/// Each pass expands in place to reveal its settings — only one at a time, and
/// only the expanded pass's settings are built.
class PassListPanel extends StatelessWidget {
  const PassListPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final pipeline = viewModel.processingPipeline;

        /// Builds one row, wiring up expansion and the inline settings.
        Widget item(
          PassType passType,
          String title,
          String subtitle,
          bool isEnabled, {
          ValueChanged<bool>? onToggle,
        }) {
          final isExpanded = viewModel.selectedPass == passType;
          return PassListItem(
            passType: passType,
            title: title,
            subtitle: subtitle,
            isEnabled: isEnabled,
            isExpanded: isExpanded,
            onToggle: onToggle ?? (enabled) => viewModel.togglePass(passType, enabled),
            onTap: () => viewModel.selectPass(passType),
            expandedChild: isExpanded ? PassSettingsInline(passType: passType) : null,
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Pass list header
            Text(
              'Video Pipeline',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),

            // List of passes
            item(
              PassType.deinterlace,
              'Deinterlace',
              _getDeinterlaceSummary(pipeline),
              pipeline.deinterlace.enabled,
            ),

            item(
              PassType.descratch,
              'DeScratch',
              pipeline.descratch.summary,
              pipeline.descratch.enabled,
            ),

            item(
              PassType.spotless,
              'SpotLess',
              pipeline.spotless.summary,
              pipeline.spotless.enabled,
            ),

            item(
              PassType.noiseReduction,
              'Noise Reduction',
              pipeline.noiseReduction.summary,
              pipeline.noiseReduction.enabled,
            ),

            item(
              PassType.chromaDenoise,
              'Chroma Denoise',
              pipeline.chromaDenoise.summary,
              pipeline.chromaDenoise.enabled,
            ),

            item(
              PassType.dehalo,
              'Dehalo',
              pipeline.dehalo.summary,
              pipeline.dehalo.enabled,
            ),

            item(
              PassType.deblock,
              'Deblock',
              pipeline.deblock.summary,
              pipeline.deblock.enabled,
            ),

            item(
              PassType.deband,
              'Deband',
              pipeline.deband.summary,
              pipeline.deband.enabled,
            ),

            item(
              PassType.sharpen,
              'Sharpen',
              pipeline.sharpen.summary,
              pipeline.sharpen.enabled,
            ),

            item(
              PassType.chromaFixes,
              'Chroma Fixes',
              pipeline.chromaFixes.summary,
              pipeline.chromaFixes.enabled,
            ),

            item(
              PassType.colorCorrection,
              'Color Correction',
              pipeline.colorCorrection.summary,
              pipeline.colorCorrection.enabled,
            ),

            item(
              PassType.cropResize,
              'Crop / Resize',
              pipeline.cropResize.summary,
              pipeline.cropResize.enabled,
            ),

            // Post-Processing section
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                'Post-Processing',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),

            item(
              PassType.subtitles,
              'Subtitles',
              pipeline.subtitles.summary,
              pipeline.subtitles.enabled,
              onToggle: (enabled) => _handleSubtitlesToggle(context, viewModel, enabled),
            ),

            const SizedBox(height: 16),

            // Pass count summary
            Text(
              _getPassSummary(pipeline),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleSubtitlesToggle(
    BuildContext context,
    MainViewModel viewModel,
    bool enabled,
  ) async {
    if (enabled) {
      final isInstalled = await WhisperAddonManager.instance.isInstalled;
      final modelId = viewModel.processingPipeline.subtitles.model.value;
      final modelInstalled =
          await WhisperAddonManager.instance.isModelInstalled(modelId);

      if (!isInstalled || !modelInstalled) {
        if (!context.mounted) return;
        final confirmed =
            await WhisperConfirmDialog.show(context, modelId: modelId);
        if (!confirmed) return;
        if (!context.mounted) return;
        final downloaded =
            await WhisperDownloadDialog.show(context, modelId: modelId);
        if (!downloaded) return;
      }
    }
    viewModel.togglePass(PassType.subtitles, enabled);
  }

  String _getPassSummary(ProcessingPipeline pipeline) {
    final videoCount = pipeline.videoPassCount;
    final hasSubtitles = pipeline.subtitles.enabled;

    if (videoCount > 0 && hasSubtitles) {
      return '$videoCount video pass${videoCount == 1 ? '' : 'es'}, subtitles enabled';
    } else if (videoCount > 0) {
      return '$videoCount pass${videoCount == 1 ? '' : 'es'} enabled';
    } else if (hasSubtitles) {
      return 'Subtitle generation only';
    } else {
      return 'Format conversion only';
    }
  }

  String _getDeinterlaceSummary(ProcessingPipeline pipeline) {
    if (!pipeline.deinterlace.enabled) return 'Off';
    return pipeline.deinterlace.preset.displayName;
  }
}
