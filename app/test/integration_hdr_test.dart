/// HDR10 sources (issue #133): the encode keeps the HDR10 static metadata,
/// and the preview shows the picture tone-mapped, the same way as the app's
/// own "before" frame.
///
/// A Dolby Vision Profile 8.1 file is this same HDR10 picture plus an RPU
/// track the decoder ignores, so the fixture is plain HDR10 — making one with
/// an RPU needs dovi_tool, which CI doesn't have. The Dolby Vision parsing is
/// covered by unit tests on both sides (`hdr_metadata.rs`,
/// `hdr_display_test.dart`) against ffprobe's real output for such a file.
///
/// Heavy (full-encode) — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/hdr_display.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/preview_generator.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/hdr';
String get _fixture => '$_outDir/hdr10_bars.mkv';

const _width = 1280;
const _height = 720;
const _frames = 24;

/// What the fixture declares, in x265's units.
const _masterDisplay =
    'G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)';

/// SMPTE HD bars converted into a real PQ / BT.2020 picture (reference white
/// at 203 nits), so a correct tone-map has saturated bars to show and an
/// untone-mapped one shows them grey.
Future<void> _makeFixture() async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-y', '-v', 'error',
      '-f', 'lavfi', '-i', 'smptehdbars=s=${_width}x$_height:r=24,format=gbrpf32le',
      '-vf',
      'zscale=tin=bt709:pin=bt709:min=gbr:t=smpte2084:p=bt2020:m=bt2020nc'
          ':r=limited:npl=203,format=yuv420p10le',
      '-frames:v', '$_frames',
      '-c:v', 'libx265',
      '-x265-params',
      'log-level=error:crf=16:colorprim=bt2020:transfer=smpte2084'
          ':colormatrix=bt2020nc:master-display=$_masterDisplay:max-cll=1000,400',
      _fixture,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  if (r.exitCode != 0) throw Exception('HDR10 fixture failed: ${r.stderr}');
}

/// Side data types on the stream and the first decoded frame.
Future<List<Map<String, dynamic>>> _sideData(String path) async {
  final json = await WorkerHarness.ffprobeJson([
    '-v', 'error',
    '-select_streams', 'v:0',
    '-read_intervals', '%+#8',
    '-show_streams', '-show_frames',
    '-of', 'json',
    path,
  ]);
  final all = <Map<String, dynamic>>[];
  for (final s in [...(json['streams'] as List), ...(json['frames'] as List? ?? [])]) {
    for (final d in (s as Map)['side_data_list'] as List? ?? const []) {
      all.add(Map<String, dynamic>.from(d as Map));
    }
  }
  return all;
}

/// The pixel at (x, y) of an rgb24 buffer.
List<int> _px(Uint8List rgb, int x, int y) {
  final i = (y * _width + x) * 3;
  return [rgb[i], rgb[i + 1], rgb[i + 2]];
}

