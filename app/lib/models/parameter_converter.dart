import 'chroma_denoise_parameters.dart';
import 'chroma_fix_parameters.dart';
import 'color_correction_parameters.dart';
import 'crop_resize_parameters.dart';
import 'deband_parameters.dart';
import 'deblock_parameters.dart';
import 'descratch_parameters.dart';
import 'spotless_parameters.dart';
import 'dehalo_parameters.dart';
import 'dynamic_parameters.dart';
import 'noise_reduction_parameters.dart';
import 'qtgmc_parameters.dart';
import 'processing_pipeline.dart';
import 'sharpen_parameters.dart';
import 'subtitle_parameters.dart';

/// Converts typed parameter classes to DynamicParameters for schema-based processing.
class ParameterConverter {
  /// Convert QTGMC parameters to dynamic format.
  static DynamicParameters fromQTGMC(QTGMCParameters params) {
    String method;
    switch (params.method) {
      case DeinterlaceMethod.qtgmc:
        method = 'qtgmc';
        break;
      case DeinterlaceMethod.ivtc:
        method = 'ivtc';
        break;
      case DeinterlaceMethod.softTelecine:
        method = 'soft_telecine';
        break;
    }

    return DynamicParameters(
      filterId: 'deinterlace',
      enabled: params.enabled,
      values: {
        'method': method,
        'preset': params.preset.displayName,
        'tff': params.tff,
        'fpsDivisor': params.fpsDivisor,
        // Null means "not set" in the model; surface the effective default so
        // the checkbox always reflects what the worker will actually do.
        'chromaUpsampleFix': params.chromaUpsampleFix ?? false,
        'highPrecision': params.highPrecision ?? false,
        'inputType': params.inputType,
        'tr0': params.tr0,
        'tr1': params.tr1,
        'tr2': params.tr2,
        'rep0': params.rep0,
        'rep1': params.rep1,
        'rep2': params.rep2,
        'repChroma': params.repChroma,
        'ediMode': params.ediMode,
        'ediQual': params.ediQual,
        'nnSize': params.nnSize,
        'nnNeurons': params.nnNeurons,
        'ediMaxD': params.ediMaxD,
        'chromaEdi': params.chromaEdi,
        'sharpness': params.sharpness,
        'sMode': params.sMode,
        'slMode': params.slMode,
        'slRad': params.slRad,
        'sOvs': params.sOvs,
        'svThin': params.svThin,
        'sbb': params.sbb,
        'srchClipPp': params.srchClipPp,
        'sourceMatch': params.sourceMatch,
        'matchPreset': params.matchPreset,
        'matchEdi': params.matchEdi,
        'matchPreset2': params.matchPreset2,
        'matchEdi2': params.matchEdi2,
        'matchTr2': params.matchTr2,
        'matchEnhance': params.matchEnhance,
        'lossless': params.lossless,
        'noiseProcess': params.noiseProcess,
        'ezDenoise': params.ezDenoise,
        'ezKeepGrain': params.ezKeepGrain,
        'noisePreset': params.noisePreset,
        'denoiser': params.denoiser,
        'fftThreads': params.fftThreads,
        'denoiseMc': params.denoiseMc,
        'noiseTr': params.noiseTr,
        'sigma': params.sigma,
        'chromaNoise': params.chromaNoise,
        'showNoise': params.showNoise,
        'grainRestore': params.grainRestore,
        'noiseRestore': params.noiseRestore,
        'noiseDeint': params.noiseDeint,
        'stabilizeNoise': params.stabilizeNoise,
        'chromaMotion': params.chromaMotion,
        'trueMotion': params.trueMotion,
        'blockSize': params.blockSize,
        'overlap': params.overlap,
        'search': params.search,
        'searchParam': params.searchParam,
        'pelSearch': params.pelSearch,
        'lambda': params.lambda,
        'lsad': params.lsad,
        'pNew': params.pNew,
        'pLevel': params.pLevel,
        'globalMotion': params.globalMotion,
        'dct': params.dct,
        'subPel': params.subPel,
        'subPelInterp': params.subPelInterp,
        'thSad1': params.thSad1,
        'thSad2': params.thSad2,
        'thScd1': params.thScd1,
        'thScd2': params.thScd2,
        'border': params.border,
        'precise': params.precise,
        'forceTr': params.forceTr,
        'str': params.str,
        'amp': params.amp,
        'fastMa': params.fastMa,
        'eSearchP': params.eSearchP,
        'refineMotion': params.refineMotion,
        'opencl': params.opencl,
        'device': params.device,
        'ivtcOrder': params.ivtcOrder,
        'ivtcMode': params.ivtcMode,
        'ivtcCthresh': params.ivtcCthresh,
        'ivtcMi': params.ivtcMi,
        'ivtcBlockX': params.ivtcBlockX,
        'ivtcBlockY': params.ivtcBlockY,
        'ivtcCycle': params.ivtcCycle,
        'ivtcDupthresh': params.ivtcDupthresh,
        'ivtcScthresh': params.ivtcScthresh,
      },
    );
  }

