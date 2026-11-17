/// Unblend (SRestore) end to end, on fixtures with a known answer
/// (Tests/TestResources/generate_blended_test.sh): small_clip frames blended
/// into interlaced video the way a standards converter does it. Deinterlaced
/// at double rate and unblended, the output should be those frames again.
///
/// What is checked, each against the report (docs/reports/2026-11-srestore):
/// - recovery: most output frames are an original frame, far more than plain
///   decimation (the Frame Rate pass repeating/dropping frames) gives;
/// - length and rate: exactly floor(n * num / den) frames;
/// - preview = encode, at frames near the start and well into the clip,
///   where the detector's window is decoded fresh by the preview;
/// - depth, two ways (task #64): the same picture at 8 and 10 bits (an
///   exact shift, nothing ahead of Unblend that rounds) gives the same frames
///   exactly; a real 10-bit copy of the source, deinterlaced at 10 bits, is
///   unblended as well as the 8-bit one. Not the same frames: QTGMC rounds
///   differently at 10 bits, and srestore's min/max statistics turn that
///   into different picks for ~5-8% of frames, each a neighbouring original.
///
/// Heavy (full encodes): runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/unblend_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

/// small_clip frame the fixtures start from (generate_blended_test.sh).
const _first = 1350;
const _width = 320, _height = 240;
const _frameBytes = _width * _height * 3;

String get _outDir => '${WorkerHarness.outputDir}/unblend';
String _fixture(String name) => p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

/// Every frame of a video as packed rgb24, decoded once.
Future<List<Uint8List>> _frames(String path, {String? vf}) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, if (vf != null) ...['-vf', vf], '-fps_mode', 'passthrough',
      '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  if (r.exitCode != 0) throw Exception('decoding $path: ${r.stderr}');
  final bytes = r.stdout as List<int>;
  final all = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  return [
    for (var o = 0; o + _frameBytes <= all.length; o += _frameBytes)
      Uint8List.sublistView(all, o, o + _frameBytes),
  ];
}

/// small_clip's frames FIRST .. FIRST+count-1: what the blending started from.
Future<List<Uint8List>> _truth(int count) => _frames(_fixture('small_clip.mp4'),
    vf: "select='between(n\\,$_first\\,${_first + count - 1})',setpts=N/TB");

/// Every frame's luma (Y plane), in 8-bit levels. Decoded in the planar
/// format itself, never through `gray`, which expands the range.
Future<List<Float64List>> _lumas(String path, {bool tenBit = false, String? vf}) async {
  final all = await _raw(path, tenBit ? 'yuv420p10le' : 'yuv420p', vf: vf);
  const luma = _width * _height, samples = luma * 3 ~/ 2;
  final bps = tenBit ? 2 : 1;
  final view = ByteData.sublistView(all);
  return [
    for (var o = 0; o + samples * bps <= all.length; o += samples * bps)
      Float64List.fromList([
        for (var i = 0; i < luma; i++)
          tenBit ? view.getUint16(o + 2 * i, Endian.little) / 4 : all[o + i].toDouble(),
      ]),
  ];
}

