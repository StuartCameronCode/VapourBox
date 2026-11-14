// A source whose video starts after its audio (a DVB-T capture): frame N
// counts from the video's first picture, so every seek of the source adds the
// video's start offset. These pin the app's half to the worker's
// (`source_decode::video_start_from_probe`, `seek_time`); the heavy
// integration_video_start_offset_test checks the pictures and the sync.
// See docs/reports/2026-11-video-start-offset.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/audio_restoration_parameters.dart';
import 'package:vapourbox/models/pass_relevance.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

Map<String, dynamic> _dvbtProbe() => jsonDecode(
        File('../Tests/TestResources/video_start_probe_dvbt.json').readAsStringSync())
    as Map<String, dynamic>;

VideoInfo _info(double offset) => VideoInfo(
      width: 720,
      height: 576,
      frameRate: 25,
      duration: 6.3,
      frameCount: 128,
      codec: 'h264',
      pixelFormat: 'yuv420p',
      hasAudio: true,
      videoStartOffset: offset,
    );

void main() {
  group('the offset (twin of source_decode::video_start_from_probe)', () {
    test('the DVB-T clip: the first picture, not the first packet', () {
      // The I picture (the stream's start_time) is at 2.722 s, three leading
      // B pictures are shown from 2.602 s, the container (the audio) starts
      // at 1.400 s. The worker's test reads the same file and asserts the
      // same 1.202022.
      final start = FieldOrderDetector.videoStartFromProbe(_dvbtProbe());
      expect(start.offset, closeTo(1.202022, 1e-6));
      expect(start.leading, closeTo(0.12, 1e-6));
    });

    test('packets without a PTS fall back to the stream start (MPEG-2 in AVI)', () {
      final start = FieldOrderDetector.videoStartFromProbe({
        'packets': [
          {'pts_time': 'N/A'},
          <String, dynamic>{},
          {'pts_time': '0.066733'},
        ],
        'streams': [
          {'start_time': '0.000000'}
        ],
        'format': {'start_time': '0.000000'},
      });
      expect(start.offset, 0);
      expect(start.leading, 0);
    });

    test('streams that start together, or missing data, mean no gap', () {
      expect(FieldOrderDetector.videoStartFromProbe({}).offset, 0);
      expect(
          FieldOrderDetector.videoStartFromProbe({
            'packets': [
              {'pts_time': '0.000000'}
            ],
            'format': {'start_time': '0.000000'},
          }).offset,
          0);
    });

    test('the app asks ffprobe exactly what the worker asks', () {
      // VIDEO_START_PROBE_ARGS in source_decode.rs, read from the source.
      final rust = File('../worker/src/source_decode.rs').readAsStringSync();
      final block = RegExp(r'VIDEO_START_PROBE_ARGS: \[&str; \d+\] = \[([^\]]*)\]')
          .firstMatch(rust)!
          .group(1)!;
      final args = RegExp(r'"([^"]*)"').allMatches(block).map((m) => m.group(1)).toList();
      expect(FieldOrderDetector.videoStartProbeArgs, args);
    });
  });

  group('frame count from duration', () {
    test("the video's own duration plus its leading pictures", () {
      // DVB-T: 5.0 s stream + 0.12 s of leading B pictures = 128, the length
      // of the worker's untrimmed decode. The container's 6.322 s gave 158.
      expect(
          FieldOrderDetector.frameCountFromDuration(
            streamDuration: 5.0,
            containerDuration: 6.322022,
            start: const VideoStart(offset: 1.202022, leading: 0.12),
            frameRate: 25,
          ),
          128);
    });

    test('no stream duration (MKV): the container less the offset', () {
      expect(
          FieldOrderDetector.frameCountFromDuration(
            streamDuration: null,
            containerDuration: 5.0,
            start: const VideoStart(offset: 1.0, leading: 0),
            frameRate: 25,
          ),
          100);
      // Streams that start together: the container's duration, as before.
      expect(
          FieldOrderDetector.frameCountFromDuration(
            streamDuration: null,
            containerDuration: 4.0,
            start: VideoStart.none,
            frameRate: 25,
          ),
          100);
    });
  });

  group('before frame and thumbnails (twin of source_decode::seek_time)', () {
    List<String> before(int frame, double offset) => PreviewGenerator.beforeFrameArgs(
        videoPath: 'in.ts',
        frameIndex: frame,
        frameRate: 25,
        videoStartOffset: offset,
        outputPath: 'o.jpg');

    test('frame 0 never seeks, like the worker', () {
      expect(before(0, 0), isNot(contains('-ss')));
      expect(before(0, 1.202022), isNot(contains('-ss')));
      expect(before(-3, 1.0), isNot(contains('-ss')));
    });

    test('every other seek adds the offset; none changes nothing', () {
      expect(before(40, 0).sublist(1, 3), ['-ss', (39.5 / 25).toStringAsFixed(6)]);
      expect(before(40, 1.202022).sublist(1, 3),
          ['-ss', (39.5 / 25 + 1.202022).toStringAsFixed(6)]);
    });

    test('a thumbnail at time t on the video timeline seeks to t + offset', () {
      final args = PreviewGenerator.thumbnailArgs(
          videoPath: 'in.ts', time: 2.0, videoStartOffset: 1.25, outputPath: 't.jpg');
      expect(args.sublist(1, 3), ['-ss', '3.250']);
      final plain =
          PreviewGenerator.thumbnailArgs(videoPath: 'in.ts', time: 2.0, outputPath: 't.jpg');
      expect(plain.sublist(1, 3), ['-ss', '2.000']);
    });
  });

  group('the suggestion', () {
    test('Audio Restoration is suggested for a broadcast-sized gap only', () {
      final r = relevanceFor(PassType.audioRestoration, _info(1.32));
      expect(r.isRecommended, isTrue);
      expect(r.reason, contains('1.32 s'));
      // ffmpeg's TS muxer leaves ~20 ms between streams: no badge.
      expect(relevanceFor(PassType.audioRestoration, _info(0.021)).level,
          PassRelevance.neutral);
      expect(relevanceFor(PassType.audioRestoration, _info(0)).level, PassRelevance.neutral);
      expect(relevanceFor(PassType.audioRestoration, null).level, PassRelevance.neutral);
    });

    test('the panel notice: any gap, and never for none', () {
      expect(videoStartNotice(0), isNull);
      expect(videoStartNotice(0.021), contains('0.02 s'));
      final text = videoStartNotice(1.202)!;
      expect(text, contains('1.20 s'));
      expect(text, contains('Start the sound with the picture'));
    });

    test('the step counts as a step, and survives a round trip', () {
      const p = AudioRestorationParameters(enabled: true, startWithPicture: true);
      expect(p.hasEffect, isTrue);
      expect(p.activeSteps, ['Start with picture']);
      final back = AudioRestorationParameters.fromJson(p.toJson());
      expect(back.startWithPicture, isTrue);
      expect(p.copyWith(limiter: true).startWithPicture, isTrue);
      expect(const AudioRestorationParameters().startWithPicture, isFalse);
    });
  });
}
