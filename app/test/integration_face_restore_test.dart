// Face Restoration end to end, on a VHS-like clip of a real face
// (Tests/TestResources/face_restore_test.mp4: NASA public-domain footage,
// see generate_face_test.sh), with the add-ons installed by the app's own
// installer (WorkerHarness.ensureAddon; set VAPOURBOX_ADDON_MIRROR to test
// files not uploaded yet):
//
//   * RestoreFormer++ finds the face and changes it, and every pixel outside a
//     generous box around the face is bit-exact to the same job with the pass
//     off (the pass composites in the source format with a mask that is zero
//     there) — in every plane, every frame;
//   * the GFPGAN and CodeFormer add-ons run, with and without smoothing;
//   * the preview is the encode's frame;
//   * a 10-bit source comes out 10-bit, changed in the face and bit-exact
//     outside it.
@Tags(['heavy'])
@Timeout(Duration(minutes: 40))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/face_restore_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

const _w = 640, _h = 480;
// Frames 30-45 of the fixture: the encode keeps 16 frames.
const _start = 30, _end = 45;
const _count = _end - _start + 1;

/// The face's detected box in the fixture is about x 255-365, y 149-286
/// (docs/reports/2026-11-face-restoration). Changes must stay inside this box,
/// which adds a little over half the face's size on every side — the
/// feathered mask reaches past the face itself, and the head moves.
const _outer = (x0: 190, y0: 70, x1: 430, y1: 370);

/// The middle of the face, which restoration must visibly change.
const _inner = (x0: 280, y0: 180, x1: 340, y1: 255);

String get _fixture => p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'face_restore_test.mp4');
String get _dir => p.join(WorkerHarness.outputDir, 'face_restore');

/// A job over the trimmed range ([trimmed]), or the whole fixture (the
/// preview's job: its `--frame` is a source frame, and the worker takes
/// `totalFrames` as the post-trim count).
Map<String, dynamic> _job(String name, FaceRestoreParameters? fr,
    {String? input, String pixFmt = 'yuv420p', bool trimmed = true}) {
  final job = VideoJob(
    id: const Uuid().v4(),
    inputPath: input ?? _fixture,
    outputPath: p.join(_dir, '$name.mkv'),
    processingPipeline: ProcessingPipeline(
      deinterlace: const QTGMCParameters(enabled: false),
      faceRestore: fr ?? const FaceRestoreParameters(enabled: false),
    ),
    encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
    inputWidth: _w,
    inputHeight: _h,
    inputPixelFormat: pixFmt,
    inputFrameRate: 29.97,
    totalFrames: trimmed ? _count : 150,
    startFrame: trimmed ? _start : null,
    endFrame: trimmed ? _end : null,
  );
  return job.toJson();
}

Future<String> _encode(String name, FaceRestoreParameters? fr,
    {String? input, String pixFmt = 'yuv420p'}) async {
  final r = await WorkerHarness.runJob(_job(name, fr, input: input, pixFmt: pixFmt),
      label: name, timeout: const Duration(minutes: 15));
  expect(r.success, isTrue, reason: '${r.error}\n${r.logs.reversed.take(30).toList().reversed.join('\n')}');
  // ignore: avoid_print
  print('  $name: ${r.duration.inMilliseconds / 1000}s for $_count frames');
  return r.outputPath ?? p.join(_dir, '$name.mkv');
}

/// Every frame of [path] as raw planar samples in [pixFmt].
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

/// Compare two decodes of 4:2:0 video sample by sample ([bytes] per sample).
/// Returns the mean absolute luma difference inside [_inner] (in 8-bit
/// levels) and the number of samples that differ outside [_outer].
({double innerDiff, int outsideChanged, int frames}) _compare(Uint8List a, Uint8List b, {int bytes = 1}) {
  expect(a.length, b.length, reason: 'the two encodes differ in size');
  final cw = _w ~/ 2, ch = _h ~/ 2;
  final frameSamples = _w * _h + 2 * cw * ch;
  final frames = a.length ~/ (frameSamples * bytes);
  int sample(Uint8List d, int i) => bytes == 1 ? d[i] : d[i * 2] | (d[i * 2 + 1] << 8);
  final scale = bytes == 1 ? 1.0 : 1 / 4.0;
  var inner = 0.0, innerN = 0, outside = 0;
  for (var f = 0; f < frames; f++) {
    final base = f * frameSamples;
    for (var y = 0; y < _h; y++) {
      for (var x = 0; x < _w; x++) {
        final i = base + y * _w + x;
        final d = (sample(a, i) - sample(b, i)).abs();
        final inOuter = x >= _outer.x0 && x < _outer.x1 && y >= _outer.y0 && y < _outer.y1;
        if (!inOuter && d != 0) outside++;
        if (x >= _inner.x0 && x < _inner.x1 && y >= _inner.y0 && y < _inner.y1) {
          inner += d * scale;
          innerN++;
        }
      }
    }
    for (var plane = 0; plane < 2; plane++) {
      final pbase = base + _w * _h + plane * cw * ch;
      for (var y = 0; y < ch; y++) {
        for (var x = 0; x < cw; x++) {
          final inOuter = x * 2 >= _outer.x0 && x * 2 < _outer.x1 && y * 2 >= _outer.y0 && y * 2 < _outer.y1;
          if (!inOuter && sample(a, pbase + y * cw + x) != sample(b, pbase + y * cw + x)) outside++;
        }
      }
    }
  }
  return (innerDiff: inner / innerN, outsideChanged: outside, frames: frames);
}

