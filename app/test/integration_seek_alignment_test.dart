// Seek alignment (issue #157): a preview of source frame N, and a trimmed
// encode from frame S, must deliver exactly those source pictures.
//
// The worker's decoders write `rawvideo`, which ffmpeg times at a constant
// rate. After a seek, for many time bases (MP4 1/2997, MOV 1/11988, TS
// 1/90000) that timing used to emit the first kept frame TWICE: the preview
// showed frame N-1 next to the app's correct "before" frame N, and a trim of
// 41..52 came out 41, 41, 42 .. 51. Preview and encode shifted together, so
// integration_frame_mapping_test.dart (preview vs encode, on a 1/25 AVI the
// bug cannot touch) passed throughout.
//
// So everything here is checked against an INDEPENDENT reference: a
// sequential decode of the source picked by index (`select=eq(n,N)`), never
// one pipeline path against another. The fixtures are ones whose sequential
// numbering is the app's frame numbering (no leading null frames, no
// pulldown, video starting with the container). Soft telecine and AVI null
// frames are integration_source_grid_test.dart's (issue #174).
//
// MPEG-PS and MPEG-TS (issue #169) are here too. They have no keyframe index,
// so a plain seek started decoding at the keyframe AFTER the frame asked for
// (DVD GOP 12: 10 -> 12, 40 -> 48; TS GOP 25: 40 -> 50; nothing past the last
// keyframe). Their frames are chosen to hit that: mid-GOP, an open GOP's
// leading B picture just before a keyframe, and past the last keyframe.
// Fixtures: Tests/TestResources/generate_mpeg_seek_test.sh. See
// docs/reports/issue-169-mpeg-seek.
//
// AVI (issue #173) is here too. Its tick is one frame and it stores
// decode-order timestamps, so a seek went wrong three ways: a decoder delay
// (MPEG-2/MPEG-4: each picture stamped 1 frame late, H.264: 2), a half-tick
// rounding tie on every NTSC-rate AVI (1 start in 3 a frame early: 10, 43 and
// 77 are tie rows), and no seek at all for frames 1-3 of a delayed one (frame
// 1 -> 45). Frames 1-3 and the trim from 2 are in the count-from-start window.
// Fixtures: Tests/TestResources/generate_avi_seek_test.sh and
// generate_telecine_test.sh. See docs/reports/issue-173-avi-seek.
//
// Timestamp resets (task #21): a TS/PS whose clock goes back mid-file (a DVD
// title spanning VOB IDs, a spliced capture). The app decodes it from a joined
// copy made by the worker (TimestampContinuityService, run here exactly as
// _analyzeQueueItem runs it), and frame N is the Nth picture of the ORIGINAL
// in a sequential decode. Before, the count stopped at the reset (150 of 300),
// a seek past it landed in the first segment, and a trim across it stopped
// there. Fixtures: the seek_reset_* pair from generate_mpeg_seek_test.sh, with
// a flash at picture 175 and a beep at the same moment, for sync. See
// docs/reports/2026-11-timestamp-resets.
@Tags(['heavy'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';
import 'package:vapourbox/services/timestamp_continuity_service.dart';
import 'package:vapourbox/services/tool_locator.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/seek_alignment';

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

/// A fixture, why it is here, the frames its preview is checked at, the
/// trims it is encoded with and the decoder delay the app must find.
class _Fixture {
  final String file;
  final String why;
  final List<int> frames;
  final List<(int, int)> trims;
  final int delay;
  const _Fixture(this.file, this.why,
      {this.frames = const [10, 41, 77],
      this.trims = const [(41, 52)],
      this.delay = 0});
}

const _fixtures = [
  _Fixture('small_clip.mp4', 'MP4, time base 1/2997: affected before #157'),
  _Fixture('seek_timebase_2997.mov',
      'MOV, time base 1/11988 (a user\'s ProRes timescale): affected before #157'),
  _Fixture('face_restore_test.mp4', 'MP4, time base 1/30000: control'),
  // Issue #169. Keyframes (display order) at 0, 12, 24, ...; 47 is the
  // leading B picture of the GOP shown from 48; 145 is after the last
  // keyframe (144). The in-point 37 is mid-GOP.
  _Fixture('seek_dvd_pal.mpg', 'MPEG-PS (DVD), 12-frame open GOPs: affected before #169',
      frames: [1, 10, 41, 47, 77, 145], trims: [(37, 52)]),
  // Keyframes at 0, 25, 50, ..., 125, video 1 s after the audio; 49 is the
  // leading B picture of the GOP from 50; 141 and 148 are past the last.
  _Fixture('seek_gop_late_video.ts',
      'MPEG-TS, 25-frame open GOPs, video 1 s late: affected before #169',
      frames: [1, 10, 41, 49, 77, 141, 148], trims: [(37, 52)]),
  // The broadcast capture: keyframes at pictures 3, 31, 59, 87, 115, field
  // coded, video 1.2 s late. Frames past 117 are left out: its constant-rate
  // tail repeats a picture whether or not it seeks (see the #169 report).
  _Fixture('pal-dvbt-fieldcoded-25i.ts',
      'MPEG-TS DVB-T capture, 28-frame GOPs: affected before #169',
      frames: [10, 40, 58, 77, 117], trims: [(45, 60)]),
  // Issue #173.
  _Fixture('hard_telecine_test.avi',
      'MPEG-2 in AVI, decoder delay 1: 1-2 frames early (1 -> 45) before #173',
      frames: [1, 2, 3, 10, 41, 43, 77], trims: [(41, 52), (2, 13)], delay: 1),
  _Fixture('avi_h264_bframes.avi',
      'H.264 in AVI, decoder delay 2: 2-3 frames early (1 -> 60) before #173',
      frames: [1, 2, 3, 10, 41, 43, 77], trims: [(41, 52), (2, 13)], delay: 2),
  _Fixture('avi_ntsc_intra.avi',
      'MPEG-4 AVI without B-frames, 29.97: the rounding tie alone before #173',
      frames: [1, 10, 41, 43, 77], trims: [(43, 54)]),
];

/// What the app learns from ffprobe, as `FieldOrderDetector` would send it.
class _Source {
  final int width;
  final int height;
  final String pixFmt;
  final double fps;
  _Source(this.width, this.height, this.pixFmt, this.fps);
}

double _rate(String? s) {
  final parts = (s ?? '0/0').split('/');
  final n = double.tryParse(parts[0]) ?? 0;
  final d = parts.length > 1 ? double.tryParse(parts[1]) ?? 0 : 1;
  return d == 0 ? 0 : n / d;
}

Future<_Source> _probe(String path) async {
  final v = await WorkerHarness.firstStream(path,
      selector: 'v:0',
      entries: ['width', 'height', 'pix_fmt', 'r_frame_rate', 'avg_frame_rate']);
  expect(v, isNotNull, reason: 'no video stream in $path');
  final r = _rate(v!['r_frame_rate'] as String?);
  final a = _rate(v['avg_frame_rate'] as String?);
  // The app's choice: the picture rate for a field-coded source (the DVB-T
  // clip's r_frame_rate is its 50 Hz field rate).
  return _Source(v['width'] as int, v['height'] as int, v['pix_fmt'] as String,
      FieldOrderDetector.selectFrameRate(r, a) ?? (r > 0 ? r : a));
}

/// The decoder delay `PreviewGenerator` finds for [video] (issue #173), as
/// the app probes it.
Future<int> _decoderDelay(String video) async {
  final j = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0', '-show_entries',
    'stream=has_b_frames', '-of', 'json', video,
  ]);
  return FieldOrderDetector.probeDecoderDelay(WorkerHarness.ffprobePath, video,
      hasBFrames: (j['streams'] as List).first['has_b_frames'] as int?,
      videoStart: 0);
}

