// The three advanced ProRes encoder options (issue #81), on the model side.
//
// `parameter_copy_with_test.dart` now scans this model's copyWith by field
// name, which catches a dropped field of any type. It cannot check the one
// thing these options additionally need: that they can be turned back *off*.
//
// Every edit in the settings dialog goes through
// `updateEncodingSettings(settings.copyWith(...))`, and `x ?? this.x` can only
// ever set a nullable field, never clear it. Without an explicit clear flag,
// unticking the override in the UI leaves the value in place and it is silently
// applied to every later ProRes encode. `videoBitrateKbps` has exactly that
// defect today and `_buildCodecRadio` works around it by recomputing the value
// on every codec change.
//
// Run with: flutter test test/prores_options_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';

void main() {
  group('defaults', () {
    test('are off, so an existing job encodes exactly as it did', () {
      const settings = EncodingSettings();
      expect(settings.proresVendorApl0, isFalse);
      expect(settings.proresBitsPerMb, isNull);
      expect(settings.proresQuantMat, isNull);
    });
  });

  group('copyWith', () {
    const set = EncodingSettings(
      codec: VideoCodec.proresHQ,
      proresVendorApl0: true,
      proresBitsPerMb: 8000,
      proresQuantMat: ProResQuantMat.hq,
    );

    test('carries the three options through an unrelated edit', () {
      // The realistic failure: the user sets these, then changes the audio
      // mode, and the ProRes options quietly revert.
      final after = set.copyWith(audioMode: AudioMode.none);
      expect(after.proresVendorApl0, isTrue);
      expect(after.proresBitsPerMb, 8000);
      expect(after.proresQuantMat, ProResQuantMat.hq);
    });

    test('can clear the two nullable options', () {
      expect(set.copyWith(clearProresBitsPerMb: true).proresBitsPerMb, isNull);
      expect(set.copyWith(clearProresQuantMat: true).proresQuantMat, isNull);
    });

    test('clearing one leaves the others alone', () {
      final after = set.copyWith(clearProresBitsPerMb: true);
      expect(after.proresBitsPerMb, isNull);
      expect(after.proresQuantMat, ProResQuantMat.hq,
          reason: 'clearing one override must not disturb another');
      expect(after.proresVendorApl0, isTrue);
    });

    test('the vendor flag can be turned back off', () {
      // A bool needs no clear flag, but `?? this.x` makes `false` indistinguish
      // -able from "not supplied" if it is ever made nullable. Pinned so that
      // change cannot pass silently.
      expect(set.copyWith(proresVendorApl0: false).proresVendorApl0, isFalse);
    });
  });

  group('round trip', () {
    test('survives JSON, so a saved preset keeps them', () {
      const original = EncodingSettings(
        codec: VideoCodec.prores4444,
        proresVendorApl0: true,
        proresBitsPerMb: 4096,
        proresQuantMat: ProResQuantMat.proxy,
      );

      final restored = EncodingSettings.fromJson(original.toJson());
      expect(restored.proresVendorApl0, isTrue);
      expect(restored.proresBitsPerMb, 4096);
      expect(restored.proresQuantMat, ProResQuantMat.proxy);
      expect(restored.codec, VideoCodec.prores4444);
    });

    test('an older preset without the fields still loads', () {
      // Every one is #[serde(default)] on the worker side and nullable or
      // defaulted here, so a preset saved before they existed must decode.
      final json = const EncodingSettings(codec: VideoCodec.proresHQ).toJson()
        ..remove('proresVendorApl0')
        ..remove('proresBitsPerMb')
        ..remove('proresQuantMat');

      final restored = EncodingSettings.fromJson(json);
      expect(restored.proresVendorApl0, isFalse);
      expect(restored.proresBitsPerMb, isNull);
      expect(restored.proresQuantMat, isNull);
    });
  });

  group('ProResQuantMat', () {
    test('values match the worker enum serde names', () {
      // ProResQuantMat in worker/src/models/video_job.rs uses
      // rename_all = "lowercase", so these are the wire format. ffmpeg rejects
      // an unknown value outright and kills the encode, so a mismatch here is a
      // failed job on an option the user cannot see.
      expect(ProResQuantMat.auto.value, 'auto');
      expect(ProResQuantMat.proxy.value, 'proxy');
      expect(ProResQuantMat.lt.value, 'lt');
      expect(ProResQuantMat.standard.value, 'standard');
      expect(ProResQuantMat.hq.value, 'hq');
      expect(ProResQuantMat.values.length, 5,
          reason: 'a matrix added here must also exist in the Rust enum, and '
              'must be a name prores_ks actually accepts');
    });

    test('every value has a label distinct from its wire name', () {
      for (final m in ProResQuantMat.values) {
        expect(m.label, isNotEmpty);
      }
      final labels = ProResQuantMat.values.map((m) => m.label).toSet();
      expect(labels.length, ProResQuantMat.values.length,
          reason: 'two matrices sharing a label are indistinguishable in the '
              'dropdown');
    });
  });
}
