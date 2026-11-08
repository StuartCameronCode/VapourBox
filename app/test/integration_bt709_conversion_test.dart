/// BT.601 -> BT.709 when an SD source is upscaled to HD (Crop & Resize, app
/// 1.7.0): the picture must look the same, and only the matrix may change.
///
/// An SD capture is BT.601. Resized to 1080 lines it used to keep its 601 tag,
/// which is correct, but a player that ignores the tag on an HD picture decodes
/// it as BT.709 and shifts greens and reds. With the conversion on, the worker
/// converts the samples in the script and declares 709 on both sides of the
/// encoder; this file checks the PICTURE, not just the tags, in the way
/// `integration_colour_tag_pixels_test.dart` does:
///
/// * the converted encode, decoded through its own tags, shows each saturated
///   patch at the RGB the source shows decoded as 601 (within 3 levels);
/// * so does the same encode decoded as 709 regardless of the tags, which is
///   what the tag-ignoring player does and the whole point of converting;
/// * with the conversion off, the tags stay 601 and the samples are the
///   source's own (within resampling of a flat patch), exactly as before;
/// * the preview of a frame shows what the encode stores.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/bt709_conversion';

const _frames = 6;
const _srcW = 720;
const _srcH = 576;

/// The patches: 75% bars, two 100% primaries, a skin tone and grey.
const _patches = <String, List<int>>{
  'red75': [191, 0, 0],
  'green75': [0, 191, 0],
  'blue75': [0, 0, 191],
  'yellow75': [191, 191, 0],
  'cyan75': [0, 191, 191],
  'magenta75': [191, 0, 191],
  'skin': [224, 172, 140],
  'grey': [128, 128, 128],
};

/// Tolerance for a converted patch against the source decoded as 601, in
/// 8-bit RGB levels: the conversion is computed in float and dithered back to
/// 8-bit 4:2:0, and both sides are rounded again on the way to RGB.
const _tolerance = 3;

Future<void> _ffmpeg(List<String> args) async {
  final r = await Process.run(WorkerHarness.ffmpegPath, ['-y', '-v', 'error', ...args],
      environment: WorkerHarness.ffmpegEnv);
  if (r.exitCode != 0) throw Exception('ffmpeg ${args.join(' ')}: ${r.stderr}');
}

/// An SD BT.601 clip of eight flat patches (4 x 2), made in RGB and converted
/// to limited-range 4:2:0 with the 601 matrix, then tagged as such.
Future<String> _makeFixture(String name, {required bool tagged}) async {
  final path = '$_outDir/$name';
  final colours = _patches.values.toList();
  final pw = _srcW ~/ 4, ph = _srcH ~/ 2;
  final inputs = <String>[];
  for (final c in colours) {
    final hex = c.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    inputs.addAll(['-f', 'lavfi', '-i', 'color=c=0x$hex:s=${pw}x$ph:r=25:d=${_frames / 25},format=rgb24']);
  }
  final graph = '[0][1][2][3]hstack=4[top];[4][5][6][7]hstack=4[bot];'
      '[top][bot]vstack,scale=out_color_matrix=bt601:out_range=tv,format=yuv420p[v]';
  await _ffmpeg([
    ...inputs,
    '-filter_complex', graph,
    '-map', '[v]',
    '-frames:v', '$_frames',
    '-c:v', 'ffv1',
    if (tagged) ...[
      '-colorspace', 'smpte170m', '-color_primaries', 'smpte170m',
      '-color_trc', 'smpte170m', '-color_range', 'tv',
    ],
    path,
  ]);
  return path;
}

/// Frame [index] of [path] as rgb24, converted with [matrix] (an swscale
/// `in_color_matrix` name) and limited range. Explicit, so "decoded through
/// its tags" and "decoded as 709 whatever the tags" are both stated rather
/// than left to ffmpeg's guess.
Future<({Uint8List rgb, int w, int h})> _decode(String path, String matrix,
    {int index = 2}) async {
  final info = (await WorkerHarness.firstStream(path,
      selector: 'v:0', entries: ['width', 'height']))!;
  final w = info['width'] as int, h = info['height'] as int;
  final out = '$_outDir/${const Uuid().v4()}.rgb';
  await _ffmpeg([
    '-i', path,
    '-vf', 'select=eq(n\\,$index),scale=in_color_matrix=$matrix:in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int+bitexact,format=rgb24',
    '-frames:v', '1', '-f', 'rawvideo', out,
  ]);
  final bytes = await File(out).readAsBytes();
  await File(out).delete();
  return (rgb: bytes, w: w, h: h);
}

