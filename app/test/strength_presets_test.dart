// The simple-mode Strength control of Noise Reduction and Sharpen (issue #177).
//
// Each simple-mode method has one schema parameter preset labelled "Strength"
// (Light / Medium / Strong / Very strong). The values were measured in
// docs/reports/issue-177-strength-mapping, and this test is what keeps the
// schemas, the models and the report saying the same thing:
//
//   * every option equals the report's data/steps.json;
//   * Medium is the schema's defaults (the user's decision: switching the pass
//     on is Medium, and existing output did not change);
//   * every option is a value the control itself accepts;
//   * NoiseReductionParameters.fromPreset and the built-in presets land on
//     named steps, so simple mode shows a step rather than "Custom";
//   * the noise-score hint's thresholds are the report's.
//
// Run with: flutter test test/strength_presets_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/models/noise_halo_report.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/processing_preset.dart';
import 'package:vapourbox/models/strength_advice.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/views/settings/dynamic_filter_panel.dart';

const _steps = ['Light', 'Medium', 'Strong', 'Very strong'];
const _filters = ['noise_reduction', 'sharpen'];

FilterSchema _schema(String id) => FilterSchema.fromJson(
    jsonDecode(File('assets/filters/core/$id.json').readAsStringSync()) as Map<String, dynamic>);

final Map<String, dynamic> _report = jsonDecode(File(
            '../docs/reports/issue-177-strength-mapping/data/steps.json')
        .readAsStringSync()) as Map<String, dynamic>;

/// The Strength preset shown for [method], or null.
ParameterPreset? _strengthFor(FilterSchema schema, String method) {
  final found = schema.parameterPresets?.values.where((p) =>
      p.label == 'Strength' && (p.visibleWhen?['method'] as List?)?.contains(method) == true);
  return (found == null || found.isEmpty) ? null : found.single;
}