  /// Convert noise reduction parameters to dynamic format.
  static DynamicParameters fromNoiseReduction(NoiseReductionParameters params) {
    String method;
    switch (params.method) {
      case NoiseReductionMethod.smDegrain:
        method = 'smdegrain';
        break;
      case NoiseReductionMethod.mcTemporalDenoise:
        method = 'mc_temporal_denoise';
        break;
      case NoiseReductionMethod.qtgmcBuiltin:
        method = 'qtgmc_builtin';
        break;
    }

    return DynamicParameters(
      filterId: 'noise_reduction',
      enabled: params.enabled,
      values: {
        'method': method,
        'smDegrainTr': params.smDegrainTr,
        'smDegrainThSAD': params.smDegrainThSAD,
        'smDegrainThSADC': params.smDegrainThSADC,
        'smDegrainRefine': params.smDegrainRefine,
        'smDegrainPrefilter': params.smDegrainPrefilter,
        'mcTemporalSigma': params.mcTemporalSigma,
        'mcTemporalRadius': params.mcTemporalRadius,
        'mcTemporalProfile': params.mcTemporalProfile,
        'qtgmcEzDenoise': params.qtgmcEzDenoise,
        'qtgmcEzKeepGrain': params.qtgmcEzKeepGrain,
      },
    );
  }

  /// Read an int that may have come back from the UI as a string.
  ///
  /// Enum dropdowns hand back the raw option value, and a numeric enum's
  /// options are strings in the schema (`["1", "16", "17", "18"]`), so the same
  /// parameter can arrive as `17` (from a converter) or `"17"` (after the user
  /// picks from the dropdown). A plain `as int?` cast throws on the latter.
  static int? _asInt(dynamic value) => switch (value) {
        num n => n.toInt(),
        String s => int.tryParse(s),
        _ => null,
      };

  /// Schema method id for a [DehaloMethod].
  static String dehaloMethodId(DehaloMethod method) => switch (method) {
        DehaloMethod.dehaloAlpha => 'dehalo_alpha',
        DehaloMethod.fineDehalo => 'fine_dehalo',
        DehaloMethod.fineDehalo2 => 'fine_dehalo2',
        DehaloMethod.yahr => 'yahr',
        DehaloMethod.edgeCleaner => 'edge_cleaner',
        DehaloMethod.vinverse => 'vinverse',
        DehaloMethod.vinverse2 => 'vinverse2',
      };

  /// Convert chroma denoise (CCD) parameters to dynamic format.
  static DynamicParameters fromChromaDenoise(ChromaDenoiseParameters params) {
    return DynamicParameters(
      filterId: 'chroma_denoise',
      enabled: params.enabled,
      values: {
        'method': 'ccd',
        'threshold': params.threshold,
        'temporalRadius': params.temporalRadius,
        'pointsLow': params.pointsLow,
        'pointsMedium': params.pointsMedium,
        'pointsHigh': params.pointsHigh,
        if (params.scale != null) 'scale': params.scale,
      },
      // Left off, scale is derived from the frame height at run time — which is
      // both the plugin's own behaviour and the only value that works on short
      // sources, so it should not start ticked.
      lastOptionalValues: {
        if (params.scale == null) 'scale': 1.0,
      },
    );
  }

  /// Convert dehalo parameters to dynamic format.
  static DynamicParameters fromDehalo(DehaloParameters params) {
    // Parameters added after the pass shipped are nullable: a null goes to
    // lastOptionalValues so its checkbox starts unticked and havsfunc's own
    // default applies, instead of the UI claiming every knob is in use.
    final values = <String, dynamic>{
      'method': dehaloMethodId(params.method),
      'rx': params.rx,
      'ry': params.ry,
      'darkStr': params.darkStr,
      'brightStr': params.brightStr,
      'lowThreshold': params.lowThreshold,
      'highThreshold': params.highThreshold,
      'yahrBlur': params.yahrBlur,
      'yahrDepth': params.yahrDepth,
    };
    final lastOptional = <String, dynamic>{};

    void optional(String key, dynamic value, dynamic fallback) {
      if (value != null) {
        values[key] = value;
      } else {
        lastOptional[key] = fallback;
      }
    }

    // Fallbacks mirror havsfunc's defaults, so ticking a checkbox starts from
    // the value the filter would have used anyway.
    optional('lowSens', params.lowSens, 50);
    optional('highSens', params.highSens, 50);
    optional('superSample', params.superSample, 1.5);
    optional('limitLow', params.limitLow, 50);
    optional('limitHigh', params.limitHigh, 100);
    optional('contra', params.contra, 0.0);
    optional('excludeCloseEdges', params.excludeCloseEdges, true);
    optional('edgeProc', params.edgeProc, 0.0);
    optional('edgeStrength', params.edgeStrength, 10);
    optional('edgeRepair', params.edgeRepair, true);
    optional('edgeRepairMode', params.edgeRepairMode, 17);
    optional('edgeSmallMode', params.edgeSmallMode, 0);
    optional('edgeHotPixels', params.edgeHotPixels, false);
    optional('vinverseStrength', params.vinverseStrength, 2.7);
    optional('vinverseAmount', params.vinverseAmount, 255);
    optional('vinverseChroma', params.vinverseChroma, true);

    return DynamicParameters(
      filterId: 'dehalo',
      enabled: params.enabled,
      values: values,
      lastOptionalValues: lastOptional,
    );
  }

