// The source grid (issue #16): every decode of the source places its frames
// on one constant-rate grid, so a null frame or a pulldown repeat is a slot
// showing the stored frame before it, the same picture everywhere. These pin
// the app's half (the Original, the thumbnails, the frame count, the Soft
// Telecine decision) to the worker's (`source_decode::grid_from_probe`,
// `decode_start`, `soft_telecine_decimates_at`) through shared files; the
// heavy integration_seek_alignment_test checks the pictures.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('../Tests/TestResources/$name').readAsStringSync())
        as Map<String, dynamic>;

VideoInfo _info(ScanType scan, double fps) => VideoInfo(
      width: 720,
      height: 480,
      frameRate: fps,
      duration: 5,
      frameCount: 120,
      codec: 'mpeg2video',
      pixelFormat: 'yuv420p',
      scanType: scan,
      hasAudio: false,
    );

void main() {
  group('shared vectors (source_grid_vectors.json)', () {
    final cases = (_json('source_grid_vectors.json')['cases'] as List)
        .cast<Map<String, dynamic>>();
    for (final c in cases) {
      test(c['name'], () {
        final grid = SourceGrid.fromProbe(
            c['probe'] as Map<String, dynamic>, (c['jobFps'] as num).toDouble());
        final want = c['grid'] as Map<String, dynamic>?;
        if (want == null) {
          expect(grid, isNull);
          return;
        }
        expect(
            grid,
            SourceGrid(
              rateNum: want['rateNum'] as int,
              rateDen: want['rateDen'] as int,
              origin: (want['origin'] as num).toDouble(),
            ));
        for (final s in (c['starts'] as List).cast<Map<String, dynamic>>()) {
          final p = s['plan'] as Map<String, dynamic>?;
          final plan = p == null
              ? null
              : SeekPlan(
                  preroll: (p['preroll'] as num).toDouble(),
                  containerStart: (p['containerStart'] as num).toDouble());
          final start = grid!.startAt(
              s['frame'] as int, (s['videoStart'] as num).toDouble(), plan);
          expect(start.input, [
            '-copyts',
            if (s['ss'] != null) ...['-ss', s['ss']],
          ], reason: 'frame ${s['frame']}');
          expect(start.filters, (s['filters'] as List).cast<String>());
        }
      });
    }
  });

  test('the grid filters are the worker\'s, character for character', () {
    final rust = File('../worker/src/source_decode.rs').readAsStringSync();
    for (final fragment in [
      'format!("setpts=PTS-{:.6}/TB", self.origin)',
      'format!("fps={}/{}", self.rate_num, self.rate_den)',
      'format!("trim=start_pts={}", first.max(0))',
      'pub const GRID_LOOKBACK_SLOTS: i64 = ${SourceGrid.lookbackSlots};',
      'pub const GRID_RATE_TOLERANCE: f64 = ${SourceGrid.rateTolerance};',
    ]) {
      expect(rust, contains(fragment));
    }
  });

  group('the Original on the grid', () {
    const grid = SourceGrid(rateNum: 25, rateDen: 1, origin: 0);

    test('a frame inside a leading null run decodes from the start', () {
      final args = PreviewGenerator.beforeFrameArgs(
        videoPath: 'in.avi',
        frameIndex: 3,
        frameRate: 25,
        grid: grid,
        outputPath: 'out.png',
      );
      expect(args.sublist(0, 2), ['-y', '-copyts']);
      expect(args, isNot(contains('-ss')));
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf,
          'setpts=PTS-0.000000/TB,fps=25/1,trim=start_pts=3,setpts=PTS-STARTPTS');
      expect(args[args.indexOf('-frames:v') + 1], '1');
    });

    test('a later frame seeks the lookback early, tag fix first, tone map last',
        () {
      final args = PreviewGenerator.beforeFrameArgs(
        videoPath: 'in.mkv',
        frameIndex: 40,
        frameRate: 25,
        tagFix: 'setparams=color_primaries=unknown',
        toneMap: 'zscale=t=linear',
        grid: grid,
        outputPath: 'out.png',
      );
      expect(args[args.indexOf('-ss') + 1], ((32 - 0.5) / 25).toStringAsFixed(6));
      expect(args[args.indexOf('-vf') + 1],
          'setparams=color_primaries=unknown,setpts=PTS-0.000000/TB,fps=25/1,'
          'trim=start_pts=40,setpts=PTS-STARTPTS,zscale=t=linear');
    });

    test('without a grid the arguments are as before', () {
      final args = PreviewGenerator.beforeFrameArgs(
        videoPath: 'in.mkv',
        frameIndex: 40,
        frameRate: 25,
        outputPath: 'out.png',
      );
      expect(args, isNot(contains('-copyts')));
      expect(args[args.indexOf('-ss') + 1], (39.5 / 25).toStringAsFixed(6));
    });

    test('a thumbnail is the frame shown at its time', () {
      final args = PreviewGenerator.thumbnailArgs(
        videoPath: 'in.mkv',
        time: 2.0,
        grid: grid,
        outputPath: 't.jpg',
      );
      expect(args[args.indexOf('-vf') + 1],
          startsWith('setpts=PTS-0.000000/TB,fps=25/1,trim=start_pts=50,'));
      expect(args[args.indexOf('-vf') + 1], contains('scale=160:-1'));
    });
  });

  test('the frame count from the last picture is its slot plus one', () {
    // soft_telecine_test.mkv: last picture 4.963 s at 24000/1001 -> 120 (its
    // container duration, 5.047 s, counted 121).
    const film = SourceGrid(rateNum: 24000, rateDen: 1001, origin: 0);
    expect(FieldOrderDetector.frameCountFromLastPicture(4.963, film), 120);
    // A late picture counts from its own start.
    const late = SourceGrid(rateNum: 25, rateDen: 1, origin: 1.0);
    expect(FieldOrderDetector.frameCountFromLastPicture(4.96, late), 100);
  });

  test('Soft Telecine decimates at the same rates as the worker', () {
    for (final row in (_json('soft_telecine_rates.json')['rates'] as List)
        .cast<Map<String, dynamic>>()) {
      final fps = (row['fps'] as num).toDouble();
      final info = _info(ScanType.softTelecine, fps);
      expect(info.softTelecineDecimates, row['decimates'], reason: '$fps');
      expect(info.contentFrameRate,
          row['decimates'] as bool ? closeTo(fps * 4 / 5, 1e-9) : fps);
    }
    // Hard telecine always reports its film rate.
    expect(_info(ScanType.telecine, 29.97).contentFrameRate,
        closeTo(23.976, 0.001));
    expect(_info(ScanType.progressive, 29.97).softTelecineDecimates, false);
  });
}
