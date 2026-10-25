// The Noise Reduction panel tells the user, the moment KNLMeans is chosen, that
// it can't run here and why: the worker's own message (the job would be
// refused with the same text). BM3D, and a machine where KNLMeans works, stay
// silent.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/filter_registry.dart';
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
    FilterRegistry.instance.registerFromJson(
      jsonDecode(File('assets/filters/core/noise_reduction.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    vm = MainViewModel(runner: FakeJobRunner());
  });

  tearDown(() => vm.dispose());

  void selectMethod(String method) => vm.updateDynamicParams(
        'noise_reduction',
        DynamicParameters(
          filterId: 'noise_reduction',
          enabled: true,
          values: {'method': method},
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
                child: PassSettingsInline(passType: PassType.noiseReduction),
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

  const message = 'KNLMeans runs on the graphics card through OpenCL, and none was found.';

  testWidgets('KNLMeans selected where no OpenCL device works: the reason',
      (tester) async {
    selectMethod('knlmeans');
    vm.debugSetKnlmMethodMessage(message);
    await pumpPanel(tester);
    expect(find.text(message), findsOneWidget);
    await settle(tester);
  });

  testWidgets('silent for BM3D, and for KNLMeans where it runs', (tester) async {
    selectMethod('bm3d');
    vm.debugSetKnlmMethodMessage(message);
    await pumpPanel(tester);
    expect(find.text(message), findsNothing);

    selectMethod('knlmeans');
    vm.debugSetKnlmMethodMessage(null);
    await pumpPanel(tester);
    expect(find.text(message), findsNothing);
    await settle(tester);
  });
}
