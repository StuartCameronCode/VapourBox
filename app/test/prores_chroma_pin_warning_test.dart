// The UI half of the ProRes chroma pin (issue #81).
//
// A ProRes profile stores a fixed chroma layout, and ffmpeg's format
// negotiation does not know that — `prores_ks -profile:v 4` picks yuv422p10le
// from a 4:2:0 source exactly as `-profile:v 2` does. The worker therefore pins
// the format from the profile (`VideoCodec::forced_pix_fmt`), which means the
// user's output colour format choice can be overridden in either direction.
// This warning says so before the job runs.
//
// **It is a second implementation of the worker's decision.** If the two
// disagree the interface promises one thing and the encode does another, which
// is worse than either being wrong alone. The table below is pinned to
// `prores_profile_decides_the_chroma` and `prores_pin_matches_the_profile_it_claims`
// in worker/src/models/video_job.rs. Change one, change both.
//
// Run with: flutter test test/prores_chroma_pin_warning_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/utils/pixel_format.dart';

void main() {
  String? warn({
    required VideoCodec codec,
    ChromaSubsampling chroma = ChromaSubsampling.original,
    String? pixelFormat,
  }) =>
      proresChromaPinWarning(
        codec: codec,
        chromaSubsampling: chroma,
        pixelFormat: pixelFormat,
      );

  /// The 4:2:2 profiles, and the 4:4:4 ones, exactly as the worker splits them
  /// (profile >= 4 stores 4:4:4).
  const c422Profiles = [
    VideoCodec.proresProxy,
    VideoCodec.proresLT,
    VideoCodec.prores422,
    VideoCodec.proresHQ,
  ];
  const c444Profiles = [
    VideoCodec.prores4444,
    VideoCodec.prores4444Xq,
  ];

  group('which profiles store what', () {
    test('matches the worker profile split, with no profile left out', () {
      // Guards against a ProRes profile being added to the enum and silently
      // treated as 4:2:2 by this file while the worker pins it to 4:4:4.
      final all = VideoCodec.values.where((c) => c.isProRes).toList();
      expect(
        all.toSet(),
        {...c422Profiles, ...c444Profiles},
        reason: 'a ProRes profile exists that this test does not classify; '
            'check it against forced_pix_fmt in the worker',
      );
    });
  });

  group('4:4:4 selected', () {
    test('warns on every 4:2:2 profile, and says it is resampled down', () {
      for (final codec in c422Profiles) {
        final message =
            warn(codec: codec, chroma: ChromaSubsampling.yuv444p10);
        expect(message, isNotNull, reason: codec.displayName);
        expect(message, contains('4:2:2'));
        expect(message, contains('ProRes 4444'),
            reason: 'the message must name the way out');
      }
    });

    test('is silent on the 4:4:4 profiles, which store exactly that', () {
      for (final codec in c444Profiles) {
        expect(warn(codec: codec, chroma: ChromaSubsampling.yuv444p10), isNull,
            reason: '${codec.displayName} stores 4:4:4 already');
      }
    });
  });

  group('narrower than 4:4:4 selected with a 4:4:4 profile', () {
    test('warns that the file grows without gaining detail', () {
      for (final codec in c444Profiles) {
        for (final chroma in [
          ChromaSubsampling.yuv420,
          ChromaSubsampling.yuv420p10,
          ChromaSubsampling.yuv422,
          ChromaSubsampling.yuv422p10,
        ]) {
          final message = warn(codec: codec, chroma: chroma);
          expect(message, isNotNull,
              reason: '${codec.displayName} + ${chroma.label}');
          expect(message, contains('4:4:4'));
          // Padding up costs size, not detail, and the message has to say so —
          // otherwise it reads as a quality warning and pushes people off a
          // profile that is doing exactly what they asked.
          expect(message, contains('Nothing is lost'));
          expect(message, contains('larger'));
        }
      }
    });
  });

  group('agreement is silent', () {
    test('4:2:2 selected on a 4:2:2 profile says nothing', () {
      for (final codec in c422Profiles) {
        for (final chroma in [
          ChromaSubsampling.yuv422,
          ChromaSubsampling.yuv422p10,
        ]) {
          expect(warn(codec: codec, chroma: chroma), isNull,
              reason: '${codec.displayName} + ${chroma.label}');
        }
      }
    });

    test('4:2:0 into a 4:2:2 profile stays quiet', () {
      // True that it is padded up, but it is the ordinary case for every
      // capture this app exists to process, and a banner that is always there
      // is wallpaper.
      for (final codec in c422Profiles) {
        expect(warn(codec: codec, chroma: ChromaSubsampling.yuv420), isNull);
      }
    });

    test('never fires for a non-ProRes codec', () {
      for (final codec in VideoCodec.values.where((c) => !c.isProRes)) {
        for (final chroma in ChromaSubsampling.values) {
          expect(
            warn(codec: codec, chroma: chroma, pixelFormat: 'yuv420p'),
            isNull,
            reason: '${codec.displayName} is not ProRes',
          );
        }
      }
    });
  });

  group('"Match source"', () {
    test('says nothing until a file is loaded', () {
      for (final codec in VideoCodec.values.where((c) => c.isProRes)) {
        expect(warn(codec: codec), isNull,
            reason: 'no source format is known yet');
      }
    });

    test('reads the layout from the source format', () {
      // A 4:4:4 source into a 4:2:2 profile is the real loss case.
      expect(
        warn(codec: VideoCodec.proresHQ, pixelFormat: 'yuv444p10le'),
        contains('4:2:2'),
      );
      // A 4:2:0 source into 4444 is the padding case.
      expect(
        warn(codec: VideoCodec.prores4444, pixelFormat: 'yuv420p'),
        contains('4:4:4'),
      );
      // And a source that already matches is silent.
      expect(
        warn(codec: VideoCodec.proresHQ, pixelFormat: 'yuv422p10le'),
        isNull,
      );
      expect(
        warn(codec: VideoCodec.prores4444, pixelFormat: 'yuv444p10le'),
        isNull,
      );
    });
  });
}
