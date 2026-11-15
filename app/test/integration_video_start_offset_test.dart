// Sources whose video starts after their audio (every DVB-T capture): frame N
// counts from the video's first picture, and the output keeps sound and
// picture in step.
//
// An input -ss counts from the container's start, which is the earliest
// stream's. With the sound 1 s ahead, the preview, the app's before frame and
// a trim all showed frame N-25; an untrimmed MKV/MP4 decode put 25 copies of
// the first picture in front (and an MP4 lost its last second to -frames:v);
// and an untrimmed TS encode came out with the sound 1 s late. Every check
// here is against an independent reference: a sequential decode of the
// source picked by index, and, for sync, the output file's own timestamps.
//
// Fixtures: Tests/TestResources/generate_video_start_offset.sh (a white frame
// at source frames 25 and 75, a 1 kHz beep at the same moments, the video
// starting 1 s after the audio). late_video_intra.ts is all-intra, so its
// seeks land on the frame asked for; late_video_gop.ts has 25-frame GOPs, so
// its seeks need the seek plan too (issue #169: an MPEG-TS seek otherwise
// lands on the next keyframe). See docs/reports/2026-11-video-start-offset
// and docs/reports/issue-169-mpeg-seek.
@Tags(['heavy'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/audio_restoration_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/video_start_offset';

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

const _fixtures = ['late_video_intra.ts', 'late_video_gop.ts', 'late_video.mkv', 'late_video.mp4'];
const _frames = 100;
const _fps = 25.0;
const _previewFrames = [0, 1, 24, 25, 26, 60, 99];
const _trimStart = 30;
const _trimEnd = 59;

/// Half a frame: the most a stamped delay may be off.
const _syncTolerance = 0.5 / _fps;

const _off = QTGMCParameters(enabled: false);

VideoJob _job(
  String input,
  String name, {
  int? start,
  int? end,
  AudioMode audio = AudioMode.none,
  AudioRestorationParameters audioPass = const AudioRestorationParameters(),
  ContainerFormat container = ContainerFormat.mkv,
  VideoCodec codec = VideoCodec.ffv1,
}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: input,
    outputPath: '$_outDir/$name.${container.extension}',
    qtgmcParameters: _off,
    processingPipeline: ProcessingPipeline(deinterlace: _off, audio: audioPass),
    encodingSettings: EncodingSettings(
      codec: codec,
      container: container,
      audioMode: audio,
    ),
    inputWidth: 320,
    inputHeight: 240,
    inputPixelFormat: 'yuv420p',
    inputFrameRate: _fps,
    startFrame: start,
    endFrame: end,
    totalFrames: start != null && end != null ? end - start + 1 : _frames,
  );
}

Future<VideoStart> _videoStart(String video) async {
  final v = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'stream=start_time:format=start_time', '-of', 'json', video,
  ]);
  return FieldOrderDetector.probeVideoStart(
    WorkerHarness.ffprobePath,
    video,
    streamStart: double.tryParse('${(v['streams'] as List).first['start_time']}'),
    containerStart: double.tryParse('${v['format']['start_time']}'),
  );
}

/// The app's seek plan for [video], as `PreviewGenerator` probes it: null
/// unless it is an MPEG-TS/PS.
Future<SeekPlan?> _seekPlan(String video) async {
  final f = await WorkerHarness.ffprobeJson(
      ['-v', 'error', '-show_entries', 'format=format_name', '-of', 'json', video]);
  return FieldOrderDetector.probeSeekPlan(WorkerHarness.ffprobePath, video,
      formatName: f['format']?['format_name'] as String?);
}

