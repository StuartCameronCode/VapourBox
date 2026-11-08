// The AI runtime add-on (assets/addons/ai-runtime.json) and the worker's
// --probe-ai-runtime answer, without the network: the wheels pinned per
// platform are the ones the bundled Python can load, the self-test model the
// probe runs is the committed one, and the probe's JSON reads as the worker
// means it. integration_ai_runtime_test.dart (heavy) installs and runs it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/models/ai_runtime_status.dart';
import 'package:vapourbox/services/manifest_addon.dart';

String get _root =>
    Directory.current.path.endsWith('app') ? Directory.current.parent.path : Directory.current.path;

AddonManifest _manifest() => AddonManifest.fromJson(
    jsonDecode(File(p.join(_root, 'app', 'assets', 'addons', 'ai-runtime.json')).readAsStringSync())
        as Map<String, dynamic>);

void main() {
  group('ai-runtime manifest', () {
    final m = _manifest();

    test('a python add-on on every platform: one onnxruntime and one NumPy wheel each', () {
      expect(m.kind, 'python');
      expect(m.requires, isEmpty);
      expect(m.platforms.keys.toSet(), addonPlatformIds.toSet());
      for (final platform in addonPlatformIds) {
        final files = m.filesFor(platform).map((f) => f.name).toList();
        expect(files.where((f) => f.startsWith('onnxruntime')).length, 1, reason: platform);
        expect(files.where((f) => f.startsWith('numpy-')).length, 1, reason: platform);
        expect(files.length, 2, reason: '$platform: only what import onnxruntime needs');
        for (final f in m.filesFor(platform)) {
          // The deps bundle's Python is 3.12 everywhere.
          expect(f.name, contains('-cp312-cp312-'), reason: f.name);
          expect(f.url, startsWith('https://files.pythonhosted.org/'), reason: f.name);
          expect(Uri.parse(f.url).pathSegments.last, f.name, reason: 'the mirror finds files by url name');
        }
      }
    });

    test('each platform gets its own build: DirectML on Windows, the last Intel wheel on Intel Macs', () {
      String ort(String platform) => m.filesFor(platform).firstWhere((f) => f.name.startsWith('onnxruntime')).name;
      expect(ort('windows-x64'), startsWith('onnxruntime_directml-'));
      expect(ort('windows-x64'), endsWith('win_amd64.whl'));
      expect(ort('macos-arm64'), contains('macosx_14_0_arm64'));
      expect(ort('macos-x64'), contains('macosx_13_0_x86_64'));
      expect(ort('linux-x64'), contains('manylinux_2_28_x86_64'));
      expect(ort('linux-arm64'), contains('manylinux_2_28_aarch64'));
      // The NumPy wheels' own macOS floors must not exceed the add-on's.
      expect(m.filesFor('macos-x64').firstWhere((f) => f.name.startsWith('numpy')).name,
          contains('macosx_10_13_x86_64'));
    });

    test('an Intel Mac before macOS 13 is told it cannot have it', () {
      expect(m.platforms['macos-x64']!['minOs'], '13.0');
      expect(ManifestAddonInstaller(m, 'macos-x64', osVersion: '12.7').unavailableReason,
          contains('macOS 13.0'));
      expect(ManifestAddonInstaller(m, 'macos-x64', osVersion: '14.2').unavailableReason, isNull);
      expect(ManifestAddonInstaller(m, 'macos-arm64', osVersion: '15.0').unavailableReason, isNull);
      expect(ManifestAddonInstaller(m, 'windows-x64').unavailableReason, isNull);
    });

    test('credits NumPy everywhere and DirectML on Windows only', () {
      List<String> credited(String platform) =>
          ManifestAddonInstaller(m, platform, osVersion: '15.0').info.credits.map((c) => c.noticeName).toList();
      expect(credited('windows-x64'), ['ONNX Runtime', 'NumPy', 'DirectML']);
      expect(credited('macos-arm64'), ['ONNX Runtime', 'NumPy']);
      expect(credited('linux-x64'), ['ONNX Runtime', 'NumPy']);
    });
  });

  test('the self-test model in ai_runtime.py is the committed one', () {
    final helper = File(p.join(_root, 'worker', 'templates', 'ai_runtime.py')).readAsStringSync().replaceAll('\r\n', '\n');
    final literal = RegExp(r'_SELFTEST_MODEL_B64 = \(\n((?:\s*"[^"]*"\n)+)\)').firstMatch(helper)!.group(1)!;
    final b64 = RegExp(r'"([^"]*)"').allMatches(literal).map((x) => x.group(1)).join();
    final committed =
        File(p.join(_root, 'Tests', 'TestResources', 'ai_runtime_selftest.onnx')).readAsBytesSync();
    expect(base64Decode(b64), committed);
    expect(committed.length, lessThan(1024), reason: 'keep it tiny');
  });

  group('AiRuntimeStatus', () {
    test('reads a working probe', () {
      final s = AiRuntimeStatus.fromJson({
        'available': true,
        'version': '1.31.1',
        'providers': ['CoreMLExecutionProvider', 'CPUExecutionProvider'],
        'provider': 'CoreMLExecutionProvider',
      });
      expect(s.available, isTrue);
      expect(s.message, isNull);
      expect(s.onGpu, isTrue);
      expect(AiRuntimeStatus.providerLabel(s.provider!), 'Core ML');
      expect(AiRuntimeStatus.providerLabel('DmlExecutionProvider'), 'DirectML');
    });

    test('a failure carries the worker\'s message; an unreadable one asks for a restart', () {
      final s = AiRuntimeStatus.fromJson(
          {'available': false, 'reason': 'notInstalled', 'message': 'Install it in Settings → Add-ons.'});
      expect(s.available, isFalse);
      expect(s.message, contains('Settings → Add-ons'));
      expect(s.onGpu, isFalse);
      final unknown = AiRuntimeStatus.fromJson({'available': false});
      expect(unknown.reason, 'probeFailed');
      expect(unknown.message, contains('Restart'));
    });
  });
}
