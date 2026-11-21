/// Sources stored off their chroma grid (task #97).
///
/// A 4:2:0 frame with an odd width or height, or 4:2:2 with an odd width, is
/// stored by FFV1, rawvideo, Y4M, VP9, AV1, MJPEG, ProRes and others, but
/// VapourSynth refuses a clip of that format and size, so every preview and
/// encode of one failed ("BlankClip: invalid height"). pipe_source now pads
/// it onto the grid, repeating its last column / row, and the encoder crops
/// it back where it can store the size (`VideoJob::grid_output`). These
/// encode real fixtures and check what only a run can show: the encode is
/// the source sample for sample, the preview is the encode, and an encoder
/// that can't store the size gets the next size up.
///
/// Heavy (full-encode): nightly, not the push gate.
/// See docs/reports/task-97-off-grid-sources.
@Tags(['heavy'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/off_grid';

/// A testsrc2 picture scaled to [w]x[h] in [pixFmt] (testsrc2's own `s=`
/// rounds the size down to the grid, so it never makes one), FFV1 in MKV.
Future<String> _fixture(int w, int h, String pixFmt, {List<String> extra = const []}) async {
  final path = '$_outDir/src_${w}x${h}_$pixFmt${extra.isEmpty ? '' : '_tagged'}.mkv';
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc2=s=256x192:r=25:d=0.4',
      '-vf', 'scale=$w:$h,format=$pixFmt',
      ...extra,
      '-c:v', 'ffv1', path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'fixture: ${r.stderr}');
  return path;
}

Map<String, dynamic> _job(
  String name,
  String input,
  int w,
  int h,
  String pixFmt, {
  VideoCodec codec = VideoCodec.ffv1,
  ContainerFormat container = ContainerFormat.mkv,
  ChromaSubsampling chroma = ChromaSubsampling.original,
  ProcessingPipeline? pipeline,
  FieldOrder? fieldOrder,
}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: input,
    outputPath: '$_outDir/$name.${container.extension}',
    processingPipeline: pipeline ??
        const ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false)),
    encodingSettings: EncodingSettings(
      codec: codec,
      container: container,
      chromaSubsampling: chroma,
      audioMode: AudioMode.none,
    ),
    inputWidth: w,
    inputHeight: h,
    inputPixelFormat: pixFmt,
    inputFrameRate: 25.0,
    detectedFieldOrder: fieldOrder,
  ).toJson();
}

Future<(int, int, String)> _stream(String path) async {
  final s = (await WorkerHarness.firstStream(path, selector: 'v:0', entries: ['width', 'height', 'pix_fmt']))!;
  return (s['width'] as int, s['height'] as int, s['pix_fmt'] as String);
}

/// Every frame's hash, decoded as [pixFmt].
Future<List<String>> _frameHashes(String path, String pixFmt) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, '-pix_fmt', pixFmt, '-f', 'framemd5', '-'],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return [
    for (final line in (r.stdout as String).split('\n'))
      if (line.trim().isNotEmpty && !line.startsWith('#')) line.split(',').last.trim(),
  ];
}

