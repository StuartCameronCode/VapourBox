import 'package:json_annotation/json_annotation.dart';

import 'chroma_fix_parameters.dart';
import 'color_correction_parameters.dart';
import 'crop_resize_parameters.dart';
import 'deband_parameters.dart';
import 'deblock_parameters.dart';
import 'dehalo_parameters.dart';
import 'noise_reduction_parameters.dart';
import 'qtgmc_parameters.dart';
import 'sharpen_parameters.dart';

part 'restoration_pipeline.g.dart';

/// Defines the type of each restoration pass.
enum PassType {
  deinterlace,
  noiseReduction,
  dehalo,
  deblock,
  deband,
  sharpen,
  colorCorrection,
  chromaFixes,
  cropResize,
}

/// Extension to provide display names for pass types.
extension PassTypeExtension on PassType {
  String get displayName {
    switch (this) {
      case PassType.deinterlace:
        return 'Deinterlace';
      case PassType.noiseReduction:
        return 'Noise Reduction';
      case PassType.dehalo:
        return 'Dehalo';
      case PassType.deblock:
        return 'Deblock';
      case PassType.deband:
        return 'Deband';
      case PassType.sharpen:
        return 'Sharpen';
      case PassType.colorCorrection:
        return 'Color Correction';
      case PassType.chromaFixes:
        return 'Chroma Fixes';
      case PassType.cropResize:
        return 'Crop / Resize';
    }
  }

  String get description {
    switch (this) {
      case PassType.deinterlace:
        return 'Remove interlacing artifacts using QTGMC';
      case PassType.noiseReduction:
        return 'Reduce video noise and grain';
      case PassType.dehalo:
        return 'Remove halo artifacts around edges';
      case PassType.deblock:
        return 'Remove compression block artifacts';
      case PassType.deband:
        return 'Remove color banding from gradients';
      case PassType.sharpen:
        return 'Sharpen edges and enhance detail';
      case PassType.colorCorrection:
        return 'Adjust brightness, contrast, and colors';
      case PassType.chromaFixes:
        return 'Fix chroma bleeding and crawl artifacts';
      case PassType.cropResize:
        return 'Crop borders and resize output';
    }
  }
}

/// Container for all restoration pass parameters.
/// Defines the complete video restoration pipeline.
@JsonSerializable(explicitToJson: true)
class RestorationPipeline {
  /// Deinterlacing pass parameters (QTGMC).
  final QTGMCParameters deinterlace;

  /// Noise reduction pass parameters.
  final NoiseReductionParameters noiseReduction;

  /// Dehalo pass parameters.
  final DehaloParameters dehalo;

  /// Deblock pass parameters.
  final DeblockParameters deblock;

  /// Deband pass parameters (f3kdb).
  final DebandParameters deband;

  /// Sharpening pass parameters.
  final SharpenParameters sharpen;

  /// Color correction pass parameters.
  final ColorCorrectionParameters colorCorrection;

  /// Chroma fix pass parameters.
  final ChromaFixParameters chromaFixes;

  /// Crop and resize pass parameters.
  final CropResizeParameters cropResize;

  const RestorationPipeline({
    this.deinterlace = const QTGMCParameters(),
    this.noiseReduction = const NoiseReductionParameters(),
    this.dehalo = const DehaloParameters(),
    this.deblock = const DeblockParameters(),
    this.deband = const DebandParameters(),
    this.sharpen = const SharpenParameters(),
    this.colorCorrection = const ColorCorrectionParameters(),
    this.chromaFixes = const ChromaFixParameters(),
    this.cropResize = const CropResizeParameters(),
  });

  /// Create a pipeline from legacy QTGMC-only parameters.
  factory RestorationPipeline.fromLegacy(QTGMCParameters qtgmcParams) {
    return RestorationPipeline(
      deinterlace: qtgmcParams,
      // Other passes disabled by default when migrating from legacy
      noiseReduction: const NoiseReductionParameters(enabled: false),
      dehalo: const DehaloParameters(enabled: false),
      deblock: const DeblockParameters(enabled: false),
      deband: const DebandParameters(enabled: false),
      sharpen: const SharpenParameters(enabled: false),
      colorCorrection: const ColorCorrectionParameters(enabled: false),
      chromaFixes: const ChromaFixParameters(enabled: false),
      cropResize: const CropResizeParameters(enabled: false),
    );
  }

