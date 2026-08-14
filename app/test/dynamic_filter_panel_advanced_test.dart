// Widget tests for how the generated filter panel honours advanced mode.
//
// The hazard worth a widget test rather than a unit test: the method dropdown
// takes its value from the pipeline and its items from the schema, so if simple
// mode ever filters an advanced-only method that is *currently selected*, the
// dropdown gets a value that isn't among its items and Flutter throws. That is
// reachable from an ordinary preset, so it must be pinned at the widget level —
// unit-testing `visibleMethods` alone would not catch a caller that forgot to
// pass `selectedId`.
//
// Run with: flutter test test/dynamic_filter_panel_advanced_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/views/settings/dynamic_filter_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final advanced = AdvancedModeService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    advanced.resetForTesting();
  });

  MethodDefinition method(String id, {bool advancedOnly = false}) =>
      MethodDefinition(
        id: id,
        name: id,
        function: 'module.$id',
        parameters: const ['strength'],
        advancedOnly: advancedOnly,
      );

  FilterSchema buildSchema() => FilterSchema(
        id: 'test_filter',
        version: '1.0.0',
        name: 'Test Filter',
        methods: [
          method('basic'),
          method('exotic', advancedOnly: true),
        ],
        parameters: {
          'enabled': const ParameterDefinition(
            type: ParameterType.boolean,
            defaultValue: false,
          ),
          'strength': const ParameterDefinition(
            type: ParameterType.number,
            defaultValue: 1.0,
            min: 0.0,
            max: 10.0,
            ui: ParameterUiConfig(label: 'Strength'),
          ),
        },
      );

  Future<void> pumpPanel(
    WidgetTester tester, {
    required String selectedMethod,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AdvancedModeService>.value(
        value: advanced,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DynamicFilterPanelCompact(
                schema: buildSchema(),
                params: DynamicParameters(
                  filterId: 'test_filter',
                  enabled: true,
                  values: {'method': selectedMethod, 'strength': 1.0},
                ),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('DynamicFilterPanelCompact advanced mode', () {
    testWidgets('simple mode hides advanced-only methods', (tester) async {
      await advanced.initialize();
      await pumpPanel(tester, selectedMethod: 'basic');

      // With only one method left to choose from, the dropdown isn't offered
      // at all — one option is not a choice.
      expect(find.text('Method'), findsNothing);
      expect(find.text('exotic (advanced)'), findsNothing);
      expect(
        find.text('More methods are available in advanced mode.'),
        findsOneWidget,
      );
    });

    testWidgets('advanced mode offers every method', (tester) async {
      await advanced.initialize();
      await advanced.setEnabled(true);
      await pumpPanel(tester, selectedMethod: 'basic');

      expect(find.text('Method'), findsOneWidget);
      expect(
        find.text('More methods are available in advanced mode.'),
        findsNothing,
      );

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.text('exotic (advanced)'), findsWidgets);
    });

    testWidgets('an advanced-only method already selected still renders in '
        'simple mode', (tester) async {
      await advanced.initialize();
      expect(advanced.enabled, false);

      // Would throw "There should be exactly one item with
      // [DropdownButton]'s value" if the selected method were filtered out.
      await pumpPanel(tester, selectedMethod: 'exotic');

      expect(tester.takeException(), isNull);
      expect(find.text('Method'), findsOneWidget);
      expect(find.text('exotic (advanced)'), findsOneWidget);
    });

    testWidgets('toggling the switch flips the global service', (tester) async {
      await advanced.initialize();
      await pumpPanel(tester, selectedMethod: 'basic');

      // The switch shows because the schema has an advanced-only method, even
      // though it has no advanced-only parameter sections.
      expect(find.byType(Switch), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(advanced.enabled, true);
      expect(find.text('Method'), findsOneWidget);
    });
  });

  group('AdvancedModeService provider scope', () {
    // The Settings dialog reads this service, and `showDialog` pushes onto the
    // MaterialApp's Navigator — so a provider placed inside `home` is out of
    // scope for the dialog and the tab renders Provider's red error box
    // instead of the switch. main.dart therefore provides it ABOVE the
    // MaterialApp. This pins the shape that makes that work; the tests above
    // supply their own provider and so cannot catch it.
    testWidgets('a dialog route resolves it when provided above MaterialApp',
        (tester) async {
      await advanced.initialize();

      await tester.pumpWidget(
        ChangeNotifierProvider<AdvancedModeService>.value(
          value: advanced,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) => Text(
                      'advanced: '
                      '${dialogContext.watch<AdvancedModeService>().enabled}',
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('advanced: false'), findsOneWidget);

      // And the dialog rebuilds when it changes, so the switch inside Settings
      // reflects a change made from a filter panel.
      await advanced.setEnabled(true);
      await tester.pumpAndSettle();
      expect(find.text('advanced: true'), findsOneWidget);
    });
  });
}