/// The same picture on its chroma grid: [src] decoded to raw planes (FFmpeg
/// stores chroma rounded up: 32x17 for 63x33 4:2:0), its luma padded here
/// by repeating the last column / row, encoded as FFV1 at the padded size.
/// Converted to RGB and cropped back, it is the reference a preview of
/// [src] is held to: FFmpeg's own conversion of an off-grid 4:2:0 frame
/// spreads 17 chroma rows over 33 luma rows (a vertical stretch, 4-8 levels
/// on testsrc2), and its `pad` drops an odd width's last column, so neither
/// can stand in for it.
Future<String> _onGridTwin(String src, int w, int h, String fmt, int sw, int sh, int bps) async {
  final pw = (w + sw - 1) ~/ sw * sw, ph = (h + sh - 1) ~/ sh * sh;
  final cw = pw ~/ sw, ch = ph ~/ sh;
  final raw = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', src, '-f', 'rawvideo', '-pix_fmt', fmt, '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(raw.exitCode, 0, reason: '${raw.stderr}');
  final bytes = raw.stdout as List<int>;
  final frameIn = (w * h + 2 * cw * ch) * bps;
  final frames = bytes.length ~/ frameIn;
  final out = BytesBuilder();
  for (var f = 0; f < frames; f++) {
    final base = f * frameIn;
    for (var y = 0; y < ph; y++) {
      final sy = y < h ? y : h - 1;
      final row = base + sy * w * bps;
      out.add(bytes.sublist(row, row + w * bps));
      for (var x = w; x < pw; x++) {
        out.add(bytes.sublist(row + (w - 1) * bps, row + w * bps));
      }
    }
    out.add(bytes.sublist(base + w * h * bps, base + frameIn));
  }
  final rawPath = '$src.ongrid.raw';
  File(rawPath).writeAsBytesSync(out.takeBytes());
  final twin = '$src.ongrid.mkv';
  final enc = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', fmt, '-s', '${pw}x$ph', '-r', '25',
      '-i', rawPath, '-c:v', 'ffv1', twin,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(enc.exitCode, 0, reason: '${enc.stderr}');
  return twin;
}

/// [rgb] (packed rgb24, [fromW] wide) cropped to its top-left [w]x[h].
Uint8List _cropRgb(Uint8List rgb, int fromW, int w, int h) {
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    out.setRange(y * w * 3, (y + 1) * w * 3, rgb, y * fromW * 3);
  }
  return out;
}

