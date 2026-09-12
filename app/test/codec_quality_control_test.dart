// Guards the pairing between `VideoCodec.hasQualityControl` and what the worker
// actually reads (issue #81).
//
// The bug being pinned: ProRes is not `isLossless`, so the settings dialog
// rendered the CRF slider for it, labelled "High (CRF 18)". The worker's
// `build_encoder_quality_args` takes the `prores_profile()` branch and returns
// without ever reading `EncodingSettings.quality` — so the slider moved and the
// output did not change.
//
// These tests are driven by `VideoCodec.values` rather than a hand-written
// list, because a hand-written list only covers the codecs someone thought to
// add, which is never the broken one. That is exactly how this shipped.
//
// Run with: flutter test test/codec_quality_control_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';

void main() {
  group('hasQualityControl', () {
    test('is false for every ProRes profile', () {
      final prores = VideoCodec.values.where((c) => c.isProRes).toList();
      expect(prores, isNotEmpty, reason: 'sanity: ProRes codecs exist');

      for (final codec in prores) {
        expect(codec.hasQualityControl, isFalse,
            reason: '${codec.displayName} takes its quality from -profile:v; '
                'the worker never reads EncodingSettings.quality for it');
      }
    });

    test('is false for every lossless codec', () {
      final lossless = VideoCodec.values.where((c) => c.isLossless).toList();
      expect(lossless, isNotEmpty, reason: 'sanity: lossless codecs exist');

      for (final codec in lossless) {
        expect(codec.hasQualityControl, isFalse,
            reason: '${codec.displayName} has no quality to set');
      }
    });

    test('is true for every other codec', () {
      final tunable = VideoCodec.values
          .where((c) => !c.isProRes && !c.isLossless)
          .toList();
      expect(tunable, isNotEmpty, reason: 'sanity: tunable codecs exist');

      for (final codec in tunable) {
        expect(codec.hasQualityControl, isTrue,
            reason: '${codec.displayName} is CRF/CQ/QP-controlled, so hiding '
                'its quality control would remove a working setting');
      }
    });

    test('every codec is decided one way or the other', () {
      // A codec that is somehow both ProRes and lossless, or whose getter
      // disagrees with the two predicates, would render two Quality sections
      // or none.
      for (final codec in VideoCodec.values) {
        expect(codec.isProRes && codec.isLossless, isFalse,
            reason: '${codec.displayName} cannot be both');
        expect(codec.hasQualityControl, !(codec.isProRes || codec.isLossless),
            reason: '${codec.displayName}: getter disagrees with its parts');
      }
    });
  });

  group('qualityDescription', () {
    test('never quotes a CRF number for a codec that ignores it', () {
      for (final codec in VideoCodec.values.where((c) => !c.hasQualityControl)) {
        // Deliberately a value that would be conspicuous if it leaked through.
        final settings = EncodingSettings(codec: codec, quality: 37);
        final description = settings.qualityDescription;

        expect(description, isNot(contains('37')),
            reason: '${codec.displayName} ignores quality, so naming the '
                'number tells the user it matters');
        expect(description.toUpperCase(), isNot(contains('CRF')),
            reason: '${codec.displayName} is not CRF-controlled');
        expect(description.toUpperCase(), isNot(contains('CQ ')),
            reason: '${codec.displayName} is not CQ-controlled');
      }
    });

    test('names the profile for ProRes', () {
      for (final codec in VideoCodec.values.where((c) => c.isProRes)) {
        final settings = EncodingSettings(codec: codec);
        expect(settings.qualityDescription, contains(codec.displayName),
            reason: 'the user needs to know which profile fixed the quality');
      }
    });

    test('still describes the number for codecs that use it', () {
      for (final codec in VideoCodec.values.where((c) => c.hasQualityControl)) {
        final settings = EncodingSettings(codec: codec, quality: 37);
        expect(settings.qualityDescription, contains('37'),
            reason: '${codec.displayName} reads quality, so the slider label '
                'must keep reporting it');
      }
    });
  });
}
