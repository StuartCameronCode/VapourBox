import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/dynamic_parameters.dart';
import '../../models/filter_registry.dart';
import '../../models/filter_schema.dart';
import '../../models/pass_advice.dart';
import '../../models/processing_pipeline.dart';
import '../../models/gpu_plugin_status.dart';
import '../../services/addon_service.dart';
import '../../services/whisper_addon_manager.dart';
import '../../utils/pixel_format.dart';
import '../../viewmodels/main_viewmodel.dart';
import '../../widgets/warning_banner.dart';
import '../settings/dynamic_filter_panel.dart';
import '../addon_dialogs.dart';

/// The settings for one processing pass, rendered inline underneath that pass's
/// row in the pass list. Leads with the filter's description — what it does and
/// when to use it — followed by any warnings and then the generated controls.
///
/// Uses schema-driven UI generation from FilterRegistry.
class PassSettingsInline extends StatelessWidget {
  /// The pass whose settings to show.
  final PassType passType;

  const PassSettingsInline({super.key, required this.passType});

  /// Maps PassType to filter schema ID. Public because `pass_list_panel.dart`
  /// needs the same mapping to look up a pass's [FilterSchema] for its "NEW"
  /// badge — kept in one place rather than a second switch to fall out of
  /// sync with this one.
  static String filterIdFor(PassType passType) {
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
      case PassType.antiAlias:
        return 'anti_alias';
      case PassType.stabilize:
        return 'stabilize';
      case PassType.geometry:
        return 'geometry';
      case PassType.grain:
        return 'grain';
      case PassType.frameRate:
        return 'frame_rate';
      case PassType.deflicker:
        return 'deflicker';
      case PassType.edgeRepair:
        return 'edge_repair';
      case PassType.ghostRemoval:
        return 'ghost_removal';
      case PassType.descale:
        return 'descale';
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
        final filterId = filterIdFor(passType);
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
            _buildGpuPluginNotice(context, viewModel, filterId, params),
            _buildKnlmNotice(viewModel, filterId, params),
            if (animeJanaiSelectedBy(filterId, params.values))
              const AnimeJanaiNotice(),
            if (filterId == 'descale') _buildDescaleDetect(context, viewModel),
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

  /// Descale's Detect: run the analysis on the selected video and offer what
  /// it found. A wrong native resolution damages the picture, so a source with
  /// no clear one is told so plainly rather than handed a guess to apply.
  Widget _buildDescaleDetect(BuildContext context, MainViewModel viewModel) {
    final theme = Theme.of(context);
    final report = viewModel.nativeResReport;
    final running = viewModel.detectingNativeRes;
    final canRun = viewModel.selectedItem != null && !running;
    final children = <Widget>[
      Row(
        children: [
          OutlinedButton.icon(
            onPressed: canRun ? viewModel.detectNativeResolution : null,
            icon: running
                ? const SizedBox.square(
                    dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search, size: 16),
            label: Text(running ? 'Detecting…' : 'Detect native resolution'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              running
                  ? 'Trying every height and the common kernels on frames from '
                      'this video. About half a minute for HD.'
                  : viewModel.selectedItem == null
                      ? 'Select a video to analyse.'
                      : 'Finds the resolution and kernel this video was upscaled from.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    ];
    if (!running && report != null) {
      if (report.error != null) {
        children.add(WarningBanner(message: 'Detection failed: ${report.error}'));
      } else if (report.found) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Icon(Icons.check_circle, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  'Drawn at ${report.width}×${report.height}, upscaled with '
                  '${report.kernelLabel}.',
                ),
              ),
              FilledButton(
                onPressed: viewModel.applyNativeResolution,
                child: const Text('Use these settings'),
              ),
            ],
          ),
        ));
      } else {
        children.add(WarningBanner(
          message: 'No clear native resolution. This video does not look like '
              'it was upscaled from a lower one, and descaling it would soften '
              'it. (Closest candidate: ${report.height}p, '
              '${report.kernelLabel}.)',
        ));
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  /// Why the KNLMeans noise-reduction method can't run here, the moment it is
  /// chosen. Like RIFE it has no fallback (the worker refuses the job), so the
  /// worker's own reason is shown verbatim.
  Widget _buildKnlmNotice(
    MainViewModel viewModel,
    String filterId,
    DynamicParameters params,
  ) {
    final message = viewModel.knlmMethodMessage;
    if (filterId != 'noise_reduction' ||
        params.values['method'] != 'knlmeans' ||
        message == null) {
      return const SizedBox.shrink();
    }
    return WarningBanner(message: message);
  }

  /// A GPU feature's prerequisites (RIFE, AI upscaling), the moment it is
  /// chosen. Unlike the OpenCL options there is no fallback — such a job on a
  /// machine without a Vulkan device is refused — so this says exactly what
  /// is missing and how to fix it (the worker's wording, see `gpu_plugin.rs`),
  /// with a button to check again once the user has.
  Widget _buildGpuPluginNotice(
    BuildContext context,
    MainViewModel viewModel,
    String filterId,
    DynamicParameters params,
  ) {
    final plugin = gpuPluginSelectedBy(filterId, params.values);
    if (plugin == null) return const SizedBox.shrink();
    final status = viewModel.gpuPluginStatus(plugin);
    final notice = gpuPluginNoticeFor(
      selected: true,
      status: status,
      checking: viewModel.gpuPluginChecking(plugin),
    );
    switch (notice) {
      case GpuPluginNotice.none:
        return const SizedBox.shrink();
      case GpuPluginNotice.checking:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Checking whether ${plugin.label} can run on this computer…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        );
      case GpuPluginNotice.unavailable:
        final scheme = Theme.of(context).colorScheme;
        return WarningBanner(
          message: status!.message!,
          action: OutlinedButton.icon(
            onPressed: () => viewModel.recheckGpuPlugin(plugin),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Check again'),
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.onErrorContainer,
              side: BorderSide(color: scheme.onErrorContainer),
              visualDensity: VisualDensity.compact,
            ),
          ),
        );
    }
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

  /// Handle parameter changes: editing a pass's settings switches the pass
  /// on, and subtitles get the add-on/model download check first.
  void _handleParamChange(
    BuildContext context,
    MainViewModel viewModel,
    String filterId,
    DynamicParameters oldParams,
    DynamicParameters newParams,
  ) async {
    newParams = newParams.enabledByEditFrom(oldParams);

    // Subtitles need whisper and the chosen model on disk before they can be
    // on — check whenever this edit turns them on or changes the model while
    // on, the same as the row's own toggle does. Declining drops the edit.
    if (filterId == 'subtitles' &&
        newParams.enabled &&
        (!oldParams.enabled ||
            oldParams.values['model'] != newParams.values['model'])) {
      final newModelId = newParams.values['model'] as String? ?? 'medium';
      final ready = await AddonPrompt.ensure(
        context,
        [WhisperAddonManager.modelAddonId(newModelId)],
        reason: 'Subtitle generation needs the Whisper speech recognition add-on.',
      );
      if (!ready) return;
    }

    // AnimeJaNai's models are an add-on: choosing it downloads them, after
    // saying what they are and that they are for non-commercial use only.
    if (_choosesAnimeJanai(filterId, oldParams, newParams)) {
      if (!context.mounted) return;
      final ready = await AddonPrompt.ensure(
        context,
        [animeJanaiAddonId],
        reason: 'AnimeJaNai upscaling needs its models.',
      );
      if (!ready) return;
    }
    viewModel.updateDynamicParams(filterId, newParams);
  }

  bool _choosesAnimeJanai(
    String filterId,
    DynamicParameters oldParams,
    DynamicParameters newParams,
  ) =>
      animeJanaiSelectedBy(filterId, newParams.values) &&
      !animeJanaiSelectedBy(filterId, oldParams.values);

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

/// Under Crop & Resize while AnimeJaNai is chosen: its terms, always — the
/// non-commercial restriction is the user's to keep in mind on every job —
/// and, if its models are not installed (deleted since, or chosen by a
/// preset), a button to download them.
class AnimeJanaiNotice extends StatefulWidget {
  final AddonService? service;
  const AnimeJanaiNotice({super.key, this.service});

  @override
  State<AnimeJanaiNotice> createState() => _AnimeJanaiNoticeState();
}

class _AnimeJanaiNoticeState extends State<AnimeJanaiNotice> {
  AddonService get _service => widget.service ?? AddonService.instance;

  @override
  void initState() {
    super.initState();
    _service.load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final info = _service.info(animeJanaiAddonId);
        if (info == null) return const SizedBox.shrink();
        final installed = _service.isInstalled(animeJanaiAddonId);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      installed
                          ? 'AnimeJaNai models installed.'
                          : 'AnimeJaNai\'s models are not installed.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    AddonTerms(info: info),
                  ],
                ),
              ),
              if (!installed)
                OutlinedButton.icon(
                  onPressed: _service.installingId != null
                      ? null
                      : () => AddonPrompt.ensure(context, [animeJanaiAddonId],
                          reason: 'AnimeJaNai upscaling needs its models.',
                          service: _service),
                  icon: const Icon(Icons.download, size: 16),
                  label: Text('Download (${formatAddonSize(info.downloadBytes)})'),
                ),
            ],
          ),
        );
      },
    );
  }
}
