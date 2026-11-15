// Integration test: audio restoration, measured on the encoded output.
//
// Every fixture is made with ffmpeg's lavfi generators, so what the audio
// should be afterwards is known exactly: a click track's onsets say where the
// sound is in time (offset, drift, trim, filter delays), a tone's level says
// what survived, and a gap's level says how much noise is left.
//
// Heavy: full encodes. Run with
//   flutter test --tags heavy test/integration_audio_restoration_test.dart
@Tags(['heavy'])
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/audio_fixtures.dart';
import 'support/worker_harness.dart';

const _rate = 48000;

/// Clicks (3 ms bursts of 3 kHz) at irregular times: two interleaved
/// periodic tracks, so no shift lines one click up with another.
const _clickExpr = "aevalsrc='0.8*sin(2*PI*3000*t)*(lt(mod(t\\,0.7)\\,0.003)+lt(mod(t+0.23\\,1.1)\\,0.003))'";

/// Encode [job] and return the output path, failing with the worker's log.
Future<String> _encode(Map<String, dynamic> job, {Duration timeout = const Duration(minutes: 5)}) async {
  final result = await WorkerHarness.runJob(job, label: job['outputPath'] as String, timeout: timeout);
  expect(result.success, isTrue,
      reason: '${result.error}\n${result.logs.where((l) => !l.contains('"debug"')).join('\n')}');
  return result.outputPath!;
}

/// Asserts the output's clicks are the source's moved by [map]: every click
/// expected inside the track (away from its ends) is found within
/// [tolerance] seconds, and every click found there was expected.
void _expectOnsets(List<double> source, List<double> output, double Function(double) map,
    double length, {double tolerance = 0.001}) {
  const margin = 0.1;
  bool inside(double t) => t > margin && t < length - margin;
  final expected = source.map(map).toList();
  double nearest(List<double> list, double t) =>
      list.reduce((a, b) => (a - t).abs() < (b - t).abs() ? a : b);
  final checked = expected.where(inside).toList();
  expect(checked.length, greaterThan(4), reason: 'too few clicks to judge');
  for (final t in checked) {
    final got = nearest(output, t);
    expect((got - t).abs(), lessThan(tolerance),
        reason: 'a click expected at ${t.toStringAsFixed(4)} s is nearest ${got.toStringAsFixed(4)} s');
  }
  for (final t in output.where(inside)) {
    expect((nearest(expected, t) - t).abs(), lessThan(tolerance),
        reason: 'a click at ${t.toStringAsFixed(4)} s was not expected');
  }
}

/// RMS level in 1 ms frames: an envelope to cross-correlate.
Float32List _envelope(Float32List x) {
  const frame = _rate ~/ 1000;
  return Float32List.fromList([
    for (var i = 0; i + frame <= x.length; i += frame)
      math.sqrt([for (var j = i; j < i + frame; j++) x[j] * x[j]].reduce((a, b) => a + b) / frame),
  ]);
}

/// Integrated loudness (LUFS) by ffmpeg's EBU R128 meter.
Future<double> _loudness(String path) async {
  final r = await Process.run(WorkerHarness.ffmpegPath,
      ['-hide_banner', '-nostats', '-i', path, '-map', '0:a:0', '-af', 'ebur128', '-f', 'null', '-'],
      environment: WorkerHarness.ffmpegEnv);
  final m = RegExp(r'I:\s+(-?[\d.]+) LUFS').allMatches(r.stderr as String).last;
  return double.parse(m.group(1)!);
}