  /// Get the ordered list of enabled passes.
  List<PassType> get enabledPasses {
    final passes = <PassType>[];
    // Order: Crop first (pre-processing), then deinterlace, noise, dehalo, deblock, deband, sharpen, chroma, color, resize last
    if (cropResize.enabled && cropResize.cropEnabled) {
      passes.add(PassType.cropResize); // Pre-crop
    }
    if (deinterlace.enabled) {
      passes.add(PassType.deinterlace);
    }
    if (noiseReduction.enabled) {
      passes.add(PassType.noiseReduction);
    }
    if (dehalo.enabled) {
      passes.add(PassType.dehalo);
    }
    if (deblock.enabled) {
      passes.add(PassType.deblock);
    }
    if (deband.enabled) {
      passes.add(PassType.deband);
    }
    if (sharpen.enabled) {
      passes.add(PassType.sharpen);
    }
    if (chromaFixes.enabled) {
      passes.add(PassType.chromaFixes);
    }
    if (colorCorrection.enabled) {
      passes.add(PassType.colorCorrection);
    }
    if (cropResize.enabled && cropResize.resizeEnabled) {
      // Resize (post-processing) - if not already added for crop
      if (!passes.contains(PassType.cropResize)) {
        passes.add(PassType.cropResize);
      }
    }
    return passes;
  }

  /// Get count of enabled passes.
  int get enabledPassCount {
    var count = 0;
    if (deinterlace.enabled) count++;
    if (noiseReduction.enabled) count++;
    if (dehalo.enabled) count++;
    if (deblock.enabled) count++;
    if (deband.enabled) count++;
    if (sharpen.enabled) count++;
    if (colorCorrection.enabled) count++;
    if (chromaFixes.enabled) count++;
    if (cropResize.enabled) count++;
    return count;
  }

  /// Check if a specific pass is enabled.
  bool isPassEnabled(PassType pass) {
    switch (pass) {
      case PassType.deinterlace:
        return deinterlace.enabled;
      case PassType.noiseReduction:
        return noiseReduction.enabled;
      case PassType.dehalo:
        return dehalo.enabled;
      case PassType.deblock:
        return deblock.enabled;
      case PassType.deband:
        return deband.enabled;
      case PassType.sharpen:
        return sharpen.enabled;
      case PassType.colorCorrection:
        return colorCorrection.enabled;
      case PassType.chromaFixes:
        return chromaFixes.enabled;
      case PassType.cropResize:
        return cropResize.enabled;
    }
  }

  /// Get summary string for a specific pass.
  String getPassSummary(PassType pass) {
    switch (pass) {
      case PassType.deinterlace:
        return deinterlace.enabled
            ? deinterlace.preset.displayName
            : 'Off';
      case PassType.noiseReduction:
        return noiseReduction.summary;
      case PassType.dehalo:
        return dehalo.summary;
      case PassType.deblock:
        return deblock.summary;
      case PassType.deband:
        return deband.summary;
      case PassType.sharpen:
        return sharpen.summary;
      case PassType.colorCorrection:
        return colorCorrection.summary;
      case PassType.chromaFixes:
        return chromaFixes.summary;
      case PassType.cropResize:
        return cropResize.summary;
    }
  }

  RestorationPipeline copyWith({
    QTGMCParameters? deinterlace,
    NoiseReductionParameters? noiseReduction,
    DehaloParameters? dehalo,
    DeblockParameters? deblock,
    DebandParameters? deband,
    SharpenParameters? sharpen,
    ColorCorrectionParameters? colorCorrection,
    ChromaFixParameters? chromaFixes,
    CropResizeParameters? cropResize,
  }) {
    return RestorationPipeline(
      deinterlace: deinterlace ?? this.deinterlace,
      noiseReduction: noiseReduction ?? this.noiseReduction,
      dehalo: dehalo ?? this.dehalo,
      deblock: deblock ?? this.deblock,
      deband: deband ?? this.deband,
      sharpen: sharpen ?? this.sharpen,
      colorCorrection: colorCorrection ?? this.colorCorrection,
      chromaFixes: chromaFixes ?? this.chromaFixes,
      cropResize: cropResize ?? this.cropResize,
    );
  }

  /// Toggle a pass on or off.
  RestorationPipeline togglePass(PassType pass, bool enabled) {
    switch (pass) {
      case PassType.deinterlace:
        return copyWith(
          deinterlace: deinterlace.copyWith(enabled: enabled),
        );
      case PassType.noiseReduction:
        return copyWith(
          noiseReduction: noiseReduction.copyWith(enabled: enabled),
        );
      case PassType.dehalo:
        return copyWith(
          dehalo: dehalo.copyWith(enabled: enabled),
        );
      case PassType.deblock:
        return copyWith(
          deblock: deblock.copyWith(enabled: enabled),
        );
      case PassType.deband:
        return copyWith(
          deband: deband.copyWith(enabled: enabled),
        );
      case PassType.sharpen:
        return copyWith(
          sharpen: sharpen.copyWith(enabled: enabled),
        );
      case PassType.colorCorrection:
        return copyWith(
          colorCorrection: colorCorrection.copyWith(enabled: enabled),
        );
      case PassType.chromaFixes:
        return copyWith(
          chromaFixes: chromaFixes.copyWith(enabled: enabled),
        );
      case PassType.cropResize:
        return copyWith(
          cropResize: cropResize.copyWith(enabled: enabled),
        );
    }
  }

  factory RestorationPipeline.fromJson(Map<String, dynamic> json) =>
      _$RestorationPipelineFromJson(json);

  Map<String, dynamic> toJson() => _$RestorationPipelineToJson(this);
}
