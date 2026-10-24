// The Frame Rate panel tells the user, the moment RIFE is chosen, why it can't
// run here and what to do — the worker's message, verbatim, with a way to
// check again once they have. RIFE has no fallback (a RIFE job without Vulkan
// is refused), so this notice is the user's only warning before a job fails.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/filter_registry.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/rife_status.dart';
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
    FilterRegistry.instance.registerFromJson(
      jsonDecode(File('assets/filters/core/frame_rate.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    vm = MainViewModel(runner: FakeJobRunner());
  });

  tearDown(() => vm.dispose());

  void selectMethod(String method) => vm.updateDynamicParams(
        'frame_rate',
        DynamicParameters(
          filterId: 'frame_rate',
          enabled: true,
          values: {'method': method, 'target': 'pal50', 'blockSize': 16, 'overlap': 8},
        ),
      );

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AdvancedModeService>.value(
        value: AdvancedModeService.instance,
        child: ChangeNotifierProvider<MainViewModel>.value(
          value: vm,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PassSettingsInline(passType: PassType.frameRate),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets the view model's preview debounce (300 ms) fire before teardown.
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 1));

  const message = 'RIFE needs a graphics card with Vulkan support, and none was found.';
  const unavailable =
      RifeStatus(available: false, reason: 'noVulkan', message: message);

  testWidgets('RIFE selected where it cannot run: the remedy and Check again',
      (tester) async {
    selectMethod('rife');
    vm.debugSetRifeStatus(unavailable);
    await pumpPanel(tester);

    expect(find.text(message), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('while the probe runs, it says so', (tester) async {
    selectMethod('rife');
    vm.debugSetRifeStatus(null, checking: true);
    await pumpPanel(tester);

    expect(find.textContaining('Checking whether RIFE can run'), findsOneWidget);
    expect(find.text(message), findsNothing);
    await settle(tester);
  });

  testWidgets('silent when RIFE runs, or when another method is chosen',
      (tester) async {
    selectMethod('rife');
    vm.debugSetRifeStatus(const RifeStatus(available: true));
    await pumpPanel(tester);
    expect(find.text('Check again'), findsNothing);
    expect(find.textContaining('RIFE can run'), findsNothing);

    selectMethod('flowFps');
    vm.debugSetRifeStatus(unavailable);
    await pumpPanel(tester);
    expect(find.text(message), findsNothing);
    expect(find.text('Check again'), findsNothing);
    await settle(tester);
  });
}
