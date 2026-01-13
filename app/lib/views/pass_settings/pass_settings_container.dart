import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/restoration_pipeline.dart';
import '../../viewmodels/main_viewmodel.dart';
import 'chroma_fix_settings_panel.dart';
import 'color_correction_settings_panel.dart';
import 'crop_resize_settings_panel.dart';
import 'deband_settings_panel.dart';
import 'deblock_settings_panel.dart';
import 'dehalo_settings_panel.dart';
import 'deinterlace_settings_panel.dart';
import 'noise_reduction_settings_panel.dart';
import 'sharpen_settings_panel.dart';

/// Container widget that shows the settings panel for the currently selected pass.
class PassSettingsContainer extends StatelessWidget {
  const PassSettingsContainer({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _buildSettingsPanel(viewModel.selectedPass),
        );
      },
    );
  }

  Widget _buildSettingsPanel(PassType selectedPass) {
    switch (selectedPass) {
      case PassType.deinterlace:
        return const DeinterlaceSettingsPanel(key: ValueKey('deinterlace'));
      case PassType.noiseReduction:
        return const NoiseReductionSettingsPanel(key: ValueKey('noiseReduction'));
      case PassType.dehalo:
        return const DehaloSettingsPanel(key: ValueKey('dehalo'));
      case PassType.deblock:
        return const DeblockSettingsPanel(key: ValueKey('deblock'));
      case PassType.deband:
        return const DebandSettingsPanel(key: ValueKey('deband'));
      case PassType.sharpen:
        return const SharpenSettingsPanel(key: ValueKey('sharpen'));
      case PassType.colorCorrection:
        return const ColorCorrectionSettingsPanel(key: ValueKey('colorCorrection'));
      case PassType.chromaFixes:
        return const ChromaFixSettingsPanel(key: ValueKey('chromaFixes'));
      case PassType.cropResize:
        return const CropResizeSettingsPanel(key: ValueKey('cropResize'));
    }
  }
}
