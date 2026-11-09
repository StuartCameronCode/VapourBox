// Colourisation end to end, on real black-and-white film
// (Tests/TestResources/colorize_test.mp4: "Diary of a Sergeant", 1945, a US
// War Department film in the public domain; see generate_colorize_test.sh),
// with the add-ons installed by the app's own installer
// (WorkerHarness.ensureAddon; set VAPOURBOX_ADDON_MIRROR to test files not
// uploaded yet):
//
//   * DDColor colours the picture, and the Y plane of every frame is
//     bit-exact to the same job with the pass off — the pass replaces only
//     the chroma;
//   * strength 0 is the input, bit-exact in every plane (the fixture's chroma
//     is exactly neutral);
//   * DeOldify Video runs the same way;
//   * a 10-bit source comes out 10-bit with its luma bit-exact;
//   * a source that already has colour keeps its luma and gets the model's
//     colour instead of its own;
//   * the preview is the encode's frame.
@Tags(['heavy'])
@Timeout(Duration(minutes: 60))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/colorize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

const _w = 640, _h = 480;
// Frames 40-55 of the fixture (the close-up): the encode keeps 16 frames.
const _start = 40, _end = 55;
const _count = _end - _start + 1;

String get _fixture => p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'colorize_test.mp4');
String get _colourFixture => p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'face_restore_test.mp4');
String get _dir => p.join(WorkerHarness.outputDir, 'colorize');

Map<String, dynamic> _job(String name, ColorizeParameters? cz,
    {String? input, String pixFmt = 'yuv420p', bool trimmed = true, double fps = 24, int total = 120}) {
  final job = VideoJob(
    id: const Uuid().v4(),
    inputPath: input ?? _fixture,
    outputPath: p.join(_dir, '$name.mkv'),
    processingPipeline: ProcessingPipeline(
      deinterlace: const QTGMCParameters(enabled: false),
      colorize: cz ?? const ColorizeParameters(enabled: false),
    ),
    encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
    inputWidth: _w,
    inputHeight: _h,
    inputPixelFormat: pixFmt,
    inputFrameRate: fps,
    totalFrames: trimmed ? _count : total,
    startFrame: trimmed ? _start : null,
    endFrame: trimmed ? _end : null,
  );
  return job.toJson();
}

Future<String> _encode(String name, ColorizeParameters? cz,
    {String? input, String pixFmt = 'yuv420p', double fps = 24}) async {
  final r = await WorkerHarness.runJob(_job(name, cz, input: input, pixFmt: pixFmt, fps: fps),
      label: name, timeout: const Duration(minutes: 25),
      // On the Intel-Mac CI VMs Core ML's virtual GPU fails and the models run
      // on a slow CPU: CodeFormer's first frame (five frames of faces, for the
      // smoothing) took ~10 min, past the worker's 600 s stall limit.
      extraEnv: const {'VAPOURBOX_STALL_TIMEOUT_SECS': '1200'});
  expect(r.success, isTrue, reason: '${r.error}\n${r.logs.reversed.take(30).toList().reversed.join('\n')}');
  // ignore: avoid_print
  print('  $name: ${r.duration.inMilliseconds / 1000}s for $_count frames');
  return r.outputPath ?? p.join(_dir, '$name.mkv');
}

Future<Uint8List> _raw(String path, String pixFmt) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', pixFmt, '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return Uint8List.fromList(r.stdout as List<int>);
}

/// Compare two decodes of 4:2:0 video ([bytes] per sample): the number of
/// luma samples that differ, the number of chroma samples that differ, and
/// the mean distance of [b]'s chroma from neutral (in 8-bit levels).
({int lumaChanged, int chromaChanged, double chroma, int frames}) _compare(Uint8List a, Uint8List b,
    {int bytes = 1}) {
  expect(a.length, b.length, reason: 'the two encodes differ in size');
  final luma = _w * _h, chroma = luma ~/ 2;
  final frameSamples = luma + chroma;
  final frames = a.length ~/ (frameSamples * bytes);
  int sample(Uint8List d, int i) => bytes == 1 ? d[i] : d[i * 2] | (d[i * 2 + 1] << 8);
  final neutral = bytes == 1 ? 128 : 512;
  final scale = bytes == 1 ? 1.0 : 0.25;
  var lumaChanged = 0, chromaChanged = 0;
  var dist = 0.0;
  for (var f = 0; f < frames; f++) {
    final base = f * frameSamples;
    for (var i = base; i < base + luma; i++) {
      if (sample(a, i) != sample(b, i)) lumaChanged++;
    }
    for (var i = base + luma; i < base + frameSamples; i++) {
      final v = sample(b, i);
      if (sample(a, i) != v) chromaChanged++;
      dist += (v - neutral).abs() * scale;
    }
  }
  return (lumaChanged: lumaChanged, chromaChanged: chromaChanged, chroma: dist / (frames * chroma), frames: frames);
}

