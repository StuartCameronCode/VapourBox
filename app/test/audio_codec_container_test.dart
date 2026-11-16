/// Convert's audio codec x container table (task #39): the model, its
/// wording, the Settings choices and the container switch, pinned to the
/// output capability table the worker also reads (task #49).
/// `output_capabilities_test.dart` checks the table against the bundled
/// FFmpeg's muxers.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/audio_compatibility_service.dart';
import 'package:vapourbox/views/settings/settings_dialog.dart';

/// The ffprobe `codec_name` each Convert codec's encoder writes.
const probeName = {
  AudioCodec.aac: 'aac',
  AudioCodec.mp3: 'mp3',
  AudioCodec.ac3: 'ac3',
  AudioCodec.flac: 'flac',
  AudioCodec.opus: 'opus',
  AudioCodec.pcm: 'pcm_s16le',
};

void main() {
  final rows = (jsonDecode(File('../Tests/TestResources/output_capabilities.json')
          .readAsStringSync())['audioConvert'] as List)
      .cast<Map<String, dynamic>>();

  test('every pair agrees with the vector file, message included', () {
    expect(rows, hasLength(AudioCodec.values.length * ContainerFormat.values.length));
    for (final row in rows) {
      final codec = AudioCodec.values.singleWhere((c) => c.value == row['codec']);
      final container =
          ContainerFormat.values.singleWhere((k) => k.value == row['container']);
      final label = '${codec.name} in ${container.name}';
      expect(codec.supportsContainer(container), row['supported'], reason: label);
      expect(codec.containerProblem(container), row['message'], reason: label);
      expect(container.supportedAudioCodecs.contains(codec), row['supported'],
          reason: label);

      final convert = EncodingSettings(
          audioMode: AudioMode.convert, audioCodec: codec, container: container);
      expect(convert.audioContainerProblem, row['message'], reason: label);
      for (final mode in [AudioMode.passthrough, AudioMode.none]) {
        expect(convert.copyWith(audioMode: mode).audioContainerProblem, isNull,
            reason: '$label, ${mode.name}');
      }
    }
  });

  test('the fallback always fits and keeps lossless lossless', () {
    for (final codec in AudioCodec.values) {
      for (final container in ContainerFormat.values) {
        final f = codec.fallbackFor(container);
        final label = '${codec.name} in ${container.name}';
        expect(f.supportsContainer(container), isTrue, reason: label);
        expect(f.isLossless, codec.isLossless, reason: label);
        if (codec.supportsContainer(container)) {
          expect(f, codec, reason: label);
        }
      }
    }
    expect(AudioCodec.flac.fallbackFor(ContainerFormat.mov), AudioCodec.pcm);
    expect(AudioCodec.opus.fallbackFor(ContainerFormat.mov), AudioCodec.aac);
    expect(AudioCodec.opus.fallbackFor(ContainerFormat.avi), AudioCodec.aac);
  });

  test('agrees with the Passthrough table for the codecs Convert writes', () {
    // One statement of what each muxer takes, not two that drift apart.
    final service = AudioCompatibilityService();
    for (final codec in AudioCodec.values) {
      for (final container in ContainerFormat.values) {
        expect(codec.supportsContainer(container),
            service.isCodecCompatible(probeName[codec]!, container),
            reason: '${codec.name} in ${container.name}');
      }
    }
  });

  group('Settings', () {
    test('the codec list holds only what the container can hold', () {
      for (final container in ContainerFormat.values) {
        final s = EncodingSettings(
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.aac,
            container: container);
        expect(audioCodecChoices(s), container.supportedAudioCodecs);
      }
      expect(
          audioCodecChoices(const EncodingSettings(container: ContainerFormat.mov)),
          isNot(contains(AudioCodec.opus)));
    });

    test('a saved unsupported codec stays listed so the dropdown keeps it', () {
      const s = EncodingSettings(
          audioMode: AudioMode.convert,
          audioCodec: AudioCodec.opus,
          container: ContainerFormat.mov);
      expect(audioCodecChoices(s), contains(AudioCodec.opus));
      expect(s.audioContainerProblem, contains("Opus audio can't be stored in MOV"));
    });

    test('switching the container switches an unsupported audio codec', () {
      const flac = EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.convert,
          audioCodec: AudioCodec.flac);
      final mov = flac.withContainer(ContainerFormat.mov);
      expect(mov.audioCodec, AudioCodec.pcm);
      expect(mov.codec.supportsContainer(ContainerFormat.mov), isTrue);
      expect(mov.audioContainerProblem, isNull);

      final opus = flac.copyWith(audioCodec: AudioCodec.opus);
      expect(opus.withContainer(ContainerFormat.mov).audioCodec, AudioCodec.aac);
      expect(opus.withContainer(ContainerFormat.avi).audioCodec, AudioCodec.aac);
      expect(opus.withContainer(ContainerFormat.mp4).audioCodec, AudioCodec.opus);
      expect(flac.withContainer(ContainerFormat.avi).audioCodec, AudioCodec.flac);
      expect(flac.withContainer(ContainerFormat.avi).codec, VideoCodec.ffv1);
    });
  });
}
