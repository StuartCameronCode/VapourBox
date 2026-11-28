/// The output conformance matrix (task #49): every valid container × audio
/// mode × source class × trim (`support/output_matrix.dart`, ~440 cases)
/// encoded from the flash/click sources (`generate_output_conformance.sh`)
/// and checked against the oracle:
///
///  1. the header writes, with the expected audio codec;
///  2. the picture count and the first picture's time (AVI: the stored count
///     and rate, task #30's 1/600 trap);
///  3. no null frames: every video packet has data, one frame apart;
///  4. each white frame has its click within one audio packet;
///  5. the audio packets follow on (AVI AAC: task #41's block size);
///  6. lossless paths are lossless: a copy is a run of the source's packets,
///     FLAC/PCM are the source's samples to the output's depth.
///
/// Cases that fail today are listed in `knownFailures`; they still run and
/// fail if they pass. Run one case with `--plain-name '<id>'`, e.g.
/// `--plain-name 'avi/convert-libmp3lame/delayed-avi/near-start'`.
@Tags(['heavy'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/audio_restoration_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/source_model.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/audio_compatibility_service.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/timestamp_continuity_service.dart';
import 'package:vapourbox/services/tool_locator.dart';

import 'support/av_sync.dart';
import 'support/bounded_process.dart';
import 'support/output_matrix.dart';
import 'support/worker_harness.dart';

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

final _outDir = p.join(Directory.systemTemp.path, 'vapourbox_output_conformance');

/// One source as the app analyses it.
class _Source {
  _Source(this.decodePath, this.model, this.info, this.videoStart, this.payload, this.samples,
      this.renderSamples, this.packetSeconds, this.clickLags);

  /// What the encode reads: the file, or the app's joined copy of a reset.
  final String decodePath;

  /// The worker's source model of [decodePath], sent with every job as the
  /// app sends it.
  final SourceModel model;
  final VideoInfo info;

  /// Where the picture starts after the container's start (the model's).
  final double videoStart;

  /// The audio stream's payload bytes, as stored (every packet's data).
  final Uint8List payload;

  /// The decoded sound, f32 mono.
  final Float32List samples;

  /// The decoded sound as Audio Restoration's render decodes it
  /// ([MatrixCase.referenceDecoder]): the float decoder for MP2. Null when
  /// that is FFmpeg's default ([samples]).
  final Float32List? renderSamples;

  /// How far each white frame's click sits after its picture in the source
  /// itself, seconds, in [matrixFlashes] order. The delayed AVI's is 23 ms:
  /// libmp3lame's priming, which AVI cannot mark, so every player plays it
  /// that late. The output keeps the source's timing, so its clicks are
  /// expected this far after their flashes (task #58).
  final List<double> clickLags;

  /// The longest audio packet, seconds.
  final double packetSeconds;
}

/// The first audio stream's packet payloads, concatenated: comparable
/// across containers that packetise the same frames differently (a TS PES
/// holds several MP2 frames, Matroska one each).
Future<Uint8List> _payload(String path) async {
  final r = await runBounded(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, '-map', '0:a:0', '-c', 'copy', '-f', 'data', '-'],
    label: 'the sound payload copy',
    binaryStdout: true,
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return Uint8List.fromList(r.stdout as List<int>);
}

Future<Float32List> _samples(String path, {String? decoder}) async {
  final r = await runBounded(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', if (decoder != null) ...['-c:a', decoder], '-i', path, '-map', '0:a:0', '-ac', '1',
     '-f', 'f32le', '-'],
    label: 'the sample decode',
    binaryStdout: true,
    environment: WorkerHarness.ffmpegEnv,
  );
  final bytes = Uint8List.fromList(r.stdout as List<int>);
  return bytes.buffer.asFloat32List(0, bytes.length ~/ 4);
}

/// The first audio stream's packets: (pts, duration), seconds, in order.
Future<List<(double, double)>> _audioTimes(String path) async {
  final j = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'a:0', '-show_entries',
    'packet=pts_time,duration_time', '-of', 'json', path,
  ]);
  return [
    for (final pk in j['packets'] as List)
      if (double.tryParse('${pk['pts_time']}') != null)
        (double.parse('${pk['pts_time']}'), double.tryParse('${pk['duration_time']}') ?? 0),
  ];
}