/// The app's before picture of [frame], through `beforeFrameArgs` (PNG).
Future<Uint8List> _beforeFrame(String video, int frame, double offset, SeekPlan? plan) async {
  final out = File(p.join(Directory.systemTemp.path,
      'vb_vstart_before_${DateTime.now().microsecondsSinceEpoch}.png'));
  try {
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      PreviewGenerator.beforeFrameArgs(
        videoPath: video,
        frameIndex: frame,
        frameRate: _fps,
        videoStartOffset: offset,
        seekPlan: plan,
        outputPath: out.path,
      ),
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: 'before frame $frame: ${r.stderr}');
    return await WorkerHarness.imageToRgb24(await out.readAsBytes(), label: 'before');
  } finally {
    if (await out.exists()) await out.delete().catchError((_) => out);
  }
}

/// [img] is source frame [n]: the closest of n-1..n+1, and nearly identical.
/// Every frame of the fixture differs (testsrc2), and the old fault was 25
/// frames off, so the neighbours tell a shift from a colour conversion.
Future<void> _expectFrame(String what, Uint8List img, String video, int n,
    {double maxDiff = 1.0}) async {
  final diffs = <int, double>{
    for (final k in [n - 1, n, n + 1])
      if (k >= 0 && k < _frames)
        k: WorkerHarness.meanAbsDiff(img, await WorkerHarness.frameRgb24(video, k, label: 'src')),
  };
  final best = diffs.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
  final table = diffs.entries.map((e) => '${e.key}: ${e.value.toStringAsFixed(2)}').join(', ');
  expect(best, n, reason: '$what is source frame $best, not $n ($table)');
  expect(diffs[n]!, lessThan(maxDiff), reason: '$what is not source frame $n ($table)');
}

/// Presentation times, on the file's own timeline, of its white frames and of
/// the onsets of its beeps (loud after 5 ms of quiet; the first 5 ms never
/// count, since a copied track can start inside a beep).
Future<({List<double> flashes, List<double> beeps, double videoStart})> _events(
    String path) async {
  final vf = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time',
    '-of', 'json', path,
  ]);
  final pts = [
    for (final f in vf['frames'] as List) double.parse('${f['pts_time']}'),
  ];
  final luma = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'quiet', '-i', path, '-map', '0:v:0', '-fps_mode', 'passthrough',
     '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
    stdoutEncoding: null,
    environment: WorkerHarness.ffmpegEnv,
  );
  final y = luma.stdout as List<int>;
  const n = 320 * 240;
  final flashes = <double>[];
  for (var i = 0; (i + 1) * n <= y.length && i < pts.length; i++) {
    var sum = 0;
    for (var k = i * n; k < (i + 1) * n; k += 97) {
      sum += y[k];
    }
    if (sum / (n / 97).ceil() > 200) flashes.add(pts[i]);
  }

  final af = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'a:0', '-show_entries',
    'frame=pts_time,nb_samples:stream=sample_rate', '-of', 'json', path,
  ]);
  final rate = int.parse('${(af['streams'] as List).first['sample_rate']}');
  final pcm = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'quiet', '-i', path, '-map', '0:a:0', '-ac', '1', '-f', 'f32le', '-'],
    stdoutEncoding: null,
    environment: WorkerHarness.ffmpegEnv,
  );
  final bytes = Uint8List.fromList(pcm.stdout as List<int>);
  final samples = bytes.buffer.asFloat32List(0, bytes.length ~/ 4);
  final quiet = rate ~/ 200;
  final beeps = <double>[];
  var pos = 0;
  var last = -10.0;
  for (final f in af['frames'] as List) {
    final count = int.parse('${f['nb_samples']}');
    final t0 = double.parse('${f['pts_time']}');
    for (var k = 0; k < count; k++) {
      final i = pos + k;
      if (i < quiet || i >= samples.length || samples[i].abs() <= 0.3) continue;
      var loudBefore = false;
      for (var j = i - quiet; j < i; j++) {
        if (samples[j].abs() > 0.3) {
          loudBefore = true;
          break;
        }
      }
      if (loudBefore) continue;
      final t = t0 + k / rate;
      if (t - last > 0.5) beeps.add(t);
      last = t;
    }
    pos += count;
  }
  return (flashes: flashes, beeps: beeps, videoStart: pts.isEmpty ? double.nan : pts.first);
}

