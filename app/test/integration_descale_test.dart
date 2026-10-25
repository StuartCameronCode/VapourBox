// Descale and its native-resolution detection, end to end on fixtures with a
// known answer: testsrc2 drawn at 1280x720 and upscaled to 1080p by ffmpeg with
// a chosen kernel, the way a studio master is made. The grid block stands in
// for credits drawn at full resolution on top of the upscale.
//
//   * Detect finds 720 and the kernel actually used (Catmull-Rom, bilinear),
//     and finds nothing on a source that was never upscaled (the VHS capture);
//   * the encode keeps the size and frame count, stays close to the source,
//     and with "Protect credits and text" leaves the grid exactly as it was —
//     without it, the grid is smeared (the mask is what protects it);
//   * the preview is the encode's frame.
@Tags(['heavy'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/descale_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

const _frames = 12;
String get _dir => p.join(WorkerHarness.outputDir, 'descale');

Future<String> _master(String name, String scaleFlags, {bool credits = false}) async {
  final out = p.join(_dir, '$name.mkv');
  final up = 'scale=1920:1080:flags=$scaleFlags,format=yuv420p';
  final args = credits
      ? ['-filter_complex',
          '[0:v]$up[up];color=c=black:s=320x120:r=30000/1001:d=0.4,format=yuv420p,'
          'drawgrid=w=4:h=4:t=1:c=white[g];[up][g]overlay=x=100:y=100:shortest=1[out]',
          '-map', '[out]']
      : ['-vf', up];
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=1280x720:r=30000/1001:d=0.4',
      ...args, '-c:v', 'ffv1', out],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return out;
}

VideoJob _job(String name, String input, DescaleParameters ds,
        {int width = 1920, int height = 1080, String pixFmt = 'yuv420p', double fps = 29.97,
         int total = _frames}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: p.join(_dir, '$name.mkv'),
      processingPipeline: ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        descale: ds,
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
      inputWidth: width,
      inputHeight: height,
      inputPixelFormat: pixFmt,
      inputFrameRate: fps,
      totalFrames: total,
    );

Future<Map<String, dynamic>> _detect(VideoJob job) async {
  final config = File(p.join(Directory.systemTemp.path, 'vb_detect_${job.id}.json'));
  await config.writeAsString(jsonEncode(job.toJson()));
  try {
    final r = await Process.run(
      WorkerHarness.workerPath,
      ['--detect-native', '--config', config.path],
      environment: WorkerHarness.workerEnv,
      workingDirectory: File(WorkerHarness.workerPath).parent.path,
    );
    final line = const LineSplitter().convert(r.stdout.toString())
        .lastWhere((l) => l.trim().startsWith('{'), orElse: () => '');
    expect(line, isNotEmpty, reason: 'no report: ${r.stdout}\n${r.stderr}');
    final report = jsonDecode(line) as Map<String, dynamic>;
    // ignore: avoid_print
    print('  detect ${p.basename(job.inputPath)}: found ${report['found']} '
        '${report['height']}p ${report['kernel']} b=${report['bicubicB']} '
        'c=${report['bicubicC']} dip ${report['dip']}');
    expect(report['error'], isNull, reason: '${report['error']}');
    return report;
  } finally {
    await config.delete();
  }
}

/// Frame [index]'s luma plane, 1920 wide.
Future<Uint8List> _luma(String path, int index) async {
  final out = File(p.join(Directory.systemTemp.path,
      'vb_luma_${DateTime.now().microsecondsSinceEpoch}.y'));
  try {
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      ['-y', '-v', 'error', '-i', path, '-vf', 'select=eq(n\\,$index),extractplanes=y',
        '-frames:v', '1', '-f', 'rawvideo', out.path],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return out.readAsBytes();
  } finally {
    if (await out.exists()) await out.delete();
  }
}

double _regionDiff(Uint8List a, Uint8List b, int x0, int y0, int x1, int y1) {
  var sum = 0, n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      sum += (a[y * 1920 + x] - b[y * 1920 + x]).abs();
      n++;
    }
  }
  return sum / n;
}

