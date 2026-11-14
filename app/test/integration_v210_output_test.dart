/// Full-encode tests for uncompressed v210 output, and for the chroma
/// conversion the script makes for the editing intermediates (v210, ProRes).
///
/// What only a real encode can show:
///   * v210 really is uncompressed: a 10-bit 4:2:2 source with every pass off
///     comes back bit for bit.
///   * The output is 10-bit 4:2:2 whatever Color Format is selected, and the
///     4:2:0 -> 4:2:2 conversion keeps each field's chroma to itself. Left to
///     ffmpeg's `-pix_fmt`, the two fields' chroma was blended. ProRes gets the
///     same in-script conversion to its profile's format (4:2:2 or 4:4:4).
///   * A deinterlaced v210 MOV is flagged progressive (`fiel` 0x0100). The
///     field order of a still-interlaced one, for every codec, is checked in
///     integration_field_order_test.dart.
///   * PCM audio is kept and offered in MOV, and the preview is the encode.
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

String get _outDir => p.join(WorkerHarness.outputDir, 'v210');
String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

Map<String, dynamic> _job({
  required String name,
  required String input,
  required String pixFmt,
  required int width,
  required int height,
  required double fps,
  VideoCodec codec = VideoCodec.v210,
  ContainerFormat container = ContainerFormat.mov,
  ChromaSubsampling chroma = ChromaSubsampling.original,
  FieldOrder? fieldOrder,
  bool deinterlace = false,
  AudioMode audioMode = AudioMode.none,
  AudioCodec audioCodec = AudioCodec.aac,
  int? endFrame,
}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: input,
    outputPath: p.join(_outDir, '$name.${container.extension}'),
    processingPipeline: ProcessingPipeline(
      deinterlace: QTGMCParameters(
        enabled: deinterlace,
        preset: QTGMCPreset.fast,
        tff: fieldOrder != FieldOrder.bottomFieldFirst,
      ),
    ),
    encodingSettings: EncodingSettings(
      codec: codec,
      container: container,
      chromaSubsampling: chroma,
      audioMode: audioMode,
      audioCodec: audioCodec,
    ),
    detectedFieldOrder: fieldOrder,
    inputWidth: width,
    inputHeight: height,
    inputPixelFormat: pixFmt,
    inputFrameRate: fps,
    startFrame: endFrame == null ? null : 0,
    endFrame: endFrame,
  ).toJson();
}

Future<String> _encode(Map<String, dynamic> job, String label) async {
  final result = await WorkerHarness.runJob(job, label: label);
  if (!result.success) {
    print(result.logs.reversed.take(30).toList().reversed.join('\n'));
  }
  expect(result.success, isTrue, reason: '$label: ${result.error}');
  return job['outputPath'] as String;
}

/// Per-frame MD5s of [path] decoded to [pixFmt] (framemd5's hash column).
///
/// Decodes the full stored frame (`-apply_cropping codec`), as the worker does:
/// pal-sd-25.mov carries a clean aperture that would otherwise crop it to 702.
Future<List<String>> _frameMd5s(String path, String pixFmt, {int? frames}) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-apply_cropping', 'codec', '-i', path,
      if (frames != null) ...['-frames:v', '$frames'],
      '-map', '0:v:0', '-pix_fmt', pixFmt, '-f', 'framemd5', '-',
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'framemd5 $path: ${r.stderr}');
  return (r.stdout as String)
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .map((l) => l.split(',').last.trim())
      .toList();
}

/// One frame decoded to raw yuv422p10le (or [pixFmt]) bytes.
Future<Uint8List> _rawFrame(String path, String pixFmt, {int frame = 0}) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-i', path,
      '-vf', 'select=eq(n\\,$frame)', '-frames:v', '1',
      '-f', 'rawvideo', '-pix_fmt', pixFmt, '-',
    ],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(r.exitCode, 0, reason: 'raw frame $path: ${r.stderr}');
  return Uint8List.fromList(r.stdout as List<int>);
}

const _fw = 720;
const _fh = 576;

