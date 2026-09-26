/// Clean-aperture sources come through at their full stored size, unresampled.
///
/// `Tests/TestResources/pal-sd-25.mov` is 720x576 10-bit 4:2:2 ProRes with a
/// QuickTime `clap` (clean aperture) atom: 8 columns off the left, 9 off the
/// right. ffprobe reports it as 720x576 — the crop only shows up as
/// `side_data_list: Frame Cropping` — but FFmpeg (7.1+) applies container
/// cropping by default, so a plain decode comes out 702x576. The worker's
/// decoder used to paper over the mismatch with `-s 720x576`, which silently
/// *rescaled* the 702-wide crop back to 720: the source was cropped and
/// resampled, with no indication, before any filter ran. It now decodes the
/// full stored frame (`-apply_cropping codec`) and refuses, rather than
/// resamples, a frame of any other size — see `worker/src/source_decode.rs`.
///
/// "Unresampled" is asserted as bit-exactness: a passthrough job encoded to
/// FFV1 must hash identically to a direct full-frame decode of the source. A
/// rescaled picture cannot pass that, however close it looks; the frame size
/// alone would (the old `-s` also produced 720x576).
///
/// Matroska carries the same crop as `PixelCrop*` elements, exported the same
/// way, so the MOV is also remuxed to MKV at run time and checked the same way.
///
/// Heavy (full encode + preview) — nightly, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/preview_generator.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/clean_aperture';

String get _mov =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'pal-sd-25.mov');

const _width = 720;
const _height = 576;
const _pixFmt = 'yuv422p10le';
const _frames = 10;

/// The source as the app probes it: ffprobe's `width`/`height`, plus the
/// container crop (which ffprobe reports only as side data).
Future<({int width, int height, String pixFmt, int cropLeft, int cropRight})>
    _probe(String path) async {
  final json = await WorkerHarness.ffprobeJson([
    '-v', 'error',
    '-select_streams', 'v:0',
    '-show_entries', 'stream=width,height,pix_fmt:stream_side_data',
    '-of', 'json',
    path,
  ]);
  final s = (json['streams'] as List).first as Map<String, dynamic>;
  final crop = ((s['side_data_list'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .firstWhere((d) => d['side_data_type'] == 'Frame Cropping',
          orElse: () => const {});
  return (
    width: s['width'] as int,
    height: s['height'] as int,
    pixFmt: s['pix_fmt'] as String,
    cropLeft: (crop['crop_left'] as int?) ?? 0,
    cropRight: (crop['crop_right'] as int?) ?? 0,
  );
}

/// Width of the first frame ffmpeg decodes with [inputOptions] before `-i`.
Future<int> _decodedWidth(String path, List<String> inputOptions) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error',
      ...inputOptions,
      '-i', path,
      '-map', '0:v:0',
      '-frames:v', '1',
      '-f', 'rawvideo', '-pix_fmt', _pixFmt,
      '-',
    ],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(r.exitCode, 0, reason: 'decode of $path failed: ${r.stderr}');
  final bytes = (r.stdout as List<int>).length;
  // yuv422p10le: 2 bytes/sample, luma + two half-width chroma planes = 4 B/px.
  return bytes ~/ (_height * 4);
}

/// MD5 of the first [_frames] frames of [path], decoded to raw [_pixFmt].
Future<String> _rawMd5(String path, {List<String> inputOptions = const []}) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error',
      ...inputOptions,
      '-i', path,
      '-map', '0:v:0',
      '-frames:v', '$_frames',
      '-c:v', 'rawvideo', '-pix_fmt', _pixFmt,
      '-f', 'md5', '-',
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'md5 of $path failed: ${r.stderr}');
  return (r.stdout as String).trim();
}

VideoJob _passthroughJob(String input, String name) => VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: const ProcessingPipeline(
        deinterlace: QTGMCParameters(enabled: false),
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      totalFrames: _frames,
      inputFrameRate: 25.0,
      inputWidth: _width,
      inputHeight: _height,
      inputPixelFormat: _pixFmt,
    );

