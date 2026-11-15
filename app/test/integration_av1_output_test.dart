/// Full-encode tests for AV1 output through SVT-AV1 (task #40).
///
/// What only a real encode can show:
///   * MP4 and MKV come out as AV1 with the audio kept, at the right length.
///   * A 10-bit 4:2:2 source comes out 10-bit 4:2:0, converted in the script.
///   * That conversion keeps each field's chroma to itself on a picture left
///     interlaced. Left to ffmpeg's `-pix_fmt` (swscale), the two fields'
///     chroma rows are blended together — which is why the worker converts.
///   * The preview is the encode.
///
/// HDR10 metadata through `-svtav1-params` is checked in
/// integration_hdr_test.dart. Every test skips where the bundled FFmpeg has no
/// libsvtav1 (macOS x64), which the app reports as unavailable.
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

String get _outDir => p.join(WorkerHarness.outputDir, 'av1');
String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

Map<String, dynamic> _job({
  required String name,
  required String input,
  required String pixFmt,
  required int width,
  required int height,
  required double fps,
  ContainerFormat container = ContainerFormat.mp4,
  ChromaSubsampling chroma = ChromaSubsampling.original,
  FieldOrder? fieldOrder,
  AudioMode audioMode = AudioMode.none,
  int quality = 24,
  int? endFrame,
}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: input,
    outputPath: p.join(_outDir, '$name.${container.extension}'),
    processingPipeline: const ProcessingPipeline(
      deinterlace: QTGMCParameters(enabled: false),
    ),
    encodingSettings: EncodingSettings(
      codec: VideoCodec.av1,
      encoderPreset: '8',
      quality: quality,
      container: container,
      chromaSubsampling: chroma,
      audioMode: audioMode,
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
  // SVT_LOG=2: the encoder's info banner stays out of the job log.
  expect(result.logs.where((l) => l.contains('Svt[info]')), isEmpty,
      reason: 'SVT-AV1 banner reached the log');
  return job['outputPath'] as String;
}

/// One frame decoded to raw [pixFmt] bytes.
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

/// An interlaced 4:2:2 fixture whose fields differ in colour: the top field
/// red, the bottom blue, woven line by line, so a field-aware 4:2:0
/// conversion keeps alternating chroma rows and a progressive one blends them.
Future<String> _fieldChromaFixture() async {
  final path = p.join(_outDir, 'src_field_chroma_422.mkv');
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'color=c=red:size=${_fw}x${_fh ~/ 2}:rate=50:duration=0.4',
      '-f', 'lavfi', '-i', 'color=c=blue:size=${_fw}x${_fh ~/ 2}:rate=50:duration=0.4',
      '-filter_complex',
      '[0:v]format=yuv422p[a];[1:v]format=yuv422p[b];'
          '[a][b]interleave,tinterlace=mode=merge,setfield=tff[v]',
      '-map', '[v]', '-c:v', 'ffv1', '-pix_fmt', 'yuv422p',
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'fixture: ${r.stderr}');
  return path;
}

