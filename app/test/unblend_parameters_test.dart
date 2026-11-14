import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/pass_advice.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/unblend_parameters.dart';

void main() {
  group('Unblend target', () {
    test('the rate at the pass follows the deinterlacer, as the worker counts it', () {
      expect(unblendInputFps(const QTGMCParameters(enabled: true), 25), 50);
      expect(unblendInputFps(const QTGMCParameters(enabled: true, fpsDivisor: 2), 25), 25);
      expect(unblendInputFps(const QTGMCParameters(enabled: false), 25), 25);
      expect(unblendInputFps(
          const QTGMCParameters(enabled: true, method: DeinterlaceMethod.ivtc), 30), 24);
    });

    test('only a lower rate, down to a fifth, is accepted', () {
      expect(unblendTargetProblem(24000 / 1001, 50), isNull);
      expect(unblendTargetProblem(25, 60000 / 1001), isNull);
      // The worker's wording, from its first words.
      expect(unblendTargetProblem(50, 50), startsWith("Unblend can't recover 50 fps from 50 fps."));
      expect(unblendTargetProblem(25, 25), isNotNull);
      expect(unblendTargetProblem(8, 50), isNotNull);
      expect(unblendTargetProblem(30000 / 1001, 25), contains('29.97 fps from 25 fps'));
    });

    test('custom targets use the typed rate', () {
      const p = UnblendParameters(enabled: true, target: FrameRateTarget.custom, customFps: 20);
      expect(p.targetFps, 20);
      expect(p.summary, 'To 20 fps');
      expect(const UnblendParameters().summary, 'Off');
    });

    test('an old pipeline without the pass loads it off', () {
      final p = ProcessingPipeline.fromJson(const {});
      expect(p.unblend.enabled, isFalse);
      expect(p.enabledPasses, isNot(contains(PassType.unblend)));
    });
  });

  group('Unblend advice', () {
    List<String> adviceOn(QTGMCParameters d, {bool on = true}) => adviseOn(ProcessingPipeline(
          deinterlace: d,
          unblend: UnblendParameters(enabled: on),
        )).where((a) => a.pass == PassType.unblend).map((a) => a.message).toList();

    test('double-rate deinterlacing is what it wants: silent', () {
      expect(adviceOn(const QTGMCParameters(enabled: true)), isEmpty);
      expect(adviceOn(const QTGMCParameters(enabled: true, fpsDivisor: 1)), isEmpty);
    });

    test('deinterlacing off, single rate or IVTC is pointed out', () {
      expect(adviceOn(const QTGMCParameters(enabled: false)).single, contains('Deinterlace is off'));
      expect(adviceOn(const QTGMCParameters(enabled: true, fpsDivisor: 2)).single,
          contains('single rate'));
      expect(adviceOn(const QTGMCParameters(enabled: true, method: DeinterlaceMethod.ivtc)).single,
          contains('Inverse telecine'));
    });

    test('nothing is said while the pass is off', () {
      expect(adviceOn(const QTGMCParameters(enabled: false), on: false), isEmpty);
    });
  });
}
