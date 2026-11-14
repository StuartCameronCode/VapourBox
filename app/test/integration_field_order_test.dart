/// Full-encode tests for the field order a still-interlaced picture is
/// declared with, codec by codec (docs/reports/2026-11-field-order-other-codecs,
/// docs/reports/2026-11-v210-field-order).
///
/// vspipe's Y4M header always says `Ip`, so the worker tells the encoder on its
/// pipe input (`-top 1|0`, `pipeline_executor::field_order_args`). What only a
/// real encode can show:
///   * v210, FFV1, HuffYUV, FFVHuff: MKV's FieldOrder is `tb` / `bt`, MOV's
///     `fiel` atom 0x0209 / 0x020e (read by walking the boxes, see
///     `WorkerHarness.movFielAtom`), AVI carries nothing, and the flag costs no
///     pixel. FFV1 also writes it in its own bitstream, which survives in AVI.
///   * ProRes: the container, and its own frame header (`+ildct`).
///   * x264: coded interlaced (MBAFF), with every frame's `pic_struct` naming
///     the right order. With `+ildct` alone, a BFF picture's SEI said
///     top-first on most frames.
///   * x265: deliberately not flagged (its interlace mode declares each woven
///     frame a single field), and the job log says so.
///   * A deinterlaced job stays progressive.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => p.join(WorkerHarness.outputDir, 'field_order');

/// A real interlaced picture (VHS, 720x576 25i, TFF; lagarith 4:2:2), cut to
/// its first ten frames. The BFF cases declare it the other way round, which
/// is all a flag test needs.
String get _source =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'interlaced_test.avi');
const _frames = 10;

Map<String, dynamic> _job(String name, VideoCodec codec, ContainerFormat container,
    FieldOrder order, {bool deinterlace = false}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: _source,
    outputPath: p.join(_outDir, '$name.${container.extension}'),
    processingPipeline: ProcessingPipeline(
      deinterlace: QTGMCParameters(
        enabled: deinterlace,
        preset: QTGMCPreset.fast,
        tff: order != FieldOrder.bottomFieldFirst,
      ),
    ),
    encodingSettings: EncodingSettings(
      codec: codec,
      container: container,
      audioMode: AudioMode.none,
    ),
    detectedFieldOrder: order,
    inputWidth: 720,
    inputHeight: 576,
    inputPixelFormat: 'yuv422p',
    inputFrameRate: 25,
    startFrame: 0,
    endFrame: _frames - 1,
  ).toJson();
}

/// Encodes and returns (output path, the job's log lines).
Future<(String, List<String>)> _encode(
    String name, VideoCodec codec, ContainerFormat container, FieldOrder order,
    {bool deinterlace = false}) async {
  final job = _job(name, codec, container, order, deinterlace: deinterlace);
  final result = await WorkerHarness.runJob(job, label: name);
  if (!result.success) {
    print(result.logs.reversed.take(30).toList().reversed.join('\n'));
  }
  expect(result.success, isTrue, reason: '$name: ${result.error}');
  return (job['outputPath'] as String, result.logs);
}

Future<String?> _fieldOrder(String path) async => (await WorkerHarness.firstStream(
        path,
        selector: 'v:0',
        entries: ['field_order']))?['field_order'] as String?;

/// (interlaced_frame, top_field_first) of every decoded frame.
Future<Set<(int, int)>> _frameFlags(String path) async {
  final json = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'frame=interlaced_frame,top_field_first',
    '-of', 'json', path,
  ]);
  return {
    for (final f in (json['frames'] as List).cast<Map<String, dynamic>>())
      (f['interlaced_frame'] as int, f['top_field_first'] as int),
  };
}

/// Per-frame MD5s of [path] decoded as yuv422p.
Future<List<String>> _frameMd5s(String path) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, '-frames:v', '$_frames', '-map', '0:v:0',
     '-pix_fmt', 'yuv422p', '-f', 'framemd5', '-'],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'framemd5 $path: ${r.stderr}');
  return (r.stdout as String)
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .map((l) => l.split(',').last.trim())
      .toList();
}

const _orders = [
  (FieldOrder.topFieldFirst, 'tb', '0209', 1),
  (FieldOrder.bottomFieldFirst, 'bt', '020e', 0),
];

