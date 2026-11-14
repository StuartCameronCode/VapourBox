// The source grid (issue #16): frame N is slot N of the constant-rate grid at
// the job's rate, from the video's first picture, each slot showing the
// stored frame its timestamp puts there. A null frame (AVI) or a pulldown
// repeat (soft telecine at 29.97) is a slot showing the stored frame before
// it.
//
// Before, the decoders took ffmpeg's own constant-rate output: on
// soft_telecine_test.mkv it invented two leading slots from the first frame's
// repeat flag (every encoded frame two late), on interlaced_test.avi it put
// stored frame 1 in slot 4, and a seek into a null run or onto a pulldown
// repeat landed on the next stored frame. The Soft Telecine method removed
// one real film frame in five from a source already at 23.976.
//
// Everything is checked against an INDEPENDENT reference built here: every
// stored frame decoded once (`-fps_mode passthrough`) and placed on the grid
// by its ffprobe timestamp. Never one pipeline path against another.
// See docs/reports/issue-16-source-grid.
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

String get _outDir => '${WorkerHarness.outputDir}/source_grid';

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

class _Fixture {
  final String file;
  final String why;

  /// Frames previewed, shown as the app's Original, and trimmed from.
  final List<int> frames;
  const _Fixture(this.file, this.why, this.frames);
}

const _fixtures = [
  _Fixture('interlaced_test.avi',
      'Lagarith AVI, 4 leading null frames: 75 stored, 79 slots', [1, 3, 4, 5, 40]),
  _Fixture('null_frames_mid.avi',
      'MPEG-4 AVI, stored frames 100-104 dropped (null frames)', [98, 100, 102, 105]),
  _Fixture('soft_telecine_test.mkv',
      '23.976 header with repeat flags: 120 film frames', [1, 10, 41]),
  _Fixture('soft_telecine_dvd.vob',
      'DVD-shaped soft telecine, MPEG-PS at 29.97: 3:2 repeats', [3, 10, 43]),
  _Fixture('soft_telecine_dvd.mkv',
      'the same stream with MakeMKV-like 23.976 timestamps', [3, 10, 43]),
];

/// The reference: the source as the app numbers it.
class _Reference {
  final int width;
  final int height;
  final String pixFmt;
  final double fps;
  final int rateNum;
  final int rateDen;

  /// Luma MD5 of every stored frame, in presentation order.
  final List<String> stored;

  /// For each slot, the stored frame it shows.
  final List<int> slots;

  _Reference(this.width, this.height, this.pixFmt, this.fps, this.rateNum,
      this.rateDen, this.stored, this.slots);

  List<String> slotHashes(int from, int to) =>
      [for (var i = from; i <= to; i++) stored[slots[i]]];
}

(int, int) _fraction(String? s) {
  final parts = (s ?? '0/0').split('/');
  return (int.tryParse(parts[0]) ?? 0, parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 1);
}

/// Luma MD5 per frame from ffmpeg's framemd5, in decode output order.
Future<List<String>> _lumaHashes(String path, List<String> extra) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, '-map', '0:v:0', ...extra,
     '-pix_fmt', 'gray', '-f', 'framemd5', '-'],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'framemd5 of $path: ${r.stderr}');
  return [
    for (final line in (r.stdout as String).split('\n'))
      if (line.isNotEmpty && !line.startsWith('#')) line.split(',').last.trim(),
  ];
}

