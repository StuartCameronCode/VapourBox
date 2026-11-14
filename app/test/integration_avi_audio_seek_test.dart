// A delayed AVI trimmed near its start keeps its sound (task 22, follow-up
// to issue #173).
//
// ffmpeg starts an input seek 3/23 s early when any stream of the file has a
// decoder delay, and an AVI cannot seek before its start, so a seek of the
// SOUND below ~0.12 s failed ("could not seek to position") and decoding
// resumed ~1.4 s in: a trim of avi_h264_bframes.avi from frame 2 came out
// with its sound starting 1.277 s late. The picture was fixed by #173 (count
// from the start); the sound now follows `source_decode` rule 9: decodes
// skip after decoding, and the copy encode seeks a NUT copy of the sound.
//
// avi_h264_bframes.avi's sound is a 440 Hz sine, which cannot show the fault:
// 1.3 s is exactly 572 periods. So the sync checks run on a copy whose sound
// is a chirp (made here, the video stream-copied: the decode-order
// timestamps and the fault come with it), where any offset shows.
//
// A stream copy keeps the source's sound from the packet its seek lands on,
// here the file's start (the fixture has one keyframe). Matroska carries that
// pre-roll in its timestamps, so it stays in sync; AVI cannot, so its sound
// runs late by up to the in-point, as every copy trim to AVI does (frame 20
// too, 667 ms, without this fix touching it). That is a separate fault and
// only bounded here. See docs/reports/2026-11-avi-audio-seek.
@Tags(['heavy'])
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'support/audio_fixtures.dart';
import 'support/worker_harness.dart';

const _rate = 32000;
const _fps = 30000 / 1001;
const _end = 61;

String get _outDir => p.join(WorkerHarness.outputDir, 'avi_audio_seek');

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

Map<String, dynamic> _job(
  String input,
  String name, {
  required int start,
  String container = 'mkv',
  Map<String, dynamic> encoding = const {},
  Map<String, dynamic>? audio,
}) =>
    {
      'id': const Uuid().v4(),
      'inputPath': input,
      'outputPath': p.join(_outDir, '$name.$container'),
      'qtgmcParameters': {'enabled': false},
      'processingPipeline': {
        'deinterlace': {'enabled': false},
        if (audio != null) 'audio': {'enabled': true, ...audio},
      },
      'encodingSettings': {
        'container': container,
        'codec': 'ffv1',
        'audioMode': 'passthrough',
        ...encoding,
      },
      'inputFrameRate': _fps,
      'inputWidth': 320,
      'inputHeight': 240,
      'inputPixelFormat': 'yuv420p',
      'startFrame': start,
      'endFrame': _end,
      'totalFrames': _end - start + 1,
    };

Future<String> _encode(Map<String, dynamic> job) async {
  final r = await WorkerHarness.runJob(job, label: p.basename(job['outputPath'] as String));
  expect(r.success, isTrue,
      reason: '${r.error}\n${r.logs.where((l) => !l.contains('"debug"')).join('\n')}');
  return r.outputPath!;
}

/// Each stream's start, on the container's timeline (what ffmpeg's decode
/// counts from), and its duration where stated.
Future<({double video, double audio})> _starts(String path) async {
  final j = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-show_entries', 'stream=codec_type,start_time:format=start_time',
    '-of', 'json', path,
  ]);
  final origin = double.tryParse('${(j['format'] as Map)['start_time']}') ?? 0;
  double of(String type) => double.parse('${(j['streams'] as List).firstWhere(
          (s) => s['codec_type'] == type)['start_time']}') - origin;
  return (video: of('video'), audio: of('audio'));
}

/// The sound of [path] as mono float at 32 kHz, sample 0 at the container's
/// start: a stream that starts later is padded with silence, as a player
/// would leave it.
Future<Float32List> _sound(String path) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-nostdin', '-i', path, '-map', '0:a:0', '-af', 'aresample=first_pts=0',
     '-ac', '1', '-ar', '$_rate', '-f', 'f32le', '-'],
    stdoutEncoding: null,
    environment: WorkerHarness.ffmpegEnv,
  );
  if (r.exitCode != 0) throw StateError('decode $path: ${r.stderr}');
  final bytes = Uint8List.fromList(r.stdout as List<int>);
  return bytes.buffer.asFloat32List(0, bytes.lengthInBytes ~/ 4);
}

/// Where the output's sound sits against its picture, in samples (+ = the
/// sound is late): 0 when the sound under the output's first picture is
/// the source's sound at the in-point. Found by cross-correlating a second of
/// chirp within a quarter second either way, and only when the peak is
/// strong (normalised > 0.9): otherwise the sound is not there at all, and
/// this returns null.
int? _syncLag(Float32List source, Float32List output, int start, double videoStart) {
  final inPoint = (start / _fps * _rate).round();
  final picture = (videoStart * _rate).round();
  const n = _rate;
  const maxLag = _rate ~/ 4;
  double at(int k) => k >= 0 && k < output.length ? output[k] : 0;
  var refEnergy = 0.0;
  for (var i = 0; i < n; i++) {
    refEnergy += source[inPoint + i] * source[inPoint + i];
  }
  int? best;
  var bestScore = 0.0;
  for (var l = -maxLag; l <= maxLag; l++) {
    var dot = 0.0, energy = 0.0;
    for (var i = 0; i < n; i += 2) {
      final x = at(picture + l + i);
      dot += source[inPoint + i] * x;
      energy += x * x;
    }
    final score = dot / math.sqrt(refEnergy / 2 * energy + 1e-12);
    if (score > bestScore) {
      bestScore = score;
      best = l;
    }
  }
  // The output sample at picture + l holds the source's in-point sample: the
  // sound is l samples late.
  return bestScore > 0.9 ? best : null;
}