/// x of the green bar's centre in SMPTE HD bars, y inside the top band.
const _greenBar = (x: 640, y: 200);

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    await _makeFixture();
  });

  VideoJob job(String name, VideoCodec codec, {bool tagged = true}) => VideoJob(
        id: const Uuid().v4(),
        inputPath: _fixture,
        outputPath: '$_outDir/$name',
        processingPipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
        ),
        encodingSettings: EncodingSettings(
          codec: codec,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
        ),
        totalFrames: _frames,
        inputFrameRate: 24,
        inputWidth: _width,
        inputHeight: _height,
        inputPixelFormat: 'yuv420p10le',
        inputColorMatrix: tagged ? 'bt2020nc' : null,
        inputColorPrimaries: tagged ? 'bt2020' : null,
        inputColorTransfer: tagged ? 'smpte2084' : null,
        inputColorRange: tagged ? 'tv' : null,
      );

  test('fixture carries HDR10 metadata (otherwise nothing here is exercised)',
      () async {
    final types = (await _sideData(_fixture)).map((d) => d['side_data_type']);
    expect(types, contains('Mastering display metadata'));
    expect(types, contains('Content light level metadata'));
  });

  test('H.265 keeps the mastering display and light levels', () async {
    final j = job('hdr10_x265.mkv', VideoCodec.h265);
    final result = await WorkerHarness.runJob(j.toJson(), label: 'hdr10 x265');
    expect(result.success, isTrue, reason: '${result.error}\n${result.logs.join('\n')}');

    final tags = await WorkerHarness.firstStream(j.outputPath, selector: 'v:0', entries: [
      'pix_fmt', 'color_space', 'color_primaries', 'color_transfer',
    ]);
    expect(tags!['color_transfer'], 'smpte2084');
    expect(tags['color_primaries'], 'bt2020');
    expect(tags['pix_fmt'], 'yuv420p10le');

    final side = await _sideData(j.outputPath);
    final md = side.firstWhere((d) => d['side_data_type'] == 'Mastering display metadata',
        orElse: () => fail('no mastering display metadata in the output: $side'));
    expect(md['max_luminance'], '10000000/10000');
    expect(md['red_x'], '34000/50000');
    final cll = side.firstWhere((d) => d['side_data_type'] == 'Content light level metadata',
        orElse: () => fail('no content light level in the output: $side'));
    expect(cll['max_content'], 1000);
    expect(cll['max_average'], 400);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('other encoders still encode an HDR source, tags intact', () async {
    // libx264 must not be handed -x265-params, which would fail the encode.
    final j = job('hdr10_x264.mkv', VideoCodec.h264);
    final result = await WorkerHarness.runJob(j.toJson(), label: 'hdr10 x264');
    expect(result.success, isTrue, reason: '${result.error}\n${result.logs.join('\n')}');
    final tags = await WorkerHarness.firstStream(j.outputPath,
        selector: 'v:0', entries: ['color_transfer']);
    expect(tags!['color_transfer'], 'smpte2084');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the preview is tone-mapped, and matches the app\'s "before" frame',
      () async {
    const frame = 5;
    final preview = await WorkerHarness.runPreview(
        job('unused.mkv', VideoCodec.h265).toJson(), frame: frame);
    expect(preview.png, isNotNull, reason: '${preview.error}\n${preview.logs}');
    final after = await WorkerHarness.imageToRgb24(preview.png!, label: 'hdr_after');

    // The control: the same preview without the tags is what every HDR
    // source looked like before — PQ read as SDR, grey and desaturated.
    final raw = await WorkerHarness.runPreview(
        job('unused.mkv', VideoCodec.h265, tagged: false).toJson(), frame: frame);
    final washed = await WorkerHarness.imageToRgb24(raw.png!, label: 'hdr_raw');

    // The app's "before" frame: PreviewGenerator.getFrameAtIndex's command.
    final beforeJpg = File('$_outDir/before.jpg');
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      [
        '-y', '-v', 'error',
        '-ss', ((frame - 0.5) / 24).toStringAsFixed(6),
        ...PreviewGenerator.sourceDecodeOptions,
        '-i', _fixture,
        '-frames:v', '1',
        '-vf', HdrDisplay.toneMapFilter(
            matrix: 'bt2020nc', primaries: 'bt2020', transfer: 'smpte2084', range: 'tv')!,
        '-q:v', '2',
        beforeJpg.path,
      ],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final before =
        await WorkerHarness.imageToRgb24(await beforeJpg.readAsBytes(), label: 'hdr_before');

    final g = _px(after, _greenBar.x, _greenBar.y);
    final w = _px(washed, _greenBar.x, _greenBar.y);
    final b = _px(before, _greenBar.x, _greenBar.y);
    print('  green bar  after $g  before $b  untone-mapped $w');

    expect(g[1] - g[0], greaterThan(100), reason: 'the green bar should be green: $g');
    expect(w[1] - w[0], lessThan(60),
        reason: 'control: without tags the bar should be the old washed-out grey: $w');
    for (var c = 0; c < 3; c++) {
      expect((g[c] - b[c]).abs(), lessThanOrEqualTo(4),
          reason: 'before $b and after $g differ in channel $c (JPEG matrix?)');
    }
    final diff = WorkerHarness.meanAbsDiff(after, before);
    print('  mean |after - before| = ${diff.toStringAsFixed(2)}');
    expect(diff, lessThan(3.0));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