void main() {
  group('schemas', () {
    for (final filter in _filters) {
      final schema = _schema(filter);

      test('$filter: every simple-mode method has one Strength, and nothing else does', () {
        for (final m in schema.methods) {
          final preset = _strengthFor(schema, m.id);
          if (m.advancedOnly) {
            // A preset is hidden in advanced mode, the only place such a
            // method is offered, so one would only be clutter.
            expect(preset, isNull, reason: '${m.id} is advanced-only');
          } else {
            expect(preset, isNotNull, reason: '${m.id} has no Strength');
          }
        }
      });

      test('$filter: every Strength matches the report', () {
        final measured = _report[filter] as Map<String, dynamic>;
        expect(
            schema.methods.where((m) => !m.advancedOnly).map((m) => m.id).toSet(),
            measured.keys.toSet());
        for (final MapEntry(key: method, value: byStep) in measured.entries) {
          final preset = _strengthFor(schema, method)!;
          expect(preset.options.keys.toList(), _steps, reason: method);
          expect(preset.defaultOption, 'Medium', reason: method);
          expect(preset.customOption, 'Custom', reason: method);
          expect(preset.sinceAppVersion, '1.8.0', reason: method);
          expect(preset.optionDescriptions?.keys.toSet(), _steps.toSet(), reason: method);
          for (final step in _steps) {
            expect(preset.options[step], (byStep as Map)[step],
                reason: '$filter $method $step differs from steps.json');
          }
        }
      });

      test('$filter: Medium is the schema default of every value it sets', () {
        for (final m in schema.methods.where((m) => !m.advancedOnly)) {
          final medium = _strengthFor(schema, m.id)!.options['Medium']!;
          for (final MapEntry(key: id, value: v) in medium.entries) {
            expect(v, schema.parameters[id]!.defaultValue, reason: '${m.id}.$id');
          }
        }
      });

      test('$filter: every option is in range, of its type, and visible for its method', () {
        for (final m in schema.methods.where((m) => !m.advancedOnly)) {
          final preset = _strengthFor(schema, m.id)!;
          for (final MapEntry(key: step, value: values) in preset.options.entries) {
            for (final MapEntry(key: id, value: v) in values.entries) {
              final p = schema.parameters[id];
              expect(p, isNotNull, reason: '${m.id} $step sets unknown $id');
              final where = '${m.id} $step $id=$v';
              switch (p!.type) {
                case ParameterType.integer:
                  expect(v, isA<int>(), reason: where);
                case ParameterType.number:
                  expect(v, isA<double>(), reason: '$where: write it as a double');
                case ParameterType.enumType:
                  expect(p.options, contains(v), reason: where);
                default:
                  fail('$where: a Strength sets only numbers and enums');
              }
              if (v is num) {
                if (p.min != null) expect(v, greaterThanOrEqualTo(p.min!), reason: where);
                if (p.max != null) expect(v, lessThanOrEqualTo(p.max!), reason: where);
              }
              final vw = p.ui?.visibleWhen?['method'];
              expect(vw is List ? vw.contains(m.id) : vw == m.id, isTrue,
                  reason: '$where: the parameter is not shown for ${m.id}');
            }
          }
        }
      });

      test('$filter: every step is a different setting', () {
        for (final m in schema.methods.where((m) => !m.advancedOnly)) {
          final opts = _strengthFor(schema, m.id)!.options.values.map(jsonEncode).toSet();
          expect(opts.length, 4, reason: m.id);
        }
      });
    }
  });

  group('models and presets', () {
    final nr = _schema('noise_reduction');
    final smdegrain = _strengthFor(nr, 'smdegrain')!;

    test('fromPreset light / moderate / heavy are SMDegrain Light / Medium / Strong', () {
      for (final (preset, step) in [
        (NoiseReductionPreset.light, 'Light'),
        (NoiseReductionPreset.moderate, 'Medium'),
        (NoiseReductionPreset.heavy, 'Strong'),
      ]) {
        final values =
            ParameterConverter.fromNoiseReduction(NoiseReductionParameters.fromPreset(preset))
                .values;
        expect(smdegrain.matchingOption(values), step, reason: preset.name);
      }
    });

    test('every built-in preset lands on a named Strength step', () {
      for (final preset in ProcessingPreset.builtInPresets()) {
        for (final (filter, params) in [
          ('noise_reduction', ParameterConverter.fromNoiseReduction(preset.pipeline.noiseReduction)),
          ('sharpen', ParameterConverter.fromSharpen(preset.pipeline.sharpen)),
        ]) {
          if (!params.enabled) continue;
          final method = params.values['method'] as String;
          final strength = _strengthFor(_schema(filter), method);
          if (strength == null) continue;
          expect(strength.matchingOption(params.values), isNotNull,
              reason: '${preset.name}: its $filter ($method) would show "Custom"');
        }
      }
    });
  });

  group('noise hint', () {
    NoiseHaloReport report(double noise, {bool high = true}) =>
        NoiseHaloReport(noise: noise, noiseHigh: high, usablePairs: 24);

    test('thresholds are the report\'s', () {
      final hint = (_report['noiseHint'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as num).toDouble()));
      expect({for (final (s, t) in strengthNoiseThresholds) s: t}, hint);
    });

    test('silent unless the worker judged the source noisy', () {
      expect(suggestedStrength(null), isNull);
      expect(suggestedStrength(const NoiseHaloReport.failed('x')), isNull);
      expect(suggestedStrength(report(20, high: false)), isNull);
      expect(suggestedStrength(const NoiseHaloReport(noiseHigh: true)), isNull);
    });

    test('a step per noise level, strongest at the most noise', () {
      final ordered = [3.6, 5.0, 6.0, 8.0, 12.0].map((n) => suggestedStrength(report(n))).toList();
      final rank = ordered.map((s) => _steps.indexOf(s!)).toList();
      for (var i = 1; i < rank.length; i++) {
        expect(rank[i], greaterThanOrEqualTo(rank[i - 1]), reason: '$ordered');
      }
      expect(ordered.first, 'Medium');
      expect(ordered.last, 'Very strong');
    });

    test('only for an enabled pass with a Strength control', () {
      final r = report(8);
      expect(noiseStrengthNotice(r, enabled: true, hasStrength: true), contains('Very strong'));
      expect(noiseStrengthNotice(r, enabled: false, hasStrength: true), isNull);
      expect(noiseStrengthNotice(r, enabled: true, hasStrength: false), isNull);
      final nr = _schema('noise_reduction');
      expect(hasStrengthFor(nr, 'smdegrain'), isTrue);
      expect(hasStrengthFor(nr, 'bm3d'), isFalse);
    });
  });

  group('panel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final advanced = AdvancedModeService.instance;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      advanced.resetForTesting();
    });

    Future<List<DynamicParameters>> pump(WidgetTester tester, DynamicParameters params,
        {String filter = 'noise_reduction'}) async {
      final changes = <DynamicParameters>[];
      await tester.pumpWidget(ChangeNotifierProvider<AdvancedModeService>.value(
        value: advanced,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DynamicFilterPanelCompact(
                schema: _schema(filter),
                params: params,
                onChanged: changes.add,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return changes;
    }

    DynamicParameters defaults() => ParameterConverter.fromNoiseReduction(
        const NoiseReductionParameters(enabled: true));

    testWidgets('simple mode shows Strength at Medium and hides what it sets', (tester) async {
      await advanced.initialize();
      final changes = await pump(tester, defaults());
      expect(find.text('Strength'), findsOneWidget);
      expect(find.text('Medium'), findsOneWidget);
      expect(find.textContaining('Luma Threshold'), findsNothing);

      await tester.tap(find.text('Medium'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Very strong').last);
      await tester.pumpAndSettle();
      final very = _strengthFor(_schema('noise_reduction'), 'smdegrain')!.options['Very strong']!;
      expect(changes.last.values, containsPair('smDegrainThSAD', very['smDegrainThSAD']));
      expect(changes.last.values, containsPair('smDegrainTr', very['smDegrainTr']));
    });

    testWidgets('values edited in advanced mode read as Custom', (tester) async {
      await advanced.initialize();
      final edited = defaults().withValues({'smDegrainThSAD': 451});
      await pump(tester, edited);
      expect(find.text('Custom'), findsOneWidget);
      expect(find.textContaining('Set in Advanced mode'), findsOneWidget);
    });

    testWidgets('advanced mode shows the raw values and no Strength', (tester) async {
      await advanced.initialize();
      await advanced.setEnabled(true);
      await pump(tester, defaults());
      expect(find.text('Strength'), findsNothing);
      expect(find.textContaining('Luma Threshold'), findsOneWidget);
    });
  });
}
