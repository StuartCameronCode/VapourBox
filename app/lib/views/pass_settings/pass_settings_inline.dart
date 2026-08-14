import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/dynamic_parameters.dart';
import '../../models/filter_registry.dart';
import '../../models/filter_schema.dart';
import '../../models/pass_advice.dart';
import '../../models/processing_pipeline.dart';
import '../../services/whisper_addon_manager.dart';
import '../../utils/pixel_format.dart';
import '../../viewmodels/main_viewmodel.dart';
import '../../widgets/warning_banner.dart';
import '../settings/dynamic_filter_panel.dart';
import '../whisper_download_dialog.dart';

/// The settings for one processing pass, rendered inline underneath that pass's
/// row in the pass list. Leads with the filter's description — what it does and
/// when to use it — followed by any warnings and then the generated controls.
///
/// Uses schema-driven UI generation from FilterRegistry.
class PassSettingsInline extends StatelessWidget {
  /// The pass whose settings to show.
  final PassType passType;

  const PassSettingsInline({super.key, required this.passType});

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
      case PassType.chromaDenoise:
        return 'chroma_denoise';
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
        final filterId = _getFilterId(passType);
        final schema = FilterRegistry.instance.get(filterId);

        // If schema not found, show a fallback message
        if (schema == null) {
          return _buildFallbackPanel(context, passType);
        }

        // Use cached dynamic params from ViewModel (preserves null values)
        final params = viewModel.getDynamicParams(filterId);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildDescription(context, schema),
            _buildInteractionAdvice(context, viewModel),
            _buildOpenCLWarning(context, viewModel, filterId, params),
            _buildBitDepthWarning(context, viewModel, schema, params),
            DynamicFilterPanelCompact(
              schema: schema,
              params: params,
              onChanged: (newParams) {
                _handleParamChange(context, viewModel, filterId, params, newParams);
              },
            ),
          ],
        );
      },
    );
  }

  /// What the filter does, shown above every option: the one-line summary
  /// always, with the fuller "what it does and when to use it" prose behind an
  /// expander. See [_FilterDescription].
  Widget _buildDescription(BuildContext context, FilterSchema schema) {
    return _FilterDescription(schema: schema);
  }

  /// How this pass interacts with the others that are switched on — a denoiser
  /// that will undo the sharpening, a setting the chosen method ignores. Shown
  /// in the advisory (not error) style, because every combination it comments on
  /// still renders. See [adviceFor].
  Widget _buildInteractionAdvice(BuildContext context, MainViewModel viewModel) {
    final message = adviceFor(passType, viewModel.processingPipeline);
    if (message == null) return const SizedBox.shrink();
    return WarningBanner(message: message);
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

    return WarningBanner(message: message);
  }

  /// Warning shown when an enabled filter can't process the source's bit depth
  /// natively (schema `maxBitDepth`), so the worker down-converts to that depth
  /// for the pass and restores it afterward — a lossy round-trip. E.g. DeScratch
  /// is 8-bit only, so a 10-bit source loses precision through that pass.
  /// Returns an empty widget when the pass is off or the source fits natively.
  Widget _buildBitDepthWarning(
    BuildContext context,
    MainViewModel viewModel,
    FilterSchema schema,
    DynamicParameters params,
  ) {
    final message = filterBitDepthWarning(
      filterName: schema.name,
      enabled: params.enabled,
      maxBitDepth: schema.maxBitDepth,
      pixelFormat: viewModel.videoInfo?.pixelFormat,
    );
    if (message == null) return const SizedBox.shrink();
    return WarningBanner(message: message);
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 32,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(
            'Filter schema not found',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Could not load settings for ${passType.displayName}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The blurb above a filter's options: the schema's one-line `description`,
/// with the fuller `longDescription` — what the filter does and when to reach
/// for it — behind an expander so it doesn't push the controls off screen.
///
/// Collapsed by default, and reset each time a pass is expanded, since the
/// widget only exists while its pass is open.
class _FilterDescription extends StatefulWidget {
  final FilterSchema schema;

  const _FilterDescription({required this.schema});

  @override
  State<_FilterDescription> createState() => _FilterDescriptionState();
}

class _FilterDescriptionState extends State<_FilterDescription> {
  bool _showDetail = false;

  @override
  Widget build(BuildContext context) {
    final schema = widget.schema;
    final summary = schema.description?.trim();
    final detail = schema.longDescription?.trim();

    // Nothing to say at all.
    if ((summary == null || summary.isEmpty) && (detail == null || detail.isEmpty)) {
      return const SizedBox.shrink();
    }

    // With no summary the long text is all we have, so show it outright.
    final headline = (summary != null && summary.isNotEmpty) ? summary : detail!;
    final hasDetail =
        detail != null && detail.isNotEmpty && detail != headline;

    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: colorScheme.primary.withValues(alpha: 0.5), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeadline(context, headline, hasDetail),

          // Full description — animates open below the summary.
          AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _showDetail && hasDetail
                ? Padding(
                    padding: const EdgeInsets.only(top: 8, right: 4),
                    child: _buildParagraphs(context, detail),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _buildHeadline(BuildContext context, String headline, bool hasDetail) {
    final colorScheme = Theme.of(context).colorScheme;
    final text = Text(
      headline,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurface.withValues(alpha: 0.8),
            height: 1.3,
          ),
    );

    if (!hasDetail) return Padding(padding: const EdgeInsets.only(right: 4), child: text);

    return InkWell(
      onTap: () => setState(() => _showDetail = !_showDetail),
      borderRadius: BorderRadius.circular(4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: text),
          const SizedBox(width: 4),
          Text(
            _showDetail ? 'Less' : 'More',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                ),
          ),
          AnimatedRotation(
            turns: _showDetail ? 0.5 : 0,
            duration: const Duration(milliseconds: 160),
            child: Icon(Icons.expand_more, size: 18, color: colorScheme.primary),
          ),
        ],
      ),
    );
  }

  /// Renders the detail text, treating blank lines as paragraph breaks.
  Widget _buildParagraphs(BuildContext context, String detail) {
    final colorScheme = Theme.of(context).colorScheme;
    final paragraphs = detail
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Text(
            paragraphs[i],
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.4,
                ),
          ),
        ],
      ],
    );
  }
}
