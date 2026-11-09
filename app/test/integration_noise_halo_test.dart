/// The pass list's noise and halo measurement (`vapourbox-worker
/// --detect-noise-halo`, app 1.7.0), run through the real worker on fixtures
/// whose noise and sharpening are known.
///
/// Built here from the repo's real footage: the VHS capture
/// `interlaced_test.avi` (interlaced 4:2:2) as it is and with Gaussian noise of
/// sigma 6 added to luma (8-bit, and decoded to 10-bit first), and the DVB-T
/// broadcast as it is and through ffmpeg's `unsharp` at amount 1.5. Every
/// fixture is stored losslessly. The scores must land on the side of the
/// worker's thresholds the report says they do
/// (docs/reports/2026-11-noise-halo-scores): clean sources recommend nothing,
/// heavy noise recommends Noise Reduction only, heavy sharpening Dehalo only.
///
/// The unit tests in `worker/src/noise_halo.rs` cover the same traps on
/// synthetic frames; this file proves the decode (in the source's own format
/// and depth), the per-field measurement and the JSON as the app runs them.
///
/// Heavy (decodes and encodes video) — runs in the nightly workflow.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:vapourbox/models/noise_halo_report.dart';
import 'package:vapourbox/models/pass_relevance.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/services/field_order_detector.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/noise_halo';
String get _vhs => '${WorkerHarness.repoRoot}/Tests/TestResources/interlaced_test.avi';
String get _dvbt => '${WorkerHarness.repoRoot}/Tests/TestResources/pal-dvbt-fieldcoded-25i.ts';

const _w = 720;
const _h = 576;
const _frames = 60;

/// Run ffmpeg, failing the test on an error.
Future<void> _ffmpeg(List<String> args) async {
  final r = await Process.run(WorkerHarness.ffmpegPath, ['-y', '-v', 'error', ...args],
      environment: WorkerHarness.ffmpegEnv);
  if (r.exitCode != 0) throw Exception('ffmpeg ${args.join(' ')}: ${r.stderr}');
}

/// The first [_frames] frames of [src], stored losslessly, optionally through
/// an ffmpeg filter.
Future<String> _copy(String src, String name, {String? vf}) async {
  final path = '$_outDir/$name.mkv';
  await _ffmpeg([
    '-i', src, '-map', '0:v:0', '-frames:v', '$_frames',
    if (vf != null) ...['-vf', vf],
    '-field_order', 'tt', '-c:v', 'ffv1', path,
  ]);
  return path;
}

