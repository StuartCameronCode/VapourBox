// The full plugin format probe against the committed table (task #48):
// every plugin call the template makes, at every reachable format, the
// documentation rows (4:1:1, 9 and 14-bit), and the frame-size axis up to
// 1080 lines. The push gate runs the quick subset
// (plugin_format_contracts_test.dart); this is the rest, nightly.
@Tags(['heavy'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/worker_harness.dart';

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  test('every plugin call refuses exactly what the table says, at every size', () async {
    final table = p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'plugin_format_table.json');
    final r = await Process.run(
      WorkerHarness.pythonPath,
      [
        p.join(WorkerHarness.repoRoot, 'Scripts', 'probe-plugin-formats.py'),
        '--check', table,
        '--ffmpeg', WorkerHarness.ffmpegPath,
      ],
      environment: {...WorkerHarness.workerEnv, 'VAPOURBOX_PLATFORM': WorkerHarness.platform},
    );
    expect(r.exitCode, 0,
        reason: 'the bundle disagrees with ${p.basename(table)} (see the probe\'s docstring for '
            'what to do):\n${r.stdout}\n${r.stderr}');
  }, timeout: const Timeout(Duration(hours: 2)));
}
