import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/dynamic_parameters.dart';
import '../../models/filter_registry.dart';
import '../../models/filter_schema.dart';
import '../../models/parameter_converter.dart';
import '../../models/restoration_pipeline.dart';
import '../../viewmodels/main_viewmodel.dart';
import '../settings/dynamic_filter_panel.dart';

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
    }
  }

  /// Gets dynamic parameters for the selected pass from the pipeline.
  static DynamicParameters _getParams(RestorationPipeline pipeline, PassType passType) {
    switch (passType) {
      case PassType.deinterlace:
        return ParameterConverter.fromQTGMC(pipeline.deinterlace);
      case PassType.noiseReduction:
        return ParameterConverter.fromNoiseReduction(pipeline.noiseReduction);
      case PassType.dehalo:
        return ParameterConverter.fromDehalo(pipeline.dehalo);
      case PassType.deblock:
        return ParameterConverter.fromDeblock(pipeline.deblock);
      case PassType.deband:
        return ParameterConverter.fromDeband(pipeline.deband);
      case PassType.sharpen:
        return ParameterConverter.fromSharpen(pipeline.sharpen);
      case PassType.colorCorrection:
        return ParameterConverter.fromColorCorrection(pipeline.colorCorrection);
      case PassType.chromaFixes:
        return ParameterConverter.fromChromaFixes(pipeline.chromaFixes);
      case PassType.cropResize:
        return ParameterConverter.fromCropResize(pipeline.cropResize);
    }
  }

  /// Updates the pipeline with new dynamic parameters.
  static void _updatePipeline(
    MainViewModel viewModel,
    PassType passType,
    DynamicParameters newParams,
  ) {
    final pipeline = viewModel.restorationPipeline;

    switch (passType) {
      case PassType.deinterlace:
        viewModel.updateRestorationPipeline(
          pipeline.copyWith(deinterlace: ParameterConverter.toQTGMC(newParams)),
        );
        break;
      case PassType.noiseReduction:
        viewModel.updateRestorationPipeline(
          pipeline.copyWith(noiseReduction: ParameterConverter.toNoiseReduction(newParams)),
        );
        break;
      case PassType.dehalo:
        viewModel.updateRestorationPipeline(
          pipeline.copyWith(dehalo: ParameterConverter.toDehalo(newParams)),
        );
        break;
      case PassType.deblock:
        viewModel.updateRestorationPipeline(
          pipeline.copyWith(deblock: ParameterConverter.toDeblock(newParams)),
        );
        break;
      case PassType.deband:
        viewModel.updateRestorationPipeline(
          pipeline.copyWith(deband: ParameterConverter.toDeband(newParams)),
        );
        break;
      case PassType.sharpen:
        viewModel.updateRestorationPipeline(
          pipeline.copyWith(sharpen: ParameterConverter.toSharpen(newParams)),
        );
        break;
      case PassType.colorCorrection:
        viewModel.updateRestorationPipeline(
          pipeline.copyWith(colorCorrection: ParameterConverter.toColorCorrection(newParams)),
        );
        break;
      case PassType.chromaFixes:
        viewModel.updateRestorationPipeline(
          pipeline.copyWith(chromaFixes: ParameterConverter.toChromaFixes(newParams)),
        );
        break;
      case PassType.cropResize:
        viewModel.updateRestorationPipeline(
          pipeline.copyWith(cropResize: ParameterConverter.toCropResize(newParams)),
        );
        break;
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

        final params = _getParams(viewModel.restorationPipeline, passType);

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: SingleChildScrollView(
            key: ValueKey(filterId),
            child: DynamicFilterPanelCompact(
              schema: schema,
              params: params,
              onChanged: (newParams) {
                _updatePipeline(viewModel, passType, newParams);
              },
            ),
          ),
        );
      },
    );
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
