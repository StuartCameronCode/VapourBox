// The panels tell the user, the moment a GPU feature is chosen — RIFE on Frame
// Rate, Real-ESRGAN / Real-CUGAN on Crop & Resize — why it can't run here and
// what to do: the worker's message, verbatim, with a way to check again once
// they have. Neither has a fallback (such a job is refused), so this notice is
// the user's only warning before a job fails.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/filter_registry.dart';
import 'package:vapourbox/models/gpu_plugin_status.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';
import 'package:vapourbox/views/pass_settings/pass_settings_inline.dart';

import 'fakes/fake_job_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MainViewModel vm;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdvancedModeService.instance.resetForTesting();
    for (final id in ['frame_rate', 'crop_resize']) {
      FilterRegistry.instance.registerFromJson(
        jsonDecode(File('assets/filters/core/$id.json').readAsStringSync())
            as Map<String, dynamic>,
      );
    }
    vm = MainViewModel(runner: FakeJobRunner());
  });

  tearDown(() => vm.dispose());

  Future<void> pumpPanel(WidgetTester tester, PassType pass) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AdvancedModeService>.value(
        value: AdvancedModeService.instance,
        child: ChangeNotifierProvider<MainViewModel>.value(
          value: vm,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: PassSettingsInline(passType: pass)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets the view model's preview debounce (300 ms) fire before teardown.
  Future<void> settle(WidgetTester tester) => tester.pump(const Duration(seconds: 1));

  // Each feature: its pass, how to select it, and how to select something else.
  final cases = <String, (PassType, GpuPlugin, void Function(), void Function())>{
    'RIFE': (
      PassType.frameRate,
      GpuPlugin.rife,
      () => vm.updateDynamicParams('frame_rate', const DynamicParameters(
            filterId: 'frame_rate', enabled: true,
            values: {'method': 'rife', 'target': 'pal50', 'blockSize': 16, 'overlap': 8})),
      () => vm.updateDynamicParams('frame_rate', const DynamicParameters(
            filterId: 'frame_rate', enabled: true,
            values: {'method': 'flowFps', 'target': 'pal50', 'blockSize': 16, 'overlap': 8})),
    ),
    'AI upscaling': (
      PassType.cropResize,
      GpuPlugin.upscale,
      () => vm.updateDynamicParams('crop_resize', const DynamicParameters(
            filterId: 'crop_resize', enabled: true,
            values: {'useIntegerUpscale': true, 'upscaleMethod': 'realCugan', 'upscaleFactor': 2})),
      () => vm.updateDynamicParams('crop_resize', const DynamicParameters(
            filterId: 'crop_resize', enabled: true,
            values: {'useIntegerUpscale': true, 'upscaleMethod': 'nnedi3Rpow2', 'upscaleFactor': 2})),
    ),
  };

  for (final MapEntry(key: name, value: (pass, plugin, select, selectOther)) in cases.entries) {
    final message = '${plugin.label} needs a graphics card with Vulkan support, and none was found.';
    final unavailable = GpuPluginStatus(available: false, reason: 'noVulkan', message: message);

    testWidgets('$name selected where it cannot run: the remedy and Check again', (tester) async {
      select();
      vm.debugSetGpuPluginStatus(plugin, unavailable);
      await pumpPanel(tester, pass);
      expect(find.text(message), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('$name: while the probe runs, it says so', (tester) async {
      select();
      vm.debugSetGpuPluginStatus(plugin, null, checking: true);
      await pumpPanel(tester, pass);
      expect(find.textContaining('Checking whether ${plugin.label} can run'), findsOneWidget);
      expect(find.text(message), findsNothing);
      await settle(tester);
    });

    testWidgets('$name: silent where it runs, or when something else is chosen', (tester) async {
      select();
      vm.debugSetGpuPluginStatus(plugin, const GpuPluginStatus(available: true));
      await pumpPanel(tester, pass);
      expect(find.text('Check again'), findsNothing);
      expect(find.textContaining('can run on this computer'), findsNothing);

      selectOther();
      vm.debugSetGpuPluginStatus(plugin, unavailable);
      await pumpPanel(tester, pass);
      expect(find.text(message), findsNothing);
      expect(find.text('Check again'), findsNothing);
      await settle(tester);
    });
  }
}