double _longest(List<(double, double)> packets) =>
    packets.take(64).fold(0.0, (m, pk) => pk.$2 > m && pk.$2 < 1 ? pk.$2 : m);

Future<_Source> _prepare(SourceClass s) async {
  var decode = _resource(s.file);
  if (s == SourceClass.resetPs) {
    final service = TimestampContinuityService(
        workerPath: WorkerHarness.workerPath, environment: WorkerHarness.workerEnv);
    final r = await service.prepare(decode, const Uuid().v4());
    expect(r.error, isNull);
    expect(r.scan!.videoResetPictures, [51], reason: 'the fixture resets at picture 51');
    decode = r.proxy!.path;
    addTearDown(r.proxy!.delete);
  }
  final model = await WorkerHarness.sourceModel(decode);
  final info = await FieldOrderDetector().getVideoInfo(decode, model);
  expect(info, isNotNull, reason: s.file);
  expect(info!.frameCount, matrixPictures, reason: '${s.file}: the app counts every picture');
  expect(model.videoStartOffset, closeTo(s.nominalVideoStart, 0.03),
      reason: '${s.file}: where the picture starts after the sound');
  // Each click against its picture, on the source's own timeline: the
  // container's start plus the picture's start plus n frames (not the
  // decoded frame's PTS, which a delayed AVI stamps a frame late).
  final fmt = await WorkerHarness.ffprobeJson(
      ['-v', 'error', '-show_entries', 'format=start_time', '-of', 'json', decode]);
  final start = double.tryParse('${(fmt['format'] as Map)['start_time']}') ?? 0;
  final beeps = await beepOnsets(decode);
  final lags = [
    for (final n in matrixFlashes)
      beeps
          .map((b) => b - (start + model.videoStartOffset + n / matrixFps))
          .reduce((a, b) => a.abs() < b.abs() ? a : b),
  ];
  for (final l in lags) {
    expect(l.abs(), lessThan(0.05), reason: '${s.file}: each click near its flash (lags $lags)');
  }
  final render = s.renderDecoder;
  return _Source(decode, model, info, model.videoStartOffset, await _payload(decode),
      await _samples(decode), render == null ? null : await _samples(decode, decoder: render),
      _longest(await _audioTimes(decode)), lags);
}

VideoJob _job(MatrixCase c, _Source s) {
  const off = QTGMCParameters(enabled: false);
  final name = c.id.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: s.decodePath,
    source: s.model,
    outputPath: p.join(_outDir, '$name.${c.container.extension}'),
    qtgmcParameters: off,
    processingPipeline: ProcessingPipeline(
      deinterlace: off,
      audio: c.restores
          ? const AudioRestorationParameters(enabled: true, driftCorrection: true)
          : const AudioRestorationParameters(),
    ),
    encodingSettings: EncodingSettings(
      codec: c.video,
      container: c.container,
      encoderPreset: c.video == VideoCodec.av1
          ? '10'
          : c.video == VideoCodec.h264
              ? 'ultrafast'
              : 'medium',
      audioMode: c.audioMode,
      audioCodec: c.convertCodec,
      audioQuality: AudioQuality.high,
    ),
    inputWidth: s.info.width,
    inputHeight: s.info.height,
    inputPixelFormat: s.info.pixelFormat,
    inputFrameRate: s.info.frameRate,
    startFrame: c.trim.start,
    endFrame: c.trim.end,
    totalFrames: c.trim.start == null ? s.info.frameCount : c.trim.pictures,
    continuityChecked: c.source == SourceClass.resetPs,
  );
}

