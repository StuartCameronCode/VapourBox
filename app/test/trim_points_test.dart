// In/out points map to the frame the preview showed (task #59).
//
// The scrubber turns a position into a frame with `round(pos × (N − 1))`
// (FrameMath). The in/out points used `round(pos × N)`, so a point set at
// frame F became F + round(F / (N − 1)): one frame late in the second half of
// the source, and `N` (one past the last frame) for an out point at the end.
// Every job (encode, preview, detectors) now takes its frames from
// QueueItem.inPointFrame / outPointFrame, which use FrameMath.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/native_res_report.dart';
import 'package:vapourbox/models/queue_item.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/frame_math.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

import 'fakes/fake_job_runner.dart';

QueueItem _item(int frameCount) => QueueItem(
      inputPath: '/videos/clip.mp4',
      outputPath: '/videos/clip.out.mkv',
      videoInfo: VideoInfo(
        width: 320,
        height: 240,
        frameRate: 25,
        duration: frameCount / 25,
        frameCount: frameCount,
        codec: 'h264',
        pixelFormat: 'yuv420p',
        hasAudio: false,
      ),
    );

double _at(int frame, int n) => FrameMath.positionForFrame(frame, n);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('frame -> position -> frame', () {
    for (final n in [2, 3, 100, 101, 3151]) {
      test('round-trips at every frame of $n', () {
        for (var f = 0; f < n; f++) {
          expect(FrameMath.frameForPosition(_at(f, n), n), f, reason: 'frame $f of $n');
        }
      });
    }
  });

  group('QueueItem in/out frames', () {
    for (final (n, firstHalf, secondHalf) in [(100, 10, 60), (3151, 10, 2000)]) {
      test('N = $n: a point at frame F is frame F, in both halves and at the ends', () {
        final item = _item(n);
        for (final f in [0, firstHalf, secondHalf, n - 2, n - 1]) {
          item.inPoint = _at(f, n);
          item.outPoint = _at(f, n);
          expect(item.inPointFrame, f, reason: 'in point at $f');
          expect(item.outPointFrame, f, reason: 'out point at $f');
        }
      });

      test('N = $n: an out point at the end is the last frame, not N', () {
        final item = _item(n)..outPoint = 1.0;
        expect(item.outPointFrame, n - 1);
        expect(item.trimmedFrameCount, n);
      });
    }

    test('a position between frames is the frame the preview shows there', () {
      final item = _item(100)..inPoint = 0.6034;
      expect(item.inPointFrame, FrameMath.frameForPosition(0.6034, 100));
      expect(item.inPointFrame, 60);
    });

    test('no range: no frames and no trimmed count', () {
      final item = _item(100);
      expect(item.inPointFrame, isNull);
      expect(item.outPointFrame, isNull);
      expect(item.trimmedFrameCount, isNull);
    });
  });

  group('jobs built by the view model', () {
    late FakeJobRunner runner;
    late List<VideoJob> detectorJobs;
    late MainViewModel vm;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      runner = FakeJobRunner();
      detectorJobs = [];
      vm = MainViewModel(
        runner: runner,
        nativeResDetector: (job) async {
          detectorJobs.add(job);
          return NativeResReport.fromJson(const {'found': false});
        },
      );
    });

    tearDown(() => vm.dispose());

    /// Set the points the way the I / O buttons do: at the scrubber, which a
    /// frame step leaves at `positionForFrame`.
    QueueItem trimmed(int n, int? inFrame, int? outFrame) {
      final item = vm.debugAddQueueItemForTest('/videos/clip_$n.mp4',
          width: 320, height: 240, frameCount: n);
      if (inFrame != null) {
        item.scrubberPosition = _at(inFrame, n);
        vm.setInPointToCurrent();
      }
      if (outFrame != null) {
        item.scrubberPosition = _at(outFrame, n);
        vm.setOutPointToCurrent();
      }
      item.status = QueueItemStatus.ready;
      return item;
    }

    for (final (n, inFrame, outFrame) in [
      (100, 60, 99),
      (100, 10, 70),
      (100, null, 99),
      (100, 99, 99),
      (3151, 2000, 3150),
    ]) {
      test('N = $n, in $inFrame, out $outFrame: the encode and the detectors get those frames',
          () async {
        trimmed(n, inFrame, outFrame);
        await vm.startQueueProcessing();
        final job = runner.started.single;
        expect(job.startFrame, inFrame);
        expect(job.endFrame, outFrame);
        expect(job.totalFrames, outFrame - (inFrame ?? 0) + 1);

        await vm.detectNativeResolution();
        expect(detectorJobs.single.startFrame, inFrame);
        expect(detectorJobs.single.endFrame, outFrame);
      });
    }

    test('an untrimmed job carries the source length and no frames', () async {
      trimmed(100, null, null);
      await vm.startQueueProcessing();
      final job = runner.started.single;
      expect(job.startFrame, isNull);
      expect(job.endFrame, isNull);
      expect(job.totalFrames, 100);
    });
  });

  test('no position is turned into a frame outside FrameMath', () {
    // Two rules for the same conversion is what this task fixed. A position
    // times a frame count anywhere else in the app is a second rule.
    final pattern = RegExp(
        r'\*\s*\(?[\w?.!]*\b(frameCount|totalFrames)\b|\b(frameCount|totalFrames)\b\)?\s*\*');
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('.g.dart')) continue;
      if (p.basename(f.path) == 'frame_math.dart') continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (pattern.hasMatch(line)) offenders.add('${f.path}:${i + 1}: ${line.trim()}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'use FrameMath.frameForPosition (QueueItem.inPointFrame / outPointFrame)');
  });
}
