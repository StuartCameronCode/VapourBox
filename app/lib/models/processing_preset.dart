import 'package:json_annotation/json_annotation.dart';
import 'package:uuid/uuid.dart';

import 'chroma_denoise_parameters.dart';
import 'chroma_fix_parameters.dart';
import 'deband_parameters.dart';
import 'deblock_parameters.dart';
import 'dehalo_parameters.dart';
import 'descratch_parameters.dart';
import 'encoding_settings.dart';
import 'noise_reduction_parameters.dart';
import 'qtgmc_parameters.dart';
import 'sharpen_parameters.dart';
import 'stabilize_parameters.dart';
import 'processing_pipeline.dart';
import 'spotless_parameters.dart';
import 'video_job.dart';

part 'processing_preset.g.dart';

/// What kind of choice a preset represents, which is how the preset menu groups
/// them.
///
/// Mixing "how hard should it try" with "what did you capture" in one flat list
/// makes both harder to pick from — they answer different questions.
enum PresetCategory {
  /// A quality/speed tier. Differs from its siblings only in effort, not in
  /// which problems it fixes.
  @JsonValue('quality')
  quality,

  /// Shaped for a kind of source: a VHS tape, a DVD, a film scan.
  @JsonValue('source')
  source,

  /// Anything the user saved themselves.
  @JsonValue('custom')
  custom,
}

/// A saved preset containing filter and encoding settings.
@JsonSerializable(explicitToJson: true)
class ProcessingPreset {
  /// Unique identifier for this preset.
  final String id;

  /// User-defined name for this preset.
  final String name;

  /// Optional description of what this preset is for.
  final String? description;

  /// The processing pipeline settings.
  final ProcessingPipeline pipeline;

  /// The encoding settings.
  final EncodingSettings encodingSettings;

  /// When this preset was created.
  final DateTime createdAt;

  /// Whether this is a built-in preset (read-only).
  final bool isBuiltIn;

  /// Which group this belongs to in the preset menu. Declared by each built-in
  /// factory rather than looked up from a list of ids elsewhere, so a new preset
  /// cannot silently land in the wrong group. Defaults to [PresetCategory.custom],
  /// which is right for anything a user saves and for presets saved before this
  /// field existed.
  final PresetCategory category;

