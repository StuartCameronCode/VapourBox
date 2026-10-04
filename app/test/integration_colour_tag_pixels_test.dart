/// Colour tags must label the output without changing a single pixel.
///
/// The worker re-declares the source's colour tags on the encode because the
/// Y4M pipe from vspipe strips them. Until 2026-09-26 it declared them on the
/// *output only*, which FFmpeg does not treat as a label: it saw an untagged
/// input feeding a bt709-tagged output, auto-inserted a scaler, read "unknown"
/// as BT.601, and re-matrixed every pixel from 601 to 709. Every encode from a
/// tagged source came out colour-shifted, while the tag assertions in
/// `integration_chroma_subsampling_test.dart` passed happily — they check the
/// label, not the picture. This file checks the picture.
///
/// The reference is the same job with the tags left off (an untagged job has
/// nothing to convert), plus the source's own decoded frames: with no passes
/// enabled and a lossless codec, the output's samples must be bit-identical to
/// both.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/colour_tag_pixels';

/// 10-bit 4:2:2 ProRes tagged bt709/bt709/bt709/tv — a real tagged source.
String get _fixture => '${WorkerHarness.repoRoot}/Tests/TestResources/pal-sd-25.mov';

/// Frames encoded per job. Enough to be a real encode, short enough to be quick.
const _frames = 10;

/// md5 of the decoded video samples, in the stream's own pixel format.
///
/// Decoding to rawvideo in the stream's native format involves no scaler, so
/// this hashes exactly what the file stores rather than a conversion of it.
///
/// [size] reproduces the worker's own decoder for the source reference: this
/// fixture has a clean aperture (720x576 coded, 702x576 decoded) and the
/// worker's decoder forces the probed 720x576 back with `-s`.
Future<String> _sampleMd5(String path, {int? frames, String? size, String? pixFmt}) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error',
      '-i', path,
      '-map', '0:v:0',
      if (frames != null) ...['-frames:v', '$frames'],
      if (size != null) ...['-s', size],
      if (pixFmt != null) ...['-pix_fmt', pixFmt],
      '-f', 'md5', '-',
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  if (r.exitCode != 0) throw Exception('md5 of $path failed: ${r.stderr}');
  return (r.stdout as String).trim();
}

