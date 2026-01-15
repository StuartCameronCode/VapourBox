import 'package:json_annotation/json_annotation.dart';
import 'package:uuid/uuid.dart';

import 'color_correction_parameters.dart';
import 'encoding_settings.dart';
import 'noise_reduction_parameters.dart';
import 'qtgmc_parameters.dart';
import 'restoration_pipeline.dart';
import 'sharpen_parameters.dart';

part 'processing_preset.g.dart';

/// A saved preset containing filter and encoding settings.
@JsonSerializable(explicitToJson: true)
class ProcessingPreset {
  /// Unique identifier for this preset.
  final String id;

  /// User-defined name for this preset.
  final String name;

  /// Optional description of what this preset is for.
  final String? description;

  /// The restoration pipeline settings.
  final RestorationPipeline pipeline;

  /// The encoding settings.
  final EncodingSettings encodingSettings;

  /// When this preset was created.
  final DateTime createdAt;

  /// Whether this is a built-in preset (read-only).
  final bool isBuiltIn;

  ProcessingPreset({
    String? id,
    required this.name,
    this.description,
    required this.pipeline,
    required this.encodingSettings,
    DateTime? createdAt,
    this.isBuiltIn = false,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  factory ProcessingPreset.fromJson(Map<String, dynamic> json) =>
      _$ProcessingPresetFromJson(json);
  Map<String, dynamic> toJson() => _$ProcessingPresetToJson(this);

  ProcessingPreset copyWith({
    String? id,
    String? name,
    String? description,
    RestorationPipeline? pipeline,
    EncodingSettings? encodingSettings,
    DateTime? createdAt,
    bool? isBuiltIn,
  }) {
    return ProcessingPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      pipeline: pipeline ?? this.pipeline,
      encodingSettings: encodingSettings ?? this.encodingSettings,
      createdAt: createdAt ?? this.createdAt,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    );
  }

  /// Built-in preset: Fast (quick processing, lower quality).
  static ProcessingPreset builtInFast() {
    return ProcessingPreset(
      id: 'builtin-fast',
      name: 'Fast',
      description: 'Quick processing with lower quality settings',
      pipeline: RestorationPipeline(
        deinterlace: QTGMCParameters(
          enabled: true,
          preset: QTGMCPreset.faster,
        ),
      ),
      encodingSettings: EncodingSettings(
        encoderPreset: 'fast',
        quality: 20,
      ),
      isBuiltIn: true,
    );
  }

  /// Built-in preset: Balanced (good quality/speed tradeoff).
  static ProcessingPreset builtInBalanced() {
    return ProcessingPreset(
      id: 'builtin-balanced',
      name: 'Balanced',
      description: 'Good balance between quality and processing speed',
      pipeline: RestorationPipeline(
        deinterlace: QTGMCParameters(
          enabled: true,
          preset: QTGMCPreset.slow,
        ),
      ),
      encodingSettings: EncodingSettings(
        encoderPreset: 'medium',
        quality: 18,
      ),
      isBuiltIn: true,
    );
  }

  /// Built-in preset: High Quality (best quality, slower).
  static ProcessingPreset builtInHighQuality() {
    return ProcessingPreset(
      id: 'builtin-high-quality',
      name: 'High Quality',
      description: 'Maximum quality with slower processing',
      pipeline: RestorationPipeline(
        deinterlace: QTGMCParameters(
          enabled: true,
          preset: QTGMCPreset.slower,
          sourceMatch: 3,
          lossless: 2,
        ),
      ),
      encodingSettings: EncodingSettings(
        encoderPreset: 'slow',
        quality: 16,
      ),
      isBuiltIn: true,
    );
  }

  /// Built-in preset: VHS Restoration.
  static ProcessingPreset builtInVhsRestoration() {
    return ProcessingPreset(
      id: 'builtin-vhs-restoration',
      name: 'VHS Restoration',
      description: 'Optimized for VHS tape restoration',
      pipeline: RestorationPipeline(
        deinterlace: QTGMCParameters(
          enabled: true,
          preset: QTGMCPreset.slow,
        ),
        noiseReduction: NoiseReductionParameters(
          enabled: true,
          method: NoiseReductionMethod.smDegrain,
          smDegrainTr: 2,
          smDegrainThSAD: 400,
        ),
        sharpen: SharpenParameters(
          enabled: true,
          method: SharpenMethod.lsfmod,
          strength: 75,
        ),
        colorCorrection: ColorCorrectionParameters(
          enabled: true,
          saturation: 1.1,
        ),
      ),
      encodingSettings: EncodingSettings(
        encoderPreset: 'slow',
        quality: 17,
      ),
      isBuiltIn: true,
    );
  }

  /// Get all built-in presets.
  static List<ProcessingPreset> builtInPresets() {
    return [
      builtInFast(),
      builtInBalanced(),
      builtInHighQuality(),
      builtInVhsRestoration(),
    ];
  }
}