Future<_Reference> _reference(String path) async {
  final v = await WorkerHarness.firstStream(path,
      selector: 'v:0',
      entries: ['width', 'height', 'pix_fmt', 'r_frame_rate', 'avg_frame_rate']);
  final r = _fraction(v!['r_frame_rate'] as String?);
  final a = _fraction(v['avg_frame_rate'] as String?);
  // FieldOrderDetector.selectFrameRate's rule: avg when r is about twice it.
  final ratio = a.$1 > 0 ? (r.$1 * a.$2) / (r.$2 * a.$1) : 0.0;
  final rate = ratio > 1.8 && ratio < 2.2 ? a : r;
  final fps = rate.$1 / rate.$2;

  final stored = await _lumaHashes(path, ['-fps_mode', 'passthrough']);
  final probe = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 'v:0',
    '-show_entries', 'frame=pts_time,best_effort_timestamp_time',
    '-of', 'json', path,
  ]);
  final times = <double>[
    for (final f in (probe['frames'] as List).cast<Map<String, dynamic>>())
      double.parse('${f['pts_time'] ?? f['best_effort_timestamp_time']}'),
  ];
  expect(times.length, stored.length, reason: 'one timestamp per stored frame');
  final origin = times.reduce((x, y) => x < y ? x : y);
  final slotOf = [for (final t in times) ((t - origin) * fps).round()];
  final slots = <int>[];
  var k = 0;
  for (var i = 0; i <= slotOf.last; i++) {
    while (k + 1 < slotOf.length && slotOf[k + 1] <= i) {
      k++;
    }
    slots.add(k);
  }
  return _Reference(v['width'] as int, v['height'] as int,
      v['pix_fmt'] as String, fps, rate.$1, rate.$2, stored, slots);
}

VideoJob _job(String input, _Reference s, String name,
    {int? start, int? end, int? total, bool softTelecine = false}) {
  final deint = softTelecine
      ? const QTGMCParameters(enabled: true, method: DeinterlaceMethod.softTelecine)
      : const QTGMCParameters(enabled: false);
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: input,
    outputPath: '$_outDir/$name.mkv',
    qtgmcParameters: deint,
    processingPipeline: ProcessingPipeline(deinterlace: deint),
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
    totalFrames: total ?? (start != null && end != null ? end - start + 1 : null),
  );
}

/// The app's frame count for [path], as `FieldOrderDetector.getVideoInfo`
/// computes it for a constant-rate source.
Future<int> _appCount(String path, double fps) async {
  final v = await WorkerHarness.firstStream(path,
      selector: 'v:0', entries: ['nb_frames', 'duration']);
  final nb = int.tryParse('${v!['nb_frames']}');
  if (nb != null) return nb;
  final f = await WorkerHarness.ffprobeJson(
      ['-v', 'error', '-show_entries', 'format=duration', '-of', 'json', path]);
  return FieldOrderDetector.frameCountWithoutStoredCount(
    WorkerHarness.ffprobePath,
    path,
    streamDuration: double.tryParse('${v['duration']}'),
    containerDuration: double.tryParse('${(f['format'] as Map)['duration']}'),
    start: VideoStart.none,
    frameRate: fps,
  );
}

/// [img] (RGB) must be stored frame [k]: the closest of its stored
/// neighbours, and the same picture.
Future<void> _expectStored(String what, String video, Uint8List img, int k,
    int storedCount) async {
  final diffs = <int, double>{};
  for (final j in [k - 1, k, k + 1]) {
    if (j < 0 || j >= storedCount) continue;
    diffs[j] = WorkerHarness.meanAbsDiff(
        img, await WorkerHarness.frameRgb24(video, j, label: 'stored'));
  }
  final best = diffs.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
  final table =
      diffs.entries.map((e) => '${e.key}: ${e.value.toStringAsFixed(2)}').join(', ');
  expect(best, k, reason: '$what is stored frame $best, not $k ($table)');
  expect(diffs[k]!, lessThan(0.5), reason: '$what is not stored frame $k ($table)');
}

