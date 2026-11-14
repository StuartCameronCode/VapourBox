/// Sources tagged with `reserved` colour primaries/transfer
/// (docs/reports/2026-11-reserved-colour-tags).
///
/// FFmpeg 9's scaler refuses to convert such a frame, so before the fix the
/// app's "before" frame and thumbnails, `--detect-crop` and `--detect-native`
/// all failed on a ProRes that writes "unknown" the Apple way (code 0, which
/// FFmpeg reads as `reserved`) — and so did the encode and preview of a ProRes
/// 4444 with alpha, which the decoder converts to the pipe format.
///
/// Every check compares against an untagged twin: the same file stream-copied
/// with valid primaries/transfer (bt709), the matrix left unknown as in the
/// fixture. Clearing invalid primaries/transfer must give exactly the twin's
/// pictures and reports, not merely succeed.
///
/// The fixtures come from `Tests/TestResources/generate_reserved_colour_tags_test.sh`.
///
/// Heavy (runs the worker, encodes) — runs in the nightly workflow.
@Tags(['heavy'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/color_tags.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

import 'support/worker_harness.dart';

String get _outDir => p.join(WorkerHarness.outputDir, 'reserved_colour_tags');

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

/// What the app reads from ffprobe for a source, through the same `colorTag`.
class _Source {
  final String path;
  final int width, height, frames;
  final double fps;
  final String pixFmt;
  final String? matrix, primaries, transfer, range;

  _Source(this.path, Map<String, dynamic> s)
      : width = s['width'] as int,
        height = s['height'] as int,
        frames = int.parse(s['nb_frames'].toString()),
        fps = _rate(s['avg_frame_rate'] as String),
        pixFmt = s['pix_fmt'] as String,
        matrix = colorTag(s, 'color_space'),
        primaries = colorTag(s, 'color_primaries'),
        transfer = colorTag(s, 'color_transfer'),
        range = colorTag(s, 'color_range');

  static double _rate(String r) {
    final parts = r.split('/');
    return double.parse(parts[0]) / double.parse(parts[1]);
  }

  static Future<_Source> probe(String path) async {
    final json = await WorkerHarness.ffprobeJson([
      '-v', 'error', '-select_streams', 'v:0', '-show_streams', '-of', 'json',
      path,
    ]);
    return _Source(path, (json['streams'] as List).first as Map<String, dynamic>);
  }

  String? get tagFix => ColorTags.decodeNeutraliser(
      matrix: matrix, primaries: primaries, transfer: transfer);

  VideoJob job(String name) => VideoJob(
        id: const Uuid().v4(),
        inputPath: path,
        outputPath: p.join(_outDir, '$name.mkv'),
        processingPipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
        ),
        totalFrames: frames,
        inputFrameRate: fps,
        inputWidth: width,
        inputHeight: height,
        inputPixelFormat: pixFmt,
        inputColorMatrix: matrix,
        inputColorPrimaries: primaries,
        inputColorTransfer: transfer,
        inputColorRange: range,
      );
}

/// [source] stream-copied with valid primaries and transfer.
Future<String> _twin(String source) async {
  final out = p.join(_outDir, 'twin_${p.basename(source)}');
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-y', '-i', source, '-map', '0', '-c', 'copy',
      '-bsf:v', 'prores_metadata=color_primaries=bt709:color_trc=bt709',
      out,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'making the twin: ${r.stderr}');
  return out;
}

/// Run ffmpeg with [args] (an output path last); the file's bytes, or null
/// with the stderr when it fails.
Future<(Uint8List?, String)> _ffmpeg(List<String> args) async {
  final out = File(args.last);
  if (out.existsSync()) out.deleteSync();
  final r = await Process.run(WorkerHarness.ffmpegPath, ['-v', 'error', ...args],
      environment: WorkerHarness.ffmpegEnv);
  if (r.exitCode != 0 || !out.existsSync()) return (null, r.stderr.toString());
  return (out.readAsBytesSync(), '');
}

Future<Map<String, dynamic>> _detect(String flag, VideoJob job) async {
  final config = File(p.join(_outDir, '${job.id}.json'));
  await config.writeAsString(jsonEncode(job.toJson()));
  try {
    final r = await Process.run(
      WorkerHarness.workerPath,
      [flag, '--config', config.path],
      environment: WorkerHarness.workerEnv,
      workingDirectory: File(WorkerHarness.workerPath).parent.path,
    );
    final line = const LineSplitter()
        .convert(r.stdout.toString())
        .lastWhere((l) => l.trim().startsWith('{'), orElse: () => '{}');
    final report = jsonDecode(line) as Map<String, dynamic>;
    expect(report, isNotEmpty, reason: '$flag printed no report: ${r.stderr}');
    expect(report['error'], isNull, reason: '$flag: ${report['error']}\n${r.stderr}');
    return report;
  } finally {
    await config.delete();
  }
}

/// MD5 of the first video stream's decoded frames, in its own format.
Future<String> _framesMd5(String path) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, '-map', '0:v:0', '-c:v', 'rawvideo', '-f', 'md5', '-'],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return (r.stdout as String).trim();
}