  /// Convert deblock parameters to dynamic format.
  static DynamicParameters fromDeblock(DeblockParameters params) {
    String method;
    switch (params.method) {
      case DeblockMethod.deblockQed:
        method = 'deblock_qed';
        break;
      case DeblockMethod.deblock:
        method = 'deblock';
        break;
    }

    return DynamicParameters(
      filterId: 'deblock',
      enabled: params.enabled,
      values: {
        'method': method,
        'quant1': params.quant1,
        'quant2': params.quant2,
        'aOffset1': params.aOffset1,
        'aOffset2': params.aOffset2,
      },
    );
  }

  /// Convert descratch parameters to dynamic format.
  /// All parameters are optional and default to off (not passed to VapourSynth).
  static DynamicParameters fromDeScratch(DeScratchParameters params) {
    return DynamicParameters(
      filterId: 'descratch',
      enabled: params.enabled,
      values: {},
      lastOptionalValues: {
        'mindif': params.mindif,
        'asym': params.asym,
        'maxgap': params.maxgap,
        'maxwidth': params.maxwidth,
        'minwidth': params.minwidth,
        'minlen': params.minlen,
        'maxlen': params.maxlen,
        'maxangle': params.maxangle,
        'blurlen': params.blurlen,
        'keep': params.keep,
        'border': params.border,
        'modeY': params.modeY,
        'modeU': params.modeU,
        'modeV': params.modeV,
        'mindifUV': params.mindifUV,
      },
    );
  }

  /// Convert spotless parameters to dynamic format.
  /// All parameters are optional and default to off (not passed to VapourSynth).
  static DynamicParameters fromSpotLess(SpotLessParameters params) {
    return DynamicParameters(
      filterId: 'spotless',
      enabled: params.enabled,
      values: {},
      lastOptionalValues: {
        'chroma': params.chroma,
        'rec': params.rec,
        'blksize': params.blksize,
        'overlap': params.overlap,
        'pel': params.pel,
      },
    );
  }

  /// Convert deband parameters to dynamic format.
  static DynamicParameters fromDeband(DebandParameters params) {
    return DynamicParameters(
      filterId: 'deband',
      enabled: params.enabled,
      values: {
        'method': 'f3kdb',
        'range': params.range,
        'y': params.y,
        'cb': params.cb,
        'cr': params.cr,
        'grainY': params.grainY,
        'grainC': params.grainC,
        'dynamicGrain': params.dynamicGrain,
        'outputDepth': params.outputDepth,
      },
    );
  }

  /// Convert sharpen parameters to dynamic format.
  static DynamicParameters fromSharpen(SharpenParameters params) {
    String method;
    switch (params.method) {
      case SharpenMethod.lsfmod:
        method = 'lsfmod';
        break;
      case SharpenMethod.cas:
        method = 'cas';
        break;
    }

    return DynamicParameters(
      filterId: 'sharpen',
      enabled: params.enabled,
      values: {
        'method': method,
        'strength': params.strength,
        'overshoot': params.overshoot,
        'undershoot': params.undershoot,
        'softEdge': params.softEdge,
        'casSharpness': params.casSharpness,
      },
    );
  }

  /// Convert color correction parameters to dynamic format.
  static DynamicParameters fromColorCorrection(ColorCorrectionParameters params) {
    return DynamicParameters(
      filterId: 'color_correction',
      enabled: params.enabled,
      values: {
        'method': 'tweak',
        'brightness': params.brightness,
        'contrast': params.contrast,
        'hue': params.hue,
        'saturation': params.saturation,
        'coring': params.coring,
        'applyLevels': params.applyLevels,
        'inputLow': params.inputLow,
        'inputHigh': params.inputHigh,
        'outputLow': params.outputLow,
        'outputHigh': params.outputHigh,
        'gamma': params.gamma,
        'temperature': params.temperature,
        'tint': params.tint,
      },
    );
  }

  /// Convert chroma fix parameters to dynamic format.
  static DynamicParameters fromChromaFixes(ChromaFixParameters params) {
    return DynamicParameters(
      filterId: 'chroma_fixes',
      enabled: params.enabled,
      values: {
        'applyChromaShift': params.applyChromaShift,
        'chromaShiftH': params.chromaShiftH,
        'chromaShiftV': params.chromaShiftV,
        'applyChromaBleedingFix': params.applyChromaBleedingFix,
        'chromaBleedCx': params.chromaBleedCx,
        'chromaBleedCy': params.chromaBleedCy,
        'chromaBleedCBlur': params.chromaBleedCBlur,
        'chromaBleedStrength': params.chromaBleedStrength,
        'applyDeCrawl': params.applyDeCrawl,
        'deCrawlYThresh': params.deCrawlYThresh,
        'deCrawlCThresh': params.deCrawlCThresh,
        'deCrawlMaxDiff': params.deCrawlMaxDiff,
        'applyVinverse': params.applyVinverse,
        'vinverseSstr': params.vinverseSstr,
        'vinverseAmnt': params.vinverseAmnt,
      },
    );
  }

