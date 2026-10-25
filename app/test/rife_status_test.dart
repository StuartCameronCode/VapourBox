// RIFE's status as the app reads it from `--probe-rife`, and the Frame Rate
// panel's decision about what to say. Pure unit tests; the probe itself is
// exercised against the real worker in integration_rife_test.dart.
import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/rife_status.dart';

void main() {
  group('RifeStatus.fromJson', () {
    test('available', () {
      final s = RifeStatus.fromJson({'available': true});
      expect(s.available, isTrue);
      expect(s.message, isNull);
    });

    test('unavailable carries the worker message verbatim', () {
      final s = RifeStatus.fromJson({
        'available': false,
        'reason': 'missingLibrary',
        'detail': 'could not load vcomp140.dll',
        'message': 'RIFE needs the Microsoft Visual C++ Redistributable (x64)…',
      });
      expect(s.available, isFalse);
      expect(s.reason, 'missingLibrary');
      expect(s.message, startsWith('RIFE needs the Microsoft Visual C++'));
    });

    test('an unavailable answer without a message is never shown as blank', () {
      final s = RifeStatus.fromJson({'available': false, 'reason': 'noVulkan'});
      expect(s.available, isFalse);
      expect(s.message, isNotEmpty);
    });
  });

  group('rifeNoticeFor', () {
    const ok = RifeStatus(available: true);
    const no = RifeStatus(available: false, reason: 'noVulkan', message: 'no GPU');

    test('says nothing unless RIFE is the chosen method', () {
      for (final method in ['flowFps', 'duplicate', null]) {
        for (final status in [ok, no, null]) {
          expect(rifeNoticeFor(method: method, status: status, checking: false),
              RifeNotice.none, reason: '$method / $status');
        }
      }
    });

    test('RIFE selected: checking, then unavailable or silent', () {
      expect(rifeNoticeFor(method: 'rife', status: null, checking: false),
          RifeNotice.checking);
      expect(rifeNoticeFor(method: 'rife', status: no, checking: true),
          RifeNotice.checking);
      expect(rifeNoticeFor(method: 'rife', status: no, checking: false),
          RifeNotice.unavailable);
      expect(rifeNoticeFor(method: 'rife', status: ok, checking: false),
          RifeNotice.none);
    });
  });

  test('the converter round-trips every Frame Rate method', () {
    for (final method in FrameRateMethod.values) {
      final params = FrameRateParameters(enabled: true, method: method);
      final dynamic = ParameterConverter.fromFrameRate(params);
      expect(dynamic.values['method'], method.name);
      expect(ParameterConverter.toFrameRate(dynamic).method, method);
    }
    // An unknown id from an old or hand-edited preset falls back to FlowFPS.
    final unknown = const DynamicParameters(
        filterId: 'frame_rate', enabled: true, values: {'method': 'bogus'});
    expect(ParameterConverter.toFrameRate(unknown).method, FrameRateMethod.flowFps);
  });
}
