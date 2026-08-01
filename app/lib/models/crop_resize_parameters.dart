import 'package:json_annotation/json_annotation.dart';

part 'crop_resize_parameters.g.dart';

/// Resize kernel/algorithm options.
enum ResizeKernel {
  @JsonValue('spline36')
  spline36,
  @JsonValue('lanczos')
  lanczos,
  @JsonValue('bicubic')
  bicubic,
  @JsonValue('bilinear')
  bilinear,
  @JsonValue('point')
  point,
  @JsonValue('spline16')
  spline16,
  @JsonValue('spline64')
  spline64,
  @JsonValue('nnedi3')
  nnedi3,
  @JsonValue('eedi3')
  eedi3,
}

/// Upscale method options (for integer scaling).
enum UpscaleMethod {
  @JsonValue('nnedi3Rpow2')
  nnedi3Rpow2,
  @JsonValue('eedi3Rpow2')
  eedi3Rpow2,
  @JsonValue('spline36')
  spline36,
}

/// Crop/resize preset options.
enum CropResizePreset {
  @JsonValue('off')
  off,
  @JsonValue('removeOverscan')
  removeOverscan,
  @JsonValue('resize720p')
  resize720p,
  @JsonValue('resize1080p')
  resize1080p,
  @JsonValue('resize4k')
  resize4k,
  @JsonValue('custom')
  custom,
}

