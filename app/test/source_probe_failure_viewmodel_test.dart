// Task #85: a source the worker cannot read (`--probe-source` answers
// `{"error": …}`) used to be marked Ready with no model: no reason anywhere,
// the previous video's preview and timeline left on screen, and a job that
// made the worker probe again and guess the count by decoding. Now the item
// is failed with the worker's reason and log lines, nothing runs or renders
// for it, and Retry analyses it again.
//
// The continuity service, the preview generator and the field-order
// detector are faked; the service's own reading of the worker's answer is
// source_probe_test.dart.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/crop_detect_report.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/queue_item.dart';
import 'package:vapourbox/models/source_model.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';
import 'package:vapourbox/services/timestamp_continuity_service.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

import 'fakes/fake_job_runner.dart';

const _reason = 'could not count the frames of bad.mp4: ffprobe\'s '
    'video-start probe failed (exit code 1)';
const _workerLines = [
  'the video-start probe failed (attempt 1 of 3): exit code 1',
  'the video-start probe failed (attempt 2 of 3): exit code 1',
];

SourceModel _model(String path, {int frames = 100, bool deferred = false,
        Map<String, dynamic>? continuity}) =>
    SourceModel.fromJson({
      'schema': SourceModel.schema,
      'identity': {'path': path, 'sizeBytes': 1, 'modifiedMs': 1},
      'formatName': deferred ? 'mpeg' : 'mov,mp4',
      'video': {'width': 720, 'height': 576, 'frameRate': 25.0, 'frameCount': frames},
      'audioStreams': [],
      if (continuity != null) 'continuity': continuity,
      if (deferred) 'continuityDeferred': true,
    })!;

const _oneReset = {
  'format': 'mpeg',
  'applies': true,
  'resets': [
    {'stream': 0, 'codecType': 'video', 'packet': 150, 'from': 6.46, 'to': 0.5}
  ],
  'videoPackets': 300,
};

class _FakeContinuity extends TimestampContinuityService {
  /// Paths that fail to probe (each answer is taken in turn; past the end,
  /// they read).
  final failures = <String, int>{};
  final probed = <String>[];
  ContinuityProxy? proxy;
  final scans = <Completer<SourceModel?>>[];
  final tasks = <ContinuityScanTask>[];
  String? scanError;

  @override
  Future<SourceProbe> probeSource(String path, {bool deferScan = false}) async {
    probed.add(path);
    final left = failures[path] ?? 0;
    if (left > 0) {
      failures[path] = left - 1;
      return const SourceProbe(error: _reason, log: _workerLines);
    }
    if (path.endsWith('.vob') && proxy == null) {
      return SourceProbe(model: _model(path, deferred: deferScan));
    }
    return SourceProbe(model: _model(path));
  }

  @override
  ContinuityScanTask completeSource(SourceModel model, {void Function(double)? onProgress}) {
    final c = Completer<SourceModel?>();
    scans.add(c);
    final t = ContinuityScanTask.of(c.future,
        error: scanError, log: scanError == null ? const [] : _workerLines);
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
    final needs = scanned?.needsCopy ?? false;
    return (checked: true, proxy: needs ? proxy : null, scan: scanned, error: null);
  }
}

/// The real generator's state (its frame count and source), with every
/// decode faked: what is selected decides [totalFrames].
class _FakePreview extends PreviewGenerator {
  final processedFor = <int>[];
  var unloads = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Uint8List>> loadVideo(String videoPath, SourceModel model,
      {int thumbnailCount = 20}) async {
    await super.selectSource(videoPath, model);
    return [Uint8List(1)];
  }

  @override
  Future<Uint8List?> getFrameAtIndex(int frameIndex) async => Uint8List(1);

  @override
  void unloadSource() {
    unloads++;
    super.unloadSource();
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
    processedFor.add(totalFrames);
    return null;
  }

  @override
  Future<void> cancelPreviewGeneration() async {}

  @override
  Future<void> dispose() async {}
}

class _FakeDetector extends FieldOrderDetector {
  @override
  Future<VideoInfo?> getVideoInfo(String videoPath, SourceModel model) async => VideoInfo(
        width: 720,
        height: 576,
        frameRate: 25,
        duration: model.frameCount / 25,
        frameCount: model.frameCount,
        codec: 'h264',
        pixelFormat: 'yuv420p',
        scanType: ScanType.progressive,
        hasAudio: false,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeContinuity continuity;
  late _FakePreview preview;
  late FakeJobRunner runner;

  MainViewModel vm() => MainViewModel(
        runner: runner,
        continuityService: continuity,
        previewGenerator: preview,
        fieldOrderDetector: _FakeDetector(),
        cropDetector: (job) async => const CropDetectReport.failed('fake'),
        noiseHaloDetector: (job) async => throw 'no noise detector in this test',
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    continuity = _FakeContinuity();
    preview = _FakePreview();
    runner = FakeJobRunner();
  });

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  String log(MainViewModel v) => v.logMessages.map((m) => m.message).join('\n');

