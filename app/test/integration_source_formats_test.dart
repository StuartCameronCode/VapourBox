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
import 'dart:typed_data';

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
      entries: ['pix_fmt', 'width', 'height', 'r_frame_rate', 'nb_read_frames'],
      countFrames: true);
  expect(src, isNotNull, reason: 'fixture should have a video stream');
  final pixFmt = src!['pix_fmt'] as String;
  final frames = int.parse(src['nb_read_frames'] as String);
  // The rate the app would carry: NTSC DV is stored at 29.97 whatever rate
  // the fixture's frames were made at, and a job claiming 25 had its ten
  // stored frames placed on eight slots of a 25 fps grid.
  final rate = (src['r_frame_rate'] as String).split('/').map(int.parse).toList();
  final fps = rate[0] / rate[1];
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
    totalFrames: frames,
    inputFrameRate: fps,
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
      selector: 'v:0',
      entries: ['codec_name', 'width', 'height', 'nb_read_frames'],
      countFrames: true);
  expect(out, isNotNull, reason: 'output should contain a video stream');
  print('  $label output: ${out?['codec_name']} '
      '${out?['width']}x${out?['height']} ${out?['nb_read_frames']} frames');
  // Single-rate deinterlacing keeps every frame.
  expect(int.parse(out!['nb_read_frames'] as String), frames,
      reason: '$label: output must keep all $frames source frames');
}

// ---------------------------------------------------------------------------
// 4:4:0 sources (task #100)
// ---------------------------------------------------------------------------

/// Frames in each 4:4:0 fixture (testsrc2, 0.2 s at 25 fps).
const _frames440 = 5;

/// A 4:4:0 FFV1 clip: testsrc2, with 1-pixel red/blue columns over the left
/// [stripeWidth] columns, so the source has horizontal chroma detail that a
/// 4:2:2 pipe cannot hold. [fullRange] makes the JPEG-camera case: full-range
/// samples tagged `pc`.
Future<String> _make440({
  required String name,
  required String pixFmt,
  required int width,
  required int height,
  required int stripeWidth,
  bool fullRange = false,
}) async {
  final path = '$_outDir/src_$name.mkv';
  final graph = [
    'testsrc2=s=${width}x$height:r=25:d=0.2[bg]',
    'color=c=black:s=${stripeWidth}x$height:r=25:d=0.2,format=gbrp,'
        "geq=r='if(mod(X\\,2)\\,255\\,0)':g='0':b='if(mod(X\\,2)\\,0\\,255)'[st]",
    '[bg][st]overlay=0:0:shortest=1:format=gbrp,'
        'scale=out_range=${fullRange ? 'pc' : 'tv'},format=$pixFmt[out]',
  ].join(';');
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-filter_complex', graph, '-map', '[out]',
      if (fullRange) ...['-color_range', 'pc'],
      '-c:v', 'ffv1', path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0,
      reason: 'fixture generation failed for $name: ${result.stderr}');
  return path;
}

/// Every frame of [path] as raw planar [pixFmt] samples, decoded by ffmpeg
/// with no filter of ours: the independent reference for a lossless encode.
Future<Uint8List> _rawFrames(String path, String pixFmt) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', pixFmt, '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(r.exitCode, 0, reason: 'decode of $path failed: ${r.stderr}');
  return Uint8List.fromList(r.stdout as List<int>);
}

/// Mean |U(x) - U(x+1)| over the stripe columns of frame [frame]'s U plane,
/// in 8-bit levels. The stripes alternate red/blue, about 200 levels apart in
/// U; a pipe that halves horizontal chroma averages each pair to ~0.
double _stripeContrast(Uint8List raw444, int width, int height, int stripeWidth,
    int frame, {required bool tenBit}) {
  final bps = tenBit ? 2 : 1;
  final plane = width * height;
  final frameBytes = plane * 3 * bps;
  final uStart = frame * frameBytes + plane * bps;
  int sample(int x, int y) {
    final i = uStart + (y * width + x) * bps;
    return tenBit ? raw444[i] | (raw444[i + 1] << 8) : raw444[i];
  }

  var total = 0.0;
  var n = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x + 1 < stripeWidth; x++) {
      total += (sample(x, y) - sample(x + 1, y)).abs();
      n++;
    }
  }
  return total / n / (tenBit ? 4 : 1);
}

