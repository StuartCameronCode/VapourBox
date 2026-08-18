// What the Chroma Fixes panel actually shows, pumped from the shipped schema.
//
// The pass covers five unrelated repairs, and it was reported as unintuitive
// because every repair's tuning sliders were on screen at once whether the
// repair was switched on or not. The cause was not the grouping: the conditions
// were written at `parameters.<id>.visibleWhen`, one level above the only place
// `ParameterUiConfig` reads them from, so they were dropped at parse time and
// nothing was ever hidden.
//
// filter_schema_curation_test.dart lints the JSON for that mistake. This is the
// other half — proof that the panel really does hide what the schema says to
// hide, which a lint over the file cannot show. It pumps the real
// chroma_fixes.json rather than a fixture, so a future edit that reintroduces an
// always-visible slider fails here.
//
// Run with: flutter test test/chroma_fixes_panel_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/chroma_fix_parameters.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/views/settings/dynamic_filter_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final advanced = AdvancedModeService.instance;

  final schema = FilterSchema.fromJson(
    jsonDecode(File('assets/filters/core/chroma_fixes.json').readAsStringSync())
        as Map<String, dynamic>,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    advanced.resetForTesting();
  });

  /// Pump the panel for [params], exactly as the pass settings panel builds it.
  Future<void> pump(
    WidgetTester tester,
    ChromaFixParameters params, {
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
                params: ParameterConverter.fromChromaFixes(params),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A slider renders as "Label: value", so match on the label alone.
  Finder slider(String label) => find.textContaining('$label:');

  group('nothing is on screen for a repair that is switched off', () {
    testWidgets('the default panel is switches only', (tester) async {
      await pump(tester, const ChromaFixParameters(enabled: true));

      // Every repair is offered...
      for (final label in [
        'Correct colour alignment automatically',
        'Correct colour alignment by hand (Y/C delay)',
        'Fix colour bleeding past edges',
        'Remove dot crawl',
        'Remove rainbow shimmer',
        'Remove chroma combing',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }

      // ...and not one of them has a control on screen yet.
      for (final label in [
        'Horizontal shift',
        'Vertical shift',
        'Strength',
        'Colour blur',
        'Brightness threshold',
        'Colour threshold',
        'Motion threshold',
        'Caution',
        'Maximum change',
      ]) {
        expect(slider(label), findsNothing, reason: label);
      }
    });

    testWidgets('a switch reveals only its own controls', (tester) async {
      await pump(
        tester,
        const ChromaFixParameters(enabled: true, applyChromaBleedingFix: true),
      );

      expect(slider('Strength'), findsOneWidget);
      expect(slider('Colour blur'), findsOneWidget);
      // Vinverse also has a "Strength", and its repair is off — so exactly one
      // of that label may be present.
      expect(slider('Horizontal shift'), findsNothing);
      expect(slider('Colour threshold'), findsNothing);
    });
  });

  group('each repair is a named group', () {
    testWidgets('simple mode shows a heading per repair', (tester) async {
      // Without headings the panel is one flat run of switches, and which
      // slider belongs to which repair is left to the reader. The panel prints
      // section titles whenever a schema has more than one section.
      await pump(tester, const ChromaFixParameters(enabled: true));

      for (final title in [
        'Colour alignment',
        'Colour bleeding',
        'Dot crawl',
        'Rainbowing',
        'Chroma combing',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }

      // Tuning sections belong to advanced mode, headings included.
      expect(find.text('Automatic alignment tuning'), findsNothing);
    });
  });

  group('automatic and manual alignment are alternatives', () {
    testWidgets('automatic alignment withdraws the manual sliders',
        (tester) async {
      await pump(
        tester,
        const ChromaFixParameters(
          enabled: true,
          applyAutoChroma: true,
          applyChromaShift: true,
          chromaShiftH: 2.0,
        ),
      );

      // Not merely disabled — gone, because the worker drops the manual block
      // when automatic alignment is on (test_150) and a visible slider that
      // changes nothing is worse than no slider.
      expect(find.text('Correct colour alignment by hand (Y/C delay)'),
          findsNothing);
      expect(slider('Horizontal shift'), findsNothing);
      expect(slider('Vertical shift'), findsNothing);
    });

    testWidgets('with automatic off the manual sliders come back',
        (tester) async {
      await pump(
        tester,
        const ChromaFixParameters(
          enabled: true,
          applyChromaShift: true,
          chromaShiftH: 2.0,
        ),
      );

      expect(find.text('Correct colour alignment by hand (Y/C delay)'),
          findsOneWidget);
      expect(slider('Horizontal shift'), findsOneWidget);
      expect(slider('Vertical shift'), findsOneWidget);
    });
  });

  group('thresholds wait for advanced mode', () {
    testWidgets('simple mode shows no tuning for an enabled repair',
        (tester) async {
      await pump(
        tester,
        const ChromaFixParameters(enabled: true, applyAutoChroma: true),
      );

      expect(find.text('Correct colour alignment automatically'), findsOneWidget);
      expect(slider('Search range'), findsNothing);
      expect(find.text('Reference frame'), findsNothing);
    });

    testWidgets('advanced mode shows it, under its own heading', (tester) async {
      await pump(
        tester,
        const ChromaFixParameters(enabled: true, applyAutoChroma: true),
        advancedMode: true,
      );

      expect(find.text('Automatic alignment tuning'), findsOneWidget);
      expect(slider('Search range'), findsOneWidget);
      expect(find.text('Reference frame'), findsOneWidget);

      // Tuning for a repair that is off stays hidden even here — the advanced
      // switch is not a "show me all 25 controls" switch.
      expect(find.text('Dot crawl tuning'), findsNothing);
      expect(slider('Colour motion limit'), findsNothing);
    });
  });
}
