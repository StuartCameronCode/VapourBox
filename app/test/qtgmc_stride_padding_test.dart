// QTGMC's picture does not depend on frame stride padding (task #70).
//
// VapourSynth leaves the bytes between a row's last sample and the next row
// uninitialised. memcheck flagged QTGMC's output at an odd chroma width and
// > 8 bits (722x480 4:2:0 12-bit) as uninitialised on x86 Linux. Task #70
// found that to be memcheck's model of `vpmaddwd` in VapourSynth's own AVX2
// std.Merge kernel, which reads padding into lanes it then discards
// (docs/reports/task-70-odd-chroma-width-memcheck). This keeps the real
// question answered on every CI platform: the report's poison.py fills the
// padding of every frame havsfunc's `core.<ns>.<fn>` calls produce with a
// pattern per seed and hashes QTGMC's visible output. Different seeds must give
// the same picture; the poisoned padding itself (read back from one
// mv.Degrain1 frame) must differ, or the harness poisoned nothing.
// It fails the day an MVTools or VapourSynth update lets padding reach the
// picture at these sizes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/worker_harness.dart';

const _cases = [
  // A real size whose 4:2:0 chroma width (361) is odd.
  ['Draft', '722x480', 'YUV420P12'],
  // task #66's sizes: chroma width 49.
  ['Draft', '98x96', 'YUV420P12'],
  ['Slower', '98x96', 'YUV420P12'],
  ['Slower', '98x96', 'YUV422P16'],
];

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  final script = p.join(WorkerHarness.repoRoot, 'docs', 'reports',
      'task-70-odd-chroma-width-memcheck', 'scripts', 'poison.py');

  for (final c in _cases) {
    test('QTGMC ${c[0]} ${c[1]} ${c[2]}: the picture ignores stride padding', () async {
      final r = await Process.run(
        WorkerHarness.pythonPath,
        [script, ...c, '1', '2'],
        environment: WorkerHarness.workerEnv,
      );
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      final out = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
      final hashes = (out['hashes'] as Map).values.toSet();
      final controls = (out['control'] as Map).values.toSet();
      // ignore: avoid_print
      print('  ${out['case']}: ${hashes.length} picture(s) from 2 seeds, '
          '${out['proxied']} calls poisoned, ${out['seconds']} s');
      expect(controls.length, 2,
          reason: 'the poisoned padding of an mv.Degrain1 frame is the same for both seeds: '
              'the harness is not reaching the frames ($out)');
      expect(out['proxied'] as int, greaterThan(0), reason: 'no QTGMC call went through the proxy');
      expect(hashes.length, 1,
          reason: 'QTGMC ${c.join(' ')} gives a different picture when only the stride padding '
              'differs: a filter reads padding into visible samples (task #70)');
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