/// Parameters for the crop and resize pass.
@JsonSerializable()
class CropResizeParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Preset for simple mode.
  final CropResizePreset preset;

  // --- Crop Parameters (applied before resize) ---

  /// Whether to apply crop.
  final bool cropEnabled;

  /// Pixels to crop from left edge.
  final int cropLeft;

  /// Pixels to crop from right edge.
  final int cropRight;

  /// Pixels to crop from top edge.
  final int cropTop;

  /// Pixels to crop from bottom edge.
  final int cropBottom;

  // --- Resize Parameters ---

  /// Whether to apply resize.
  final bool resizeEnabled;

  /// Target width (null = auto based on height and aspect).
  final int? targetWidth;

  /// Target height (null = auto based on width and aspect).
  final int? targetHeight;

  /// Resize algorithm to use.
  final ResizeKernel kernel;

  /// Bicubic `b` (blurring), passed as `filter_param_a`.
  final double? bicubicB;

  /// Bicubic `c` (ringing), passed as `filter_param_b`.
  final double? bicubicC;

  /// Lanczos tap count, passed as `filter_param_a`.
  final int? lanczosTaps;

  /// Maintain aspect ratio when resizing.
  final bool maintainAspect;

  // --- Upscale Parameters (for integer scaling) ---

  /// Whether to use integer upscaling (2x, 4x) instead of arbitrary resize.
  final bool useIntegerUpscale;

  /// Upscale method for integer scaling.
  final UpscaleMethod upscaleMethod;

  /// Upscale factor (2 = 2x, 4 = 4x).
  final int upscaleFactor;

  // --- nnedi3 controls for the edge-directed upscale paths ---
  // With EEDI3 selected these shape the nnedi3 sclip that guides it.

  /// Neighbourhood size / shape (nnedi3 `nsize`, 0-6).
  final int? upscaleNsize;

  /// Neuron count (nnedi3 `nns`: 0=16, 1=32, 2=64, 3=128, 4=256).
  final int? upscaleNeurons;

  /// Prediction quality (nnedi3 `qual`, 1-2).
  final int? upscaleQual;

  /// Error metric used to pick the predictor (nnedi3 `etype`, 0-1).
  final int? upscaleEtype;

  /// Prescreener (nnedi3 `pscrn`, 0-4; 0 processes every pixel).
  final int? upscalePscrn;

  // --- EEDI3 controls ---

  /// Edge-direction connection cost (EEDI3 `alpha`).
  final double? upscaleAlpha;

  /// Edge-direction smoothness cost (EEDI3 `beta`).
  final double? upscaleBeta;

  /// Penalty for directions away from vertical (EEDI3 `gamma`).
  final double? upscaleGamma;

  /// Neighbourhood radius for the cost function (EEDI3 `nrad`).
  final int? upscaleNrad;

  /// Maximum search distance (EEDI3 `mdis`).
  final int? upscaleMdis;

  const CropResizeParameters({
    this.enabled = false,
    this.preset = CropResizePreset.off,
    // Crop defaults
    this.cropEnabled = false,
    this.cropLeft = 0,
    this.cropRight = 0,
    this.cropTop = 0,
    this.cropBottom = 0,
    // Resize defaults
    this.resizeEnabled = false,
    this.targetWidth,
    this.targetHeight,
    this.kernel = ResizeKernel.spline36,
    this.bicubicB,
    this.bicubicC,
    this.lanczosTaps,
    this.maintainAspect = true,
    // Upscale defaults
    this.useIntegerUpscale = false,
    this.upscaleMethod = UpscaleMethod.nnedi3Rpow2,
    this.upscaleFactor = 2,
    this.upscaleNsize,
    this.upscaleNeurons,
    this.upscaleQual,
    this.upscaleEtype,
    this.upscalePscrn,
    this.upscaleAlpha,
    this.upscaleBeta,
    this.upscaleGamma,
    this.upscaleNrad,
    this.upscaleMdis,
  });

  /// Create parameters from a preset.
  factory CropResizeParameters.fromPreset(CropResizePreset preset) {
    switch (preset) {
      case CropResizePreset.off:
        return const CropResizeParameters(
          enabled: false,
          preset: CropResizePreset.off,
        );
      case CropResizePreset.removeOverscan:
        return const CropResizeParameters(
          enabled: true,
          preset: CropResizePreset.removeOverscan,
          cropEnabled: true,
          cropLeft: 8,
          cropRight: 8,
          cropTop: 8,
          cropBottom: 8,
        );
      case CropResizePreset.resize720p:
        return const CropResizeParameters(
          enabled: true,
          preset: CropResizePreset.resize720p,
          resizeEnabled: true,
          targetWidth: 1280,
          targetHeight: 720,
          kernel: ResizeKernel.spline36,
          maintainAspect: true,
        );
      case CropResizePreset.resize1080p:
        return const CropResizeParameters(
          enabled: true,
          preset: CropResizePreset.resize1080p,
          resizeEnabled: true,
          targetWidth: 1920,
          targetHeight: 1080,
          kernel: ResizeKernel.spline36,
          maintainAspect: true,
        );
      case CropResizePreset.resize4k:
        return const CropResizeParameters(
          enabled: true,
          preset: CropResizePreset.resize4k,
          resizeEnabled: true,
          useIntegerUpscale: true,
          upscaleMethod: UpscaleMethod.nnedi3Rpow2,
          upscaleFactor: 2,
        );
      case CropResizePreset.custom:
        return const CropResizeParameters(
          enabled: true,
          preset: CropResizePreset.custom,
        );
    }
  }

  CropResizeParameters copyWith({
    bool? enabled,
    CropResizePreset? preset,
    bool? cropEnabled,
    int? cropLeft,
    int? cropRight,
    int? cropTop,
    int? cropBottom,
    bool? resizeEnabled,
    int? targetWidth,
    int? targetHeight,
    ResizeKernel? kernel,
    double? bicubicB,
    double? bicubicC,
    int? lanczosTaps,
    bool? maintainAspect,
    bool? useIntegerUpscale,
    UpscaleMethod? upscaleMethod,
    int? upscaleFactor,
    int? upscaleNsize,
    int? upscaleNeurons,
    int? upscaleQual,
    int? upscaleEtype,
    int? upscalePscrn,
    double? upscaleAlpha,
    double? upscaleBeta,
    double? upscaleGamma,
    int? upscaleNrad,
    int? upscaleMdis,
  }) {
    return CropResizeParameters(
      enabled: enabled ?? this.enabled,
      preset: preset ?? this.preset,
      cropEnabled: cropEnabled ?? this.cropEnabled,
      cropLeft: cropLeft ?? this.cropLeft,
      cropRight: cropRight ?? this.cropRight,
      cropTop: cropTop ?? this.cropTop,
      cropBottom: cropBottom ?? this.cropBottom,
      resizeEnabled: resizeEnabled ?? this.resizeEnabled,
      targetWidth: targetWidth ?? this.targetWidth,
      targetHeight: targetHeight ?? this.targetHeight,
      kernel: kernel ?? this.kernel,
      bicubicB: bicubicB ?? this.bicubicB,
      bicubicC: bicubicC ?? this.bicubicC,
      lanczosTaps: lanczosTaps ?? this.lanczosTaps,
      maintainAspect: maintainAspect ?? this.maintainAspect,
      useIntegerUpscale: useIntegerUpscale ?? this.useIntegerUpscale,
      upscaleMethod: upscaleMethod ?? this.upscaleMethod,
      upscaleFactor: upscaleFactor ?? this.upscaleFactor,
      upscaleNsize: upscaleNsize ?? this.upscaleNsize,
      upscaleNeurons: upscaleNeurons ?? this.upscaleNeurons,
      upscaleQual: upscaleQual ?? this.upscaleQual,
      upscaleEtype: upscaleEtype ?? this.upscaleEtype,
      upscalePscrn: upscalePscrn ?? this.upscalePscrn,
      upscaleAlpha: upscaleAlpha ?? this.upscaleAlpha,
      upscaleBeta: upscaleBeta ?? this.upscaleBeta,
      upscaleGamma: upscaleGamma ?? this.upscaleGamma,
      upscaleNrad: upscaleNrad ?? this.upscaleNrad,
      upscaleMdis: upscaleMdis ?? this.upscaleMdis,
    );
  }

  /// Get total horizontal crop.
  int get totalHorizontalCrop => cropLeft + cropRight;

  /// Get total vertical crop.
  int get totalVerticalCrop => cropTop + cropBottom;

  /// Get a human-readable summary of the current settings.
  String get summary {
    if (!enabled) return 'Off';
    if (preset != CropResizePreset.custom && preset != CropResizePreset.off) {
      switch (preset) {
        case CropResizePreset.removeOverscan:
          return 'Remove Overscan';
        case CropResizePreset.resize720p:
          return '720p';
        case CropResizePreset.resize1080p:
          return '1080p';
        case CropResizePreset.resize4k:
          return '4K Upscale';
        default:
          return preset.name;
      }
    }
    final parts = <String>[];
    if (cropEnabled && totalHorizontalCrop + totalVerticalCrop > 0) {
      parts.add('Crop');
    }
    if (resizeEnabled && (targetWidth != null || targetHeight != null)) {
      parts.add('${targetWidth ?? "?"}x${targetHeight ?? "?"}');
    }
    if (useIntegerUpscale) {
      parts.add('${upscaleFactor}x');
    }
    return parts.isEmpty ? 'Custom' : parts.join(' ');
  }

  factory CropResizeParameters.fromJson(Map<String, dynamic> json) =>
      _$CropResizeParametersFromJson(json);

  Map<String, dynamic> toJson() => _$CropResizeParametersToJson(this);
}
