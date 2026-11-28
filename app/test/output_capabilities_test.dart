/// Pins the output capability table (`Tests/TestResources/output_capabilities.json`,
/// task #49) to what the bundled FFmpeg's muxers actually do, both ways: the
/// Passthrough copy table (issue #118), Convert's codecs (task #39) and every
/// video codec x container verdict.
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

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/output_capabilities_table.dart';
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
    // H.264 is offered in every container, so only the sound decides.
    expect(AudioCompatibilityService.compatibleContainers('mp2', VideoCodec.h264),
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

    // Convert (task #39): each AudioCodec's own encoder into each container,
    // as the job does, against `AudioCodec.supportsContainer`, both ways.
    for (final codec in AudioCodec.values) {
      test('Convert ${codec.value}', () async {
        final mismatches = <String>[];
        for (final container in ContainerFormat.values) {
          final out = p.join(tmp.path, 'convert_${codec.name}.${container.extension}');
          final muxed = await ffmpeg([
            '-f', 'lavfi', '-i', 'testsrc=s=64x64:d=0.2',
            '-f', 'lavfi',
            '-i', 'sine=d=0.2,aformat=channel_layouts=stereo:sample_rates=48000',
            '-c:v', 'mpeg4', '-c:a', codec.value,
            out,
          ]);
          final ffmpegAccepts = muxed.exitCode == 0;
          if (ffmpegAccepts != codec.supportsContainer(container)) {
            mismatches.add('${container.displayName}: FFmpeg '
                '${ffmpegAccepts ? 'accepts' : 'rejects'} it, the table '
                '${ffmpegAccepts ? 'refuses' : 'allows'} it ${muxed.stderr}');
          }
        }
        expect(mismatches, isEmpty, reason: '${codec.value}: ${mismatches.join('; ')}');
      });
    }

    // Video (task #49): every codec x container row with the bundled FFmpeg.
    // An offered or not-offered pair must mux; a refused one must fail,
    // unless the row says FFmpeg writes it (AV1 in AVI's non-standard tag).
    // A hardware encoder is checked through its software twin (`muxEncoder`):
    // muxing depends on the codec id, and no runner has the hardware.
    for (final codec in VideoCodec.values) {
      test('Video ${codec.value}', () async {
        final mismatches = <String>[];
        for (final container in ContainerFormat.values) {
          final (verdict, _, muxEncoder, ffmpegWrites) =
              outputVideoRows[(codec.value, container.value)]!;
          final encoder = (muxEncoder ?? codec.value).split(' ');
          if (encoder.first == 'libsvtav1' && !await WorkerHarness.hasEncoder('libsvtav1')) {
            continue; // macOS x64's FFmpeg has none (task #45)
          }
          final out = p.join(tmp.path, 'video_${codec.name}.${container.extension}');
          final muxed = await ffmpeg([
            '-f', 'lavfi', '-i', 'testsrc=s=64x64:d=0.2',
            '-pix_fmt', _muxPixFmt(codec),
            '-c:v', ...encoder,
            out,
          ]);
          final ffmpegAccepts = muxed.exitCode == 0;
          final expected = verdict != 'refused' || ffmpegWrites;
          if (ffmpegAccepts != expected) {
            mismatches.add('${container.displayName}: FFmpeg '
                '${ffmpegAccepts ? 'writes' : 'refuses'} it, the table says $verdict '
                '${muxed.stderr}');
          }
        }
        expect(mismatches, isEmpty, reason: '${codec.value}: ${mismatches.join('; ')}');
      });
    }
  });
}

/// The pixel format each codec is encoded from (the worker's pins).
String _muxPixFmt(VideoCodec codec) {
  if (codec == VideoCodec.prores4444 || codec == VideoCodec.prores4444Xq) {
    return 'yuv444p10le';
  }
  if (codec.isProRes || codec.isUncompressed) return 'yuv422p10le';
  if (codec == VideoCodec.huffyuv) return 'yuv422p';
  return 'yuv420p';
}
