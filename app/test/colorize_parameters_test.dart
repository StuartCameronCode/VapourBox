// The Colourisation pass's Dart model: its defaults and wire names must be
// the worker's (worker/src/models/colorize_parameters.rs), the converter must
// carry every field through the panel's dynamic form (where the model is the
// schema's method), and each model must name the add-on the worker insists on.
//
// Run with: flutter test test/colorize_parameters_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/colorize_parameters.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/processing_pipeline.dart';

void main() {
  test('defaults match the worker\'s and the schema\'s', () {
    const p = ColorizeParameters();
    expect(p.enabled, isFalse);
    expect(p.model, ColorizeModel.ddcolor);
    expect(p.ddcolorRenderSize, 512);
    expect(p.deoldifyRenderFactor, 21);
    expect(p.strength, 1.0);
    expect(p.temporalRadius, 2);
    // And an empty object decodes to them, as the worker's serde defaults do.
    expect(ColorizeParameters.fromJson(const {}).toJson(), p.toJson());

    final rust = File('../worker/src/models/colorize_parameters.rs').readAsStringSync();
    expect(rust, contains('fn default_ddcolor_size() -> i32 { 512 }'));
    expect(rust, contains('fn default_render_factor() -> i32 { 21 }'));
    expect(rust, contains('fn default_strength() -> f64 { 1.0 }'));
    expect(rust, contains('fn default_radius() -> i32 { 2 }'));

    final schema = jsonDecode(File('assets/filters/core/colorize.json').readAsStringSync())
        as Map<String, dynamic>;
    final params = schema['parameters'] as Map<String, dynamic>;
    expect(params['method']['default'], p.model.value);
    expect(params['ddcolorRenderSize']['default'], p.ddcolorRenderSize);
    expect(params['deoldifyRenderFactor']['default'], p.deoldifyRenderFactor);
    expect(params['strength']['default'], p.strength);
    expect(params['temporalRadius']['default'], p.temporalRadius);
    expect([for (final m in schema['methods'] as List) m['id']],
        [for (final m in ColorizeModel.values) m.value]);
  });

  test('wire names are the worker\'s', () {
    final json = const ColorizeParameters(model: ColorizeModel.deoldify).toJson();
    expect(json.keys.toSet(), {
      'enabled', 'model', 'ddcolorRenderSize', 'deoldifyRenderFactor', 'strength', 'temporalRadius',
    });
    expect(json['model'], 'deoldify');
    final rust = File('../worker/src/models/colorize_parameters.rs').readAsStringSync();
    for (final m in ColorizeModel.values) {
      expect(ColorizeParameters.fromJson({'model': m.value}).model, m);
      expect(rust, contains('#[serde(rename = "${m.value}")]'), reason: m.value);
    }
  });

  test('JSON round trip and the converter keep every field', () {
    const p = ColorizeParameters(
      enabled: true,
      model: ColorizeModel.deoldify,
      ddcolorRenderSize: 384,
      deoldifyRenderFactor: 30,
      strength: 0.65,
      temporalRadius: 0,
    );
    expect(ColorizeParameters.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>).toJson(),
        p.toJson());
    final dyn = ParameterConverter.fromColorize(p);
    expect(dyn.filterId, 'colorize');
    expect(dyn.values['method'], 'deoldify', reason: 'the model is the schema\'s method');
    expect(ParameterConverter.toColorize(dyn).toJson(), p.toJson());
    final pipeline = const ProcessingPipeline().copyWith(colorize: p);
    expect(ParameterConverter.toPipeline(ParameterConverter.fromPipeline(pipeline)).colorize.toJson(),
        p.toJson());
  });

  test('each model names the add-on the worker requires', () {
    expect(ColorizeModel.ddcolor.addonId, 'colorize-ddcolor');
    expect(ColorizeModel.deoldify.addonId, 'colorize-deoldify');
    for (final m in ColorizeModel.values) {
      final manifest = jsonDecode(File('assets/addons/${m.addonId}.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(manifest['requires'], contains('ai-runtime'), reason: m.addonId);
      expect(manifest['usageNote'], isNull, reason: '${m.addonId} is free for any use');
    }
    expect(colorizeAddonSelectedBy('colorize', false, const {'method': 'deoldify'}), isNull,
        reason: 'nothing to offer while the pass is off');
    expect(colorizeAddonSelectedBy('face_restore', true, const {}), isNull);
    expect(colorizeAddonSelectedBy('colorize', true, const {'method': 'deoldify'}), 'colorize-deoldify');
    expect(colorizeAddonSelectedBy('colorize', true, const {}), 'colorize-ddcolor');
  });

  test('the pass runs between Chroma Fixes and Color Correction, and toggles cleanly', () {
    const custom = ColorizeParameters(model: ColorizeModel.deoldify, strength: 0.4);
    final pipeline = const ProcessingPipeline()
        .copyWith(colorize: custom)
        .togglePass(PassType.colorize, true)
        .togglePass(PassType.chromaFixes, true)
        .togglePass(PassType.colorCorrection, true);
    final passes = pipeline.enabledPasses;
    expect(passes.indexOf(PassType.colorize), greaterThan(passes.indexOf(PassType.chromaFixes)));
    expect(passes.indexOf(PassType.colorize), lessThan(passes.indexOf(PassType.colorCorrection)));
    expect(pipeline.colorize.model, ColorizeModel.deoldify, reason: 'togglePass must not reset the model');
    expect(pipeline.colorize.strength, 0.4);
    expect(pipeline.getPassSummary(PassType.colorize), 'DeOldify Video');
    expect(pipeline.togglePass(PassType.colorize, false).getPassSummary(PassType.colorize), 'Off');
  });
}
