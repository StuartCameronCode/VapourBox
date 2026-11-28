// The Frame Rate pass's target as the app reads it, the rate the pass
// receives, and the target it starts at when switched on (task #139).
//
// Run with: flutter test test/frame_rate_starting_target_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/queue_item.dart';
import 'package:vapourbox/models/unblend_parameters.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

import 'fakes/fake_job_runner.dart';
import 'fakes/no_source_model_continuity.dart';

const film = 24000 / 1001;
const ntsc = 30000 / 1001;

FrameRateParameters? start(FrameRateParameters p, double fps) =>
    startingFrameRateTarget(p, fps);

void main() {
  group('frameRateTargetFps', () {
    test('every broadcast target', () {
      expect(frameRateTargetFps(FrameRateTarget.pal25, 0), 25);
      expect(frameRateTargetFps(FrameRateTarget.ntsc2997, 0), ntsc);
      expect(frameRateTargetFps(FrameRateTarget.film23976, 0), film);
      expect(frameRateTargetFps(FrameRateTarget.film24, 0), 24);
      expect(frameRateTargetFps(FrameRateTarget.pal50, 0), 50);
      expect(frameRateTargetFps(FrameRateTarget.ntsc5994, 0), 60000 / 1001);
    });

    test('custom is read as the worker reads it (custom_fps_fraction)', () {
      double c(double v) => frameRateTargetFps(FrameRateTarget.custom, v);
      expect(c(48), 48);
      expect(c(12.5), 12.5);
      expect(c(59.94), 60000 / 1001);
      expect(c(29.97), ntsc);
      expect(c(23.976), film);
      expect(c(47.952), 48000 / 1001);
      expect(c(0), 1, reason: 'clamped to 1–240');
      expect(c(1000), 240);
    });

    test('Unblend reads its targets through the same table', () {
      for (final t in FrameRateTarget.values) {
        expect(UnblendParameters(target: t, customFps: 24).targetFps,
            frameRateTargetFps(t, 24));
      }
    });
  });

  group('frameRateInputFps', () {
    const off = QTGMCParameters(enabled: false);
    const noUnblend = UnblendParameters();

    test('no deinterlace: the source rate', () {
      expect(frameRateInputFps(off, noUnblend, 25), 25);
    });

    test('double rate doubles it, single rate keeps it', () {
      expect(frameRateInputFps(const QTGMCParameters(enabled: true), noUnblend, 25), 50);
      expect(
          frameRateInputFps(
              const QTGMCParameters(enabled: true, fpsDivisor: 2), noUnblend, 25),
          25);
    });

    test('IVTC keeps four frames in five', () {
      expect(
          frameRateInputFps(
              const QTGMCParameters(enabled: true, method: DeinterlaceMethod.ivtc),
              noUnblend,
              ntsc),
          closeTo(film, 1e-9));
    });

    test('Soft Telecine decimates only at a pulldown rate', () {
      const st = QTGMCParameters(
          enabled: true, method: DeinterlaceMethod.softTelecine);
      expect(frameRateInputFps(st, noUnblend, ntsc), closeTo(film, 1e-9));
      expect(
          frameRateInputFps(st, noUnblend, film, softTelecineDecimates: false),
          film);
    });

    test('Unblend sets the rate to its target', () {
      expect(
          frameRateInputFps(const QTGMCParameters(enabled: true),
              const UnblendParameters(enabled: true, target: FrameRateTarget.pal25), 25),
          25);
    });
  });

  group('frameRateCloseness', () {
    test('equal, close and far', () {
      expect(frameRateCloseness(25, 25), FrameRateCloseness.equal);
      expect(frameRateCloseness(25, film), FrameRateCloseness.close);
      expect(frameRateCloseness(25, 24), FrameRateCloseness.close);
      expect(frameRateCloseness(30, ntsc), FrameRateCloseness.close);
      expect(frameRateCloseness(50, 25), FrameRateCloseness.far);
      expect(frameRateCloseness(ntsc, 25), FrameRateCloseness.far);
      expect(frameRateCloseness(25, 0), FrameRateCloseness.far);
    });
  });

  group('startingFrameRateTarget', () {
    const p = FrameRateParameters(enabled: true);

    test('the model default is still 25 fps', () {
      expect(const FrameRateParameters().target, FrameRateTarget.pal25);
    });

    test('PAL 25 starts at 50', () {
      expect(start(p, 25)!.target, FrameRateTarget.pal50);
    });

    test('NTSC 29.97 starts at 59.94', () {
      expect(start(p.copyWith(target: FrameRateTarget.ntsc2997), ntsc)!.target, FrameRateTarget.ntsc5994);
    });

    test('film 23.976 starts at 47.952, which the worker reads as 48000/1001', () {
      final s = start(p, film)!;
      expect(s.target, FrameRateTarget.custom);
      expect(s.customFps, 47.952);
      expect(s.targetFps, 48000 / 1001);
    });

    test('film 24 and 30 fps start at Custom 48 and 60', () {
      final s24 = start(p, 24)!;
      expect(s24.target, FrameRateTarget.custom);
      expect(s24.customFps, 48);
      final s30 = start(p.copyWith(target: FrameRateTarget.ntsc2997), 30)!;
      expect(s30.target, FrameRateTarget.custom);
      expect(s30.customFps, 60);
    });

    test('another low rate is doubled', () {
      final s = start(
          p.copyWith(target: FrameRateTarget.custom, customFps: 15), 15)!;
      expect(s.target, FrameRateTarget.custom);
      expect(s.customFps, 30);
    });

    test('a deliberate conversion is kept', () {
      expect(start(p.copyWith(target: FrameRateTarget.ntsc2997), 25), isNull);
      expect(start(p, ntsc), isNull,
          reason: 'the default 25 on a 29.97 source is a real conversion');
      expect(start(p.copyWith(target: FrameRateTarget.pal50), 25), isNull);
    });

    test('a high input rate is left alone', () {
      expect(start(p.copyWith(target: FrameRateTarget.pal50), 50), isNull);
      expect(start(p, 50), isNull);
    });

    test('an unknown rate is left alone', () {
      expect(start(p, 0), isNull);
    });

    test('the rest of the parameters are kept', () {
      final s = start(
          p.copyWith(method: FrameRateMethod.rife, sourceFpsNum: 25, sourceFpsDen: 1),
          25)!;
      expect(s.method, FrameRateMethod.rife);
      expect(s.sourceFpsNum, 25);
      expect(s.enabled, isTrue);
    });
  });

  group('switching the pass on (MainViewModel)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late MainViewModel vm;

    VideoInfo info(double fps) => VideoInfo(
          width: 720,
          height: 576,
          frameRate: fps,
          duration: 60,
          frameCount: 1500,
          codec: 'h264',
          pixelFormat: 'yuv420p',
          scanType: ScanType.progressive,
          hasAudio: true,
        );

    Future<void> select(double? fps) async {
      await vm.addMultipleToQueue(['/tmp/vapourbox_test_frame_rate.mkv']);
      final item = vm.queue.single;
      item.status = QueueItemStatus.ready;
      if (fps != null) item.videoInfo = info(fps);
      vm.togglePass(PassType.deinterlace, false);
    }

    setUp(() {
      vm = MainViewModel(
          runner: FakeJobRunner(),
          continuityService: const NoSourceModelContinuity());
    });
    tearDown(() => vm.dispose());

    test('a 25p source starts at 50, and the panel shows it', () async {
      await select(25);
      expect(vm.selectedItem?.videoInfo?.frameRate, 25,
          reason: 'the added item must be the selected one');
      vm.togglePass(PassType.frameRate, true);
      expect(vm.processingPipeline.frameRate.target, FrameRateTarget.pal50);
      expect(vm.getDynamicParams('frame_rate').values['target'], 'pal50');
    });

    test('no video selected: stays at 25', () async {
      vm.togglePass(PassType.frameRate, true);
      expect(vm.processingPipeline.frameRate.target, FrameRateTarget.pal25);
    });

    test('a target chosen before is kept when the pass is switched on',
        () async {
      await select(25);
      vm.updateDynamicParams(
          'frame_rate',
          vm
              .getDynamicParams('frame_rate')
              .withValue('target', 'ntsc2997'));
      vm.togglePass(PassType.frameRate, true);
      expect(vm.processingPipeline.frameRate.target, FrameRateTarget.ntsc2997);
    });
  });
}