/// An interlaced 4:2:0 fixture whose two fields have different chroma: the
/// top field is red, the bottom blue, woven line by line in every plane, so
/// chroma row k of the 4:2:0 picture belongs to field k % 2.
Future<String> _fieldChromaFixture() async {
  final path = p.join(_outDir, 'src_field_chroma_420.mkv');
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'color=c=red:size=${_fw}x${_fh ~/ 2}:rate=50:duration=0.4',
      '-f', 'lavfi', '-i', 'color=c=blue:size=${_fw}x${_fh ~/ 2}:rate=50:duration=0.4',
      '-filter_complex',
      '[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];'
          '[a][b]interleave,tinterlace=mode=merge,setfield=tff[v]',
      '-map', '[v]', '-c:v', 'ffv1', '-pix_fmt', 'yuv420p',
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'fixture: ${r.stderr}');
  return path;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  test('a 10-bit 4:2:2 source comes back bit for bit', () async {
    final src = _resource('pal-sd-25.mov'); // ProRes 422, yuv422p10le, 25p
    final out = await _encode(
      _job(
        name: 'bitexact',
        input: src,
        pixFmt: 'yuv422p10le',
        width: 720,
        height: 576,
        fps: 25,
        endFrame: 24,
      ),
      'v210 bit-exact',
    );
    final s = await WorkerHarness.firstStream(out,
        selector: 'v:0',
        entries: ['codec_name', 'pix_fmt', 'field_order', 'nb_read_frames'],
        countFrames: true);
    expect(s!['codec_name'], 'v210');
    expect(s['pix_fmt'], 'yuv422p10le');
    expect(s['field_order'], 'progressive');
    expect(int.parse(s['nb_read_frames'].toString()), 25);
    expect(WorkerHarness.movFielAtom(out), '0100');

    final expected = await _frameMd5s(src, 'yuv422p10le', frames: 25);
    final actual = await _frameMd5s(out, 'yuv422p10le');
    expect(actual, expected,
        reason: 'v210 is uncompressed: every frame must equal the source');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('an 8-bit source with a 4:2:0 selection is still 10-bit 4:2:2, '
      'and the preview is the encode', () async {
    final src = _resource('interlaced_test.avi'); // lagarith yuv422p
    final job = _job(
      name: 'from_8bit',
      input: src,
      pixFmt: 'yuv422p',
      width: 720,
      height: 576,
      fps: 25,
      chroma: ChromaSubsampling.yuv420,
      fieldOrder: FieldOrder.topFieldFirst,
    );
    final out = await _encode(job, 'v210 from 8-bit');
    final s = await WorkerHarness.firstStream(out,
        selector: 'v:0',
        entries: ['codec_name', 'pix_fmt', 'nb_read_frames'],
        countFrames: true);
    expect(s!['codec_name'], 'v210');
    expect(s['pix_fmt'], 'yuv422p10le');
    // The AVI index says 79, but four of its entries are empty: what decodes
    // is the count to match.
    final source = await WorkerHarness.firstStream(src,
        selector: 'v:0', entries: ['nb_read_frames'], countFrames: true);
    expect(int.parse(s['nb_read_frames'].toString()),
        int.parse(source!['nb_read_frames'].toString()));

    final pv = await WorkerHarness.runPreview(job, frame: 10, label: 'v210 preview');
    expect(pv.png, isNotNull, reason: '${pv.error}\n${pv.logs}');
    final diff = WorkerHarness.meanAbsDiff(
      await WorkerHarness.imageToRgb24(pv.png!, label: 'v210_pv'),
      await WorkerHarness.frameRgb24(out, 10, label: 'v210_enc'),
    );
    print('  v210 preview vs encode: meanAbsDiff ${diff.toStringAsFixed(3)}');
    expect(diff, lessThan(1.0), reason: 'the preview is not the encoded picture');
  }, timeout: const Timeout(Duration(minutes: 10)));

  group('field order of a still-interlaced picture', () {
    late String fixture;
    setUpAll(() async => fixture = await _fieldChromaFixture());

    Future<String> encode(String name, VideoCodec codec, ContainerFormat c,
            FieldOrder order, {bool deinterlace = false}) =>
        _encode(
          _job(
            name: name,
            input: fixture,
            pixFmt: 'yuv420p',
            width: _fw,
            height: _fh,
            fps: 25,
            codec: codec,
            container: c,
            fieldOrder: order,
            deinterlace: deinterlace,
          ),
          name,
        );

    Future<String?> fieldOrder(String path) async => (await WorkerHarness.firstStream(
            path,
            selector: 'v:0',
            entries: ['field_order']))?['field_order'] as String?;

    // The per-codec, per-container field-order checks (v210 among them)
    // are in integration_field_order_test.dart.

    test('deinterlaced output is progressive', () async {
      final mov = await encode('v210_deint', VideoCodec.v210, ContainerFormat.mov,
          FieldOrder.topFieldFirst,
          deinterlace: true);
      expect(await fieldOrder(mov), 'progressive');
      expect(WorkerHarness.movFielAtom(mov), '0100');
    }, timeout: const Timeout(Duration(minutes: 10)));

    // The script converts to the codec's one stored format itself, after the
    // clip is marked field-based, so zimg keeps each field's chroma to itself.
    // Left to ffmpeg's `-pix_fmt` (ProRes until app 1.8.0), the two fields'
    // chroma was blended: these rows came out 454,454,866,866 instead of
    // 360,960,360,960 (docs/reports/2026-11-prores-script-chroma).
    for (final (codec, pixFmt, chroma444) in [
      (VideoCodec.v210, 'yuv422p10le', false),
      (VideoCodec.proresProxy, 'yuv422p10le', false),
      (VideoCodec.proresHQ, 'yuv422p10le', false),
      (VideoCodec.prores4444, 'yuv444p10le', true),
    ]) {
      test('${codec.displayName}: 4:2:0 -> ${chroma444 ? "4:4:4" : "4:2:2"} '
          'keeps each field\'s chroma to itself', () async {
        final name = 'chroma_fields_${codec.name}';
        final mov = await encode(
            name, codec, ContainerFormat.mov, FieldOrder.topFieldFirst);
        expect(WorkerHarness.movFielAtom(mov), '0209', reason: 'still flagged TFF');

        // The fixture's per-field chroma, in 8-bit units: U of chroma rows 0, 1.
        final src = await _rawFrame(fixture, 'yuv420p');
        final cw = _fw ~/ 2;
        final srcU = _fw * _fh;
        final topU = src[srcU + 0 * cw + cw ~/ 2];
        final botU = src[srcU + 1 * cw + cw ~/ 2];
        expect((topU - botU).abs(), greaterThan(50), reason: 'fixture fields differ');

        // The output's U plane at 10 bits: one chroma row per luma row, row r
        // in field r % 2. (ProRes 4444 decodes as 12-bit; read at 10.)
        final out = await _rawFrame(mov, pixFmt);
        final ow = chroma444 ? _fw : cw;
        final y10 = _fw * _fh * 2;
        int u(int row) {
          final o = y10 + (row * ow + ow ~/ 2) * 2;
          return out[o] | (out[o + 1] << 8);
        }

        final rows = [for (var r = 100; r < 112; r++) u(r)];
        print('  ${codec.displayName} U rows (10-bit) 100..111: $rows; '
            'fields 8-bit $topU / $botU');
        for (var r = 100; r < 112; r++) {
          final want = (r.isEven ? topU : botU) * 4;
          // Measured exact for every profile (each field is flat, and ProRes
          // codes the fields apart with +ildct); 8 leaves room for the codec.
          expect((u(r) - want).abs(), lessThanOrEqualTo(8),
              reason: 'row $r: ${u(r)} vs its field\'s $want — fields blended');
        }
      }, timeout: const Timeout(Duration(minutes: 5)));
    }

    test('ProRes 422 HQ from interlaced 4:2:0: the preview is the encode',
        () async {
      final job = _job(
        name: 'prores_hq_preview',
        input: fixture,
        pixFmt: 'yuv420p',
        width: _fw,
        height: _fh,
        fps: 25,
        codec: VideoCodec.proresHQ,
        fieldOrder: FieldOrder.topFieldFirst,
      );
      final out = await _encode(job, 'ProRes HQ preview');
      final pv = await WorkerHarness.runPreview(job, frame: 3, label: 'prores preview');
      expect(pv.png, isNotNull, reason: '${pv.error}\n${pv.logs}');
      final diff = WorkerHarness.meanAbsDiff(
        await WorkerHarness.imageToRgb24(pv.png!, label: 'prores_pv'),
        await WorkerHarness.frameRgb24(out, 3, label: 'prores_enc'),
      );
      print('  ProRes HQ preview vs encode: meanAbsDiff ${diff.toStringAsFixed(3)}');
      expect(diff, lessThan(1.0), reason: 'the preview is not the encoded picture');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('PCM audio in MOV', () {
    test('a PCM source is passed through', () async {
      final out = await _encode(
        _job(
          name: 'pcm_passthrough',
          input: _resource('interlaced_test.avi'), // pcm_s16le
          pixFmt: 'yuv422p',
          width: 720,
          height: 576,
          fps: 25,
          audioMode: AudioMode.passthrough,
          endFrame: 24,
        ),
        'v210 pcm passthrough',
      );
      final a = await WorkerHarness.firstStream(out,
          selector: 'a:0', entries: ['codec_name']);
      expect(a!['codec_name'], 'pcm_s16le');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Convert to PCM is offered and works', () async {
      final out = await _encode(
        _job(
          name: 'pcm_convert',
          input: _resource('small_clip.mp4'), // aac
          pixFmt: 'yuv420p',
          width: 320,
          height: 240,
          fps: 29.97,
          audioMode: AudioMode.convert,
          audioCodec: AudioCodec.pcm,
          endFrame: 29,
        ),
        'v210 pcm convert',
      );
      final v = await WorkerHarness.firstStream(out,
          selector: 'v:0', entries: ['codec_name', 'pix_fmt']);
      expect(v!['codec_name'], 'v210');
      final a = await WorkerHarness.firstStream(out,
          selector: 'a:0', entries: ['codec_name']);
      expect(a!['codec_name'], 'pcm_s16le');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
