// Real-ESRGAN / Real-CUGAN / AnimeJaNai upscaling, encoded end to end and
// checked by pixels. AnimeJaNai's models are an add-on, which the harness
// installs from the upstream download the app pins.
//
// Wherever AI upscaling ships, CI gives the runner a Vulkan device (a software
// one, lavapipe, on the GPU-less Linux and Windows runners) and sets
// VAPOURBOX_EXPECT_VULKAN=1, so these must run there; see
// support/gpu_expectations.dart. The source is the small progressive clip
// (320x240) and each job encodes five frames, so even 4x CUGAN on a CPU Vulkan
// driver finishes in minutes. It must be progressive: on a combed source the
// networks rightly remove the combing, and that difference from Spline36 —
// real detail at the source's own resolution — would swamp the comparison.
//
// What is checked, per method and factor:
//   * size and frame count — an upscale changes the size, never the count;
//   * on real footage, the network ran (the result is not plain resampling)
//     and stays close to a Spline36 upscale of the same frames — a loose sanity
//     bound only: Real-ESRGAN 2x legitimately redraws ~5 levels' worth, and
//     this clip has duplicate frames, so it cannot prove colour or position;
//   * on a synthetic pattern, which can: a white bar's centre stays where
//     Spline36 puts it (within 0.75 of an output pixel, both axes) for every
//     model — the networks widen a hard edge by up to ~1.5 px each side, which
//     moves either edge on its own but not the centre — and flat colour
//     patches keep their colour. Real-CUGAN 2x reproduces flat colour to under
//     a level, and every method shares the template's conversions, so it is
//     the strict check of the matrix and range (a mix-up moves these patches
//     5-20 levels). Real-ESRGAN measurably tints and saturates flat colour
//     (measured up to 3 levels at 2x and 11 at 4x, in fp32 too, with vs-mlrt's
//     own wrapper doing nothing more than this template — the model, not the
//     pipeline) and CUGAN 4x drifts ~4, so those get bounds just above that.
//     AnimeJaNai keeps flat colour within half a level at 2x and 4x (measured
//     0.3 and 0.5), so it gets the strictest bound;
//   * the preview of a frame is the encode's frame (the same script runs);
//   * a 10-bit source stays 10-bit and matches the 8-bit result;
//   * AnimeJaNai picks its SD model for an SD picture (where the HD size
//     setting changes nothing) and the chosen HD model above 576 lines.
@Tags(['heavy'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/gpu_expectations.dart';
import 'support/worker_harness.dart';

const _start = 100;
const _w = 320, _h = 240;
String get _input => p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'small_clip.mp4');
const _frames = 5;
String get _outDir => p.join(WorkerHarness.outputDir, 'ai_upscale');

VideoJob _job(String name, UpscaleMethod method, int factor,
        {String noise = 'conservative',
        String? input,
        String pixFmt = 'yuv420p',
        String animejanaiModel = 'compact'}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input ?? _input,
      outputPath: p.join(_outDir, '$name.mkv'),
      processingPipeline: ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        cropResize: CropResizeParameters(
          enabled: true,
          useIntegerUpscale: true,
          upscaleMethod: method,
          upscaleFactor: factor,
          cuganNoise: noise,
          animejanaiModel: animejanaiModel,
        ),
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      inputWidth: _w,
      inputHeight: _h,
      inputPixelFormat: pixFmt,
      inputFrameRate: 29.97,
      // The post-trim count: the decoder pipes exactly these frames.
      startFrame: _start,
      endFrame: _start + _frames - 1,
      totalFrames: _frames,
    );

Future<String> _encode(VideoJob job, String label) async {
  final r = await WorkerHarness.runJob(job.toJson(), label: label,
      timeout: const Duration(minutes: 20));
  expect(r.success, isTrue, reason: '$label: ${r.error}\n${r.logs.join('\n')}');
  return r.outputPath!;
}

/// Frame [index] of [path], area-downscaled to the source size.
Future<Uint8List> _atSourceSize(String path, int index, String label) async {
  final png = File(p.join(Directory.systemTemp.path,
      'vb_${label}_${DateTime.now().microsecondsSinceEpoch}.png'));
  try {
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      ['-y', '-v', 'error', '-i', path,
        '-vf', 'select=eq(n\\,$index),scale=$_w:$_h:flags=area', '-frames:v', '1', png.path],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return WorkerHarness.imageToRgb24(await png.readAsBytes(), label: label);
  } finally {
    if (await png.exists()) await png.delete();
  }
}

Future<Map<String, dynamic>> _stream(String path) async =>
    (await WorkerHarness.firstStream(path,
        selector: 'v:0',
        entries: ['width', 'height', 'pix_fmt', 'nb_read_frames'],
        countFrames: true))!;

void main() {
  // One Spline36 reference per factor, shared by every method at that factor.
  final references = <int, Future<String>>{};
  Future<String> reference(int factor) => references.putIfAbsent(
      factor,
      () => _encode(_job('spline36_${factor}x', UpscaleMethod.spline36, factor),
          'spline36_${factor}x'));

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    // ignore: avoid_print
    print('AI upscaling on $platformId (expect Vulkan: $expectVulkan)');
  });

  final cases = <(UpscaleMethod, int, String)>[
    (UpscaleMethod.realEsrgan, 2, 'conservative'),
    (UpscaleMethod.realEsrgan, 4, 'conservative'),
    (UpscaleMethod.realCugan, 2, 'none'),
    (UpscaleMethod.realCugan, 2, 'conservative'),
    (UpscaleMethod.realCugan, 2, 'denoise3x'),
    (UpscaleMethod.realCugan, 4, 'conservative'),
    (UpscaleMethod.animeJanai, 2, ''),
    (UpscaleMethod.animeJanai, 4, ''),
  ];

  /// The rule, plus AnimeJaNai's add-on where the method needs it.
  Future<bool> ready(UpscaleMethod method) async {
    if (!await requireGpuPlugin('--probe-upscale')) return false;
    if (method == UpscaleMethod.animeJanai) await WorkerHarness.ensureAnimeJanai();
    return true;
  }

  for (final (method, factor, noise) in cases) {
    final name = '${method.name}_${factor}x${method == UpscaleMethod.realCugan ? '_$noise' : ''}';
    test(name, () async {
      if (!await ready(method)) return;
      final job = _job(name, method, factor, noise: noise);
      final out = await _encode(job, name);

      final s = await _stream(out);
      expect(s['width'], _w * factor);
      expect(s['height'], _h * factor);
      expect(s['pix_fmt'], 'yuv420p');
      expect(int.parse('${s['nb_read_frames']}'), _frames,
          reason: 'an upscale must not change the frame count');

      // The picture is the source's, and the network changed it.
      final ref = await reference(factor);
      for (final i in [0, 2, 4]) {
        final small = WorkerHarness.meanAbsDiff(
            await _atSourceSize(out, i, '${name}_s$i'),
            await _atSourceSize(ref, i, 'ref${factor}_s$i'));
        final full = WorkerHarness.meanAbsDiff(
            await WorkerHarness.frameRgb24(out, i, label: '${name}_$i'),
            await WorkerHarness.frameRgb24(ref, i, label: 'ref${factor}_$i'));
        // ignore: avoid_print
        print('  $name frame $i vs Spline36: at source size ${small.toStringAsFixed(2)}, '
            'full size ${full.toStringAsFixed(2)}');
        expect(small, lessThan(8.0), reason: 'frame $i is not the same picture as the source');
        expect(full, greaterThan(0.5), reason: 'frame $i is plain resampling: no network ran');
      }

      // The preview runs the same script on the same frame.
      final pv = await WorkerHarness.runPreview(job.toJson(),
          frame: _start + 2, label: '${name}_pv');
      expect(pv.success, isTrue, reason: pv.errorTail);
      final pvDiff = WorkerHarness.meanAbsDiff(
          await WorkerHarness.imageToRgb24(pv.png!, label: '${name}_pv'),
          await WorkerHarness.frameRgb24(out, 2, label: '${name}_enc2'));
      // ignore: avoid_print
      print('  $name preview vs encode: meanAbsDiff ${pvDiff.toStringAsFixed(2)}');
      expect(pvDiff, lessThan(1.0), reason: 'the preview is not the encoded picture');
    }, timeout: const Timeout(Duration(minutes: 30)));
  }

  // Flat patches keep their colour and a hard edge keeps its position — the
  // two things a wrong matrix, range or offset would break.
  group('synthetic pattern', () {
    late String pattern;
    // Mid-saturation colours: nothing clips, so a range mix-up (which moves a
    // channel ~10 levels here) or a BT.601/709 mix-up (5-20) cannot hide at
    // 0 or 255, where the networks also roll off by a few levels.
    const patches = <String, (int, int)>{
      '0xB04030': (16, 16), '0x30A050': (96, 16), '0x4060C0': (176, 16),
      '0xC0B040': (16, 120), '0x40B0B0': (96, 120), '0xA040A0': (176, 120),
    };
    const patch = 64, barX = 256;

    setUpAll(() async {
      pattern = p.join(_outDir, 'pattern.mkv');
      final boxes = [
        for (final MapEntry(key: c, value: (x, y)) in patches.entries)
          'drawbox=x=$x:y=$y:w=$patch:h=$patch:color=$c@1:t=fill',
        'drawbox=x=$barX:y=40:w=48:h=160:color=white@1:t=fill',
      ].join(',');
      final r = await Process.run(
        WorkerHarness.ffmpegPath,
        ['-y', '-v', 'error', '-f', 'lavfi',
          '-i', 'color=c=0x808080:s=${_w}x$_h:r=25:d=0.4,format=yuv420p,$boxes',
          '-c:v', 'ffv1', pattern],
        environment: WorkerHarness.ffmpegEnv,
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });

    VideoJob patternJob(String name, UpscaleMethod method, int factor) {
      final j = _job(name, method, factor, input: pattern);
      return VideoJob.fromJson({
        ...j.toJson(),
        'inputFrameRate': 25.0,
        'startFrame': 2,
        'endFrame': 4,
        'totalFrames': 3,
      });
    }

    /// Mean RGB over a square region (output pixels), inset to avoid edges.
    List<double> meanRgb(Uint8List rgb, int width, int x0, int y0, int size) {
      final sums = [0.0, 0.0, 0.0];
      var n = 0;
      for (var y = y0; y < y0 + size; y++) {
        for (var x = x0; x < x0 + size; x++) {
          final i = (y * width + x) * 3;
          for (var c = 0; c < 3; c++) {
            sums[c] += rgb[i + c];
          }
          n++;
        }
      }
      return [for (final v in sums) v / n];
    }

    /// Where a line of luminance samples crosses half-way between its two
    /// ends, to sub-pixel precision: an edge's position.
    double crossing(double Function(int) lum, int from, int to) {
      final mid = (lum(from) + lum(to)) / 2;
      final rising = lum(to) > lum(from);
      for (var i = from; i < to; i++) {
        final a = lum(i), b = lum(i + 1);
        if (rising ? (a < mid && b >= mid) : (a >= mid && b < mid)) {
          return i + (mid - a) / (b - a);
        }
      }
      return double.nan;
    }

    /// The white bar's (left, right, top, bottom) edges in an output frame.
    (double, double, double, double) barEdges(Uint8List rgb, int factor) {
      final w = _w * factor;
      double at(int x, int y) {
        final i = (y * w + x) * 3;
        return (rgb[i] + rgb[i + 1] + rgb[i + 2]) / 3;
      }
      final row = 120 * factor, col = (barX + 24) * factor, r = 16 * factor;
      return (
        crossing((x) => at(x, row), barX * factor - r, barX * factor + r),
        crossing((x) => at(x, row), (barX + 48) * factor - r, (barX + 48) * factor + r),
        crossing((y) => at(col, y), 40 * factor - r, 40 * factor + r),
        crossing((y) => at(col, y), 200 * factor - r, 200 * factor + r),
      );
    }

    for (final (method, factor, colourTolerance) in [
      (UpscaleMethod.realEsrgan, 2, 6.0), (UpscaleMethod.realEsrgan, 4, 14.0),
      (UpscaleMethod.realCugan, 2, 2.0), (UpscaleMethod.realCugan, 4, 6.0),
      (UpscaleMethod.animeJanai, 2, 1.0), (UpscaleMethod.animeJanai, 4, 1.0),
    ]) {
      test('${method.name} ${factor}x keeps colour and position', () async {
        if (!await ready(method)) return;
        final name = 'pattern_${method.name}_${factor}x';
        final out = await _encode(patternJob(name, method, factor), name);
        final ref = await _encode(
            patternJob('pattern_spline36_${factor}x', UpscaleMethod.spline36, factor),
            'pattern_spline36_${factor}x');
        final w = _w * factor;
        final a = await WorkerHarness.frameRgb24(out, 1, label: '${name}_1');
        final b = await WorkerHarness.frameRgb24(ref, 1, label: 'pref${factor}_1');

        final inset = 12 * factor, size = (patch * factor) - 2 * inset;
        for (final MapEntry(key: c, value: (x, y)) in patches.entries) {
          final ma = meanRgb(a, w, x * factor + inset, y * factor + inset, size);
          final mb = meanRgb(b, w, x * factor + inset, y * factor + inset, size);
          final worst = [for (var i = 0; i < 3; i++) (ma[i] - mb[i]).abs()]
              .reduce((p, q) => p > q ? p : q);
          // ignore: avoid_print
          print('  $name $c: ${ma.map((v) => v.toStringAsFixed(1)).toList()} '
              'vs ${mb.map((v) => v.toStringAsFixed(1)).toList()}');
          expect(worst, lessThan(colourTolerance), reason: '$c patch changed colour');
        }

        final (l, rt, t, bt) = barEdges(a, factor);
        final (rl, rr, rtop, rb) = barEdges(b, factor);
        final cx = (l + rt) / 2, cy = (t + bt) / 2;
        final rcx = (rl + rr) / 2, rcy = (rtop + rb) / 2;
        // ignore: avoid_print
        print('  $name bar centre (${cx.toStringAsFixed(2)}, ${cy.toStringAsFixed(2)}) '
            'width ${(rt - l).toStringAsFixed(2)}; Spline36 (${rcx.toStringAsFixed(2)}, '
            '${rcy.toStringAsFixed(2)}) width ${(rr - rl).toStringAsFixed(2)}');
        expect((cx - rcx).abs(), lessThan(0.75), reason: 'the picture moved horizontally');
        expect((cy - rcy).abs(), lessThan(0.75), reason: 'the picture moved vertically');
        // Spline36 itself lands on factor x source: the reference is right.
        expect((rcx - ((barX + 24) * factor - 0.5)).abs(), lessThan(0.25));
        expect(((rt - l) - (rr - rl)).abs(), lessThan(4.0), reason: 'the bar changed size');
      }, timeout: const Timeout(Duration(minutes: 30)));
    }
  });

  test('a 10-bit source stays 10-bit and matches the 8-bit result', () async {
    if (!await requireGpuPlugin('--probe-upscale')) return;
    // Both fixtures from the same conversion, so frame N is the same picture
    // in each (the AVI's own frame count differs between decoders).
    final sources = <String, String>{};
    for (final fmt in ['yuv420p', 'yuv420p10le']) {
      final path = p.join(_outDir, 'source_$fmt.mkv');
      final made = await Process.run(
        WorkerHarness.ffmpegPath,
        ['-y', '-v', 'error', '-i', _input, '-frames:v', '200', '-pix_fmt', fmt,
          '-c:v', 'ffv1', path],
        environment: WorkerHarness.ffmpegEnv,
      );
      expect(made.exitCode, 0, reason: '${made.stderr}');
      sources[fmt] = path;
    }

    final eight = await _encode(
        _job('esrgan_8bit', UpscaleMethod.realEsrgan, 2, input: sources['yuv420p']),
        'esrgan_8bit');
    final ten = await _encode(
        _job('esrgan_10bit', UpscaleMethod.realEsrgan, 2,
            input: sources['yuv420p10le'], pixFmt: 'yuv420p10le'),
        'esrgan_10bit');
    expect((await _stream(ten))['pix_fmt'], 'yuv420p10le');
    final Uint8List a = await WorkerHarness.frameRgb24(eight, 2, label: 'esrgan8');
    final Uint8List b = await WorkerHarness.frameRgb24(ten, 2, label: 'esrgan10');
    final diff = WorkerHarness.meanAbsDiff(a, b);
    // ignore: avoid_print
    print('  8-bit vs 10-bit: meanAbsDiff ${diff.toStringAsFixed(2)}');
    expect(diff, lessThan(2.0), reason: 'the 10-bit path is not the same picture');
  }, timeout: const Timeout(Duration(minutes: 30)));

  // The script chooses AnimeJaNai's model by height. On an SD picture it is
  // always the SD model, so the HD size setting changes nothing; above 576
  // lines it is the chosen HD model, so two sizes give two pictures. One
  // preview frame each, so a CPU Vulkan driver gets through 720p quickly.
  test('AnimeJaNai uses its SD model up to 576 lines and the chosen HD model above', () async {
    if (!await ready(UpscaleMethod.animeJanai)) return;
    final hd = p.join(_outDir, 'source_720p.mkv');
    final made = await Process.run(
      WorkerHarness.ffmpegPath,
      ['-y', '-v', 'error', '-i', _input, '-frames:v', '120', '-vf', 'scale=1280:720',
        '-c:v', 'ffv1', hd],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(made.exitCode, 0, reason: '${made.stderr}');

    Future<Uint8List> frame(String label, String model, {String? input}) async {
      var j = _job(label, UpscaleMethod.animeJanai, 2, input: input, animejanaiModel: model);
      if (input != null) {
        j = VideoJob.fromJson(
            {...j.toJson(), 'inputWidth': 1280, 'inputHeight': 720, 'startFrame': 100});
      }
      final pv = await WorkerHarness.runPreview(j.toJson(), frame: _start + 2, label: label);
      expect(pv.success, isTrue, reason: pv.errorTail);
      return WorkerHarness.imageToRgb24(pv.png!, label: label);
    }

    final sdCompact = await frame('ajn_sd_compact', 'compact');
    final sdTiny = await frame('ajn_sd_suc', 'superUltraCompact');
    final hdCompact = await frame('ajn_hd_compact', 'compact', input: hd);
    final hdTiny = await frame('ajn_hd_suc', 'superUltraCompact', input: hd);
    final sd = WorkerHarness.meanAbsDiff(sdCompact, sdTiny);
    final hdDiff = WorkerHarness.meanAbsDiff(hdCompact, hdTiny);
    // ignore: avoid_print
    print('  AnimeJaNai Compact vs SuperUltraCompact: SD ${sd.toStringAsFixed(3)}, '
        'HD ${hdDiff.toStringAsFixed(3)}');
    expect(sd, lessThan(0.01), reason: 'an SD picture did not use the SD model');
    expect(hdDiff, greaterThan(0.2), reason: 'a 720p picture did not use the chosen HD model');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
