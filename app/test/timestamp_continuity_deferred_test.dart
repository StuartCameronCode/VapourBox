// Task #55: an MPEG-PS/TS's timestamp-reset scan reads the whole file
// (77 s for a 2 h DVD title on a network share), so analysis no longer
// waits for it. The worker's model comes back with the scan deferred, the
// item shows what needs no seek (Video Info, frame 0, the processed preview
// at frame 0), and every seek (thumbnails, the scrubber, in/out points,
// detectors) and every job waits until the scan answers: on a file whose
// clock resets, a seek can land in any segment, before the reset too.
//
// The worker, the preview generator and the field-order detector are faked
// and record every call; a Completer stands in for the scan.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/crop_detect_report.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/source_model.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';
import 'package:vapourbox/services/timestamp_continuity_service.dart';
import 'package:vapourbox/services/worker_manager.dart' show CompletionResult;
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

import 'fakes/fake_job_runner.dart';

Map<String, dynamic> _modelJson(String path,
        {bool deferred = false, Map<String, dynamic>? continuity, int frames = 150}) =>
    {
      'schema': SourceModel.schema,
      'identity': {'path': path, 'sizeBytes': 1, 'modifiedMs': 1},
      'formatName': 'mpeg',
      'video': {'width': 720, 'height': 576, 'frameRate': 25.0, 'frameCount': frames},
      'audioStreams': [],
      if (continuity != null) 'continuity': continuity,
      if (deferred) 'continuityDeferred': true,
    };

const _noReset = {'format': 'mpeg', 'applies': true, 'resets': [], 'videoPackets': 150};
const _oneReset = {
  'format': 'mpeg',
  'applies': true,
  'resets': [
    {'stream': 0, 'codecType': 'video', 'packet': 150, 'from': 6.46, 'to': 0.5}
  ],
  'videoPackets': 300,
};

class _FakeContinuity extends TimestampContinuityService {
  final probed = <(String, bool)>[];
  final prepared = <SourceModel?>[];
  final scans = <Completer<SourceModel?>>[];
  final tasks = <ContinuityScanTask>[];
  ContinuityProxy? proxy;
  String? failPrepareFor;

  @override
  Future<SourceProbe> probeSource(String path, {bool deferScan = false}) async {
    probed.add((path, deferScan));
    if (proxy != null && path == proxy!.path) {
      return SourceProbe(
          model: SourceModel.fromJson(_modelJson(path, continuity: _noReset, frames: 300)));
    }
    return SourceProbe(model: SourceModel.fromJson(_modelJson(path, deferred: deferScan)));
  }

  @override
  ContinuityScanTask completeSource(SourceModel model, {void Function(double)? onProgress}) {
    final c = Completer<SourceModel?>();
    scans.add(c);
    onProgress?.call(0.25);
    final t = ContinuityScanTask.of(c.future);
    tasks.add(t);
    return t;
  }

  @override
  Future<({bool checked, ContinuityProxy? proxy, ContinuityScan? scan, String? error})>
      prepare(String source, String id,
          {ContinuityScan? scanned,
          SourceModel? model,
          void Function(ContinuityScan)? onJoining,
          void Function(double)? onProgress}) async {
    prepared.add(model);
    if (source == failPrepareFor) throw StateError('join failed to start');
    final needs = scanned?.needsCopy ?? false;
    return (checked: true, proxy: needs ? proxy : null, scan: scanned, error: null);
  }
}

/// Records every decode; a seek is anything but frame 0.
class _FakePreview extends PreviewGenerator {
  final calls = <String>[];
  final processedFrames = <int>[];

  @override
  Future<void> initialize() async {}

  @override
  int get totalFrames => 150;

  @override
  Future<List<Uint8List>> loadVideo(String videoPath, SourceModel model,
      {int thumbnailCount = 20}) async {
    calls.add('thumbnails $videoPath');
    return [Uint8List(1)];
  }

  @override
  Future<void> selectSource(String videoPath, SourceModel model) async {
    calls.add('select $videoPath');
  }

  @override
  Future<List<Uint8List>> loadVideoRange({
    required String videoPath,
    required SourceModel model,
    required double startTime,
    required double endTime,
    required int thumbnailCount,
  }) async {
    calls.add('range $videoPath');
    return [Uint8List(1)];
  }

  @override
  Future<Uint8List?> getFrameAtIndex(int frameIndex) async {
    calls.add('frame $frameIndex');
    return Uint8List(1);
  }

  @override
  Future<Uint8List?> generateProcessedPreview({
    required int frameNumber,
    required ProcessingPipeline pipeline,
    required FieldOrder fieldOrder,
    required EncodingSettings encodingSettings,
    int subFrame = 0,
    int? startFrame,
    int? endFrame,
    String? pitchFactorsPath,
    CancelToken? cancelToken,
  }) async {
    processedFrames.add(frameNumber);
    return null;
  }

  @override
  Future<void> cancelPreviewGeneration() async {}

