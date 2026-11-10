/// Crop & Resize's Detect (`vapourbox-worker --detect-crop`, app 1.7.0),
/// run through the real worker on videos whose borders are known.
///
/// The fixtures are built here from real picture: frames of the VHS capture
/// `interlaced_test.avi`, cut to its inner region (so they carry no borders of
/// their own) and placed on a canvas with black borders, noisy blanking, a
/// letterbox, burnt-in subtitles, fades to black and a simulated
/// head-switching band (the bottom lines shifted sideways by 5-13 px, with
/// noisy luma and wrecked chroma, different in every frame). Each is encoded
/// losslessly and measured; every edge must come back within 2 lines of what
/// was drawn. Two real files are measured as well: a DVB-T broadcast (black
/// side bars, black bottom lines; checked by eye, see the report) and the VHS
/// capture itself.
///
/// The unit tests in `worker/src/crop_detect.rs` cover the same traps on
/// synthetic frames; this file proves the decode, the sampling and the JSON
/// as the app runs them.
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

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/crop_detect';
String get _vhs => '${WorkerHarness.repoRoot}/Tests/TestResources/interlaced_test.avi';
String get _dvbt => '${WorkerHarness.repoRoot}/Tests/TestResources/pal-dvbt-fieldcoded-25i.ts';

const _w = 720;
const _h = 576;
const _frames = 30;

/// What to draw.
class _Spec {
  final String name;
  final int left, right, top, bottom;
  final double blankNoise;
  final int band;
  final bool subtitles;
  final bool fades;

  const _Spec(this.name,
      {this.left = 0,
      this.right = 0,
      this.top = 0,
      this.bottom = 0,
      this.blankNoise = 0,
      this.band = 0,
      this.subtitles = false,
      this.fades = false});
}

/// [_frames] frames of the VHS capture's inner region, resized to [w]x[h],
/// as yuv444p.
Future<List<Uint8List>> _picture(int w, int h) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-i', _vhs,
      '-vf', 'crop=664:536:28:12,scale=$w:$h:flags=bicubic',
      '-frames:v', '$_frames', '-f', 'rawvideo', '-pix_fmt', 'yuv444p', '-',
    ],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  if (r.exitCode != 0) throw Exception('decoding the picture: ${r.stderr}');
  final bytes = r.stdout as List<int>;
  final size = w * h * 3;
  return [
    for (var i = 0; i + size <= bytes.length; i += size)
      Uint8List.fromList(bytes.sublist(i, i + size)),
  ];
}

