// The source grid (issue #174): every decode of the source places its frames
// on one constant-rate grid, so a null frame or a pulldown repeat is a slot
// showing the stored frame before it, the same picture everywhere. These pin
// the app's half (the Original, the thumbnails, the starts) to the
// worker's (`decode_start`) through a shared file; the
// heavy integration_seek_alignment_test checks the pictures.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('../Tests/TestResources/$name').readAsStringSync())
        as Map<String, dynamic>;

VideoInfo _info(ScanType scan, double fps, {bool pulldown = false}) => VideoInfo(
      width: 720,
      height: 480,
      frameRate: fps,
      duration: 5,
      frameCount: 120,
      codec: 'mpeg2video',
      pixelFormat: 'yuv420p',
      scanType: scan,
      hasAudio: false,
      pulldownRate: pulldown,
    );

void main() {
  group('shared vectors (source_grid_vectors.json)', () {
    final cases = (_json('source_grid_vectors.json')['cases'] as List)
        .cast<Map<String, dynamic>>();
    for (final c in cases) {
      test(c['name'], () {
        // The grid itself is the worker's (`grid_from_probe`, in the source
        // model since task #50); the starts are still built here.
        final want = c['grid'] as Map<String, dynamic>?;
        if (want == null) return;
        final grid = SourceGrid(
          rateNum: want['rateNum'] as int,
          rateDen: want['rateDen'] as int,
          origin: (want['origin'] as num).toDouble(),
        );
        for (final s in (c['starts'] as List).cast<Map<String, dynamic>>()) {
          final p = s['plan'] as Map<String, dynamic>?;
          final plan = p == null
              ? null
              : SeekPlan(
                  preroll: (p['preroll'] as num).toDouble(),
                  containerStart: (p['containerStart'] as num).toDouble());
          final start = grid.startAt(
              s['frame'] as int, (s['videoStart'] as num).toDouble(), plan);
          expect(start.input, [
            if (s['copyts'] as bool? ?? true) '-copyts',
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
      expect(args[args.indexOf('-ss') + 1], SeekPlan.formatSeek((32 - 0.5) / 25));
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
      expect(args[args.indexOf('-ss') + 1], SeekPlan.formatSeek(39.5 / 25));
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

  test('Soft Telecine decimates where the worker says the rate holds repeats', () {
    // The rate rule is the worker's (`soft_telecine_decimates_at`, the
    // model's `pulldownRate`); VideoInfo combines it with the scan type.
    expect(_info(ScanType.softTelecine, 29.97, pulldown: true).softTelecineDecimates, true);
    expect(_info(ScanType.softTelecine, 29.97, pulldown: true).contentFrameRate,
        closeTo(29.97 * 4 / 5, 1e-9));
    expect(_info(ScanType.softTelecine, 23.976).softTelecineDecimates, false);
    expect(_info(ScanType.softTelecine, 23.976).contentFrameRate, 23.976);
    // Hard telecine always reports its film rate.
    expect(_info(ScanType.telecine, 29.97).contentFrameRate,
        closeTo(23.976, 0.001));
    expect(_info(ScanType.progressive, 29.97, pulldown: true).softTelecineDecimates, false);
  });
}
