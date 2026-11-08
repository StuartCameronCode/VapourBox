// The AI runtime add-on for real: install it from its pinned PyPI wheels with
// the app's own installer (WorkerHarness.ensureAddon), then run the worker's
// --probe-ai-runtime, which imports ONNX Runtime the way a job does
// (templates/ai_runtime.py) and runs the committed self-test model directly
// and through a VapourSynth frame. Fails if a pinned URL or hash stops
// holding, or if the wheels don't load into the bundled Python.
@Tags(['heavy'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/models/ai_runtime_status.dart';
import 'package:vapourbox/services/manifest_addon.dart';

import 'support/worker_harness.dart';

Future<AiRuntimeStatus> _probe({Map<String, String> env = const {}}) async {
  final result = await Process.run(WorkerHarness.workerPath, ['--probe-ai-runtime'],
      environment: {...WorkerHarness.workerEnv, ...env});
  expect(result.exitCode, 0, reason: '${result.stderr}');
  final line = const LineSplitter()
      .convert(result.stdout as String)
      .lastWhere((l) => l.trim().startsWith('{'));
  // ignore: avoid_print
  print('probe: $line');
  return AiRuntimeStatus.fromJson(jsonDecode(line) as Map<String, dynamic>);
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  test('installs from its pinned wheels and runs the self-test model', () async {
    final dir = await WorkerHarness.ensureAddon('ai-runtime');
    expect(File(p.join(dir.path, ManifestAddonInstaller.markerName)).existsSync(), isTrue);
    expect(Directory(p.join(dir.path, 'site-packages', 'onnxruntime')).existsSync(), isTrue);
    expect(Directory(p.join(dir.path, 'site-packages', 'numpy')).existsSync(), isTrue);

    final status = await _probe();
    expect(status.available, isTrue, reason: status.message);
    expect(status.version, isNotNull);
    expect(status.providers, contains('CPUExecutionProvider'));
    final expected = switch (WorkerHarness.platform) {
      'macos-arm64' || 'macos-x64' => {'CoreMLExecutionProvider', 'CPUExecutionProvider'},
      'windows-x64' => {'DmlExecutionProvider', 'CPUExecutionProvider'},
      _ => {'CPUExecutionProvider'},
    };
    expect(expected, contains(status.provider));
    if (WorkerHarness.platform.startsWith('macos')) {
      expect(status.providers, contains('CoreMLExecutionProvider'));
    }
  });

  test('VAPOURBOX_AI_FORCE_CPU runs it on the CPU', () async {
    await WorkerHarness.ensureAddon('ai-runtime');
    final status = await _probe(env: {'VAPOURBOX_AI_FORCE_CPU': '1'});
    expect(status.available, isTrue, reason: status.message);
    expect(status.provider, 'CPUExecutionProvider');
  });
}