VideoJob _job(String input, _Source s, String name,
    {int? start, int? end, AudioMode audio = AudioMode.none, bool checked = false}) {
  const off = QTGMCParameters(enabled: false);
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: input,
    outputPath: '$_outDir/$name.mkv',
    qtgmcParameters: off,
    processingPipeline: const ProcessingPipeline(deinterlace: off),
    encodingSettings: EncodingSettings(
      codec: VideoCodec.ffv1,
      container: ContainerFormat.mkv,
      audioMode: audio,
    ),
    inputWidth: s.width,
    inputHeight: s.height,
    inputPixelFormat: s.pixFmt,
    inputFrameRate: s.fps,
    startFrame: start,
    endFrame: end,
    totalFrames: start != null && end != null ? end - start + 1 : null,
    continuityChecked: checked,
  );
}

/// What `PreviewGenerator` learns about where and how to seek: the video's
/// start offset (#168) and, on an MPEG-TS/PS, the seek plan (#169).
Future<({double offset, SeekPlan? plan})> _seekInfo(String video) async {
  final j = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0', '-show_entries',
    'stream=start_time:format=start_time,format_name', '-of', 'json', video,
  ]);
  final format = j['format'] as Map<String, dynamic>;
  final start = await FieldOrderDetector.probeVideoStart(
    WorkerHarness.ffprobePath,
    video,
    streamStart: double.tryParse('${(j['streams'] as List).first['start_time']}'),
    containerStart: double.tryParse('${format['start_time']}'),
  );
  final plan = await FieldOrderDetector.probeSeekPlan(WorkerHarness.ffprobePath, video,
      formatName: format['format_name'] as String?);
  return (offset: start.offset, plan: plan);
}