void main() {
  var available = false;
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    available = await WorkerHarness.hasEncoder('libsvtav1');
  });

  bool skipIfUnavailable() {
    if (!available) {
      markTestSkipped('this FFmpeg has no libsvtav1 (macOS x64)');
    }
    return !available;
  }

  test('8-bit 4:2:0 to MP4: AV1, yuv420p, audio kept, every frame', () async {
    if (skipIfUnavailable()) return;
    final src = _resource('small_clip.mp4'); // H.264 320x240 29.97, AAC
    final out = await _encode(
      _job(
        name: 'mp4_8bit',
        input: src,
        pixFmt: 'yuv420p',
        width: 320,
        height: 240,
        fps: 29.97,
        audioMode: AudioMode.passthrough,
        endFrame: 59,
      ),
      'av1 mp4',
    );
    final v = await WorkerHarness.firstStream(out,
        selector: 'v:0',
        entries: ['codec_name', 'codec_tag_string', 'pix_fmt', 'nb_read_frames'],
        countFrames: true);
    expect(v!['codec_name'], 'av1');
    expect(v['codec_tag_string'], 'av01');
    expect(v['pix_fmt'], 'yuv420p');
    expect(int.parse(v['nb_read_frames'].toString()), 60);
    final a = await WorkerHarness.firstStream(out,
        selector: 'a:0', entries: ['codec_name']);
    expect(a, isNotNull, reason: 'the audio was dropped');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('10-bit 4:2:2 to MKV is 10-bit 4:2:0, close to the source, '
      'and the preview is the encode', () async {
    if (skipIfUnavailable()) return;
    final src = _resource('pal-sd-25.mov'); // ProRes 422 HQ, yuv422p10le, 25p
    final job = _job(
      name: 'mkv_10bit_422',
      input: src,
      pixFmt: 'yuv422p10le',
      width: _fw,
      height: _fh,
      fps: 25,
      container: ContainerFormat.mkv,
      quality: 20,
      endFrame: 24,
    );
    final out = await _encode(job, 'av1 mkv 10-bit');
    final v = await WorkerHarness.firstStream(out,
        selector: 'v:0',
        entries: ['codec_name', 'pix_fmt', 'nb_read_frames'],
        countFrames: true);
    expect(v!['codec_name'], 'av1');
    expect(v['pix_fmt'], 'yuv420p10le');
    expect(int.parse(v['nb_read_frames'].toString()), 25);

    final pv = await WorkerHarness.runPreview(job, frame: 10, label: 'av1 preview');
    expect(pv.png, isNotNull, reason: '${pv.error}\n${pv.logs}');
    final diff = WorkerHarness.meanAbsDiff(
      await WorkerHarness.imageToRgb24(pv.png!, label: 'av1_pv'),
      await WorkerHarness.frameRgb24(out, 10, label: 'av1_enc'),
    );
    print('  AV1 preview vs encode: meanAbsDiff ${diff.toStringAsFixed(3)}');
    // The preview is the script's output before the lossy encode.
    expect(diff, lessThan(2.0), reason: 'the preview is not the encoded picture');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a still-interlaced 4:2:2 picture keeps each field\'s chroma', () async {
    if (skipIfUnavailable()) return;
    final src = await _fieldChromaFixture();
    final out = await _encode(
      _job(
        name: 'field_chroma',
        input: src,
        pixFmt: 'yuv422p',
        width: _fw,
        height: _fh,
        fps: 25,
        container: ContainerFormat.mkv,
        fieldOrder: FieldOrder.topFieldFirst,
        quality: 10,
      ),
      'av1 field chroma',
    );
    final s = await WorkerHarness.firstStream(out,
        selector: 'v:0', entries: ['pix_fmt']);
    expect(s!['pix_fmt'], 'yuv420p');

    // V (Cr) plane of frame 2: red's Cr is high, blue's low. Field-aware, the
    // 4:2:0 chroma rows alternate field by field; blended, every row is the
    // same magenta.
    final raw = await _rawFrame(out, 'yuv420p', frame: 2);
    const cw = _fw ~/ 2, ch = _fh ~/ 2;
    final vPlane = raw.sublist(_fw * _fh + cw * ch, _fw * _fh + 2 * cw * ch);
    double rowMean(int row) {
      var sum = 0;
      for (var x = 0; x < cw; x++) {
        sum += vPlane[row * cw + x];
      }
      return sum / cw;
    }

    // Away from the top and bottom edges.
    var even = 0.0, odd = 0.0;
    var rows = 0;
    for (var r = 20; r < ch - 20; r += 2) {
      even += rowMean(r);
      odd += rowMean(r + 1);
      rows++;
    }
    even /= rows;
    odd /= rows;
    print('  Cr rows: field 0 ${even.toStringAsFixed(1)}, '
        'field 1 ${odd.toStringAsFixed(1)}');
    // Red Cr ~240, blue Cr ~110 in limited range; blended both ~175.
    expect(even - odd, greaterThan(60),
        reason: 'the two fields\' chroma was blended (not field-aware)');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('MOV is refused with a clear message', () async {
    final job = _job(
      name: 'refused',
      input: _resource('small_clip.mp4'),
      pixFmt: 'yuv420p',
      width: 320,
      height: 240,
      fps: 29.97,
      container: ContainerFormat.mov,
      endFrame: 9,
    );
    final result = await WorkerHarness.runJob(job, label: 'av1 mov');
    expect(result.success, isFalse);
    expect('${result.error}', contains('Choose MP4 or MKV'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
