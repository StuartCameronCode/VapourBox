/// Pins `AudioCompatibilityService`'s container/codec table to what the bundled
/// FFmpeg's muxers actually accept for `-c:a copy` (issue #118).
///
/// The table decides whether audio passthrough is blocked before a job starts,
/// so an entry missing from it refuses a job that would have worked — `mp2`
/// was missing from every container, which made VHS/DVD MPEG audio impossible
/// to pass through at all. An extra entry is the opposite failure: the job
/// starts and ffmpeg dies. This test checks both directions, for every codec
/// the table names, by muxing a short clip with the real binary.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/audio_compatibility_service.dart';

import 'support/worker_harness.dart';

/// ffprobe `codec_name` -> the FFmpeg encoder that produces it.
const _encoderFor = {'dts': 'dca'};

void main() {
  final service = AudioCompatibilityService();

  test('MP2 passes through in every container (issue #118)', () {
    for (final container in ContainerFormat.values) {
      expect(service.isCodecCompatible('mp2', container), isTrue,
          reason: 'mp2 must be allowed in ${container.displayName}');
    }
    expect(service.getCompatibleContainers('mp2'),
        unorderedEquals(ContainerFormat.values));
  });

  group('table matches the bundled FFmpeg', () {
    late Directory tmp;

    setUpAll(() async {
      await WorkerHarness.ensureReady();
      tmp = Directory.systemTemp.createTempSync('vapourbox_audio_compat_');
    });

    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<ProcessResult> ffmpeg(List<String> args) => Process.run(
          WorkerHarness.ffmpegPath,
          ['-v', 'error', '-y', ...args],
          environment: WorkerHarness.ffmpegEnv,
        );

    for (final codec in AudioCompatibilityService.knownCodecs.toList()..sort()) {
      test(codec, () async {
        final source = p.join(tmp.path, '$codec.mka');
        final made = await ffmpeg([
          '-f', 'lavfi',
          '-i', 'sine=d=0.5,aformat=channel_layouts=stereo:sample_rates=48000',
          '-strict', '-2',
          '-c:a', _encoderFor[codec] ?? codec,
          source,
        ]);
        expect(made.exitCode, 0,
            reason: 'could not encode a $codec source: ${made.stderr}');

        final mismatches = <String>[];
        for (final container in ContainerFormat.values) {
          final out = p.join(tmp.path, '$codec.${container.extension}');
          final muxed = await ffmpeg([
            '-f', 'lavfi', '-i', 'testsrc=s=64x64:d=0.5',
            '-i', source,
            '-map', '0:v', '-map', '1:a',
            '-c:v', 'mpeg4', '-c:a', 'copy',
            out,
          ]);
          final ffmpegAccepts = muxed.exitCode == 0;
          if (ffmpegAccepts != service.isCodecCompatible(codec, container)) {
            mismatches.add('${container.displayName}: FFmpeg '
                '${ffmpegAccepts ? 'accepts' : 'rejects'} it, the table '
                '${ffmpegAccepts ? 'blocks' : 'allows'} it');
          }
        }
        expect(mismatches, isEmpty, reason: '$codec: ${mismatches.join('; ')}');
      });
    }
  });
}