void main() {
  late String baseline;
  late Uint8List baselineRaw;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
    // Each model's add-on, with its requirement (the AI runtime).
    await WorkerHarness.ensureAddon('colorize-ddcolor');
    await WorkerHarness.ensureAddon('colorize-deoldify');
    baseline = await _encode('baseline', null);
    baselineRaw = await _raw(baseline, 'yuv420p');
  });

  test('DDColor colours the picture and keeps every luma sample', () async {
    final out = await _encode('ddcolor', const ColorizeParameters(enabled: true));
    final c = _compare(baselineRaw, await _raw(out, 'yuv420p'));
    // ignore: avoid_print
    print('  ddcolor: mean chroma ${c.chroma.toStringAsFixed(2)} levels from neutral, '
        '${c.lumaChanged} luma samples changed');
    expect(c.frames, _count);
    expect(c.lumaChanged, 0, reason: 'the pass must keep the source\'s luma bit-exact');
    expect(c.chroma, greaterThan(2.0), reason: 'the picture was not coloured');
  });

  test('strength 0 is the input, bit-exact', () async {
    final out = await _encode('strength0', const ColorizeParameters(enabled: true, strength: 0));
    final c = _compare(baselineRaw, await _raw(out, 'yuv420p'));
    expect(c.lumaChanged, 0);
    expect(c.chromaChanged, 0);
  });

  test('DeOldify Video colours the picture and keeps every luma sample', () async {
    final out = await _encode('deoldify',
        const ColorizeParameters(enabled: true, model: ColorizeModel.deoldify, temporalRadius: 1));
    final c = _compare(baselineRaw, await _raw(out, 'yuv420p'));
    // ignore: avoid_print
    print('  deoldify: mean chroma ${c.chroma.toStringAsFixed(2)} levels from neutral');
    expect(c.lumaChanged, 0);
    expect(c.chroma, greaterThan(1.0));
  });

  test('a 10-bit source stays 10-bit, its luma bit-exact', () async {
    final src10 = p.join(_dir, 'colorize_10bit.mkv');
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      ['-y', '-v', 'error', '-i', _fixture, '-vf', 'format=yuv420p10le', '-c:v', 'ffv1', src10],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final off = await _encode('baseline_10bit', null, input: src10, pixFmt: 'yuv420p10le');
    final on = await _encode('ddcolor_10bit', const ColorizeParameters(enabled: true, temporalRadius: 0),
        input: src10, pixFmt: 'yuv420p10le');
    final stream = await WorkerHarness.firstStream(on, selector: 'v:0', entries: ['pix_fmt']);
    expect(stream?['pix_fmt'], 'yuv420p10le');
    final c = _compare(await _raw(off, 'yuv420p10le'), await _raw(on, 'yuv420p10le'), bytes: 2);
    // ignore: avoid_print
    print('  10-bit: mean chroma ${c.chroma.toStringAsFixed(2)} (8-bit levels), ${c.lumaChanged} luma changed');
    expect(c.lumaChanged, 0);
    expect(c.chroma, greaterThan(2.0));
  });

  test('a colour source keeps its luma and gets the model\'s colour', () async {
    // The face fixture is colour video (640x480, 29.97 fps).
    final off = await _encode('colour_baseline', null, input: _colourFixture, fps: 29.97);
    final on = await _encode('colour_ddcolor', const ColorizeParameters(enabled: true, temporalRadius: 0),
        input: _colourFixture, fps: 29.97);
    final c = _compare(await _raw(off, 'yuv420p'), await _raw(on, 'yuv420p'));
    expect(c.lumaChanged, 0);
    expect(c.chromaChanged, greaterThan(0), reason: 'the source\'s own colour should be replaced');
  });

  test('the preview is the encode\'s frame', () async {
    const cz = ColorizeParameters(enabled: true);
    final out = await _encode('preview_ref', cz);
    // Two frames or more from the trim's ends, so the encode's temporal
    // neighbours (two either side) are the preview's.
    for (final frame in [_start + 2, _start + 10]) {
      final pv = await WorkerHarness.runPreview(_job('preview', cz, trimmed: false), frame: frame,
          // Same budget as _encode: on the Intel-Mac VMs Core ML falls back to
          // the CPU, and the v2 runner's first frame alone can take ~10 min.
          timeout: const Duration(minutes: 20),
          extraEnv: const {'VAPOURBOX_STALL_TIMEOUT_SECS': '1200'});
      expect(pv.success, isTrue, reason: '${pv.error}\n${pv.logs}');
      final preview = await WorkerHarness.imageToRgb24(pv.png!, label: 'cz_pv');
      final encoded = await WorkerHarness.frameRgb24(out, frame - _start, label: 'cz_enc');
      final input = await WorkerHarness.frameRgb24(baseline, frame - _start, label: 'cz_in');
      final diff = WorkerHarness.meanAbsDiff(preview, encoded);
      final coloured = WorkerHarness.meanAbsDiff(input, encoded);
      // ignore: avoid_print
      print('  frame $frame: preview vs encode $diff, input vs encode $coloured');
      expect(diff, lessThan(0.5), reason: 'the preview shows a different picture');
      expect(coloured, greaterThan(diff * 4), reason: 'the comparison cannot tell coloured from not');
    }
  }, timeout: const Timeout(Duration(minutes: 75)));
}
