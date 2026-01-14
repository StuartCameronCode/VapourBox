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
        'preset': params.preset.name,
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
}