/// [src] decoded as planar 4:2:2 at [bits], with Gaussian noise of [sigma]
/// (8-bit levels) added to luma, stored losslessly.
Future<String> _noisy(String src, String name, double sigma, {int bits = 8}) async {
  final pix = bits == 8 ? 'yuv422p' : 'yuv422p${bits}le';
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', src, '-frames:v', '$_frames', '-f', 'rawvideo', '-pix_fmt', pix, '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  if (r.exitCode != 0) throw Exception('decoding $src: ${r.stderr}');
  final bytes = Uint8List.fromList(r.stdout as List<int>);
  final bps = bits == 8 ? 1 : 2;
  final frame = _w * _h * 2 * bps; // 4:2:2: luma + two half-width planes
  final scale = 1 << (bits - 8);
  final max = (1 << bits) - 1;
  final rnd = Random(11);
  double gauss() {
    final u = rnd.nextDouble() + 1e-12, v = rnd.nextDouble();
    return sqrt(-2 * log(u)) * cos(2 * pi * v);
  }

  final data = ByteData.sublistView(bytes);
  for (var off = 0; off + frame <= bytes.length; off += frame) {
    for (var i = 0; i < _w * _h; i++) {
      if (bps == 1) {
        bytes[off + i] = (bytes[off + i] + sigma * gauss()).round().clamp(0, max);
      } else {
        final p = off + 2 * i;
        final v = data.getUint16(p, Endian.little);
        data.setUint16(p, (v + sigma * scale * gauss()).round().clamp(0, max), Endian.little);
      }
    }
  }
  final path = '$_outDir/$name.mkv';
  final p = await Process.start(
    WorkerHarness.ffmpegPath,
    [
      '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', pix, '-s', '${_w}x$_h', '-r', '25',
      '-i', '-', '-field_order', 'tt', '-c:v', 'ffv1', '-pix_fmt', pix, path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  final err = p.stderr.transform(utf8.decoder).join();
  p.stdout.drain<void>();
  p.stdin.add(bytes);
  await p.stdin.close();
  if (await p.exitCode != 0) throw Exception('encoding $name: ${await err}');
  return path;
}

/// Run `--detect-noise-halo` on [path] as the app does; returns the report.
Future<Map<String, dynamic>> _detect(String path, String pixFmt, {String fieldOrder = 'tff'}) async {
  final job = {
    'id': const Uuid().v4(),
    'inputPath': path,
    'outputPath': '$_outDir/unused.mkv',
    'qtgmcParameters': <String, dynamic>{},
    'encodingSettings': <String, dynamic>{},
    'detectedFieldOrder': fieldOrder,
    'totalFrames': _frames,
    'inputFrameRate': 25.0,
    'inputWidth': _w,
    'inputHeight': _h,
    'inputPixelFormat': pixFmt,
  };
  final config = File('$_outDir/${job['id']}.json');
  await config.writeAsString(jsonEncode(job));
  final sw = Stopwatch()..start();
  final r = await Process.run(
    WorkerHarness.workerPath,
    ['--detect-noise-halo', '--config', config.path],
    environment: WorkerHarness.workerEnv,
    workingDirectory: File(WorkerHarness.workerPath).parent.path,
  );
  sw.stop();
  await config.delete();
  final line = const LineSplitter()
      .convert(r.stdout as String)
      .lastWhere((l) => l.trim().startsWith('{'), orElse: () => '{}');
  final report = jsonDecode(line) as Map<String, dynamic>;
  expect(report['error'], isNull, reason: '${r.stderr}');
  print('  ${path.split('/').last}: ${sw.elapsedMilliseconds} ms, noise ${report['noise']} '
      '(${report['noiseHigh']}), halo ${report['halo']} (${report['haloHigh']}, '
      '${report['haloEdges']} edges), pairs ${report['usablePairs']}');
  return report;
}

/// What the pass list would badge for [report] on a PAL interlaced source.
Set<PassType> _suggested(Map<String, dynamic> report) {
  const info = VideoInfo(
    width: _w, height: _h, frameRate: 25, duration: 2.4, frameCount: _frames,
    codec: 'ffv1', pixelFormat: 'yuv422p', scanType: ScanType.interlaced, hasAudio: false,
  );
  final measured = NoiseHaloReport.fromJson(report);
  return {
    for (final p in [PassType.noiseReduction, PassType.dehalo])
      if (relevanceFor(p, info, measured: measured).isRecommended) p,
  };
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  const timeout = Timeout(Duration(minutes: 5));

  test('the VHS capture as it is: nothing recommended', () async {
    final r = await _detect(await _copy(_vhs, 'vhs'), 'yuv422p');
    expect(r['interlaced'], isTrue);
    expect(r['noise'] as num, lessThan(2.5), reason: 'report: 1.40 on this clip');
    expect(r['noiseHigh'], isFalse);
    expect(r['haloHigh'], isFalse);
    expect(_suggested(r), isEmpty);
  }, timeout: timeout);

  test('the VHS capture with sigma 6 noise: Noise Reduction only', () async {
    final r = await _detect(await _noisy(_vhs, 'vhs_n6', 6), 'yuv422p');
    // Motion compensation reads white noise about 6 % low (report).
    expect(r['noise'] as num, inInclusiveRange(4.8, 7.0));
    expect(r['noiseHigh'], isTrue);
    expect(r['haloHigh'], isFalse, reason: 'noise is not a halo');
    expect(_suggested(r), {PassType.noiseReduction});
  }, timeout: timeout);

  test('10-bit: the same noise reads the same in 8-bit units', () async {
    final r8 = await _detect(await _noisy(_vhs, 'vhs_n6_8', 6), 'yuv422p');
    final r10 = await _detect(await _noisy(_vhs, 'vhs_n6_10', 6, bits: 10), 'yuv422p10le');
    expect(r10['noiseHigh'], isTrue);
    expect(((r10['noise'] as num) - (r8['noise'] as num)).abs(), lessThan(0.4));
  }, timeout: timeout);

  test('the DVB-T broadcast: clean, and sharpened reads as halos', () async {
    final clean = await _detect(await _copy(_dvbt, 'dvbt'), 'yuv420p');
    expect(clean['haloEdges'] as int, greaterThanOrEqualTo(200));
    expect(clean['halo'] as num, lessThan(3.0), reason: 'report: -2.2');
    expect(_suggested(clean), isEmpty);
    final sharp = await _detect(await _copy(_dvbt, 'dvbt_usm', vf: 'unsharp=5:5:1.5:5:5:0'), 'yuv420p');
    expect(sharp['halo'] as num, greaterThan(10.0), reason: 'report: 15.7');
    expect(sharp['haloHigh'], isTrue);
    expect(sharp['noiseHigh'], isFalse);
    expect(_suggested(sharp), {PassType.dehalo});
  }, timeout: timeout);
}
