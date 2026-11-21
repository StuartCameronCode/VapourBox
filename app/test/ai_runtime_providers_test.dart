// Which ONNX Runtime execution providers `ai_runtime.preferred_providers()`
// offers, per machine (task #94). Intel Macs are never offered Core ML: there
// it runs on the GPU through Metal Performance Shaders, which can abort the
// whole vspipe process while compiling a model's kernels (SIGABRT in
// MPSLibrary, seen in 6 of 12 macOS x64 nightly heavy jobs in four days), and
// no Python exception reaches the CPU retry. This runs the helper under the
// bundle's Python with onnxruntime replaced by a stub that offers Core ML and
// the CPU, and the platform patched, so it needs no add-on and runs on every
// platform. integration_ai_runtime_test.dart (heavy) checks the real probe.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/worker_harness.dart';

const _script = r'''
import json, os, platform, sys, types
sys.path.insert(0, sys.argv[1])
import ai_runtime

stub = types.SimpleNamespace(
    get_available_providers=lambda: ["CoreMLExecutionProvider", "CPUExecutionProvider"])
ai_runtime._ort = stub

CASES = {
    "intelMac": ("darwin", "x86_64", {}),
    "appleSilicon": ("darwin", "arm64", {}),
    "intelMacOverride": ("darwin", "x86_64", {"VAPOURBOX_AI_COREML_ON_INTEL": "1"}),
    "intelMacForceCpu": ("darwin", "x86_64", {"VAPOURBOX_AI_FORCE_CPU": "1"}),
    "appleSiliconForceCpu": ("darwin", "arm64", {"VAPOURBOX_AI_FORCE_CPU": "1"}),
    "linuxX64": ("linux", "x86_64", {}),
}

out = {}
for name, (plat, machine, env) in CASES.items():
    for k in ("VAPOURBOX_AI_COREML_ON_INTEL", "VAPOURBOX_AI_FORCE_CPU"):
        os.environ.pop(k, None)
    os.environ.update(env)
    sys.platform = plat
    platform.machine = lambda m=machine: m
    out[name] = {
        "providers": ai_runtime.preferred_providers(),
        "forced": ai_runtime.preferred_providers(force_cpu=True),
        "cpuReason": ai_runtime.cpu_reason(),
    }
print(json.dumps(out))
''';

void main() {
  late Map<String, dynamic> out;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    final script = File(p.join(Directory.systemTemp.path, 'vb_ai_providers_$pid.py'));
    await script.writeAsString(_script);
    try {
      final r = await Process.run(
        WorkerHarness.pythonPath,
        [script.path, p.join(WorkerHarness.repoRoot, 'worker', 'templates')],
        environment: WorkerHarness.workerEnv,
      );
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      out = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
    } finally {
      if (script.existsSync()) script.deleteSync();
    }
  });

  const coreMl = 'CoreMLExecutionProvider', cpu = 'CPUExecutionProvider';

  test('an Intel Mac runs on the CPU and says why (task #94)', () {
    expect(out['intelMac']['providers'], [cpu]);
    expect(out['intelMac']['cpuReason'], allOf(contains('Intel Macs'), contains('task #94')));
  });

  test('Apple Silicon keeps Core ML, with no reason given', () {
    expect(out['appleSilicon']['providers'], [coreMl, cpu]);
    expect(out['appleSilicon']['cpuReason'], isNull);
    expect(out['linuxX64']['cpuReason'], isNull);
  });

  test('VAPOURBOX_AI_COREML_ON_INTEL=1 offers Core ML on an Intel Mac again (for measuring)', () {
    expect(out['intelMacOverride']['providers'], [coreMl, cpu]);
    expect(out['intelMacOverride']['cpuReason'], isNull);
  });

  test('VAPOURBOX_AI_FORCE_CPU and force_cpu still mean the CPU everywhere', () {
    expect(out['intelMacForceCpu']['providers'], [cpu]);
    expect(out['appleSiliconForceCpu']['providers'], [cpu]);
    for (final c in out.values) {
      expect((c as Map)['forced'], [cpu]);
    }
  });
}
