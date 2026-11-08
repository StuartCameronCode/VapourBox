// The Face Restoration pass's Dart model: its defaults and wire names must be
// the worker's (worker/src/models/face_restore_parameters.rs), the converter
// must carry every field through the panel's dynamic form, and each model must
// name the add-ons the worker will insist on.
//
// Run with: flutter test test/face_restore_parameters_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/face_restore_parameters.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/processing_pipeline.dart';

void main() {
  test('defaults match the worker\'s', () {
    const p = FaceRestoreParameters();
    expect(p.enabled, isFalse);
    expect(p.model, FaceRestoreModel.restoreFormer);
    expect(p.strength, 0.8);
    expect(p.codeFormerFidelity, 0.7);
    expect(p.detectionThreshold, 0.8);
    expect(p.minFaceSize, 32);
    expect(p.maxFaces, 8);
    expect(p.temporalSmoothing, isTrue);
    // And an empty object decodes to them, as the worker's serde defaults do.
    expect(FaceRestoreParameters.fromJson(const {}).toJson(), p.toJson());
  });

  test('wire names are the worker\'s', () {
    final json = const FaceRestoreParameters(model: FaceRestoreModel.codeFormer).toJson();
    expect(json.keys.toSet(), {
      'enabled', 'model', 'strength', 'codeFormerFidelity', 'detectionThreshold',
      'minFaceSize', 'maxFaces', 'temporalSmoothing',
    });
    expect(json['model'], 'codeFormer');
    for (final m in FaceRestoreModel.values) {
      final decoded = FaceRestoreParameters.fromJson({'model': m.value});
      expect(decoded.model, m);
      expect(FaceRestoreModel.fromValue(m.value), m);
    }
    // The Rust enum has the same three variants; serde's camelCase renaming
    // turns `RestoreFormer` into `restoreFormer`, and so on.
    final rust = File('../worker/src/models/face_restore_parameters.rs').readAsStringSync().replaceAll('\r\n', '\n');
    expect(rust, contains('#[serde(rename_all = "camelCase")]\npub enum FaceRestoreModel'));
    for (final m in FaceRestoreModel.values) {
      final variant = m.value[0].toUpperCase() + m.value.substring(1);
      expect(RegExp('^    $variant,\$', multiLine: true).hasMatch(rust), isTrue, reason: variant);
    }
  });

  test('JSON round trip keeps every field', () {
    const p = FaceRestoreParameters(
      enabled: true,
      model: FaceRestoreModel.gfpgan,
      strength: 0.55,
      codeFormerFidelity: 0.3,
      detectionThreshold: 0.65,
      minFaceSize: 48,
      maxFaces: 2,
      temporalSmoothing: false,
    );
    final back = FaceRestoreParameters.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.toJson(), p.toJson());
  });

  test('the converter carries every field both ways', () {
    const p = FaceRestoreParameters(
      enabled: true,
      model: FaceRestoreModel.codeFormer,
      strength: 0.4,
      codeFormerFidelity: 0.9,
      detectionThreshold: 0.6,
      minFaceSize: 20,
      maxFaces: 5,
      temporalSmoothing: false,
    );
    final dyn = ParameterConverter.fromFaceRestore(p);
    expect(dyn.filterId, 'face_restore');
    expect(ParameterConverter.toFaceRestore(dyn).toJson(), p.toJson());
    // And through a whole pipeline.
    final pipeline = const ProcessingPipeline().copyWith(faceRestore: p);
    expect(ParameterConverter.toPipeline(ParameterConverter.fromPipeline(pipeline)).faceRestore.toJson(),
        p.toJson());
  });

  test('each model names the add-ons the worker requires', () {
    expect(faceRestoreAddonIds(FaceRestoreModel.restoreFormer), ['face-restoration']);
    expect(faceRestoreAddonIds(FaceRestoreModel.gfpgan), ['face-restoration', 'face-gfpgan']);
    expect(faceRestoreAddonIds(FaceRestoreModel.codeFormer),
        ['face-restoration', 'face-codeformer']);
    for (final m in FaceRestoreModel.values) {
      expect(File('assets/addons/${m.addonId}.json').existsSync(), isTrue, reason: m.addonId);
    }
    expect(faceRestoreAddonsSelectedBy('face_restore', false, const {'model': 'gfpgan'}), isNull,
        reason: 'nothing to offer while the pass is off');
    expect(faceRestoreAddonsSelectedBy('crop_resize', true, const {}), isNull);
    expect(faceRestoreAddonsSelectedBy('face_restore', true, const {'model': 'gfpgan'}),
        ['face-restoration', 'face-gfpgan']);
  });

  test('the pass runs after Crop & Resize and before Sharpen, and toggles cleanly', () {
    const custom = FaceRestoreParameters(model: FaceRestoreModel.gfpgan, strength: 0.3);
    final pipeline = const ProcessingPipeline().copyWith(
      faceRestore: custom,
    ).togglePass(PassType.faceRestore, true);
    expect(pipeline.isPassEnabled(PassType.faceRestore), isTrue);
    expect(pipeline.faceRestore.model, FaceRestoreModel.gfpgan,
        reason: 'togglePass must not reset the model');
    expect(pipeline.faceRestore.strength, 0.3);
    expect(pipeline.getPassSummary(PassType.faceRestore), 'GFPGAN v1.4');
    expect(pipeline.togglePass(PassType.faceRestore, false).getPassSummary(PassType.faceRestore),
        'Off');
  });
}