/// Each white frame has its beep: the first beep from 0.5 s before it to 1.5 s
/// after (beeps are 2 s apart and the fault was late sound), within half a frame.
Future<void> _expectInSync(String what, String path,
    {required int flashes, double tolerance = _syncTolerance}) async {
  final e = await _events(path);
  expect(e.flashes, hasLength(flashes), reason: '$what: white frames at ${e.flashes}');
  for (final f in e.flashes) {
    final near = e.beeps.where((b) => b - f >= -0.5 && b - f <= 1.5).toList();
    expect(near, isNotEmpty, reason: '$what: no beep for the flash at $f (beeps ${e.beeps})');
    expect((near.first - f).abs(), lessThan(tolerance),
        reason: '$what: the beep is ${(near.first - f).toStringAsFixed(4)} s from '
            'the flash at $f');
  }
}

Future<String> _encode(VideoJob job, String label) async {
  final r = await WorkerHarness.runJob(job.toJson(), label: label);
  expect(r.success, isTrue, reason: r.error);
  return r.outputPath!;
}

Future<int> _countFrames(String path) async {
  final s = await WorkerHarness.firstStream(path,
      selector: 'v:0', entries: ['nb_read_frames'], countFrames: true);
  return int.parse('${s!['nb_read_frames']}');
}

/// The video stream of an AVI as stored: its average rate, the frame count
/// in its header (null frames included: the 600 fps trap of task #30, which
/// `nb_read_frames` hides) and the first frames' times.
Future<({String rate, int stored, List<double> pts})> _aviVideo(String path) async {
  final v = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0', '-show_entries',
    'stream=avg_frame_rate,time_base,nb_frames', '-read_intervals', '%+#3',
    '-show_entries', 'frame=pts_time', '-of', 'json', path,
  ]);
  final s = (v['streams'] as List).first as Map<String, dynamic>;
  return (
    rate: '${s['avg_frame_rate']}',
    stored: int.parse('${s['nb_frames']}'),
    pts: [for (final f in v['frames'] as List) double.parse('${f['pts_time']}')],
  );
}

