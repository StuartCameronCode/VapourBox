// MPEG-TS/PS seeks (issue #169): a TS or PS has no keyframe index, so a plain
// `-ss` starts decoding at the keyframe AFTER the frame asked for. Its decodes
// seek a GOP early with `-copyts` and trim to the frame instead. These pin the
// app's half (the before frame, the thumbnails) to the worker's
// (`source_decode::seek_plan_from_probe`, `decoder_seek`); the heavy
// integration_seek_alignment_test checks the pictures.
// See docs/reports/issue-169-mpeg-seek.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

Map<String, dynamic> _dvbtProbe() => jsonDecode(
        File('../Tests/TestResources/seek_probe_dvbt.json').readAsStringSync())
    as Map<String, dynamic>;

Map<String, dynamic> _probe(String format, String start, List<List<String>> packets) => {
      'packets': [
        for (final p in packets) {'pts_time': p[0], 'dts_time': p[1], 'flags': p[2]},
      ],
      'format': {'format_name': format, 'start_time': start},
    };

String _rust() => File('../worker/src/source_decode.rs').readAsStringSync();

void main() {
  group('the plan (twin of source_decode::seek_plan_from_probe)', () {
    test('the DVB-T clip: one GOP plus reorder plus margin', () {
      // Keyframes every 1.12 s, PTS up to 0.2 s after DTS, the container (the
      // audio) from 1.4 s. The worker's test reads the same file.
      final plan = FieldOrderDetector.seekPlanFromProbe(_dvbtProbe())!;
      expect(plan.preroll, closeTo(1.12 + 0.2 + 0.5, 1e-6));
      expect(plan.containerStart, closeTo(1.4, 1e-9));
    });

    test('only MPEG-TS and MPEG-PS get one', () {
      final pk = [
        ['0.0', '0.0', 'K__'],
        ['0.48', '0.48', 'K__'],
      ];
      for (final f in ['mpegts', 'mpeg']) {
        expect(FieldOrderDetector.seekPlanFromProbe(_probe(f, '0.5', pk)), isNotNull, reason: f);
      }
      for (final f in [
        'mov,mp4,m4a,3gp,3g2,mj2',
        'matroska,webm',
        'avi',
        'mpegvideo',
        'h264',
        'mpegtsraw',
      ]) {
        expect(FieldOrderDetector.seekPlanFromProbe(_probe(f, '0.0', pk)), isNull, reason: f);
      }
      expect(FieldOrderDetector.seekPlanFromProbe({}), isNull);
    });

    test('a floor, and the whole window when it holds one keyframe', () {
      final dvd = FieldOrderDetector.seekPlanFromProbe(_probe('mpeg', '0.53', [
        ['0.54', '0.54', 'K_'],
        ['0.58', '0.58', '__'],
        ['1.02', '1.02', 'K_'],
      ]))!;
      expect(dvd.preroll, FieldOrderDetector.seekPrerollMin);
      final one = FieldOrderDetector.seekPlanFromProbe(_probe('mpegts', '1.4', [
        ['1.5', '1.4', 'K_'],
        ['1.54', '1.44', '__'],
      ]))!;
      expect(one.preroll, closeTo(20 + 0.1 + 0.5, 1e-9));
      expect(FieldOrderDetector.seekPlanFromProbe(_probe('mpegts', 'N/A', []))!.containerStart, 0);
    });

    test('the app asks ffprobe exactly what the worker asks', () {
      final block = RegExp(r'SEEK_PROBE_ARGS: \[&str; \d+\] = \[([^\]]*)\]')
          .firstMatch(_rust())!
          .group(1)!;
      final args = RegExp(r'"([^"]*)"').allMatches(block).map((m) => m.group(1)).toList();
      expect(FieldOrderDetector.seekProbeArgs, args);
    });

    test('the same constants as the worker', () {
      final rust = _rust();
      double constant(String name) => double.parse(
          RegExp('pub const $name: [a-z0-9]+ = ([0-9.]+);').firstMatch(rust)!.group(1)!);
      expect(FieldOrderDetector.seekPrerollMargin, constant('SEEK_PREROLL_MARGIN'));
      expect(FieldOrderDetector.seekPrerollMin, constant('SEEK_PREROLL_MIN'));
      expect(FieldOrderDetector.seekProbeSeconds, constant('SEEK_PROBE_SECONDS'));
      final formats = RegExp(r'TIMESTAMP_SEARCH_FORMATS: \[&str; \d+\] = \[([^\]]*)\]')
          .firstMatch(rust)!
          .group(1)!;
      expect(FieldOrderDetector.timestampSearchFormats,
          RegExp(r'"([^"]*)"').allMatches(formats).map((m) => m.group(1)).toList());
    });
  });

  group('the before frame (twin of source_decode::decoder_seek)', () {
    const plan = SeekPlan(preroll: 1.82, containerStart: 1.4);

    List<String> before(int frame, {SeekPlan? seekPlan, String? tagFix, String? toneMap}) =>
        PreviewGenerator.beforeFrameArgs(
          videoPath: 'in.ts',
          frameIndex: frame,
          frameRate: 25,
          videoStartOffset: 1.2,
          seekPlan: seekPlan,
          tagFix: tagFix,
          toneMap: toneMap,
          outputPath: 'o.png',
        );

    String vf(List<String> args) => args[args.indexOf('-vf') + 1];

    test('no plan: exactly the arguments it always had', () {
      final args = before(40);
      expect(args.sublist(0, 3), ['-y', '-ss', (39.5 / 25 + 1.2).toStringAsFixed(6)]);
      expect(args, isNot(contains('-copyts')));
      expect(args, isNot(contains('-vf')));
    });

    test('a plan seeks a GOP early with -copyts and trims absolutely', () {
      final target = 39.5 / 25 + 1.2;
      final args = before(40, seekPlan: plan);
      final i = args.indexOf('-i');
      expect(args.indexOf('-copyts'), lessThan(i));
      expect(args[args.indexOf('-ss') + 1], (target - 1.82).toStringAsFixed(6));
      expect(args.indexOf('-ss'), lessThan(i));
      expect(vf(args), 'trim=start=${(1.4 + target).toStringAsFixed(6)}');
      // The same numbers the worker's builders produce: its test asserts
      // `-ss` = target - preroll and `trim=start=` container start + target.
    });

    test('within one preroll of the start: no -ss, still the trim', () {
      final args = before(2, seekPlan: plan);
      expect(args, isNot(contains('-ss')));
      expect(args, contains('-copyts'));
      expect(vf(args), 'trim=start=${(1.4 + 1.5 / 25 + 1.2).toStringAsFixed(6)}');
    });

    test('frame 0 never seeks or trims', () {
      final args = before(0, seekPlan: plan);
      expect(args, isNot(contains('-ss')));
      expect(args, isNot(contains('-copyts')));
      expect(args, isNot(contains('-vf')));
    });

    test('the tag fix first, the trim before the tone map, one -vf', () {
      final args = before(40, seekPlan: plan, tagFix: 'setparams=colorspace=unknown', toneMap: 'TONEMAP');
      expect(args.where((a) => a == '-vf'), hasLength(1));
      final chain = vf(args).split(',');
      expect(chain.first, 'setparams=colorspace=unknown');
      expect(chain[1], startsWith('trim=start='));
      expect(chain.last, 'TONEMAP');
    });
  });

  group('thumbnails', () {
    const plan = SeekPlan(preroll: 1.82, containerStart: 1.4);

    List<String> thumb(double time, {SeekPlan? seekPlan}) => PreviewGenerator.thumbnailArgs(
          videoPath: 'in.ts',
          time: time,
          videoStartOffset: 1.2,
          seekPlan: seekPlan,
          outputPath: 't.jpg',
        );

    test('no plan: unchanged', () {
      final args = thumb(3.0);
      expect(args.sublist(0, 3), ['-y', '-ss', '4.200']);
      expect(args, isNot(contains('-copyts')));
      expect(args[args.indexOf('-vf') + 1], 'scale=160:-1');
    });

    test('a plan: early seek, trim ahead of the scale', () {
      final args = thumb(3.0, seekPlan: plan);
      expect(args.sublist(0, 4), ['-y', '-copyts', '-ss', (4.2 - 1.82).toStringAsFixed(6)]);
      expect(args[args.indexOf('-vf') + 1],
          'trim=start=${(1.4 + 4.2).toStringAsFixed(6)},scale=160:-1');
    });
  });
}
