import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/chroma_fix_parameters.dart';
import 'package:vapourbox/models/color_correction_parameters.dart';
import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/deband_parameters.dart';
import 'package:vapourbox/models/deblock_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/restoration_pipeline.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';

void main() {
  group('ParameterConverter', () {
    group('fromQTGMC', () {
      test('converts default parameters', () {
        const params = QTGMCParameters();
        final dynamic = ParameterConverter.fromQTGMC(params);

        expect(dynamic.filterId, 'deinterlace');
        expect(dynamic.enabled, true);
        expect(dynamic.values['method'], 'qtgmc');
        expect(dynamic.values['preset'], 'slower');
        expect(dynamic.values['fpsDivisor'], 1);
      });

      test('converts custom parameters', () {
        const params = QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
          sourceMatch: 1,
          sharpness: 0.5,
        );
        final dynamic = ParameterConverter.fromQTGMC(params);

        expect(dynamic.values['preset'], 'fast');
        expect(dynamic.values['tff'], true);
        expect(dynamic.values['fpsDivisor'], 2);
        expect(dynamic.values['sourceMatch'], 1);
        expect(dynamic.values['sharpness'], 0.5);
      });
    });

    group('fromDehalo', () {
      test('converts DeHalo Alpha parameters', () {
        const params = DehaloParameters(
          enabled: true,
          method: DehaloMethod.dehaloAlpha,
          rx: 2.5,
          ry: 2.0,
          darkStr: 0.8,
          brightStr: 0.9,
        );
        final dynamic = ParameterConverter.fromDehalo(params);

        expect(dynamic.filterId, 'dehalo');
        expect(dynamic.enabled, true);
        expect(dynamic.values['method'], 'dehalo_alpha');
        expect(dynamic.values['rx'], 2.5);
        expect(dynamic.values['ry'], 2.0);
        expect(dynamic.values['darkStr'], 0.8);
        expect(dynamic.values['brightStr'], 0.9);
      });

      test('converts YAHR parameters', () {
        const params = DehaloParameters(
          enabled: true,
          method: DehaloMethod.yahr,
          yahrBlur: 3,
          yahrDepth: 48,
        );
        final dynamic = ParameterConverter.fromDehalo(params);

        expect(dynamic.values['method'], 'yahr');
        expect(dynamic.values['yahrBlur'], 3);
        expect(dynamic.values['yahrDepth'], 48);
      });

      test('converts FineDehalo parameters', () {
        const params = DehaloParameters(
          enabled: true,
          method: DehaloMethod.fineDehalo,
          lowThreshold: 40,
          highThreshold: 90,
        );
        final dynamic = ParameterConverter.fromDehalo(params);

        expect(dynamic.values['method'], 'fine_dehalo');
        expect(dynamic.values['lowThreshold'], 40);
        expect(dynamic.values['highThreshold'], 90);
      });
    });

    group('fromDeblock', () {
      test('converts Deblock_QED parameters', () {
        const params = DeblockParameters(
          enabled: true,
          method: DeblockMethod.deblockQed,
          quant1: 20,
          quant2: 24,
        );
        final dynamic = ParameterConverter.fromDeblock(params);

        expect(dynamic.filterId, 'deblock');
        expect(dynamic.values['method'], 'deblock_qed');
        expect(dynamic.values['quant1'], 20);
        expect(dynamic.values['quant2'], 24);
      });

      test('converts simple Deblock parameters', () {
        const params = DeblockParameters(
          enabled: true,
          method: DeblockMethod.deblock,
          blockSize: 8,
          overlap: 4,
        );
        final dynamic = ParameterConverter.fromDeblock(params);

        expect(dynamic.values['method'], 'deblock');
        expect(dynamic.values['blockSize'], 8);
        expect(dynamic.values['overlap'], 4);
      });
    });

    group('fromDeband', () {
      test('converts f3kdb parameters', () {
        const params = DebandParameters(
          enabled: true,
          range: 20,
          y: 48,
          cb: 32,
          cr: 32,
          grainY: 24,
          grainC: 16,
          dynamicGrain: true,
          outputDepth: 16,
        );
        final dynamic = ParameterConverter.fromDeband(params);

        expect(dynamic.filterId, 'deband');
        expect(dynamic.values['method'], 'f3kdb');
        expect(dynamic.values['range'], 20);
        expect(dynamic.values['y'], 48);
        expect(dynamic.values['cb'], 32);
        expect(dynamic.values['grainY'], 24);
        expect(dynamic.values['dynamicGrain'], true);
      });
    });

    group('fromSharpen', () {
      test('converts LSFmod parameters', () {
        const params = SharpenParameters(
          enabled: true,
          method: SharpenMethod.lsfmod,
          strength: 120,
          overshoot: 2,
          undershoot: 2,
        );
        final dynamic = ParameterConverter.fromSharpen(params);

        expect(dynamic.filterId, 'sharpen');
        expect(dynamic.values['method'], 'lsfmod');
        expect(dynamic.values['strength'], 120);
        expect(dynamic.values['overshoot'], 2);
      });

      test('converts CAS parameters', () {
        const params = SharpenParameters(
          enabled: true,
          method: SharpenMethod.cas,
          casSharpness: 0.7,
        );
        final dynamic = ParameterConverter.fromSharpen(params);

        expect(dynamic.values['method'], 'cas');
        expect(dynamic.values['casSharpness'], 0.7);
      });
    });

    group('fromNoiseReduction', () {
      test('converts SMDegrain parameters', () {
        const params = NoiseReductionParameters(
          enabled: true,
          method: NoiseReductionMethod.smDegrain,
          smDegrainTr: 3,
          smDegrainThSAD: 400,
          smDegrainThSADC: 200,
          smDegrainRefine: true,
          smDegrainPrefilter: 2,
        );
        final dynamic = ParameterConverter.fromNoiseReduction(params);

        expect(dynamic.filterId, 'noise_reduction');
        expect(dynamic.values['method'], 'smdegrain');
        expect(dynamic.values['smDegrainTr'], 3);
        expect(dynamic.values['smDegrainThSAD'], 400);
        expect(dynamic.values['smDegrainRefine'], true);
      });

      test('converts MCTemporalDenoise parameters', () {
        const params = NoiseReductionParameters(
          enabled: true,
          method: NoiseReductionMethod.mcTemporalDenoise,
          mcTemporalSigma: 5.0,
          mcTemporalRadius: 3,
        );
        final dynamic = ParameterConverter.fromNoiseReduction(params);

        expect(dynamic.values['method'], 'mc_temporal_denoise');
        expect(dynamic.values['mcTemporalSigma'], 5.0);
        expect(dynamic.values['mcTemporalRadius'], 3);
      });
    });

    group('fromColorCorrection', () {
      test('converts color parameters', () {
        const params = ColorCorrectionParameters(
          enabled: true,
          brightness: 10.0,
          contrast: 1.2,
          saturation: 1.1,
          hue: 5.0,
          gamma: 0.9,
        );
        final dynamic = ParameterConverter.fromColorCorrection(params);

        expect(dynamic.filterId, 'color_correction');
        expect(dynamic.values['brightness'], 10.0);
        expect(dynamic.values['contrast'], 1.2);
        expect(dynamic.values['saturation'], 1.1);
        expect(dynamic.values['hue'], 5.0);
        expect(dynamic.values['gamma'], 0.9);
      });

      test('converts levels parameters', () {
        const params = ColorCorrectionParameters(
          enabled: true,
          applyLevels: true,
          inputLow: 16,
          inputHigh: 235,
          outputLow: 0,
          outputHigh: 255,
        );
        final dynamic = ParameterConverter.fromColorCorrection(params);

        expect(dynamic.values['applyLevels'], true);
        expect(dynamic.values['inputLow'], 16);
        expect(dynamic.values['outputHigh'], 255);
      });
    });

    group('fromChromaFixes', () {
      test('converts chroma bleeding parameters', () {
        const params = ChromaFixParameters(
          enabled: true,
          applyChromaBleedingFix: true,
          chromaBleedCx: 6,
          chromaBleedCy: 6,
          chromaBleedCBlur: 0.8,
          chromaBleedStrength: 0.9,
        );
        final dynamic = ParameterConverter.fromChromaFixes(params);

        expect(dynamic.filterId, 'chroma_fixes');
        expect(dynamic.values['applyChromaBleedingFix'], true);
        expect(dynamic.values['chromaBleedCx'], 6);
        expect(dynamic.values['chromaBleedCBlur'], 0.8);
      });

      test('converts Vinverse parameters', () {
        const params = ChromaFixParameters(
          enabled: true,
          applyVinverse: true,
          vinverseSstr: 2.5,
          vinverseAmnt: 200,
          vinverseScl: 15,
        );
        final dynamic = ParameterConverter.fromChromaFixes(params);

        expect(dynamic.values['applyVinverse'], true);
        expect(dynamic.values['vinverseSstr'], 2.5);
        expect(dynamic.values['vinverseAmnt'], 200);
      });

      test('converts DeCrawl parameters', () {
        const params = ChromaFixParameters(
          enabled: true,
          applyDeCrawl: true,
          deCrawlYThresh: 15,
          deCrawlCThresh: 15,
          deCrawlMaxDiff: 60,
        );
        final dynamic = ParameterConverter.fromChromaFixes(params);

        expect(dynamic.values['applyDeCrawl'], true);
        expect(dynamic.values['deCrawlYThresh'], 15);
        expect(dynamic.values['deCrawlMaxDiff'], 60);
      });
    });

    group('fromCropResize', () {
      test('converts crop parameters', () {
        const params = CropResizeParameters(
          enabled: true,
          cropEnabled: true,
          cropLeft: 16,
          cropRight: 16,
          cropTop: 8,
          cropBottom: 8,
        );
        final dynamic = ParameterConverter.fromCropResize(params);

        expect(dynamic.filterId, 'crop_resize');
        expect(dynamic.values['cropEnabled'], true);
        expect(dynamic.values['cropLeft'], 16);
        expect(dynamic.values['cropTop'], 8);
      });

      test('converts resize parameters', () {
        const params = CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 1920,
          targetHeight: 1080,
          kernel: ResizeKernel.lanczos,
          maintainAspect: true,
        );
        final dynamic = ParameterConverter.fromCropResize(params);

        expect(dynamic.values['resizeEnabled'], true);
        expect(dynamic.values['targetWidth'], 1920);
        expect(dynamic.values['targetHeight'], 1080);
        expect(dynamic.values['kernel'], 'lanczos');
        expect(dynamic.values['maintainAspect'], true);
      });

      test('converts upscale parameters', () {
        const params = CropResizeParameters(
          enabled: true,
          useIntegerUpscale: true,
          upscaleMethod: UpscaleMethod.nnedi3Rpow2,
          upscaleFactor: 2,
        );
        final dynamic = ParameterConverter.fromCropResize(params);

        expect(dynamic.values['useIntegerUpscale'], true);
        expect(dynamic.values['upscaleMethod'], 'nnedi3Rpow2');
        expect(dynamic.values['upscaleFactor'], 2);
      });
    });

    group('fromPipeline', () {
      test('converts full restoration pipeline', () {
        const pipeline = RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
          ),
          dehalo: DehaloParameters(
            enabled: true,
            method: DehaloMethod.dehaloAlpha,
          ),
          deband: DebandParameters(
            enabled: true,
            range: 20,
          ),
          sharpen: SharpenParameters(
            enabled: true,
            method: SharpenMethod.cas,
          ),
        );

        final dynamicPipeline = ParameterConverter.fromPipeline(pipeline);

        // Check that all filters are present
        expect(dynamicPipeline.get('deinterlace'), isNotNull);
        expect(dynamicPipeline.get('dehalo'), isNotNull);
        expect(dynamicPipeline.get('deband'), isNotNull);
        expect(dynamicPipeline.get('sharpen'), isNotNull);
        expect(dynamicPipeline.get('noise_reduction'), isNotNull);
        expect(dynamicPipeline.get('deblock'), isNotNull);
        expect(dynamicPipeline.get('color_correction'), isNotNull);
        expect(dynamicPipeline.get('chroma_fixes'), isNotNull);
        expect(dynamicPipeline.get('crop_resize'), isNotNull);

        // Check values
        expect(dynamicPipeline.get('deinterlace')?.values['preset'], 'fast');
        expect(dynamicPipeline.get('dehalo')?.enabled, true);
        expect(dynamicPipeline.get('deband')?.values['range'], 20);
        expect(dynamicPipeline.get('sharpen')?.values['method'], 'cas');
      });

      test('pipeline.toDynamicPipeline() works', () {
        const pipeline = RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.medium,
          ),
        );

        final dynamicPipeline = pipeline.toDynamicPipeline();

        expect(dynamicPipeline.get('deinterlace')?.values['preset'], 'medium');
      });
    });
  });
}