  ProcessingPreset({
    String? id,
    required this.name,
    this.description,
    required this.pipeline,
    required this.encodingSettings,
    DateTime? createdAt,
    this.isBuiltIn = false,
    this.category = PresetCategory.custom,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  factory ProcessingPreset.fromJson(Map<String, dynamic> json) =>
      _$ProcessingPresetFromJson(json);
  Map<String, dynamic> toJson() => _$ProcessingPresetToJson(this);

  ProcessingPreset copyWith({
    String? id,
    String? name,
    String? description,
    ProcessingPipeline? pipeline,
    EncodingSettings? encodingSettings,
    DateTime? createdAt,
    bool? isBuiltIn,
    PresetCategory? category,
  }) {
    return ProcessingPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      pipeline: pipeline ?? this.pipeline,
      encodingSettings: encodingSettings ?? this.encodingSettings,
      createdAt: createdAt ?? this.createdAt,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      category: category ?? this.category,
    );
  }

  /// Built-in preset: Fast (quick processing, lower quality).
  static ProcessingPreset builtInFast() {
    return ProcessingPreset(
      id: 'builtin-fast',
      name: 'Fast',
      description: 'Quick processing with lower quality settings',
      pipeline: ProcessingPipeline(
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
      category: PresetCategory.quality,
    );
  }

  /// Built-in preset: Balanced (good quality/speed tradeoff).
  static ProcessingPreset builtInBalanced() {
    return ProcessingPreset(
      id: 'builtin-balanced',
      name: 'Balanced',
      description: 'Good balance between quality and processing speed',
      pipeline: ProcessingPipeline(
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
      category: PresetCategory.quality,
    );
  }

  /// Built-in preset: High Quality (best quality, slower).
  static ProcessingPreset builtInHighQuality() {
    return ProcessingPreset(
      id: 'builtin-high-quality',
      name: 'High Quality',
      description: 'Maximum quality with slower processing',
      pipeline: ProcessingPipeline(
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
      category: PresetCategory.quality,
    );
  }

  /// Built-in preset: VHS Cleanup.
  static ProcessingPreset builtInVhsCleanup() {
    return ProcessingPreset(
      id: 'builtin-vhs-cleanup',
      name: 'VHS Cleanup',
      description: 'Optimized for VHS tape cleanup',
      pipeline: ProcessingPipeline(
        deinterlace: QTGMCParameters(
          enabled: true,
        ),
        noiseReduction: NoiseReductionParameters(
          enabled: true,
          preset: NoiseReductionPreset.custom,
          method: NoiseReductionMethod.smDegrain,
          smDegrainTr: 2,
          smDegrainThSAD: 300,
          smDegrainThSADC: 150,
          smDegrainRefine: true,
          smDegrainPrefilter: 2,
        ),
        // CCD is the filter the restoration community reaches for first on
        // tape, and it was shipping unused: chroma noise on VHS is a different
        // failure from the luma grain SMDegrain handles, so one does not cover
        // the other.
        chromaDenoise: ChromaDenoiseParameters(
          enabled: true,
          threshold: 5.0,
        ),
        dehalo: DehaloParameters(
          enabled: true,
          method: DehaloMethod.dehaloAlpha,
          rx: 3.0,
          ry: 3.0,
        ),
        // Composite captures are soft, and LSFmod is the sharpener that suits
        // them because it is built not to add halos — which matters here more
        // than usual, since the dehalo pass above has just removed some.
        // Modest strength: this runs after a denoise, and sharpening a denoised
        // picture hard is how tape captures end up looking artificial.
        sharpen: SharpenParameters(
          enabled: true,
          method: SharpenMethod.lsfmod,
          strength: 80,
        ),
      ),
      encodingSettings: EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        encoderPreset: 'medium',
        quality: 18,
      ),
      isBuiltIn: true,
      category: PresetCategory.source,
    );
  }

  /// Built-in preset: DVD IVTC.
  static ProcessingPreset builtInDvdIvtc() {
    return ProcessingPreset(
      id: 'builtin-dvd-ivtc',
      name: 'DVD IVTC',
      description: 'Inverse telecine for NTSC DVD sources (29.97i \u2192 23.976p)',
      pipeline: ProcessingPipeline(
        deinterlace: QTGMCParameters(
          enabled: true,
          method: DeinterlaceMethod.ivtc,
          ivtcOrder: 1, // TFF (standard for DVD)
          ivtcMode: 1,
          ivtcCycle: 5,
        ),
      ),
      encodingSettings: EncodingSettings(
        encoderPreset: 'medium',
        quality: 18,
      ),
      isBuiltIn: true,
      category: PresetCategory.source,
    );
  }

  /// Built-in preset: PAL DVD / digital broadcast (576i MPEG-2).
  ///
  /// Named for the source rather than the technique, which is the point: the
  /// user knows what they fed in, not which denoiser it wants. MPEG-2 at DVD and
  /// broadcast bitrates blocks visibly, so this pairs deinterlacing with a
  /// deblock and deliberately leaves denoising off — the picture is usually
  /// clean, and denoising it costs detail for nothing.
  static ProcessingPreset builtInPalDvd() {
    return ProcessingPreset(
      id: 'builtin-pal-dvd',
      name: 'PAL DVD / Broadcast',
      description: 'Interlaced 576i MPEG-2: deinterlace and deblock, no denoise',
      pipeline: ProcessingPipeline(
        deinterlace: QTGMCParameters(
          enabled: true,
          preset: QTGMCPreset.slow,
        ),
        deblock: DeblockParameters(
          enabled: true,
          method: DeblockMethod.deblockQed,
        ),
      ),
      encodingSettings: EncodingSettings(
        encoderPreset: 'medium',
        quality: 18,
      ),
      isBuiltIn: true,
      category: PresetCategory.source,
    );
  }

  /// Built-in preset: DV camcorder tape (DV/DVCAM, interlaced).
  ///
  /// DV's heavily subsampled chroma (4:1:1 on NTSC, 4:2:0 on PAL) misaligns and
  /// bleeds, so the chroma work matters more here than the noise work. Noise is
  /// light rather than off: DV tape is grainier than a DVD but far cleaner than
  /// VHS.
  static ProcessingPreset builtInDvCamcorder() {
    return ProcessingPreset(
      id: 'builtin-dv-camcorder',
      name: 'DV Camcorder Tape',
      description: 'Interlaced DV: deinterlace, fix chroma alignment, light denoise',
      pipeline: ProcessingPipeline(
        deinterlace: QTGMCParameters(
          enabled: true,
          preset: QTGMCPreset.slow,
          chromaUpsampleFix: true,
        ),
        // fromPreset, not `preset:` — the enum on its own is only a label, and
        // passing it without the matching values leaves every threshold at its
        // default, i.e. "light" would denoise exactly as hard as "moderate".
        noiseReduction:
            NoiseReductionParameters.fromPreset(NoiseReductionPreset.light),
        chromaFixes: ChromaFixParameters(
          enabled: true,
          preset: ChromaFixPreset.custom,
          applyChromaBleedingFix: true,
        ),
        // DV's chroma is heavily subsampled and noisy with it, and the light
        // luma denoise above deliberately leaves it alone. Gentler than the VHS
        // setting: DV chroma is misaligned more than it is dirty.
        chromaDenoise: ChromaDenoiseParameters(
          enabled: true,
          threshold: 3.0,
        ),
      ),
      encodingSettings: EncodingSettings(
        encoderPreset: 'medium',
        quality: 18,
      ),
      isBuiltIn: true,
      category: PresetCategory.source,
    );
  }

  /// Built-in preset: 8mm / Super 8 film scan.
  ///
  /// A film scan is already progressive, so deinterlacing is off — running it
  /// would only soften the picture. What film has instead is physical damage,
  /// which is what DeScratch and SpotLess are for. Encodes to FFV1 because a
  /// scan is usually a master, not a delivery copy.
  static ProcessingPreset builtInFilmScan() {
    return ProcessingPreset(
      id: 'builtin-film-scan',
      name: '8mm / Super 8 Film Scan',
      description:
          'Progressive film scan: dust, scratches and grain — no deinterlacing',
      pipeline: ProcessingPipeline(
        // Explicitly off, and it has to be: QTGMCParameters defaults to
        // `enabled: true`, so a preset that simply omits deinterlacing gets it
        // anyway — which on a progressive scan just softens the picture.
        deinterlace: QTGMCParameters(enabled: false),
        descratch: DeScratchParameters(enabled: true),
        spotless: SpotLessParameters(enabled: true),
        noiseReduction:
            NoiseReductionParameters.fromPreset(NoiseReductionPreset.moderate),
        // Gate weave is the first thing anyone notices on a cine scan, and this
        // pass shipped for exactly this source while no preset used it. The
        // pipeline already runs Stabilize last before Crop/Resize, so the thin
        // empty edges it exposes can be cropped afterwards.
        stabilize: StabilizeParameters(enabled: true),
      ),
      encodingSettings: EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        encoderPreset: 'medium',
        quality: 18,
      ),
      isBuiltIn: true,
      category: PresetCategory.source,
    );
  }

  /// Built-in preset: anime DVD (telecined film, drawn line art).
  ///
  /// Telecined, so it wants IVTC rather than deinterlacing. Line art shows the
  /// two faults live action mostly hides: halos from the broadcast chain's
  /// sharpening, and banding across the large flat colour areas.
  static ProcessingPreset builtInAnimeDvd() {
    return ProcessingPreset(
      id: 'builtin-anime-dvd',
      name: 'Anime DVD',
      description: 'Telecined line art: inverse telecine, dehalo and deband',
      pipeline: ProcessingPipeline(
        deinterlace: QTGMCParameters(
          enabled: true,
          method: DeinterlaceMethod.ivtc,
          ivtcOrder: 1,
          ivtcMode: 1,
          ivtcCycle: 5,
        ),
        dehalo: DehaloParameters(
          enabled: true,
          method: DehaloMethod.fineDehalo,
        ),
        deband: DebandParameters(enabled: true),
        // Composite-mastered anime discs are notorious for rainbowing on fine
        // line art. LUTDeRainbow shipped for this and was used by nothing.
        chromaFixes: ChromaFixParameters(
          enabled: true,
          preset: ChromaFixPreset.custom,
          applyDeRainbow: true,
        ),
      ),
      encodingSettings: EncodingSettings(
        encoderPreset: 'medium',
        quality: 18,
      ),
      isBuiltIn: true,
      category: PresetCategory.source,
    );
  }

  /// Get all built-in presets.
  ///
  /// Ordered so the source-shaped presets come after the three quality tiers:
  /// a user who knows what they captured should be able to find it by name.
  static List<ProcessingPreset> builtInPresets() {
    return [
      builtInFast(),
      builtInBalanced(),
      builtInHighQuality(),
      builtInVhsCleanup(),
      builtInDvCamcorder(),
      builtInPalDvd(),
      builtInDvdIvtc(),
      builtInAnimeDvd(),
      builtInFilmScan(),
    ];
  }
}