double _lumaDiff(Float64List a, Float64List b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

/// For each output frame, the original within +-3 of where it belongs that
/// is nearest in luma, and its distance.
List<(int, double)> _nearestLuma(List<Float64List> out, List<Float64List> truth) => [
      for (var m = 0; m < out.length; m++)
        [
          for (var k = m - 3; k <= m + 3; k++)
            if (k >= 0 && k < truth.length) (k, _lumaDiff(out[m], truth[k])),
        ].reduce((a, b) => a.$2 <= b.$2 ? a : b),
    ];

/// Every sample of every frame, raw (yuv420p bytes or yuv420p10le words).
Future<Uint8List> _raw(String path, String pixFmt, {String? vf}) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, if (vf != null) ...['-vf', vf], '-fps_mode', 'passthrough',
      '-f', 'rawvideo', '-pix_fmt', pixFmt, '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  if (r.exitCode != 0) throw Exception('decoding $path: ${r.stderr}');
  final bytes = r.stdout as List<int>;
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

Future<String?> _pixFmt(String path) async =>
    (await WorkerHarness.firstStream(path, selector: 'v:0', entries: ['pix_fmt']))?['pix_fmt'] as String?;

/// For each output frame, its distance (rgb mean abs diff) to the nearest
/// original within +-3 of where it belongs.
List<double> _nearest(List<Uint8List> out, List<Uint8List> truth) => [
      for (var m = 0; m < out.length; m++)
        [
          for (var k = m - 3; k <= m + 3; k++)
            if (k >= 0 && k < truth.length) WorkerHarness.meanAbsDiff(out[m], truth[k]),
        ].reduce((a, b) => a < b ? a : b),
    ];

VideoJob _job(String name, String input, double fps, {
  required ProcessingPipeline pipeline,
  ContainerFormat container = ContainerFormat.mkv,
  String? pixelFormat,
}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: '$_outDir/$name.${container == ContainerFormat.mov ? 'mov' : 'mkv'}',
      processingPipeline: pipeline,
      encodingSettings: EncodingSettings(
        codec: VideoCodec.ffv1,
        container: container,
        audioMode: AudioMode.none,
      ),
      inputFrameRate: fps,
      // Set for every >8-bit fixture: before task #50 a job without it was
      // decoded as 8-bit 4:2:0, silently, and a depth test compared the
      // 8-bit run with itself (task #64).
      inputPixelFormat: pixelFormat,
    );

ProcessingPipeline _unblend(FrameRateTarget target) => ProcessingPipeline(
      deinterlace: const QTGMCParameters(enabled: true, tff: true),
      unblend: UnblendParameters(enabled: true, target: target),
    );

ProcessingPipeline _decimate(FrameRateTarget target) => ProcessingPipeline(
      deinterlace: const QTGMCParameters(enabled: true, tff: true),
      frameRate: FrameRateParameters(
          enabled: true, target: target, method: FrameRateMethod.duplicate),
    );

Future<String> _encode(VideoJob job) async {
  final result = await WorkerHarness.runJob(job.toJson(), label: p.basename(job.outputPath));
  expect(result.success, isTrue, reason: '${result.error}\n${result.logs.join('\n')}');
  return result.outputPath!;
}

/// Clean: within this of an original. Calibrated in the report: the same
/// chain with frames repeated instead of blended leaves originals within
/// ~1.5 levels (luma, p99) and a blend of neighbours sits ~3.6 levels (p50)
/// from either; rgb24 differences run a little higher than luma ones.
const _cleanLimit = 2.2;

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  group('Unblend (SRestore)', () {
    late List<Uint8List> truth;
    late String filmEncode;
    late VideoJob filmJob;

    setUpAll(() async {
      truth = await _truth(144);
      filmJob = _job('film_unblend', _fixture('blended_film_50i.mkv'), 25,
          pipeline: _unblend(FrameRateTarget.film23976));
      filmEncode = await _encode(filmJob);
    });

    test('recovers the film frames from PAL blending, far beyond decimation', () async {
      final out = await _frames(filmEncode);
      // 150 frames of 25i -> 300 at 50p -> floor(300 * 480 / 1001).
      expect(out.length, 143);
      final unblended = _nearest(out, truth);
      final decimated = _nearest(
          await _frames(await _encode(_job('film_decimate', _fixture('blended_film_50i.mkv'), 25,
              pipeline: _decimate(FrameRateTarget.film23976)))),
          truth);
      int clean(List<double> d) => d.where((v) => v <= _cleanLimit).length;
      print('  clean: unblend ${clean(unblended)}/${out.length}, '
          'decimation ${clean(decimated)}/${decimated.length}');
      // Measured (report): 143/143 and 87/143 (luma metric).
      expect(clean(unblended), greaterThanOrEqualTo((out.length * 0.95).floor()));
      expect(clean(unblended), greaterThan(clean(decimated) + out.length ~/ 5));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('recovers PAL frames from NTSC blending, at 10-bit 4:2:2', () async {
      final path = await _encode(_job('pal_unblend', _fixture('blended_pal_5994i.mkv'), 29.97,
          pipeline: _unblend(FrameRateTarget.pal25), pixelFormat: 'yuv422p10le'));
      expect(await _pixFmt(path), 'yuv422p10le', reason: 'the 10-bit 4:2:2 path must really run');
      final pal = await _truth(125);
      final out = await _frames(path);
      // 150 frames of 29.97i -> 300 at 59.94p -> floor(300 * 1001 / 2400).
      expect(out.length, 125);
      final unblended = _nearest(out, pal);
      final decimated = _nearest(
          await _frames(await _encode(_job('pal_decimate', _fixture('blended_pal_5994i.mkv'), 29.97,
              pipeline: _decimate(FrameRateTarget.pal25), pixelFormat: 'yuv422p10le'))),
          pal);
      int clean(List<double> d) => d.where((v) => v <= _cleanLimit).length;
      print('  clean: unblend ${clean(unblended)}/${out.length}, '
          'decimation ${clean(decimated)}/${decimated.length}');
      // Measured (report): 101/125 and 73/125 (luma metric).
      expect(clean(unblended), greaterThan(clean(decimated) + out.length ~/ 10));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('declares the exact target rate', () async {
      final path = await _encode(_job('film_rate', _fixture('blended_film_50i.mkv'), 25,
          pipeline: _unblend(FrameRateTarget.film23976), container: ContainerFormat.mov));
      // MOV: Matroska's 1/1000 timebase cannot hold 24000/1001 exactly.
      final v = await WorkerHarness.firstStream(path,
          selector: 'v:0', entries: ['r_frame_rate', 'nb_read_frames'], countFrames: true);
      expect(v?['r_frame_rate'], '24000/1001');
      expect(v?['nb_read_frames'], '143');
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('the same picture at 10 bits gives the 8-bit result exactly', () async {
      // The detector's own input, deinterlaced once at 8 bits, and its exact
      // 10-bit copy (ffmpeg's 8 -> 10 is a shift by 2). Nothing ahead of
      // Unblend rounds, so every measurement and pick must be the same: a
      // threshold left in 8-bit units at 10 bits would move most of them.
      final eightIn = await _encode(_job('film_deint_8bit', _fixture('blended_film_50i.mkv'), 25,
          pipeline: ProcessingPipeline(deinterlace: const QTGMCParameters(enabled: true, tff: true))));
      final tenIn = '$_outDir/film_deint_10bit.mkv';
      final r = await Process.run(WorkerHarness.ffmpegPath, [
        '-y', '-v', 'error', '-i', eightIn, '-c:v', 'ffv1', '-pix_fmt', 'yuv420p10le', tenIn,
      ], environment: WorkerHarness.ffmpegEnv);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final progressive = ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        unblend: UnblendParameters(enabled: true, target: FrameRateTarget.film23976),
      );
      final eight = await _encode(
          _job('film_exact_8bit', eightIn, 50, pipeline: progressive, pixelFormat: 'yuv420p'));
      final ten = await _encode(
          _job('film_exact_10bit', tenIn, 50, pipeline: progressive, pixelFormat: 'yuv420p10le'));
      expect(await _pixFmt(ten), 'yuv420p10le', reason: 'the 10-bit path must really run');
      final a = await _raw(eight, 'yuv420p');
      final b = await _raw(ten, 'yuv420p10le');
      // 300 frames at 50p -> floor(300 * 480 / 1001).
      const frameSamples = _width * _height * 3 ~/ 2;
      expect(a.length, 143 * frameSamples);
      expect(b.length, a.length * 2);
      final words = ByteData.sublistView(b);
      var differ = 0;
      int? firstFrame;
      for (var i = 0; i < a.length; i++) {
        if (words.getUint16(2 * i, Endian.little) != a[i] << 2) {
          differ++;
          firstFrame ??= i ~/ frameSamples;
        }
      }
      expect(differ, 0, reason: '$differ samples differ, first in output frame $firstFrame');
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('a 10-bit copy of the source is unblended as well as the 8-bit one', () async {
      final tenSource = '$_outDir/blended_film_50i_10bit.mkv';
      final r = await Process.run(WorkerHarness.ffmpegPath, [
        '-y', '-v', 'error', '-i', _fixture('blended_film_50i.mkv'),
        '-c:v', 'ffv1', '-pix_fmt', 'yuv420p10le', tenSource,
      ], environment: WorkerHarness.ffmpegEnv);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final ten = await _encode(_job('film_unblend_10bit', tenSource, 25,
          pipeline: _unblend(FrameRateTarget.film23976), pixelFormat: 'yuv420p10le'));
      expect(await _pixFmt(ten), 'yuv420p10le', reason: 'the 10-bit path must really run');
      final truth = await _lumas(_fixture('small_clip.mp4'),
          vf: "select='between(n\\,$_first\\,${_first + 143})',setpts=N/TB");
      final eight = await _lumas(filmEncode);
      final deep = await _lumas(ten, tenBit: true);
      expect(deep.length, eight.length);
      final n8 = _nearestLuma(eight, truth), n10 = _nearestLuma(deep, truth);
      // Luma: within 2 levels of an original (report: originals repeated
      // through the same chain sit within ~1.5, a blend ~3.6 from either).
      int clean(List<(int, double)> d) => d.where((x) => x.$2 <= 2.0).length;
      final same = [for (var m = 0; m < eight.length; m++) if (n8[m].$1 == n10[m].$1) m];
      final diffs = [for (final m in same) _lumaDiff(eight[m], deep[m])]..sort();
      final median = diffs[diffs.length ~/ 2], worst = diffs.last;
      print('  clean (luma <= 2.0): 8-bit ${clean(n8)}/${eight.length}, '
          '10-bit ${clean(n10)}/${deep.length}; same original ${same.length}/${eight.length}; '
          'luma 8 vs 10 where same: median ${median.toStringAsFixed(3)}, max ${worst.toStringAsFixed(3)}');
      // Measured on macOS arm64 (task #64): 143/143 at both depths, 136/143
      // the same original (the report's probe: 132), median 0.37 and max
      // 1.26 levels where the same. Picks differ a little per platform.
      expect(clean(n10), greaterThanOrEqualTo((deep.length * 0.95).floor()));
      expect(clean(n10), greaterThanOrEqualTo(clean(n8) - (deep.length * 0.02).ceil()));
      expect(same.length, greaterThanOrEqualTo((eight.length * 0.85).floor()));
      expect(median, lessThanOrEqualTo(0.6));
      expect(worst, lessThanOrEqualTo(2.0));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('the preview shows the encode\'s frame', () async {
      // Decoded as the preview converts to RGB (pipeline_executor.rs,
      // preview_scale_filter, task #56 F8; the fixture is untagged, so
      // limited range): with ffmpeg's default flags the same frame read
      // 0.54 apart.
      final encoded = await _frames(filmEncode,
          vf: 'scale=in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int');
      // Near the start (the detector starts at the clip's first frame) and
      // past the window, where the preview decodes only part of the clip.
      for (final t in [3, 30, 60, 100, 140]) {
        final pv = await WorkerHarness.runPreview(filmJob.toJson(), frame: t, label: 'unblend_pv$t');
        expect(pv.success, isTrue, reason: pv.toString());
        final preview = await WorkerHarness.imageToRgb24(pv.png!, label: 'unblend_pv$t');
        // Source frame t is 50p frames [2t, 2t + 2); output m is taken from
        // 50p frame floor(m * 1001 / 480).
        final outputs = [
          for (var m = 0; m < encoded.length; m++)
            if ((m * 1001) ~/ 480 >= 2 * t && (m * 1001) ~/ 480 < 2 * t + 2) m,
        ];
        final want = outputs.isNotEmpty
            ? outputs.first
            : [for (var m = 0; m < encoded.length; m++) if ((m * 1001) ~/ 480 < 2 * t) m].last;
        final diffs = {
          for (var m = want - 2; m <= want + 2; m++)
            if (m >= 0 && m < encoded.length) m: WorkerHarness.meanAbsDiff(preview, encoded[m]),
        };
        print('  source $t -> output $want: ${diffs.map((k, v) => MapEntry(k, v.toStringAsFixed(2)))}');
        expect(diffs[want]!, lessThan(0.5), reason: 'preview of $t should be encode frame $want');
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  });
}
