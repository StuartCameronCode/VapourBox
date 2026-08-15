import 'package:json_annotation/json_annotation.dart';

import 'anti_alias_parameters.dart';
import 'chroma_fix_parameters.dart';
import 'color_correction_parameters.dart';
import 'crop_resize_parameters.dart';
import 'deband_parameters.dart';
import 'deblock_parameters.dart';
import 'descratch_parameters.dart';
import 'spotless_parameters.dart';
import 'stabilize_parameters.dart';
import 'dehalo_parameters.dart';
import 'dynamic_parameters.dart';
import 'chroma_denoise_parameters.dart';
import 'noise_reduction_parameters.dart';
import 'parameter_converter.dart';
import 'qtgmc_parameters.dart';
import 'sharpen_parameters.dart';
import 'subtitle_parameters.dart';

part 'processing_pipeline.g.dart';

/// Defines the type of each processing pass.
enum PassType {
  deinterlace,
  descratch,
  spotless,
  noiseReduction,
  chromaDenoise,
  dehalo,
  deblock,
  deband,
  sharpen,
  antiAlias,
  stabilize,
  colorCorrection,
  chromaFixes,
  cropResize,
  subtitles,
}

/// Extension to provide display names for pass types.
extension PassTypeExtension on PassType {
  String get displayName {
    switch (this) {
      case PassType.deinterlace:
        return 'Deinterlace';
      case PassType.descratch:
        return 'DeScratch';
      case PassType.spotless:
        return 'SpotLess';
      case PassType.noiseReduction:
        return 'Noise Reduction';
      case PassType.chromaDenoise:
        return 'Chroma Denoise';
      case PassType.dehalo:
        return 'Dehalo';
      case PassType.deblock:
        return 'Deblock';
      case PassType.deband:
        return 'Deband';
      case PassType.sharpen:
        return 'Sharpen';
      case PassType.antiAlias:
        return 'Anti-Aliasing';
      case PassType.stabilize:
        return 'Stabilize';
      case PassType.colorCorrection:
        return 'Color Correction';
      case PassType.chromaFixes:
        return 'Chroma Fixes';
      case PassType.cropResize:
        return 'Crop / Resize';
      case PassType.subtitles:
        return 'Subtitles';
    }
  }

  String get description {
    switch (this) {
      case PassType.deinterlace:
        return 'Deinterlace (QTGMC) or inverse telecine (IVTC)';
      case PassType.descratch:
        return 'Remove vertical scratches from scanned film';
      case PassType.spotless:
        return 'Remove dust, dirt, and temporal spots from film';
      case PassType.noiseReduction:
        return 'Reduce video noise and grain';
      case PassType.chromaDenoise:
        return 'Remove blotchy colour noise (CCD)';
      case PassType.dehalo:
        return 'Remove halo artifacts around edges';
      case PassType.deblock:
        return 'Remove compression block artifacts';
      case PassType.deband:
        return 'Remove color banding from gradients';
      case PassType.sharpen:
        return 'Sharpen edges and enhance detail';
      case PassType.antiAlias:
        return 'Smooth stair-stepping on diagonal edges';
      case PassType.stabilize:
        return 'Remove shake and weave from the picture';
      case PassType.colorCorrection:
        return 'Adjust brightness, contrast, and colors';
      case PassType.chromaFixes:
        return 'Fix chroma bleeding and crawl artifacts';
      case PassType.cropResize:
        return 'Crop borders and resize output';
      case PassType.subtitles:
        return 'Generate subtitles using Whisper AI';
    }
  }
}

/// Container for all processing pass parameters.
/// Defines the complete video processing pipeline.
@JsonSerializable(explicitToJson: true)
class ProcessingPipeline {
  /// Deinterlacing pass parameters (QTGMC).
  final QTGMCParameters deinterlace;

  /// DeScratch pass parameters (scratch removal).
  final DeScratchParameters descratch;

  /// SpotLess pass parameters (spot/dirt removal).
  final SpotLessParameters spotless;

  /// Noise reduction pass parameters.
  final NoiseReductionParameters noiseReduction;

  /// Chroma denoise pass parameters (CCD).
  final ChromaDenoiseParameters chromaDenoise;

  /// Dehalo pass parameters.
  final DehaloParameters dehalo;

  /// Deblock pass parameters.
  final DeblockParameters deblock;

  /// Deband pass parameters (f3kdb).
  final DebandParameters deband;

  /// Sharpening pass parameters.
  final SharpenParameters sharpen;
  final AntiAliasParameters antiAlias;
  final StabilizeParameters stabilize;

  /// Color correction pass parameters.
  final ColorCorrectionParameters colorCorrection;

  /// Chroma fix pass parameters.
  final ChromaFixParameters chromaFixes;

