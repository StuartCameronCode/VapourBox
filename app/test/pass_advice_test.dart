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
import 'package:vapourbox/models/colorize_parameters.dart';
import 'package:vapourbox/models/deband_parameters.dart';
import 'package:vapourbox/models/geometry_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/chroma_fix_parameters.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/pass_advice.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/unblend_parameters.dart';
import 'package:vapourbox/services/field_order_detector.dart';

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

  group('sharpening with the denoiser', () {
    // Issue #109: this pair used to warn that "Sharpen runs before Noise
    // Reduction, so the denoiser will soften much of this again". It does not
    // — Sharpen runs after it — so the warning described a flaw the pipeline
    // does not have.
    test('is silent, since Sharpen already runs after Noise Reduction', () {
      expect(
        adviseOn(ProcessingPipeline(
          deinterlace: const QTGMCParameters(enabled: false),
          noiseReduction:
              NoiseReductionParameters.fromPreset(NoiseReductionPreset.heavy),
          sharpen: const SharpenParameters(enabled: true),
        )),
        isEmpty,
      );
    });

    test('silent when only Sharpen is on', () {
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

  group('the order the advice talks about is the order the pipeline has', () {
    // The advice states pass order as fact. These pin each statement to
    // enabledPasses, so the text and the pipeline cannot drift apart again.
    final order = ProcessingPipeline(
      deinterlace: const QTGMCParameters(enabled: false),
      noiseReduction:
          NoiseReductionParameters.fromPreset(NoiseReductionPreset.moderate),
      chromaDenoise: const ChromaDenoiseParameters(enabled: true),
      dehalo: const DehaloParameters(enabled: true),
      deband: const DebandParameters(enabled: true),
      sharpen: const SharpenParameters(enabled: true),
    ).enabledPasses;

    test('Sharpen runs after every clean-up pass', () {
      final sharpen = order.indexOf(PassType.sharpen);
      expect(sharpen, isNonNegative);
      for (final earlier in const [
        PassType.noiseReduction,
        PassType.chromaDenoise,
        PassType.dehalo,
        PassType.deband,
      ]) {
        expect(order.indexOf(earlier), isNonNegative, reason: '$earlier');
        expect(order.indexOf(earlier), lessThan(sharpen),
            reason: '$earlier must run before Sharpen');
      }
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

  group('chroma denoise before colourisation', () {
    test('warns on Chroma Denoise, whose colour Colourisation replaces', () {
      final pipeline = const ProcessingPipeline(
        chromaDenoise: ChromaDenoiseParameters(enabled: true),
        colorize: ColorizeParameters(enabled: true),
      );
      final advice = adviceFor(PassType.chromaDenoise, pipeline);
      expect(advice, isNotNull);
      expect(advice, contains('replaces the colour'));
      // The order it states is the pipeline's.
      final passes = pipeline.enabledPasses;
      expect(passes.indexOf(PassType.chromaDenoise), lessThan(passes.indexOf(PassType.colorize)));
      // And Colourisation itself carries no warning.
      expect(adviceFor(PassType.colorize, pipeline), isNull);
    });

    test('silent with either alone', () {
      expect(adviseOn(const ProcessingPipeline(colorize: ColorizeParameters(enabled: true))), isEmpty);
      expect(adviseOn(const ProcessingPipeline(chromaDenoise: ChromaDenoiseParameters(enabled: true))),
          isEmpty);
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

  group('frame rate target near the input rate (task #139)', () {
    VideoInfo info(double fps, {bool pulldownRate = true, ScanType? scan}) =>
        VideoInfo(
          width: 720,
          height: 576,
          frameRate: fps,
          duration: 60,
          frameCount: 1500,
          codec: 'h264',
          pixelFormat: 'yuv420p',
          scanType: scan ?? ScanType.progressive,
          hasAudio: true,
          pulldownRate: pulldownRate,
        );
    const film = 24000 / 1001;
    const ntsc = 30000 / 1001;
    const noDeint = QTGMCParameters(enabled: false);

    ProcessingPipeline fr(FrameRateParameters f,
            {QTGMCParameters deinterlace = noDeint,
            UnblendParameters unblend = const UnblendParameters()}) =>
        ProcessingPipeline(
            deinterlace: deinterlace, unblend: unblend, frameRate: f);

    const on25 = FrameRateParameters(enabled: true);

    String? advice(ProcessingPipeline p, VideoInfo? i) =>
        adviceFor(PassType.frameRate, p, info: i);

    test('an untouched pipeline is silent with a video selected', () {
      expect(adviseOn(const ProcessingPipeline(), info: info(25)), isEmpty);
    });

    test('silent when the pass is off', () {
      expect(adviseOn(fr(const FrameRateParameters()), info: info(25)),
          isEmpty);
    });

    test('silent with no video selected', () {
      expect(advice(fr(on25), null), isNull);
    });

    test('25 to 25 converts nothing', () {
      final all = adviseOn(fr(on25), info: info(25));
      expect(all.map((a) => a.pass), [PassType.frameRate],
          reason: 'the advice attaches to the Frame Rate pass only');
      expect(all.single.message, contains('nothing to convert'));
      expect(all.single.message, contains('25 fps'));
    });

    test('23.976 to 25 is close', () {
      final m = advice(fr(on25), info(film))!;
      expect(m, contains('within 4.3%'));
      expect(m, contains('23.976 fps'));
      expect(m, contains('not look smoother'));
    });

    test('29.97 to Custom 30 is close, Custom 29.97 is equal', () {
      expect(
          advice(
              fr(on25.copyWith(target: FrameRateTarget.custom, customFps: 30)),
              info(ntsc)),
          contains('within 0.1%'));
      expect(
          advice(
              fr(on25.copyWith(
                  target: FrameRateTarget.custom, customFps: 29.97)),
              info(ntsc)),
          contains('nothing to convert'));
    });

    test('a real conversion is silent', () {
      expect(advice(fr(on25.copyWith(target: FrameRateTarget.pal50)), info(25)),
          isNull);
      expect(
          advice(
              fr(on25.copyWith(target: FrameRateTarget.custom, customFps: 48)),
              info(24)),
          isNull);
      expect(advice(fr(on25), info(ntsc)), isNull);
    });

    test('a double-rate deinterlace reaches the pass at 50: 25 is silent', () {
      expect(
          advice(
              fr(on25, deinterlace: const QTGMCParameters(enabled: true)),
              info(25, scan: ScanType.interlaced)),
          isNull);
    });

    test('a single-rate deinterlace keeps 25: 25 converts nothing', () {
      expect(
          advice(
              fr(on25,
                  deinterlace:
                      const QTGMCParameters(enabled: true, fpsDivisor: 2)),
              info(25, scan: ScanType.interlaced)),
          contains('nothing to convert'));
    });

    test('IVTC from 29.97 reaches the pass at 23.976', () {
      expect(
          advice(
              fr(on25.copyWith(target: FrameRateTarget.film23976),
                  deinterlace: const QTGMCParameters(
                      enabled: true, method: DeinterlaceMethod.ivtc)),
              info(ntsc, scan: ScanType.telecine)),
          contains('nothing to convert'));
    });

    test('Soft Telecine at the film rate keeps every frame', () {
      const st =
          QTGMCParameters(enabled: true, method: DeinterlaceMethod.softTelecine);
      final target = on25.copyWith(target: FrameRateTarget.film23976);
      expect(
          advice(fr(target, deinterlace: st),
              info(film, pulldownRate: false, scan: ScanType.softTelecine)),
          contains('nothing to convert'));
      expect(
          advice(fr(target, deinterlace: st),
              info(ntsc, scan: ScanType.softTelecine)),
          contains('nothing to convert'));
    });

    test('Unblend to 25 ahead of a 25 target converts nothing', () {
      expect(
          advice(
              fr(on25,
                  deinterlace: const QTGMCParameters(enabled: true),
                  unblend: const UnblendParameters(
                      enabled: true, target: FrameRateTarget.pal25)),
              info(25, scan: ScanType.interlaced)),
          contains('nothing to convert'));
    });
  });
}
