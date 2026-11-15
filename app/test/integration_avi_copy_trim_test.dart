// A Passthrough trim into AVI keeps its sound in sync (task 24).
//
// A stream copy keeps the source's packets from where the demuxer's seek
// lands: the keyframe before the in-point, here up to 0.4 s early
// (small_clip.mp4's picture has a keyframe every 0.4 s). Matroska and MP4
// store that pre-roll as a later video start; AVI cannot store where a
// stream starts, so the extra sound played under the first picture and the
// whole track ran late (0.08-0.38 s on these fixtures, a GOP at worst).
//
// The fix (`audio_restoration::SoundCut`): PCM is re-written in its own
// codec, seeked and decoded, so it is the source sample for sample; a
// compressed stream is still copied, from the packet nearest the in-point
// (within half a packet). Measured against an exact reference, a chirp,
// never start_time tags. See docs/reports/2026-11-avi-copy-trim.
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

const _rate = 48000;
const _fps = 30000 / 1001;
const _end = 340;
const _seconds = 12;
// Rises from 150 Hz to 3030 Hz over 12 s: no stretch of it repeats.
const _chirp = 'aevalsrc=0.5*sin(2*PI*(150*t+120*t*t)):s=$_rate:d=$_seconds';

String get _outDir => p.join(WorkerHarness.outputDir, 'avi_copy_trim');

Map<String, dynamic> _job(String input, String name, int start, String container) => {
      'id': const Uuid().v4(),
      'inputPath': input,
      'outputPath': p.join(_outDir, '$name.$container'),
      'qtgmcParameters': {'enabled': false},
      'processingPipeline': {
        'deinterlace': {'enabled': false},
      },
      'encodingSettings': {
        'container': container,
        'codec': 'ffv1',
        'audioMode': 'passthrough',
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

/// The video's start on the container's timeline.
Future<double> _videoStart(String path) async {
  final j = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-show_entries', 'stream=codec_type,start_time:format=start_time',
    '-of', 'json', path,
  ]);
  final origin = double.tryParse('${(j['format'] as Map)['start_time']}') ?? 0;
  return double.parse('${(j['streams'] as List).firstWhere(
          (s) => s['codec_type'] == 'video')['start_time']}') - origin;
}

Future<String> _codec(String path, int stream) async =>
    '${(await WorkerHarness.firstStream(path, selector: 'a:$stream', entries: ['codec_name']))!['codec_name']}';

/// Audio stream [stream] of [path] as mono float at 48 kHz, sample 0 at the
/// container's start (a stream that starts later is padded with silence).
Future<Float32List> _sound(String path, [int stream = 0]) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-nostdin', '-i', path, '-map', '0:a:$stream', '-af', 'aresample=first_pts=0',
     '-ac', '1', '-ar', '$_rate', '-f', 'f32le', '-'],
    stdoutEncoding: null,
    environment: WorkerHarness.ffmpegEnv,
  );
  if (r.exitCode != 0) throw StateError('decode $path: ${r.stderr}');
  final bytes = Uint8List.fromList(r.stdout as List<int>);
  return bytes.buffer.asFloat32List(0, bytes.lengthInBytes ~/ 4);
}

/// Where the output's sound sits against its first picture, in samples (+ =
/// late): the lag at which a quarter second of the source's chirp, half a
/// second after the in-point, best matches the output, searched within a
/// quarter second either way. Null when the match is weak (the sound is not
/// there at all).
int? _syncLag(Float32List source, Float32List output, int start, double videoStart) {
  final from = (start / _fps * _rate).round() + _rate ~/ 2;
  final at = (videoStart * _rate).round() + _rate ~/ 2;
  const n = _rate ~/ 4;
  const maxLag = _rate ~/ 4;
  var refEnergy = 0.0;
  for (var i = 0; i < n; i++) {
    refEnergy += source[from + i] * source[from + i];
  }
  int? best;
  var bestScore = 0.0;
  for (var l = -maxLag; l <= maxLag; l++) {
    final o = at + l;
    if (o < 0 || o + n > output.length) continue;
    var dot = 0.0, energy = 0.0;
    for (var i = 0; i < n; i++) {
      final x = output[o + i];
      dot += source[from + i] * x;
      energy += x * x;
    }
    final score = dot / math.sqrt(refEnergy * energy + 1e-12);
    if (score > bestScore) {
      bestScore = score;
      best = l;
    }
  }
  return bestScore > 0.9 ? best : null;
}

