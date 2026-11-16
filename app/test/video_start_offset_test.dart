// A source whose video starts after its audio (a DVB-T capture): frame N
// counts from the video's first picture, so every seek of the source adds the
// video's start offset. These pin the app's half to the worker's
// (`seek_time`; the offset itself comes from the worker's source model); the heavy
// integration_video_start_offset_test checks the pictures and the sync.
// See docs/reports/2026-11-video-start-offset.
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/audio_restoration_parameters.dart';
import 'package:vapourbox/models/pass_relevance.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/video_job.dart' show ContainerFormat;
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

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
  // Where the first picture sits, and the frame count with its leading
  // pictures and an untimed last picture (task #26), are the worker's since
  // task #50 (`source_model.rs`, tested with video_start_probe_dvbt.json and
  // tail_frames_probe_dvd_pal.json).

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

    test('no suggestion into AVI, which already starts the sound with the picture (task #30)', () {
      for (final c in ContainerFormat.values) {
        final r = relevanceFor(PassType.audioRestoration, _info(1.32), container: c);
        expect(r.isRecommended, c != ContainerFormat.avi, reason: c.name);
      }
    });

    test('only AVI cannot store where a stream starts (twin of the worker)', () {
      expect([for (final c in ContainerFormat.values) if (!c.storesStreamStart) c],
          [ContainerFormat.avi]);
    });

    test('the panel notice: any gap, and never for none', () {
      expect(videoStartNotice(0), isNull);
      expect(videoStartNotice(0.021), contains('0.02 s'));
      final text = videoStartNotice(1.202)!;
      expect(text, contains('1.20 s'));
      expect(text, contains('Start the sound with the picture'));
      // MKV, MP4 and MOV keep today's wording.
      for (final c in [ContainerFormat.mkv, ContainerFormat.mp4, ContainerFormat.mov]) {
        expect(videoStartNotice(1.202, container: c), text);
      }
      // AVI says the gap is left out, and that the step has nothing to do.
      final avi = videoStartNotice(1.202, container: ContainerFormat.avi)!;
      expect(avi, contains("AVI can't store a picture that starts after its sound"));
      expect(avi, contains('leaves those 1.20 s out'));
      expect(avi, isNot(contains('Start the sound with the picture')));
      expect(videoStartNotice(0, container: ContainerFormat.avi), isNull);
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
