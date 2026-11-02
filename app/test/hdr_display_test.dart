// HDR sources on an SDR screen, and Dolby Vision detection (issue #133).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/models/hdr_display.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/widgets/dynamic_range_badge.dart';

String _repoFile(String rel) => File(p.join(
        Directory.current.path.endsWith('app')
            ? Directory.current.parent.path
            : Directory.current.path,
        rel))
    .readAsStringSync();

/// ffprobe's stream side data for a Dolby Vision file.
Map<String, dynamic> _dvStream(int profile, int compatibilityId) => {
      'side_data_list': [
        {
          'side_data_type': 'DOVI configuration record',
          'dv_version_major': 1,
          'dv_version_minor': 0,
          'dv_profile': profile,
          'dv_level': 6,
          'dv_bl_signal_compatibility_id': compatibilityId,
        },
        {
          'side_data_type': 'Mastering display metadata',
          'max_luminance': '10000000/10000',
        },
      ],
    };

VideoInfo _info({String? transfer, DolbyVisionInfo? dolbyVision}) => VideoInfo(
      width: 3840,
      height: 2160,
      frameRate: 24,
      duration: 1,
      frameCount: 24,
      codec: 'hevc',
      pixelFormat: 'yuv420p10le',
      hasAudio: false,
      colorTransfer: transfer,
      dolbyVision: dolbyVision,
    );

void main() {
  group('toneMapFilter', () {
    test('is the worker\'s chain, character for character', () {
      // Same input and expected string as the Rust test
      // `hdr10_tone_map_chain` in worker/src/models/color_metadata.rs.
      expect(
        HdrDisplay.toneMapFilter(
          matrix: 'bt2020nc',
          primaries: 'bt2020',
          transfer: 'smpte2084',
          range: 'tv',
        ),
        'setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084:range=tv,'
        'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
        'tonemap=tonemap=hable:desat=0,zscale=t=bt709:r=full,'
        'format=rgb24,setparams=colorspace=gbr',
      );
    });

    test('matches the format string in the worker source', () {
      // The test above only proves this side. Read the worker's own
      // format! string and fill it the same way, so a change on either side
      // alone fails here rather than as a before/after colour mismatch.
      // A Windows checkout gives the file CRLF; the patterns below span
      // line breaks.
      final src = _repoFile('worker/src/models/color_metadata.rs')
          .replaceAll('\r\n', '\n');
      final fn = src.substring(src.indexOf('pub fn display_tonemap_filter'));
      final start = fn.indexOf('format!(\n') + 'format!(\n'.length;
      final literal = fn.substring(fn.indexOf('"', start) + 1, fn.indexOf('"\n', start));
      final rust = literal.replaceAll(RegExp(r'\\\r?\n\s*'), '');
      for (final (m, pr, t, r) in [
        ('bt2020nc', 'bt2020', 'smpte2084', 'tv'),
        ('bt709', 'smpte432', 'arib-std-b67', 'pc'),
      ]) {
        final filled = rust
            .replaceAll('{matrix}', m)
            .replaceAll('{primaries}', pr)
            .replaceAll('{transfer}', t)
            .replaceAll('{range}', r);
        expect(
          HdrDisplay.toneMapFilter(matrix: m, primaries: pr, transfer: t, range: r),
          filled,
        );
      }
    });

    test('SDR sources are left alone', () {
      for (final t in [null, 'bt709', 'smpte170m', 'bt2020-10']) {
        expect(HdrDisplay.toneMapFilter(transfer: t), isNull, reason: '$t');
      }
    });

    test('untagged or unusable matrix and primaries read as BT.2020', () {
      expect(
        HdrDisplay.toneMapFilter(matrix: 'smpte2085', transfer: 'smpte2084', range: 'jpeg'),
        startsWith('setparams=colorspace=bt2020nc:color_primaries=bt2020:'
            'color_trc=smpte2084:range=pc,'),
      );
    });
  });

  group('Dolby Vision', () {
    test('Profile 8.1 is HDR10 underneath', () {
      final dv = DolbyVisionInfo.fromStream(_dvStream(8, 1))!;
      expect(dv.label, 'Dolby Vision 8.1');
      expect(dv.baseLayerIsUndecodable, isFalse);
    });

    test('Profile 5 cannot be decoded without the RPU', () {
      final dv = DolbyVisionInfo.fromStream(_dvStream(5, 0))!;
      expect(dv.label, 'Dolby Vision 5');
      expect(dv.baseLayerIsUndecodable, isTrue);
    });

    test('a stream without the record is not Dolby Vision', () {
      expect(DolbyVisionInfo.fromStream({}), isNull);
      expect(DolbyVisionInfo.fromStream({'side_data_list': []}), isNull);
    });
  });

  group('dynamicRangeLabel', () {
    test('names the range, Dolby Vision first', () {
      expect(_info().dynamicRangeLabel, isNull);
      expect(_info(transfer: 'bt709').dynamicRangeLabel, isNull);
      expect(_info(transfer: 'smpte2084').dynamicRangeLabel, 'HDR10');
      expect(_info(transfer: 'arib-std-b67').dynamicRangeLabel, 'HLG');
      expect(
        _info(
          transfer: 'smpte2084',
          dolbyVision: const DolbyVisionInfo(profile: 8, compatibilityId: 1),
        ).dynamicRangeLabel,
        'Dolby Vision 8.1',
      );
    });
  });

  group('DynamicRangeBadge', () {
    Future<void> pump(WidgetTester tester, VideoInfo info) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: DynamicRangeBadge(info: info))),
        );

    test('is not shown for SDR', () {
      expect(DynamicRangeBadge.shows(_info(transfer: 'bt709')), isFalse);
      expect(DynamicRangeBadge.shows(_info(transfer: 'smpte2084')), isTrue);
    });

    testWidgets('Profile 8.1 is a plain label', (tester) async {
      await pump(
        tester,
        _info(
          transfer: 'smpte2084',
          dolbyVision: const DolbyVisionInfo(profile: 8, compatibilityId: 1),
        ),
      );
      expect(find.text('Dolby Vision 8.1'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('Profile 5 is a warning that says why', (tester) async {
      final info = _info(
        transfer: 'smpte2084',
        dolbyVision: const DolbyVisionInfo(profile: 5, compatibilityId: 0),
      );
      await pump(tester, info);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.textContaining('colours unsupported'), findsOneWidget);
      expect(DynamicRangeBadge.explanation(info), contains('pink and green'));
    });
  });
}
