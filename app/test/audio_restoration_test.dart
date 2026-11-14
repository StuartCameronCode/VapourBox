// Audio restoration's model, converter and wiring — the parts that run without
// a worker. The generated arguments are checked against the worker itself in
// integration_audio_plan_test.dart, and the audio in
// integration_audio_restoration_test.dart (heavy).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/audio_restoration_parameters.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/progress_info.dart';

const _everything = AudioRestorationParameters(
  enabled: true,
  streamIndex: 1,
  channelFix: ChannelFix.rightOnly,
  offsetMs: -120,
  startWithPicture: true,
  driftCorrection: true,
  driftMaxPercent: 0.3,
  declip: true,
  declick: true,
  declickThreshold: 3.5,
  humRemoval: true,
  humFrequency: HumFrequency.hz60,
  rumbleFilter: true,
  rumbleCutoffHz: 60,
  denoise: true,
  denoiseStrength: 18,
  deepFilter: true,
  deepFilterAttenuation: 30,
  loudnessNormalize: true,
  loudnessTarget: -23,
  limiter: true,
  limiterCeilingDb: -2,
);

void main() {
  test('the JSON is what the worker reads', () {
    // The same names and values as the worker's json_names_match_the_app.
    final json = _everything.toJson();
    expect(json['channelFix'], 'rightOnly');
    expect(json['humFrequency'], '60');
    expect(json['offsetMs'], -120);
    expect(json['startWithPicture'], true);
    expect(json['deepFilterAttenuation'], 30);
    expect(json.keys.toSet(), {
      'enabled', 'streamIndex', 'channelFix', 'offsetMs', 'startWithPicture',
      'driftCorrection',
      'driftMaxPercent', 'declip', 'declick', 'declickThreshold', 'humRemoval',
      'humFrequency', 'rumbleFilter', 'rumbleCutoffHz', 'denoise',
      'denoiseStrength', 'deepFilter', 'deepFilterAttenuation',
      'loudnessNormalize', 'loudnessTarget', 'limiter', 'limiterCeilingDb',
    });
    for (final fix in ChannelFix.values) {
      final back = AudioRestorationParameters.fromJson(
          const AudioRestorationParameters(channelFix: ChannelFix.off)
              .copyWith(channelFix: fix)
              .toJson());
      expect(back.channelFix, fix);
    }
    // The pipeline carries it as "audio", which the worker's pipeline reads.
    final pipeline = const ProcessingPipeline(audio: _everything).toJson();
    expect((pipeline['audio'] as Map)['offsetMs'], -120);
    expect(ProcessingPipeline.fromJson(jsonDecode(jsonEncode(pipeline))).audio.toJson(),
        _everything.toJson());
  });

  test('the converter round-trips every field', () {
    final dynamic = ParameterConverter.fromAudioRestoration(_everything);
    expect(dynamic.filterId, 'audio_restoration');
    expect(ParameterConverter.toAudioRestoration(dynamic).toJson(), _everything.toJson());
    // And through a whole pipeline.
    final back = ParameterConverter.toPipeline(
        ParameterConverter.fromPipeline(const ProcessingPipeline(audio: _everything)));
    expect(back.audio.toJson(), _everything.toJson());
  });

  test('every converter value is a schema parameter with a valid value', () {
    final schema = FilterSchema.fromJson(jsonDecode(
            File('assets/filters/core/audio_restoration.json').readAsStringSync())
        as Map<String, dynamic>);
    final values = ParameterConverter.fromAudioRestoration(_everything).values;
    for (final entry in values.entries) {
      final def = schema.parameters[entry.key];
      expect(def, isNotNull, reason: '${entry.key} is not in the schema');
      if (def!.options != null) {
        expect(def.options, contains(entry.value), reason: entry.key);
      }
    }
    // Every visible schema parameter is something the converter sets.
    for (final id in schema.parameters.keys) {
      if (id == 'enabled' || id == 'method') continue;
      expect(values.containsKey(id), isTrue, reason: '$id is never converted');
    }
  });

  test('a pass switched on with nothing in it does nothing', () {
    const on = AudioRestorationParameters(enabled: true);
    expect(on.hasEffect, isFalse);
    expect(on.summary, 'Nothing selected');
    expect(const AudioRestorationParameters().summary, 'Off');
    expect(on.copyWith(offsetMs: 40).hasEffect, isTrue);
    expect(on.copyWith(offsetMs: 40).summary, 'Sync +40 ms');
    expect(_everything.summary, startsWith('Channels, Declip +'));
  });

  test('it is not a picture pass', () {
    const p = ProcessingPipeline(audio: _everything);
    expect(p.enabledPasses, isNot(contains(PassType.audioRestoration)));
    expect(p.isPassEnabled(PassType.audioRestoration), isTrue);
    expect(p.enabledPassCount - p.videoPassCount, 1);
    // Toggling keeps every setting.
    final off = p.togglePass(PassType.audioRestoration, false);
    expect(off.audio.enabled, isFalse);
    expect(off.togglePass(PassType.audioRestoration, true).audio.toJson(),
        _everything.toJson());
  });

  test('DeepFilterNet is offered when speech enhancement is switched on', () {
    expect(deepFilterChosen('audio_restoration', {'deepFilter': false}, {'deepFilter': true}), isTrue);
    expect(deepFilterChosen('audio_restoration', {'deepFilter': true}, {'deepFilter': true}), isFalse);
    expect(deepFilterChosen('audio_restoration', {}, {'denoise': true}), isFalse);
    expect(deepFilterChosen('noise_reduction', {}, {'deepFilter': true}), isFalse);
    expect(deepFilterNetAddonId, 'deepfilternet');
    expect(File('assets/addons/$deepFilterNetAddonId.json').existsSync(), isTrue);
  });

  test('the audio phase is its own progress phase', () {
    const p = ProgressInfo(frame: 40, totalFrames: 100, fps: 0, eta: 0, phase: 'audio');
    expect(p.isAudioPhase, isTrue);
    expect(p.isEncodingPhase, isFalse);
  });
}