  /// Convert crop resize parameters to dynamic format.
  static DynamicParameters fromCropResize(CropResizeParameters params) {
    final values = <String, dynamic>{
      'cropEnabled': params.cropEnabled,
      'cropLeft': params.cropLeft,
      'cropRight': params.cropRight,
      'cropTop': params.cropTop,
      'cropBottom': params.cropBottom,
      'resizeEnabled': params.resizeEnabled,
      'targetWidth': params.targetWidth,
      'targetHeight': params.targetHeight,
      'kernel': params.kernel.name,
      'maintainAspect': params.maintainAspect,
      'useIntegerUpscale': params.useIntegerUpscale,
      'upscaleMethod': params.upscaleMethod.name,
      'upscaleFactor': params.upscaleFactor,
    };
    // Kernel tuning and the nnedi3/EEDI3 controls start unticked, so the
    // plugin's own default applies until the user opts in. Fallbacks are those
    // defaults, so ticking a box changes nothing until the value is moved.
    final lastOptional = <String, dynamic>{};
    void optional(String key, dynamic value, dynamic fallback) {
      if (value != null) {
        values[key] = value;
      } else {
        lastOptional[key] = fallback;
      }
    }

    optional('bicubicB', params.bicubicB, 0.0);
    optional('bicubicC', params.bicubicC, 0.5);
    optional('lanczosTaps', params.lanczosTaps, 3);
    optional('upscaleNsize', params.upscaleNsize, 6);
    optional('upscaleNeurons', params.upscaleNeurons, 1);
    optional('upscaleQual', params.upscaleQual, 1);
    optional('upscaleEtype', params.upscaleEtype, 0);
    optional('upscalePscrn', params.upscalePscrn, 2);
    optional('upscaleAlpha', params.upscaleAlpha, 0.2);
    optional('upscaleBeta', params.upscaleBeta, 0.25);
    optional('upscaleGamma', params.upscaleGamma, 20.0);
    optional('upscaleNrad', params.upscaleNrad, 2);
    optional('upscaleMdis', params.upscaleMdis, 20);

    return DynamicParameters(
      filterId: 'crop_resize',
      enabled: params.enabled,
      values: values,
      lastOptionalValues: lastOptional,
    );
  }

  /// Convert subtitle parameters to dynamic format.
  static DynamicParameters fromSubtitles(SubtitleParameters params) {
    return DynamicParameters(
      filterId: 'subtitles',
      enabled: params.enabled,
      values: {
        'method': 'whisper',
        'model': params.model.value,
        'output': params.output.value,
        'language': params.language ?? 'auto',
      },
    );
  }

  /// Convert a full processing pipeline to a dynamic pipeline.
  static DynamicPipeline fromPipeline(ProcessingPipeline pipeline) {
    return DynamicPipeline(
      filters: {
        'deinterlace': fromQTGMC(pipeline.deinterlace),
        'descratch': fromDeScratch(pipeline.descratch),
        'spotless': fromSpotLess(pipeline.spotless),
        'noise_reduction': fromNoiseReduction(pipeline.noiseReduction),
        'chroma_denoise': fromChromaDenoise(pipeline.chromaDenoise),
        'dehalo': fromDehalo(pipeline.dehalo),
        'deblock': fromDeblock(pipeline.deblock),
        'deband': fromDeband(pipeline.deband),
        'sharpen': fromSharpen(pipeline.sharpen),
        'color_correction': fromColorCorrection(pipeline.colorCorrection),
        'chroma_fixes': fromChromaFixes(pipeline.chromaFixes),
        'crop_resize': fromCropResize(pipeline.cropResize),
        'subtitles': fromSubtitles(pipeline.subtitles),
      },
    );
  }

  // ============================================================
  // Reverse conversions: DynamicParameters -> typed parameters
  // ============================================================

