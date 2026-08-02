/// Full-encode tests for unusual source pixel formats (issue #50).
///
/// `templates/pipe_source.py` reads raw planar frames off stdin, so it only
/// understands the formats in its `_FORMAT_MAP`. The app passes ffprobe's
/// `pix_fmt` through verbatim, so every source outside that map used to fail the
/// whole job at script evaluation with "Unsupported pixel format: <name>" —
/// NTSC DV (`yuv411p`) being the reported case. `worker/src/pixel_format.rs` now
/// passes readable formats through and converts the rest in the decoder.
///
/// Fixtures are generated at run time with the bundled ffmpeg rather than
/// committed, since a second of DV is megabytes of repo.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/source_formats';

/// Generate a short clip in a specific pixel format with the bundled ffmpeg.
Future<String> _makeFixture({
  required String name,
  required String codec,
  required String pixFmt,
  required String container,
  String size = '320x240',
}) async {
  final path = '$_outDir/src_$name.$container';
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc=size=$size:rate=25:duration=0.4',
      '-c:v', codec, '-pix_fmt', pixFmt,
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0,
      reason: 'fixture generation failed for $name: ${result.stderr}');
  expect(File(path).existsSync(), isTrue);
  return path;
}

/// Run the worker over [fixture] with a light deinterlace pass and assert it
/// produced a playable video.
Future<void> _expectEncodes(String fixture, String label) async {
  // Probe exactly as the app does — whatever ffprobe reports is what the job
  // carries, so the test exercises the real path rather than a curated name.
  final src = await WorkerHarness.firstStream(fixture,
      selector: 'v:0',
      entries: ['pix_fmt', 'width', 'height', 'nb_read_frames'],
      countFrames: true);
  expect(src, isNotNull, reason: 'fixture should have a video stream');
  final pixFmt = src!['pix_fmt'] as String;
  print('  $label source: $pixFmt ${src['width']}x${src['height']} '
      '${src['nb_read_frames']} frames');

  final job = VideoJob(
    id: const Uuid().v4(),
    inputPath: fixture,
    outputPath: '$_outDir/$label.mkv',
    processingPipeline: const ProcessingPipeline(
      deinterlace: QTGMCParameters(
        enabled: true,
        preset: QTGMCPreset.fast,
        tff: true,
        fpsDivisor: 2,
      ),
    ),
    encodingSettings: const EncodingSettings(
      codec: VideoCodec.h264,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none,
    ),
    detectedFieldOrder: FieldOrder.topFieldFirst,
    totalFrames: int.parse(src['nb_read_frames'] as String),
    inputFrameRate: 25.0,
    inputWidth: int.parse(src['width'].toString()),
    inputHeight: int.parse(src['height'].toString()),
    inputPixelFormat: pixFmt,
  );

  final result = await WorkerHarness.runJob(job.toJson(), label: label);
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '$pixFmt source failed: ${result.error}\n'
          '--- worker log (tail) ---\n${tail.join('\n')}');
  final out = await WorkerHarness.firstStream(result.outputPath!,
      selector: 'v:0', entries: ['codec_name', 'width', 'height']);
  expect(out, isNotNull, reason: 'output should contain a video stream');
  print('  $label output: ${out?['codec_name']} '
      '${out?['width']}x${out?['height']}');
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  group('unusual source pixel formats (full encode)', () {
    test('NTSC DV 4:1:1 encodes end-to-end', () async {
      // dvvideo only accepts DV frame sizes; NTSC DV is 720x480 4:1:1.
      final fixture = await _makeFixture(
        name: 'dv_ntsc',
        codec: 'dvvideo',
        pixFmt: 'yuv411p',
        container: 'dv',
        size: '720x480',
      );
      final src = await WorkerHarness.firstStream(fixture,
          selector: 'v:0', entries: ['pix_fmt']);
      expect(src?['pix_fmt'], 'yuv411p',
          reason: 'fixture must really be 4:1:1 to exercise the fix');
      await _expectEncodes(fixture, 'dv_ntsc_411');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('grayscale source encodes end-to-end', () async {
      final fixture = await _makeFixture(
        name: 'gray',
        codec: 'rawvideo',
        pixFmt: 'gray',
        container: 'avi',
      );
      await _expectEncodes(fixture, 'gray');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('RGB source encodes end-to-end', () async {
      final fixture = await _makeFixture(
        name: 'rgb',
        codec: 'ffv1',
        pixFmt: 'gbrp',
        container: 'mkv',
      );
      await _expectEncodes(fixture, 'rgb');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('4:1:0 source encodes end-to-end', () async {
      final fixture = await _makeFixture(
        name: 'yuv410p',
        codec: 'rawvideo',
        pixFmt: 'yuv410p',
        container: 'avi',
      );
      await _expectEncodes(fixture, 'yuv410p');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