Future<JobResult> _run(Map<String, dynamic> job, String label) async {
  final r = await WorkerHarness.runJob(job, label: label);
  expect(r.success, isTrue, reason: '$label: ${r.error}\n${r.logs.reversed.take(20).join('\n')}');
  return r;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    Directory(_outDir).createSync(recursive: true);
  });

  for (final (w, h, fmt) in [
    (64, 33, 'yuv420p'),
    (63, 32, 'yuv420p'),
    (63, 32, 'yuv422p'),
    (63, 33, 'yuv420p10le'),
  ]) {
    test('${w}x$h $fmt: the encode is the source, the preview is the encode', () async {
      final src = await _fixture(w, h, fmt);
      final job = _job('ffv1_${w}x${h}_$fmt', src, w, h, fmt);
      final r = await _run(job, 'ffv1 ${w}x$h $fmt');
      final out = r.outputPath ?? job['outputPath'] as String;
      expect(await _stream(out), (w, h, fmt));
      expect(await _frameHashes(out, fmt), await _frameHashes(src, fmt),
          reason: 'every stored sample comes through');
      expect(r.logs.join('\n'), contains('The encoder crops it back to ${w}x$h.'));

      final preview = await WorkerHarness.runPreview(job, frame: 3);
      expect(preview.success, isTrue, reason: preview.errorTail);
      final shown = await WorkerHarness.imageToRgb24(preview.png!);
      final (sw, sh) = fmt.startsWith('yuv420') ? (2, 2) : (2, 1);
      final twin = await _onGridTwin(out, w, h, fmt, sw, sh, fmt.endsWith('10le') ? 2 : 1);
      final pw = (w + sw - 1) ~/ sw * sw;
      final reference = _cropRgb(await WorkerHarness.previewFrameRgb24(twin, 3), pw, w, h);
      expect(WorkerHarness.meanAbsDiff(shown, reference), lessThan(0.5),
          reason: 'preview = encode, at the stored size');
    });
  }

  test('H.264 cannot store 63x33 4:2:0: the output is 64x34, and the log says so', () async {
    final src = await _fixture(63, 33, 'yuv420p');
    final r = await _run(
        _job('x264_63x33', src, 63, 33, 'yuv420p',
            codec: VideoCodec.h264, container: ContainerFormat.mp4),
        'x264');
    final (ow, oh, _) = await _stream(r.outputPath!);
    expect((ow, oh), (64, 34));
    expect(r.logs.join('\n'), contains("H.264 can't store 63x33 in yuv420p, so the output is 64x34"));
  });

  test('a 63x33 4:4:4 source as 4:2:0 output keeps 63x33', () async {
    final src = await _fixture(63, 33, 'yuv444p');
    final r = await _run(
        _job('444to420', src, 63, 33, 'yuv444p', chroma: ChromaSubsampling.yuv420), '444 -> 420');
    expect(await _stream(r.outputPath!), (63, 33, 'yuv420p'));
  });

  test('a pass, crops and a resize run on an off-grid source', () async {
    final src = await _fixture(63, 33, 'yuv420p10le');
    final denoise = await _run(
        _job('denoise', src, 63, 33, 'yuv420p10le',
            pipeline: const ProcessingPipeline(
              deinterlace: QTGMCParameters(enabled: false),
              noiseReduction: NoiseReductionParameters(enabled: true),
            )),
        'denoise');
    expect(await _stream(denoise.outputPath!), (63, 33, 'yuv420p10le'));

    ProcessingPipeline crop(int l, int r, int t, int b) => ProcessingPipeline(
          deinterlace: const QTGMCParameters(enabled: false),
          cropResize: CropResizeParameters(
              enabled: true, cropEnabled: true, cropLeft: l, cropRight: r, cropTop: t, cropBottom: b),
        );
    // Left / top: the repeated line stays where the encoder crops it.
    final left = await _run(_job('crop_left', src, 63, 33, 'yuv420p10le', pipeline: crop(4, 0, 2, 0)), 'left');
    expect(await _stream(left.outputPath!), (59, 31, 'yuv420p10le'));
    // Right / bottom: the crop takes it, one real line more than asked.
    final right = await _run(_job('crop_right', src, 63, 33, 'yuv420p10le', pipeline: crop(0, 4, 0, 2)), 'right');
    expect(await _stream(right.outputPath!), (60, 32, 'yuv420p10le'));
    expect(right.logs.join('\n'), contains('one real line more than the crop'));

    final resized = await _run(
        _job('resize', src, 63, 33, 'yuv420p10le',
            pipeline: const ProcessingPipeline(
              deinterlace: QTGMCParameters(enabled: false),
              cropResize: CropResizeParameters(enabled: true, resizeEnabled: true, targetWidth: 32),
            )),
        'resize');
    final (rw, rh, _) = await _stream(resized.outputPath!);
    expect(rw, 32);
    expect(rh, 16, reason: 'fitted to the real 63x33 picture, not the padded 64x34');
  });

  test('an interlaced odd-height source deinterlaces and stays interlaced', () async {
    final src = await _fixture(176, 121, 'yuv420p');
    final qtgmc = await _run(
        _job('qtgmc', src, 176, 121, 'yuv420p',
            fieldOrder: FieldOrder.topFieldFirst,
            pipeline: const ProcessingPipeline(
                deinterlace: QTGMCParameters(enabled: true, preset: QTGMCPreset.fast, tff: true))),
        'qtgmc');
    expect(await _stream(qtgmc.outputPath!), (176, 121, 'yuv420p'));

    final kept = _job('still_interlaced', src, 176, 121, 'yuv420p', fieldOrder: FieldOrder.topFieldFirst);
    final r = await _run(kept, 'still interlaced');
    expect(await _frameHashes(r.outputPath!, 'yuv420p'), await _frameHashes(src, 'yuv420p'));
  });

  test('an HDR source off its grid previews (the tone map runs on the padded frame)', () async {
    final src = await _fixture(63, 33, 'yuv420p10le', extra: [
      '-color_primaries', 'bt2020', '-color_trc', 'smpte2084',
      '-colorspace', 'bt2020nc', '-color_range', 'tv',
    ]);
    final job = _job('hdr', src, 63, 33, 'yuv420p10le')
      ..['inputColorMatrix'] = 'bt2020nc'
      ..['inputColorPrimaries'] = 'bt2020'
      ..['inputColorTransfer'] = 'smpte2084'
      ..['inputColorRange'] = 'tv';
    final preview = await WorkerHarness.runPreview(job, frame: 2);
    expect(preview.success, isTrue, reason: preview.errorTail);
    final r = await _run(job, 'hdr');
    expect(await _frameHashes(r.outputPath!, 'yuv420p10le'), await _frameHashes(src, 'yuv420p10le'));
  });
}