  /// Convert dynamic parameters to QTGMC parameters.
  static QTGMCParameters toQTGMC(DynamicParameters params) {
    final v = params.values;
    final presetStr = v['preset'] as String? ?? 'Slower';
    final methodStr = v['method'] as String? ?? 'qtgmc';
    DeinterlaceMethod method;
    switch (methodStr) {
      case 'ivtc':
        method = DeinterlaceMethod.ivtc;
        break;
      case 'soft_telecine':
        method = DeinterlaceMethod.softTelecine;
        break;
      default:
        method = DeinterlaceMethod.qtgmc;
    }

    return QTGMCParameters(
      enabled: params.enabled,
      method: method,
      preset: QTGMCPreset.values.firstWhere(
        (p) => p.displayName == presetStr || p.name == presetStr.toLowerCase(),
        orElse: () => QTGMCPreset.slower,
      ),
      tff: v['tff'] as bool?,
      fpsDivisor: v['fpsDivisor'] as int?,
      chromaUpsampleFix: v['chromaUpsampleFix'] as bool?,
      highPrecision: v['highPrecision'] as bool?,
      inputType: v['inputType'] as int?,
      tr0: v['tr0'] as int?,
      tr1: v['tr1'] as int?,
      tr2: v['tr2'] as int?,
      rep0: v['rep0'] as int?,
      rep1: v['rep1'] as int?,
      rep2: v['rep2'] as int?,
      repChroma: v['repChroma'] as bool?,
      ediMode: v['ediMode'] as String?,
      ediQual: v['ediQual'] as int?,
      nnSize: v['nnSize'] as int?,
      nnNeurons: v['nnNeurons'] as int?,
      ediMaxD: v['ediMaxD'] as int?,
      chromaEdi: v['chromaEdi'] as String?,
      sharpness: (v['sharpness'] as num?)?.toDouble(),
      sMode: v['sMode'] as int?,
      slMode: v['slMode'] as int?,
      slRad: v['slRad'] as int?,
      sOvs: v['sOvs'] as int?,
      svThin: (v['svThin'] as num?)?.toDouble(),
      sbb: v['sbb'] as int?,
      srchClipPp: v['srchClipPp'] as int?,
      sourceMatch: v['sourceMatch'] as int?,
      matchPreset: v['matchPreset'] as String?,
      matchEdi: v['matchEdi'] as String?,
      matchPreset2: v['matchPreset2'] as String?,
      matchEdi2: v['matchEdi2'] as String?,
      matchTr2: v['matchTr2'] as int?,
      matchEnhance: (v['matchEnhance'] as num?)?.toDouble(),
      lossless: v['lossless'] as int?,
      noiseProcess: v['noiseProcess'] as int?,
      ezDenoise: (v['ezDenoise'] as num?)?.toDouble(),
      ezKeepGrain: (v['ezKeepGrain'] as num?)?.toDouble(),
      noisePreset: v['noisePreset'] as String?,
      denoiser: v['denoiser'] as String?,
      fftThreads: v['fftThreads'] as int?,
      denoiseMc: v['denoiseMc'] as bool?,
      noiseTr: v['noiseTr'] as int?,
      sigma: (v['sigma'] as num?)?.toDouble(),
      chromaNoise: v['chromaNoise'] as bool?,
      showNoise: (v['showNoise'] as num?)?.toDouble(),
      grainRestore: (v['grainRestore'] as num?)?.toDouble(),
      noiseRestore: (v['noiseRestore'] as num?)?.toDouble(),
      noiseDeint: v['noiseDeint'] as String?,
      stabilizeNoise: v['stabilizeNoise'] as bool?,
      chromaMotion: v['chromaMotion'] as bool?,
      trueMotion: v['trueMotion'] as bool?,
      blockSize: v['blockSize'] as int?,
      overlap: v['overlap'] as int?,
      search: v['search'] as int?,
      searchParam: v['searchParam'] as int?,
      pelSearch: v['pelSearch'] as int?,
      lambda: v['lambda'] as int?,
      lsad: v['lsad'] as int?,
      pNew: v['pNew'] as int?,
      pLevel: v['pLevel'] as int?,
      globalMotion: v['globalMotion'] as bool?,
      dct: v['dct'] as int?,
      subPel: v['subPel'] as int?,
      subPelInterp: v['subPelInterp'] as int?,
      thSad1: v['thSad1'] as int?,
      thSad2: v['thSad2'] as int?,
      thScd1: v['thScd1'] as int?,
      thScd2: v['thScd2'] as int?,
      border: v['border'] as bool?,
      precise: v['precise'] as bool?,
      forceTr: v['forceTr'] as int?,
      str: (v['str'] as num?)?.toDouble(),
      amp: (v['amp'] as num?)?.toDouble(),
      fastMa: v['fastMa'] as bool?,
      eSearchP: v['eSearchP'] as bool?,
      refineMotion: v['refineMotion'] as bool?,
      opencl: v['opencl'] as bool?,
      device: v['device'] as int?,
      ivtcOrder: v['ivtcOrder'] as int?,
      ivtcMode: v['ivtcMode'] as int?,
      ivtcCthresh: v['ivtcCthresh'] as int?,
      ivtcMi: v['ivtcMi'] as int?,
      ivtcBlockX: v['ivtcBlockX'] as int?,
      ivtcBlockY: v['ivtcBlockY'] as int?,
      ivtcCycle: v['ivtcCycle'] as int?,
      ivtcDupthresh: (v['ivtcDupthresh'] as num?)?.toDouble(),
      ivtcScthresh: (v['ivtcScthresh'] as num?)?.toDouble(),
    );
  }

