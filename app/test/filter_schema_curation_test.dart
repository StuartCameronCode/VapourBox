// Lints every built-in filter schema against the rules that keep the method
// dropdowns usable as filters are added. These are cheap assertions over the
// shipped JSON, and they exist because each rule has a silent failure mode:
// break one and the UI still renders, just wrongly.
//
// Rules and why:
//   - The first method is the resolved default (`methods.first` is what an unset
//     `method` falls back to), so marking it advancedOnly would default every
//     user to a method most of them can't see.
//   - At least one method must be visible in simple mode, or simple mode shows
//     an arbitrary single choice with no dropdown at all.
//   - Every method needs a description, because that is the only guidance shown
//     beside it in the dropdown. A dropdown of sixteen bare names is worse than
//     one of four.
//   - `visibleWhen` lives at `parameters.<id>.ui.visibleWhen` and nowhere else.
//     `ParameterDefinition` and `UiSection` do not declare the key, so a copy
//     written one level up (or on a section) is dropped at parse time and the
//     control is simply always visible. Eight schemas shipped that way, which
//     is how Chroma Fixes came to show its automatic-alignment sliders with
//     automatic alignment switched off.
//   - A condition must name something that exists. A key naming no parameter,
//     or a `method` condition naming no method, can never be satisfied, so the
//     control it guards is invisible forever — the same silent failure in the
//     other direction.
//
// Run with: flutter test test/filter_schema_curation_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/filter_schema.dart';