/// The app's own "before" picture of [frame], through the same argument
/// builder `PreviewGenerator.getFrameAtIndex` uses (PNG instead of JPEG, so
/// the comparison isn't measuring JPEG), with the source grid the app probes
/// (issue #174; none for an AVI that stores decode-order timestamps).
Future<Uint8List> _beforeFrame(String video, int frame, double fps,
    ({double offset, SeekPlan? plan}) seek, int delay) async {
  final grid = await FieldOrderDetector.probeSourceGrid(
      WorkerHarness.ffprobePath, video, frameRate: fps);
  final out = File(p.join(Directory.systemTemp.path,
      'vb_seek_before_${DateTime.now().microsecondsSinceEpoch}.png'));
  try {
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      PreviewGenerator.beforeFrameArgs(
        videoPath: video,
        frameIndex: frame,
        frameRate: fps,
        videoStartOffset: seek.offset,
        seekPlan: seek.plan,
        decoderDelayFrames: delay,
        grid: grid,
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

/// Asserts [img] is source frame [n] of [refs] (sequential frames keyed by
/// index): the closest of the neighbours, and near-identical to it.
///
/// Relative, as in integration_frame_mapping_test.dart: an absolute bound
/// alone could not tell a one-frame shift from a colour conversion. The
/// absolute bound is there too, because both sides are the same decode and
/// RGB conversion of the same picture, so they agree (measured 0.0 on macOS
/// arm64).
void _expectFrame(String what, Uint8List img, int n, Map<int, Uint8List> refs) {
  final diffs = {
    for (final e in refs.entries) e.key: WorkerHarness.meanAbsDiff(img, e.value),
  };
  final best = diffs.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
  final table = diffs.entries
      .map((e) => '${e.key}: ${e.value.toStringAsFixed(2)}')
      .join(', ');
  expect(best, n, reason: '$what is source frame $best, not $n ($table)');
  expect(diffs[n]!, lessThan(0.5),
      reason: '$what is not the same picture as source frame $n ($table)');
}

Future<Map<int, Uint8List>> _neighbours(String video, int n, {int? count}) async => {
      for (final k in [n - 1, n, n + 1])
        if (k >= 0 && (count == null || k < count))
          k: await WorkerHarness.frameRgb24(video, k, label: 'src'),
    };

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  for (final f in _fixtures) {
    group('${f.file} (${f.why})', () {
      final video = _resource(f.file);
      late _Source source;
      late ({double offset, SeekPlan? plan}) seek;
      late int delay;

      setUpAll(() async {
        expect(await File(video).exists(), isTrue, reason: 'missing $video');
        source = await _probe(video);
        seek = await _seekInfo(video);
        // Only the MPEG-PS/TS fixtures seek with a plan.
        expect(seek.plan != null, f.file.endsWith('.ts') || f.file.endsWith('.mpg'),
            reason: '${f.file}: ${seek.plan}');
        // The app must find the decoder delay the worker uses (issue #173):
        // only the delayed AVIs have one.
        delay = await _decoderDelay(video);
        expect(delay, f.delay, reason: '${f.file}: decoder delay');
      });

      for (final n in f.frames) {
        test('the preview of frame $n, every pass off, is source frame $n, '
            'as is the app\'s before frame', () async {
          final pv = await WorkerHarness.runPreview(
              _job(video, source, 'preview').toJson(),
              frame: n,
              label: 'seek_preview_$n');
          expect(pv.success, isTrue, reason: '${pv.error}\n${pv.errorTail}');
          final preview =
              await WorkerHarness.imageToRgb24(pv.png!, label: 'preview');
          final before = await _beforeFrame(video, n, source.fps, seek, delay);
          final refs = await _neighbours(video, n);

          _expectFrame('the preview', preview, n, refs);
          _expectFrame('the before frame', before, n, refs);
        });
      }

      if (f.delay > 0) {
        // A delayed AVI's first picture is stamped D frames in; rawvideo's
        // constant-rate output used to fill that gap with copies of it (H.264
        // in AVI: frame 0 three times, the last two frames lost).
        test('an untrimmed lossless encode is the source, frame for frame', () async {
          final total = int.parse((await WorkerHarness.firstStream(video,
                  selector: 'v:0', entries: ['nb_read_frames'], countFrames: true))![
              'nb_read_frames']
              .toString());
          final job = _job(video, source, 'untrimmed_${p.basenameWithoutExtension(f.file)}');
          final r = await WorkerHarness.runJob(
              {...job.toJson(), 'totalFrames': total},
              label: 'seek_untrimmed');
          expect(r.success, isTrue, reason: r.error);
          final out = r.outputPath!;
          final frames = await WorkerHarness.firstStream(out,
              selector: 'v:0', entries: ['nb_read_frames'], countFrames: true);
          expect(int.parse(frames!['nb_read_frames'].toString()), total);
          for (final n in [0, 1, 2, total - 1]) {
            final refs = {
              for (final k in [n - 1, n, n + 1].where((k) => k >= 0 && k < total))
                k: await WorkerHarness.frameRgb24(video, k, label: 'src'),
            };
            _expectFrame('output frame $n of the untrimmed encode',
                await WorkerHarness.frameRgb24(out, n, label: 'full'), n, refs);
          }
        });
      }

      for (final (trimStart, trimEnd) in f.trims) {
        test('a trimmed lossless encode of $trimStart..$trimEnd starts at '
            '$trimStart and ends at $trimEnd', () async {
          final r = await WorkerHarness.runJob(
            _job(video, source,
                    'trim_${p.basenameWithoutExtension(f.file)}_$trimStart',
                    start: trimStart, end: trimEnd)
                .toJson(),
            label: 'seek_trim',
          );
          expect(r.success, isTrue, reason: r.error);
          final out = r.outputPath!;
          final count = trimEnd - trimStart + 1;

          final frames = await WorkerHarness.firstStream(out,
              selector: 'v:0', entries: ['nb_read_frames'], countFrames: true);
          expect(int.parse(frames!['nb_read_frames'].toString()), count);

          // The first two frames catch a doubled first frame (41, 41, 42 ..);
          // the last catches the frame that doubling pushed off the end.
          for (final i in [0, 1, count - 1]) {
            final n = trimStart + i;
            _expectFrame('output frame $i of the trim',
                await WorkerHarness.frameRgb24(out, i, label: 'trim'), n,
                await _neighbours(video, n));
          }
        });
      }
    });
  }

  for (final file in ['seek_reset_dvd_pal.mpg', 'seek_reset_h264.ts']) {
    group('$file (timestamps reset at picture 150, task #21)', () {
      final original = _resource(file);
      late String decode;
      late _Source source;
      late ({double offset, SeekPlan? plan}) seek;

      setUpAll(() async {
        await ToolLocator.instance.initialize();
        final service = TimestampContinuityService(
            workerPath: WorkerHarness.workerPath, environment: WorkerHarness.workerEnv);
        final r = await service.prepare(original, const Uuid().v4());
        expect(r.error, isNull);
        expect(r.checked, isTrue);
        expect(r.scan!.videoResetPictures, [150]);
        expect(r.proxy, isNotNull, reason: 'a reset means a joined copy');
        decode = r.proxy!.path;
        addTearDown(r.proxy!.delete);
        source = await _probe(decode);
        seek = await _seekInfo(decode);
        expect(seek.plan, isNotNull, reason: 'the copy is still an MPEG-PS/TS');
      });

      test('the analysed frame count is every picture (it was the last segment\'s)',
          () async {
        final before = await FieldOrderDetector().getVideoInfo(original);
        final after = await FieldOrderDetector().getVideoInfo(decode);
        expect(before!.frameCount, lessThan(160), reason: 'the fault the copy fixes');
        // A program stream whose last picture's packet has no PTS counts one
        // short, reset or not (seek_dvd_pal.mpg: 149 of 150): task #26.
        expect(after!.frameCount, file.endsWith('.mpg') ? inInclusiveRange(299, 300) : 300);
      });

      for (final n in [100, 149, 150, 151, 160, 290]) {
        test('the preview and the before frame of $n are picture $n of the original',
            () async {
          final pv = await WorkerHarness.runPreview(
              _job(decode, source, 'reset_preview', checked: true).toJson(),
              frame: n,
              label: 'reset_preview_$n');
          expect(pv.success, isTrue, reason: '${pv.error}\n${pv.errorTail}');
          final refs = await _neighbours(original, n);
          _expectFrame('the preview',
              await WorkerHarness.imageToRgb24(pv.png!, label: 'preview'), n, refs);
          _expectFrame('the before frame',
              await _beforeFrame(decode, n, source.fps, seek), n, refs);
        });
      }

      for (final (start, end, checks) in [
        (100, 200, [0, 1, 49, 50, 51, 100]),
        (160, 190, [0, 1, 30]),
        (null, null, [0, 149, 150, 299]),
      ]) {
        final what = start == null ? 'an untrimmed encode' : 'a trim of $start..$end';
        test('$what is exact, across the reset', () async {
          final name = 'reset_${p.basenameWithoutExtension(file)}_${start ?? 'all'}';
          final r = await WorkerHarness.runJob(
            _job(decode, source, name, start: start, end: end, checked: true).toJson(),
            label: 'reset_encode',
          );
          expect(r.success, isTrue, reason: r.error);
          final frames = await WorkerHarness.firstStream(r.outputPath!,
              selector: 'v:0', entries: ['nb_read_frames'], countFrames: true);
          final count = start == null ? 300 : end! - start + 1;
          expect(int.parse(frames!['nb_read_frames'].toString()), count);
          for (final i in checks) {
            final n = (start ?? 0) + i;
            _expectFrame('output frame $i',
                await WorkerHarness.frameRgb24(r.outputPath!, i, label: 'reset'), n,
                await _neighbours(original, n, count: 300));
          }
        });
      }

      for (final (start, end) in [(null, null), (160, 190)]) {
        test('sound stays with picture after the reset '
            '(${start == null ? 'untrimmed' : 'trim $start..$end'})', () async {
          final name = 'reset_sync_${p.basenameWithoutExtension(file)}_${start ?? 'all'}';
          final r = await WorkerHarness.runJob(
            _job(decode, source, name,
                    start: start, end: end, audio: AudioMode.passthrough, checked: true)
                .toJson(),
            label: 'reset_sync',
          );
          expect(r.success, isTrue, reason: r.error);
          final flash = await _flashTime(r.outputPath!);
          final beep = await _beepTime(r.outputPath!);
          // Within a frame and a half: the beep starts with the 40 ms flash
          // picture; MP2 frames are 24 ms.
          expect((beep - flash).abs(), lessThan(0.06),
              reason: 'flash at ${flash.toStringAsFixed(3)} s, '
                  'beep at ${beep.toStringAsFixed(3)} s');
        });
      }
    });
  }
}

/// When the output's white flash picture is shown (its pts), in seconds.
Future<double> _flashTime(String video) async {
  final j = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-f', 'lavfi',
    'movie=${video.replaceAll(':', '\\:')},signalstats',
    '-show_entries', 'frame=pts_time:frame_tags=lavfi.signalstats.YAVG',
    '-of', 'json',
  ]);
  for (final f in (j['frames'] as List)) {
    final yavg = double.tryParse('${(f['tags'] as Map?)?['lavfi.signalstats.YAVG']}') ?? 0;
    if (yavg > 200) return double.parse('${f['pts_time']}');
  }
  fail('no flash in $video');
}

/// When the output's beep starts, in seconds: the first 10 ms window (mono,
/// 48 kHz) sample over 2000 (the fixture's 1 kHz tone peaks at ~4300, the
/// rest is silence), on the audio stream's own clock.
Future<double> _beepTime(String video) async {
  final a = await WorkerHarness.firstStream(video,
      selector: 'a:0', entries: ['start_time']);
  final start = double.tryParse('${a?['start_time']}') ?? 0;
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', video, '-map', '0:a:0', '-ac', '1', '-ar', '48000',
     '-f', 's16le', '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  final bytes = Uint8List.fromList(r.stdout as List<int>);
  final samples = bytes.buffer.asInt16List(0, bytes.length ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    if (samples[i].abs() > 2000) return start + i / 48000;
  }
  fail('no beep in $video');
}
