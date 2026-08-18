// Tests for the advice shown about pass *combinations*.
//
// The behaviours worth pinning are the negative ones: advice about a pass that
// is switched off is noise, and an empty pipeline must be silent. A default
// pipeline that produced advice would put a warning banner in front of a user
// who has done nothing yet, which is how advisory UI gets learned-to-ignore.
//
// Run with: flutter test test/pass_advice_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/chroma_denoise_parameters.dart';
import 'package:vapourbox/models/color_correction_parameters.dart';
import 'package:vapourbox/models/deband_parameters.dart';
import 'package:vapourbox/models/geometry_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/chroma_fix_parameters.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/pass_advice.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';

void main() {
  group('silence by default', () {
    test('an untouched pipeline says nothing', () {
      expect(adviseOn(const ProcessingPipeline()), isEmpty);
    });

    test('a single enabled pass says nothing', () {
      expect(
        adviseOn(ProcessingPipeline(
          noiseReduction:
              NoiseReductionParameters.fromPreset(NoiseReductionPreset.moderate),
        )),
        isEmpty,
      );
    });

    test('luma and chroma denoise together is a good combination, not a '
        'conflict', () {
      // Explicitly asserted so nobody "helpfully" warns about it later: these
      // two split luma and chroma and are meant to be used together.
      final advice = adviseOn(ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        noiseReduction:
            NoiseReductionParameters.fromPreset(NoiseReductionPreset.moderate),
        chromaDenoise: const ChromaDenoiseParameters(enabled: true),
      ));
      expect(advice, isEmpty);
    });
  });

  group('sharpening against the denoiser', () {
    test('warns on the Sharpen pass, naming the consequence', () {
      final advice = adviceFor(
        PassType.sharpen,
        ProcessingPipeline(
          deinterlace: const QTGMCParameters(enabled: false),
          noiseReduction:
              NoiseReductionParameters.fromPreset(NoiseReductionPreset.heavy),
          sharpen: const SharpenParameters(enabled: true),
        ),
      );
      expect(advice, isNotNull);
      expect(advice, contains('denoiser'));
    });

    test('silent when only one of the two is on', () {
      expect(
        adviceFor(
          PassType.sharpen,
          ProcessingPipeline(
            deinterlace: const QTGMCParameters(enabled: false),
            sharpen: const SharpenParameters(enabled: true),
          ),
        ),
        isNull,
      );
    });
  });

  group('dehalo against sharpening', () {
    test('warns on Sharpen, since Dehalo runs first', () {
      final advice = adviceFor(
        PassType.sharpen,
        ProcessingPipeline(
          deinterlace: const QTGMCParameters(enabled: false),
          dehalo: const DehaloParameters(enabled: true),
          sharpen: const SharpenParameters(enabled: true),
        ),
      );
      expect(advice, isNotNull);
      expect(advice, contains('Dehalo'));
    });
  });

  group('deband grain against sharpening', () {
    test('warns on the Deband pass', () {
      final advice = adviceFor(
        PassType.deband,
        ProcessingPipeline(
          deinterlace: const QTGMCParameters(enabled: false),
          deband: const DebandParameters(enabled: true),
          sharpen: const SharpenParameters(enabled: true),
        ),
      );
      expect(advice, isNotNull);
      expect(advice, contains('grain'));
    });
  });

  group('IVTC and the FPS divisor', () {
    test('warns that the divisor is ignored', () {
      final advice = adviceFor(
        PassType.deinterlace,
        const ProcessingPipeline(
          deinterlace: QTGMCParameters(
            enabled: true,
            method: DeinterlaceMethod.ivtc,
            fpsDivisor: 2,
          ),
        ),
      );
      expect(advice, isNotNull);
      expect(advice, contains('ignored'));
    });

    test('silent for QTGMC deinterlacing, where the divisor does apply', () {
      expect(
        adviceFor(
          PassType.deinterlace,
          const ProcessingPipeline(
            deinterlace: QTGMCParameters(
              enabled: true,
              method: DeinterlaceMethod.qtgmc,
              fpsDivisor: 2,
            ),
          ),
        ),
        isNull,
      );
    });

    test('silent for IVTC with no divisor set', () {
      expect(
        adviceFor(
          PassType.deinterlace,
          const ProcessingPipeline(
            deinterlace: QTGMCParameters(
              enabled: true,
              method: DeinterlaceMethod.ivtc,
            ),
          ),
        ),
        isNull,
      );
    });
  });

  group('deinterlace clean-up with no deinterlacing', () {
    test('warns when Vinverse is on but deinterlacing is off', () {
      final advice = adviceFor(
        PassType.chromaFixes,
        const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
          chromaFixes: ChromaFixParameters(
            enabled: true,
            applyVinverse: true,
          ),
        ),
      );
      expect(advice, isNotNull);
      expect(advice, contains('deinterlacing'));
    });

    test('silent when deinterlacing is on', () {
      expect(
        adviceFor(
          PassType.chromaFixes,
          const ProcessingPipeline(
            deinterlace: QTGMCParameters(enabled: true),
            chromaFixes: ChromaFixParameters(
              enabled: true,
              applyVinverse: true,
            ),
          ),
        ),
        isNull,
      );
    });

    test('silent for chroma shift, which has nothing to do with fields', () {
      expect(
        adviceFor(
          PassType.chromaFixes,
          const ProcessingPipeline(
            deinterlace: QTGMCParameters(enabled: false),
            chromaFixes: ChromaFixParameters(
              enabled: true,
              applyChromaShift: true,
            ),
          ),
        ),
        isNull,
      );
    });
  });

  group('colour correction set both automatically and by hand', () {
    test('says the manual levels points are not used', () {
      final advice = adviceFor(
        PassType.colorCorrection,
        const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
          colorCorrection: ColorCorrectionParameters(
            enabled: true,
            applyAutoLevels: true,
            applyLevels: true,
            inputLow: 16,
          ),
        ),
      );
      expect(advice, isNotNull);
      expect(advice, contains('automatically'));
    });

    test('says which order white balance happens in', () {
      final advice = adviceFor(
        PassType.colorCorrection,
        const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
          colorCorrection: ColorCorrectionParameters(
            enabled: true,
            applyAutoWhiteBalance: true,
            temperature: 20,
          ),
        ),
      );
      expect(advice, isNotNull);
      expect(advice, contains('after'));
    });

    test('silent when only the automatic side is on', () {
      expect(
        adviceFor(
          PassType.colorCorrection,
          const ProcessingPipeline(
            deinterlace: QTGMCParameters(enabled: false),
            colorCorrection: ColorCorrectionParameters(
              enabled: true,
              applyAutoLevels: true,
              applyAutoWhiteBalance: true,
            ),
          ),
        ),
        isNull,
      );
    });
  });

  group('a manual chroma shift the automatic measurement has superseded', () {
    // The panel hides the manual sliders while automatic alignment is on, so a
    // preset that saved both leaves the user nothing to look at — the advice is
    // the only place the dropped shift is mentioned.
    test('says the hand-set shift is not being used', () {
      final advice = adviceFor(
        PassType.chromaFixes,
        const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
          chromaFixes: ChromaFixParameters(
            enabled: true,
            applyAutoChroma: true,
            applyChromaShift: true,
            chromaShiftH: 2.0,
          ),
        ),
      );
      expect(advice, isNotNull);
      expect(advice, contains('automatically'));
    });

    test('silent when only one of the two is on', () {
      for (final chroma in const [
        ChromaFixParameters(enabled: true, applyAutoChroma: true),
        ChromaFixParameters(
            enabled: true, applyChromaShift: true, chromaShiftH: 2.0),
      ]) {
        expect(
          adviceFor(
            PassType.chromaFixes,
            ProcessingPipeline(
              deinterlace: const QTGMCParameters(enabled: false),
              chromaFixes: chroma,
            ),
          ),
          isNull,
        );
      }
    });
  });

  group('rotating interlaced material', () {
    test('warns when a quarter turn runs with deinterlacing off', () {
      final advice = adviceFor(
        PassType.geometry,
        const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
          geometry: GeometryParameters(
            enabled: true,
            rotation: Rotation.cw90,
          ),
        ),
      );
      expect(advice, isNotNull);
      expect(advice, contains('destroys'));
    });

    test('silent when deinterlacing is on, since it runs first', () {
      expect(
        adviceFor(
          PassType.geometry,
          const ProcessingPipeline(
            deinterlace: QTGMCParameters(enabled: true),
            geometry: GeometryParameters(
              enabled: true,
              rotation: Rotation.cw90,
            ),
          ),
        ),
        isNull,
      );
    });

    test('silent for a half turn and for flips, which keep fields in rows', () {
      for (final geometry in [
        const GeometryParameters(enabled: true, rotation: Rotation.rotate180),
        const GeometryParameters(enabled: true, flipHorizontal: true),
      ]) {
        expect(
          adviceFor(
            PassType.geometry,
            ProcessingPipeline(
              deinterlace: const QTGMCParameters(enabled: false),
              geometry: geometry,
            ),
          ),
          isNull,
        );
      }
    });
  });

  group('advice is always attached to an enabled pass', () {
    test('no advice names a pass that is switched off', () {
      // Otherwise a user sees a banner on a pass they are not using, which
      // teaches them to ignore the banners.
      final pipelines = [
        const ProcessingPipeline(),
        ProcessingPipeline(
          deinterlace: const QTGMCParameters(enabled: false),
          sharpen: const SharpenParameters(enabled: true),
          noiseReduction:
              NoiseReductionParameters.fromPreset(NoiseReductionPreset.heavy),
          dehalo: const DehaloParameters(enabled: true),
          deband: const DebandParameters(enabled: true),
        ),
        const ProcessingPipeline(
          deinterlace: QTGMCParameters(
            enabled: true,
            method: DeinterlaceMethod.ivtc,
            fpsDivisor: 2,
          ),
        ),
      ];

      for (final pipeline in pipelines) {
        for (final advice in adviseOn(pipeline)) {
          expect(pipeline.isPassEnabled(advice.pass), true,
              reason: 'advice attached to disabled pass ${advice.pass}');
        }
      }
    });
  });
}
