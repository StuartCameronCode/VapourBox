/// End-to-end tests for the Stabilize pass's vertical pitch ("frame height
/// breathing") correction for scanned film (issue #150).
///
/// A filter like this can run cleanly and produce the wrong picture, so these
/// test against a *reference* rather than "did it run": a fixture is built
/// with a known per-frame vertical stretch (by the stabiliser's own file mode,
/// inverted), and the corrections must bring it back measurably closer to the
/// undistorted original.
///
/// Heavy (full-encode) — tagged so it runs in the nightly workflow, not the
/// push gate. Script-generation coverage is in
/// integration_filter_parameters_test.dart and the worker's test_211…test_218.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/stabilize_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/stabilize';

String get _source =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'small_clip.mp4');

// A steady stretch of small_clip.mp4 (320x240, 29.97p): little subject motion,
// so pitch is measurable on every frame.
const _start = 900;
const _frames = 34;
const _width = 320;
const _height = 240;

/// The breathing injected into the fixture: up to ±0.6% of frame height per
/// frame — about what a pull-through scanner produces — from a fixed seed.
final List<double> _factors = () {
  final rng = math.Random(150);
  return List.generate(_frames, (_) => 1.0 + (rng.nextDouble() * 2 - 1) * 0.006);
}();

const _off = StabilizeParameters();

VideoJob _job(
  String name, {
  required String input,
  required StabilizeParameters stabilize,
  String? factorsPath,
  int? startFrame,
  int? endFrame,
  int totalFrames = _frames,
}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        stabilize: stabilize,
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      detectedFieldOrder: FieldOrder.progressive,
      totalFrames: totalFrames,
      inputFrameRate: 29.97,
      inputWidth: _width,
      inputHeight: _height,
      inputPixelFormat: 'yuv420p',
      startFrame: startFrame,
      endFrame: endFrame,
      pitchFactorsPath: factorsPath,
    );

Future<String> _encode(VideoJob job) async {
  final result = await WorkerHarness.runJob(job.toJson(), label: p.basename(job.outputPath));
  final tail = result.logs.length > 25 ? result.logs.sublist(result.logs.length - 25) : result.logs;
  expect(result.success, isTrue,
      reason: '${result.error}\n--- worker log (tail) ---\n${tail.join('\n')}');
  return result.outputPath!;
}

/// Frame [n] of [video] as rgb24.
Future<Uint8List> _frame(String video, int n) async {
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-i', video,
      '-vf', 'select=eq(n\\,$n)', '-frames:v', '1',
      '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
    ],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  if (result.exitCode != 0) throw Exception('frame $n of $video: ${result.stderr}');
  return Uint8List.fromList(result.stdout as List<int>);
}

/// Mean abs diff (0-255) to [reference] over the interior frames, ignoring
/// the top and bottom rows a correction fills from outside the picture.
Future<double> _distance(String video, String reference) async {
  const margin = 8; // rows
  const rowBytes = _width * 3;
  var total = 0.0;
  var count = 0;
  for (var n = 6; n < _frames - 6; n++) {
    final a = await _frame(video, n);
    final b = await _frame(reference, n);
    Uint8List crop(Uint8List x) =>
        Uint8List.sublistView(x, margin * rowBytes, (_height - margin) * rowBytes);
    total += WorkerHarness.meanAbsDiff(crop(a), crop(b));
    count++;
  }
  return total / count;
}