/// The mean RGB of a 9x9 block at each patch's centre.
Map<String, List<double>> _patchRgb(({Uint8List rgb, int w, int h}) frame) {
  final result = <String, List<double>>{};
  final names = _patches.keys.toList();
  for (var i = 0; i < names.length; i++) {
    final cx = ((i % 4) + 0.5) * frame.w ~/ 4;
    final cy = ((i ~/ 4) + 0.5) * frame.h ~/ 2;
    final sum = [0.0, 0.0, 0.0];
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final o = ((cy + dy) * frame.w + (cx + dx)) * 3;
        for (var c = 0; c < 3; c++) {
          sum[c] += frame.rgb[o + c];
        }
      }
    }
    result[names[i]] = sum.map((s) => s / 81).toList();
  }
  return result;
}

double _maxDelta(List<double> a, List<double> b) =>
    [for (var c = 0; c < 3; c++) (a[c] - b[c]).abs()].reduce((x, y) => x > y ? x : y);

/// swscale's name for an ffprobe `color_space`.
String _swsMatrix(String? tag) => switch (tag) {
      'bt709' => 'bt709',
      'bt470bg' => 'bt470bg',
      _ => 'smpte170m',
    };

void main() {
  late String tagged;
  late String untagged480;
  late Map<String, List<double>> source601;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    tagged = await _makeFixture('sd601_patches.mkv', tagged: true);
    source601 = _patchRgb(await _decode(tagged, 'smpte170m'));
    print('  source decoded as 601: '
        '${source601.map((k, v) => MapEntry(k, v.map((x) => x.round()).toList()))}');
  });

  VideoJob job(String name, String input, Bt709Conversion mode,
      {int width = _srcW, int height = _srcH, bool sourceTagged = true, int targetH = 1080}) {
    return VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: '$_outDir/$name',
      processingPipeline: ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        cropResize: CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: targetH * 16 ~/ 9,
          targetHeight: targetH,
          maintainAspect: true,
          convertToBt709: mode,
        ),
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      totalFrames: _frames,
      inputFrameRate: 25,
      inputWidth: width,
      inputHeight: height,
      inputPixelFormat: 'yuv420p',
      inputColorMatrix: sourceTagged ? 'smpte170m' : null,
      inputColorPrimaries: sourceTagged ? 'smpte170m' : null,
      inputColorTransfer: sourceTagged ? 'smpte170m' : null,
      inputColorRange: sourceTagged ? 'tv' : null,
    );
  }

  Future<String> encode(VideoJob j) async {
    final result = await WorkerHarness.runJob(j.toJson(), label: j.outputPath);
    expect(result.success, isTrue, reason: '${result.error}\n${result.logs.join('\n')}');
    return result.outputPath ?? j.outputPath;
  }

  Future<Map<String, dynamic>> tags(String path) async =>
      (await WorkerHarness.firstStream(path, selector: 'v:0', entries: [
        'width', 'height', 'pix_fmt',
        'color_space', 'color_primaries', 'color_transfer', 'color_range',
      ]))!;

  test('converted: tagged 709, and every patch shows the source\'s colour', () async {
    final out = await encode(job('on_1080.mkv', tagged, Bt709Conversion.auto));
    final t = await tags(out);
    print('  converted output: $t');
    expect(t['height'], 1080);
    expect(t['color_space'], 'bt709');
    expect(t['color_transfer'], 'bt709');
    expect(t['color_range'], 'tv');
    expect(t['color_primaries'], 'smpte170m',
        reason: 'only the matrix is converted, so the primaries stay the source\'s');

    final viaTags = _patchRgb(await _decode(out, _swsMatrix(t['color_space'] as String?)));
    final as709 = _patchRgb(await _decode(out, 'bt709'));
    for (final name in _patches.keys) {
      final d = _maxDelta(viaTags[name]!, source601[name]!);
      print('  $name: source ${source601[name]!.map((x) => x.round()).toList()}'
          ' output ${viaTags[name]!.map((x) => x.round()).toList()}  max delta ${d.toStringAsFixed(2)}');
      expect(d, lessThanOrEqualTo(_tolerance), reason: '$name through the output\'s tags');
      expect(_maxDelta(as709[name]!, source601[name]!), lessThanOrEqualTo(_tolerance),
          reason: '$name decoded as 709 by a player that ignores the tag');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('off: tags stay 601 and the samples are the source\'s', () async {
    final out = await encode(job('off_1080.mkv', tagged, Bt709Conversion.off));
    final t = await tags(out);
    print('  unconverted output: $t');
    expect(t['height'], 1080);
    expect(t['color_space'], 'smpte170m');
    expect(t['color_primaries'], 'smpte170m');
    // Decoded through its (601) tags: the source's colours, as before 1.7.0.
    final viaTags = _patchRgb(await _decode(out, 'smpte170m'));
    // The samples themselves are the source's: a flat patch survives a resize
    // unchanged, so decoding both as 601 must agree to rounding.
    for (final name in _patches.keys) {
      expect(_maxDelta(viaTags[name]!, source601[name]!), lessThanOrEqualTo(1.0), reason: name);
    }
    // The problem the conversion exists for: the same file read as 709.
    final misread = _patchRgb(await _decode(out, 'bt709'));
    final worst = _patches.keys
        .map((n) => (n, _maxDelta(misread[n]!, source601[n]!)))
        .reduce((a, b) => a.$2 > b.$2 ? a : b);
    print('  unconverted, read as 709: worst ${worst.$1} off by ${worst.$2.toStringAsFixed(1)}');
    expect(worst.$2, greaterThan(15),
        reason: 'control: reading 601 samples as 709 must visibly shift colour');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('an SD-sized output under Auto is left alone', () async {
    // A 700-line box: 875x700, under both HD thresholds.
    final sd = job('auto_sd.mkv', tagged, Bt709Conversion.auto, targetH: 700);
    final out = await encode(sd);
    final t = await tags(out);
    expect(t['height'], lessThan(720));
    expect(t['color_space'], 'smpte170m');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('untagged NTSC-sized source: read as 601, tagged with NTSC primaries', () async {
    untagged480 = '$_outDir/sd601_untagged_480.mkv';
    await _ffmpeg(['-i', tagged, '-vf', 'scale=720:480:flags=neighbor', '-c:v', 'ffv1', untagged480]);
    final out = await encode(job('untagged_480.mkv', untagged480, Bt709Conversion.auto,
        height: 480, sourceTagged: false));
    final t = await tags(out);
    print('  untagged 480 output: $t');
    expect(t['color_space'], 'bt709');
    expect(t['color_primaries'], 'smpte170m');
    final viaTags = _patchRgb(await _decode(out, 'bt709'));
    final src = _patchRgb(await _decode(untagged480, 'smpte170m'));
    for (final name in _patches.keys) {
      expect(_maxDelta(viaTags[name]!, src[name]!), lessThanOrEqualTo(_tolerance), reason: name);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the preview shows what the converted encode stores', () async {
    final j = job('on_preview.mkv', tagged, Bt709Conversion.auto);
    final out = await encode(j);
    const frame = 2;
    final preview = await WorkerHarness.runPreview(j.toJson(), frame: frame);
    expect(preview.success, isTrue, reason: '$preview');
    final previewRgb = await WorkerHarness.imageToRgb24(preview.png!, label: 'pv709');
    // Decoded the way ffmpeg decodes it by default, through the file's tags:
    // the preview's own YUV-to-RGB step uses swscale's default path too, so
    // the two are compared like for like (the accurate path above differs
    // from the default one by ~1.5/255 on this content, in both directions).
    final encoded = await WorkerHarness.frameRgb24(out, frame, label: 'enc709');
    final diff = WorkerHarness.meanAbsDiff(previewRgb, encoded);
    print('  preview vs encode mean abs diff: ${diff.toStringAsFixed(3)}/255');
    expect(diff, lessThan(1.0), reason: 'the preview shows different colours from the encode');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