/// Whether [out] (decoded) is a run of [src], sample for sample to within
/// one step at the output's [depth]. Returns why not, or null.
///
/// The tone between the clicks repeats, so the output's first second matches
/// the source at many offsets; each is compared in full and the best kept
/// (taking the first put a trimmed output a whole number of tone periods
/// early, and every click then "differed").
String? _sampleExact(Float32List out, Float32List src, int depth) {
  final tol = 1.0 / (1 << (depth - 1)) + 1e-7;
  var first = 0;
  while (first < out.length && out[first].abs() < 1e-3) {
    first++;
  }
  if (first >= out.length) return 'the output is silent';
  final probe = out.length - first < 4800 ? out.length - first : 4800;
  (int, int, int)? best; // (offset, differ, compared)
  for (var o = 0; o + probe <= src.length; o++) {
    var ok = true;
    for (var k = 0; k < probe; k++) {
      if ((src[o + k] - out[first + k]).abs() > tol) {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    final at = o - first;
    var differ = 0, compared = 0;
    for (var k = 0; k < out.length; k++) {
      final j = at + k;
      if (j < 0 || j >= src.length) continue;
      compared++;
      if ((src[j] - out[k]).abs() > tol) differ++;
    }
    if (best == null || differ < best.$2 || (differ == best.$2 && compared > best.$3)) {
      best = (at, differ, compared);
    }
    if (differ == 0 && compared >= out.length - 1920) break;
  }
  if (best == null) return 'no run of the source matches the output\'s first $probe samples';
  final (at, differ, compared) = best;
  if (differ > 0) return '$differ of $compared samples differ (offset $at)';
  if (compared < out.length - 1920) {
    return 'only $compared of ${out.length} samples overlap the source';
  }
  return null;
}

/// Whether [out] is a contiguous run of [src]'s bytes. Returns why not, or null.
String? _byteRun(Uint8List out, Uint8List src) {
  if (out.isEmpty) return 'no audio payload';
  // The tone repeats, so a prefix can match in several places: try each.
  var best = 0, bestAt = -1;
  for (var o = 0; o + out.length <= src.length; o++) {
    var k = 0;
    while (k < out.length && src[o + k] == out[k]) {
      k++;
    }
    if (k == out.length) return null;
    if (k > best) {
      best = k;
      bestAt = o;
    }
  }
  return 'the copy\'s ${out.length} bytes are not a run of the source\'s ${src.length} '
      '(the longest match: $best bytes, at $bestAt)';
}

/// Each case's limit, and its job's: the job's is below the case's, so a
/// hung job is killed as a tree and reported with where it hung (task #99),
/// not cut off by the test's bare TimeoutException with its processes left
/// running. `conformance_timeouts_test.dart` (push gate) holds the order.
const caseTimeout = Duration(minutes: 3);
const jobTimeout = Duration(seconds: 150);

/// Encodes [c] and checks the output; on any failure prints what tells an
/// encoder that lost a picture from a decoder that did, or a pipeline that
/// did ([_evidence]), and keeps the output in `$VAPOURBOX_CONFORMANCE_KEEP`.
Future<void> _check(MatrixCase c, _Source s) async {
  final job = _job(c, s).toJson();
  final r = await WorkerHarness.runJob(job, label: c.id, timeout: jobTimeout);
  try {
    expect(r.success, isTrue, reason: '1. the job: ${r.error}');
    await _checkOutput(c, s, r.outputPath!);
  } catch (_) {
    await _evidence(c, job, r);
    rethrow;
  }
  // `VAPOURBOX_CONFORMANCE_KEEP_ALL=1` keeps passing cases too: the repro
  // workflow replays a good job's encoder from them (task #99).
  if (Platform.environment['VAPOURBOX_CONFORMANCE_KEEP_ALL'] == '1') {
    await _evidence(c, job, r, failed: false);
  }
}

/// What a failed case leaves behind for its diagnosis (task #99): the job's
/// log tail (vspipe's "Output N frames", the encoder's last lines), the
/// output's video packet count beside the frames ffprobe and an ffmpeg
/// decode count, the decoder ffmpeg chose, and the job. With
/// `$VAPOURBOX_CONFORMANCE_KEEP` set, the output and the job are copied
/// there (nightly uploads it).
Future<void> _evidence(MatrixCase c, Map<String, dynamic> job, JobResult r,
    {bool failed = true}) async {
  final b = StringBuffer('--- evidence for ${c.id} (task #99) ---\n');
  b.writeln('job: ${r.success ? 'succeeded' : 'failed: ${r.error}'} in ${r.duration.inMilliseconds} ms');
  final out = r.outputPath ?? '${job['outputPath']}';
  for (final l in r.logs) {
    if (l.contains('Output ') && l.contains(' frames')) b.writeln('vspipe: $l');
  }
  final tail = r.logs.length > 40 ? r.logs.sublist(r.logs.length - 40) : r.logs;
  b.writeln('job log, last ${tail.length} lines:');
  for (final l in tail) {
    b.writeln('  ${l.length > 400 ? '${l.substring(0, 400)}…' : l}');
  }
  if (File(out).existsSync()) {
    try {
      final v = await WorkerHarness.ffprobeJson([
        '-v', 'error', '-select_streams', 'v:0', '-count_packets', '-count_frames',
        '-show_entries', 'stream=codec_name,nb_frames,nb_read_packets,nb_read_frames',
        '-of', 'json', out,
      ], timeout: const Duration(seconds: 60));
      b.writeln('video stream: ${(v['streams'] as List).firstOrNull}');
    } catch (e) {
      b.writeln('ffprobe count: $e');
    }
    try {
      final d = await runBounded(
        WorkerHarness.ffmpegPath,
        ['-hide_banner', '-nostats', '-v', 'info', '-i', out, '-map', '0:v:0', '-f', 'null', '-'],
        label: 'the evidence decode',
        timeout: const Duration(seconds: 60),
        environment: WorkerHarness.ffmpegEnv,
      );
      for (final l in '${d.stderr}'.split('\n')) {
        if (l.contains('Stream #0:') && l.contains('->') || l.contains('frames decoded') ||
            l.contains('frames encoded') || l.contains('frame=')) {
          b.writeln('ffmpeg decode: ${l.trim()}');
        }
      }
    } catch (e) {
      b.writeln('ffmpeg decode: $e');
    }
  } else {
    b.writeln('no output file at $out');
  }
  b.writeln('job: ${jsonEncode(job)}');
  final keep = Platform.environment['VAPOURBOX_CONFORMANCE_KEEP'];
  if (keep != null && keep.isNotEmpty) {
    final dir = Directory(p.join(keep, c.id.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')))
      ..createSync(recursive: true);
    if (File(out).existsSync()) File(out).copySync(p.join(dir.path, p.basename(out)));
    File(p.join(dir.path, 'job.json')).writeAsStringSync(jsonEncode(job));
    File(p.join(dir.path, 'log.txt')).writeAsStringSync('${b.toString()}\n${r.logs.join('\n')}');
    b.writeln('kept in ${dir.path}');
  }
  if (failed) print(b);
}

Future<void> _checkOutput(MatrixCase c, _Source s, String out) async {

  // 1. The header wrote: one video stream and the expected sound.
  final streams = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-show_entries',
    'stream=codec_type,codec_name,sample_fmt,bits_per_raw_sample', '-of', 'json', out,
  ]);
  final list = (streams['streams'] as List).cast<Map<String, dynamic>>();
  expect(list.where((x) => x['codec_type'] == 'video'), hasLength(1), reason: '1. video');
  final audio = list.where((x) => x['codec_type'] == 'audio').toList();
  expect(audio, hasLength(1), reason: '1. one audio stream');
  expect(c.audioCodecMatches('${audio.first['codec_name']}'), isTrue,
      reason: '1. the audio codec: ${audio.first['codec_name']}, expected ${c.expectedAudioCodec}');

  // 2. Picture count and first picture.
  expect(await countFrames(out), c.expectedPictures, reason: '2. pictures');
  final vp = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time,size',
    '-of', 'json', out,
  ]);
  final packets = (vp['packets'] as List).cast<Map<String, dynamic>>();
  final pts = [for (final pk in packets) double.parse('${pk['pts_time']}')]..sort();
  final expectedFirst = c.expectedFirstPts(s.videoStart);
  if (expectedFirst != null) {
    expect(pts.first, closeTo(expectedFirst, 0.5 / matrixFps), reason: '2. the first picture');
  } else {
    // A copy's pre-roll: at most a GOP (25 pictures) and a packet.
    expect(pts.first, inInclusiveRange(0, 1.2), reason: '2. the first picture');
  }
  final firstPts = pts.first;
  if (c.container.timesVideoByFrame) {
    final avi = await aviVideo(out);
    expect(avi.rate, '$matrixFps/1', reason: '2. AVI rate (the 1/600 trap)');
    expect(avi.stored, c.expectedPictures, reason: '2. AVI stored frames (null frames)');
  }

  // 3. No null frames.
  expect(packets.where((pk) => int.parse('${pk['size']}') == 0), isEmpty,
      reason: '3. empty video packets');
  for (var i = 1; i < pts.length; i++) {
    expect(pts[i] - pts[i - 1], closeTo(1 / matrixFps, 0.002),
        reason: '3. pictures ${i - 1}..$i are not one frame apart');
  }

  // 4. Every white frame has its click, within one audio packet of where the
  // source has it (its own lag after the picture, [_Source.clickLags]).
  final times = await _audioTimes(out);
  final tolerance = [_longest(times), s.packetSeconds].reduce((a, b) => a > b ? a : b) + 0.001;
  final e = await events(out);
  final want = c.expectedFlashTimes(firstPts);
  expect(e.flashes, hasLength(want.length), reason: '4. white frames at ${e.flashes}');
  for (var i = 0; i < want.length; i++) {
    expect(e.flashes[i], closeTo(want[i], 0.5 / matrixFps), reason: '4. white frame $i');
    final lag = s.clickLags[matrixFlashes.indexOf(c.trim.flashes[i])];
    final at = e.flashes[i] + lag;
    final near = e.beeps.isEmpty
        ? double.infinity
        : e.beeps.map((b) => (b - at).abs()).reduce((a, b) => a < b ? a : b);
    final nearest = e.beeps.isEmpty
        ? null
        : e.beeps.reduce((a, b) => (a - at).abs() < (b - at).abs() ? a : b);
    expect(near, lessThan(tolerance),
        reason: '4. the click for the flash at ${e.flashes[i].toStringAsFixed(4)} s is at '
            '${nearest?.toStringAsFixed(4)} (${((nearest ?? 0) - e.flashes[i]).toStringAsFixed(4)} s '
            'after it, the source\'s ${lag.toStringAsFixed(4)}; one packet ${tolerance.toStringAsFixed(4)} s)');
  }

  // 5. The audio packets follow on. AVI stores no duration for its first
  // audio chunk (nor for any FLAC chunk); such a packet is taken to last the
  // stream's usual packet, and with no duration anywhere only order is checked.
  final known = [for (final t in times) if (t.$2 > 0) t.$2]..sort();
  final usual = known.isEmpty ? null : known[known.length ~/ 2];
  for (var i = 1; i < times.length; i++) {
    final last = times[i - 1].$2 > 0 ? times[i - 1].$2 : usual;
    if (last == null) {
      expect(times[i].$1, greaterThan(times[i - 1].$1), reason: '5. audio packet $i is out of order');
      continue;
    }
    final gap = times[i].$1 - (times[i - 1].$1 + last);
    expect(gap.abs(), lessThanOrEqualTo(last / 2 + 1e-4),
        reason: '5. audio packet $i starts ${gap.toStringAsFixed(4)} s off the last one\'s end');
  }
  if (c.checksAacBlockAlign) await expectAacTimedOnce('5. AVI AAC', out);

  // 6. Lossless paths.
  switch (c.lossless) {
    case LosslessCheck.copy:
      final why = _byteRun(await _payload(out), s.payload);
      expect(why, isNull, reason: '6. the copy: $why');
    case LosslessCheck.exact:
      final a = audio.first;
      final fmt = '${a['sample_fmt']}';
      final raw = int.tryParse('${a['bits_per_raw_sample']}') ?? 0;
      final depth = raw > 0 ? raw : (fmt.startsWith('s16') ? 16 : fmt.startsWith('s32') ? 32 : 24);
      final ref = c.referenceDecoder == null ? s.samples : s.renderSamples!;
      final why = _sampleExact(await _samples(out), ref, depth);
      expect(why, isNull, reason: '6. the samples ($depth-bit): $why');
    case LosslessCheck.none:
      break;
  }
}

