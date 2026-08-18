// Every setting a built-in preset turns on must be a setting the user can find.
//
// A preset is the main way settings arrive without anyone touching a control, so
// it is also the main way a *hidden* setting arrives. The panel hides a parameter
// whose `visibleWhen` is unsatisfied and skips one that no section lists, and
// neither reports anything — so a preset can enable a filter the user cannot see,
// cannot adjust and cannot switch off, while the pass summary says nothing about
// it. That is exactly what the 2026-08-18 review found in the panels themselves,
// and the presets are the other half of it.
//
// The check walks each built-in preset's enabled passes through the real
// converter — the same call the settings panel makes — and asserts that anything
// differing from the schema default is actually on screen for that preset's own
// state.
//
// Two exemptions, both deliberate:
//
//   * A value hidden **only** by a `method` condition. Carrying another method's
//     value is normal and sometimes intended: `builtin-fast` selects Bwdif and
//     still sets a QTGMC preset, so that switching the method in the UI lands
//     somewhere sensible. Nothing is applied, so nothing is misreported.
//   * The allowlist below, for values in advanced-only sections. Those are
//     visible, just not in simple mode, and bundling expert settings is what a
//     quality tier is for — but each one is named here so that adding another is
//     a decision rather than a drift.
//
// Run with: flutter test test/preset_visibility_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/processing_preset.dart';

/// Values a built-in preset may set that only appear in advanced mode.
///
/// All three are QTGMC's, in a pass whose own control (the QTGMC preset) is
/// visible and whose summary names it — so the user can see *that* the tier is
/// doing something expert, just not each knob.
const _advancedAllowed = {
  'deinterlace.sourceMatch', // High Quality: the fidelity mode it is named for
  'deinterlace.lossless', // ditto, and only meaningful alongside sourceMatch
  'deinterlace.chromaUpsampleFix', // DV Camcorder: 4:2:0 chroma is its whole problem
};

/// The pass-to-schema mapping the settings panel uses.
/// Mirrors `PassSettingsInline._getFilterId`.
const _filterIds = {
  PassType.deinterlace: 'deinterlace',
  PassType.descratch: 'descratch',
  PassType.spotless: 'spotless',
  PassType.noiseReduction: 'noise_reduction',
  PassType.chromaDenoise: 'chroma_denoise',
  PassType.dehalo: 'dehalo',
  PassType.deblock: 'deblock',
  PassType.deband: 'deband',
  PassType.sharpen: 'sharpen',
  PassType.antiAlias: 'anti_alias',
  PassType.stabilize: 'stabilize',
  PassType.geometry: 'geometry',
  PassType.chromaFixes: 'chroma_fixes',
  PassType.colorCorrection: 'color_correction',
  PassType.cropResize: 'crop_resize',
  PassType.grain: 'grain',
  PassType.subtitles: 'subtitles',
  PassType.edgeRepair: 'edge_repair',
  PassType.deflicker: 'deflicker',
  PassType.ghostRemoval: 'ghost_removal',
  PassType.frameRate: 'frame_rate',
};

FilterSchema _schema(String id) => FilterSchema.fromJson(
      jsonDecode(File('assets/filters/core/$id.json').readAsStringSync())
          as Map<String, dynamic>,
    );

/// Schema defaults and model defaults are asserted equal elsewhere
/// (`schema_converter_integration_test`), so either side can stand for "the user
/// did not choose this". Numbers arrive as int or double depending on the route.
bool _isDefault(dynamic value, dynamic defaultValue) =>
    value == defaultValue ||
    (value is num && defaultValue is num &&
        value.toDouble() == defaultValue.toDouble()) ||
    value.toString() == defaultValue.toString();

void main() {
  final schemas = <String, FilterSchema>{
    for (final id in _filterIds.values) id: _schema(id),
  };

  for (final preset in ProcessingPreset.builtInPresets()) {
    group(preset.id, () {
      final dynamic_ = ParameterConverter.fromPipeline(preset.pipeline);

      for (final pass in preset.pipeline.enabledPasses) {
        final filterId = _filterIds[pass];

        test('${filterId ?? pass.name}: every setting it changes is reachable',
            () {
          expect(filterId, isNotNull,
              reason: '$pass has no schema, so its settings have no UI at all');
          final schema = schemas[filterId]!;
          final params = dynamic_.get(filterId!);
          expect(params, isNotNull,
              reason: 'the converter does not know $filterId, so the panel '
                  'would show schema defaults instead of the preset');

          final sectioned = <String>{
            for (final s in schema.ui?.sections ?? const <UiSection>[])
              ...s.parameters,
          };
          final advancedOnly = <String>{
            for (final s in schema.ui?.sections ?? const <UiSection>[])
              if (s.advancedOnly) ...s.parameters,
          };

          for (final entry in params!.values.entries) {
            final key = entry.key;
            final definition = schema.parameters[key];
            if (definition == null) continue; // worker-only field
            if (key == 'enabled' || key == 'method') continue;
            if (definition.ui?.hidden == true) continue; // owned elsewhere in the UI
            if (entry.value == null) continue;
            if (_isDefault(entry.value, definition.defaultValue)) continue;

            expect(sectioned, contains(key),
                reason: '$filterId.$key is set to ${entry.value} but no section '
                    'lists it, so the panel never renders it');

            final condition = definition.ui?.visibleWhen ?? const {};
            final hiddenOnlyByMethod =
                condition.keys.isNotEmpty &&
                    condition.keys.every((k) => k == 'method');
            if (!hiddenOnlyByMethod) {
              for (final gate in condition.entries) {
                final current = params.values[gate.key];
                final expected = gate.value;
                final satisfied = expected is List
                    ? expected.contains(current)
                    : current == expected;
                expect(satisfied, isTrue,
                    reason: '$filterId.$key is set to ${entry.value} but the '
                        'panel hides it while ${gate.key} is $current — the '
                        'preset would apply a setting with no control on screen');
              }
            }

            if (advancedOnly.contains(key)) {
              expect(_advancedAllowed, contains('$filterId.$key'),
                  reason: '$filterId.$key is set to ${entry.value} but only '
                      'appears in advanced mode. Either move the control into a '
                      'simple-mode section or add it to _advancedAllowed with a '
                      'reason');
            }
          }
        });
      }
    });
  }

  test('the advanced allowlist has no stale entries', () {
    // A control moved out of an advanced section, or a preset that stopped
    // setting it, should shrink this list rather than leave it asserting
    // nothing.
    final used = <String>{};
    for (final preset in ProcessingPreset.builtInPresets()) {
      final dynamic_ = ParameterConverter.fromPipeline(preset.pipeline);
      for (final pass in preset.pipeline.enabledPasses) {
        final filterId = _filterIds[pass];
        if (filterId == null) continue;
        final schema = schemas[filterId]!;
        final params = dynamic_.get(filterId);
        if (params == null) continue;
        final advancedOnly = <String>{
          for (final s in schema.ui?.sections ?? const <UiSection>[])
            if (s.advancedOnly) ...s.parameters,
        };
        for (final entry in params.values.entries) {
          final definition = schema.parameters[entry.key];
          if (definition == null || definition.ui?.hidden == true) continue;
          if (entry.value == null ||
              _isDefault(entry.value, definition.defaultValue)) continue;
          if (advancedOnly.contains(entry.key)) used.add('$filterId.${entry.key}');
        }
      }
    }

    expect(used, _advancedAllowed);
  });
}
