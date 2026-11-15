/// Full-encode tests for task #33: Soft Telecine's film frames are progressive
/// (docs/reports/issue-33-soft-telecine-field-based).
///
/// A bare `vivtc.VDecimate` used to keep the `_FieldBased=2` the source
/// marking stamped, so every later zimg resize resampled each film frame's
/// 4:2:0 chroma as two fields. The worker now leaves Soft Telecine unmarked.
/// What only a real encode can show:
///   * the Color Format conversion to 4:2:2 equals a progressive conversion of
///     the same frames (ffmpeg's zscale, the same zimg kernel), and is far
///     from a per-field one;
///   * ProRes (whose 4:2:2 conversion happens in the script) is written with a
///     progressive `fiel` atom, at the decimated length;
///   * the preview converts the same way, frame for frame.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => p.join(WorkerHarness.outputDir, 'soft_telecine_field_based');

/// MPEG-2 352x240 4:2:0 with soft pulldown: 150 frames at 29.97 decode to
/// 120 film frames once VDecimate removes the repeats.
String get _source =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'soft_telecine_dvd.mkv');
const _w = 352;
const _h = 240;
const _decoded = 150;
const _film = 120;

Map<String, dynamic> _job(String name, VideoCodec codec, ContainerFormat container,
    ChromaSubsampling cs) {
  const deinterlace = QTGMCParameters(
      enabled: true, method: DeinterlaceMethod.softTelecine, tff: true);
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: _source,
    outputPath: p.join(_outDir, '$name.${container.extension}'),
    qtgmcParameters: deinterlace,
    processingPipeline: const ProcessingPipeline(deinterlace: deinterlace),
    encodingSettings: EncodingSettings(
      codec: codec,
      container: container,
      audioMode: AudioMode.none,
      chromaSubsampling: cs,
    ),
    // What the app's analysis says for this fixture's MPEG-2 field flag; the
    // marking used to come from the pass's tff regardless.
    detectedFieldOrder: FieldOrder.topFieldFirst,
    totalFrames: _decoded,
    inputFrameRate: 30000 / 1001,
    inputWidth: _w,
    inputHeight: _h,
    inputPixelFormat: 'yuv420p',
  ).toJson();
}

Future<String> _encode(String name, VideoCodec codec, ContainerFormat container,
    ChromaSubsampling cs) async {
  final job = _job(name, codec, container, cs);
  final result = await WorkerHarness.runJob(job, label: name);
  if (!result.success) {
    print(result.logs.reversed.take(30).toList().reversed.join('\n'));
  }
  expect(result.success, isTrue, reason: '$name: ${result.error}');
  return job['outputPath'] as String;
}

/// Every frame of [path] as raw planar bytes, after [vf] (if any).
Future<Uint8List> _raw(String path, String pixFmt, {String? vf}) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, if (vf != null) ...['-vf', vf],
     '-f', 'rawvideo', '-pix_fmt', pixFmt, '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(r.exitCode, 0, reason: 'decode $path: ${r.stderr}');
  return Uint8List.fromList(r.stdout as List<int>);
}

/// Mean absolute difference, in 8-bit levels, of the chroma planes of two
/// yuv422p frame sequences of the same size.
double _chromaMad(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  const luma = _w * _h;
  const frame = luma * 2;
  var sum = 0, n = 0;
  for (var f = 0; f + frame <= a.length; f += frame) {
    for (var i = f + luma; i < f + frame; i++) {
      sum += (a[i] - b[i]).abs();
      n++;
    }
  }
  return sum / n;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  test('4:2:2 Color Format converts the film frames progressively', () async {
    final as420 = await _encode('st_420', VideoCodec.ffv1, ContainerFormat.mkv,
        ChromaSubsampling.original);
    final as422 = await _encode('st_422', VideoCodec.ffv1, ContainerFormat.mkv,
        ChromaSubsampling.yuv422);

    final out = await _raw(as422, 'yuv422p');
    expect(out.length, _film * _w * _h * 2, reason: 'decimated to the film frames');

    // References from the lossless 4:2:0 encode of the same job, so the
    // frames are the same ones. zscale's bicubic is zimg's, as resize.Bicubic.
    final progressive = await _raw(as420, 'yuv422p',
        vf: 'zscale=filter=bicubic,format=yuv422p');
    // A per-field conversion, only to show the fixture tells the two apart.
    // (The old script's per-field result was not this one exactly: its
    // field chroma siting differs from zscale's, 4.8 levels from it.)
    final perField = await _raw(as420, 'yuv422p',
        vf: 'separatefields,zscale=filter=bicubic,format=yuv422p,weave=first_field=top');

    final toProgressive = _chromaMad(out, progressive);
    final toPerField = _chromaMad(out, perField);
    final between = _chromaMad(progressive, perField);
    print('chroma MAD: output vs progressive ${toProgressive.toStringAsFixed(3)}, '
        'vs per-field ${toPerField.toStringAsFixed(3)}, '
        'progressive vs per-field ${between.toStringAsFixed(3)}');
    expect(between, greaterThan(1.0), reason: 'the fixture must tell them apart');
    // Measured: 0.049 now; 2.505 while the frames were marked TFF.
    expect(toProgressive, lessThan(0.5));
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('ProRes HQ is written progressive at the film length', () async {
    final out = await _encode('st_prores_hq', VideoCodec.proresHQ,
        ContainerFormat.mov, ChromaSubsampling.original);
    final s = await WorkerHarness.firstStream(out,
        selector: 'v:0', entries: ['pix_fmt', 'height', 'field_order', 'nb_frames']);
    expect(s!['pix_fmt'], 'yuv422p10le');
    expect('${s['height']}', '$_h');
    expect('${s['nb_frames']}', '$_film');
    expect(s['field_order'], anyOf(isNull, 'progressive'));
    expect(WorkerHarness.movFielAtom(out), anyOf(isNull, '0100'));
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('the preview converts like the encode', () async {
    // The preview has no VDecimate (it shows source frame N), so compare its
    // 4:2:2 conversion with its own unconverted frame: both progressive, the
    // two differ only by the chroma kernel. Per field they differed far more.
    const frame = 40;
    final converted = await WorkerHarness.runPreview(
        _job('st_pv_422', VideoCodec.ffv1, ContainerFormat.mkv,
            ChromaSubsampling.yuv422),
        frame: frame,
        label: 'st_pv_422');
    final plain = await WorkerHarness.runPreview(
        _job('st_pv_420', VideoCodec.ffv1, ContainerFormat.mkv,
            ChromaSubsampling.original),
        frame: frame,
        label: 'st_pv_420');
    expect(converted.success, isTrue, reason: converted.error);
    expect(plain.success, isTrue, reason: plain.error);
    final mad = WorkerHarness.meanAbsDiff(
        await WorkerHarness.imageToRgb24(converted.png!, label: 'st_pv_422'),
        await WorkerHarness.imageToRgb24(plain.png!, label: 'st_pv_420'));
    print('preview RGB MAD, 4:2:2 vs original: ${mad.toStringAsFixed(3)}');
    expect(mad, lessThan(_previewLimit));
  }, timeout: const Timeout(Duration(minutes: 4)));
}

/// Measured at frame 40: 1.08 now, 2.85 while the frames were marked TFF.
const _previewLimit = 1.5;
