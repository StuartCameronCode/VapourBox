// MPEG-TS/PS seeks (issue #169): a TS or PS has no keyframe index, so a plain
// `-ss` starts decoding at the keyframe AFTER the frame asked for. Its decodes
// seek a GOP early with `-copyts` and trim to the frame instead. These pin the
// app's half (the before frame, the thumbnails) to the worker's
// (`source_decode::seek_plan_from_probe`, `decoder_seek`); the heavy
// integration_seek_alignment_test checks the pictures.
// See docs/reports/issue-169-mpeg-seek.
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

void main() {
  // The plan itself is the worker's (`seek_plan_from_probe`, in the source
  // model since task #50, tested there against seek_probe_dvbt.json).

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