  @override
  Future<void> dispose() async {}

  /// Every call that seeks: thumbnails, ranges, any frame but 0.
  List<String> get seeks => [
        for (final c in calls)
          if (c.startsWith('thumbnails') || c.startsWith('range') ||
              (c.startsWith('frame') && c != 'frame 0'))
            c,
      ];
}

class _FakeDetector extends FieldOrderDetector {
  final read = <(String, int)>[];
  @override
  Future<VideoInfo?> getVideoInfo(String videoPath, SourceModel model) async {
    read.add((videoPath, model.frameCount));
    return VideoInfo(
      width: 720,
      height: 576,
      frameRate: 25,
      duration: model.frameCount / 25,
      frameCount: model.frameCount,
      codec: 'mpeg2video',
      pixelFormat: 'yuv420p',
      scanType: ScanType.progressive,
      hasAudio: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeContinuity continuity;
  late _FakePreview preview;
  late _FakeDetector detector;
  late FakeJobRunner runner;
  late List<VideoJob> detectorJobs;

  MainViewModel vm() => MainViewModel(
        runner: runner,
        continuityService: continuity,
        previewGenerator: preview,
        fieldOrderDetector: detector,
        cropDetector: (job) async {
          detectorJobs.add(job);
          return const CropDetectReport.failed('fake');
        },
        noiseHaloDetector: (job) async => throw 'no noise detector in this test',
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    continuity = _FakeContinuity();
    preview = _FakePreview();
    detector = _FakeDetector();
    runner = FakeJobRunner();
    detectorJobs = [];
  });

  /// Lets the scan queue and the preview debounce run.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('analysis shows what needs no seek, and holds every seek until the scan answers',
      () async {
    final v = vm();
    await v.addToQueue('/nas/title.vob');
    await settle();
    final item = v.selectedItem!;

    expect(continuity.probed.first, ('/nas/title.vob', true),
        reason: 'the scan is deferred, not run during analysis');
    expect(item.videoInfo, isNotNull, reason: 'Video Info does not wait');
    expect(item.currentFrame, isNotNull, reason: 'frame 0 never seeks');
    expect(preview.processedFrames, isNotEmpty);
    expect(preview.processedFrames.toSet(), {0}, reason: 'the processed preview of frame 0');
    expect(item.continuityPending, isTrue);
    expect(continuity.scans, hasLength(1), reason: 'the scan runs after analysis');
    expect(item.continuityProgress, 0.25);
    expect(v.timestampCheckText, contains('25%'));

    // Nothing that seeks gets through while it runs.
    await v.setScrubberPosition(0.5);
    v.setInPoint(0.2);
    v.setOutPointToCurrent();
    v.zoomTimelineBy(4);
    await settle();
    expect(item.scrubberPosition, 0.0);
    expect(item.inPoint, isNull);
    expect(item.outPoint, isNull);
    expect(preview.seeks, isEmpty, reason: '${preview.calls}');
    expect(item.thumbnails, isEmpty);

    // A detector and a job wait for the answer.
    final detect = v.detectCrop();
    final start = v.startQueueProcessing();
    await settle();
    expect(detectorJobs, isEmpty);
    expect(runner.started, isEmpty);
    expect(v.waitingForContinuity, same(item));

    continuity.scans.single
        .complete(SourceModel.fromJson(_modelJson('/nas/title.vob', continuity: _noReset)));
    await detect;
    await settle();
    expect(item.continuityPending, isFalse);
    expect(item.continuityChecked, isTrue);
    expect(item.sourceModel!.continuityDeferred, isFalse);
    expect(item.sourceModel!.continuity!.needsCopy, isFalse);
    expect(item.decodePath, '/nas/title.vob', reason: 'no reset, no copy');
    expect(detectorJobs.single.continuityChecked, isTrue);
    expect(runner.started.single.continuityChecked, isTrue);
    expect(runner.started.single.source, isNotNull);
    expect(item.thumbnails, isNotEmpty, reason: 'the timeline opens');
    expect(preview.calls, contains('thumbnails /nas/title.vob'));
    await v.setScrubberPosition(0.5);
    expect(item.scrubberPosition, 0.5);
    await runner.complete(const CompletionResult(success: true));
    await start;
    v.dispose();
  });

  test('a reset found by the scan joins first; nothing seeks the original', () async {
    const proxy = ContinuityProxy(
        path: '/tmp/continuous_abc_title.vob', resetCount: 1, sizeBytes: 1 << 20);
    continuity.proxy = proxy;
    final v = vm();
    await v.addToQueue('/nas/title.vob');
    await settle();
    final item = v.selectedItem!;
    expect(item.videoInfo!.frameCount, 150, reason: 'the original counts its last segment');

    final completed =
        SourceModel.fromJson(_modelJson('/nas/title.vob', continuity: _oneReset))!;
    continuity.scans.single.complete(completed);
    await settle();

    expect(continuity.prepared.last, same(completed),
        reason: 'the join is given the scan, so the worker does not read the source again');
    expect(item.decodePath, proxy.path);
    expect(item.continuityPending, isFalse);
    expect(item.videoInfo!.frameCount, 300, reason: 'Video Info is read again from the copy');
    expect(detector.read.last, (proxy.path, 300));
    expect(preview.seeks, ['thumbnails ${proxy.path}'],
        reason: 'the only seeking decode is of the copy: ${preview.calls}');
    await v.detectCrop();
    expect(detectorJobs.single.inputPath, proxy.path);
    v.dispose();
  });

