/// The output capability table on the app side (task #49): the generated
/// `lib/models/output_capabilities_table.dart` is current, complete and
/// self-consistent, and no app code decides by comparing containers.
/// `output_capabilities_test.dart` checks the table against FFmpeg; the
/// worker reads the same JSON (`models::output_capabilities`).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/output_capabilities_table.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/audio_compatibility_service.dart';

import '../tool/generate_output_capabilities.dart' as generator;

void main() {
  test('the generated table is current', () {
    final fresh = generator.generate(File(generator.tablePath).readAsStringSync());
    expect(File(generator.outputPath).readAsStringSync(), fresh,
        reason: 'output_capabilities.json changed: run '
            '`dart run tool/generate_output_capabilities.dart` in app/');
  });

  test('every codec has a row per container, every container its traits', () {
    expect(outputVideoRows, hasLength(VideoCodec.values.length * ContainerFormat.values.length));
    expect(outputAudioConvertRows,
        hasLength(AudioCodec.values.length * ContainerFormat.values.length));
    for (final k in ContainerFormat.values) {
      expect(outputContainerTraits[k.value]?.keys, unorderedEquals([
        'storesStreamStart', 'videoTimeBase', 'fieldFlag', 'audioPacketTiming',
        'restoredPassthrough', 'subtitles', 'isoMedia',
      ]), reason: k.name);
      expect(outputAudioCopy[k.value], isNotNull, reason: k.name);
      for (final c in VideoCodec.values) {
        final (_, message, _, _) = outputVideoRows[(c.value, k.value)]!;
        expect(message == null, c.supportsContainer(k), reason: '${c.name}/${k.name}');
        expect(c.containerMessage(k), message);
      }
    }
  });

  test('the table agrees with itself', () {
    for (final k in ContainerFormat.values) {
      expect(k.copies(k.restoredPassthrough), isTrue,
          reason: '${k.name}: its restored track must be a codec it copies');
      expect(k.copies('pcm_s24le'), isTrue, reason: k.name);
      expect(k.storesStreamStart, !k.timesVideoByFrame, reason: k.name);
    }
    for (final c in VideoCodec.values) {
      expect(c.supportsContainer(c.preferredContainer), isTrue, reason: c.name);
    }
    // The settings dialog's switches land on an offered video pair and a
    // supported audio pair, from every start.
    for (final c in VideoCodec.values) {
      for (final from in ContainerFormat.values) {
        for (final to in ContainerFormat.values) {
          for (final a in AudioCodec.values) {
            final s = EncodingSettings(
                    codec: c, container: from, audioMode: AudioMode.convert, audioCodec: a)
                .withContainer(to);
            expect(s.codec.supportsContainer(to), isTrue, reason: '${c.name} ${from.name}->${to.name}');
            expect(s.audioCodec.supportsContainer(to), isTrue);
          }
        }
      }
    }
  });

  test('the pre-run check names exactly the pairs the worker refuses', () {
    for (final c in VideoCodec.values) {
      for (final k in ContainerFormat.values) {
        final s = EncodingSettings(codec: c, container: k);
        final refused = c.containerVerdict(k) == ContainerVerdict.refused;
        expect(s.videoContainerProblem != null, refused, reason: '${c.name}/${k.name}');
        if (refused) {
          // The dialog's way out: the codec's own container.
          final fixed = s.withContainer(c.preferredContainer);
          expect(fixed.videoContainerProblem, isNull);
          expect(fixed.codec, c);
        }
      }
    }
    expect(const EncodingSettings(codec: VideoCodec.av1, container: ContainerFormat.mov)
        .videoContainerProblem, contains('Choose MP4 or MKV'));
  });

  test('the copy refusal has the worker\'s words', () {
    expect(AudioCompatibilityService.copyProblem('aac', ContainerFormat.mp4), isNull);
    expect(AudioCompatibilityService.copyProblem('opus', ContainerFormat.avi),
        'OPUS audio can\'t be copied into AVI files. Choose Convert in Settings → Audio, '
        'or save as MP4 or MKV.');
    expect(AudioCompatibilityService.copyProblem('wmav2', ContainerFormat.mkv),
        'WMAV2 audio can\'t be copied into MKV files. Choose Convert in Settings → Audio.');
    // The worker's copy of these strings.
    final rust = File('../worker/src/models/output_capabilities.rs').readAsStringSync();
    expect(rust, contains('"OPUS audio can\'t be copied into AVI files. Choose Convert in Settings \\u{2192} Audio, or save as MP4 or MKV."'));
  });

  /// A container fact is a column of the table, read through `ContainerFormat`'s
  /// getters; no app code outside the enum compares or switches on one.
  /// Defaults and assignments (`container: ContainerFormat.mkv`) are fine.
  test('no container is compared outside the table', () {
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('.g.dart')) continue;
      if (f.path.endsWith('output_capabilities_table.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        if (RegExp(r'case ContainerFormat\.|[=!]= ContainerFormat\.|ContainerFormat\.\w+ =>')
            .hasMatch(code)) {
          found.add('${f.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(found, isEmpty,
        reason: 'container decisions belong in Tests/TestResources/output_capabilities.json');
  });
}
