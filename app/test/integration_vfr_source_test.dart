/// Variable-frame-rate sources, end to end (issue #137).
///
/// A phone or screen recording drops its frame rate when the scene gets dark
/// or busy. The decoder used to fill each gap by repeating a frame, and the job
/// counted only the stored frames, so the encode came out short of its audio
/// with frozen frames wherever the camera had slowed — which frame
/// interpolation then turned into stutter, animating between two identical
/// frames and then jumping.
///
/// The fixture (see [VfrFixture]) is cut from a constant-rate clip, so the
/// frame the camera "dropped" at every gap is still known: the pixels are
/// checked against it, not against an expected number.
///
/// Heavy (full encodes + preview) — nightly, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/vfr_fixture.dart';
import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/vfr';

/// The job the app builds for the fixture: it counts the source by duration
/// (`FieldOrderDetector.frameCountFor`), which is the slot count.
Map<String, dynamic> _job(String name, String input, FrameRateParameters fr) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        frameRate: fr,
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.h264,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.passthrough,
      ),
      totalFrames: VfrFixture.slots,
      inputFrameRate: VfrFixture.fps,
      inputWidth: VfrFixture.width,
      inputHeight: VfrFixture.height,
      inputPixelFormat: 'yuv420p',
    ).toJson();

/// The container's duration: Matroska streams carry none of their own.
Future<double> _duration(String path) async {
  final json = await WorkerHarness.ffprobeJson(
      ['-v', 'error', '-show_entries', 'format=duration', '-of', 'json', path]);
  return double.parse(json['format']['duration'].toString());
}

Future<int> _frames(String path) async {
  final s = await WorkerHarness.firstStream(path,
      selector: 'v:0', entries: ['nb_read_frames'], countFrames: true);
  return int.parse(s!['nb_read_frames'].toString());
}

/// Gap slots spread over the slowed half, and the real frames beside them.
const _gaps = [152, 182, 212, 242, 272];

void main() {
  late String vfr;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    vfr = await VfrFixture.path();
  });

  test('a VFR source is encoded for its whole length', () async {
    final r = await WorkerHarness.runJob(
        _job('full_length', vfr, const FrameRateParameters()),
        label: 'vfr_full_length');
    expect(r.success, isTrue, reason: r.error);

    final n = await _frames(r.outputPath!);
    final video = await _duration(r.outputPath!);
    final source = await _duration(VfrFixture.groundTruth);
    print('  $n frames, ${video.toStringAsFixed(3)} s (source ${source.toStringAsFixed(3)} s)');
    expect(n, VfrFixture.slots,
        reason: 'one frame per 1/29.97 s of source. ${VfrFixture.storedFrames} '
            'means the gaps were dropped; the old decode also cut the end off');
    expect(video, closeTo(source, 2 / VfrFixture.fps),
        reason: 'the encode must be as long as the source, or audio runs on '
            'past the picture');
  }, timeout: const Timeout(Duration(minutes: 5)));

  group('FlowFPS to 59.94', () {
    late String output;

    setUpAll(() async {
      final r = await WorkerHarness.runJob(
          _job('flowfps', vfr, const FrameRateParameters(
              enabled: true, target: FrameRateTarget.ntsc5994)),
          label: 'vfr_flowfps');
      expect(r.success, isTrue, reason: r.error);
      output = r.outputPath!;
    });

    test('fills each gap with the motion the camera missed', () async {
      // FlowFPS 2x passes the slots through at even output frames, so output
      // 2i is slot i. A gap slot must look more like the frame the camera
      // dropped than repeating its neighbour would — a repeat is what made
      // interpolation stall and jump.
      var interpolated = 0.0, repeated = 0.0;
      for (final i in _gaps) {
        expect(VfrFixture.isGap(i), isTrue);
        final truth = await WorkerHarness.frameRgb24(VfrFixture.groundTruth, i, label: 'truth');
        final before = await WorkerHarness.frameRgb24(VfrFixture.groundTruth, i - 1, label: 'truth');
        final out = await WorkerHarness.frameRgb24(output, 2 * i, label: 'out');
        final ei = WorkerHarness.meanAbsDiff(out, truth);
        final er = WorkerHarness.meanAbsDiff(before, truth);
        print('  slot $i: interpolated ${ei.toStringAsFixed(2)}, repeat would be ${er.toStringAsFixed(2)}');
        interpolated += ei;
        repeated += er;
      }
      expect(interpolated, lessThan(repeated * 0.85));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('keeps the real frames in their own slots', () async {
      // An off-by-one in the slot map would put each real frame a slot early
      // or late; it must match its own ground truth best.
      for (final i in [151, 183, 241]) {
        expect(VfrFixture.isGap(i), isFalse);
        final out = await WorkerHarness.frameRgb24(output, 2 * i, label: 'out');
        final diffs = {
          for (final j in [i - 1, i, i + 1])
            j: WorkerHarness.meanAbsDiff(
                out, await WorkerHarness.frameRgb24(VfrFixture.groundTruth, j, label: 'truth')),
        };
        print('  slot $i vs source frames: $diffs');
        final best = diffs.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
        expect(best, i);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('the preview of a gap shows the frame the encode has there', () async {
      for (final i in [152, 200]) {
        final pv = await WorkerHarness.runPreview(
            _job('flowfps_preview', vfr, const FrameRateParameters(
                enabled: true, target: FrameRateTarget.ntsc5994)),
            frame: i);
        expect(pv.success, isTrue, reason: pv.errorTail);
        final rgb = await WorkerHarness.imageToRgb24(pv.png!, label: 'pv$i');
        final diffs = {
          for (final k in [2 * i - 1, 2 * i, 2 * i + 1])
            k: WorkerHarness.meanAbsDiff(rgb, await WorkerHarness.frameRgb24(output, k, label: 'enc')),
        };
        print('  preview of slot $i vs encoded frames: $diffs');
        final best = diffs.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
        expect(best, 2 * i);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
