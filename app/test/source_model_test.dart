// The worker's source model (`--probe-source`, task #50) as the app reads it.
// The app derives no source fact of its own: it reads the worker's JSON and
// sends it back unchanged. These check the reader against what the worker
// actually prints, so a renamed field fails here rather than reading as
// "unknown" in the app.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/source_model.dart';

import 'support/worker_harness.dart';

void main() {
  group('reading', () {
    test('an error answer, another schema or no video is not a model', () {
      expect(SourceModel.parse('{"error": "nope"}'), isNull);
      expect(SourceModel.fromJson({'schema': 99, 'video': {}}), isNull);
      expect(SourceModel.fromJson({'schema': SourceModel.schema}), isNull);
      expect(SourceModel.parse('not json'), isNull);
    });

    test('it goes back exactly as it came, unknown fields included', () {
      final json = {
        'schema': SourceModel.schema,
        'video': {'width': 2, 'futureField': [1]},
        'somethingNew': true,
      };
      expect(SourceModel.fromJson(json)!.toJson(), same(json));
    });

    test('the timeline of a late picture is its frames, not the file', () {
      final m = SourceModel.fromJson({
        'schema': SourceModel.schema,
        'duration': 6.32,
        'video': {'frameRate': 25.0, 'frameCount': 128, 'videoStartOffset': 1.2},
      })!;
      expect(m.duration, closeTo(128 / 25, 1e-9));
    });
  });

  group('against the worker', () {
    setUpAll(() async => WorkerHarness.ensureReady());

    String res(String name) =>
        '${WorkerHarness.repoRoot}/Tests/TestResources/$name';

    test('every field the app reads is one the worker writes', () async {
      final m = await WorkerHarness.sourceModel(res('pal-dvbt-fieldcoded-25i.ts'));
      final video = m.toJson()['video'] as Map<String, dynamic>;
      for (final key in [
        'width', 'height', 'codec', 'codecTagString', 'pixelFormat', 'sar',
        'fieldOrder', 'rFrameRate', 'frameRate', 'frameCount',
        'videoStartOffset', 'decoderDelayFrames', 'seekPlan', 'sourceGrid',
        'pulldownRate', 'colorMatrix', 'colorPrimaries', 'colorTransfer',
        'colorRange', 'dolbyVision',
      ]) {
        expect(video.containsKey(key), isTrue, reason: 'video.$key');
      }
      for (final key in ['schema', 'identity', 'formatName', 'duration',
          'audioStreams', 'continuity']) {
        expect(m.toJson().containsKey(key), isTrue, reason: key);
      }
      // The DVB-T clip (issue #13, #168, #169): the picture rate, not the
      // field rate; the first picture 1.2 s after the sound; a seek plan.
      expect(m.frameRate, 25);
      expect(m.frameCount, 128);
      expect(m.videoStartOffset, closeTo(1.202, 0.001));
      expect(m.seekPlan, isNotNull);
      expect(m.sourceGrid!.rateNum, 25);
      expect(m.sar, '16:11');
      expect(m.audioStreams.single.codec, 'mp2');
      expect(m.continuity!.applies, isTrue);
      expect(m.continuity!.needsCopy, isFalse);
      expect(m.path, res('pal-dvbt-fieldcoded-25i.ts'));
    });

    test('a delayed AVI and a stored count', () async {
      final m = await WorkerHarness.sourceModel(res('avi_h264_bframes.avi'));
      expect(m.decoderDelayFrames, 2);
      expect(m.frameCount, 90);
      expect(m.sourceGrid, isNull, reason: 'packets without timestamps');
      expect(m.continuity!.applies, isFalse);
    });

    test('the null frames of an AVI are counted (79, not the 75 decoded)', () async {
      final m = await WorkerHarness.sourceModel(res('interlaced_test.avi'));
      expect(m.frameCount, 79);
    });

    test('a reset is reported for the app to join', () async {
      final m = await WorkerHarness.sourceModel(res('seek_reset_dvd_pal.mpg'));
      expect(m.continuity!.needsCopy, isTrue);
    });

    test('a file that is not a video is not a model', () async {
      final f = File('${Directory.systemTemp.path}/vb_not_a_video.txt')
        ..writeAsStringSync('hello');
      try {
        expect(() => WorkerHarness.sourceModel(f.path), throwsException);
      } finally {
        f.deleteSync();
      }
    });
  });
}
