// Widget tests for the schema-driven file picker.
//
// `WidgetType.filepicker` is the schema system's only filesystem concept, and
// two of its properties are invisible to a unit test:
//
//  * the field has to repaint when the value changes underneath it. The plain
//    textfield widget beside it uses `TextFormField(initialValue:)`, which is
//    read once — a path written back by the picker would never appear. This one
//    is stateful with a controller precisely to avoid that, so the behaviour is
//    pinned here.
//  * the shipped Subtitles schema has to actually reach it. Nothing else in
//    `assets/filters/core/` uses the widget, so a typo in `subtitles.json`
//    would silently fall back to a bare text field.
//
// Run with: flutter test test/parameter_file_picker_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/views/settings/widgets/parameter_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester, {
    required ParameterDefinition param,
    required dynamic value,
    ValueChanged<dynamic>? onChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ParameterWidgetFactory.build(
            paramId: 'burnInPath',
            param: param,
            value: value,
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const picker = ParameterDefinition(
    type: ParameterType.string,
    defaultValue: '',
    ui: ParameterUiConfig(
      label: 'Subtitle file to burn in',
      widget: WidgetType.filepicker,
      fileExtensions: ['srt', 'ass', 'ssa'],
    ),
  );

  group('filepicker widget', () {
    testWidgets('renders a browse button beside an editable field',
        (tester) async {
      await pump(tester, param: picker, value: '/tmp/example.srt');

      expect(find.text('Subtitle file to burn in'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Browse…'), findsOneWidget);

      // The path is shown, and the field is not read-only — typing or pasting
      // a path has to keep working; the button is an addition.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, '/tmp/example.srt');
      expect(field.readOnly, isFalse);
    });

    testWidgets('the field follows a value changed from outside',
        (tester) async {
      await pump(tester, param: picker, value: '/tmp/first.srt');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '/tmp/first.srt',
      );

      // This is what a stateless `initialValue:` field would fail: rebuilt with
      // a new value, it would keep displaying the old one.
      await pump(tester, param: picker, value: '/tmp/second.srt');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '/tmp/second.srt',
      );
    });

    testWidgets('typing a path reports it', (tester) async {
      String? reported;
      await pump(
        tester,
        param: picker,
        value: '',
        onChanged: (v) => reported = v as String,
      );

      await tester.enterText(find.byType(TextField), '/tmp/typed.ass');
      expect(reported, '/tmp/typed.ass');
    });

    testWidgets('a plain string parameter still gets a bare text field',
        (tester) async {
      // The picker must be opted into explicitly — `_inferWidgetType` maps
      // string to textfield, and schemas like crop_resize's customSar rely on
      // that.
      await pump(
        tester,
        param: const ParameterDefinition(
          type: ParameterType.string,
          defaultValue: '',
        ),
        value: '16:9',
      );
      expect(find.widgetWithText(OutlinedButton, 'Browse…'), findsNothing);
      expect(find.byType(TextFormField), findsOneWidget);
    });
  });

  group('the shipped subtitles schema', () {
    late FilterSchema schema;

    setUpAll(() {
      schema = FilterSchema.fromJson(
        jsonDecode(File('assets/filters/core/subtitles.json').readAsStringSync())
            as Map<String, dynamic>,
      );
    });

    test('burnInPath asks for the picker, limited to subtitle files', () {
      final param = schema.parameters['burnInPath'];
      expect(param, isNotNull, reason: 'burnInPath should exist');
      expect(param!.ui?.widget, WidgetType.filepicker);
      expect(param.ui?.fileExtensions, containsAll(<String>['srt', 'ass']));
    });

    test('its description no longer claims transcription runs after the encode',
        () {
      // The worker transcribes before the encode and feeds the result into
      // burn-in (worker/src/main.rs), so the old wording was actively wrong.
      final description = schema.parameters['burnInPath']!.ui!.description!;
      expect(description, isNot(contains('cannot be burnt in')));
      expect(description.toLowerCase(), contains('skips transcription'));
    });
  });
}
