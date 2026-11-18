// The heavy tests report a failed preview by PreviewResult.errorTail. It must
// keep the worker's own error line, which carries vspipe's exit status, even
// when more than four lines follow it (task #65: the nightly showed only
// plugin warnings and vspipe's frame count).
import 'package:flutter_test/flutter_test.dart';

import 'support/worker_harness.dart';

void main() {
  const status = 'Error generating preview: vspipe exited with signal 11 '
      '(SIGSEGV) — a native crash; no Python error was printed';

  test('keeps the worker error line when it has scrolled out of the tail', () {
    final logs = [
      status,
      'Core freed but 3 filter instances still exist',
      'Plugin already loaded (com.vapoursynth.a)',
      'Plugin already loaded (com.vapoursynth.b)',
      'Plugin already loaded (com.vapoursynth.c)',
      'Output 1 frames in 0.00 seconds (1000.00 fps)',
    ].join('\n');
    final tail = previewErrorTail(logs, 'preview exited with 1');
    expect(tail, startsWith(status));
    expect(tail, endsWith('Output 1 frames in 0.00 seconds (1000.00 fps)'));
    expect(tail, isNot(contains('Core freed')));
  });

  test('does not repeat a worker error line already in the tail', () {
    final logs = ['warning', status, 'Traceback line'].join('\n');
    expect(previewErrorTail(logs, null), 'warning | $status | Traceback line');
  });

  test('without the worker line, the last four lines', () {
    final logs = List.generate(6, (i) => 'line $i').join('\n');
    expect(previewErrorTail(logs, null), 'line 2 | line 3 | line 4 | line 5');
  });

  test('no logs: the error', () {
    expect(previewErrorTail('\n  \n', 'timed out'), 'timed out');
  });
}
