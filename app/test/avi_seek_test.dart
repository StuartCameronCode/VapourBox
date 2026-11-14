// AVI seeks (issue #173). An AVI stores decode-order timestamps only, and its
// tick is one frame, so the plain `(N - 0.5) / fps` seek landed early three
// ways: the decoder delay (MPEG-2/MPEG-4/H.264 stamp each picture 1-2 frames
// late), a half-tick rounding tie on every NTSC-rate AVI, and no seek at all
// for frames 1-3 of a delayed one. These pin the app's half (the before frame,
// the thumbnails) to the worker's (`source_decode::source_seek`, `seek_arg`,
// `decoder_delay_from_probe`); the heavy integration_seek_alignment_test checks
// the pictures. See docs/reports/issue-173-avi-seek.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

Map<String, dynamic> _resource(String name) =>
    jsonDecode(File('../Tests/TestResources/$name').readAsStringSync())
        as Map<String, dynamic>;

String _rust() => File('../worker/src/source_decode.rs').readAsStringSync();

void main() {
  group('the decoder delay (twin of source_decode::decoder_delay_from_probe)', () {
    test('the probe arguments are the worker\'s, word for word', () {
      final rust = _rust();
      final start = rust.indexOf('pub const DECODER_DELAY_PROBE_ARGS');
      final body = rust.substring(start, rust.indexOf('];', start));
      final words = RegExp(r'"([^"]*)"').allMatches(body).map((m) => m.group(1)).toList();
      expect(words, FieldOrderDetector.decoderDelayProbeArgs);
      expect(rust, contains('pub const MAX_DECODER_DELAY: u32 = ${FieldOrderDetector.maxDecoderDelay};'));
      expect(rust, contains('pub const COUNT_SEEK_BELOW: f64 = ${SeekPlan.countSeekBelow};'));
    });

    test('decode-order storage is recognised from the packet probe', () {
      expect(FieldOrderDetector.storesDecodeOrder(_resource('video_start_probe_avi.json')), isTrue);
      expect(FieldOrderDetector.storesDecodeOrder(_resource('video_start_probe_dvbt.json')), isFalse);
      expect(FieldOrderDetector.storesDecodeOrder({}), isFalse);
    });

    test('the MPEG-2 AVI fixture is one frame late', () {
      final probe = _resource('decoder_delay_probe_avi.json');
      expect(FieldOrderDetector.decoderDelayFromProbe(probe, 0), 1);
      expect(FieldOrderDetector.decoderDelayFromProbe(probe, 0.033367), 0);
    });

    test('implausible delays are ignored', () {
      Map<String, dynamic> probe(String first, String rate) => {
            'frames': [
              {'best_effort_timestamp_time': first}
            ],
            'streams': [
              {'r_frame_rate': rate}
            ],
            'format': {'start_time': '0.000000'},
          };
      expect(FieldOrderDetector.decoderDelayFromProbe(probe('0.066733', '30000/1001'), 0), 2);
      expect(FieldOrderDetector.decoderDelayFromProbe(probe('0.000000', '30000/1001'), 0), 0);
      expect(FieldOrderDetector.decoderDelayFromProbe(probe('0.200000', '25/1'), 0), 0);
      expect(FieldOrderDetector.decoderDelayFromProbe(probe('0.040000', '0/0'), 0), 0);
      expect(FieldOrderDetector.decoderDelayFromProbe({'frames': []}, 0), 0);
    });
  });

  group('the seek (twin of source_decode::source_seek)', () {
    test('matches the shared table', () {
      final cases = _resource('seek_arg_cases.json')['cases'] as List<dynamic>;
      expect(cases.length, greaterThan(20));
      for (final c in cases.cast<Map<String, dynamic>>()) {
        final seek = SeekPlan.frameSeekArgs(
          frame: c['frame'] as int,
          frameRate: (c['fpsNum'] as int) / (c['fpsDen'] as int),
          videoStartOffset: (c['videoStart'] as num).toDouble(),
          decoderDelayFrames: c['delay'] as int,
        );
        final ss = c['ss'] as String?;
        final trimFrames = c['trimFrames'] as int?;
        if (ss == null && trimFrames == null) {
          expect(seek, isNull, reason: '$c');
        } else if (trimFrames != null) {
          expect(seek!.input, isEmpty, reason: '$c');
          expect(seek.trim, 'trim=start_frame=$trimFrames', reason: '$c');
        } else {
          expect(seek!.input, ['-ss', ss], reason: '$c');
          expect(seek.trim, isNull, reason: '$c');
        }
      }
    });

    test('seek values round up to the microsecond', () {
      // Frame 43 at 30000/1001: 1.4180833.. s printed 1.418083, below the
      // half tick, and the decode began at frame 42.
      const t = (43 - 0.5) / (30000 / 1001);
      expect(t.toStringAsFixed(6), '1.418083');
      expect(SeekPlan.formatSeek(t), '1.418084');
      expect(SeekPlan.formatSeek(0.38), '0.380000');
      expect(SeekPlan.formatSeek(1.58 + 1.202022), '2.782022');
    });

    test('a seek plan takes no decoder delay', () {
      const plan = SeekPlan(preroll: 1.82, containerStart: 1.4);
      final withDelay = SeekPlan.frameSeekArgs(
          frame: 40, frameRate: 25, videoStartOffset: 1.2, decoderDelayFrames: 1, plan: plan)!;
      final without = SeekPlan.frameSeekArgs(
          frame: 40, frameRate: 25, videoStartOffset: 1.2, plan: plan)!;
      expect(withDelay.input, without.input);
      expect(withDelay.trim, without.trim);
    });
  });

  group('the before frame', () {
    List<String> before(int frame, {int delay = 0, String? tagFix}) =>
        PreviewGenerator.beforeFrameArgs(
          videoPath: 'in.avi',
          frameIndex: frame,
          frameRate: 30000 / 1001,
          tagFix: tagFix,
          decoderDelayFrames: delay,
          outputPath: 'f.png',
        );

    test('near a delayed AVI\'s start: no seek, drop by count', () {
      final args = before(2, delay: 1, tagFix: 'setparams=colorspace=unknown');
      expect(args, isNot(contains('-ss')));
      expect(args[args.indexOf('-vf') + 1], 'setparams=colorspace=unknown,trim=start_frame=2');
    });

    test('past it: the delay is added', () {
      final args = before(41, delay: 1);
      expect(args.sublist(0, 3), ['-y', '-ss', '1.384717']);
      expect(args, isNot(contains('-vf')));
    });

    test('no delay: the plain seek, rounded up', () {
      expect(before(43).sublist(0, 3), ['-y', '-ss', '1.418084']);
      expect(before(0), isNot(contains('-ss')));
    });
  });

  group('thumbnails', () {
    List<String> thumb(double time, {int delay = 0}) => PreviewGenerator.thumbnailArgs(
          videoPath: 'in.avi',
          time: time,
          frameRate: 30000 / 1001,
          decoderDelayFrames: delay,
          outputPath: 't.jpg',
        );

    test('the first never seeks (a delayed AVI cannot seek there)', () {
      expect(thumb(0), isNot(contains('-ss')));
      expect(thumb(0, delay: 1), isNot(contains('-ss')));
    });

    test('a delayed AVI: by count near the start, the delay added after', () {
      final early = thumb(0.2, delay: 1);
      expect(early, isNot(contains('-ss')));
      expect(early[early.indexOf('-vf') + 1], 'trim=start_frame=6,scale=160:-1');
      final later = thumb(2.0, delay: 1);
      expect(later.sublist(0, 3), ['-y', '-ss', SeekPlan.formatSeek(2.0 + 1001 / 30000)]);
    });

    test('no delay: unchanged', () {
      expect(thumb(2.0).sublist(0, 3), ['-y', '-ss', '2.000']);
    });
  });
}
