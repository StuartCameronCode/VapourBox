// Colour tags FFmpeg's scaler refuses (ProRes's `reserved`) are cleared before
// the app's own decodes convert a frame; see ColorTags.decodeNeutraliser and
// its twin, decode_tag_neutraliser in worker/src/models/color_metadata.rs.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/models/color_tags.dart';
import 'package:vapourbox/models/hdr_display.dart';
import 'package:vapourbox/services/preview_generator.dart';

String _repoFile(String rel) => File(p.join(
        Directory.current.path.endsWith('app')
            ? Directory.current.parent.path
            : Directory.current.path,
        rel))
    .readAsStringSync()
    .replaceAll('\r\n', '\n');

/// The `&str` entries of one `const NAME: &[&str] = &[ … ];` in Rust source.
List<String> _rustList(String src, String name) {
  final start = src.indexOf('const $name: &[&str] = &[');
  expect(start, isNot(-1), reason: '$name not found in color_metadata.rs');
  final body = src.substring(start, src.indexOf('];', start));
  return RegExp(r'"([^"]*)"')
      .allMatches(body.substring(body.indexOf('&[') + 2))
      .map((m) => m.group(1)!)
      .toList();
}

void main() {
  group('ColorTags lists', () {
    final rust = _repoFile('worker/src/models/color_metadata.rs');
    test('are the worker\'s, value for value', () {
      expect(ColorTags.matrices, _rustList(rust, 'MATRICES'));
      expect(ColorTags.scalerMatrices, _rustList(rust, 'SCALER_MATRICES'));
      expect(ColorTags.primaries, _rustList(rust, 'PRIMARIES'));
      expect(ColorTags.transfers, _rustList(rust, 'TRANSFERS'));
    });
  });

  group('decodeNeutraliser', () {
    String? n(String? m, String? pr, String? t) =>
        ColorTags.decodeNeutraliser(matrix: m, primaries: pr, transfer: t);

    // The shared table: the Rust test `decode_tag_neutraliser_matches_the_
    // shared_table` checks the same rows against the worker.
    test('matches the shared case table', () {
      final table = jsonDecode(_repoFile(
              'Tests/TestResources/decode_neutraliser_cases.json'))
          as Map<String, dynamic>;
      final cases = (table['cases'] as List).cast<Map<String, dynamic>>();
      expect(cases.length, greaterThan(25));
      for (final c in cases) {
        expect(
          n(c['matrix'] as String?, c['primaries'] as String?,
              c['transfer'] as String?),
          c['filter'] as String?,
          reason: '$c',
        );
      }
    });

    test('never touches a tag the scaler converts', () {
      for (final m in [...ColorTags.scalerMatrices, 'gbr']) {
        for (final pr in [...ColorTags.primaries, null]) {
          expect(n(m, pr, null), isNull, reason: '$m/$pr');
        }
      }
      for (final t in ColorTags.transfers) {
        expect(n(null, null, t), isNull, reason: t);
      }
    });

    // Task #76: every other valid matrix stands in as the preview reads it.
    test('replaces a matrix the scaler cannot convert by its stand-in', () {
      for (final m in ColorTags.matrices) {
        for (final pr in [...ColorTags.primaries, null]) {
          final s = ColorTags.scalerStandIn(m, pr);
          if (ColorTags.scalerMatrices.contains(m)) {
            expect(s, isNull, reason: m);
            continue;
          }
          expect(s == 'unknown' || ColorTags.scalerMatrices.contains(s), isTrue,
              reason: '$m/$pr: $s');
          expect(n(m, pr, null), 'setparams=colorspace=$s', reason: '$m/$pr');
        }
      }
    });
  });

  group('PreviewGenerator arguments', () {
    const fix = 'setparams=color_primaries=unknown:color_trc=unknown';
    List<String> vfOf(List<String> args) {
      expect(args.where((a) => a == '-vf').length, 1);
      return args[args.indexOf('-vf') + 1].split(',');
    }

    test('before frame: clean tags change nothing', () {
      final args = PreviewGenerator.beforeFrameArgs(
          videoPath: 'in.mov', frameIndex: 10, frameRate: 25, outputPath: 'o.jpg');
      expect(args, [
        '-y', '-ss', '0.380000', '-apply_cropping', 'codec', '-i', 'in.mov',
        '-frames:v', '1', '-q:v', '2', 'o.jpg',
      ]);
    });

    test('before frame: the fix is the whole -vf, after -i', () {
      final args = PreviewGenerator.beforeFrameArgs(
          videoPath: 'in.mov', frameIndex: 0, frameRate: 25, tagFix: fix,
          outputPath: 'o.jpg');
      expect(vfOf(args), [fix]);
      expect(args.indexOf('-vf'), greaterThan(args.indexOf('-i')));
    });

    test('before frame: the fix precedes the HDR tone map', () {
      // Dolby Vision profile 5: PQ transfer, ipt-c2 matrix.
      final toneMap = HdrDisplay.toneMapFilter(
          matrix: 'ipt-c2', primaries: 'bt2020', transfer: 'smpte2084')!;
      final tagFix = ColorTags.decodeNeutraliser(
          matrix: 'ipt-c2', primaries: 'bt2020', transfer: 'smpte2084');
      expect(tagFix, 'setparams=colorspace=unknown');
      final args = PreviewGenerator.beforeFrameArgs(
          videoPath: 'in.mov', frameIndex: 5, frameRate: 24, toneMap: toneMap,
          tagFix: tagFix, outputPath: 'o.jpg');
      expect(args[args.indexOf('-vf') + 1], '$tagFix,$toneMap');
    });

    test('thumbnail: the fix precedes scale, which converts', () {
      final plain = PreviewGenerator.thumbnailArgs(
          videoPath: 'in.mov', time: 1, outputPath: 't.jpg');
      expect(vfOf(plain), ['scale=160:-1']);
      final fixed = PreviewGenerator.thumbnailArgs(
          videoPath: 'in.mov', time: 1, tagFix: fix, outputPath: 't.jpg');
      expect(vfOf(fixed), [...fix.split(','), 'scale=160:-1']);
      final hdr = HdrDisplay.toneMapFilter(transfer: 'smpte2084')!;
      final both = PreviewGenerator.thumbnailArgs(
          videoPath: 'in.mov', time: 1, tagFix: fix, toneMap: hdr,
          outputPath: 't.jpg');
      expect(both[both.indexOf('-vf') + 1], '$fix,scale=160:-2,$hdr');
    });
  });
}