void main() {
  late List<String> sourceMd5s;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    sourceMd5s = await _frameMd5s(_source);
    expect(sourceMd5s, hasLength(_frames));
  });

  group('container-flagged codecs', () {
    for (final codec in [VideoCodec.ffv1, VideoCodec.huffyuv, VideoCodec.ffvhuff, VideoCodec.v210]) {
      for (final (order, label, atom, tff) in _orders) {
        test('${codec.name} ${order.value}: MKV and MOV say so, AVI cannot', () async {
          final name = '${codec.name}_${order.value}';
          final (mkv, _) = await _encode('${name}_mkv', codec, ContainerFormat.mkv, order);
          expect(await _fieldOrder(mkv), label, reason: 'MKV FieldOrder');

          final (mov, _) = await _encode('${name}_mov', codec, ContainerFormat.mov, order);
          expect(await _fieldOrder(mov), label);
          expect(WorkerHarness.movFielAtom(mov), atom,
              reason: 'the fiel atom is what an editor reads');

          final (avi, aviLogs) = await _encode('${name}_avi', codec, ContainerFormat.avi, order);
          expect(await _fieldOrder(avi) ?? 'unknown', 'unknown',
              reason: 'AVI has nowhere to put it');

          if (codec == VideoCodec.ffv1) {
            // FFV1's own bitstream carries it, in every container.
            for (final f in [mkv, mov, avi]) {
              expect(await _frameFlags(f), {(1, tff)}, reason: 'FFV1 bitstream: $f');
            }
            expect(aviLogs.any((l) => l.contains('AVI cannot record')), isFalse,
                reason: 'FFV1 in AVI keeps its field order');
          } else {
            expect(aviLogs.any((l) => l.contains('AVI cannot record')), isTrue,
                reason: 'the job log says AVI drops it');
          }

          // The flag changes no pixel: lossless codecs give the source back.
          if (codec != VideoCodec.v210) {
            for (final f in [mkv, mov, avi]) {
              expect(await _frameMd5s(f), sourceMd5s, reason: 'lossless: $f');
            }
          }
        }, timeout: const Timeout(Duration(minutes: 5)));
      }
    }
  });

  group('ProRes', () {
    for (final (order, label, atom, tff) in _orders) {
      test('ProRes 422 HQ ${order.value}: container and frame header', () async {
        final (mov, _) = await _encode(
            'prores_${order.value}', VideoCodec.proresHQ, ContainerFormat.mov, order);
        expect(await _fieldOrder(mov), label);
        expect(WorkerHarness.movFielAtom(mov), atom);
        expect(await _frameFlags(mov), {(1, tff)}, reason: 'ProRes frame header');
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  });

  group('x264 codes the picture interlaced', () {
    for (final (order, label, _, tff) in _orders) {
      test('H.264 ${order.value}: MBAFF, every pic_struct agrees', () async {
        final (mkv, _) =
            await _encode('x264_${order.value}', VideoCodec.h264, ContainerFormat.mkv, order);
        final h = await WorkerHarness.bitstreamHeaderCounts(mkv, [
          'frame_mbs_only_flag',
          'mb_adaptive_frame_field_flag',
          'pic_struct',
        ]);
        print('  x264 ${order.value}: $h');
        expect(h['frame_mbs_only_flag'], {'0': 1}, reason: 'interlaced coding');
        expect(h['mb_adaptive_frame_field_flag'], {'1': 1}, reason: 'MBAFF');
        // pic_struct 3 = top then bottom, 4 = bottom then top: on every frame.
        expect(h['pic_struct'], {tff == 1 ? '3' : '4': _frames});
        expect(await _frameFlags(mkv), {(1, tff)});
        expect(await _fieldOrder(mkv), label);

        final (mp4, _) =
            await _encode('x264_${order.value}_mp4', VideoCodec.h264, ContainerFormat.mp4, order);
        expect(await _frameFlags(mp4), {(1, tff)});
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  });

  test('x265 is left unflagged, and the job log says why', () async {
    final (mp4, logs) =
        await _encode('x265_tff', VideoCodec.h265, ContainerFormat.mp4, FieldOrder.topFieldFirst);
    expect(await _fieldOrder(mp4), 'progressive');
    expect(WorkerHarness.movFielAtom(mp4), '0100');
    final h = await WorkerHarness.bitstreamHeaderCounts(mp4, ['field_seq_flag']);
    expect(h['field_seq_flag'], {'0': 1},
        reason: 'never x265 interlace mode: it calls each woven frame a field');
    expect(logs.any((l) => l.contains('cannot mark it as interlaced')), isTrue,
        reason: 'job log: ${logs.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 5)));

  group('deinterlaced output is progressive', () {
    for (final (codec, container) in [
      (VideoCodec.ffv1, ContainerFormat.mkv),
      (VideoCodec.h264, ContainerFormat.mp4),
    ]) {
      test(codec.name, () async {
        final (out, logs) = await _encode('${codec.name}_deint', codec, container,
            FieldOrder.topFieldFirst,
            deinterlace: true);
        expect(await _fieldOrder(out), 'progressive');
        expect(await _frameFlags(out), {(0, 0)});
        expect(logs.any((l) => l.contains('still interlaced')), isFalse);
        if (codec == VideoCodec.h264) {
          final h = await WorkerHarness.bitstreamHeaderCounts(out, ['frame_mbs_only_flag']);
          expect(h['frame_mbs_only_flag'], {'1': 1});
        }
      }, timeout: const Timeout(Duration(minutes: 10)));
    }
  });
}
