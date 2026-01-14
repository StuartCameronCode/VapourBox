import 'chroma_fix_parameters.dart';
import 'color_correction_parameters.dart';
import 'crop_resize_parameters.dart';
import 'deband_parameters.dart';
import 'deblock_parameters.dart';
import 'dehalo_parameters.dart';
import 'dynamic_parameters.dart';
import 'noise_reduction_parameters.dart';
import 'qtgmc_parameters.dart';
import 'restoration_pipeline.dart';
import 'sharpen_parameters.dart';

/// Converts typed parameter classes to DynamicParameters for schema-based processing.
class ParameterConverter {
  /// Convert QTGMC parameters to dynamic format.
  static DynamicParameters fromQTGMC(QTGMCParameters params) {
    return DynamicParameters(
      filterId: 'deinterlace',
      enabled: params.enabled,
      values: {
        'method': 'qtgmc',
        'preset': params.preset.displayName,
        'tff': params.tff,
        'fpsDivisor': params.fpsDivisor,
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

  /// Convert dehalo parameters to dynamic format.
  static DynamicParameters fromDehalo(DehaloParameters params) {
    String method;
    switch (params.method) {
      case DehaloMethod.dehaloAlpha:
        method = 'dehalo_alpha';
        break;
      case DehaloMethod.fineDehalo:
        method = 'fine_dehalo';
        break;
      case DehaloMethod.yahr:
        method = 'yahr';
        break;
    }

    return DynamicParameters(
      filterId: 'dehalo',
      enabled: params.enabled,
      values: {
        'method': method,
        'rx': params.rx,
        'ry': params.ry,
        'darkStr': params.darkStr,
        'brightStr': params.brightStr,
        'lowThreshold': params.lowThreshold,
        'highThreshold': params.highThreshold,
        'yahrBlur': params.yahrBlur,
        'yahrDepth': params.yahrDepth,
      },
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
        'blockSize': params.blockSize,
        'overlap': params.overlap,
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
      },
    );
  }

  /// Convert chroma fix parameters to dynamic format.
  static DynamicParameters fromChromaFixes(ChromaFixParameters params) {
    return DynamicParameters(
      filterId: 'chroma_fixes',
      enabled: params.enabled,
      values: {
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
        'vinverseScl': params.vinverseScl,
      },
    );
  }

  /// Convert crop resize parameters to dynamic format.
  static DynamicParameters fromCropResize(CropResizeParameters params) {
    return DynamicParameters(
      filterId: 'crop_resize',
      enabled: params.enabled,
      values: {
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
      },
    );
  }

  /// Convert a full restoration pipeline to a dynamic pipeline.
  static DynamicPipeline fromPipeline(RestorationPipeline pipeline) {
    return DynamicPipeline(
      filters: {
        'deinterlace': fromQTGMC(pipeline.deinterlace),
        'noise_reduction': fromNoiseReduction(pipeline.noiseReduction),
        'dehalo': fromDehalo(pipeline.dehalo),
        'deblock': fromDeblock(pipeline.deblock),
        'deband': fromDeband(pipeline.deband),
        'sharpen': fromSharpen(pipeline.sharpen),
        'color_correction': fromColorCorrection(pipeline.colorCorrection),
        'chroma_fixes': fromChromaFixes(pipeline.chromaFixes),
        'crop_resize': fromCropResize(pipeline.cropResize),
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
    return QTGMCParameters(
      enabled: params.enabled,
      preset: QTGMCPreset.values.firstWhere(
        (p) => p.displayName == presetStr || p.name == presetStr.toLowerCase(),
        orElse: () => QTGMCPreset.slower,
      ),
      tff: v['tff'] as bool?,
      fpsDivisor: v['fpsDivisor'] as int? ?? 1,
      inputType: v['inputType'] as int? ?? 0,
      tr0: v['tr0'] as int?,
      tr1: v['tr1'] as int?,
      tr2: v['tr2'] as int?,
      rep0: v['rep0'] as int?,
      rep1: v['rep1'] as int? ?? 0,
      rep2: v['rep2'] as int?,
      repChroma: v['repChroma'] as bool? ?? true,
      ediMode: v['ediMode'] as String?,
      ediQual: v['ediQual'] as int? ?? 1,
      nnSize: v['nnSize'] as int?,
      nnNeurons: v['nnNeurons'] as int?,
      ediMaxD: v['ediMaxD'] as int?,
      chromaEdi: v['chromaEdi'] as String? ?? '',
      sharpness: (v['sharpness'] as num?)?.toDouble(),
      sMode: v['sMode'] as int?,
      slMode: v['slMode'] as int?,
      slRad: v['slRad'] as int?,
      sOvs: v['sOvs'] as int? ?? 0,
      svThin: (v['svThin'] as num?)?.toDouble() ?? 0.0,
      sbb: v['sbb'] as int?,
      srchClipPp: v['srchClipPp'] as int?,
      sourceMatch: v['sourceMatch'] as int? ?? 0,
      matchPreset: v['matchPreset'] as String?,
      matchEdi: v['matchEdi'] as String?,
      matchPreset2: v['matchPreset2'] as String?,
      matchEdi2: v['matchEdi2'] as String?,
      matchTr2: v['matchTr2'] as int? ?? 1,
      matchEnhance: (v['matchEnhance'] as num?)?.toDouble() ?? 0.5,
      lossless: v['lossless'] as int? ?? 0,
      noiseProcess: v['noiseProcess'] as int?,
      ezDenoise: (v['ezDenoise'] as num?)?.toDouble(),
      ezKeepGrain: (v['ezKeepGrain'] as num?)?.toDouble(),
      noisePreset: v['noisePreset'] as String? ?? 'Fast',
      denoiser: v['denoiser'] as String?,
      fftThreads: v['fftThreads'] as int? ?? 1,
      denoiseMc: v['denoiseMc'] as bool?,
      noiseTr: v['noiseTr'] as int?,
      sigma: (v['sigma'] as num?)?.toDouble(),
      chromaNoise: v['chromaNoise'] as bool? ?? false,
      showNoise: (v['showNoise'] as num?)?.toDouble() ?? 0.0,
      grainRestore: (v['grainRestore'] as num?)?.toDouble(),
      noiseRestore: (v['noiseRestore'] as num?)?.toDouble(),
      noiseDeint: v['noiseDeint'] as String?,
      stabilizeNoise: v['stabilizeNoise'] as bool?,
      chromaMotion: v['chromaMotion'] as bool?,
      trueMotion: v['trueMotion'] as bool? ?? false,
      blockSize: v['blockSize'] as int?,
      overlap: v['overlap'] as int?,
      search: v['search'] as int?,
      searchParam: v['searchParam'] as int?,
      pelSearch: v['pelSearch'] as int?,
      lambda: v['lambda'] as int?,
      lsad: v['lsad'] as int?,
      pNew: v['pNew'] as int?,
      pLevel: v['pLevel'] as int?,
      globalMotion: v['globalMotion'] as bool? ?? true,
      dct: v['dct'] as int? ?? 0,
      subPel: v['subPel'] as int?,
      subPelInterp: v['subPelInterp'] as int? ?? 2,
      thSad1: v['thSad1'] as int? ?? 640,
      thSad2: v['thSad2'] as int? ?? 256,
      thScd1: v['thScd1'] as int? ?? 180,
      thScd2: v['thScd2'] as int? ?? 98,
      border: v['border'] as bool? ?? false,
      precise: v['precise'] as bool?,
      forceTr: v['forceTr'] as int? ?? 0,
      str: (v['str'] as num?)?.toDouble() ?? 2.0,
      amp: (v['amp'] as num?)?.toDouble() ?? 0.0625,
      fastMa: v['fastMa'] as bool? ?? false,
      eSearchP: v['eSearchP'] as bool? ?? false,
      refineMotion: v['refineMotion'] as bool? ?? false,
      opencl: v['opencl'] as bool? ?? false,
      device: v['device'] as int?,
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
      mcTemporalProfile: v['mcTemporalProfile'] as String? ?? 'fast',
      qtgmcEzDenoise: (v['qtgmcEzDenoise'] as num?)?.toDouble() ?? 2.0,
      qtgmcEzKeepGrain: (v['qtgmcEzKeepGrain'] as num?)?.toDouble() ?? 0.2,
    );
  }

  /// Convert dynamic parameters to dehalo parameters.
  static DehaloParameters toDehalo(DynamicParameters params) {
    final v = params.values;
    final methodStr = v['method'] as String? ?? 'dehalo_alpha';
    DehaloMethod method;
    switch (methodStr) {
      case 'fine_dehalo':
        method = DehaloMethod.fineDehalo;
        break;
      case 'yahr':
        method = DehaloMethod.yahr;
        break;
      default:
        method = DehaloMethod.dehaloAlpha;
    }

    return DehaloParameters(
      enabled: params.enabled,
      method: method,
      rx: (v['rx'] as num?)?.toDouble() ?? 2.0,
      ry: (v['ry'] as num?)?.toDouble() ?? 2.0,
      darkStr: (v['darkStr'] as num?)?.toDouble() ?? 1.0,
      brightStr: (v['brightStr'] as num?)?.toDouble() ?? 1.0,
      lowThreshold: v['lowThreshold'] as int? ?? 50,
      highThreshold: v['highThreshold'] as int? ?? 100,
      yahrBlur: v['yahrBlur'] as int? ?? 2,
      yahrDepth: v['yahrDepth'] as int? ?? 32,
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
      blockSize: v['blockSize'] as int? ?? 8,
      overlap: v['overlap'] as int? ?? 4,
    );
  }

  /// Convert dynamic parameters to deband parameters.
  static DebandParameters toDeband(DynamicParameters params) {
    final v = params.values;
    return DebandParameters(
      enabled: params.enabled,
      range: v['range'] as int? ?? 15,
      y: v['y'] as int? ?? 64,
      cb: v['cb'] as int? ?? 64,
      cr: v['cr'] as int? ?? 64,
      grainY: v['grainY'] as int? ?? 64,
      grainC: v['grainC'] as int? ?? 64,
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
      coring: v['coring'] as bool? ?? true,
      applyLevels: v['applyLevels'] as bool? ?? false,
      inputLow: v['inputLow'] as int? ?? 0,
      inputHigh: v['inputHigh'] as int? ?? 255,
      outputLow: v['outputLow'] as int? ?? 0,
      outputHigh: v['outputHigh'] as int? ?? 255,
      gamma: (v['gamma'] as num?)?.toDouble() ?? 1.0,
    );
  }

  /// Convert dynamic parameters to chroma fix parameters.
  static ChromaFixParameters toChromaFixes(DynamicParameters params) {
    final v = params.values;
    return ChromaFixParameters(
      enabled: params.enabled,
      applyChromaBleedingFix: v['applyChromaBleedingFix'] as bool? ?? false,
      chromaBleedCx: v['chromaBleedCx'] as int? ?? 4,
      chromaBleedCy: v['chromaBleedCy'] as int? ?? 4,
      chromaBleedCBlur: (v['chromaBleedCBlur'] as num?)?.toDouble() ?? 0.6,
      chromaBleedStrength: (v['chromaBleedStrength'] as num?)?.toDouble() ?? 1.0,
      applyDeCrawl: v['applyDeCrawl'] as bool? ?? false,
      deCrawlYThresh: v['deCrawlYThresh'] as int? ?? 10,
      deCrawlCThresh: v['deCrawlCThresh'] as int? ?? 10,
      deCrawlMaxDiff: v['deCrawlMaxDiff'] as int? ?? 50,
      applyVinverse: v['applyVinverse'] as bool? ?? false,
      vinverseSstr: (v['vinverseSstr'] as num?)?.toDouble() ?? 2.7,
      vinverseAmnt: v['vinverseAmnt'] as int? ?? 255,
      vinverseScl: v['vinverseScl'] as int? ?? 12,
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
        (k) => k.name == (v['kernel'] ?? 'lanczos'),
        orElse: () => ResizeKernel.lanczos,
      ),
      maintainAspect: v['maintainAspect'] as bool? ?? true,
      useIntegerUpscale: v['useIntegerUpscale'] as bool? ?? false,
      upscaleMethod: UpscaleMethod.values.firstWhere(
        (m) => m.name == (v['upscaleMethod'] ?? 'nnedi3Rpow2'),
        orElse: () => UpscaleMethod.nnedi3Rpow2,
      ),
      upscaleFactor: v['upscaleFactor'] as int? ?? 2,
    );
  }

  /// Convert a dynamic pipeline to a restoration pipeline.
  static RestorationPipeline toPipeline(DynamicPipeline dynamic) {
    return RestorationPipeline(
      deinterlace: dynamic.get('deinterlace') != null
          ? toQTGMC(dynamic.get('deinterlace')!)
          : const QTGMCParameters(),
      noiseReduction: dynamic.get('noise_reduction') != null
          ? toNoiseReduction(dynamic.get('noise_reduction')!)
          : const NoiseReductionParameters(),
      dehalo: dynamic.get('dehalo') != null
          ? toDehalo(dynamic.get('dehalo')!)
          : const DehaloParameters(),
      deblock: dynamic.get('deblock') != null
          ? toDeblock(dynamic.get('deblock')!)
          : const DeblockParameters(),
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
    );
  }
}
