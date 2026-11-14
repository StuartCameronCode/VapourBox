// Crop & Resize's Detect (app 1.7.0): the panel measures the selected video's
// edges and offers what it found, and nothing changes until a button is
// pressed. A letterbox bar is a separate choice, and a head-switching band can
// be repaired with Edge Repair instead of cropped.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/crop_detect_report.dart';
import 'package:vapourbox/models/filter_registry.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';
import 'package:vapourbox/views/pass_settings/pass_settings_inline.dart';

import 'fakes/fake_job_runner.dart';

/// What the worker prints for a VHS capture: blanking at the sides, a
/// head-switching band at the bottom, inside a letterbox.
const _workerJson = '''
{"found":true,"width":720,"height":576,"interlaced":true,"frames":[10,20,30],"usableFrames":3,
 "crop":{"left":12,"right":8,"top":0,"bottom":8},
 "cropWithBars":{"left":12,"right":8,"top":72,"bottom":72},
 "edgeRepair":{"left":0,"right":0,"top":0,"bottom":8},
 "cropWithRepair":{"left":12,"right":8,"top":0,"bottom":0},
 "edges":{
  "left":{"kind":"blanking","blank":10,"ramp":2,"band":0,"bar":0,"crop":12,"cropWithBars":12,"confidence":1.0},
  "right":{"kind":"blanking","blank":8,"ramp":0,"band":0,"bar":0,"crop":8,"cropWithBars":8,"confidence":0.9},
  "top":{"kind":"bar","blank":72,"ramp":0,"band":0,"bar":72,"crop":0,"cropWithBars":72,"confidence":1.0},
  "bottom":{"kind":"headSwitching","blank":0,"ramp":0,"band":8,"bar":64,"crop":8,"cropWithBars":72,"confidence":0.8}},
 "confidence":0.8,"stepX":2,"stepY":4,"message":null}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MainViewModel vm;
  late List<VideoJob> asked;
  late CropDetectReport answer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdvancedModeService.instance.resetForTesting();
    for (final id in ['crop_resize', 'edge_repair']) {
      FilterRegistry.instance.registerFromJson(
        jsonDecode(File('assets/filters/core/$id.json').readAsStringSync())
            as Map<String, dynamic>,
      );
    }
    asked = [];
    vm = MainViewModel(
      runner: FakeJobRunner(),
      cropDetector: (job) async {
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
                child: PassSettingsInline(passType: PassType.cropResize),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) => tester.pump(const Duration(seconds: 1));

  Future<void> detect(WidgetTester tester) async {
    // The reported ProRes capture's tags (task #5): Apple's "unknown" read
    // as `reserved`, which the worker must be told about to clear.
    vm.debugAddQueueItemForTest('/videos/tape.avi', width: 720, height: 576,
        colorMatrix: 'bt709', colorPrimaries: 'reserved', colorTransfer: 'reserved', colorRange: 'tv');
    await pumpPanel(tester);
    await tester.tap(find.text('Detect borders'));
    await tester.pump();
    await tester.pump();
  }

  test('the worker\'s JSON is read in full', () {
    final r = CropDetectReport.fromJson(jsonDecode(_workerJson) as Map<String, dynamic>);
    expect(r.found, isTrue);
    expect(r.crop, const CropSides(left: 12, right: 8, top: 0, bottom: 8));
    expect(r.cropWithBars, const CropSides(left: 12, right: 8, top: 72, bottom: 72));
    expect(r.edgeRepair, const CropSides(bottom: 8));
    expect(r.bottom.kind, CropEdgeKind.headSwitching);
    expect(r.top.kind, CropEdgeKind.bar);
    expect(r.sampledFrames, 3);
    expect(r.findings.map((f) => f.$1), ['Left', 'Right', 'Top', 'Bottom']);
    expect(CropDetectReport.fromJson({'error': 'boom'}).error, 'boom');
  });

  testWidgets('without a selected video, Detect cannot run', (tester) async {
    await pumpPanel(tester);
    final button = tester.widget<OutlinedButton>(
        find.ancestor(of: find.text('Detect borders'), matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
    expect(button.onPressed, isNull);
    expect(find.text('Select a video to analyse.'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('what was found is shown, and nothing changes until Apply', (tester) async {
    answer = CropDetectReport.fromJson(jsonDecode(_workerJson) as Map<String, dynamic>);
    final before = vm.getDynamicParams('crop_resize').values['cropLeft'];
    await detect(tester);
    expect(asked.single.inputPath, '/videos/tape.avi');
    expect(asked.single.processingPipeline, isNotNull,
        reason: 'the worker needs the pipeline: the crop follows Rotate / Flip');
    final job = asked.single;
    expect((job.inputColorMatrix, job.inputColorPrimaries, job.inputColorTransfer, job.inputColorRange),
        ('bt709', 'reserved', 'reserved', 'tv'),
        reason: 'without the raw tags the worker cannot clear a reserved one before converting');
    expect(find.text('Left: 10 px of black / blanking and a 2-px soft edge'), findsOneWidget);
    expect(find.text('Top: 72-line letterbox bar'), findsOneWidget);
    expect(find.textContaining('Bottom: 8 lines of head-switching noise'), findsOneWidget);
    expect(find.text('Crop left 12, right 8, top 0, bottom 8.'), findsOneWidget);
    // Advisory: the controls are untouched until a button is pressed.
    expect(vm.getDynamicParams('crop_resize').values['cropLeft'], before);

    await tester.tap(find.text('Apply crop'));
    await tester.pump();
    final cr = vm.processingPipeline.cropResize;
    expect(cr.enabled, isTrue);
    expect(cr.cropEnabled, isTrue);
    expect([cr.cropLeft, cr.cropRight, cr.cropTop, cr.cropBottom], [12, 8, 0, 8]);
    expect(vm.processingPipeline.edgeRepair.enabled, isFalse);
    await settle(tester);
  });

  testWidgets('the bars are a separate choice', (tester) async {
    answer = CropDetectReport.fromJson(jsonDecode(_workerJson) as Map<String, dynamic>);
    await detect(tester);
    await tester.tap(find.text('Crop the bars too'));
    await tester.pump();
    final cr = vm.processingPipeline.cropResize;
    expect([cr.cropLeft, cr.cropRight, cr.cropTop, cr.cropBottom], [12, 8, 72, 72]);
    await settle(tester);
  });

  testWidgets('the band can be repaired with Edge Repair instead', (tester) async {
    answer = CropDetectReport.fromJson(jsonDecode(_workerJson) as Map<String, dynamic>);
    await detect(tester);
    await tester.tap(find.text('Repair the band instead'));
    await tester.pump();
    final cr = vm.processingPipeline.cropResize;
    expect([cr.cropLeft, cr.cropRight, cr.cropTop, cr.cropBottom], [12, 8, 0, 0]);
    final er = vm.processingPipeline.edgeRepair;
    expect(er.enabled, isTrue);
    expect(er.bottom, 8);
    await settle(tester);
  });

  testWidgets('nothing found: said plainly, nothing to apply', (tester) async {
    answer = CropDetectReport.fromJson(const {
      'found': false,
      'crop': {'left': 0, 'right': 0, 'top': 0, 'bottom': 0},
      'message': 'No black borders, blanking or head-switching noise at the edges.',
    });
    await detect(tester);
    expect(find.textContaining('No black borders'), findsOneWidget);
    expect(find.text('Apply crop'), findsNothing);
    await settle(tester);
  });

  testWidgets('a hard-to-judge result says so', (tester) async {
    final json = jsonDecode(_workerJson) as Map<String, dynamic>;
    answer = CropDetectReport.fromJson({...json, 'confidence': 0.2});
    await detect(tester);
    expect(find.textContaining('Hard to judge'), findsOneWidget);
    expect(find.text('Apply crop'), findsOneWidget, reason: 'still the user\'s call');
    await settle(tester);
  });

  testWidgets('a failure is shown, not applied', (tester) async {
    answer = const CropDetectReport.failed('Could not decode frame 4');
    await detect(tester);
    expect(find.textContaining('Detection failed: Could not decode frame 4'), findsOneWidget);
    expect(find.text('Apply crop'), findsNothing);
    await settle(tester);
  });
}