double _maxDiff(Float32List a, int aFrom, Float32List b, int bFrom, int n) {
  var m = 0.0;
  for (var i = 0; i < n; i++) {
    m = math.max(m, (a[aFrom + i] - b[bFrom + i]).abs());
  }
  return m;
}

void main() {
  late String chirp;
  late Float32List source;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    Directory(_outDir).createSync(recursive: true);
    // The fixture's picture, stream-copied (decode-order timestamps and all),
    // with a chirp for sound.
    chirp = p.join(_outDir, 'chirp_h264_bframes.avi');
    await AudioFixtures.ffmpeg([
      '-i', _resource('avi_h264_bframes.avi'),
      '-f', 'lavfi', '-i', 'aevalsrc=0.5*sin(2*PI*(200*t+300*t*t)):s=$_rate:d=3.003',
      '-map', '0:v', '-c:v', 'copy', '-map', '1:a', '-c:a', 'pcm_s16le',
      chirp,
    ]);
    final v = await WorkerHarness.firstStream(chirp,
        selector: 'v:0', entries: ['has_b_frames']);
    expect(v!['has_b_frames'], 2, reason: 'the copy must keep the decoder delay');
    source = await _sound(chirp);
  });

  // The task's own case: the committed fixture (PCM), copied to MKV. Before
  // the fix its sound started 1.277 s after the picture.
  for (final start in [1, 2, 3]) {
    test('a stream copy of avi_h264_bframes.avi from frame $start keeps its sound '
        'and every frame', () async {
      final out = await _encode(_job(_resource('avi_h264_bframes.avi'), 'copy_$start',
          start: start));
      final starts = await _starts(out);
      expect(starts.audio, lessThanOrEqualTo(starts.video + 0.001), reason: '$starts');
      final count = int.parse('${(await WorkerHarness.ffprobeJson([
        '-v', 'error', '-count_packets', '-select_streams', 'v:0',
        '-show_entries', 'stream=nb_read_packets', '-of', 'json', out,
      ]))['streams'][0]['nb_read_packets']}');
      expect(count, _end - start + 1);
      // The sound runs to within a packet of the picture's end.
      final pictureEnd = starts.video + count / _fps;
      final soundEnd = (await _sound(out)).length / _rate;
      expect(soundEnd, greaterThan(pictureEnd - 0.05),
          reason: 'sound ends $soundEnd s, picture $pictureEnd s');
    });
  }

  // Frames 1-3 are below the failed seek; 20 is the control.
  for (final start in [1, 2, 3, 20]) {
    test('the chirp copied to MKV from frame $start is in sync', () async {
      final out = await _encode(_job(chirp, 'chirp_mkv_$start', start: start));
      final starts = await _starts(out);
      final lag = _syncLag(source, await _sound(out), start, starts.video);
      // Matroska stores milliseconds: 32 samples at 32 kHz. Before the fix
      // the sound was 1.28 s off.
      expect(lag, isNotNull, reason: 'the in-point\'s sound is not near the picture: $starts');
      expect(lag!.abs(), lessThanOrEqualTo(40), reason: 'lag $lag samples, $starts');
    });
  }

  for (final start in [1, 2, 3]) {
    test('the chirp copied to AVI from frame $start is late by at most the in-point', () async {
      final out = await _encode(_job(chirp, 'chirp_avi_$start', start: start, container: 'avi'));
      final starts = await _starts(out);
      final lag = _syncLag(source, await _sound(out), start, starts.video);
      // AVI drops the copy's pre-roll timing: late by at most the in-point
      // (see the header). Before the fix it was 1.28 s early.
      final inPoint = (start / _fps * _rate).round();
      expect(lag, isNotNull, reason: 'the in-point\'s sound is not near the picture: $starts');
      expect(lag, inInclusiveRange(-40, inPoint + 40), reason: 'lag $lag samples, $starts');
    });
  }

  test('re-encoded from frame 2, the sound is the source sample for sample', () async {
    final out = await _encode(_job(chirp, 'flac_2',
        start: 2, encoding: {'audioMode': 'convert', 'audioCodec': 'flac'}));
    final starts = await _starts(out);
    expect(starts.video, closeTo(0, 1e-3));
    expect(starts.audio, closeTo(0, 1e-3));
    final sound = await _sound(out);
    final from = (2 / _fps * _rate).round(); // 2135
    expect(_maxDiff(source, from, sound, 0, _rate * 3 ~/ 2), lessThan(1e-6));
  });

  test('Audio Restoration from frame 2 reads the sound at the in-point', () async {
    // A limiter at 0 dB on a -6 dB chirp changes nothing: the rendered track
    // must be the source from the in-point, exactly the picture's length.
    final out = await _encode(_job(chirp, 'restored_2',
        start: 2, audio: {'limiter': true, 'limiterCeilingDb': 0}));
    final starts = await _starts(out);
    expect(starts.audio, closeTo(starts.video, 1e-3));
    final sound = await _sound(out);
    final from = (2 / _fps * _rate).round();
    expect(sound.length, ((_end - 2 + 1) / _fps * _rate).round(),
        reason: 'the rendered track is the picture\'s length');
    expect(_maxDiff(source, from, sound, 0, _rate * 3 ~/ 2), lessThan(1e-4));
  });
}