void main() {
  late String clicks;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    clicks = await AudioFixtures.source('clicks',
        seconds: 8, filterComplex: '$_clickExpr:s=$_rate:d=8,pan=stereo|c0=c0|c1=c0[a]');
  });

  test('a dead channel is replaced: both channels come out equal', () async {
    final src = await AudioFixtures.source('dead_right',
        filterComplex: 'sine=f=1000:r=$_rate:d=6,pan=stereo|c0=0.5*c0|c1=0*c0[a]');
    final out = await _encode(AudioFixtures.job(src, {'channelFix': 'auto'}, label: 'dead_right'));
    final ch = await AudioFixtures.decode(out);
    expect(ch, hasLength(2));
    final left = AudioFixtures.rmsDb(ch[0]), right = AudioFixtures.rmsDb(ch[1]);
    expect(left, closeTo(20 * math.log(0.5 / math.sqrt2) / math.ln10 - 18.06, 0.5),
        reason: 'the live channel keeps its level');
    expect(right, closeTo(left, 0.01), reason: 'the dead channel now carries the same');
    expect(await AudioFixtures.audioSeconds(out), closeTo(6.0, 0.001));
  });

  group('sync offset', () {
    for (final ms in [250, -250]) {
      test('$ms ms moves every click by $ms ms', () async {
        final out = await _encode(AudioFixtures.job(clicks, {'offsetMs': ms}, label: 'offset_$ms'));
        final source = AudioFixtures.onsets((await AudioFixtures.decode(clicks, mono: true)).first, _rate);
        final output = AudioFixtures.onsets((await AudioFixtures.decode(out, mono: true)).first, _rate);
        _expectOnsets(source, output, (t) => t + ms / 1000, 8.0);
        expect(await AudioFixtures.audioSeconds(out), closeTo(8.0, 0.001),
            reason: 'the track is cut or padded to the picture');
      });
    }

    test('with a trim, the offset is from the in-point', () async {
      // Frames 25–174: 1.0 s to 7.0 s.
      final out = await _encode(AudioFixtures.job(clicks, {'offsetMs': 300},
          label: 'offset_trim', extra: {'startFrame': 25, 'endFrame': 174, 'totalFrames': 150}));
      final source = AudioFixtures.onsets((await AudioFixtures.decode(clicks, mono: true)).first, _rate);
      final output = AudioFixtures.onsets((await AudioFixtures.decode(out, mono: true)).first, _rate);
      _expectOnsets(source, output, (t) => t - 1.0 + 0.3, 6.0);
      expect(await AudioFixtures.audioSeconds(out), closeTo(6.0, 0.001));
    });
  });

  test('drift correction scales the track to the picture', () async {
    // 20 s of picture, 20.08 s of audio (0.4% fast clock): clicks at
    // audio-time t belong at picture-time t / 1.004.
    final trimmedVideo = '${AudioFixtures.dir.path}/drift.mkv';
    if (!File(trimmedVideo).existsSync()) {
      await AudioFixtures.ffmpeg([
        '-f', 'lavfi', '-i', 'testsrc2=s=160x120:r=25:d=20',
        '-f', 'lavfi', '-i', '$_clickExpr:s=$_rate:d=20.08',
        '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'ultrafast',
        '-pix_fmt', 'yuv420p', '-c:a', 'flac', trimmedVideo,
      ]);
    }
    final out = await _encode(AudioFixtures.job(trimmedVideo, {'driftCorrection': true},
        label: 'drift', extra: {'totalFrames': 500}));
    final source = AudioFixtures.onsets((await AudioFixtures.decode(trimmedVideo, mono: true)).first, _rate);
    final output = AudioFixtures.onsets((await AudioFixtures.decode(out, mono: true)).first, _rate);
    final factor = (await AudioFixtures.audioSeconds(trimmedVideo)) / 20.0;
    expect(factor, closeTo(1.004, 0.0005));
    _expectOnsets(source, output, (t) => t / factor, 20.0, tolerance: 0.002);
    expect(await AudioFixtures.audioSeconds(out), closeTo(20.0, 0.001));
  });

  test('hum removal notches 50 Hz and its harmonics, and keeps a 1 kHz tone', () async {
    final src = await AudioFixtures.source('hum50',
        filterComplex: 'sine=f=1000:r=$_rate:d=6[t];sine=f=50:r=$_rate:d=6[h1];'
            'sine=f=100:r=$_rate:d=6[h2];sine=f=150:r=$_rate:d=6[h3];'
            "[t][h1][h2][h3]amix=inputs=4:weights='1 0.8 0.4 0.3':normalize=0,"
            'pan=stereo|c0=c0|c1=c0[a]');
    final out = await _encode(AudioFixtures.job(src, {'humRemoval': true, 'humFrequency': 'auto'}, label: 'hum'));
    // Two seconds in the middle: the notches' own settling is over.
    Float32List mid(Float32List x) => Float32List.sublistView(x, 2 * _rate, 4 * _rate);
    final before = mid((await AudioFixtures.decode(src, mono: true)).first);
    final after = mid((await AudioFixtures.decode(out, mono: true)).first);
    for (final f in [50.0, 100.0, 150.0]) {
      final drop = AudioFixtures.bandDb(before, _rate, f) - AudioFixtures.bandDb(after, _rate, f);
      expect(drop, greaterThan(30), reason: '$f Hz down by only ${drop.toStringAsFixed(1)} dB');
    }
    final tone = AudioFixtures.bandDb(after, _rate, 1000) - AudioFixtures.bandDb(before, _rate, 1000);
    expect(tone.abs(), lessThan(0.5), reason: 'the 1 kHz tone changed by $tone dB');
  });

  test('afftdn lowers the noise floor without moving the clicks', () async {
    final src = await AudioFixtures.source('clicks_noise',
        seconds: 8,
        filterComplex: '$_clickExpr:s=$_rate:d=8[c];anoisesrc=c=white:a=0.02:r=$_rate:d=8:seed=7[n];'
            '[c][n]amix=inputs=2:normalize=0,pan=stereo|c0=c0|c1=c0[a]');
    final out = await _encode(AudioFixtures.job(src, {'denoise': true, 'denoiseStrength': 20}, label: 'afftdn'));
    final before = (await AudioFixtures.decode(src, mono: true)).first;
    final after = (await AudioFixtures.decode(out, mono: true)).first;
    final source = AudioFixtures.onsets(before, _rate);
    _expectOnsets(source, AudioFixtures.onsets(after, _rate), (t) => t, 8.0);
    // Noise in a click-free stretch (the clicks are 3 ms; 0.71–0.86 s and
    // 4.0–4.12 s are clear of both tracks), after afftdn has adapted.
    double floor(Float32List x) =>
        AudioFixtures.rmsDb(x, from: (4.0 * _rate).round(), to: (4.12 * _rate).round());
    final drop = floor(before) - floor(after);
    expect(drop, greaterThan(6), reason: 'noise floor down by only ${drop.toStringAsFixed(1)} dB');
  });

  test('loudness normalisation hits its target within 1 LU', () async {
    final src = await AudioFixtures.source('quiet_speechlike',
        seconds: 10,
        // A 200 Hz buzz, syllable-modulated, well under the target.
        filterComplex: "aevalsrc='0.05*sin(2*PI*200*t)*(0.6+0.4*sin(2*PI*4*t))*lt(mod(t\\,1.5)\\,1.0)'"
            ':s=$_rate:d=10,pan=stereo|c0=c0|c1=c0[a]');
    expect(await _loudness(src), lessThan(-30));
    for (final target in [-23.0, -16.0]) {
      final out = await _encode(AudioFixtures.job(src,
          {'loudnessNormalize': true, 'loudnessTarget': target, 'limiter': true},
          label: 'loudness_${target.abs().round()}'));
      expect(await _loudness(out), closeTo(target, 1.0));
      expect(await AudioFixtures.audioSeconds(out), closeTo(10.0, 0.001));
    }
  });

  test('a late-starting audio stream keeps its place', () async {
    // The audio starts 0.5 s after the picture; the encode used to keep that
    // through the container's timestamps, the rendered track keeps it in samples.
    final late = '${AudioFixtures.dir.path}/late_audio.mkv';
    if (!File(late).existsSync()) {
      await AudioFixtures.ffmpeg(['-i', clicks, '-itsoffset', '0.5', '-i', clicks,
          '-map', '0:v', '-map', '1:a', '-c', 'copy', '-t', '8', late]);
    }
    final out = await _encode(AudioFixtures.job(late, {'limiter': true}, label: 'late_audio'));
    final source = AudioFixtures.onsets((await AudioFixtures.decode(clicks, mono: true)).first, _rate);
    final output = AudioFixtures.onsets((await AudioFixtures.decode(out, mono: true)).first, _rate);
    _expectOnsets(source, output, (t) => t + 0.5, 8.0);
  });

  group('several audio streams', () {
    late String twoStreams;
    setUpAll(() async {
      final base = await AudioFixtures.source('two_streams_base',
          audioStreams: 2,
          filterComplex: 'sine=f=440:r=$_rate:d=6[a0];'
              'sine=f=660:r=44100:d=6,pan=stereo|c0=c0|c1=0*c0[a1]');
      twoStreams = '${AudioFixtures.dir.path}/two_streams.mkv';
      if (!File(twoStreams).existsSync()) {
        await AudioFixtures.ffmpeg(['-i', base, '-map', '0', '-c', 'copy',
            '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=jpn', twoStreams]);
      }
    });

    test('the chosen stream is restored and first; the other is copied untouched', () async {
      final out = await _encode(AudioFixtures.job(twoStreams,
          {'streamIndex': 1, 'channelFix': 'auto'}, label: 'two_streams'));
      final streams = (await WorkerHarness.ffprobeJson(['-v', 'error', '-of', 'json',
          '-select_streams', 'a', '-show_entries', 'stream=codec_name,channels,sample_rate:stream_tags=language', out]))['streams'] as List;
      expect(streams, hasLength(2));
      expect(streams[0]['codec_name'], 'flac', reason: 'restored, encoded (passthrough in MKV)');
      expect(streams[0]['sample_rate'], '44100');
      expect((streams[0]['tags'] as Map)['language'], 'jpn', reason: 'its own tags come with it');
      expect((streams[1]['tags'] as Map)['language'], 'eng');
      final restored = await AudioFixtures.decode(out, rate: 44100);
      expect(AudioFixtures.rmsDb(restored[1]), closeTo(AudioFixtures.rmsDb(restored[0]), 0.01),
          reason: 'the dead right channel was fixed');
      final copied = (await AudioFixtures.decode(out, stream: 1)).first;
      final original = (await AudioFixtures.decode(twoStreams, stream: 0)).first;
      expect(copied.length, original.length);
      var maxDiff = 0.0;
      for (var i = 0; i < copied.length; i++) {
        maxDiff = math.max(maxDiff, (copied[i] - original[i]).abs());
      }
      expect(maxDiff, 0, reason: 'the other stream is copied bit for bit');
    });

    test('in MP4 with audio copied, the restored stream is AAC', () async {
      final out = await _encode(AudioFixtures.job(twoStreams, {'limiter': true},
          container: 'mp4', label: 'two_streams_mp4',
          encoding: {'audioMode': 'passthrough'}));
      final first = await WorkerHarness.firstStream(out, selector: 'a:0', entries: ['codec_name']);
      expect(first!['codec_name'], 'aac');
    });
  });

  test('beside ProRes or v210, and in AVI, with audio copied, the restored stream is 24-bit PCM', () async {
    // An editing intermediate keeps its restored audio lossless and 24-bit, and
    // so does AVI beside any codec (restored_passthrough_codec;
    // docs/reports/2026-11-intermediate-pcm-depth, F6 for AVI): AAC would be a
    // second lossy generation, 16-bit rounds the float render's quietest detail
    // away. The same render in MKV (FLAC, already 24-bit) is the reference:
    // every one must decode to the same samples.
    Future<List<int>> s32(String path) async {
      final r = await Process.run(WorkerHarness.ffmpegPath,
          ['-v', 'error', '-i', path, '-map', '0:a:0', '-f', 's32le', '-'],
          environment: WorkerHarness.workerEnv, stdoutEncoding: null);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return r.stdout as List<int>;
    }

    final reference = await _encode(AudioFixtures.job(clicks, {'limiter': true},
        container: 'mkv', label: 'intermediate_reference', encoding: {'audioMode': 'passthrough'}));
    final ref = await WorkerHarness.firstStream(reference,
        selector: 'a:0', entries: ['codec_name', 'bits_per_raw_sample']);
    expect(ref!['codec_name'], 'flac');
    expect(ref['bits_per_raw_sample'], '24', reason: 'a restored track in MKV is 24-bit FLAC');
    final expected = await s32(reference);

    for (final (codec, container) in [
      ('prores_ks -profile:v 0', 'mov'),
      ('v210', 'mov'),
      ('v210', 'mkv'),
      ('v210', 'avi'),
      // Not intermediates: AVI alone makes these 24-bit.
      ('ffv1', 'avi'),
      ('huffyuv', 'avi'),
      ('libx264', 'avi'),
    ]) {
      final label = '${codec.startsWith('prores') ? 'prores' : codec}_$container';
      final out = await _encode(AudioFixtures.job(clicks, {'limiter': true},
          container: container, label: 'intermediate_$label',
          encoding: {'audioMode': 'passthrough', 'codec': codec}));
      final first = await WorkerHarness.firstStream(out,
          selector: 'a:0', entries: ['codec_name', 'codec_tag_string', 'bits_per_sample']);
      expect(first!['codec_name'], 'pcm_s24le', reason: label);
      expect(first['bits_per_sample'], 24, reason: label);
      if (container == 'mov') expect(first['codec_tag_string'], 'in24', reason: label);
      expect(await s32(out), orderedEquals(expected), reason: '$label: the same samples as the MKV reference');
    }
  });

  test('subtitles are transcribed from the restored sound, so cues follow the offset', () async {
    // CI provisions Whisper; locally, VAPOURBOX_FETCH_WHISPER=1 installs the
    // engine and the small model (466 MB) with the app's own installers.
    if (Platform.environment['VAPOURBOX_FETCH_WHISPER'] == '1') await WorkerHarness.ensureWhisper();
    // Where the worker looks (DependencyLocator::whisper_path / whisper_model_path).
    final whisper = p.join(WorkerHarness.addonsDirectory.path, 'whisper');
    final cli = Platform.isWindows ? p.join(whisper, 'whisper-cli.exe') : p.join(whisper, 'bin', 'whisper-cli');
    if (!File(cli).existsSync() || !File(p.join(whisper, 'models', 'ggml-small.bin')).existsSync()) {
      markTestSkipped('whisper add-on not present (VAPOURBOX_FETCH_WHISPER=1 installs it)');
      return;
    }
    final clip = p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'small_clip.mp4');
    final video = await WorkerHarness.firstStream(clip,
        selector: 'v:0', entries: ['width', 'height', 'pix_fmt']);
    /// Cue start times by their text (letters only, lower case), for texts
    /// that occur once.
    Future<Map<String, double>> cues(int offsetMs) async {
      final job = AudioFixtures.job(clip, {'offsetMs': offsetMs},
          label: 'subtitles_offset_$offsetMs',
          extra: {
            // The first 30 s.
            'startFrame': 0, 'endFrame': 899, 'totalFrames': 900,
            'inputFrameRate': 29.97, 'inputWidth': video!['width'], 'inputHeight': video['height'],
            'inputPixelFormat': video['pix_fmt'],
            'subtitleSettings': {'enabled': true, 'model': 'small', 'output': 'srt_file', 'language': 'en'},
          });
      // Whisper's small model on 30 s of sound reached 82% in the harness's
      // default 5 min on the linux-x64-v2 runner.
      final out = await _encode(job, timeout: const Duration(minutes: 15));
      final srt = File(p.setExtension(out, '.srt')).readAsStringSync().replaceAll('\r\n', '\n');
      final byText = <String, List<double>>{};
      for (final block in srt.split(RegExp(r'\n\s*\n'))) {
        final m = RegExp(r'(\d\d):(\d\d):(\d\d),(\d\d\d) -->[^\n]*\n([\s\S]*)').firstMatch(block);
        if (m == null) continue;
        final start = int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 +
            int.parse(m.group(3)!) + int.parse(m.group(4)!) / 1000;
        final text = m.group(5)!.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
        if (text.length >= 8) byText.putIfAbsent(text, () => []).add(start);
      }
      return {for (final e in byText.entries) if (e.value.length == 1) e.key: e.value.single};
    }

    final plain = await cues(0);
    final delayed = await cues(2000);
    final shifts = [
      for (final text in plain.keys)
        if (delayed.containsKey(text)) delayed[text]! - plain[text]!,
    ]..sort();
    // Whisper segments the two runs differently and its timestamps are
    // coarse, so the cues it transcribed identically are compared, by their
    // median shift, to the 2 s the sound was moved.
    expect(shifts.length, greaterThanOrEqualTo(2),
        reason: 'too few cues transcribed alike to compare: $plain / $delayed');
    expect(shifts[shifts.length ~/ 2], closeTo(2.0, 0.6),
        reason: 'cue shifts $shifts (cues $plain, then $delayed)');
  }, timeout: const Timeout(Duration(minutes: 35)));

  test('DeepFilterNet lowers stationary noise and keeps the timing', () async {
    await WorkerHarness.ensureAddon('deepfilternet');
    // A voiced, syllable-modulated harmonic complex in bursts, over pink noise.
    final src = await AudioFixtures.source('speechlike_noise',
        seconds: 8,
        filterComplex: "aevalsrc='(0.12*sin(2*PI*140*t)+0.08*sin(2*PI*280*t)+0.05*sin(2*PI*420*t)"
            "+0.03*sin(2*PI*840*t))*(0.5+0.5*sin(2*PI*5*t))*lt(mod(t\\,1.6)\\,0.9)':s=$_rate:d=8[v];"
            'anoisesrc=c=pink:a=0.03:r=$_rate:d=8:seed=3[n];'
            '[v][n]amix=inputs=2:normalize=0,pan=stereo|c0=c0|c1=c0[a]');
    final out = await _encode(AudioFixtures.job(src, {'deepFilter': true}, label: 'deepfilternet'));
    final before = (await AudioFixtures.decode(src, mono: true)).first;
    final after = (await AudioFixtures.decode(out, mono: true)).first;
    expect(after.length, before.length, reason: 'the track keeps the picture\'s length');
    // Noise alone: the gaps (0.95–1.55 s of every 1.6 s cycle).
    double gaps(Float32List x) {
      var sum = 0.0;
      var n = 0;
      for (var cycle = 1; cycle < 4; cycle++) {
        final from = ((cycle * 1.6 + 0.95) * _rate).round(), to = ((cycle * 1.6 + 1.55) * _rate).round();
        for (var i = from; i < to; i++) {
          sum += x[i] * x[i];
        }
        n += to - from;
      }
      return 10 * math.log(sum / n + 1e-20) / math.ln10;
    }
    final drop = gaps(before) - gaps(after);
    expect(drop, greaterThan(10), reason: 'noise down by only ${drop.toStringAsFixed(1)} dB');
    // Timing: the bursts' envelopes line up to the millisecond.
    final lag = AudioFixtures.lag(_envelope(before), _envelope(after), 60);
    expect(lag.abs(), lessThanOrEqualTo(1), reason: 'DeepFilterNet moved the sound by $lag ms');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