Future<void> _expectFullFrameUnresampled(String source, String label) async {
  // The fixture really is the case under test — otherwise this passes vacuously.
  final probed = await _probe(source);
  expect((probed.width, probed.height, probed.pixFmt), (_width, _height, _pixFmt),
      reason: '$label: ffprobe must report the full stored size');
  expect(probed.cropLeft + probed.cropRight, greaterThan(0),
      reason: '$label: fixture must carry a container crop');
  final defaultWidth = await _decodedWidth(source, const []);
  expect(defaultWidth, lessThan(_width),
      reason: "$label: ffmpeg's default decode must apply the crop, or this "
          'test no longer exercises the bug');
  print('  $label: probed ${probed.width}x${probed.height}, crop '
      'L${probed.cropLeft}/R${probed.cropRight}, default decode ${defaultWidth}w');

  // The app's own "before" frame decodes the same full frame the worker does.
  expect(await _decodedWidth(source, PreviewGenerator.sourceDecodeOptions), _width,
      reason: '$label: the before/after "before" frame must be the full frame');

  // Encode: passthrough to lossless, bit-identical to the full stored frame.
  final result = await WorkerHarness.runJob(
      _passthroughJob(source, label).toJson(),
      label: label);
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '$label failed: ${result.error}\n${tail.join('\n')}');
  final out = await WorkerHarness.firstStream(result.outputPath!,
      selector: 'v:0', entries: ['width', 'height', 'pix_fmt']);
  expect((out?['width'], out?['height'], out?['pix_fmt']),
      (_width, _height, _pixFmt),
      reason: '$label: output must keep the full stored frame and format');

  final expected = await _rawMd5(source,
      inputOptions: PreviewGenerator.sourceDecodeOptions);
  final actual = await _rawMd5(result.outputPath!);
  print('  $label: source $expected / output $actual');
  expect(actual, expected,
      reason: '$label: output pixels differ from the full stored frame — the '
          'source was cropped and/or resampled on the way in');

  // Preview: the same full frame, no desync (a size mismatch here reads as
  // garbage or a length mismatch rather than a subtle difference).
  final preview = await WorkerHarness.runPreview(
      _passthroughJob(source, '${label}_preview').toJson(),
      frame: 5);
  expect(preview.png, isNotNull,
      reason: '$label preview failed: ${preview.error}\n${preview.logs}');
  final previewRgb = await WorkerHarness.imageToRgb24(preview.png!, label: label);
  expect(previewRgb.length, _width * _height * 3,
      reason: '$label: preview must be the full ${_width}x$_height frame');
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  test('clean-aperture MOV is processed at its full stored size, unresampled',
      () async {
    await _expectFullFrameUnresampled(_mov, 'clap_mov');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Matroska PixelCrop is treated the same way', () async {
    final mkv = '$_outDir/pal_pixelcrop.mkv';
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      [
        '-v', 'error', '-y',
        '-i', _mov,
        '-map', '0:v:0',
        '-frames:v', '${_frames + 5}',
        '-c', 'copy',
        mkv,
      ],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: 'remux to MKV failed: ${r.stderr}');
    await _expectFullFrameUnresampled(mkv, 'pixelcrop_mkv');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a source that changes size mid-stream fails instead of resampling',
      () async {
    // Two MPEG-TS segments at different widths, concatenated byte-wise: ffprobe
    // (like the app) reports the first segment's size.
    final a = '$_outDir/size_a.ts';
    final b = '$_outDir/size_b.ts';
    final joined = '$_outDir/size_change.ts';
    for (final (path, size, offset) in [(a, '720x576', 0), (b, '544x576', 1)]) {
      final r = await Process.run(
        WorkerHarness.ffmpegPath,
        [
          '-v', 'error', '-y',
          '-f', 'lavfi', '-i', 'testsrc2=s=$size:r=25:d=1',
          '-c:v', 'mpeg2video', '-pix_fmt', 'yuv420p',
          '-output_ts_offset', '$offset',
          '-f', 'mpegts', path,
        ],
        environment: WorkerHarness.ffmpegEnv,
      );
      expect(r.exitCode, 0, reason: 'segment $size failed: ${r.stderr}');
    }
    await File(joined).writeAsBytes([
      ...await File(a).readAsBytes(),
      ...await File(b).readAsBytes(),
    ]);
    final probed = await _probe(joined);
    expect((probed.width, probed.height), (720, 576));

    final job = VideoJob(
      id: const Uuid().v4(),
      inputPath: joined,
      outputPath: '$_outDir/size_change.mkv',
      processingPipeline: const ProcessingPipeline(
        deinterlace: QTGMCParameters(enabled: false),
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      totalFrames: 50,
      inputFrameRate: 25.0,
      inputWidth: 720,
      inputHeight: 576,
      inputPixelFormat: 'yuv420p',
    );
    final result = await WorkerHarness.runJob(job.toJson(), label: 'size_change');
    expect(result.success, isFalse,
        reason: 'a mid-stream size change must fail, not be resampled to fit');
    expect(result.error, contains('different frame size'),
        reason: 'the failure must say why: ${result.error}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
