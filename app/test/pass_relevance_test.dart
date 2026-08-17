// Tests for which passes the app suggests for a given source.
//
// The property that matters most here is restraint: badging most of the list
// would make the badge meaningless, so these tests assert the *number* of
// suggestions as well as which ones, and that every pass detection can't speak
// to stays quiet.
//
// Run with: flutter test test/pass_relevance_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/pass_relevance.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/services/field_order_detector.dart';

VideoInfo source({
  int width = 720,
  int height = 576,
  double frameRate = 25.0,
  String codec = 'mpeg2video',
  String pixelFormat = 'yuv420p',
  ScanType scanType = ScanType.interlaced,
  String? sar,
}) =>
    VideoInfo(
      width: width,
      height: height,
      frameRate: frameRate,
      duration: 60,
      frameCount: 1500,
      codec: codec,
      pixelFormat: pixelFormat,
      scanType: scanType,
      hasAudio: true,
      sar: sar,
    );

Set<PassType> suggestedFor(VideoInfo? info) => PassType.values
    .where((p) => relevanceFor(p, info).isRecommended)
    .toSet();

Set<PassType> notApplicableFor(VideoInfo? info) => PassType.values
    .where((p) => relevanceFor(p, info).isNotApplicable)
    .toSet();

void main() {
  group('nothing loaded', () {
    test('says nothing at all', () {
      for (final pass in PassType.values) {
        expect(relevanceFor(pass, null).level, PassRelevance.neutral);
        expect(relevanceFor(pass, null).reason, isNull);
      }
    });
  });

  group('deinterlace', () {
    test('suggested for every fielded scan type, naming it', () {
      for (final scan in [
        ScanType.interlaced,
        ScanType.telecine,
        ScanType.softTelecine,
      ]) {
        final result =
            relevanceFor(PassType.deinterlace, source(scanType: scan));
        expect(result.isRecommended, true, reason: '$scan should suggest it');
        expect(result.reason, contains(scan.displayName.toLowerCase()));
      }
    });

    test('not applicable for progressive', () {
      final result = relevanceFor(
          PassType.deinterlace, source(scanType: ScanType.progressive));
      expect(result.isNotApplicable, true);
      expect(result.reason, 'source is progressive');
    });

    test('silent when detection failed', () {
      // ScanType.unknown means ffprobe/idet could not decide. Claiming either
      // way would be worse than saying nothing.
      expect(
        relevanceFor(PassType.deinterlace, source(scanType: ScanType.unknown))
            .level,
        PassRelevance.neutral,
      );
    });
  });

  group('chroma fixes', () {
    test('suggested for an SD fielded source', () {
      expect(
        relevanceFor(PassType.chromaFixes,
                source(height: 576, scanType: ScanType.interlaced))
            .isRecommended,
        true,
      );
    });

    test('not applicable for progressive HD', () {
      expect(
        relevanceFor(PassType.chromaFixes,
                source(height: 1080, scanType: ScanType.progressive))
            .isNotApplicable,
        true,
      );
    });

    test('silent for SD progressive — could still be a tape transfer', () {
      expect(
        relevanceFor(PassType.chromaFixes,
                source(height: 480, scanType: ScanType.progressive))
            .level,
        PassRelevance.neutral,
      );
    });

    test('silent for interlaced HD — not composite', () {
      expect(
        relevanceFor(PassType.chromaFixes,
                source(height: 1080, scanType: ScanType.interlaced))
            .level,
        PassRelevance.neutral,
      );
    });
  });

  group('deblock', () {
    test('suggested for MPEG-2', () {
      expect(
        relevanceFor(PassType.deblock, source(codec: 'mpeg2video'))
            .isRecommended,
        true,
      );
    });

    test('silent for other codecs, since bitrate is invisible', () {
      for (final codec in ['h264', 'prores', 'dvvideo', 'hevc']) {
        expect(
          relevanceFor(PassType.deblock, source(codec: codec)).level,
          PassRelevance.neutral,
          reason: codec,
        );
      }
    });
  });

  group('crop / resize', () {
    test('suggested for an anamorphic source, quoting the SAR', () {
      final result =
          relevanceFor(PassType.cropResize, source(sar: '10:11'));
      expect(result.isRecommended, true);
      expect(result.reason, contains('10:11'));
    });

    test('silent for square pixels', () {
      expect(relevanceFor(PassType.cropResize, source(sar: null)).level,
          PassRelevance.neutral);
      expect(relevanceFor(PassType.cropResize, source(sar: '')).level,
          PassRelevance.neutral);
    });
  });

  group('restraint', () {
    // The badge is only worth having if it is rare. These bounds are the point
    // of the feature, not incidental.
    test('a PAL DVD capture suggests at most four passes', () {
      final suggested = suggestedFor(source(
        height: 576,
        codec: 'mpeg2video',
        scanType: ScanType.interlaced,
        sar: '16:15',
      ));
      expect(suggested.length, lessThanOrEqualTo(4));
      expect(
        suggested,
        {
          PassType.deinterlace,
          PassType.chromaFixes,
          PassType.deblock,
          PassType.cropResize,
        },
      );
    });

    test('a modern progressive camera file suggests nothing', () {
      final info = source(
        width: 1920,
        height: 1080,
        codec: 'h264',
        frameRate: 25,
        scanType: ScanType.progressive,
      );
      expect(suggestedFor(info), isEmpty);
      // And it actively rules two out.
      expect(notApplicableFor(info),
          {PassType.deinterlace, PassType.chromaFixes});
    });

    test('passes detection cannot judge are always neutral', () {
      // Dirt, scratches, grain, halos, banding and colour casts need eyes on
      // the picture. If one of these ever starts making claims, the badge has
      // stopped meaning anything.
      const invisible = [
        PassType.descratch,
        PassType.spotless,
        PassType.noiseReduction,
        PassType.chromaDenoise,
        PassType.dehalo,
        PassType.deband,
        PassType.sharpen,
        PassType.colorCorrection,
        PassType.subtitles,
      ];

      for (final scan in ScanType.values) {
        for (final height in [480, 576, 720, 1080, 2160]) {
          for (final codec in ['mpeg2video', 'h264', 'prores']) {
            final info =
                source(height: height, codec: codec, scanType: scan, sar: '4:3');
            for (final pass in invisible) {
              expect(relevanceFor(pass, info).level, PassRelevance.neutral,
                  reason: '$pass claimed something for $scan/$height/$codec');
            }
          }
        }
      }
    });

    test('no pass is both suggested and not applicable', () {
      for (final scan in ScanType.values) {
        final info = source(scanType: scan);
        expect(suggestedFor(info).intersection(notApplicableFor(info)), isEmpty);
      }
    });
  });
}
