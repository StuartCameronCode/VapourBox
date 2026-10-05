import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/encoding_settings.dart';

// The frame cache override (issue #107). Off by default: the worker only
// writes `core.max_cache_size` into the script when this is set, and a fixed
// 1 GB cap is what made HD deinterlacing run at ~1 fps.

void main() {
  test('is off by default, leaving the cache to VapourSynth', () {
    expect(const EncodingSettings().maxCacheSizeMb, isNull);
    expect(const EncodingSettings().toJson()['maxCacheSizeMb'], isNull);
  });

  group('copyWith', () {
    const set = EncodingSettings(maxCacheSizeMb: 6000);

    test('carries the override through an unrelated edit', () {
      expect(set.copyWith(audioMode: AudioMode.none).maxCacheSizeMb, 6000);
    });

    test('can clear it, so unticking the box really turns it off', () {
      expect(set.copyWith(clearMaxCacheSizeMb: true).maxCacheSizeMb, isNull);
    });
  });

  group('round trip', () {
    test('survives JSON under the name the worker reads', () {
      final json = const EncodingSettings(maxCacheSizeMb: 6000).toJson();
      expect(json['maxCacheSizeMb'], 6000);
      expect(EncodingSettings.fromJson(json).maxCacheSizeMb, 6000);
    });

    test('an older preset without the field still loads', () {
      final json = const EncodingSettings().toJson()..remove('maxCacheSizeMb');
      expect(EncodingSettings.fromJson(json).maxCacheSizeMb, isNull);
    });
  });
}