void main() {
  late String catrom, bilinear, credits;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
    catrom = await _master('catrom', 'bicubic:param0=0:param1=0.5');
    bilinear = await _master('bilinear', 'bilinear');
    credits = await _master('credits', 'bicubic:param0=0:param1=0.5', credits: true);
  });

  group('Detect', () {
    test('finds 720p Catmull-Rom on a Catmull-Rom master', () async {
      final r = await _detect(_job('d_catrom', catrom, const DescaleParameters()));
      expect(r['found'], isTrue);
      expect((r['height'], r['width']), (720, 1280));
      expect(r['kernel'], 'bicubic');
      expect((r['bicubicB'] as num).toDouble(), closeTo(0, 1e-9));
      expect((r['bicubicC'] as num).toDouble(), closeTo(0.5, 1e-9));
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('finds 720p bilinear on a bilinear master', () async {
      final r = await _detect(_job('d_bilinear', bilinear, const DescaleParameters()));
      expect(r['found'], isTrue);
      expect(r['height'], 720);
      expect(r['kernel'], 'bilinear');
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('still finds it with credits drawn over the picture', () async {
      final r = await _detect(_job('d_credits', credits, const DescaleParameters()));
      expect(r['found'], isTrue);
      expect(r['height'], 720);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('finds nothing on a source that was never upscaled', () async {
      final r = await _detect(_job('d_vhs', WorkerHarness.inputFile, const DescaleParameters(),
          width: 720, height: 576, pixFmt: 'yuv422p', fps: 25, total: 75));
      expect(r['found'], isFalse, reason: 'a never-upscaled VHS capture reported a native resolution');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('Encode', () {
    const ds = DescaleParameters(enabled: true, nativeHeight: 720, kernel: DescaleKernel.bicubic,
        bicubicB: 0, bicubicC: 0.5);

    test('keeps size and count, stays close, and protects the credits', () async {
      final protected = await WorkerHarness.runJob(_job('e_protect', credits, ds).toJson(),
          label: 'descale_protect');
      expect(protected.success, isTrue, reason: protected.error);
      final s = (await WorkerHarness.firstStream(protected.outputPath!,
          selector: 'v:0', entries: ['width', 'height', 'pix_fmt', 'nb_read_frames'], countFrames: true))!;
      expect((s['width'], s['height'], s['pix_fmt']), (1920, 1080, 'yuv420p'));
      expect(int.parse('${s['nb_read_frames']}'), _frames);

      final bare = await WorkerHarness.runJob(
          _job('e_bare', credits, ds.copyWith(protectDetail: false)).toJson(), label: 'descale_bare');
      expect(bare.success, isTrue, reason: bare.error);

      final src = await _luma(credits, 3);
      final withMask = await _luma(protected.outputPath!, 3);
      final without = await _luma(bare.outputPath!, 3);
      final gridKept = _regionDiff(withMask, src, 110, 110, 410, 210);
      final gridLost = _regionDiff(without, src, 110, 110, 410, 210);
      final picture = _regionDiff(withMask, src, 700, 300, 1800, 1000);
      // ignore: avoid_print
      print('  grid: protected $gridKept, unprotected $gridLost; picture $picture');
      expect(gridKept, lessThan(0.5), reason: 'the credits were not protected');
      expect(gridLost, greaterThan(20), reason: 'without the mask the grid should be lost — '
          'if it is not, the mask is not what protects it');
      expect(picture, lessThan(3.0), reason: 'the rescaled picture is not the source\'s');

      final pv = await WorkerHarness.runPreview(_job('e_pv', credits, ds).toJson(),
          frame: 3, label: 'descale_pv');
      expect(pv.success, isTrue, reason: pv.errorTail);
      final pvDiff = WorkerHarness.meanAbsDiff(
          await WorkerHarness.imageToRgb24(pv.png!, label: 'descale_pv'),
          await WorkerHarness.frameRgb24(protected.outputPath!, 3, label: 'descale_enc3'));
      // ignore: avoid_print
      print('  preview vs encode: $pvDiff');
      expect(pvDiff, lessThan(1.0));
    }, timeout: const Timeout(Duration(minutes: 15)));
  });
}