Future<Uint8List> _original(String video, int frame, _Reference ref) async {
  final grid = await FieldOrderDetector.probeSourceGrid(
      WorkerHarness.ffprobePath, video, frameRate: ref.fps);
  final plan = await FieldOrderDetector.probeSeekPlan(
      WorkerHarness.ffprobePath, video,
      formatName: (await WorkerHarness.ffprobeJson([
        '-v', 'error', '-show_entries', 'format=format_name', '-of', 'json', video
      ]))['format']['format_name'] as String?);
  final out = File(p.join(Directory.systemTemp.path,
      'vb_grid_before_${DateTime.now().microsecondsSinceEpoch}.png'));
  try {
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      PreviewGenerator.beforeFrameArgs(
        videoPath: video,
        frameIndex: frame,
        frameRate: ref.fps,
        seekPlan: plan,
        grid: grid,
        outputPath: out.path,
      ),
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: 'Original of $frame: ${r.stderr}');
    return WorkerHarness.imageToRgb24(await out.readAsBytes(), label: 'original');
  } finally {
    if (await out.exists()) await out.delete().catchError((_) => out);
  }
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  for (final f in _fixtures) {
    group('${f.file} (${f.why})', () {
      final video = _resource(f.file);
      late _Reference ref;
      final stem = p.basenameWithoutExtension(f.file) + p.extension(f.file).substring(1);

      setUpAll(() async {
        expect(await File(video).exists(), isTrue,
            reason: 'missing $video (Tests/TestResources/generate_source_grid_test.sh)');
        ref = await _reference(video);
      });

      test('the app counts the frames the encode produces, and the untrimmed '
          'encode is every slot', () async {
        final count = await _appCount(video, ref.fps);
        expect(count, ref.slots.length,
            reason: 'the timeline must be the grid\'s length');
        final r = await WorkerHarness.runJob(
            _job(video, ref, 'all_$stem', total: count).toJson(),
            label: 'grid_all');
        expect(r.success, isTrue, reason: r.error);
        expect(await _lumaHashes(r.outputPath!, []),
            ref.slotHashes(0, ref.slots.length - 1));
      });

      for (final n in f.frames) {
        test('frame $n: the preview, the Original and a trim from it are slot '
            '$n', () async {
          final k = ref.slots[n];

          final pv = await WorkerHarness.runPreview(
              _job(video, ref, 'preview').toJson(),
              frame: n,
              label: 'grid_preview_$n');
          expect(pv.success, isTrue, reason: '${pv.error}\n${pv.errorTail}');
          await _expectStored('the preview of $n', video,
              await WorkerHarness.imageToRgb24(pv.png!, label: 'preview'), k,
              ref.stored.length);

          await _expectStored('the Original of $n', video,
              await _original(video, n, ref), k, ref.stored.length);

          final end = (n + 11).clamp(0, ref.slots.length - 1);
          final r = await WorkerHarness.runJob(
              _job(video, ref, 'trim_${stem}_$n', start: n, end: end).toJson(),
              label: 'grid_trim');
          expect(r.success, isTrue, reason: r.error);
          expect(await _lumaHashes(r.outputPath!, []), ref.slotHashes(n, end),
              reason: 'the trim $n..$end, slot by slot');
        });
      }
    });
  }

  group('the Soft Telecine method keeps every film frame', () {
    for (final (file, fps) in [
      ('soft_telecine_test.mkv', '23.976 (already film: nothing removed)'),
      ('soft_telecine_dvd.vob', '29.97 (3:2 repeats removed)'),
    ]) {
      test('$file at $fps', () async {
        final video = _resource(file);
        final ref = await _reference(video);
        final count = await _appCount(video, ref.fps);
        final r = await WorkerHarness.runJob(
            _job(video, ref, 'soft_${p.basenameWithoutExtension(file)}',
                    total: count, softTelecine: true)
                .toJson(),
            label: 'soft_telecine');
        expect(r.success, isTrue, reason: r.error);
        final out = await _lumaHashes(r.outputPath!, []);
        final missing = [
          for (var i = 0; i < ref.stored.length; i++)
            if (!out.contains(ref.stored[i])) i,
        ];
        expect(missing, isEmpty, reason: 'film frames missing from the output');
        expect(out.toSet().length, out.length, reason: 'no repeats left');
        final rate = await WorkerHarness.firstStream(r.outputPath!,
            selector: 'v:0', entries: ['r_frame_rate']);
        expect(rate!['r_frame_rate'], '24000/1001');
      });
    }
  });
}
