import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/pass_relevance.dart';
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
///
/// The rows are grouped into stages under headers. The order of the list is the
/// order the passes actually run in, so **the groups have to be contiguous runs
/// of that order** — they are labels over the existing sequence, not a
/// reordering. Nothing here may change which pass runs when; that lives in
/// `script_generator.rs`. Grouping is what keeps the panel scannable as passes
/// are added: five labelled stages read as shorter than thirteen ungrouped
/// rows, and the count beside each header shows where something is switched on
/// without reading every row.
class PassListPanel extends StatelessWidget {
  const PassListPanel({super.key});

  /// The stage labels and the passes under each, in pipeline order.
  ///
  /// Public so `pass_list_stages_test.dart` can assert it covers every
  /// [PassType] exactly once — a pass missing from here silently disappears
  /// from the UI rather than failing.
  static const List<({String title, List<PassType> passes})> stages = [
    (
      title: 'Deinterlace & Film Damage',
      passes: [
        PassType.deinterlace,
        PassType.edgeRepair,
        PassType.ghostRemoval,
        PassType.deflicker,
        PassType.descratch,
        PassType.spotless,
      ],
    ),
    (
      title: 'Noise & Artifacts',
      passes: [
        PassType.noiseReduction,
        PassType.chromaDenoise,
        PassType.dehalo,
        PassType.deblock,
        PassType.deband,
      ],
    ),
    (
      title: 'Detail & Color',
      passes: [
        PassType.antiAlias,
        PassType.sharpen,
        PassType.chromaFixes,
        PassType.colorCorrection,
      ],
    ),
    (
      title: 'Framing',
      passes: [PassType.stabilize, PassType.geometry, PassType.cropResize],
    ),
    (
      title: 'Finishing',
      passes: [PassType.grain, PassType.frameRate],
    ),
    (
      title: 'Post-Processing',
      passes: [PassType.subtitles],
    ),
  ];

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
            relevance: relevanceFor(passType, viewModel.videoInfo),
            onToggle: onToggle ?? (enabled) => viewModel.togglePass(passType, enabled),
            onTap: () => viewModel.selectPass(passType),
            expandedChild: isExpanded ? PassSettingsInline(passType: passType) : null,
          );
        }

        /// Builds one row for a pass, looking its title and summary up so the
        /// stage table stays a plain list of pass types.
        Widget row(PassType passType) {
          switch (passType) {
            case PassType.deinterlace:
              return item(passType, 'Deinterlace',
                  _getDeinterlaceSummary(pipeline), pipeline.deinterlace.enabled);
            case PassType.descratch:
              return item(passType, 'DeScratch', pipeline.descratch.summary,
                  pipeline.descratch.enabled);
            case PassType.spotless:
              return item(passType, 'SpotLess', pipeline.spotless.summary,
                  pipeline.spotless.enabled);
            case PassType.noiseReduction:
              return item(passType, 'Noise Reduction',
                  pipeline.noiseReduction.summary, pipeline.noiseReduction.enabled);
            case PassType.chromaDenoise:
              return item(passType, 'Chroma Denoise',
                  pipeline.chromaDenoise.summary, pipeline.chromaDenoise.enabled);
            case PassType.dehalo:
              return item(passType, 'Dehalo', pipeline.dehalo.summary,
                  pipeline.dehalo.enabled);
            case PassType.deblock:
              return item(passType, 'Deblock', pipeline.deblock.summary,
                  pipeline.deblock.enabled);
            case PassType.deband:
              return item(passType, 'Deband', pipeline.deband.summary,
                  pipeline.deband.enabled);
            case PassType.sharpen:
              return item(passType, 'Sharpen', pipeline.sharpen.summary,
                  pipeline.sharpen.enabled);
            case PassType.antiAlias:
              return item(passType, 'Anti-Aliasing', pipeline.antiAlias.summary,
                  pipeline.antiAlias.enabled);
            case PassType.stabilize:
              return item(passType, 'Stabilize', pipeline.stabilize.summary,
                  pipeline.stabilize.enabled);
            case PassType.geometry:
              return item(passType, 'Rotate / Flip', pipeline.geometry.summary,
                  pipeline.geometry.enabled);
            case PassType.grain:
              return item(passType, 'Film Grain', pipeline.grain.summary,
                  pipeline.grain.enabled);
            case PassType.frameRate:
              return item(passType, 'Frame Rate', pipeline.frameRate.summary,
                  pipeline.frameRate.enabled);
            case PassType.deflicker:
              return item(passType, 'Deflicker', pipeline.deflicker.summary,
                  pipeline.deflicker.enabled);
            case PassType.edgeRepair:
              return item(passType, 'Edge Repair', pipeline.edgeRepair.summary,
                  pipeline.edgeRepair.enabled);
            case PassType.ghostRemoval:
              return item(passType, 'Ghost Removal',
                  pipeline.ghostRemoval.summary, pipeline.ghostRemoval.enabled);
            case PassType.chromaFixes:
              return item(passType, 'Chroma Fixes', pipeline.chromaFixes.summary,
                  pipeline.chromaFixes.enabled);
            case PassType.colorCorrection:
              return item(passType, 'Color Correction',
                  pipeline.colorCorrection.summary,
                  pipeline.colorCorrection.enabled);
            case PassType.cropResize:
              return item(passType, 'Crop / Resize', pipeline.cropResize.summary,
                  pipeline.cropResize.enabled);
            case PassType.subtitles:
              return item(
                passType,
                'Subtitles',
                pipeline.subtitles.summary,
                pipeline.subtitles.enabled,
                onToggle: (enabled) =>
                    _handleSubtitlesToggle(context, viewModel, enabled),
              );
          }
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

            for (final stage in stages) ...[
              _buildStageHeader(
                context,
                stage.title,
                enabledCount: stage.passes
                    .where((p) => pipeline.isPassEnabled(p))
                    .length,
                isFirst: stage == stages.first,
              ),
              for (final passType in stage.passes) row(passType),
            ],

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

  /// A stage label over the pass rows, with a count when anything in the stage
  /// is switched on — so "where did I turn something on" is answerable without
  /// reading every row.
  Widget _buildStageHeader(
    BuildContext context,
    String title, {
    required int enabledCount,
    required bool isFirst,
  }) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isFirst) const Divider(height: 24) else const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 4),
          child: Row(
            children: [
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: muted),
              ),
              if (enabledCount > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '· $enabledCount on',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
              ],
            ],
          ),
        ),
      ],
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