  test('a failed scan lets everything go ahead, unchecked, and says so', () async {
    final v = vm();
    await v.addToQueue('/nas/capture.ts');
    await settle();
    final item = v.selectedItem!;
    continuity.scans.single.complete(null);
    await settle();
    expect(item.continuityPending, isFalse);
    expect(item.continuityChecked, isFalse, reason: 'the worker will scan and warn');
    expect(item.decodePath, '/nas/capture.ts');
    expect(item.thumbnails, isNotEmpty);
    expect(v.logMessages.map((m) => m.message).join('\n'), contains('could not be checked'));
    v.dispose();
  });

  test('removing a video stops its scan', () async {
    final v = vm();
    await v.addToQueue('/nas/title.vob');
    await settle();
    final item = v.selectedItem!;
    v.removeFromQueue(item.id);
    expect(continuity.tasks.single.isCancelled, isTrue);
    expect(item.continuityPending, isFalse);
    continuity.scans.single.complete(
        SourceModel.fromJson(_modelJson('/nas/title.vob', continuity: _oneReset)));
    await settle();
    expect(continuity.prepared, isEmpty, reason: 'no join for a removed video');
    v.dispose();
  });

  test('cancelling a job that waits for the scan returns the queue to idle', () async {
    final v = vm();
    await v.addToQueue('/nas/title.vob');
    await settle();
    final item = v.selectedItem!;
    final start = v.startQueueProcessing();
    await settle();
    expect(v.waitingForContinuity, same(item));
    await v.cancelProcessing();
    await start;
    expect(v.waitingForContinuity, isNull);
    expect(v.state.isActive, isFalse);
    expect(runner.started, isEmpty);
    expect(item.continuityPending, isTrue, reason: 'the scan itself goes on');
    v.dispose();
  });

  test('scans run one at a time, in the order the videos were added', () async {
    final v = vm();
    await v.addToQueue('/nas/a.vob');
    await v.addToQueue('/nas/b.vob');
    await settle();
    expect(continuity.scans, hasLength(1), reason: 'the second waits for the first');
    final b = v.queue.last;
    expect(b.continuityPending, isTrue);
    expect(v.queue.last.continuityTask, isNull, reason: 'queued, not running');
    continuity.scans.first
        .complete(SourceModel.fromJson(_modelJson('/nas/a.vob', continuity: _noReset)));
    await settle();
    expect(continuity.scans, hasLength(2));
    continuity.scans.last
        .complete(SourceModel.fromJson(_modelJson('/nas/b.vob', continuity: _noReset)));
    await settle();
    expect(b.continuityPending, isFalse);
    v.dispose();
  });

  test('a scan that throws releases its video and the scans after it', () async {
    continuity.failPrepareFor = '/nas/a.vob';
    final v = vm();
    await v.addToQueue('/nas/a.vob');
    await v.addToQueue('/nas/b.vob');
    await settle();
    final a = v.queue.first;
    final b = v.queue.last;
    continuity.scans.first
        .complete(SourceModel.fromJson(_modelJson('/nas/a.vob', continuity: _noReset)));
    await settle();
    expect(a.continuityPending, isFalse);
    expect(continuity.scans, hasLength(2), reason: 'the queue goes on after a throw');
    expect(v.logMessages.map((m) => m.message).join('\n'), contains('timestamp check failed'));
    continuity.scans.last
        .complete(SourceModel.fromJson(_modelJson('/nas/b.vob', continuity: _noReset)));
    await settle();
    expect(b.continuityPending, isFalse);
    v.dispose();
  });

  test('idet decodes a TS/PS from its start, and seeks anything else as before', () {
    final ps = FieldOrderDetector.idetArgs('/nas/t.vob',
        duration: 100, frameRate: 25, sequential: true);
    expect(ps, isNot(contains('-ss')));
    expect(ps.join(' '), contains('-vf trim=start_frame=50,idet -frames:v 200'));
    final mp4 = FieldOrderDetector.idetArgs('/x.mp4', duration: 100, frameRate: 25);
    expect(mp4.take(4), ['-ss', '2', '-i', '/x.mp4']);
    expect(mp4.join(' '), contains('-vf idet -frames:v 200'));
    final short = FieldOrderDetector.idetArgs('/t.vob',
        duration: 3, frameRate: 25, sequential: true);
    expect(short.join(' '), contains('-vf idet'));
  });
}