  /// Convert dynamic parameters to noise reduction parameters.
  static NoiseReductionParameters toNoiseReduction(DynamicParameters params) {
    final v = params.values;
    final methodStr = v['method'] as String? ?? 'smdegrain';
    NoiseReductionMethod method;
    switch (methodStr) {
      case 'mc_temporal_denoise':
        method = NoiseReductionMethod.mcTemporalDenoise;
        break;
      case 'qtgmc_builtin':
        method = NoiseReductionMethod.qtgmcBuiltin;
        break;
      default:
        method = NoiseReductionMethod.smDegrain;
    }

    return NoiseReductionParameters(
      enabled: params.enabled,
      preset: params.enabled ? NoiseReductionPreset.custom : NoiseReductionPreset.off,
      method: method,
      smDegrainTr: v['smDegrainTr'] as int? ?? 2,
      smDegrainThSAD: v['smDegrainThSAD'] as int? ?? 300,
      smDegrainThSADC: v['smDegrainThSADC'] as int? ?? 150,
      smDegrainRefine: v['smDegrainRefine'] as bool? ?? true,
      smDegrainPrefilter: v['smDegrainPrefilter'] as int? ?? 2,
      mcTemporalSigma: (v['mcTemporalSigma'] as num?)?.toDouble() ?? 4.0,
      mcTemporalRadius: v['mcTemporalRadius'] as int? ?? 2,
      mcTemporalProfile: v['mcTemporalProfile'] as String? ?? 'medium',
      qtgmcEzDenoise: (v['qtgmcEzDenoise'] as num?)?.toDouble() ?? 0.0,
      qtgmcEzKeepGrain: (v['qtgmcEzKeepGrain'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// Convert dynamic parameters to chroma denoise (CCD) parameters.
  static ChromaDenoiseParameters toChromaDenoise(DynamicParameters params) {
    final v = params.values;
    return ChromaDenoiseParameters(
      enabled: params.enabled,
      threshold: (v['threshold'] as num?)?.toDouble() ?? 4.0,
      temporalRadius: _asInt(v['temporalRadius']) ?? 0,
      pointsLow: v['pointsLow'] as bool? ?? true,
      pointsMedium: v['pointsMedium'] as bool? ?? true,
      pointsHigh: v['pointsHigh'] as bool? ?? false,
      // Absent means "derive from the frame height".
      scale: (v['scale'] as num?)?.toDouble(),
    );
  }

  /// Convert dynamic parameters to dehalo parameters.
  static DehaloParameters toDehalo(DynamicParameters params) {
    final v = params.values;
    final methodStr = v['method'] as String? ?? 'dehalo_alpha';
    final method = switch (methodStr) {
      'fine_dehalo' => DehaloMethod.fineDehalo,
      'fine_dehalo2' => DehaloMethod.fineDehalo2,
      'yahr' => DehaloMethod.yahr,
      'edge_cleaner' => DehaloMethod.edgeCleaner,
      'vinverse' => DehaloMethod.vinverse,
      'vinverse2' => DehaloMethod.vinverse2,
      _ => DehaloMethod.dehaloAlpha,
    };

    return DehaloParameters(
      enabled: params.enabled,
      method: method,
      rx: (v['rx'] as num?)?.toDouble() ?? 2.0,
      ry: (v['ry'] as num?)?.toDouble() ?? 2.0,
      darkStr: (v['darkStr'] as num?)?.toDouble() ?? 1.0,
      brightStr: (v['brightStr'] as num?)?.toDouble() ?? 1.0,
      // Absent (checkbox off) stays null so the script omits it entirely.
      lowSens: (v['lowSens'] as num?)?.toInt(),
      highSens: (v['highSens'] as num?)?.toInt(),
      superSample: (v['superSample'] as num?)?.toDouble(),
      lowThreshold: v['lowThreshold'] as int? ?? 50,
      highThreshold: v['highThreshold'] as int? ?? 100,
      limitLow: (v['limitLow'] as num?)?.toInt(),
      limitHigh: (v['limitHigh'] as num?)?.toInt(),
      contra: (v['contra'] as num?)?.toDouble(),
      excludeCloseEdges: v['excludeCloseEdges'] as bool?,
      edgeProc: (v['edgeProc'] as num?)?.toDouble(),
      yahrBlur: v['yahrBlur'] as int? ?? 2,
      yahrDepth: v['yahrDepth'] as int? ?? 32,
      edgeStrength: (v['edgeStrength'] as num?)?.toInt(),
      edgeRepair: v['edgeRepair'] as bool?,
      edgeRepairMode: _asInt(v['edgeRepairMode']),
      edgeSmallMode: _asInt(v['edgeSmallMode']),
      edgeHotPixels: v['edgeHotPixels'] as bool?,
      vinverseStrength: (v['vinverseStrength'] as num?)?.toDouble(),
      vinverseAmount: (v['vinverseAmount'] as num?)?.toInt(),
      vinverseChroma: v['vinverseChroma'] as bool?,
    );
  }

  /// Convert dynamic parameters to deblock parameters.
  static DeblockParameters toDeblock(DynamicParameters params) {
    final v = params.values;
    final methodStr = v['method'] as String? ?? 'deblock_qed';
    DeblockMethod method;
    switch (methodStr) {
      case 'deblock':
        method = DeblockMethod.deblock;
        break;
      default:
        method = DeblockMethod.deblockQed;
    }

    return DeblockParameters(
      enabled: params.enabled,
      method: method,
      quant1: v['quant1'] as int? ?? 24,
      quant2: v['quant2'] as int? ?? 26,
      aOffset1: v['aOffset1'] as int? ?? 1,
      aOffset2: v['aOffset2'] as int? ?? 1,
    );
  }

  /// Convert dynamic parameters to descratch parameters.
  static DeScratchParameters toDeScratch(DynamicParameters params) {
    final v = params.values;
    return DeScratchParameters(
      enabled: params.enabled,
      mindif: v['mindif'] as int? ?? 5,
      asym: v['asym'] as int? ?? 10,
      maxgap: v['maxgap'] as int? ?? 3,
      maxwidth: v['maxwidth'] as int? ?? 3,
      minwidth: v['minwidth'] as int? ?? 1,
      minlen: v['minlen'] as int? ?? 100,
      maxlen: v['maxlen'] as int? ?? 2048,
      maxangle: v['maxangle'] as int? ?? 5,
      blurlen: v['blurlen'] as int? ?? 15,
      keep: v['keep'] as int? ?? 100,
      border: v['border'] as int? ?? 2,
      modeY: _asInt(v['modeY']) ?? 1,
      modeU: _asInt(v['modeU']) ?? 0,
      modeV: _asInt(v['modeV']) ?? 0,
      mindifUV: v['mindifUV'] as int? ?? 0,
    );
  }

  /// Convert dynamic parameters to spotless parameters.
  static SpotLessParameters toSpotLess(DynamicParameters params) {
    final v = params.values;
    return SpotLessParameters(
      enabled: params.enabled,
      chroma: v['chroma'] as bool? ?? true,
      rec: v['rec'] as bool? ?? false,
      blksize: v['blksize'] as int? ?? 16,
      overlap: v['overlap'] as int? ?? 8,
      pel: _asInt(v['pel']) ?? 2,
    );
  }

  /// Convert dynamic parameters to deband parameters.
  static DebandParameters toDeband(DynamicParameters params) {
    final v = params.values;
    return DebandParameters(
      enabled: params.enabled,
      range: v['range'] as int? ?? 15,
      y: v['y'] as int? ?? 32,
      cb: v['cb'] as int? ?? 32,
      cr: v['cr'] as int? ?? 32,
      grainY: v['grainY'] as int? ?? 24,
      grainC: v['grainC'] as int? ?? 24,
      dynamicGrain: v['dynamicGrain'] as bool? ?? true,
      outputDepth: v['outputDepth'] as int? ?? 16,
    );
  }

  /// Convert dynamic parameters to sharpen parameters.
  static SharpenParameters toSharpen(DynamicParameters params) {
    final v = params.values;
    final methodStr = v['method'] as String? ?? 'lsfmod';
    SharpenMethod method;
    switch (methodStr) {
      case 'cas':
        method = SharpenMethod.cas;
        break;
      default:
        method = SharpenMethod.lsfmod;
    }

    return SharpenParameters(
      enabled: params.enabled,
      method: method,
      strength: v['strength'] as int? ?? 100,
      overshoot: v['overshoot'] as int? ?? 1,
      undershoot: v['undershoot'] as int? ?? 1,
      softEdge: v['softEdge'] as int? ?? 0,
      casSharpness: (v['casSharpness'] as num?)?.toDouble() ?? 0.5,
    );
  }

  /// Convert dynamic parameters to color correction parameters.
  static ColorCorrectionParameters toColorCorrection(DynamicParameters params) {
    final v = params.values;
    return ColorCorrectionParameters(
      enabled: params.enabled,
      brightness: (v['brightness'] as num?)?.toDouble() ?? 0.0,
      contrast: (v['contrast'] as num?)?.toDouble() ?? 1.0,
      hue: (v['hue'] as num?)?.toDouble() ?? 0.0,
      saturation: (v['saturation'] as num?)?.toDouble() ?? 1.0,
      coring: v['coring'] as bool? ?? false,
      applyLevels: v['applyLevels'] as bool? ?? false,
      inputLow: v['inputLow'] as int? ?? 0,
      inputHigh: v['inputHigh'] as int? ?? 255,
      outputLow: v['outputLow'] as int? ?? 0,
      outputHigh: v['outputHigh'] as int? ?? 255,
      gamma: (v['gamma'] as num?)?.toDouble() ?? 1.0,
      temperature: (v['temperature'] as num?)?.toDouble() ?? 0.0,
      tint: (v['tint'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// Convert dynamic parameters to chroma fix parameters.
  static ChromaFixParameters toChromaFixes(DynamicParameters params) {
    final v = params.values;
    return ChromaFixParameters(
      enabled: params.enabled,
      applyChromaShift: v['applyChromaShift'] as bool? ?? false,
      chromaShiftH: (v['chromaShiftH'] as num?)?.toDouble() ?? 0.0,
      chromaShiftV: (v['chromaShiftV'] as num?)?.toDouble() ?? 0.0,
      applyChromaBleedingFix: v['applyChromaBleedingFix'] as bool? ?? false,
      chromaBleedCx: v['chromaBleedCx'] as int? ?? 4,
      chromaBleedCy: v['chromaBleedCy'] as int? ?? 4,
      chromaBleedCBlur: (v['chromaBleedCBlur'] as num?)?.toDouble() ?? 0.7,
      chromaBleedStrength: (v['chromaBleedStrength'] as num?)?.toDouble() ?? 0.8,
      applyDeCrawl: v['applyDeCrawl'] as bool? ?? false,
      deCrawlYThresh: v['deCrawlYThresh'] as int? ?? 10,
      deCrawlCThresh: v['deCrawlCThresh'] as int? ?? 10,
      deCrawlMaxDiff: v['deCrawlMaxDiff'] as int? ?? 50,
      applyVinverse: v['applyVinverse'] as bool? ?? false,
      vinverseSstr: (v['vinverseSstr'] as num?)?.toDouble() ?? 2.7,
      vinverseAmnt: v['vinverseAmnt'] as int? ?? 255,
    );
  }

  /// Convert dynamic parameters to crop resize parameters.
  static CropResizeParameters toCropResize(DynamicParameters params) {
    final v = params.values;
    return CropResizeParameters(
      enabled: params.enabled,
      cropEnabled: v['cropEnabled'] as bool? ?? false,
      cropLeft: v['cropLeft'] as int? ?? 0,
      cropRight: v['cropRight'] as int? ?? 0,
      cropTop: v['cropTop'] as int? ?? 0,
      cropBottom: v['cropBottom'] as int? ?? 0,
      resizeEnabled: v['resizeEnabled'] as bool? ?? false,
      targetWidth: v['targetWidth'] as int? ?? 1920,
      targetHeight: v['targetHeight'] as int? ?? 1080,
      kernel: ResizeKernel.values.firstWhere(
        (k) => k.name.toLowerCase() == (v['kernel'] as String? ?? 'spline36').toLowerCase(),
        orElse: () => ResizeKernel.spline36,
      ),
      maintainAspect: v['maintainAspect'] as bool? ?? true,
      useIntegerUpscale: v['useIntegerUpscale'] as bool? ?? false,
      upscaleMethod: UpscaleMethod.values.firstWhere(
        (m) => m.name.toLowerCase() == (v['upscaleMethod'] as String? ?? 'nnedi3Rpow2').toLowerCase(),
        orElse: () => UpscaleMethod.nnedi3Rpow2,
      ),
      upscaleFactor: v['upscaleFactor'] as int? ?? 2,
      // Absent (checkbox off) stays null so the script omits it entirely.
      bicubicB: (v['bicubicB'] as num?)?.toDouble(),
      bicubicC: (v['bicubicC'] as num?)?.toDouble(),
      lanczosTaps: _asInt(v['lanczosTaps']),
      upscaleNsize: _asInt(v['upscaleNsize']),
      upscaleNeurons: _asInt(v['upscaleNeurons']),
      upscaleQual: _asInt(v['upscaleQual']),
      upscaleEtype: _asInt(v['upscaleEtype']),
      upscalePscrn: _asInt(v['upscalePscrn']),
      upscaleAlpha: (v['upscaleAlpha'] as num?)?.toDouble(),
      upscaleBeta: (v['upscaleBeta'] as num?)?.toDouble(),
      upscaleGamma: (v['upscaleGamma'] as num?)?.toDouble(),
      upscaleNrad: _asInt(v['upscaleNrad']),
      upscaleMdis: _asInt(v['upscaleMdis']),
    );
  }

  /// Convert dynamic parameters to subtitle parameters.
  static SubtitleParameters toSubtitles(DynamicParameters params) {
    final v = params.values;
    final modelStr = v['model'] as String? ?? 'medium';
    final outputStr = v['output'] as String? ?? 'srt_file';
    final languageStr = v['language'] as String? ?? 'auto';

    return SubtitleParameters(
      enabled: params.enabled,
      model: WhisperModel.values.firstWhere(
        (m) => m.value == modelStr,
        orElse: () => WhisperModel.medium,
      ),
      output: SubtitleOutput.values.firstWhere(
        (o) => o.value == outputStr,
        orElse: () => SubtitleOutput.srtFile,
      ),
      language: languageStr == 'auto' ? null : languageStr,
    );
  }

  /// Convert a dynamic pipeline to a processing pipeline.
  static ProcessingPipeline toPipeline(DynamicPipeline dynamic) {
    return ProcessingPipeline(
      deinterlace: dynamic.get('deinterlace') != null
          ? toQTGMC(dynamic.get('deinterlace')!)
          : const QTGMCParameters(),
      noiseReduction: dynamic.get('noise_reduction') != null
          ? toNoiseReduction(dynamic.get('noise_reduction')!)
          : const NoiseReductionParameters(),
      chromaDenoise: dynamic.get('chroma_denoise') != null
          ? toChromaDenoise(dynamic.get('chroma_denoise')!)
          : const ChromaDenoiseParameters(),
      dehalo: dynamic.get('dehalo') != null
          ? toDehalo(dynamic.get('dehalo')!)
          : const DehaloParameters(),
      deblock: dynamic.get('deblock') != null
          ? toDeblock(dynamic.get('deblock')!)
          : const DeblockParameters(),
      descratch: dynamic.get('descratch') != null
          ? toDeScratch(dynamic.get('descratch')!)
          : const DeScratchParameters(),
      spotless: dynamic.get('spotless') != null
          ? toSpotLess(dynamic.get('spotless')!)
          : const SpotLessParameters(),
      deband: dynamic.get('deband') != null
          ? toDeband(dynamic.get('deband')!)
          : const DebandParameters(),
      sharpen: dynamic.get('sharpen') != null
          ? toSharpen(dynamic.get('sharpen')!)
          : const SharpenParameters(),
      colorCorrection: dynamic.get('color_correction') != null
          ? toColorCorrection(dynamic.get('color_correction')!)
          : const ColorCorrectionParameters(),
      chromaFixes: dynamic.get('chroma_fixes') != null
          ? toChromaFixes(dynamic.get('chroma_fixes')!)
          : const ChromaFixParameters(),
      cropResize: dynamic.get('crop_resize') != null
          ? toCropResize(dynamic.get('crop_resize')!)
          : const CropResizeParameters(),
      subtitles: dynamic.get('subtitles') != null
          ? toSubtitles(dynamic.get('subtitles')!)
          : const SubtitleParameters(),
    );
  }
}
