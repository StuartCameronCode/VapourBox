// The app's HDR "before" frame of a source stored off its chroma grid
// (task #97).
//
// The display tone map starts with zscale, and zimg refuses a 4:2:0 frame
// with an odd width or height ("code 1027: image dimensions must be divisible
// by subsampling factor"), so the before frame of such a source was empty.
// The worker reports the grid in the source model (`video.gridPad`), and
// `beforeFrameArgs` crops to the grid below just before the tone map; it then
// matches the worker's preview (which tone-maps the padded frame) everywhere
// but the last line. SDR keeps its arguments. The shell-out half runs the
// real arguments through this platform's bundled ffmpeg.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/models/hdr_display.dart';
import 'package:vapourbox/models/source_model.dart';
import 'package:vapourbox/services/preview_generator.dart';

import 'support/worker_harness.dart';

SourceModel _model(int w, int h, String fmt, {Map<String, dynamic>? gridPad}) =>
    SourceModel.fromJson({
      'schema': SourceModel.schema,
      'video': {
        'width': w,
        'height': h,
        'pixelFormat': fmt,
        if (gridPad != null) 'gridPad': gridPad,
      },
    })!;

void main() {
  group('the model', () {
    test('reports no grid crop for a frame on its grid', () {
      final m = _model(1920, 1080, 'yuv420p10le');
      expect(m.gridPad, isNull);
      expect(m.gridCropBelow, isNull);
    });

    test('crops an off-grid frame to the grid below', () {
      final m = _model(1279, 719, 'yuv420p10le',
          gridPad: {'right': 1, 'bottom': 1, 'stepWidth': 2, 'stepHeight': 2});
      expect(m.gridPad!.right, 1);
      expect(m.gridCropBelow, 'crop=1278:718:0:0');
      expect(
          _model(63, 32, 'yuv422p10le',
                  gridPad: {'right': 1, 'bottom': 0, 'stepWidth': 2, 'stepHeight': 1})
              .gridCropBelow,
          'crop=62:32:0:0');
      expect(
          _model(62, 32, 'yuv411p',
                  gridPad: {'right': 2, 'bottom': 0, 'stepWidth': 4, 'stepHeight': 1})
              .gridCropBelow,
          'crop=60:32:0:0');
    });
  });

  group('beforeFrameArgs', () {
    final toneMap = HdrDisplay.toneMapFilter(
        matrix: 'bt2020nc', primaries: 'bt2020', transfer: 'smpte2084', range: 'tv')!;
    List<String> args({String? tm, String? crop}) => PreviewGenerator.beforeFrameArgs(
          videoPath: 'in.mkv',
          frameIndex: 0,
          frameRate: 25,
          toneMap: tm,
          gridCrop: crop,
          outputPath: 'out.jpg',
        );
    String? vf(List<String> a) {
      final i = a.indexOf('-vf');
      return i < 0 ? null : a[i + 1];
    }

    test('puts the grid crop directly before the tone map', () {
      expect(vf(args(tm: toneMap, crop: 'crop=62:32:0:0')), 'crop=62:32:0:0,$toneMap');
    });

    test('leaves SDR and on-grid HDR arguments as they were', () {
      expect(args(crop: 'crop=62:32:0:0'), args());
      expect(args(tm: toneMap), args(tm: toneMap, crop: null));
      expect(vf(args(tm: toneMap)), toneMap);
    });
  });

  group('through the bundled ffmpeg', () {
    setUpAll(WorkerHarness.ensureReady);

    test('an off-grid PQ source gives a before frame', () async {
      final dir = await Directory.systemTemp.createTemp('vb_off_grid_before');
      addTearDown(() => dir.deleteSync(recursive: true));
      final toneMap = HdrDisplay.toneMapFilter(
          matrix: 'bt2020nc', primaries: 'bt2020', transfer: 'smpte2084', range: 'tv')!;
      for (final (w, h, fmt, crop) in [
        (63, 33, 'yuv420p10le', 'crop=62:32:0:0'),
        (64, 33, 'yuv420p10le', 'crop=64:32:0:0'),
        (63, 32, 'yuv422p10le', 'crop=62:32:0:0'),
      ]) {
        final src = p.join(dir.path, '${w}x${h}_$fmt.mkv');
        final made = await Process.run(
            WorkerHarness.ffmpegPath,
            [
              '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=s=128x96:d=0.12',
              '-vf', 'scale=$w:$h,format=$fmt',
              '-color_primaries', 'bt2020', '-color_trc', 'smpte2084',
              '-colorspace', 'bt2020nc', '-color_range', 'tv',
              '-c:v', 'ffv1', src,
            ],
            environment: WorkerHarness.ffmpegEnv);
        expect(made.exitCode, 0, reason: '${made.stderr}');

        Future<ProcessResult> before(String? gridCrop, String out) => Process.run(
            WorkerHarness.ffmpegPath,
            PreviewGenerator.beforeFrameArgs(
              videoPath: src,
              frameIndex: 1,
              frameRate: 25,
              toneMap: toneMap,
              gridCrop: gridCrop,
              outputPath: out,
            ),
            environment: WorkerHarness.ffmpegEnv);

        final ok = p.join(dir.path, 'ok_${w}x$h.jpg');
        final r = await before(crop, ok);
        expect(r.exitCode, 0, reason: '${w}x$h $fmt: ${r.stderr}');
        expect(File(ok).existsSync(), isTrue);

        // The fixture still shows the fault the crop fixes. If a future zimg
        // takes it, this says so rather than passing quietly.
        final failed = await before(null, p.join(dir.path, 'bad_${w}x$h.jpg'));
        expect(failed.exitCode, isNot(0),
            reason: '${w}x$h $fmt: the uncropped tone map no longer fails; '
                'the fixture no longer reproduces task #97, drop this guard');
        expect('${failed.stderr}', contains('1027'));
      }
    });
  });
}