void main() {
  late Map<String, dynamic> src;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    src = (await WorkerHarness.firstStream(_fixture, selector: 'v:0', entries: [
      'pix_fmt', 'width', 'height',
      'color_space', 'color_primaries', 'color_transfer', 'color_range',
    ]))!;
  });

  /// A job that does nothing to the picture: no deinterlace, no passes,
  /// source colour format. [tagged] decides whether the source's colour tags
  /// are passed to the worker, as the app does after probing.
  VideoJob job(String name, VideoCodec codec, ContainerFormat container,
      {required bool tagged}) {
    return VideoJob(
      id: const Uuid().v4(),
      inputPath: _fixture,
      outputPath: '$_outDir/$name',
      processingPipeline: const ProcessingPipeline(
        deinterlace: QTGMCParameters(enabled: false),
      ),
      encodingSettings: EncodingSettings(
        codec: codec,
        container: container,
        audioMode: AudioMode.none,
      ),
      // The post-trim count, which is what pipe_source must be told.
      totalFrames: _frames,
      inputFrameRate: 25,
      startFrame: 0,
      endFrame: _frames - 1,
      inputWidth: src['width'] as int,
      inputHeight: src['height'] as int,
      inputPixelFormat: src['pix_fmt'] as String,
      inputColorMatrix: tagged ? src['color_space'] as String? : null,
      inputColorPrimaries: tagged ? src['color_primaries'] as String? : null,
      inputColorTransfer: tagged ? src['color_transfer'] as String? : null,
      inputColorRange: tagged ? src['color_range'] as String? : null,
    );
  }

  Future<String> encode(VideoJob j) async {
    final result = await WorkerHarness.runJob(j.toJson(), label: j.outputPath);
    expect(result.success, isTrue, reason: '${result.error}\n${result.logs.join('\n')}');
    return result.outputPath ?? j.outputPath;
  }

  test('fixture is a tagged source (otherwise nothing here is exercised)', () {
    expect(src['color_space'], 'bt709');
    expect(src['color_range'], 'tv');
  });

  test('FFV1: a tagged encode stores the same samples as the source', () async {
    final tagged = await encode(
        job('ffv1_tagged.mkv', VideoCodec.ffv1, ContainerFormat.mkv, tagged: true));
    final untagged = await encode(
        job('ffv1_untagged.mkv', VideoCodec.ffv1, ContainerFormat.mkv, tagged: false));

    final tags = await WorkerHarness.firstStream(tagged, selector: 'v:0', entries: [
      'pix_fmt', 'color_space', 'color_primaries', 'color_transfer', 'color_range',
    ]);
    print('  tagged output: $tags');

    final t = await WorkerHarness.frameAverages(tagged);
    final u = await WorkerHarness.frameAverages(untagged);
    print('  frame averages  tagged: $t\n                untagged: $u');

    // The picture: identical to the untagged encode and to the source itself.
    final sourceMd5 = await _sampleMd5(_fixture,
        frames: _frames,
        size: '${src['width']}x${src['height']}',
        pixFmt: src['pix_fmt'] as String);
    expect(await _sampleMd5(untagged), sourceMd5,
        reason: 'control: a no-op pipeline into FFV1 must be lossless');
    expect(await _sampleMd5(tagged), sourceMd5,
        reason: 'declaring the source\'s colour tags changed the pixels — '
            'ffmpeg is converting untagged input to the output tag '
            '(tagged $t vs untagged $u)');

    // The label: all four tags written, not just the two ffmpeg negotiates.
    expect(tags!['pix_fmt'], src['pix_fmt']);
    expect(tags['color_space'], 'bt709');
    expect(tags['color_range'], 'tv');
    expect(tags['color_primaries'], 'bt709',
        reason: 'output-only -color_primaries never reached the file');
    expect(tags['color_transfer'], 'bt709',
        reason: 'output-only -color_trc never reached the file');
  }, timeout: const Timeout(Duration(minutes: 5)));

  // The preview converts the (untagged) Y4M frame to RGB with the source's
  // matrix fed to swscale explicitly (`swscale_input_opts`). The encode, read
  // back through its tags, must show the same picture — before the fix it was
  // re-matrixed and then labelled bt709, so it could not.
  test('the tagged encode looks the same as the preview of that frame', () async {
    final j = job('ffv1_preview_match.mkv', VideoCodec.ffv1, ContainerFormat.mkv,
        tagged: true);
    final out = await encode(j);
    const frame = 2;
    final preview = await WorkerHarness.runPreview(j.toJson(), frame: frame);
    expect(preview.success, isTrue, reason: '$preview');

    final previewRgb = await WorkerHarness.imageToRgb24(preview.png!, label: 'pv');
    final encodedRgb = await WorkerHarness.frameRgb24(out, frame, label: 'enc');
    final diff = WorkerHarness.meanAbsDiff(previewRgb, encodedRgb);
    print('  preview vs encode mean abs diff: ${diff.toStringAsFixed(3)}/255');
    expect(diff, lessThan(1.0),
        reason: 'the encode shows different colours from the preview');
  }, timeout: const Timeout(Duration(minutes: 5)));

  // The forced-pix_fmt path: ProRes 4444 pins yuv444p10le, so a scaler *is*
  // inserted for the 4:2:2 -> 4:4:4 step. It must only resample chroma, never
  // re-matrix, so the tagged and untagged encodes must still match exactly.
  test('ProRes 4444 (pinned pix_fmt): tags do not change the pixels', () async {
    final tagged = await encode(job(
        'prores4444_tagged.mov', VideoCodec.prores4444, ContainerFormat.mov,
        tagged: true));
    final untagged = await encode(job(
        'prores4444_untagged.mov', VideoCodec.prores4444, ContainerFormat.mov,
        tagged: false));

    final t = await WorkerHarness.frameAverages(tagged);
    final u = await WorkerHarness.frameAverages(untagged);
    print('  frame averages  tagged: $t\n                untagged: $u');

    expect(await _sampleMd5(tagged), await _sampleMd5(untagged),
        reason: 'tagged $t vs untagged $u');

    final tags = await WorkerHarness.firstStream(tagged,
        selector: 'v:0', entries: ['pix_fmt', 'color_space', 'color_range']);
    expect(tags!['pix_fmt'], contains('444'));
    expect(tags['color_space'], 'bt709');
    expect(tags['color_range'], 'tv');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
