// Descale's Detect: the panel runs the analysis on the selected video and
// offers what it found — and when a video has no clear native resolution, it
// says so instead of offering a guess, because a wrong one damages the picture.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/filter_registry.dart';
import 'package:vapourbox/models/native_res_report.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';
import 'package:vapourbox/views/pass_settings/pass_settings_inline.dart';

import 'fakes/fake_job_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MainViewModel vm;
  late List<VideoJob> asked;
  late NativeResReport answer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdvancedModeService.instance.resetForTesting();
    FilterRegistry.instance.registerFromJson(
      jsonDecode(File('assets/filters/core/descale.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    asked = [];
    vm = MainViewModel(
      runner: FakeJobRunner(),
      nativeResDetector: (job) async {
        asked.add(job);
        return answer;
      },
    );
  });

  tearDown(() => vm.dispose());

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AdvancedModeService>.value(
        value: AdvancedModeService.instance,
        child: ChangeNotifierProvider<MainViewModel>.value(
          value: vm,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PassSettingsInline(passType: PassType.descale),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) => tester.pump(const Duration(seconds: 1));

  testWidgets('without a selected video, Detect cannot run', (tester) async {
    await pumpPanel(tester);
    final button = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Detect native resolution'));
    expect(button.onPressed, isNull);
    expect(find.text('Select a video to analyse.'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('a clear match is offered, and Use these settings applies it', (tester) async {
    answer = const NativeResReport(
      found: true, height: 810, width: 1440, kernel: 'bicubic',
      bicubicB: 1 / 3, bicubicC: 1 / 3, dip: 0.12,
      kernels: [('Bicubic (Mitchell)', 1e-5), ('Bilinear', 4e-5)],
    );
    vm.debugAddQueueItemForTest('/videos/episode1.mkv', width: 1920, height: 1080);
    await pumpPanel(tester);
    await tester.tap(find.text('Detect native resolution'));
    await tester.pump();
    await tester.pump();
    expect(asked.single.inputPath, '/videos/episode1.mkv');
    expect(asked.single.inputHeight, 1080);
    expect(find.text('Drawn at 1440×810, upscaled with Bicubic (Mitchell).'), findsOneWidget);

    await tester.tap(find.text('Use these settings'));
    await tester.pump();
    final ds = vm.processingPipeline.descale;
    expect(ds.enabled, isTrue);
    expect(ds.nativeHeight, 810);
    expect(ds.bicubicB, closeTo(1 / 3, 1e-9));
    await settle(tester);
  });

  testWidgets('no clear native resolution: said plainly, nothing to apply', (tester) async {
    answer = const NativeResReport(found: false, height: 559, width: 699, kernel: 'bicubic', dip: 0.91);
    vm.debugAddQueueItemForTest('/videos/vhs.avi', width: 720, height: 576);
    await pumpPanel(tester);
    await tester.tap(find.text('Detect native resolution'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('No clear native resolution'), findsOneWidget);
    expect(find.text('Use these settings'), findsNothing);
    await settle(tester);
  });
}