  /// Crop and resize pass parameters.
  final CropResizeParameters cropResize;

  /// Subtitle generation pass parameters (Whisper AI).
  final SubtitleParameters subtitles;

  const ProcessingPipeline({
    this.deinterlace = const QTGMCParameters(),
    this.descratch = const DeScratchParameters(),
    this.spotless = const SpotLessParameters(),
    this.noiseReduction = const NoiseReductionParameters(),
    this.chromaDenoise = const ChromaDenoiseParameters(),
    this.dehalo = const DehaloParameters(),
    this.deblock = const DeblockParameters(),
    this.deband = const DebandParameters(),
    this.sharpen = const SharpenParameters(),
    this.antiAlias = const AntiAliasParameters(),
    this.stabilize = const StabilizeParameters(),
    this.colorCorrection = const ColorCorrectionParameters(),
    this.chromaFixes = const ChromaFixParameters(),
    this.cropResize = const CropResizeParameters(),
    this.subtitles = const SubtitleParameters(),
  });

  /// Create a pipeline from legacy QTGMC-only parameters.
  factory ProcessingPipeline.fromLegacy(QTGMCParameters qtgmcParams) {
    return ProcessingPipeline(
      deinterlace: qtgmcParams,
      // Other passes disabled by default when migrating from legacy
      descratch: const DeScratchParameters(enabled: false),
      spotless: const SpotLessParameters(enabled: false),
      noiseReduction: const NoiseReductionParameters(enabled: false),
      chromaDenoise: const ChromaDenoiseParameters(enabled: false),
      dehalo: const DehaloParameters(enabled: false),
      deblock: const DeblockParameters(enabled: false),
      deband: const DebandParameters(enabled: false),
      sharpen: const SharpenParameters(enabled: false),
      antiAlias: const AntiAliasParameters(enabled: false),
      stabilize: const StabilizeParameters(enabled: false),
      colorCorrection: const ColorCorrectionParameters(enabled: false),
      chromaFixes: const ChromaFixParameters(enabled: false),
      cropResize: const CropResizeParameters(enabled: false),
      subtitles: const SubtitleParameters(enabled: false),
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
    if (descratch.enabled) {
      passes.add(PassType.descratch);
    }
    if (spotless.enabled) {
      passes.add(PassType.spotless);
    }
    if (noiseReduction.enabled) {
      passes.add(PassType.noiseReduction);
    }
    // Chroma noise is removed with the rest of the denoising, before the
    // deband/sharpen steps that would otherwise amplify it.
    if (chromaDenoise.enabled) {
      passes.add(PassType.chromaDenoise);
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
    // Anti-aliasing before sharpening: sharpening stair-stepped edges makes
    // the stepping more visible, not less.
    if (antiAlias.enabled) {
      passes.add(PassType.antiAlias);
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
    // Stabilisation shifts the picture within the frame, so it runs last
    // before framing — a crop can then remove the edges it exposes.
    if (stabilize.enabled) {
      passes.add(PassType.stabilize);
    }
    if (cropResize.enabled && cropResize.resizeEnabled) {
      // Resize (post-processing) - if not already added for crop
      if (!passes.contains(PassType.cropResize)) {
        passes.add(PassType.cropResize);
      }
    }
    return passes;
  }

  /// Get count of enabled passes (includes subtitles).
  int get enabledPassCount {
    var count = 0;
    if (deinterlace.enabled) count++;
    if (descratch.enabled) count++;
    if (spotless.enabled) count++;
    if (noiseReduction.enabled) count++;
    if (chromaDenoise.enabled) count++;
    if (dehalo.enabled) count++;
    if (deblock.enabled) count++;
    if (deband.enabled) count++;
    if (sharpen.enabled) count++;
    if (antiAlias.enabled) count++;
    if (stabilize.enabled) count++;
    if (colorCorrection.enabled) count++;
    if (chromaFixes.enabled) count++;
    if (cropResize.enabled) count++;
    if (subtitles.enabled) count++;
    return count;
  }

  /// Get count of enabled video processing passes (excludes subtitles).
  int get videoPassCount {
    var count = 0;
    if (deinterlace.enabled) count++;
    if (descratch.enabled) count++;
    if (spotless.enabled) count++;
    if (noiseReduction.enabled) count++;
    if (chromaDenoise.enabled) count++;
    if (dehalo.enabled) count++;
    if (deblock.enabled) count++;
    if (deband.enabled) count++;
    if (sharpen.enabled) count++;
    if (antiAlias.enabled) count++;
    if (stabilize.enabled) count++;
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
      case PassType.descratch:
        return descratch.enabled;
      case PassType.spotless:
        return spotless.enabled;
      case PassType.noiseReduction:
        return noiseReduction.enabled;
      case PassType.chromaDenoise:
        return chromaDenoise.enabled;
      case PassType.dehalo:
        return dehalo.enabled;
      case PassType.deblock:
        return deblock.enabled;
      case PassType.deband:
        return deband.enabled;
      case PassType.sharpen:
        return sharpen.enabled;
      case PassType.antiAlias:
        return antiAlias.enabled;
      case PassType.stabilize:
        return stabilize.enabled;
      case PassType.colorCorrection:
        return colorCorrection.enabled;
      case PassType.chromaFixes:
        return chromaFixes.enabled;
      case PassType.cropResize:
        return cropResize.enabled;
      case PassType.subtitles:
        return subtitles.enabled;
    }
  }

  /// Get summary string for a specific pass.
  String getPassSummary(PassType pass) {
    switch (pass) {
      case PassType.deinterlace:
        if (!deinterlace.enabled) return 'Off';
        if (deinterlace.method == DeinterlaceMethod.ivtc) return 'IVTC';
        return deinterlace.preset.displayName;
      case PassType.descratch:
        return descratch.summary;
      case PassType.spotless:
        return spotless.summary;
      case PassType.noiseReduction:
        return noiseReduction.summary;
      case PassType.chromaDenoise:
        return chromaDenoise.summary;
      case PassType.dehalo:
        return dehalo.summary;
      case PassType.deblock:
        return deblock.summary;
      case PassType.deband:
        return deband.summary;
      case PassType.sharpen:
        return sharpen.summary;
      case PassType.antiAlias:
        return antiAlias.summary;
      case PassType.stabilize:
        return stabilize.summary;
      case PassType.colorCorrection:
        return colorCorrection.summary;
      case PassType.chromaFixes:
        return chromaFixes.summary;
      case PassType.cropResize:
        return cropResize.summary;
      case PassType.subtitles:
        return subtitles.summary;
    }
  }

  ProcessingPipeline copyWith({
    QTGMCParameters? deinterlace,
    DeScratchParameters? descratch,
    SpotLessParameters? spotless,
    NoiseReductionParameters? noiseReduction,
    ChromaDenoiseParameters? chromaDenoise,
    DehaloParameters? dehalo,
    DeblockParameters? deblock,
    DebandParameters? deband,
    SharpenParameters? sharpen,
    AntiAliasParameters? antiAlias,
    StabilizeParameters? stabilize,
    ColorCorrectionParameters? colorCorrection,
    ChromaFixParameters? chromaFixes,
    CropResizeParameters? cropResize,
    SubtitleParameters? subtitles,
  }) {
    return ProcessingPipeline(
      deinterlace: deinterlace ?? this.deinterlace,
      descratch: descratch ?? this.descratch,
      spotless: spotless ?? this.spotless,
      noiseReduction: noiseReduction ?? this.noiseReduction,
      chromaDenoise: chromaDenoise ?? this.chromaDenoise,
      dehalo: dehalo ?? this.dehalo,
      deblock: deblock ?? this.deblock,
      deband: deband ?? this.deband,
      sharpen: sharpen ?? this.sharpen,
      antiAlias: antiAlias ?? this.antiAlias,
      stabilize: stabilize ?? this.stabilize,
      colorCorrection: colorCorrection ?? this.colorCorrection,
      chromaFixes: chromaFixes ?? this.chromaFixes,
      cropResize: cropResize ?? this.cropResize,
      subtitles: subtitles ?? this.subtitles,
    );
  }

  /// Toggle a pass on or off.
  ProcessingPipeline togglePass(PassType pass, bool enabled) {
    switch (pass) {
      case PassType.deinterlace:
        return copyWith(
          deinterlace: deinterlace.copyWith(enabled: enabled),
        );
      case PassType.descratch:
        return copyWith(
          descratch: descratch.copyWith(enabled: enabled),
        );
      case PassType.spotless:
        return copyWith(
          spotless: spotless.copyWith(enabled: enabled),
        );
      case PassType.chromaDenoise:
        return copyWith(
          chromaDenoise: chromaDenoise.copyWith(enabled: enabled),
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
      case PassType.antiAlias:
        return copyWith(
          antiAlias: antiAlias.copyWith(enabled: enabled),
        );
      case PassType.stabilize:
        return copyWith(
          stabilize: stabilize.copyWith(enabled: enabled),
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
      case PassType.subtitles:
        return copyWith(
          subtitles: subtitles.copyWith(enabled: enabled),
        );
    }
  }

  /// Convert to a dynamic pipeline for schema-based processing.
  DynamicPipeline toDynamicPipeline() {
    return ParameterConverter.fromPipeline(this);
  }

  factory ProcessingPipeline.fromJson(Map<String, dynamic> json) =>
      _$ProcessingPipelineFromJson(json);

  Map<String, dynamic> toJson() => _$ProcessingPipelineToJson(this);
}