void main() {
  final cases = matrixCases();
  final sources = <SourceClass, _Source>{};
  var av1 = false;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await ToolLocator.instance.initialize();
    Directory(_outDir).createSync(recursive: true);
    for (final s in SourceClass.values) {
      sources[s] = await _prepare(s);
    }
    av1 = await WorkerHarness.hasEncoder('libsvtav1');
  });

  // `VAPOURBOX_CONFORMANCE_REPEAT=N` registers each case N times, for
  // reproducing an intermittent one in one process
  // (`repro-output-conformance.yml`, task #99). Never a retry: each run is
  // its own test and its own verdict.
  final repeat = int.tryParse(Platform.environment['VAPOURBOX_CONFORMANCE_REPEAT'] ?? '') ?? 1;
  final runs = [for (final c in cases) for (var k = 1; k <= repeat; k++) (c, k)];
  for (final (c, run) in runs) {
    test(repeat == 1 ? c.id : '${c.id} (run $run of $repeat)', () async {
      if (c.video == VideoCodec.av1 && !av1) {
        markTestSkipped('no libsvtav1 in this FFmpeg');
        return;
      }
      final known = knownFailures[c.id];
      if (known == null) {
        await _check(c, sources[c.source]!);
        return;
      }
      Object? failure;
      try {
        await _check(c, sources[c.source]!);
      } catch (e) {
        failure = e;
      }
      expect(failure, isNotNull,
          reason: 'a known failure ($known) now passes: remove it from knownFailures');
      print('  known failure ($known): $failure');
    }, timeout: const Timeout(caseTimeout));
  }

  // Found by the matrix: a reset whose first part's sound ends off the
  // picture's grid (2.0 s of MP2 is 83.3 frames) is joined with its second
  // part's picture 16 ms late, so ffprobe reads 125 fps and the app analyses
  // 493 pictures. Known failure: fails while the fault is there.
  // The first part's sound runs 16 ms past its last picture (a DVD cell's
  // may). ffmpeg's own correction joined at the sound's end, so every later
  // picture sat 16 ms off the grid and ffprobe read 125 fps; the picture now
  // decides the join, and the overhanging sound packet goes (task #58).
  test('a reset whose sound ends off the picture grid joins on the grid', () async {
    final service = TimestampContinuityService(
        workerPath: WorkerHarness.workerPath, environment: WorkerHarness.workerEnv);
    final r = await service.prepare(_resource('conf_reset_offgrid.mpg'), const Uuid().v4());
    expect(r.error, isNull);
    expect(r.scan!.videoResetPictures, [50]);
    addTearDown(r.proxy!.delete);
    final info = await FieldOrderDetector()
        .getVideoInfo(r.proxy!.path, await WorkerHarness.sourceModel(r.proxy!.path));
    expect(info!.frameRate, 25, reason: 'the copy\'s rate');
    expect(info.frameCount, matrixPictures, reason: 'the copy\'s pictures');
    // Every picture one frame after the last, and each click on its flash.
    final e = await events(r.proxy!.path);
    expect(e.flashes, hasLength(matrixFlashes.length), reason: 'white frames at ${e.flashes}');
    for (var i = 0; i < matrixFlashes.length; i++) {
      expect(e.flashes[i] - e.flashes[0], closeTo((matrixFlashes[i] - matrixFlashes[0]) / matrixFps, 0.002),
          reason: 'flash $i on the grid');
      final near = e.beeps.map((b) => (b - e.flashes[i]).abs()).reduce((a, b) => a < b ? a : b);
      expect(near, lessThan(0.013), reason: 'the click for flash $i within half a sound packet');
    }
  });

  test('a copy the container cannot hold is refused before any work (task #49)', () async {
    final opus = p.join(_outDir, 'opus_source.mkv');
    final made = await runBounded(
      WorkerHarness.ffmpegPath,
      ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=s=160x120:r=25:d=1',
       '-f', 'lavfi', '-i', 'sine=d=1:sample_rate=48000', '-c:v', 'ffv1', '-c:a', 'libopus', opus],
      label: 'making the Opus source',
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final job = VideoJob(
      id: const Uuid().v4(),
      inputPath: opus,
      outputPath: p.join(_outDir, 'opus_copy.avi'),
      qtgmcParameters: const QTGMCParameters(enabled: false),
      processingPipeline: const ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false)),
      encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1, container: ContainerFormat.avi, audioMode: AudioMode.passthrough),
      inputWidth: 160,
      inputHeight: 120,
      inputPixelFormat: 'yuv420p',
      inputFrameRate: 25,
      totalFrames: 25,
    );
    final r = await WorkerHarness.runJob(job.toJson(), label: 'opus copy');
    expect(r.success, isFalse);
    expect(r.error, AudioCompatibilityService.copyProblem('opus', ContainerFormat.avi,
        videoCodec: VideoCodec.ffv1));
    expect(r.logs.any((l) => l.contains('Generating VapourSynth script')), isFalse);
  });
}
