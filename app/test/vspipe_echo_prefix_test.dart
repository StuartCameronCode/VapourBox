// The preview echoes vspipe's stderr lines as they arrive (task #122), and
// the app leaves them out of a failed preview's error text. The prefix is
// a twin of the worker's `VSPIPE_ECHO_PREFIX`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/services/preview_generator.dart';

void main() {
  test('the echo prefix matches the worker', () {
    final repo = Directory.current.path.endsWith('app')
        ? Directory.current.parent.path
        : Directory.current.path;
    final rust = File(p.join(repo, 'worker', 'src', 'pipeline_executor.rs'))
        .readAsStringSync();
    final m = RegExp(r'pub const VSPIPE_ECHO_PREFIX: &str = "([^"]*)";')
        .firstMatch(rust);
    expect(m, isNotNull, reason: 'VSPIPE_ECHO_PREFIX not found in the worker');
    expect(vspipeEchoPrefix, m!.group(1));
  });

  test('a failed preview\'s error leaves out the echoed vspipe lines', () {
    const stderr = 'Generated preview script\r\n'
        'vspipe: +   312 ms Script evaluation failed:\n'
        'vspipe: +   312 ms Python exception: boom\n'
        'Error: The VapourSynth script failed: boom\n';
    final text = previewErrorText(stderr.replaceAll('\r\n', '\n'));
    expect(text, isNot(contains('vspipe: +')));
    expect(text, contains('Generated preview script'));
    expect(text, contains('The VapourSynth script failed: boom'));
  });
}