void main() {
  final manifest = (jsonDecode(
    File('assets/filters/manifest.json').readAsStringSync(),
  ) as List)
      .cast<String>();

  final rawSchemas = <String, Map<String, dynamic>>{
    for (final filename in manifest)
      filename: jsonDecode(
        File('assets/filters/core/$filename').readAsStringSync(),
      ) as Map<String, dynamic>,
  };

  final schemas = <FilterSchema>[
    for (final raw in rawSchemas.values) FilterSchema.fromJson(raw),
  ];

  test('the manifest lists every schema file', () {
    final onDisk = Directory('assets/filters/core')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.json'))
        .toSet();

    expect(onDisk.difference(manifest.toSet()), isEmpty,
        reason: 'a schema file exists but nothing loads it');
  });

  group('method curation', () {
    for (final schema in schemas) {
      test('${schema.id}: first method is never advanced-only', () {
        expect(schema.methods.first.advancedOnly, false,
            reason: '${schema.methods.first.id} is the default method, so '
                'hiding it in simple mode would default users to a method '
                'they cannot see');
      });

      test('${schema.id}: something is visible in simple mode', () {
        expect(schema.visibleMethods(showAdvanced: false), isNotEmpty);
      });

      test('${schema.id}: every method has guidance', () {
        for (final method in schema.methods) {
          expect(method.description?.trim() ?? '', isNotEmpty,
              reason: '${method.id} has no description, so the dropdown shows '
                  'a bare name with no hint of when to choose it');
        }
      });
    }
  });

  group('curation actually shortens the long dropdowns', () {
    // Pins the decisions made when advanced mode landed. Adding methods is
    // expected; letting a simple-mode dropdown grow without curating is not.
    // A count here going up means the curation was not extended along with the
    // new methods.
    const maxSimpleMethods = 4;

    for (final schema in schemas) {
      test('${schema.id}: at most $maxSimpleMethods methods in simple mode',
          () {
        final visible = schema.visibleMethods(showAdvanced: false);
        expect(visible.length, lessThanOrEqualTo(maxSimpleMethods),
            reason: 'simple mode offers ${visible.map((m) => m.id).toList()}; '
                'mark the specialist ones advancedOnly');
      });
    }

    test('dehalo hides its specialist and duplicated methods', () {
      final dehalo = schemas.firstWhere((s) => s.id == 'dehalo');
      expect(
        dehalo.visibleMethods(showAdvanced: false).map((m) => m.id),
        // HQDeringmod is visible because deringing is a distinct problem from
        // dehaloing, not a variant of it — this pass is named for both.
        ['dehalo_alpha', 'fine_dehalo', 'yahr', 'hq_deringmod'],
      );
      // Vinverse is offered by Chroma Fixes too; Fine Dehalo 2 is a follow-up
      // pass rather than a first choice.
      expect(dehalo.methods.length, 8);
    });

    test('the filters added from the gap analysis are behind advanced mode', () {
      // Each is an alternative for when the default is not the right tool, not
      // a better default — which is exactly what advanced mode is for.
      //
      // mClean is the one deliberate exception, and it spends the schema's last
      // simple-mode slot. It is the only candidate that is a *goal* — denoise,
      // restore detail, restore grain, behind one control — rather than another
      // mechanism, which is the distinction this whole lint exists to enforce.
      // Noise Reduction is now at the 4-method cap and cannot grow again
      // without something else moving behind advanced.
      final nr = schemas.firstWhere((s) => s.id == 'noise_reduction');
      expect(
        nr.visibleMethods(showAdvanced: false).map((m) => m.id),
        ['smdegrain', 'mc_temporal_denoise', 'qtgmc_builtin', 'mclean'],
      );
      // TemporalDegrain2 is the most-requested filter in the gap analysis and
      // is still advanced: 21 fps, a dozen interacting parameters, and three
      // values that break it outright. An expert asks for it by name; a novice
      // should never land on it by scrolling.
      for (final id in [
        'dfttest',
        'fft3dfilter',
        'ttempsmooth',
        'temporal_degrain2',
      ]) {
        expect(nr.getMethod(id)?.advancedOnly, true, reason: id);
      }

      // aWarpSharp2 is visible: it is a genuinely different mechanism from
      // LSFmod and CAS rather than another variant of them, and the pass only
      // offered two options.
      final sharpen = schemas.firstWhere((s) => s.id == 'sharpen');
      expect(sharpen.getMethod('awarpsharp2')?.advancedOnly, false);
      expect(sharpen.visibleMethods(showAdvanced: false).length, 3);
    });
  });

  group('conditional visibility is where the model can see it', () {
    // Both halves matter: a condition in the wrong place never hides anything,
    // and a condition naming something that does not exist never shows
    // anything. Neither fails loudly at runtime.
    rawSchemas.forEach((filename, raw) {
      final id = raw['id'] as String;
      final parameters = (raw['parameters'] as Map).cast<String, dynamic>();
      final methodIds = [
        for (final m in (raw['methods'] as List)) (m as Map)['id'] as String,
      ];
      final sections =
          ((raw['ui'] as Map?)?['sections'] as List?) ?? const <dynamic>[];

      test('$id: no parameter puts visibleWhen outside its ui block', () {
        final misplaced = [
          for (final entry in parameters.entries)
            if ((entry.value as Map).containsKey('visibleWhen')) entry.key,
        ];
        expect(misplaced, isEmpty,
            reason: 'ParameterDefinition has no visibleWhen field, so these '
                'conditions are dropped at parse time and the controls are '
                'always visible: $misplaced. Move each one into its `ui`.');
      });

      test('$id: no section carries a visibleWhen', () {
        final misplaced = [
          for (final s in sections)
            if ((s as Map).containsKey('visibleWhen')) s['title'],
        ];
        expect(misplaced, isEmpty,
            reason: 'UiSection has no visibleWhen field, so these sections are '
                'shown regardless: $misplaced. Put the condition on each '
                'parameter in the section instead.');
      });

      test('$id: every condition names something that exists', () {
        for (final entry in parameters.entries) {
          final ui = (entry.value as Map)['ui'] as Map?;
          final condition = ui?['visibleWhen'] as Map?;
          if (condition == null) continue;

          for (final key in condition.keys) {
            expect(parameters.keys, contains(key),
                reason: '${entry.key} is conditional on "$key", which is not '
                    'a parameter of this filter — it can never be satisfied');

            if (key != 'method') continue;
            final expected = condition[key];
            for (final value in expected is List ? expected : [expected]) {
              expect(methodIds, contains(value),
                  reason: '${entry.key} is conditional on method "$value", '
                      'which this filter does not offer');
            }
          }
        }
      });
    });
  });

  group('colour correction pairs each automatic control with its manual one', () {
    // The pass offers two adjustments that can be made automatically or by
    // hand — levels and white balance — and the automatic half used to sit in
    // its own "Automatic" section at the top, three groups away from the manual
    // half it supersedes. Each pair now shares a section, automatic first.
    final colour = schemas.firstWhere((s) => s.id == 'color_correction');
    final sections = colour.ui!.sections!;

    test('the sections pair them up', () {
      expect(sections.map((s) => '${s.title}${s.advancedOnly ? " (adv)" : ""}'),
          [
            'Brightness and colour',
            'Brightness and colour tuning (adv)',
            'Levels',
            'Levels tuning (adv)',
            'White balance',
            'Shadow detail',
          ]);

      final levels = sections.firstWhere((s) => s.title == 'Levels').parameters;
      expect(levels.indexOf('applyAutoLevels'),
          lessThan(levels.indexOf('applyLevels')),
          reason: 'the automatic control comes first — it is the one that '
              'supersedes the other');

      final wb =
          sections.firstWhere((s) => s.title == 'White balance').parameters;
      expect(wb.indexOf('applyAutoWhiteBalance'), lessThan(wb.indexOf('temperature')));
    });

    test('the automatic targets sit beside the switch that uses them', () {
      // 16/235 (broadcast) against 0/255 (full range) is the main choice
      // automatic levels offers, not a tuning detail — it was briefly moved into
      // the advanced section and immediately read as missing.
      final levels = sections.firstWhere((s) => s.title == 'Levels').parameters;
      expect(levels, containsAll(['autoLevelsBlack', 'autoLevelsWhite']));
      expect(sections.firstWhere((s) => s.title == 'Levels tuning').parameters,
          ['smoothLevels']);
    });

    test('the automatic switches say what they set', () {
      // Both are named for the adjustment, not for the symptom, so the group
      // heading and the switch agree and the words the user is looking for
      // ("levels", "white balance") are on the control itself.
      expect(colour.parameters['applyAutoLevels']!.ui!.label,
          'Set levels automatically');
      expect(colour.parameters['applyAutoWhiteBalance']!.ui!.label,
          'Set white balance automatically');
    });

    test('there is no method dropdown to mislead anyone', () {
      // It declared "Tweak" and "White Balance" as methods, but no parameter was
      // ever conditional on the choice, no model had a method field, and the
      // converter hardcoded 'tweak'. The dropdown rendered and changed nothing.
      expect(colour.methods, hasLength(1));
    });

    test('the manual levels points yield to the automatic measurement', () {
      for (final id in ['inputLow', 'inputHigh', 'outputLow', 'outputHigh']) {
        expect(colour.parameters[id]!.ui!.visibleWhen!['applyAutoLevels'], false,
            reason: '$id is superseded by automatic levels and must hide');
      }
      // Gamma is the exception, and deliberately so: automatic levels does not
      // touch the midtones, and this is the only place in the app to reach them.
      expect(colour.parameters['gamma']!.ui!.visibleWhen,
          {'applyLevels': true});
    });

    test('nothing carries a second enable checkbox', () {
      for (final entry in colour.parameters.entries) {
        expect(entry.value.optional ?? false, false, reason: entry.key);
      }
    });
  });

  group('a method dropdown has to change something', () {
    // Three schemas declared methods that gated nothing: Color Correction
    // ("Tweak" / "White Balance") and Crop & Resize ("standard" / "nnedi3_2x" /
    // "eedi3_2x"). In both, every control rendered whatever was selected, no
    // model had a `method` field, and the converter either hardcoded one value
    // or emitted none. The dropdown appeared, responded, and did nothing —
    // which is worse than no dropdown, because it teaches the user the panel
    // reacts to it. Crop & Resize was the sharper case: its real upscaler
    // choice is the `upscaleMethod` PARAMETER, so the dropdown was an inert
    // second copy of a control that works.
    rawSchemas.forEach((filename, raw) {
      final id = raw['id'] as String;
      final methods = (raw['methods'] as List).cast<Map<String, dynamic>>();
      if (methods.length < 2) return;

      final parameters = (raw['parameters'] as Map).cast<String, dynamic>();

      test('$id: at least one parameter is conditional on the method', () {
        final gated = parameters.entries.where((e) {
          final ui = (e.value as Map)['ui'] as Map?;
          return ((ui?['visibleWhen'] as Map?) ?? const {})
              .containsKey('method');
        });

        expect(gated, isNotEmpty,
            reason: 'the ${methods.length} methods of $id change nothing on '
                'screen — either gate parameters on the choice or declare one '
                'method, which suppresses the dropdown');
      });

      test('$id: a parameter only some methods use says so', () {
        // deblock's `quant1` was ungated while DCTFilter, which does not take
        // it, was one of the three methods offered — so the panel showed a
        // control that could not do anything.
        for (final entry in parameters.entries) {
          final param = entry.value as Map;
          final ui = param['ui'] as Map?;
          if (ui?['hidden'] == true) continue;

          final users = methods
              .where((m) => (m['parameters'] as List).contains(entry.key))
              .map((m) => m['id'] as String)
              .toSet();
          if (users.isEmpty || users.length == methods.length) continue;

          final condition = (ui?['visibleWhen'] as Map?)?['method'];
          expect(condition, isNotNull,
              reason: '${entry.key} is used by ${users.toList()} but shown for '
                  'every method');

          final declared = <String>{
            ...(condition is List ? condition.cast<String>() : [condition as String]),
          };
          expect(declared, users,
              reason: '${entry.key} is shown for ${declared.toList()} but used '
                  'by ${users.toList()}');
        }
      });
    });

    rawSchemas.forEach((filename, raw) {
      final id = raw['id'] as String;
      final sections =
          ((raw['ui'] as Map?)?['sections'] as List?) ?? const <dynamic>[];

      test('$id: no section exists only to hold the method', () {
        // The panel draws the dropdown itself and always skips the `method`
        // parameter, so such a section renders nothing — and now that sections
        // print their titles, it would have printed a heading with no content
        // had the panel not skipped empty ones.
        for (final section in sections.cast<Map<String, dynamic>>()) {
          expect(section['parameters'], isNot(['method']),
              reason: '"${section['title']}" in $id renders nothing');
        }
      });
    });
  });

  group('chroma fixes stays grouped by symptom', () {
    // The pass covers five unrelated repairs, and the panel renders sections in
    // schema order with no headings in simple mode — so this order IS the
    // grouping the user sees. Each repair's switch comes first, its everyday
    // controls next, and its thresholds in an advanced-only section straight
    // after. Reordering these rows shuffles unrelated sliders together again.
    final chroma = schemas.firstWhere((s) => s.id == 'chroma_fixes');
    final sections = chroma.ui!.sections!;

    test('the sections are one repair at a time, tuning after each', () {
      expect(sections.map((s) => '${s.title}${s.advancedOnly ? " (adv)" : ""}'),
          [
            'Colour alignment',
            'Automatic alignment tuning (adv)',
            'Colour bleeding',
            'Colour bleeding tuning (adv)',
            'Dot crawl',
            // Two separate tuning sections, not one: several labels repeat
            // between LUTDeCrawl and DeDot ("Colour threshold"), and the
            // heading is the only thing that says which filter a slider
            // belongs to.
            'Dot crawl tuning (adv)',
            'Dot crawl (across frames) tuning (adv)',
            'Rainbowing',
            'Rainbow tuning (adv)',
            'Rainbow (across frames) tuning (adv)',
            'Chroma combing',
            'Chroma combing tuning (adv)',
          ]);
    });

    test('every switch is reachable in simple mode', () {
      // A repair whose switch sat in an advanced-only section could be left on
      // by a preset — VHS Cleanup enables DeDot, Anime DVD enables two — with
      // no way for a simple-mode user to see or clear it.
      final simpleParams = sections
          .where((s) => !s.advancedOnly)
          .expand((s) => s.parameters)
          .toSet();
      final switches = chroma.parameters.keys.where((k) => k.startsWith('apply'));

      expect(switches, isNotEmpty);
      for (final id in switches) {
        expect(simpleParams, contains(id), reason: '$id is only reachable in '
            'advanced mode, so a preset could enable it invisibly');
      }
    });

    test('every control below a switch is gated on it', () {
      // The complaint this schema was rewritten for: sliders belonging to a
      // repair that is switched off, sitting on screen with nothing to do.
      for (final entry in chroma.parameters.entries) {
        if (entry.key == 'enabled' || entry.key.startsWith('apply')) continue;

        final condition = entry.value.ui?.visibleWhen;
        expect(condition, isNotNull,
            reason: '${entry.key} is always visible — gate it on the '
                'apply* switch of the repair it belongs to');
        expect(condition!.keys.any((k) => k.startsWith('apply')), isTrue,
            reason: '${entry.key} is conditional on ${condition.keys}, none of '
                'which is a repair switch');
      }
    });

    test('the manual alignment sliders yield to the automatic measurement', () {
      // Both are emitted into the script when both are set, and the automatic
      // pass runs first — so a manual shift on top of it double-corrects.
      // ScriptGenerator drops the manual shift when automatic is on
      // (test_150 in worker/tests/filter_integration_test.rs) and
      // ParameterConverter.toChromaFixes agrees, so the controls hide rather
      // than lie about what the render will do.
      for (final id in ['applyChromaShift', 'chromaShiftH', 'chromaShiftV']) {
        expect(chroma.parameters[id]!.ui!.visibleWhen!['applyAutoChroma'], false,
            reason: '$id must disappear while automatic alignment is on');
      }
    });

    test('nothing carries a second enable checkbox', () {
      // Every control here already sits behind an apply* switch. `optional`
      // would add a checkbox of its own promising "leave it out and the plugin
      // default applies" — which is not what happens: the worker sends a value
      // for all of these regardless.
      for (final entry in chroma.parameters.entries) {
        expect(entry.value.optional ?? false, false, reason: entry.key);
      }
    });
  });
}