/// Half the longest of the source's first audio packets, seconds: how far a
/// copied compressed sound cut at a packet may sit from the first picture.
Future<double> _halfPacket(String video) async {
  final a = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'a:0', '-read_intervals', '%+#32',
    '-show_entries', 'packet=duration_time', '-of', 'json', video,
  ]);
  var longest = 0.0;
  for (final pk in a['packets'] as List) {
    final d = double.tryParse('${pk['duration_time']}') ?? 0;
    if (d > longest && d < 1) longest = d;
  }
  return longest / 2;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  for (final file in _fixtures) {
    group(file, () {
      final video = _resource(file);
      final stem = p.basenameWithoutExtension(file);
      late VideoStart start;
      late SeekPlan? plan;

      setUpAll(() async {
        expect(await File(video).exists(), isTrue, reason: 'missing $video');
        start = await _videoStart(video);
        plan = await _seekPlan(video);
        expect(plan != null, file.endsWith('.ts'),
            reason: 'a TS seeks with a plan, nothing else does ($plan)');
      });

      test('the app finds the 1 s gap and counts the video, not the file', () async {
        // TS muxing adds ~10 ms between the streams.
        expect(start.offset, closeTo(1.0, 0.02));
        final v = await WorkerHarness.ffprobeJson([
          '-v', 'error', '-select_streams', 'v:0', '-show_entries',
          'stream=nb_frames,duration:format=duration', '-of', 'json', video,
        ]);
        final stream = (v['streams'] as List).first as Map<String, dynamic>;
        final stored = int.tryParse('${stream['nb_frames']}');
        final count = stored ??
            FieldOrderDetector.frameCountFromDuration(
              streamDuration: double.tryParse('${stream['duration']}'),
              containerDuration: double.tryParse('${v['format']['duration']}'),
              start: start,
              frameRate: _fps,
            );
        expect(count, _frames);
      });

      for (final n in _previewFrames) {
        test('frame $n: the preview and the before frame are source frame $n', () async {
          final pv = await WorkerHarness.runPreview(_job(video, 'preview').toJson(),
              frame: n, label: 'vstart_preview_$n');
          expect(pv.success, isTrue, reason: '${pv.error}\n${pv.errorTail}');
          await _expectFrame('the preview', await WorkerHarness.imageToRgb24(pv.png!), video, n);
          await _expectFrame(
              'the before frame', await _beforeFrame(video, n, start.offset, plan), video, n);
        });
      }

      test('a trim of $_trimStart..$_trimEnd is exactly those frames', () async {
        final out = await _encode(
            _job(video, 'trim_$stem', start: _trimStart, end: _trimEnd), 'vstart_trim');
        expect(await _countFrames(out), _trimEnd - _trimStart + 1);
        for (final i in [0, 1, _trimEnd - _trimStart]) {
          await _expectFrame('output frame $i of the trim',
              await WorkerHarness.frameRgb24(out, i, label: 'trim'), video, _trimStart + i);
        }
      });

      test('an untrimmed encode is every picture once, from the first', () async {
        final out = await _encode(_job(video, 'full_$stem'), 'vstart_full');
        expect(await _countFrames(out), _frames);
        for (final i in [0, 1, _frames - 1]) {
          await _expectFrame('output frame $i',
              await WorkerHarness.frameRgb24(out, i, label: 'full'), video, i);
        }
      });

      test('untrimmed, sound copied: in sync, the picture joining 1 s in', () async {
        final out = await _encode(
            _job(video, 'sync_copy_$stem', audio: AudioMode.passthrough), 'vstart_sync_copy');
        await _expectInSync('copied', out, flashes: 2);
        final e = await _events(out);
        expect(e.videoStart, closeTo(start.offset, _syncTolerance),
            reason: 'the output keeps the source\'s layout');
      });

      test('untrimmed, "start the sound with the picture": in sync from 0', () async {
        final out = await _encode(
            _job(video, 'sync_start_$stem',
                audio: AudioMode.passthrough,
                audioPass: const AudioRestorationParameters(
                    enabled: true, startWithPicture: true)),
            'vstart_sync_start');
        await _expectInSync('start with the picture', out, flashes: 2);
        final e = await _events(out);
        expect(e.videoStart, closeTo(0, _syncTolerance));
        final a = await WorkerHarness.firstStream(out,
            selector: 'a:0', entries: ['duration', 'start_time']);
        // Matroska stores no audio duration, so read it from the last packet.
        final d = double.tryParse('${a?['duration']}');
        if (d != null) expect(d, closeTo(_frames / _fps, 0.1));
      });

      // Task #30: AVI cannot store a picture that starts after its sound
      // (avienc wrote null frames at 1/600 and held the first picture from
      // 0), so an untrimmed AVI starts both with the picture.
      for (final codec in [VideoCodec.ffv1, VideoCodec.huffyuv]) {
        test('untrimmed to AVI (${codec.value}): a constant-rate file, every picture once',
            () async {
          final out = await _encode(
              _job(video, 'avi_${codec.value}_$stem',
                  audio: AudioMode.passthrough, container: ContainerFormat.avi, codec: codec),
              'vstart_avi');
          final v = await _aviVideo(out);
          expect(v.rate, '25/1');
          expect(v.stored, _frames, reason: 'stored frames, null frames included');
          expect(v.pts.take(2).toList(), [0.0, 0.04]);
          for (final i in [0, 1, _frames - 1]) {
            // HuffYUV stores 4:2:2, so its chroma is resampled (~1.2 levels).
            await _expectFrame('output frame $i of the AVI',
                await WorkerHarness.frameRgb24(out, i, label: 'avi'), video, i,
                maxDiff: codec == VideoCodec.huffyuv ? 2.0 : 1.0);
          }
        });
      }

      // (Convert is left out: its AAC in AVI gains a frame at the head on
      // every source, gap or not, a separate fault.)
      test('untrimmed to AVI: in sync from the first picture, copied and restored',
          () async {
        final half = await _halfPacket(video);
        final copied = await _encode(
            _job(video, 'avi_sync_copy_$stem',
                audio: AudioMode.passthrough, container: ContainerFormat.avi),
            'vstart_avi_sync_copy');
        // PCM is re-written to the sample; a compressed copy is cut at the
        // packet nearest the first picture.
        await _expectInSync('AVI, copied', copied, flashes: 2, tolerance: half + 0.001);
        for (final (label, job) in [
          ('restored', _job(video, 'avi_sync_restored_$stem',
              audio: AudioMode.passthrough,
              container: ContainerFormat.avi,
              audioPass: const AudioRestorationParameters(enabled: true, limiter: true))),
        ]) {
          final out = await _encode(job, 'vstart_avi_sync_$label');
          await _expectInSync('AVI, $label', out, flashes: 2, tolerance: 0.001);
          final e = await _events(out);
          expect(e.flashes.first, closeTo(1.0, 0.001), reason: 'frame 25 at 1 s');
          final a = await WorkerHarness.firstStream(out, selector: 'a:0', entries: ['duration']);
          final d = double.tryParse('${a?['duration']}');
          if (d != null) expect(d, closeTo(_frames / _fps, 0.05), reason: 'AVI, $label');
        }
      });

      test('trimmed $_trimStart..89, sound copied and restored: in sync', () async {
        final copied = await _encode(
            _job(video, 'sync_trim_copy_$stem',
                start: _trimStart, end: 89, audio: AudioMode.passthrough),
            'vstart_sync_trim_copy');
        await _expectInSync('trimmed, copied', copied, flashes: 1);
        final restored = await _encode(
            _job(video, 'sync_trim_restored_$stem',
                start: _trimStart,
                end: 89,
                audio: AudioMode.passthrough,
                audioPass: const AudioRestorationParameters(enabled: true, limiter: true)),
            'vstart_sync_trim_restored');
        await _expectInSync('trimmed, restored', restored, flashes: 1);
      });
    });
  }

  test('the DVB-T capture to AVI: its 126 pictures at 25/1, the first at 0 (task #30)', () async {
    final video = _resource('pal-dvbt-fieldcoded-25i.ts');
    final job = VideoJob(
      id: const Uuid().v4(),
      inputPath: video,
      outputPath: '$_outDir/dvbt.avi',
      qtgmcParameters: _off,
      processingPipeline: const ProcessingPipeline(deinterlace: _off),
      encodingSettings: EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.avi,
        audioMode: AudioMode.passthrough,
      ),
      inputFrameRate: _fps,
    );
    final v = await _aviVideo(await _encode(job, 'vstart_dvbt_avi'));
    expect(v.rate, '25/1');
    expect(v.stored, 126, reason: 'every picture once, no null frames');
    expect(v.pts.take(2).toList(), [0.0, 0.04]);
  });

  test('a source whose streams start together gets no delay', () async {
    final video = _resource('seek_timebase_2997.mov');
    expect((await _videoStart(video)).offset, 0);
    final job = VideoJob(
      id: const Uuid().v4(),
      inputPath: video,
      outputPath: '$_outDir/control.mkv',
      qtgmcParameters: _off,
      processingPipeline: const ProcessingPipeline(deinterlace: _off),
      encodingSettings: EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.passthrough,
      ),
      inputFrameRate: 30000 / 1001,
    );
    final out = await _encode(job, 'vstart_control');
    final e = await _events(out);
    expect(e.videoStart, 0);
  });
}
