// Audio fixtures and measurements for the audio restoration tests: sources
// made with ffmpeg's lavfi generators (nothing committed), decoded back to
// float samples, and measured here in Dart — level per channel, energy in a
// narrow band, and the lag between two signals by cross-correlation.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'worker_harness.dart';

class AudioFixtures {
  static Directory get dir =>
      Directory(p.join(WorkerHarness.outputDir, 'audio_fixtures'))..createSync(recursive: true);

  /// Run the bundle's ffmpeg; throws with its stderr on failure.
  static Future<void> ffmpeg(List<String> args) async {
    final r = await Process.run(
        WorkerHarness.ffmpegPath, ['-hide_banner', '-nostdin', '-y', '-v', 'error', ...args],
        environment: WorkerHarness.ffmpegEnv);
    if (r.exitCode != 0) throw StateError('ffmpeg ${args.join(' ')}\n${r.stderr}');
  }

  /// A source with a small picture (25 fps) and the audio [filterComplex]
  /// labels `[a]` (or several `[a0]`, `[a1]`… when [audioStreams] > 1).
  /// Made once per name.
  static Future<String> source(
    String name, {
    required String filterComplex,
    double seconds = 6,
    int audioStreams = 1,
    String audioCodec = 'flac',
  }) async {
    final out = p.join(dir.path, '$name.mkv');
    if (File(out).existsSync()) return out;
    await ffmpeg([
      '-f', 'lavfi', '-i', 'testsrc2=s=160x120:r=25:d=$seconds',
      '-filter_complex', filterComplex,
      '-map', '0:v',
      if (audioStreams == 1) ...['-map', '[a]'] else
        for (var i = 0; i < audioStreams; i++) ...['-map', '[a$i]'],
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'ultrafast',
      '-c:a', audioCodec,
      '-t', '$seconds',
      out,
    ]);
    return out;
  }

  /// A job for [input] with [audio] as its audio restoration settings and
  /// nothing done to the picture.
  static Map<String, dynamic> job(
    String input,
    Map<String, dynamic> audio, {
    String container = 'mkv',
    String label = 'audio',
    Map<String, dynamic> encoding = const {},
    Map<String, dynamic> extra = const {},
    Map<String, dynamic> pipeline = const {},
  }) {
    final out = p.join(WorkerHarness.outputDir, 'audio_restoration', '$label.$container');
    Directory(p.dirname(out)).createSync(recursive: true);
    return {
      'id': const Uuid().v4(),
      'inputPath': input,
      'outputPath': out,
      'qtgmcParameters': {'enabled': false},
      'processingPipeline': {
        'deinterlace': {'enabled': false},
        ...pipeline,
        'audio': {'enabled': true, ...audio},
      },
      'encodingSettings': {
        'container': container,
        'codec': 'libx264',
        'encoderPreset': 'ultrafast',
        ...encoding,
      },
      'inputFrameRate': 25.0,
      'inputWidth': 160,
      'inputHeight': 120,
      'inputPixelFormat': 'yuv420p',
      ...extra,
    };
  }

  /// `vapourbox-worker --audio-plan` for [jobJson]: the decoded JSON.
  static Future<Map<String, dynamic>> plan(Map<String, dynamic> jobJson) async {
    final cfg = File(p.join(Directory.systemTemp.path, 'vb_plan_${jobJson['id']}.json'))
      ..writeAsStringSync(jsonEncode(jobJson));
    try {
      final r = await Process.run(WorkerHarness.workerPath, ['--audio-plan', '--config', cfg.path],
          environment: WorkerHarness.workerEnv, stdoutEncoding: utf8, stderrEncoding: utf8);
      final line = (r.stdout as String).trim().split('\n').last;
      return jsonDecode(line) as Map<String, dynamic>;
    } finally {
      cfg.deleteSync();
    }
  }

  /// Decode audio stream [stream] of [path] to float samples at [rate],
  /// one list per channel (or downmixed to one with [mono]).
  static Future<List<Float32List>> decode(String path,
      {int stream = 0, int rate = 48000, bool mono = false}) async {
    final probe = await WorkerHarness.ffprobeJson(
        ['-v', 'error', '-of', 'json', '-select_streams', 'a:$stream', '-show_entries', 'stream=channels', path]);
    final channels = mono ? 1 : ((probe['streams'] as List).first['channels'] as int);
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      ['-v', 'error', '-nostdin', '-i', path, '-map', '0:a:$stream', '-ac', '$channels',
       '-ar', '$rate', '-f', 'f32le', '-'],
      stdoutEncoding: null,
      environment: WorkerHarness.ffmpegEnv,
    );
    if (r.exitCode != 0) throw StateError('decode $path: ${r.stderr}');
    final bytes = Uint8List.fromList(r.stdout as List<int>);
    final all = bytes.buffer.asFloat32List(0, bytes.lengthInBytes ~/ 4);
    final frames = all.length ~/ channels;
    return [
      for (var c = 0; c < channels; c++)
        Float32List.fromList([for (var i = 0; i < frames; i++) all[i * channels + c]]),
    ];
  }

  static double rmsDb(Float32List x, {int from = 0, int? to}) {
    final end = to ?? x.length;
    var sum = 0.0;
    for (var i = from; i < end; i++) {
      sum += x[i] * x[i];
    }
    final rms = math.sqrt(sum / math.max(1, end - from));
    return 20 * math.log(rms + 1e-12) / math.ln10;
  }

  /// Energy (dB) at [freq], by the Goertzel algorithm with a Hann window,
  /// over [x] sampled at [rate].
  static double bandDb(Float32List x, int rate, double freq) {
    final n = x.length;
    final w = 2 * math.pi * freq / rate;
    final coeff = 2 * math.cos(w);
    var s1 = 0.0, s2 = 0.0;
    for (var i = 0; i < n; i++) {
      final win = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
      final s = x[i] * win + coeff * s1 - s2;
      s2 = s1;
      s1 = s;
    }
    final power = (s1 * s1 + s2 * s2 - coeff * s1 * s2) / (n * n);
    return 10 * math.log(power + 1e-30) / math.ln10;
  }

  /// Positions (seconds) of the onsets of the clicks in [x]: the first sample
  /// above [threshold] after at least [gap] seconds below it.
  static List<double> onsets(Float32List x, int rate, {double threshold = 0.3, double gap = 0.1}) {
    final out = <double>[];
    var last = -1e9;
    for (var i = 0; i < x.length; i++) {
      if (x[i].abs() > threshold) {
        final t = i / rate;
        if (t - last > gap) out.add(t);
        last = t;
      }
    }
    return out;
  }

  /// Lag of [sig] against [ref] in samples (+ = [sig] late), by direct
  /// cross-correlation within ±[maxLag].
  static int lag(Float32List ref, Float32List sig, int maxLag) {
    final n = math.min(ref.length, sig.length);
    var best = 0;
    var bestScore = -double.infinity;
    for (var l = -maxLag; l <= maxLag; l++) {
      var score = 0.0;
      for (var i = math.max(0, -l); i < n && i + l < n; i += 4) {
        score += ref[i] * sig[i + l];
      }
      if (score > bestScore) {
        bestScore = score;
        best = l;
      }
    }
    return best;
  }

  /// The output's duration in seconds, by its audio sample count.
  static Future<double> audioSeconds(String path, {int stream = 0}) async =>
      (await decode(path, stream: stream, mono: true)).first.length / 48000;
}
