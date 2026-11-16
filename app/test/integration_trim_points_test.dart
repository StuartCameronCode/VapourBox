// A trim set at the frames the preview showed encodes exactly those frames
// (task #59).
//
// The in/out points used `round(pos × N)` while the scrubber uses
// `round(pos × (N − 1))`, so an in point in the second half of a source began
// one frame late and an out point at the last frame asked for frame N, one
// past the end (the output repeated its last picture). Here the points are
// set the way the I / O buttons set them, the job is the one the view model
// builds, and the lossless output is compared with an INDEPENDENT decode of
// the source (`select=eq(n,F)`), never with the preview.
@Tags(['heavy'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/queue_item.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/frame_math.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

import 'fakes/fake_job_runner.dart';
import 'support/av_sync.dart' show countFrames;
import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/trim_points';

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

class _Fixture {
  final String file;

  /// (in, out) frames; null is "not set". `-1` is the last frame.
  final List<(int?, int?)> trims;

  /// The count the source model must report for the fixture's last frames to
  /// exist (null: whatever it says). small_clip.mp4's model says 3154 until
  /// task #54, where the decoder delivers 3151.
  final int? needsCount;
  const _Fixture(this.file, this.trims, {this.needsCount});
}

const _fixtures = [
  // 100 pictures, testsrc2 (every picture differs), H.264 with B-frames.
  _Fixture('conf_plain.mp4', [(10, 70), (60, -1), (null, -1), (99, -1)]),
  _Fixture('small_clip.mp4', [(2000, -1), (3148, -1)], needsCount: 3151),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  for (final f in _fixtures) {
    for (final (inArg, outArg) in f.trims) {
      test('${f.file}: in ${inArg ?? '-'}, out ${outArg == -1 ? 'last' : outArg ?? '-'}',
          () async {
        final source = _resource(f.file);
        final model = await WorkerHarness.sourceModel(source);
        final n = model.frameCount;
        if (f.needsCount != null && n != f.needsCount) {
          markTestSkipped('${f.file}: the source model says $n frames, the decoder '
              'delivers ${f.needsCount} (task #54)');
          return;
        }
        final inFrame = inArg;
        final outFrame = outArg == -1 ? n - 1 : outArg;

        // The job the app builds, with the points set as the I / O buttons
        // set them: at the scrubber, which a frame step puts at
        // positionForFrame.
        SharedPreferences.setMockInitialValues({});
        final runner = FakeJobRunner();
        final vm = MainViewModel(runner: runner);
        addTearDown(vm.dispose);
        final item = vm.debugAddQueueItemForTest(source,
            width: model.width,
            height: model.height,
            frameCount: n,
            frameRate: model.frameRate,
            pixelFormat: model.pixelFormat ?? 'yuv420p',
            source: model);
        if (inFrame != null) {
          item.scrubberPosition = FrameMath.positionForFrame(inFrame, n);
          vm.setInPointToCurrent();
        }
        if (outFrame != null) {
          item.scrubberPosition = FrameMath.positionForFrame(outFrame, n);
          vm.setOutPointToCurrent();
        }
        item.status = QueueItemStatus.ready;
        await vm.startQueueProcessing();
        final built = runner.started.single;
        expect(built.startFrame, inFrame);
        expect(built.endFrame, outFrame);

        // Encode it losslessly, with no pass, keeping the app's frames.
        const off = QTGMCParameters(enabled: false);
        final name = '${p.basenameWithoutExtension(f.file)}_${inFrame}_$outFrame';
        final job = built.copyWith(
          outputPath: '$_outDir/$name.mkv',
          qtgmcParameters: off,
          processingPipeline: ProcessingPipeline(deinterlace: off),
          encodingSettings: EncodingSettings(
            codec: VideoCodec.ffv1,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.none,
          ),
        );
        final result = await WorkerHarness.runJob(job.toJson(), label: name);
        expect(result.success, isTrue, reason: '${result.error}\n${result.logs.join('\n')}');
        final output = job.outputPath;

        final first = inFrame ?? 0;
        final last = outFrame ?? n - 1;
        final count = last - first + 1;
        expect(await countFrames(output), count, reason: 'pictures stored');

        Future<void> same(int outIndex, int sourceFrame) async {
          final got = await WorkerHarness.frameRgb24(output, outIndex, label: 'out');
          final want = await WorkerHarness.frameRgb24(source, sourceFrame, label: 'src');
          expect(WorkerHarness.meanAbsDiff(got, want), 0,
              reason: 'output picture $outIndex must be source frame $sourceFrame');
        }

        await same(0, first);
        await same(count - 1, last);
        if (count > 1) {
          // Not a repeat of the picture before (the over-ask past the end
          // repeated the last picture): testsrc2 changes every picture.
          final a = await WorkerHarness.frameRgb24(output, count - 2, label: 'out');
          final b = await WorkerHarness.frameRgb24(output, count - 1, label: 'out');
          expect(WorkerHarness.meanAbsDiff(a, b), greaterThan(0),
              reason: 'the last picture is repeated');
        }
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  }
}
