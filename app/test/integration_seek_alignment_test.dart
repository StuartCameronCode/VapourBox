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
// pulldown). Sources where it isn't (MPEG-2 in AVI, soft telecine, AVI null
// frames) are separate issues; see docs/reports/issue-157-seek-alignment.
//
// MPEG-PS and MPEG-TS (issue #169) are here too. They have no keyframe index,
// so a plain seek started decoding at the keyframe AFTER the frame asked for
// (DVD GOP 12: 10 -> 12, 40 -> 48; TS GOP 25: 40 -> 50; nothing past the last
// keyframe). Their frames are chosen to hit that: mid-GOP, an open GOP's
// leading B picture just before a keyframe, and past the last keyframe.
// Fixtures: Tests/TestResources/generate_mpeg_seek_test.sh. See
// docs/reports/issue-169-mpeg-seek.
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

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/seek_alignment';

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

/// A fixture, why it is here, the frames its preview is checked at and the
/// trim it is encoded with.
class _Fixture {
  final String file;
  final String why;
  final List<int> frames;
  final int trimStart;
  final int trimEnd;
  const _Fixture(this.file, this.why,
      {this.frames = const [10, 41, 77], this.trimStart = 41, this.trimEnd = 52});
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
      frames: [1, 10, 41, 47, 77, 145], trimStart: 37, trimEnd: 52),
  // Keyframes at 0, 25, 50, ..., 125, video 1 s after the audio; 49 is the
  // leading B picture of the GOP from 50; 141 and 148 are past the last.
  _Fixture('seek_gop_late_video.ts',
      'MPEG-TS, 25-frame open GOPs, video 1 s late: affected before #169',
      frames: [1, 10, 41, 49, 77, 141, 148], trimStart: 37, trimEnd: 52),
  // The broadcast capture: keyframes at pictures 3, 31, 59, 87, 115, field
  // coded, video 1.2 s late. Frames past 117 are left out: its constant-rate
  // tail repeats a picture whether or not it seeks (see the #169 report).
  _Fixture('pal-dvbt-fieldcoded-25i.ts',
      'MPEG-TS DVB-T capture, 28-frame GOPs: affected before #169',
      frames: [10, 40, 58, 77, 117], trimStart: 45, trimEnd: 60),
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

VideoJob _job(String input, _Source s, String name, {int? start, int? end}) {
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
      audioMode: AudioMode.none,
    ),
    inputWidth: s.width,
    inputHeight: s.height,
    inputPixelFormat: s.pixFmt,
    inputFrameRate: s.fps,
    startFrame: start,
    endFrame: end,
    totalFrames: start != null && end != null ? end - start + 1 : null,
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
/// the comparison isn't measuring JPEG).
Future<Uint8List> _beforeFrame(String video, int frame, double fps,
    ({double offset, SeekPlan? plan}) seek) async {
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

Future<Map<int, Uint8List>> _neighbours(String video, int n) async => {
      for (final k in [n - 1, n, n + 1])
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

      setUpAll(() async {
        expect(await File(video).exists(), isTrue, reason: 'missing $video');
        source = await _probe(video);
        seek = await _seekInfo(video);
        // Only the MPEG-PS/TS fixtures seek with a plan.
        expect(seek.plan != null, f.file.endsWith('.ts') || f.file.endsWith('.mpg'),
            reason: '${f.file}: ${seek.plan}');
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
          final before = await _beforeFrame(video, n, source.fps, seek);
          final refs = await _neighbours(video, n);

          _expectFrame('the preview', preview, n, refs);
          _expectFrame('the before frame', before, n, refs);
        });
      }

      test('a trimmed lossless encode of ${f.trimStart}..${f.trimEnd} starts at '
          '${f.trimStart} and ends at ${f.trimEnd}', () async {
        final r = await WorkerHarness.runJob(
          _job(video, source, 'trim_${p.basenameWithoutExtension(f.file)}',
                  start: f.trimStart, end: f.trimEnd)
              .toJson(),
          label: 'seek_trim',
        );
        expect(r.success, isTrue, reason: r.error);
        final out = r.outputPath!;
        final count = f.trimEnd - f.trimStart + 1;

        final frames = await WorkerHarness.firstStream(out,
            selector: 'v:0', entries: ['nb_read_frames'], countFrames: true);
        expect(int.parse(frames!['nb_read_frames'].toString()), count);

        // The first two frames catch a doubled first frame (41, 41, 42 ..);
        // the last catches the frame that doubling pushed off the end.
        for (final i in [0, 1, count - 1]) {
          final n = f.trimStart + i;
          _expectFrame('output frame $i of the trim',
              await WorkerHarness.frameRgb24(out, i, label: 'trim'), n,
              await _neighbours(video, n));
        }
      });
    });
  }
}