/// Build and encode one fixture; returns its path.
Future<String> _fixture(_Spec s) async {
  final pw = _w - s.left - s.right;
  final ph = _h - s.top - s.bottom;
  final picture = await _picture(pw, ph);
  final rnd = Random(7);
  const n = _w * _h;
  final out = BytesBuilder(copy: false);
  for (var t = 0; t < picture.length; t++) {
    final f = Uint8List(n * 3);
    f.fillRange(0, n, 16);
    f.fillRange(n, 3 * n, 128);
    final p = picture[t];
    final fade = s.fades && t % 3 == 0;
    for (var y = 0; y < ph; y++) {
      for (var x = 0; x < pw; x++) {
        final si = y * pw + x;
        final di = (y + s.top) * _w + x + s.left;
        var luma = p[si];
        var u = p[pw * ph + si], v = p[2 * pw * ph + si];
        if (fade) {
          luma = 16 + (luma - 16) ~/ 12;
          u = 128 + (u - 128) ~/ 12;
          v = 128 + (v - 128) ~/ 12;
        }
        f[di] = luma;
        f[n + di] = u;
        f[2 * n + di] = v;
      }
    }
    if (s.blankNoise > 0) {
      for (var y = 0; y < _h; y++) {
        for (var x = 0; x < s.left; x++) {
          f[y * _w + x] = 16 + (rnd.nextDouble() * s.blankNoise).round();
        }
      }
    }
    // A subtitle in two frames out of three: white blocks across the middle
    // third, its bottom 40 lines above the frame's.
    if (s.subtitles && t % 3 != 0) {
      for (var y = _h - 62; y < _h - 40; y++) {
        for (var x = _w ~/ 3; x < 2 * _w ~/ 3; x++) {
          if ((x ~/ 9 + y ~/ 6 + t) % 3 != 0) f[y * _w + x] = 232;
        }
      }
    }
    // Head switching: each line torn sideways from a picture line above it,
    // with noisy luma and wrecked chroma.
    for (var o = 0; o < s.band; o++) {
      final y = _h - 1 - o;
      final shift = 5 + (o * 3 + t) % 9;
      final src = y - 10;
      for (var x = 0; x < _w; x++) {
        final i = y * _w + x;
        final from = f[src * _w + (x - shift + _w) % _w];
        f[i] = (from * 0.7 + 40 + (rnd.nextDouble() - 0.5) * 50).round().clamp(16, 235);
        f[n + i] = (128 + (rnd.nextDouble() - 0.5) * 80).round();
        f[2 * n + i] = (128 + (rnd.nextDouble() - 0.5) * 80).round();
      }
    }
    out.add(f);
  }
  final path = '$_outDir/${s.name}.mkv';
  final p = await Process.start(
    WorkerHarness.ffmpegPath,
    [
      '-y', '-v', 'error',
      '-f', 'rawvideo', '-pix_fmt', 'yuv444p', '-s', '${_w}x$_h', '-r', '25', '-i', '-',
      '-c:v', 'ffv1', '-pix_fmt', 'yuv422p', path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  final err = p.stderr.transform(utf8.decoder).join();
  p.stdout.drain<void>();
  p.stdin.add(out.takeBytes());
  await p.stdin.close();
  if (await p.exitCode != 0) throw Exception('encoding ${s.name}: ${await err}');
  return path;
}

/// Run the worker's `--detect-crop` on [path]; returns the report and the time.
Future<(Map<String, dynamic>, Duration)> _detect(
  String path, {
  required int width,
  required int height,
  required int frames,
  required double fps,
  required String pixFmt,
  String fieldOrder = 'progressive',
}) async {
  final job = {
    'id': const Uuid().v4(),
    'inputPath': path,
    'outputPath': '$_outDir/unused.mkv',
    'qtgmcParameters': {'enabled': false},
    'processingPipeline': {
      'deinterlace': {'enabled': false},
    },
    'encodingSettings': <String, dynamic>{},
    'detectedFieldOrder': fieldOrder,
    'totalFrames': frames,
    'inputFrameRate': fps,
    'inputWidth': width,
    'inputHeight': height,
    'inputPixelFormat': pixFmt,
  };
  final config = File('$_outDir/${job['id']}.json');
  await config.writeAsString(jsonEncode(job));
  final sw = Stopwatch()..start();
  final r = await Process.run(
    WorkerHarness.workerPath,
    ['--detect-crop', '--config', config.path],
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
  return (report, sw.elapsed);
}

/// The measured (unrounded) value for one edge.
int _edge(Map<String, dynamic> r, String side, [String key = 'crop']) =>
    ((r['edges'] as Map)[side] as Map)[key] as int;

String _kind(Map<String, dynamic> r, String side) => ((r['edges'] as Map)[side] as Map)['kind'] as String;

void _near(Map<String, dynamic> r, String side, int expected, {String key = 'crop'}) {
  final got = _edge(r, side, key);
  expect((got - expected).abs(), lessThanOrEqualTo(2),
      reason: '$side ($key): measured $got, drawn $expected');
}

void _summary(String name, Map<String, dynamic> r, Duration t) {
  final e = r['edges'] as Map;
  String side(String s) {
    final m = e[s] as Map;
    return '$s ${m['kind']} ${m['crop']}/${m['cropWithBars']} (conf ${(m['confidence'] as num).toStringAsFixed(2)})';
  }

  print('  $name: ${t.inMilliseconds} ms, usable ${r['usableFrames']}/${(r['frames'] as List).length}, '
      'crop ${r['crop']}  ${side('left')}; ${side('right')}; ${side('top')}; ${side('bottom')}');
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  Future<Map<String, dynamic>> run(_Spec s, {String fieldOrder = 'progressive'}) async {
    final path = await _fixture(s);
    final (r, t) = await _detect(path,
        width: _w, height: _h, frames: _frames, fps: 25, pixFmt: 'yuv422p', fieldOrder: fieldOrder);
    _summary(s.name, r, t);
    return r;
  }

  test('VHS: blanking, noisy blanking and a head-switching band', () async {
    final r = await run(const _Spec('vhs', left: 14, right: 10, top: 2, band: 8, blankNoise: 12));
    expect(r['found'], isTrue);
    _near(r, 'left', 14);
    _near(r, 'right', 10);
    _near(r, 'top', 2);
    expect(_kind(r, 'bottom'), 'headSwitching');
    _near(r, 'bottom', 8);
    // Rounded outward to even values the Crop pass accepts.
    final crop = r['crop'] as Map;
    for (final side in ['left', 'right', 'top', 'bottom']) {
      expect((crop[side] as int) % 2, 0, reason: side);
      expect(crop[side] as int, greaterThanOrEqualTo(_edge(r, side)), reason: side);
    }
    expect(r['edgeRepair'], {'left': 0, 'right': 0, 'top': 0, 'bottom': 8});
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('interlaced: the band is found per field, the crop in fours', () async {
    final r = await run(const _Spec('vhs_interlaced', left: 14, right: 10, band: 12),
        fieldOrder: 'tff');
    expect(r['interlaced'], isTrue);
    _near(r, 'left', 14);
    _near(r, 'right', 10);
    expect(_kind(r, 'bottom'), 'headSwitching');
    _near(r, 'bottom', 12);
    // 4:2:2 keeps its chroma per line, so twos are enough here.
    expect(r['stepY'], 2);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('letterbox: the bars are reported but not in the recommended crop', () async {
    final r = await run(const _Spec('letterbox', left: 8, right: 8, top: 72, bottom: 72));
    expect(_kind(r, 'top'), 'bar');
    expect(_kind(r, 'bottom'), 'bar');
    expect((r['crop'] as Map)['top'], 0);
    expect((r['crop'] as Map)['bottom'], 0);
    _near(r, 'top', 72, key: 'cropWithBars');
    _near(r, 'bottom', 72, key: 'cropWithBars');
    _near(r, 'left', 8);
    _near(r, 'right', 8);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('burnt-in subtitles near the bottom are not head switching', () async {
    final r = await run(const _Spec('subtitles', left: 8, right: 8, subtitles: true));
    expect(_kind(r, 'bottom'), isNot('headSwitching'));
    expect(_edge(r, 'bottom'), lessThanOrEqualTo(2));
    _near(r, 'left', 8);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('fades to black do not move the edges', () async {
    final r = await run(const _Spec('fades', left: 12, right: 12, top: 4, fades: true));
    expect(r['usableFrames'] as int, lessThan((r['frames'] as List).length),
        reason: 'the faded frames are left out');
    _near(r, 'left', 12);
    _near(r, 'right', 12);
    _near(r, 'top', 4);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a real DVB-T broadcast: black side bars and bottom lines', () async {
    // Measured by eye on the decoded frames (docs/reports/2026-11-crop-detect-709):
    // 7 black columns left, 8 right, 4 black lines and one dim line at the
    // bottom, nothing at the top.
    final (r, t) = await _detect(_dvbt,
        width: 720, height: 576, frames: 250, fps: 25, pixFmt: 'yuv420p', fieldOrder: 'tff');
    _summary('pal-dvbt', r, t);
    _near(r, 'left', 7);
    _near(r, 'right', 8);
    _near(r, 'top', 0);
    _near(r, 'bottom', 5);
    // Still interlaced 4:2:0 at the crop (deinterlacing is off here): fours.
    expect(r['stepY'], 4);
    expect((r['crop'] as Map)['bottom'], 8);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the real VHS capture: its blanking is found', () async {
    // 10 dark columns then a ramp at the left, a narrower one at the right,
    // and one black first line (see the report).
    final (r, t) = await _detect(_vhs,
        width: 720, height: 576, frames: 79, fps: 25, pixFmt: 'yuv422p', fieldOrder: 'tff');
    _summary('interlaced_test', r, t);
    expect(r['found'], isTrue);
    expect(_edge(r, 'left', 'blank'), inInclusiveRange(8, 12));
    expect(_edge(r, 'left'), inInclusiveRange(10, 18));
    expect(_edge(r, 'right'), inInclusiveRange(3, 9));
    expect(_edge(r, 'top'), 1);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