void main() {
  late String baseline;
  late Uint8List baselineRaw;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
    // The base add-on (detector, parser, RestoreFormer++) and the two
    // non-commercial models, each with its requirements (the AI runtime).
    await WorkerHarness.ensureAddon('face-restoration');
    await WorkerHarness.ensureAddon('face-gfpgan');
    await WorkerHarness.ensureAddon('face-codeformer');
    baseline = await _encode('baseline', null);
    baselineRaw = await _raw(baseline, 'yuv420p');
  });

  test('RestoreFormer++ changes the face and nothing outside it', () async {
    final out = await _encode('restoreformer', const FaceRestoreParameters(enabled: true));
    final c = _compare(baselineRaw, await _raw(out, 'yuv420p'));
    // ignore: avoid_print
    print('  restoreformer: face mean |diff| ${c.innerDiff.toStringAsFixed(2)}, '
        '${c.outsideChanged} samples changed outside the face box');
    expect(c.frames, _count);
    expect(c.innerDiff, greaterThan(2.0), reason: 'the face was not restored');
    expect(c.outsideChanged, 0, reason: 'pixels outside the face changed');
  });

  test('strength 0 is the input, bit-exact', () async {
    final out = await _encode('strength0', const FaceRestoreParameters(enabled: true, strength: 0));
    final c = _compare(baselineRaw, await _raw(out, 'yuv420p'));
    expect(c.innerDiff, 0);
    expect(c.outsideChanged, 0);
  });

  for (final (model, smoothing) in [
    (FaceRestoreModel.gfpgan, true),
    (FaceRestoreModel.codeFormer, true),
    (FaceRestoreModel.codeFormer, false),
  ]) {
    test('${model.displayName} runs (smoothing ${smoothing ? 'on' : 'off'})', () async {
      final out = await _encode('${model.value}_${smoothing ? 'smooth' : 'plain'}',
          FaceRestoreParameters(enabled: true, model: model, temporalSmoothing: smoothing));
      final c = _compare(baselineRaw, await _raw(out, 'yuv420p'));
      // ignore: avoid_print
      print('  ${model.value}: face mean |diff| ${c.innerDiff.toStringAsFixed(2)}');
      expect(c.innerDiff, greaterThan(2.0), reason: 'the face was not restored');
      expect(c.outsideChanged, 0, reason: 'pixels outside the face changed');
    });
  }

  test('the preview is the encode\'s frame', () async {
    const fr = FaceRestoreParameters(enabled: true);
    final out = await _encode('preview_ref', fr);
    // Two frames or more from the trim's ends, so the encode's temporal
    // neighbours (two either side) are the preview's.
    for (final frame in [_start + 2, _start + 10]) {
      final pv = await WorkerHarness.runPreview(_job('preview', fr, trimmed: false), frame: frame,
          timeout: const Duration(minutes: 5));
      expect(pv.success, isTrue, reason: '${pv.error}\n${pv.logs}');
      final preview = await WorkerHarness.imageToRgb24(pv.png!, label: 'fr_pv');
      final encoded = await WorkerHarness.frameRgb24(out, frame - _start, label: 'fr_enc');
      final input = await WorkerHarness.frameRgb24(baseline, frame - _start, label: 'fr_in');
      final diff = WorkerHarness.meanAbsDiff(preview, encoded);
      final restored = WorkerHarness.meanAbsDiff(input, encoded);
      // ignore: avoid_print
      print('  frame $frame: preview vs encode $diff, input vs encode $restored');
      expect(diff, lessThan(0.5), reason: 'the preview shows a different picture');
      expect(restored, greaterThan(diff * 4), reason: 'the comparison cannot tell restored from not');
    }
  });

  test('a 10-bit source stays 10-bit, restored in the face and exact outside it', () async {
    final src10 = p.join(_dir, 'face_10bit.mkv');
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      ['-y', '-v', 'error', '-i', _fixture, '-vf', 'format=yuv420p10le', '-c:v', 'ffv1', src10],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final off = await _encode('baseline_10bit', null, input: src10, pixFmt: 'yuv420p10le');
    final on = await _encode('restoreformer_10bit', const FaceRestoreParameters(enabled: true),
        input: src10, pixFmt: 'yuv420p10le');
    final stream = await WorkerHarness.firstStream(on, selector: 'v:0', entries: ['pix_fmt']);
    expect(stream?['pix_fmt'], 'yuv420p10le');
    final c = _compare(await _raw(off, 'yuv420p10le'), await _raw(on, 'yuv420p10le'), bytes: 2);
    // ignore: avoid_print
    print('  10-bit: face mean |diff| ${c.innerDiff.toStringAsFixed(2)} (8-bit levels), '
        '${c.outsideChanged} samples changed outside');
    expect(c.innerDiff, greaterThan(2.0));
    expect(c.outsideChanged, 0);
  });
}
