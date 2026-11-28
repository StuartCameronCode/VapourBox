// Output and encoding settings survive a restart (issue #264).
//
// They used to live only in MainViewModel's memory, so a chosen output
// folder, codec or container was back at its default on every launch.
// EncodingSettingsStore keeps them in shared_preferences; a "restart" here is
// resetForTesting() + initialize(), which reads storage again, and a new view
// model built from the store.
//
// Run with: flutter test test/encoding_settings_store_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_preset.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/encoding_settings_store.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

import 'fakes/fake_job_runner.dart';
import 'fakes/no_source_model_continuity.dart';

/// Settings with every field moved off its default.
EncodingSettings _changed() => const EncodingSettings(
      codec: VideoCodec.proresHQ,
      encoderPreset: 'slow',
      quality: 23,
      videoBitrateKbps: 12000,
      audioMode: AudioMode.convert,
      audioCodec: AudioCodec.flac,
      audioQuality: AudioQuality.veryHigh,
      chromaSubsampling: ChromaSubsampling.yuv422p10,
      proresVendorApl0: true,
      proresBitsPerMb: 4000,
      proresQuantMat: ProResQuantMat.hq,
      customFfmpegArgs: '-metadata title=x',
      customVapoursynth: 'clip = clip',
      maxCacheSizeMb: 2048,
      container: ContainerFormat.mov,
      outputDirectory: '/Volumes/Archive/out',
      filenamePattern: '{input_filename}_{date}',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = EncodingSettingsStore.instance;

  Future<void> restart() async {
    store.resetForTesting();
    await store.initialize();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store.resetForTesting();
  });

  group('EncodingSettingsStore', () {
    test('starts from the defaults when nothing is saved', () async {
      await store.initialize();
      expect(store.initial.toJson(), const EncodingSettings().toJson());
    });

    test('every field, custom code included, comes back after a restart',
        () async {
      await store.initialize();
      final settings = _changed();
      // Guard the fixture: each field really is off its default, or the
      // round trip would prove nothing about it.
      final defaults = const EncodingSettings().toJson();
      settings.toJson().forEach((key, value) {
        expect(value, isNot(defaults[key]), reason: '$key is at its default');
      });

      await store.save(settings);
      await restart();

      expect(store.initial.toJson(), settings.toJson());
      expect(store.initial.customFfmpegArgs, '-metadata title=x');
      expect(store.initial.customVapoursynth, 'clip = clip');
    });

    test('save leaves this session\'s starting point alone', () async {
      await store.initialize();
      await store.save(_changed());
      expect(store.initial.toJson(), const EncodingSettings().toJson());
    });

    for (final (name, raw) in [
      ('corrupt JSON', '{not json'),
      ('a JSON value that is not an object', '[1, 2]'),
      (
        'a codec this build does not know',
        jsonEncode({...const EncodingSettings().toJson(), 'codec': 'h267'})
      ),
    ]) {
      test('$name falls back to the defaults', () async {
        SharedPreferences.setMockInitialValues(
            {EncodingSettingsStore.prefsKey: raw});
        await store.initialize();
        expect(store.initial.toJson(), const EncodingSettings().toJson());
      });
    }
  });

  group('MainViewModel', () {
    MainViewModel newViewModel() => MainViewModel(
        runner: FakeJobRunner(),
        continuityService: const NoSourceModelContinuity());

    test('a change in Settings is there after a restart (issue #264)',
        () async {
      await store.initialize();
      final vm = newViewModel();
      vm.updateEncodingSettings(_changed());
      await pumpEventQueue();
      vm.dispose();

      await restart();
      final next = newViewModel();
      addTearDown(next.dispose);
      expect(next.encodingSettings.toJson(), _changed().toJson());
    });

    test('loading a preset with no folder keeps the chosen folder', () async {
      final saved = <EncodingSettings>[];
      final vm = MainViewModel(
        runner: FakeJobRunner(),
        continuityService: const NoSourceModelContinuity(),
        initialEncodingSettings:
            const EncodingSettings(outputDirectory: '/Volumes/Archive/out'),
        saveEncodingSettings: saved.add,
      );
      addTearDown(vm.dispose);

      final preset = ProcessingPreset.builtInBalanced();
      expect(preset.encodingSettings.outputDirectory, isNull);
      vm.loadPreset(preset);

      expect(vm.encodingSettings.outputDirectory, '/Volumes/Archive/out');
      expect(vm.encodingSettings.codec, preset.encodingSettings.codec);
      // What the preset applied is what the next launch starts from.
      expect(saved.last.toJson(), vm.encodingSettings.toJson());
    });

    test('a preset that names a folder still sets it', () async {
      final vm = MainViewModel(
        runner: FakeJobRunner(),
        continuityService: const NoSourceModelContinuity(),
        initialEncodingSettings:
            const EncodingSettings(outputDirectory: '/Volumes/Archive/out'),
        saveEncodingSettings: (_) {},
      );
      addTearDown(vm.dispose);

      vm.loadPreset(ProcessingPreset(
        name: 'Mine',
        pipeline: ProcessingPreset.builtInBalanced().pipeline,
        encodingSettings: const EncodingSettings(outputDirectory: '/elsewhere'),
      ));

      expect(vm.encodingSettings.outputDirectory, '/elsewhere');
    });
  });
}
