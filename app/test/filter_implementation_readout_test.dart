// The "what is this actually doing" readout: the VapourSynth calls a pass
// makes, shown so someone who knows the plugins from other tools can identify
// the pipeline rather than infer it from label wording.
//
// Two things make this worth a widget test. The readout is assembled from
// schema data at build time, so a schema that declares nothing renders nothing
// with no error; and it is gated on advanced mode, which is the app-wide
// complexity lever — leaking plugin names into simple mode would undo the
// curation the rest of the panel is built around.
//
// Run with: flutter test test/filter_implementation_readout_test.dart

import 'dart:convert';
import 'dart:io';

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

  FilterSchema shipped(String filename) => FilterSchema.fromJson(
        jsonDecode(File('assets/filters/core/$filename').readAsStringSync())
            as Map<String, dynamic>,
      );

  Future<void> pump(
    WidgetTester tester,
    FilterSchema schema,
    Map<String, dynamic> values,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AdvancedModeService>.value(
        value: advanced,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DynamicFilterPanelCompact(
                schema: schema,
                params: DynamicParameters(
                  filterId: schema.id,
                  enabled: true,
                  values: values,
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

  /// The rendered function names, in order, with whether each is emphasised.
  List<(String, bool)> readout(WidgetTester tester) {
    final out = <(String, bool)>[];
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      final span = rt.text;
      if (span is! TextSpan) continue;
      final children = span.children;
      if (children == null || children.isEmpty) continue;
      final first = children.first;
      if (first is! TextSpan) continue;
      if (first.style?.fontFamily != 'monospace') continue;
      out.add((first.text ?? '', first.style?.fontWeight == FontWeight.w600));
    }
    return out;
  }

  group('advanced mode gating', () {
    testWidgets('simple mode shows no plugin names at all', (tester) async {
      await advanced.setEnabled(false);
      await pump(tester, shipped('chroma_denoise.json'), {
        'method': 'ccd',
        'enabled': true,
      });
      expect(readout(tester), isEmpty);
      expect(find.textContaining('zsmooth'), findsNothing);
    });

    testWidgets('advanced mode names the selected method', (tester) async {
      await advanced.setEnabled(true);
      await pump(tester, shipped('chroma_denoise.json'), {
        'method': 'ccd',
        'enabled': true,
      });
      expect(readout(tester), [('core.zsmooth.CCD', true)]);
    });

    testWidgets('it follows the method, not the filter', (tester) async {
      await advanced.setEnabled(true);
      await pump(tester, shipped('chroma_denoise.json'), {
        'method': 'cnr4',
        'enabled': true,
      });
      expect(readout(tester), [('core.zsmooth.Cnr4', true)]);
    });
  });

  group('a composite pass shows its whole repertoire', () {
    // Colour Correction is the pass that prompted this: it has no method
    // dropdown, so before `implementation` existed there was nothing anywhere
    // in the UI naming what it ran.
    testWidgets('everything is listed, and nothing is active when nothing is '
        'switched on', (tester) async {
      await advanced.setEnabled(true);
      await pump(tester, shipped('color_correction.json'), {'enabled': true});

      final rows = readout(tester);
      final names = rows.map((r) => r.$1).toList();
      expect(names, contains('core.retinex.MSRCP'));
      expect(names, contains('haf.SmoothLevels'));
      expect(names, contains('adjust.Tweak'));

      // Tweak is unconditional; every gated call is inactive with all the
      // switches off.
      expect(rows.firstWhere((r) => r.$1 == 'adjust.Tweak').$2, isTrue);
      expect(rows.firstWhere((r) => r.$1 == 'core.retinex.MSRCP').$2, isFalse);
    });

    testWidgets('switching a repair on emphasises its call', (tester) async {
      await advanced.setEnabled(true);
      await pump(tester, shipped('color_correction.json'), {
        'enabled': true,
        'applyShadowDetail': true,
      });

      final rows = readout(tester);
      expect(rows.firstWhere((r) => r.$1 == 'core.retinex.MSRCP').$2, isTrue,
          reason: 'shadow detail is on, so MSRCP is running');
      expect(rows.firstWhere((r) => r.$1 == 'haf.SmoothLevels').$2, isFalse,
          reason: 'levels are still off');
    });

    testWidgets('two calls behind one switch pick the right one',
        (tester) async {
      // applyLevels chooses between std.Levels and SmoothLevels, so exactly
      // one of the pair must be emphasised — showing both would misreport what
      // runs, and that pair is the reason activeWhen takes more than one key.
      await advanced.setEnabled(true);
      await pump(tester, shipped('color_correction.json'), {
        'enabled': true,
        'applyLevels': true,
        'smoothLevels': true,
      });

      var rows = readout(tester);
      expect(rows.firstWhere((r) => r.$1 == 'haf.SmoothLevels').$2, isTrue);
      expect(rows.where((r) => r.$1 == 'core.std.Levels').every((r) => !r.$2),
          isTrue, reason: 'SmoothLevels replaces std.Levels, not joins it');

      await pump(tester, shipped('color_correction.json'), {
        'enabled': true,
        'applyLevels': true,
        'smoothLevels': false,
      });
      rows = readout(tester);
      expect(rows.firstWhere((r) => r.$1 == 'haf.SmoothLevels').$2, isFalse);
      expect(rows.where((r) => r.$1 == 'core.std.Levels').any((r) => r.$2),
          isTrue);
    });

    testWidgets('chroma fixes distinguishes automatic from manual alignment',
        (tester) async {
      // Both are core.resize.Spline36, told apart only by their role text, and
      // automatic suppresses manual — the same precedence the generator uses.
      await advanced.setEnabled(true);
      await pump(tester, shipped('chroma_fixes.json'), {
        'enabled': true,
        'applyAutoChroma': true,
        'applyChromaShift': true,
      });

      final active = readout(tester).where((r) => r.$2).toList();
      expect(active.length, 1,
          reason: 'automatic alignment supersedes the manual shift, so only '
              'one of the two Spline36 calls runs');
      expect(active.single.$1, 'core.resize.Spline36');
    });
  });

  group('placeholders never reach the screen', () {
    testWidgets('a "custom" function is not shown as a plugin name',
        (tester) async {
      // `custom` is schema bookkeeping meaning "declared in implementation
      // instead". Rendering it would be worse than rendering nothing.
      await advanced.setEnabled(true);
      await pump(tester, shipped('crop_resize.json'), {'enabled': true});
      expect(readout(tester).map((r) => r.$1), isNot(contains('custom')));
      expect(find.text('custom'), findsNothing);
    });
  });
}