/// Encode a 4:4:0 fixture with every pass off into FFV1 at "Match source",
/// and check the encode, and a preview of it, keep the source's horizontal
/// chroma: the output is 4:4:4, bit-identical to ffmpeg's own 4:4:4 decode
/// of the source, the 1-pixel colour columns survive, and the preview shows
/// the encode's picture.
Future<void> _expect440KeepsChroma({
  required String label,
  required String pixFmt,
  required String expectedOut,
  int width = 128,
  int height = 96,
  bool fullRange = false,
}) async {
  final stripeWidth = width ~/ 2;
  final fixture = await _make440(
    name: label,
    pixFmt: pixFmt,
    width: width,
    height: height,
    stripeWidth: stripeWidth,
    fullRange: fullRange,
  );
  final src = await WorkerHarness.firstStream(fixture,
      selector: 'v:0', entries: ['pix_fmt', 'color_range']);
  expect(src?['pix_fmt'], pixFmt, reason: 'fixture must really be $pixFmt');
  if (fullRange) expect(src?['color_range'], 'pc');

  final job = VideoJob(
    id: const Uuid().v4(),
    inputPath: fixture,
    outputPath: '$_outDir/$label.mkv',
    processingPipeline: const ProcessingPipeline(
      deinterlace: QTGMCParameters(enabled: false),
    ),
    encodingSettings: const EncodingSettings(
      codec: VideoCodec.ffv1,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none,
    ),
    totalFrames: _frames440,
    inputFrameRate: 25,
    inputWidth: width,
    inputHeight: height,
    inputPixelFormat: pixFmt,
    inputColorRange: src?['color_range'] as String?,
  );

  final result = await WorkerHarness.runJob(job.toJson(), label: label);
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '$label failed: ${result.error}\n'
          '--- worker log (tail) ---\n${tail.join('\n')}');
  final out = result.outputPath!;
  final outInfo = await WorkerHarness.firstStream(out,
      selector: 'v:0', entries: ['pix_fmt', 'color_range', 'width', 'height']);

  // Everything is measured and printed before it is asserted, so a failing
  // run (the unfixed worker) still reports what it produced.
  final tenBit = expectedOut.contains('10');
  final reference = await _rawFrames(fixture, expectedOut);
  final encoded = await _rawFrames(out, expectedOut);
  final srcContrast =
      _stripeContrast(reference, width, height, stripeWidth, 2, tenBit: tenBit);
  final outContrast = encoded.length == reference.length
      ? _stripeContrast(encoded, width, height, stripeWidth, 2, tenBit: tenBit)
      : double.nan;
  var differing = 0;
  if (encoded.length == reference.length) {
    for (var i = 0; i < encoded.length; i++) {
      if (encoded[i] != reference[i]) differing++;
    }
  }

  const frame = 2;
  final preview = await WorkerHarness.runPreview(job.toJson(), frame: frame);
  expect(preview.success, isTrue, reason: '$label preview: $preview');
  final previewRgb = await WorkerHarness.imageToRgb24(preview.png!, label: 'pv');
  final encodeRgb =
      await WorkerHarness.previewFrameRgb24(out, frame, label: 'enc');
  final previewVsEncode = WorkerHarness.meanAbsDiff(previewRgb, encodeRgb);
  // The columns as the preview shows them: odd columns red, even blue.
  var rightHue = 0;
  var stripePixels = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < stripeWidth; x++) {
      final i = (y * width + x) * 3;
      final r = previewRgb[i], b = previewRgb[i + 2];
      if (x.isOdd ? r > b + 64 : b > r + 64) rightHue++;
      stripePixels++;
    }
  }
  final hueShare = rightHue / stripePixels;

  print('  $label: out ${outInfo?['pix_fmt']} ${outInfo?['color_range']} '
      '${outInfo?['width']}x${outInfo?['height']}; '
      'samples differing from ffmpeg\'s $expectedOut decode: '
      '${encoded.length == reference.length ? '$differing of ${encoded.length}' : 'size ${encoded.length} vs ${reference.length}'}; '
      'stripe U contrast source ${srcContrast.toStringAsFixed(1)} '
      'encode ${outContrast.toStringAsFixed(1)}; '
      'preview vs encode ${previewVsEncode.toStringAsFixed(3)}; '
      'preview stripe hue ${(hueShare * 100).toStringAsFixed(1)}%');

  expect(outInfo?['pix_fmt'], expectedOut,
      reason: 'a 4:4:0 source must come out 4:4:4 under Match source '
          '(4:2:2 halves its horizontal chroma)');
  if (fullRange) expect(outInfo?['color_range'], 'pc');
  expect(srcContrast, greaterThan(100),
      reason: 'control: the fixture must have its colour columns');
  expect(encoded.length, reference.length);
  expect(differing, 0,
      reason: 'the encode must be ffmpeg\'s own $expectedOut decode of the '
          'source, sample for sample');
  expect(outContrast, greaterThan(100),
      reason: 'the 1-pixel colour columns must survive');
  expect(previewVsEncode, lessThan(0.5),
      reason: 'the preview must show the encode\'s picture');
  expect(hueShare, greaterThan(0.95),
      reason: 'the preview must show the colour columns');
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

  // Task #100: 4:4:0 (some JPEG/MJPEG cameras) has full horizontal chroma
  // and half vertical. It used to be piped as 4:2:2, which halves the
  // horizontal chroma; it is piped as 4:4:4 now.
  group('4:4:0 sources keep their horizontal chroma (task #100)', () {
    test('yuv440p', () async {
      await _expect440KeepsChroma(
          label: 'yuv440p', pixFmt: 'yuv440p', expectedOut: 'yuv444p');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('full-range 4:4:0, as a JPEG camera stores it', () async {
      await _expect440KeepsChroma(
          label: 'yuv440p_pc',
          pixFmt: 'yuv440p',
          expectedOut: 'yuv444p',
          fullRange: true);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('yuv440p10le', () async {
      await _expect440KeepsChroma(
          label: 'yuv440p10le',
          pixFmt: 'yuv440p10le',
          expectedOut: 'yuv444p10le');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('yuv440p at an odd size (127x95)', () async {
      // Off a 4:2:2 grid horizontally; a 4:4:4 pipe has no grid to be off.
      await _expect440KeepsChroma(
          label: 'yuv440p_127x95',
          pixFmt: 'yuv440p',
          expectedOut: 'yuv444p',
          width: 127,
          height: 95);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
