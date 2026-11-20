// The full plugin format probe against the committed table (task #48):
// every plugin call the template makes, at every reachable format, the
// documentation rows (4:1:1, 9 and 14-bit), and the frame-size axis up to
// 1080 lines. The push gate runs the quick subset
// (plugin_format_contracts_test.dart); this is the rest, nightly. Both print
// each call's time as it finishes (support/plugin_probe_runner.dart).
@Tags(['heavy'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/plugin_probe_runner.dart';
import 'support/worker_harness.dart';

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  // macOS arm64 took 59 min (nightly 44342418084). macOS x64 never finished
  // before task #75: its LUTDeCrawl child alone passed an hour. The probe
  // stops itself 90 s before this (--budget) and says which calls were still
  // running.
  const fullTimeout = Duration(hours: 2);
  test('every plugin call refuses exactly what the table says, at every size', () async {
    final table = p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'plugin_format_table.json');
    final r = await runPluginProbe(['--check', table], timeout: fullTimeout);
    expect(r.exitCode, 0,
        reason: 'the bundle disagrees with ${p.basename(table)} (see the probe\'s docstring for '
            'what to do; exit 3 is --budget, exit 2 a call that did not finish):\n${r.report}');
  }, timeout: const Timeout(fullTimeout));
}
