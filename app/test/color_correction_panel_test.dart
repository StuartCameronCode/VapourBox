// What the Color Correction panel shows, pumped from the shipped schema.
//
// The pass offers two adjustments that can be made automatically or by hand —
// levels and white balance — and the automatic half used to live in its own
// "Automatic" section three groups above the manual half it supersedes, with its
// own settings on screen whether it was switched on or not. It also rendered a
// Method dropdown ("Tweak" / "White Balance") that changed nothing at all: no
// parameter was conditional on it, no model had a method field, and the
// converter hardcoded 'tweak'.
//
// Run with: flutter test test/color_correction_panel_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/color_correction_parameters.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/views/settings/dynamic_filter_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final advanced = AdvancedModeService.instance;

  final schema = FilterSchema.fromJson(jsonDecode(
    File('assets/filters/core/color_correction.json').readAsStringSync(),
  ) as Map<String, dynamic>);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    advanced.resetForTesting();
  });

  Future<void> pump(
    WidgetTester tester,
    ColorCorrectionParameters params, {
    bool advancedMode = false,
  }) async {
    await advanced.initialize();
    if (advancedMode) await advanced.setEnabled(true);

    await tester.pumpWidget(
      ChangeNotifierProvider<AdvancedModeService>.value(
        value: advanced,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DynamicFilterPanelCompact(
                schema: schema,
                params: ParameterConverter.fromColorCorrection(params),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder slider(String label) => find.textContaining('$label:');

  testWidgets('no Method dropdown, and the groups are named', (tester) async {
    await pump(tester, const ColorCorrectionParameters(enabled: true));

    expect(find.text('Method'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);

    for (final title in [
      'Brightness and colour',
      'Levels',
      'White balance',
      'Shadow detail',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
  });

  testWidgets('automatic settings stay hidden until it is switched on',
      (tester) async {
    await pump(tester, const ColorCorrectionParameters(enabled: true));
    expect(slider('Strength'), findsNothing);

    await pump(
      tester,
      const ColorCorrectionParameters(enabled: true, applyAutoLevels: true),
    );
    // Auto levels' own strength appears; auto white balance's does not, because
    // that half is still off. Both are labelled "Strength" and only their group
    // tells them apart, which is what the headings are for.
    expect(slider('Strength'), findsOneWidget);
    // Its targets come with it, in simple mode: which black and white to aim
    // for is the main thing to say about an automatic levels pass.
    expect(slider('Target black'), findsOneWidget);
    expect(slider('Target white'), findsOneWidget);
  });

  testWidgets('both automatic switches are named for what they set',
      (tester) async {
    await pump(tester, const ColorCorrectionParameters(enabled: true));

    expect(find.text('Set levels automatically'), findsOneWidget);
    expect(find.text('Set white balance automatically'), findsOneWidget);
  });

  testWidgets('automatic levels withdraws the manual points but keeps gamma',
      (tester) async {
    await pump(
      tester,
      const ColorCorrectionParameters(
        enabled: true,
        applyAutoLevels: true,
        applyLevels: true,
        inputLow: 16,
      ),
    );

    for (final label in ['Input black', 'Input white', 'Output black', 'Output white']) {
      expect(slider(label), findsNothing, reason: '$label is superseded');
    }
    expect(slider('Gamma'), findsOneWidget,
        reason: 'automatic levels never touches the midtones, and this is the '
            'only control for them');
  });

  testWidgets('with automatic levels off the points come back', (tester) async {
    await pump(
      tester,
      const ColorCorrectionParameters(
        enabled: true,
        applyLevels: true,
        inputLow: 16,
      ),
    );

    expect(slider('Input black'), findsOneWidget);
    expect(slider('Output white'), findsOneWidget);
    expect(slider('Gamma'), findsOneWidget);
  });

  testWidgets('white balance keeps both halves, automatic first',
      (tester) async {
    // These compose legitimately — neutralise the cast, then warm it a little —
    // so unlike the levels pair the sliders stay put.
    await pump(
      tester,
      const ColorCorrectionParameters(
        enabled: true,
        applyAutoWhiteBalance: true,
        temperature: 20,
      ),
    );

    expect(find.text('Set white balance automatically'), findsOneWidget);
    expect(slider('Temperature'), findsOneWidget);
    expect(slider('Tint'), findsOneWidget);
  });
}
