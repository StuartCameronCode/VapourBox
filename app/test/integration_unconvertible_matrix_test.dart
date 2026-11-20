/// Sources tagged with a matrix FFmpeg 9's scaler has no conversion for:
/// ycgco, bt2020c, smpte2085, chroma-derived-* and ictcp (task #76,
/// docs/reports/task-76-unconvertible-matrix-tags).
///
/// FFmpeg accepts those as tags but fails any decode that converts a frame
/// carrying one ("Impossible to convert between the formats…"). Before the
/// fix that was the app's "before" frame and thumbnails, Detect borders (and
/// the other detectors where they convert), an encode whose decoder converts
/// to the pipe format, and an encode whose encoder converts (HuffYUV's
/// yuv422p, AMF's nv12). An HDR source tagged bt2020c also failed its tone
/// map in zscale.
///
/// Every check compares against a twin: the same pictures tagged with the
/// matrix the fix reads the tag as (`ColorTags.scalerStandIn`), which the
/// scaler converts. The fix must give exactly the twin's pictures and
/// reports, and the encode must keep the source's own tag.
///
/// The fixtures are made here from small_clip.mp4, retagged with setparams
/// on the decoded frames (no sample is converted) into FFV1.
///
/// Heavy (runs the worker, encodes) — runs in the nightly workflow.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/color_tags.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/hdr_display.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/source_model.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/preview_generator.dart';

import 'support/worker_harness.dart';

String get _outDir => p.join(WorkerHarness.outputDir, 'unconvertible_matrix');

const _frames = 30;

/// What the app reads about a source: the worker's source model, whose
/// colour tags are ffprobe's raw values.
class _Source {
  final String path;
  final int width, height, frames;
  final double fps;
  final String pixFmt;
  final String? matrix, primaries, transfer, range;

  _Source(this.path, SourceModel m)
      : width = m.width,
        height = m.height,
        frames = m.frameCount,
        fps = m.frameRate,
        pixFmt = m.pixelFormat ?? 'yuv420p',
        matrix = m.colorMatrix,
        primaries = m.colorPrimaries,
        transfer = m.colorTransfer,
        range = m.colorRange;

  static Future<_Source> probe(String path) async =>
      _Source(path, await WorkerHarness.sourceModel(path));

  String? get tagFix => ColorTags.decodeNeutraliser(
      matrix: matrix, primaries: primaries, transfer: transfer);

  String? get toneMap => HdrDisplay.toneMapFilter(
      matrix: matrix, primaries: primaries, transfer: transfer, range: range);

  VideoJob job(String name, {VideoCodec codec = VideoCodec.ffv1}) => VideoJob(
        id: const Uuid().v4(),
        inputPath: path,
        outputPath: p.join(_outDir, '$name.mkv'),
        processingPipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
        ),
        encodingSettings: EncodingSettings(
          codec: codec,
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

/// small_clip.mp4's first [_frames] frames in [pixFmt], tagged [matrix] etc.
/// The format change (if any) happens before setparams, untagged.
Future<_Source> _retag(String name, String matrix,
    {String? primaries, String? transfer, String pixFmt = 'yuv420p'}) async {
  final out = p.join(_outDir, '$name.mkv');
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-y',
      '-i', p.join(WorkerHarness.repoRoot, 'Tests/TestResources/small_clip.mp4'),
      '-map', '0:v:0', '-frames:v', '$_frames',
      '-vf', [
        'format=$pixFmt',
        'setparams=colorspace=$matrix:range=tv'
            '${primaries == null ? '' : ':color_primaries=$primaries'}'
            '${transfer == null ? '' : ':color_trc=$transfer'}',
      ].join(','),
      '-c:v', 'ffv1', out,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'making $name: ${r.stderr}');
  return _Source.probe(out);
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
    [
      '-v', 'error', '-i', path, '-map', '0:v:0',
      // The stored tag may be one the scaler refuses; rawvideo in the
      // stream's own format converts nothing, so this changes no sample.
      '-vf', 'setparams=colorspace=unknown',
      '-c:v', 'rawvideo', '-f', 'md5', '-',
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return (r.stdout as String).trim();
}

Future<String?> _colorSpace(String path) async =>
    (await WorkerHarness.firstStream(path,
        selector: 'v:0', entries: ['color_space']))?['color_space'] as String?;

void main() {
  // (tag, primaries): chroma-derived stands in by its primaries.
  const tags = [
    ('ycgco', null),
    ('bt2020c', 'bt2020'),
    ('smpte2085', null),
    ('ictcp', null),
    ('chroma-derived-nc', 'bt709'),
  ];

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    Directory(_outDir).createSync(recursive: true);
  });