void main() {
  late _Source prores422, twin422, prores4444a, twin4444a;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    Directory(_outDir).createSync(recursive: true);
    prores422 = await _Source.probe(_resource('reserved_colour_tags.mov'));
    prores4444a = await _Source.probe(_resource('reserved_colour_tags_4444a.mov'));
    twin422 = await _Source.probe(await _twin(prores422.path));
    twin4444a = await _Source.probe(await _twin(prores4444a.path));
  });

  test('the fixtures carry reserved tags, and the twins valid ones', () {
    for (final s in [prores422, prores4444a]) {
      expect((s.primaries, s.transfer, s.matrix), ('reserved', 'reserved', null),
          reason: s.path);
      expect(s.tagFix, 'setparams=color_primaries=unknown:color_trc=unknown');
    }
    for (final s in [twin422, twin4444a]) {
      expect((s.primaries, s.transfer, s.matrix), ('bt709', 'bt709', null));
      expect(s.tagFix, isNull);
    }
    expect(prores4444a.pixFmt, 'yuva444p12le',
        reason: 'must not be a pipe format, or the encode decoder never converts');
  });

  test('before frame: fails without the fix, equals the twin\'s with it', () async {
    List<String> args(_Source s, {required bool fix}) =>
        PreviewGenerator.beforeFrameArgs(
          videoPath: s.path,
          frameIndex: 7,
          frameRate: s.fps,
          tagFix: fix ? s.tagFix : null,
          outputPath: p.join(_outDir, 'before_${p.basename(s.path)}_$fix.png'),
        );
    final (broken, err) = await _ffmpeg(args(prores422, fix: false));
    expect(broken, isNull, reason: 'the fixture no longer reproduces the bug');
    expect(err, contains('Unsupported input'));

    for (final (s, t) in [(prores422, twin422), (prores4444a, twin4444a)]) {
      final (fixed, e1) = await _ffmpeg(args(s, fix: true));
      expect(fixed, isNotNull, reason: e1);
      final (twin, e2) = await _ffmpeg(args(t, fix: true));
      expect(twin, isNotNull, reason: e2);
      expect(
        WorkerHarness.meanAbsDiff(
          await WorkerHarness.imageToRgb24(fixed!),
          await WorkerHarness.imageToRgb24(twin!),
        ),
        0,
        reason: s.path,
      );
    }
  });

  test('thumbnail: fails without the fix, succeeds with it', () async {
    List<String> args({String? tagFix}) => PreviewGenerator.thumbnailArgs(
          videoPath: prores422.path,
          time: 0.2,
          tagFix: tagFix,
          outputPath: p.join(_outDir, 'thumb_${tagFix != null}.jpg'),
        );
    final (broken, _) = await _ffmpeg(args());
    expect(broken, isNull, reason: 'the fixture no longer reproduces the bug');
    final (fixed, err) = await _ffmpeg(args(tagFix: prores422.tagFix));
    expect(fixed, isNotNull, reason: err);
  });

  test('--detect-crop reports exactly what it reports on the twin', () async {
    final report = await _detect('--detect-crop', prores422.job('crop'));
    final twin = await _detect('--detect-crop', twin422.job('crop_twin'));
    expect(report, twin);
  });

  test('--detect-native reports exactly what it reports on the twin', () async {
    final report = await _detect('--detect-native', prores422.job('native'));
    final twin = await _detect('--detect-native', twin422.job('native_twin'));
    expect(report, twin);
  });

  test('--detect-noise-halo reports exactly what it reports on the twin', () async {
    final report = await _detect('--detect-noise-halo', prores422.job('nh'));
    final twin = await _detect('--detect-noise-halo', twin422.job('nh_twin'));
    expect(report, twin);
  });

  test('preview renders the twin\'s picture (422 and converted 4444a)', () async {
    for (final (s, t) in [(prores422, twin422), (prores4444a, twin4444a)]) {
      final preview = await WorkerHarness.runPreview(s.job('pv').toJson(), frame: 5);
      expect(preview.success, isTrue, reason: '${preview.error}\n${preview.logs}');
      final twin = await WorkerHarness.runPreview(t.job('pv_twin').toJson(), frame: 5);
      expect(twin.success, isTrue, reason: '${twin.error}\n${twin.logs}');
      expect(
        WorkerHarness.meanAbsDiff(
          await WorkerHarness.imageToRgb24(preview.png!),
          await WorkerHarness.imageToRgb24(twin.png!),
        ),
        0,
        reason: s.path,
      );
    }
  });

  test('a 4444-with-alpha encode (converting decoder) equals the twin\'s', () async {
    final job = await WorkerHarness.runJob(prores4444a.job('enc').toJson(),
        label: 'encode reserved 4444a');
    expect(job.success, isTrue, reason: '${job.error}\n${job.logs.join('\n')}');
    final twin = await WorkerHarness.runJob(twin4444a.job('enc_twin').toJson(),
        label: 'encode twin 4444a');
    expect(twin.success, isTrue, reason: '${twin.error}\n${twin.logs.join('\n')}');
    expect(await _framesMd5(job.outputPath!), await _framesMd5(twin.outputPath!));
  });
}