/// The largest difference between the output from its first picture and the
/// source from the in-point, over a second.
double _maxDiffFromInPoint(Float32List source, Float32List output, int start, double videoStart) {
  final from = (start / _fps * _rate).round();
  final at = (videoStart * _rate).round();
  var m = 0.0;
  for (var i = 0; i < _rate; i++) {
    m = math.max(m, (source[from + i] - output[at + i]).abs());
  }
  return m;
}

void main() {
  final sources = <String, String>{};

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    Directory(_outDir).createSync(recursive: true);
    final clip = p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'small_clip.mp4');
    Future<String> make(String name, List<String> audio) async {
      final out = p.join(_outDir, name);
      await AudioFixtures.ffmpeg([
        '-t', '$_seconds', '-i', clip, '-f', 'lavfi', '-i', _chirp,
        '-map', '0:v', '-c:v', 'copy', '-map', '1:a', ...audio, '-t', '$_seconds', out,
      ]);
      return out;
    }

    sources['pcm'] = await make('src_pcm.avi', ['-c:a', 'pcm_s16le']);
    sources['ac3_avi'] = await make('src_ac3.avi', ['-c:a', 'ac3', '-b:a', '192k']);
    sources['aac_mp4'] = await make('src_aac.mp4', ['-c:a', 'aac', '-b:a', '192k']);
    sources['ac3_mkv'] = await make('src_ac3.mkv', ['-c:a', 'ac3', '-b:a', '192k']);
    final two = p.join(_outDir, 'src_two.avi');
    await AudioFixtures.ffmpeg([
      '-i', sources['pcm']!, '-i', sources['ac3_avi']!,
      '-map', '0:v', '-map', '0:a', '-map', '1:a', '-c', 'copy', two,
    ]);
    sources['two'] = two;
    // Task 22's delayed AVI (decoder delay, one keyframe) with an MP3 chirp:
    // trims under half a second read the sound from the NUT copy.
    final mp3 = p.join(_outDir, 'src_mp3_delayed.avi');
    await AudioFixtures.ffmpeg([
      '-i', p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'avi_h264_bframes.avi'),
      '-f', 'lavfi', '-i', 'aevalsrc=0.5*sin(2*PI*(150*t+120*t*t)):s=44100:d=3.003',
      '-map', '0:v', '-c:v', 'copy', '-map', '1:a', '-c:a', 'libmp3lame', '-b:a', '192k', mp3,
    ]);
    sources['mp3_delayed'] = mp3;
  });

  for (final start in [20, 100]) {
    test('PCM trimmed into AVI from frame $start is the source sample for sample', () async {
      final source = await _sound(sources['pcm']!);
      final out = await _encode(_job(sources['pcm']!, 'pcm_$start', start, 'avi'));
      expect(await _codec(out, 0), 'pcm_s16le');
      final vs = await _videoStart(out);
      final sound = await _sound(out);
      // Before the fix: 137-375 ms late.
      expect(_syncLag(source, sound, start, vs), 0);
      expect(_maxDiffFromInPoint(source, sound, start, vs), 0);
    });
  }

  // Half a packet, plus a millisecond for the AVI demuxer's own timestamps.
  // AC-3 packets are 32 ms, AAC's 21.3 ms.
  for (final (key, packetMs, codec) in [
    ('ac3_avi', 32.0, 'ac3'),
    ('aac_mp4', 1024 / 48, 'aac'),
    ('ac3_mkv', 32.0, 'ac3'),
  ]) {
    for (final start in [20, 100]) {
      test('$key trimmed into AVI from frame $start is copied, within half a packet', () async {
        final source = await _sound(sources[key]!);
        final out = await _encode(_job(sources[key]!, '${key}_$start', start, 'avi'));
        expect(await _codec(out, 0), codec, reason: 'still a copy');
        final lag = _syncLag(source, await _sound(out), start, await _videoStart(out));
        expect(lag, isNotNull);
        final bound = ((packetMs / 2 + 1) * _rate / 1000).round();
        // Before the fix: 76-375 ms late.
        expect(lag!.abs(), lessThanOrEqualTo(bound), reason: 'lag $lag samples');
        if (key.endsWith('_avi')) {
          // From an AVI the sound's own timestamps limit MKV just as much:
          // the AVI output now matches it.
          final mkv = await _encode(_job(sources[key]!, '${key}_${start}_ref', start, 'mkv'));
          final ref = _syncLag(source, await _sound(mkv), start, await _videoStart(mkv));
          expect((lag - ref!).abs(), lessThanOrEqualTo(_rate ~/ 1000), reason: 'avi $lag, mkv $ref');
        }
      });
    }
  }

  test('two streams trimmed into AVI: PCM exact, AC-3 within half a packet', () async {
    final pcm = await _sound(sources['two']!, 0);
    final ac3 = await _sound(sources['two']!, 1);
    const start = 20;
    final out = await _encode(_job(sources['two']!, 'two_$start', start, 'avi'));
    expect(await _codec(out, 0), 'pcm_s16le');
    expect(await _codec(out, 1), 'ac3');
    final vs = await _videoStart(out);
    final s0 = await _sound(out, 0);
    expect(_syncLag(pcm, s0, start, vs), 0);
    expect(_maxDiffFromInPoint(pcm, s0, start, vs), 0);
    final lag = _syncLag(ac3, await _sound(out, 1), start, vs);
    expect(lag, isNotNull);
    expect(lag!.abs(), lessThanOrEqualTo((17 * _rate / 1000).round()), reason: 'lag $lag');
  });

  // Review of task 24: the NUT copy counts MP3 in samples, not packets, so
  // its packet input must seek half a packet early too. Before: -18.9 ms at
  // frame 1 (half an MP3 packet at 44.1 kHz is 13.1 ms).
  for (final start in [1, 2, 3]) {
    test('MP3 under a delayed AVI trimmed into AVI from frame $start is within half a packet', () async {
      final source = await _sound(sources['mp3_delayed']!);
      final job = _job(sources['mp3_delayed']!, 'mp3_delayed_$start', start, 'avi')
        ..['endFrame'] = 61
        ..['totalFrames'] = 61 - start + 1;
      final out = await _encode(job);
      expect(await _codec(out, 0), 'mp3', reason: 'still a copy');
      final lag = _syncLag(source, await _sound(out), start, await _videoStart(out));
      expect(lag, isNotNull);
      final bound = ((1152 / 44.1 / 2 + 1) * _rate / 1000).round();
      expect(lag!.abs(), lessThanOrEqualTo(bound), reason: 'lag $lag samples');
    });
  }

  test('MKV keeps its copy: the pre-roll is stored and the sound in sync', () async {
    final source = await _sound(sources['aac_mp4']!);
    final out = await _encode(_job(sources['aac_mp4']!, 'aac_mkv_20', 20, 'mkv'));
    expect(await _codec(out, 0), 'aac');
    final vs = await _videoStart(out);
    expect(vs, greaterThan(0.2), reason: 'the copy keeps the pre-roll before the picture');
    final lag = _syncLag(source, await _sound(out), 20, vs);
    expect(lag!.abs(), lessThanOrEqualTo(_rate ~/ 1000));
  });
}