  for (final (tag, primaries) in tags) {
    group('$tag', () {
      late _Source src, twin;
      late String standIn;

      setUpAll(() async {
        standIn = ColorTags.scalerStandIn(tag, primaries)!;
        src = await _retag('m76_$tag', tag, primaries: primaries);
        twin = await _retag('m76_${tag}_twin', standIn, primaries: primaries);
      });

      test('the fixture carries the tag, the twin its stand-in', () {
        expect(src.matrix, tag);
        expect(src.tagFix, 'setparams=colorspace=$standIn');
        expect(twin.matrix, standIn == 'unknown' ? isNull : standIn);
        expect(twin.tagFix, isNull);
      });

      test('before frame: fails without the fix, equals the twin\'s with it',
          () async {
        List<String> args(_Source s, {required bool fix}) =>
            PreviewGenerator.beforeFrameArgs(
              videoPath: s.path,
              frameIndex: 7,
              frameRate: s.fps,
              tagFix: fix ? s.tagFix : null,
              outputPath: p.join(_outDir, 'before_${p.basename(s.path)}_$fix.png'),
            );
        final (broken, err) = await _ffmpeg(args(src, fix: false));
        expect(broken, isNull, reason: 'the fixture no longer reproduces the bug');
        expect(err, contains('Impossible to convert'));
        final (fixed, e1) = await _ffmpeg(args(src, fix: true));
        expect(fixed, isNotNull, reason: e1);
        final (other, e2) = await _ffmpeg(args(twin, fix: true));
        expect(other, isNotNull, reason: e2);
        expect(
          WorkerHarness.meanAbsDiff(await WorkerHarness.imageToRgb24(fixed!),
              await WorkerHarness.imageToRgb24(other!)),
          0,
        );
      });

      test('thumbnail: fails without the fix, equals the twin\'s with it',
          () async {
        List<String> args(_Source s, {required bool fix}) =>
            PreviewGenerator.thumbnailArgs(
              videoPath: s.path,
              time: 0.2,
              tagFix: fix ? s.tagFix : null,
              outputPath: p.join(_outDir, 'thumb_${p.basename(s.path)}_$fix.jpg'),
            );
        final (broken, _) = await _ffmpeg(args(src, fix: false));
        expect(broken, isNull, reason: 'the fixture no longer reproduces the bug');
        final (fixed, err) = await _ffmpeg(args(src, fix: true));
        expect(fixed, isNotNull, reason: err);
        final (other, _) = await _ffmpeg(args(twin, fix: true));
        expect(fixed, other, reason: 'the JPEG bytes are the twin\'s');
      });

      for (final flag in ['--detect-crop', '--detect-noise-halo', '--detect-native']) {
        test('$flag reports exactly what it reports on the twin', () async {
          final report = await _detect(flag, src.job('det'));
          final other = await _detect(flag, twin.job('det_twin'));
          expect(report, other);
        }, timeout: const Timeout(Duration(minutes: 5)));
      }

      // HuffYUV takes yuv422p only, so the encoder converts this 4:2:0
      // picture: the bridge keeps the tag, and the samples are the twin's.
      test('an encode whose encoder converts keeps the tag and the samples',
          () async {
        final job = await WorkerHarness.runJob(
            src.job('enc_huff_$tag', codec: VideoCodec.huffyuv).toJson(),
            label: 'huffyuv $tag');
        expect(job.success, isTrue, reason: '${job.error}\n${job.logs.join('\n')}');
        final other = await WorkerHarness.runJob(
            twin.job('enc_huff_${tag}_twin', codec: VideoCodec.huffyuv).toJson(),
            label: 'huffyuv twin');
        expect(other.success, isTrue, reason: '${other.error}');
        expect(await _colorSpace(job.outputPath!), tag);
        expect(await _framesMd5(job.outputPath!), await _framesMd5(other.outputPath!));
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
  }

  // 4:4:0 is not a pipe format, so the encode's own decoder converts it to
  // 4:2:2: the neutraliser in front lets it.
  test('ycgco 4:4:0: an encode whose decoder converts equals the twin\'s',
      () async {
    final src = await _retag('m76_ycgco_440', 'ycgco', pixFmt: 'yuv440p');
    final twin = await _retag('m76_ycgco_440_twin', 'unknown', pixFmt: 'yuv440p');
    expect(src.pixFmt, 'yuv440p');
    final job = await WorkerHarness.runJob(src.job('enc_440').toJson(),
        label: 'ffv1 ycgco 440');
    expect(job.success, isTrue, reason: '${job.error}\n${job.logs.join('\n')}');
    final other = await WorkerHarness.runJob(twin.job('enc_440_twin').toJson(),
        label: 'ffv1 440 twin');
    expect(other.success, isTrue, reason: '${other.error}');
    expect(await _colorSpace(job.outputPath!), 'ycgco');
    expect(await _framesMd5(job.outputPath!), await _framesMd5(other.outputPath!));
  }, timeout: const Timeout(Duration(minutes: 5)));

  // zimg refuses constant luminance with a PQ transfer, so bt2020c HDR is
  // tone-mapped as bt2020nc, in the worker's preview and the app's before
  // frame alike.
  test('HDR bt2020c: preview and before frame read it as bt2020nc', () async {
    final src = await _retag('m76_hdr_cl', 'bt2020c',
        primaries: 'bt2020', transfer: 'smpte2084', pixFmt: 'yuv420p10le');
    final twin = await _retag('m76_hdr_ncl', 'bt2020nc',
        primaries: 'bt2020', transfer: 'smpte2084', pixFmt: 'yuv420p10le');
    final pv = await WorkerHarness.runPreview(src.job('hdr_pv').toJson(), frame: 5);
    expect(pv.success, isTrue, reason: '${pv.error}\n${pv.logs}');
    final pvTwin = await WorkerHarness.runPreview(twin.job('hdr_pv_twin').toJson(), frame: 5);
    expect(pvTwin.success, isTrue, reason: '${pvTwin.error}');
    expect(
      WorkerHarness.meanAbsDiff(await WorkerHarness.imageToRgb24(pv.png!),
          await WorkerHarness.imageToRgb24(pvTwin.png!)),
      0,
    );

    List<String> args(_Source s) => PreviewGenerator.beforeFrameArgs(
          videoPath: s.path,
          frameIndex: 5,
          frameRate: s.fps,
          tagFix: s.tagFix,
          toneMap: s.toneMap,
          outputPath: p.join(_outDir, 'hdr_before_${p.basename(s.path)}.png'),
        );
    final (before, err) = await _ffmpeg(args(src));
    expect(before, isNotNull, reason: err);
    final (beforeTwin, _) = await _ffmpeg(args(twin));
    expect(
      WorkerHarness.meanAbsDiff(await WorkerHarness.imageToRgb24(before!),
          await WorkerHarness.imageToRgb24(beforeTwin!)),
      0,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