  test('the item shows the reason, and the log has it with the worker\'s lines', () async {
    continuity.failures['/v/bad.mp4'] = 1;
    final v = vm();
    await v.addToQueue('/v/bad.mp4');
    final item = v.selectedItem!;

    expect(item.status, QueueItemStatus.failed);
    expect(item.analysisFailed, isTrue);
    expect(item.sourceError, _reason);
    expect(item.errorMessage, 'Could not read this video: $_reason');
    expect(item.sourceErrorLog, _workerLines);
    expect(item.sourceModel, isNull);
    expect(item.videoInfo, isNull);
    expect(item.canProcess, isFalse);
    expect(log(v), contains('bad.mp4: could not be read: $_reason'));
    for (final l in _workerLines) {
      expect(log(v), contains('bad.mp4: worker: $l'));
    }
  });

  test('no job runs for it', () async {
    continuity.failures['/v/bad.mp4'] = 1;
    final v = vm();
    await v.addToQueue('/v/bad.mp4');
    await v.addToQueue('/v/good.mp4');
    await v.startQueueProcessing();
    await settle();
    expect(runner.started.map((j) => j.inputPath), ['/v/good.mp4'],
        reason: 'only the readable video runs');
    expect(v.queue.first.status, QueueItemStatus.failed);
    expect(v.queue.first.errorMessage, contains(_reason));
  });

  test('a run keeps its log, so a failure log can still say why', () async {
    continuity.failures['/v/bad.mp4'] = 1;
    final v = vm();
    await v.addToQueue('/v/bad.mp4');
    await v.addToQueue('/v/good.mp4');
    await v.startQueueProcessing();
    await settle();
    expect(v.debugItemLog(v.queue.first.id).map((m) => m.message).join('\n'),
        contains(_reason));
  });

  test('Retry analyses it again; once it reads, a job carries the model', () async {
    continuity.failures['/v/bad.mp4'] = 1;
    final v = vm();
    await v.addToQueue('/v/bad.mp4');
    final item = v.selectedItem!;
    expect(item.status, QueueItemStatus.failed);

    v.requeueItem(item.id);
    await settle();
    expect(continuity.probed.where((p) => p == '/v/bad.mp4'), hasLength(2));
    expect(item.status, QueueItemStatus.ready);
    expect(item.analysisFailed, isFalse);
    expect(item.errorMessage, isNull);
    expect(item.videoInfo!.frameCount, 100);

    await v.startQueueProcessing();
    await settle();
    expect(runner.started, hasLength(1));
    expect(runner.started.single.source, isNotNull);
  });

  test('Retry all re-probes it first, and it stays failed if it still can\'t be read',
      () async {
    continuity.failures['/v/bad.mp4'] = 2;
    final v = vm();
    await v.addToQueue('/v/bad.mp4');
    await v.retryFailed();
    await settle();
    final item = v.queue.single;
    expect(continuity.probed.where((p) => p == '/v/bad.mp4'), hasLength(2));
    expect(item.status, QueueItemStatus.failed);
    expect(item.sourceError, _reason);
    expect(runner.started, isEmpty);
  });

  test('reset() leaves it failed', () async {
    continuity.failures['/v/bad.mp4'] = 1;
    final v = vm();
    await v.addToQueue('/v/bad.mp4');
    v.reset();
    expect(v.queue.single.status, QueueItemStatus.failed);
    expect(v.queue.single.analysisFailed, isTrue);
  });

  test('selecting it leaves no timeline or preview of the previous video', () async {
    continuity.failures['/v/bad.mp4'] = 1;
    final v = vm();
    await v.addToQueue('/v/good.mp4');
    await settle();
    expect(v.totalFrames, 100);
    await v.addToQueue('/v/bad.mp4');
    await settle();
    final bad = v.queue.last;
    final rendered = preview.processedFor.length;

    await v.selectQueueItem(bad.id);
    await settle();
    expect(preview.unloads, greaterThan(0));
    expect(v.totalFrames, 0, reason: 'not the other video\'s count');
    expect(preview.processedFor.length, rendered,
        reason: 'no processed preview is rendered for it');
  });

  test('a joined copy that can\'t be read fails the item, naming the copy', () async {
    const proxy = ContinuityProxy(
        path: '/tmp/continuous_abc_title.vob', resetCount: 1, sizeBytes: 1 << 20);
    final v = vm();
    await v.addToQueue('/v/title.vob');
    await settle();
    final item = v.selectedItem!;
    expect(item.continuityPending, isTrue);
    continuity.proxy = proxy;
    continuity.failures[proxy.path] = 1;
    continuity.scans.single
        .complete(_model('/v/title.vob', frames: 150, continuity: _oneReset));
    await settle();
    expect(item.status, QueueItemStatus.failed);
    expect(item.sourceError, 'its joined copy could not be read: $_reason');
    expect(item.errorMessage, contains('joined copy'));
  });

  test('a failed --complete-source warns with its reason; the item stays ready', () async {
    continuity.scanError = 'the reset scan failed: exit code 1';
    final v = vm();
    await v.addToQueue('/v/title.vob');
    await settle();
    final item = v.selectedItem!;
    continuity.scans.single.complete(null);
    await settle();
    expect(item.status, QueueItemStatus.ready);
    expect(item.analysisFailed, isFalse);
    expect(log(v), contains('could not be checked for resets (the reset scan failed: exit code 1)'));
    expect(log(v), contains('title.vob: worker: ${_workerLines.first}'));
  });
}
