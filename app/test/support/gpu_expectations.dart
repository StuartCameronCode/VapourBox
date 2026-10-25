// Where the ncnn-on-Vulkan features (RIFE, AI upscaling) must work, and the
// one rule every GPU test applies.
//
// The hosted CI runners have no GPU. The workflows give the Linux and Windows
// runners Mesa's software Vulkan driver (lavapipe) and set
// VAPOURBOX_EXPECT_VULKAN=1 wherever a Vulkan device is provisioned. Under that
// variable, on a platform that ships the feature, "not available" is a test
// failure — so a broken bundle, plugin or probe cannot hide behind a skip, which
// is how it would read on a runner that simply has no GPU. Without it (a local
// run, a machine with no driver) the GPU tests skip and say why. On a platform
// that does not ship the feature, the probe must say exactly that.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'worker_harness.dart';

/// The platforms whose deps bundle ships RIFE and VSNCNN — the worker's
/// `gpu_plugin::platform_ships_*`, which attribution_test.dart pins to the
/// deps manifest.
const gpuPluginPlatforms = {'macos-arm64', 'windows-x64', 'linux-x64'};

/// This machine's deps platform id.
String get platformId {
  final abi = Abi.current();
  if (abi == Abi.macosArm64) return 'macos-arm64';
  if (abi == Abi.macosX64) return 'macos-x64';
  if (abi == Abi.windowsX64) return 'windows-x64';
  if (abi == Abi.windowsArm64) return 'windows-arm64';
  if (abi == Abi.linuxX64) return 'linux-x64';
  if (abi == Abi.linuxArm64) return 'linux-arm64';
  return abi.toString();
}

/// Whether this run has a Vulkan device provisioned and so must exercise the
/// GPU features rather than skip them.
bool get expectVulkan => Platform.environment['VAPOURBOX_EXPECT_VULKAN'] == '1';

/// Whether this platform's bundle ships the GPU features at all.
bool get platformShipsGpuPlugins => gpuPluginPlatforms.contains(platformId);

/// Run the worker's probe (`--probe-rife`, `--probe-upscale`) and return its JSON.
Future<Map<String, dynamic>> probeGpuPlugin(
  String flag, {
  Map<String, String> extraEnv = const {},
}) async {
  final r = await Process.run(
    WorkerHarness.workerPath,
    [flag],
    environment: {...WorkerHarness.workerEnv, ...extraEnv},
    workingDirectory: File(WorkerHarness.workerPath).parent.path,
  );
  expect(r.exitCode, 0, reason: '$flag failed: ${r.stderr}');
  final line = const LineSplitter()
      .convert(r.stdout.toString())
      .lastWhere((l) => l.trim().startsWith('{'), orElse: () => '');
  expect(line, isNotEmpty, reason: 'no JSON from $flag: ${r.stdout}');
  return jsonDecode(line) as Map<String, dynamic>;
}

/// The rule, for a test that needs the feature to run: true to go ahead;
/// false after marking the test skipped (feature not expected to work here);
/// a test failure if it is expected to work and the probe says otherwise.
Future<bool> requireGpuPlugin(String flag) async {
  final probe = await probeGpuPlugin(flag);
  if (probe['available'] == true) return true;
  if (platformShipsGpuPlugins && expectVulkan) {
    fail('$flag says unavailable on $platformId, where CI provisions Vulkan '
        '(VAPOURBOX_EXPECT_VULKAN=1): ${probe['reason']}: ${probe['message']}');
  }
  markTestSkipped('$flag: not available on $platformId (${probe['reason']})');
  return false;
}