void main() {
  late String reference; // the untouched frames
  late String distorted; // the same frames with known breathing
  late String factorsForDistorted; // per-frame factors, indexed from 0

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);

    // The reference: the same trimmed range, pass off, lossless.
    reference = await _encode(_job('reference',
        input: _source,
        stabilize: _off,
        startFrame: _start,
        endFrame: _start + _frames - 1));

    // The fixture: file mode, inverted, on a TRIMMED encode — so this also
    // exercises source-frame indexing (the file names frames 900…933).
    final injectFile = File('$_outDir/inject.pitch.txt');
    await injectFile.writeAsString([
      '# frame,factor — stretch to apply',
      for (var k = 0; k < _frames; k++) '${_start + k},${_factors[k]}',
    ].join('\n'));
    distorted = await _encode(_job('distorted',
        input: _source,
        stabilize: const StabilizeParameters(
          enabled: true,
          weave: false,
          pitchMode: PitchMode.file,
          invertFactors: true,
        ),
        factorsPath: injectFile.path,
        startFrame: _start,
        endFrame: _start + _frames - 1));

    final f = File('$_outDir/distorted.pitch.txt');
    await f.writeAsString(_factors.join('\n'));
    factorsForDistorted = f.path;
  });

  test('the fixture is actually distorted', () async {
    final d = await _distance(distorted, reference);
    print('  distorted vs reference: $d');
    // ~0.33 measured: small_clip is soft, so ±0.6% of height moves little.
    // Every other bound here is relative to this, so it just has to be real.
    expect(d, greaterThan(0.2), reason: 'the injected breathing must be visible to the metric');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('file mode undoes known per-frame factors', () async {
    final corrected = await _encode(_job('file_corrected',
        input: distorted,
        stabilize: const StabilizeParameters(
          enabled: true,
          weave: false,
          pitchMode: PitchMode.file,
        ),
        factorsPath: factorsForDistorted));
    final before = await _distance(distorted, reference);
    final after = await _distance(corrected, reference);
    print('  file mode: $before -> $after');
    // Two Spline36 resamples can't be perfect, but most of the error must go.
    expect(after, lessThan(before * 0.4));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('auto mode measures and removes the breathing', () async {
    final corrected = await _encode(_job('auto_corrected',
        input: distorted,
        stabilize: const StabilizeParameters(
          enabled: true,
          weave: false,
          pitchMode: PitchMode.auto,
        )));
    final before = await _distance(distorted, reference);
    final after = await _distance(corrected, reference);
    print('  auto mode: $before -> $after');
    // Auto corrects to the local mean rather than the absolute truth, and the
    // clip has some real motion, so it is held to a looser bound than file
    // mode: it must still remove a clear majority of the error.
    expect(after, lessThan(before * 0.75));
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('weave + auto pitch runs and keeps the frame geometry', () async {
    final out = await _encode(_job('weave_auto',
        input: distorted,
        stabilize: const StabilizeParameters(
            enabled: true, pitchMode: PitchMode.auto, pitchEdgeFill: EdgeFill.black)));
    final v = await WorkerHarness.firstStream(out,
        selector: 'v:0', entries: ['width', 'height', 'nb_read_frames'],
        countFrames: true);
    expect(v?['width'], _width);
    expect(v?['height'], _height);
    expect(int.parse('${v?['nb_read_frames']}'), _frames);
    // Stabilising an already-steady clip must not wreck it.
    expect(await _distance(out, distorted), lessThan(6.0));
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('preview applies the factor of the frame it shows', () async {
    // The preview decodes a window that starts before the target, so frame n
    // of the preview script is not source frame n. If the offset were lost,
    // the preview would correct frame 15 with another frame's factor.
    const target = 15;
    final job = _job('preview_file',
        input: distorted,
        stabilize: const StabilizeParameters(
          enabled: true,
          weave: false,
          pitchMode: PitchMode.file,
        ),
        factorsPath: factorsForDistorted);
    final corrected = await WorkerHarness.runPreview(job.toJson(), frame: target);
    final plain = await WorkerHarness.runPreview(
        _job('preview_plain', input: distorted, stabilize: _off).toJson(),
        frame: target);
    final ref = await WorkerHarness.runPreview(
        _job('preview_ref', input: reference, stabilize: _off).toJson(),
        frame: target);

    for (final (label, result) in [('corrected', corrected), ('plain', plain), ('ref', ref)]) {
      expect(result.success, isTrue, reason: '$label preview failed: ${result.error}\n${result.logs}');
    }
    final c = await WorkerHarness.imageToRgb24(corrected.png!, label: 'stab_c');
    final d = await WorkerHarness.imageToRgb24(plain.png!, label: 'stab_d');
    final r = await WorkerHarness.imageToRgb24(ref.png!, label: 'stab_r');
    const rowBytes = _width * 3;
    Uint8List crop(Uint8List x) =>
        Uint8List.sublistView(x, 8 * rowBytes, (_height - 8) * rowBytes);
    final before = WorkerHarness.meanAbsDiff(crop(d), crop(r));
    final after = WorkerHarness.meanAbsDiff(crop(c), crop(r));
    print('  preview frame $target (factor ${_factors[target]}): $before -> $after');
    expect(after, lessThan(before * 0.5));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
