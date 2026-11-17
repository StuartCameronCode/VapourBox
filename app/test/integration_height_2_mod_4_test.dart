/// Full-encode tests for 720x486 (NTSC D1) pictures in 4:2:0 (task #57).
///
/// At 486 lines a 4:2:0 frame has 243 chroma rows, so a field has no whole
/// chroma height. Splitting it into fields (SeparateFields, inside QTGMC,
/// MCTemporalDenoise, the per-field Deblock) and any zimg resize of it while
/// it is field-flagged ("Resize error 1027") refused, which failed the whole
/// job. The passes now run on a frame padded to whole field chroma rows and
/// cropped back (`plugin_formats.pad_around`). The format sweep covers every
/// pass at 96x66; this runs the real size end to end, through the encoder,
/// including the most common way to meet it: a 4:2:2 D1 capture written out
/// as 4:2:0.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/deblock_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/height_2_mod_4';

const _w = 720;
const _h = 486;
const _frames = 12;

/// A moving, interlaced 720x486 picture in [pixFmt], flagged top field first.
Future<String> _fixture(String pixFmt) async {
  final path = '$_outDir/src_$pixFmt.mkv';
  if (File(path).existsSync()) return path;
  await Directory(_outDir).create(recursive: true);
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi',
      '-i', 'testsrc2=size=${_w}x$_h:rate=30000/1001',
      '-frames:v', '$_frames',
      '-vf', 'setfield=tff',
      '-c:v', 'ffv1', '-pix_fmt', pixFmt, '-field_order', 'tt',
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0, reason: 'fixture: ${result.stderr}');
  return path;
}

Map<String, dynamic> _job(
  String name,
  String input,
  String pixFmt,
  ProcessingPipeline pipeline, {
  ChromaSubsampling chroma = ChromaSubsampling.original,
}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: input,
    outputPath: '$_outDir/$name.mkv',
    processingPipeline: pipeline,
    encodingSettings: EncodingSettings(
      codec: VideoCodec.ffv1,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none,
      chromaSubsampling: chroma,
    ),
    inputWidth: _w,
    inputHeight: _h,
    inputPixelFormat: pixFmt,
    inputFrameRate: 30000 / 1001,
    detectedFieldOrder: FieldOrder.topFieldFirst,
    totalFrames: _frames,
  ).toJson();
}

Future<Map<String, dynamic>> _encode(String name, Map<String, dynamic> job) async {
  final result = await WorkerHarness.runJob(job, label: name);
  expect(result.success, isTrue,
      reason: '$name failed: ${result.error}\n${result.logs.join('\n')}');
  final stream = await WorkerHarness.firstStream(result.outputPath!,
      selector: 'v:0', entries: ['width', 'height', 'pix_fmt', 'nb_read_frames'], countFrames: true);
  expect(stream, isNotNull, reason: '$name: no video stream');
  print('  $name: ${stream!['width']}x${stream['height']} ${stream['pix_fmt']}, '
      '${stream['nb_read_frames']} frames');
  return stream;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  test('QTGMC deinterlaces a 4:2:0 720x486 picture at its own size, double rate', () async {
    for (final pixFmt in ['yuv420p', 'yuv420p10le']) {
      final src = await _fixture(pixFmt);
      final s = await _encode(
          'qtgmc_$pixFmt',
          _job('qtgmc_$pixFmt', src, pixFmt,
              const ProcessingPipeline(
                  deinterlace: QTGMCParameters(enabled: true, preset: QTGMCPreset.fast, tff: true))));
      expect((s['width'], s['height'], s['pix_fmt']), (_w, _h, pixFmt));
      expect(int.parse('${s['nb_read_frames']}'), 2 * _frames);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('still-interlaced 4:2:0 720x486: per-field Deblock and LSFmod run', () async {
    for (final pixFmt in ['yuv420p', 'yuv420p16le']) {
      final src = await _fixture(pixFmt);
      final s = await _encode(
          'deblock_sharpen_$pixFmt',
          _job('deblock_sharpen_$pixFmt', src, pixFmt,
              const ProcessingPipeline(
                deinterlace: QTGMCParameters(enabled: false),
                deblock: DeblockParameters(enabled: true),
                sharpen: SharpenParameters(enabled: true, method: SharpenMethod.lsfmod),
              )));
      expect((s['width'], s['height'], s['pix_fmt']), (_w, _h, pixFmt));
      expect(int.parse('${s['nb_read_frames']}'), _frames);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a still-interlaced 4:2:2 D1 picture goes out as 4:2:0 at 486 lines', () async {
    // The output conversion runs per field (zimg honours _FieldBased), and a
    // 4:2:0 frame 486 high has no whole chroma rows per field: this refused
    // at the very end of every such job (Color Format 4:2:0, or AV1).
    for (final (pixFmt, chroma, want) in [
      ('yuv422p10le', ChromaSubsampling.yuv420, 'yuv420p'),
      ('yuv422p', ChromaSubsampling.yuv420p10, 'yuv420p10le'),
    ]) {
      final src = await _fixture(pixFmt);
      final s = await _encode(
          'to420_$pixFmt',
          _job('to420_$pixFmt', src, pixFmt, const ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false)),
              chroma: chroma));
      expect((s['width'], s['height'], s['pix_fmt']), (_w, _h, want));
      expect(int.parse('${s['nb_read_frames']}'), _frames);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
