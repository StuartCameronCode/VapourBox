/// The harness prints the CPU feature set in its banner so a run states which
/// hardware it tested. That line degrades to "unknown" rather than throwing —
/// deliberately, since a diagnostic must never fail a run — which means a
/// broken probe would go unnoticed exactly when it matters. This pins it.
///
/// Why it matters: bundled plugins select a kernel from these bits, and
/// GitHub's hosted Windows fleet is mixed for AVX-512. `ctmf.CTMF`'s AVX-512
/// kernel for 8-bit input crashes the process, so a green Windows run means
/// nothing about that path unless the run says which hardware it drew.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/worker_harness.dart';

void main() {
  setUpAll(() async => WorkerHarness.ensureReady());

  test('the worker reports a CPU feature set the harness can read', () async {
    final described = await WorkerHarness.describeCpu();

    expect(
      described,
      isNot(startsWith('unknown')),
      reason: 'the probe degrades silently, so a broken --probe-cpu would '
          'otherwise leave every run claiming unknown hardware',
    );
    // "<arch> [<feature> <feature> ...]"
    expect(described, matches(RegExp(r'^\S+ \[.+\]$')));

    if (Platform.version.contains('x64') ||
        described.startsWith('x86_64') ||
        described.startsWith('x86')) {
      // SSE2 is part of the x86-64 baseline, so its absence means the probe is
      // reporting nothing rather than reporting a modest CPU.
      expect(described, contains('sse2'));
    }
  });
}
