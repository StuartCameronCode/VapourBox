// The UI half of the ProRes chroma pin (issue #81).
//
// A ProRes profile stores one format: 10-bit 4:2:2 (Proxy..HQ) or 10-bit 4:4:4
// (4444, 4444 XQ). The worker converts to exactly that in the script, whatever
// Color Format is selected (`EncodingSettings::effective_chroma_subsampling`),
// so an interlaced 4:2:0 source keeps each field's chroma. The selection is
// therefore ignored, and what is lost or padded depends on the source alone.
// This warning says so before the job runs.
//
// **It is a second implementation of the worker's decision.** If the two
// disagree the interface promises one thing and the encode does another, which
// is worse than either being wrong alone. The table below is pinned row for
// row to `prores_converts_to_its_profile_format_whatever_is_selected` in
// worker/src/models/video_job.rs. Change one, change both.
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
      for (final c in c422Profiles) {
        expect(c.fixedOutputFormat, ChromaSubsampling.yuv422p10, reason: c.name);
      }
      for (final c in c444Profiles) {
        expect(c.fixedOutputFormat, ChromaSubsampling.yuv444p10, reason: c.name);
      }
    });

    test('profile numbers match the wire value', () {
      expect(VideoCodec.proresProxy.proresProfile, 0);
      expect(VideoCodec.proresHQ.proresProfile, 3);
      expect(VideoCodec.prores4444Xq.proresProfile, 5);
      for (final c in VideoCodec.values.where((c) => !c.isProRes)) {
        expect(c.proresProfile, isNull, reason: c.name);
      }
    });
  });

  group('the worker table', () {
    // Same sources as FIXED_FORMAT_SOURCES in video_job.rs. yuv444p12le is what
    // the decoder reports for every ProRes 4444 source.
    const sources = [
      'yuv420p',
      'yuv411p',
      'yuv422p',
      'yuv422p10le',
      'yuv444p10le',
      'yuv444p12le',
      'yuv422p16le',
    ];

    /// (selection ignored, source chroma lost, padded up to 4:4:4) — the same
    /// rows as the worker's `expected`.
    (bool, bool, bool) expected(
        bool stores444, ChromaSubsampling cs, String src) {
      final src444 = src.startsWith('yuv444');
      if (!stores444) {
        switch (cs) {
          case ChromaSubsampling.original:
          case ChromaSubsampling.yuv422p10:
            return (false, src444, false);
          case ChromaSubsampling.yuv420:
          case ChromaSubsampling.yuv420p10:
          case ChromaSubsampling.yuv422:
          case ChromaSubsampling.yuv444p10:
            return (true, src444, false);
        }
      }
      switch (cs) {
        case ChromaSubsampling.original:
        case ChromaSubsampling.yuv444p10:
          return (false, false, !src444);
        case ChromaSubsampling.yuv420:
        case ChromaSubsampling.yuv420p10:
        case ChromaSubsampling.yuv422:
        case ChromaSubsampling.yuv422p10:
          return (true, false, !src444);
      }
    }

    test('every profile, selection and source: the effective format', () {
      for (final codec in [...c422Profiles, ...c444Profiles]) {
        for (final cs in ChromaSubsampling.values) {
          expect(
            EncodingSettings(codec: codec, chromaSubsampling: cs)
                .effectiveChromaSubsampling,
            codec.fixedOutputFormat,
            reason: '${codec.displayName} ${cs.value}',
          );
        }
      }
    });

    test('speaks exactly where the choice is ignored, chroma is lost or padded',
        () {
      for (final codec in [...c422Profiles, ...c444Profiles]) {
        final stores444 = c444Profiles.contains(codec);
        for (final cs in ChromaSubsampling.values) {
          for (final src in sources) {
            final (ignored, lost, padded) = expected(stores444, cs, src);
            final message = warn(codec: codec, chroma: cs, pixelFormat: src);
            final ctx = '${codec.displayName} ${cs.value} from $src: $message';
            expect(message != null, ignored || lost || padded, reason: ctx);
            if (message == null) continue;
            expect(message, contains(stores444 ? '4:4:4' : '4:2:2'), reason: ctx);
            expect(message.contains('ignored'), ignored, reason: ctx);
            expect(message.contains('resampled down'), lost, reason: ctx);
            // Padding up costs size, not detail, and the message has to say
            // so — otherwise it reads as a quality warning and pushes people
            // off a profile that is doing exactly what they asked.
            expect(message.contains('Nothing is lost'), padded, reason: ctx);
            expect(message.contains('larger'), padded, reason: ctx);
            if (lost) {
              expect(message, contains('ProRes 4444'),
                  reason: 'the message must name the way out: $ctx');
            }
          }
        }
      }
    });
  });

  group('4:4:4 selected on a 4:2:2 profile', () {
    test('names ProRes 4444 without claiming a loss the source does not have',
        () {
      for (final codec in c422Profiles) {
        final message = warn(
            codec: codec,
            chroma: ChromaSubsampling.yuv444p10,
            pixelFormat: 'yuv420p');
        expect(message, contains('ignored'));
        expect(message, contains('ProRes 4444'));
        expect(message, isNot(contains('resampled down')),
            reason: 'a 4:2:0 source loses nothing to a 4:2:2 profile');
      }
    });
  });

  group('silences', () {
    test('4:2:0 into a 4:2:2 profile with Match source stays quiet', () {
      // True that it is padded up, but it is the ordinary case for every
      // capture this app exists to process, and a banner that is always there
      // is wallpaper.
      for (final codec in c422Profiles) {
        expect(warn(codec: codec, pixelFormat: 'yuv420p'), isNull);
      }
    });

    test('says nothing until a file is loaded, with Match source', () {
      for (final codec in VideoCodec.values.where((c) => c.isProRes)) {
        expect(warn(codec: codec), isNull,
            reason: 'no source format is known yet');
      }
    });

    test('before a file is loaded, only "ignored" can be said', () {
      final message =
          warn(codec: VideoCodec.prores4444, chroma: ChromaSubsampling.yuv420);
      expect(message, contains('ignored'));
      expect(message, isNot(contains('Nothing is lost')));
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
}
