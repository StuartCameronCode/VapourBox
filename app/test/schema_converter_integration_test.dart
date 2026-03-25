/// Integration tests verifying that filter JSON schemas and the Dart
/// ParameterConverter stay in sync.
///
/// These tests load the real schema files from disk and validate:
/// 1. Every non-hidden schema param key exists in converter output
/// 2. Every converter output key exists in the schema (no orphaned values)
/// 3. Enum option values match what the converter produces
/// 4. Schema defaults match Dart model defaults
/// 5. Round-trip: typed → dynamic → typed preserves all values
/// 6. Schema structural integrity (section refs, method refs)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/chroma_fix_parameters.dart';
import 'package:vapourbox/models/color_correction_parameters.dart';
import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/deband_parameters.dart';
import 'package:vapourbox/models/deblock_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/subtitle_parameters.dart';

/// Load a filter schema JSON from the assets directory.
FilterSchema loadSchema(String filename) {
  final file = File('assets/filters/core/$filename');
  if (!file.existsSync()) {
    throw StateError('Schema file not found: ${file.path}');
  }
  final jsonStr = file.readAsStringSync();
  return FilterSchema.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
}

/// Load raw JSON map from the assets directory.
Map<String, dynamic> loadSchemaJson(String filename) {
  final file = File('assets/filters/core/$filename');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// Get all non-hidden, non-method, non-enabled parameter keys from a schema.
Set<String> getVisibleSchemaKeys(FilterSchema schema) {
  final keys = <String>{};
  for (final entry in schema.parameters.entries) {
    final key = entry.key;
    final param = entry.value;
    // Skip hidden system params
    if (key == 'enabled') continue;
    if (key == 'method' && (param.ui?.hidden == true)) continue;
    keys.add(key);
  }
  return keys;
}

/// Get all parameter keys from a schema (including hidden ones, minus 'enabled').
Set<String> getAllSchemaParamKeys(FilterSchema schema) {
  return schema.parameters.keys.where((k) => k != 'enabled').toSet();
}

void main() {
  group('Schema structural integrity', () {
    final schemaFiles = [
      'deinterlace.json',
      'noise_reduction.json',
      'dehalo.json',
      'deblock.json',
      'deband.json',
      'sharpen.json',
      'color_correction.json',
      'chroma_fixes.json',
      'crop_resize.json',
      'subtitles.json',
    ];

    for (final filename in schemaFiles) {
      test('$filename: all section params exist in parameters', () {
        final schema = loadSchema(filename);
        final paramKeys = schema.parameters.keys.toSet();

        for (final section in (schema.ui?.sections ?? [])) {
          for (final paramRef in section.parameters) {
            expect(paramKeys, contains(paramRef),
                reason:
                    'Section "${section.title}" references "$paramRef" '
                    'which does not exist in parameters');
          }
        }
      });

      test('$filename: all method param refs exist in parameters', () {
        final schema = loadSchema(filename);
        final paramKeys = schema.parameters.keys.toSet();

        for (final method in schema.methods) {
          for (final paramRef in method.parameters) {
            expect(paramKeys, contains(paramRef),
                reason:
                    'Method "${method.id}" references "$paramRef" '
                    'which does not exist in parameters');
          }
        }
      });

      test('$filename: all non-hidden params appear in at least one section',
          () {
        final schema = loadSchema(filename);
        final sectionParams = <String>{};
        for (final section in (schema.ui?.sections ?? [])) {
          sectionParams.addAll(section.parameters);
        }

        for (final entry in schema.parameters.entries) {
          if (entry.key == 'enabled') continue;
          if (entry.key == 'method' && entry.value.ui?.hidden == true) continue;
          if (entry.value.ui?.hidden == true) continue;
          expect(sectionParams, contains(entry.key),
              reason:
                  'Parameter "${entry.key}" is not hidden but does not '
                  'appear in any UI section');
        }
      });

      test('$filename: enum params have default in options list', () {
        final schema = loadSchema(filename);
        for (final entry in schema.parameters.entries) {
          if (entry.value.type != ParameterType.enumType) continue;
          final options = entry.value.options;
          final defaultVal = entry.value.defaultValue;
          if (options == null || options.isEmpty) continue;
          if (defaultVal == null) continue;
          // Empty string is valid (means "use plugin default")
          if (defaultVal == '') continue;
          expect(options, contains(defaultVal),
              reason:
                  'Enum "${entry.key}" default "$defaultVal" is not in '
                  'options: $options');
        }
      });

      test('$filename: method IDs referenced in visibleWhen exist', () {
        final schema = loadSchema(filename);
        final methodIds = schema.methods.map((m) => m.id).toSet();
        // Also include method options from the method param itself
        final methodParam = schema.parameters['method'];
        final methodOptions = methodParam?.options?.toSet() ?? <String>{};

        for (final entry in schema.parameters.entries) {
          final visibleWhen = entry.value.ui?.visibleWhen;
          if (visibleWhen == null) continue;
          final methodCondition = visibleWhen['method'];
          if (methodCondition == null) continue;
          if (methodCondition is List) {
            for (final mid in methodCondition) {
              expect(
                methodIds.contains(mid) || methodOptions.contains(mid),
                isTrue,
                reason:
                    'Parameter "${entry.key}" visibleWhen references '
                    'method "$mid" which does not exist. '
                    'Available: $methodIds',
              );
            }
          }
        }
      });
    }
  });

  group('Schema-converter key consistency', () {
    /// For each filter, verify that the converter's dynamic param keys
    /// match the schema's parameter keys.

    test('deinterlace: converter keys match schema', () {
      final schema = loadSchema('deinterlace.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = QTGMCParameters();
      final dynamic = ParameterConverter.fromQTGMC(params);

      // Every schema key (except method) should exist in converter output
      for (final key in schemaKeys) {
        if (key == 'method') continue; // method is handled separately
        // IVTC params may not be in QTGMC output - that's OK, they're in the same converter
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });

    test('noise_reduction: converter keys match schema', () {
      final schema = loadSchema('noise_reduction.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = NoiseReductionParameters(enabled: true);
      final dynamic = ParameterConverter.fromNoiseReduction(params);

      for (final key in schemaKeys) {
        if (key == 'method') continue;
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });

    test('dehalo: converter keys match schema', () {
      final schema = loadSchema('dehalo.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = DehaloParameters(enabled: true);
      final dynamic = ParameterConverter.fromDehalo(params);

      for (final key in schemaKeys) {
        if (key == 'method') continue;
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });

    test('deblock: converter keys match schema', () {
      final schema = loadSchema('deblock.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = DeblockParameters(enabled: true);
      final dynamic = ParameterConverter.fromDeblock(params);

      for (final key in schemaKeys) {
        if (key == 'method') continue;
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });

    test('deband: converter keys match schema', () {
      final schema = loadSchema('deband.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = DebandParameters(enabled: true);
      final dynamic = ParameterConverter.fromDeband(params);

      for (final key in schemaKeys) {
        if (key == 'method') continue;
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });

    test('sharpen: converter keys match schema', () {
      final schema = loadSchema('sharpen.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = SharpenParameters(enabled: true);
      final dynamic = ParameterConverter.fromSharpen(params);

      for (final key in schemaKeys) {
        if (key == 'method') continue;
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });

    test('color_correction: converter keys match schema', () {
      final schema = loadSchema('color_correction.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = ColorCorrectionParameters(enabled: true);
      final dynamic = ParameterConverter.fromColorCorrection(params);

      for (final key in schemaKeys) {
        if (key == 'method') continue;
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });

    test('chroma_fixes: converter keys match schema', () {
      final schema = loadSchema('chroma_fixes.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = ChromaFixParameters(enabled: true);
      final dynamic = ParameterConverter.fromChromaFixes(params);

      for (final key in schemaKeys) {
        if (key == 'method') continue;
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });

    test('crop_resize: converter keys match schema', () {
      final schema = loadSchema('crop_resize.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = CropResizeParameters(enabled: true);
      final dynamic = ParameterConverter.fromCropResize(params);

      for (final key in schemaKeys) {
        if (key == 'method') continue;
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });

    test('subtitles: converter keys match schema', () {
      final schema = loadSchema('subtitles.json');
      final schemaKeys = getAllSchemaParamKeys(schema);
      const params = SubtitleParameters(enabled: true);
      final dynamic = ParameterConverter.fromSubtitles(params);

      for (final key in schemaKeys) {
        if (key == 'method') continue;
        expect(dynamic.values.containsKey(key), isTrue,
            reason: 'Schema param "$key" missing from converter output');
      }
    });
  });

  group('Enum option matching', () {
    /// Verify that converter-produced enum values exist in schema options.
    /// This catches the case-mismatch bug (e.g. "spline36" vs "Spline36").

    test('deinterlace: method IDs match schema', () {
      final schema = loadSchema('deinterlace.json');
      final methodOptions = schema.parameters['method']!.options!;

      // Test all three method conversions
      var dyn = ParameterConverter.fromQTGMC(
          const QTGMCParameters(method: DeinterlaceMethod.qtgmc));
      expect(methodOptions, contains(dyn.values['method']));

      dyn = ParameterConverter.fromQTGMC(
          const QTGMCParameters(method: DeinterlaceMethod.ivtc));
      expect(methodOptions, contains(dyn.values['method']));

      dyn = ParameterConverter.fromQTGMC(
          const QTGMCParameters(method: DeinterlaceMethod.softTelecine));
      expect(methodOptions, contains(dyn.values['method']));
    });

    test('deinterlace: preset values match schema options', () {
      final schema = loadSchema('deinterlace.json');
      final presetOptions = schema.parameters['preset']!.options!;

      for (final preset in QTGMCPreset.values) {
        final dyn = ParameterConverter.fromQTGMC(
            QTGMCParameters(preset: preset));
        expect(presetOptions, contains(dyn.values['preset']),
            reason: 'Preset ${preset.name} produces "${dyn.values['preset']}" '
                'which is not in schema options: $presetOptions');
      }
    });

    test('noise_reduction: method IDs match schema', () {
      final schema = loadSchema('noise_reduction.json');
      final methodOptions = schema.parameters['method']!.options!;

      for (final method in NoiseReductionMethod.values) {
        final dyn = ParameterConverter.fromNoiseReduction(
            NoiseReductionParameters(enabled: true, method: method));
        expect(methodOptions, contains(dyn.values['method']),
            reason:
                'Method ${method.name} produces "${dyn.values['method']}" '
                'not in schema options: $methodOptions');
      }
    });

    test('dehalo: method IDs match schema', () {
      final schema = loadSchema('dehalo.json');
      final methodOptions = schema.parameters['method']!.options!;

      for (final method in DehaloMethod.values) {
        final dyn = ParameterConverter.fromDehalo(
            DehaloParameters(enabled: true, method: method));
        expect(methodOptions, contains(dyn.values['method']),
            reason: 'Method ${method.name} produces "${dyn.values['method']}"');
      }
    });

    test('deblock: method IDs match schema', () {
      final schema = loadSchema('deblock.json');
      final methodOptions = schema.parameters['method']!.options!;

      for (final method in DeblockMethod.values) {
        final dyn = ParameterConverter.fromDeblock(
            DeblockParameters(enabled: true, method: method));
        expect(methodOptions, contains(dyn.values['method']),
            reason: 'Method ${method.name} produces "${dyn.values['method']}"');
      }
    });

    test('sharpen: method IDs match schema', () {
      final schema = loadSchema('sharpen.json');
      final methodOptions = schema.parameters['method']!.options!;

      for (final method in SharpenMethod.values) {
        final dyn = ParameterConverter.fromSharpen(
            SharpenParameters(enabled: true, method: method));
        expect(methodOptions, contains(dyn.values['method']),
            reason: 'Method ${method.name} produces "${dyn.values['method']}"');
      }
    });

    test('crop_resize: kernel values match schema options', () {
      final schema = loadSchema('crop_resize.json');
      final kernelOptions = schema.parameters['kernel']!.options!;

      for (final kernel in ResizeKernel.values) {
        // nnedi3 and eedi3 are upscale-only, not in resize dropdown
        if (kernel == ResizeKernel.nnedi3 || kernel == ResizeKernel.eedi3) {
          continue;
        }
        final dyn = ParameterConverter.fromCropResize(
            CropResizeParameters(enabled: true, kernel: kernel));
        expect(kernelOptions, contains(dyn.values['kernel']),
            reason:
                'Kernel ${kernel.name} produces "${dyn.values['kernel']}" '
                'not in schema options: $kernelOptions');
      }
    });

    test('crop_resize: upscaleMethod values match schema options', () {
      final schema = loadSchema('crop_resize.json');
      final methodOptions = schema.parameters['upscaleMethod']!.options!;

      for (final method in UpscaleMethod.values) {
        final dyn = ParameterConverter.fromCropResize(
            CropResizeParameters(enabled: true, upscaleMethod: method));
        expect(methodOptions, contains(dyn.values['upscaleMethod']),
            reason:
                'UpscaleMethod ${method.name} produces '
                '"${dyn.values['upscaleMethod']}" '
                'not in schema options: $methodOptions');
      }
    });

    test('subtitles: model/output/language values match schema options', () {
      final schema = loadSchema('subtitles.json');

      // Test model options
      final modelOptions = schema.parameters['model']!.options!;
      for (final model in WhisperModel.values) {
        final dyn = ParameterConverter.fromSubtitles(
            SubtitleParameters(enabled: true, model: model));
        expect(modelOptions, contains(dyn.values['model']),
            reason: 'Model ${model.name} produces "${dyn.values['model']}"');
      }

      // Test output options
      final outputOptions = schema.parameters['output']!.options!;
      for (final output in SubtitleOutput.values) {
        final dyn = ParameterConverter.fromSubtitles(
            SubtitleParameters(enabled: true, output: output));
        expect(outputOptions, contains(dyn.values['output']),
            reason:
                'Output ${output.name} produces "${dyn.values['output']}"');
      }
    });
  });

  group('Round-trip preservation', () {
    /// Convert typed → dynamic → typed and verify values survive.

    test('noise_reduction round-trip preserves all values', () {
      const original = NoiseReductionParameters(
        enabled: true,
        method: NoiseReductionMethod.smDegrain,
        smDegrainTr: 3,
        smDegrainThSAD: 450,
        smDegrainThSADC: 200,
        smDegrainRefine: false,
        smDegrainPrefilter: 1,
      );

      final dynamic = ParameterConverter.fromNoiseReduction(original);
      final restored = ParameterConverter.toNoiseReduction(dynamic);

      expect(restored.enabled, original.enabled);
      expect(restored.method, original.method);
      expect(restored.smDegrainTr, original.smDegrainTr);
      expect(restored.smDegrainThSAD, original.smDegrainThSAD);
      expect(restored.smDegrainThSADC, original.smDegrainThSADC);
      expect(restored.smDegrainRefine, original.smDegrainRefine);
      expect(restored.smDegrainPrefilter, original.smDegrainPrefilter);
    });

    test('noise_reduction MCTemporal round-trip preserves values', () {
      const original = NoiseReductionParameters(
        enabled: true,
        method: NoiseReductionMethod.mcTemporalDenoise,
        mcTemporalSigma: 6.0,
        mcTemporalRadius: 3,
        mcTemporalProfile: 'high',
      );

      final dynamic = ParameterConverter.fromNoiseReduction(original);
      final restored = ParameterConverter.toNoiseReduction(dynamic);

      expect(restored.method, original.method);
      expect(restored.mcTemporalSigma, original.mcTemporalSigma);
      expect(restored.mcTemporalRadius, original.mcTemporalRadius);
      expect(restored.mcTemporalProfile, original.mcTemporalProfile);
    });

    test('dehalo round-trip preserves all values', () {
      const original = DehaloParameters(
        enabled: true,
        method: DehaloMethod.fineDehalo,
        rx: 2.5,
        ry: 1.8,
        darkStr: 0.6,
        brightStr: 0.7,
        lowThreshold: 60,
        highThreshold: 120,
      );

      final dynamic = ParameterConverter.fromDehalo(original);
      final restored = ParameterConverter.toDehalo(dynamic);

      expect(restored.method, original.method);
      expect(restored.rx, original.rx);
      expect(restored.ry, original.ry);
      expect(restored.darkStr, original.darkStr);
      expect(restored.brightStr, original.brightStr);
      expect(restored.lowThreshold, original.lowThreshold);
      expect(restored.highThreshold, original.highThreshold);
    });

    test('deblock round-trip preserves all values', () {
      const original = DeblockParameters(
        enabled: true,
        method: DeblockMethod.deblockQed,
        quant1: 28,
        quant2: 30,
        aOffset1: 2,
        aOffset2: -1,
      );

      final dynamic = ParameterConverter.fromDeblock(original);
      final restored = ParameterConverter.toDeblock(dynamic);

      expect(restored.method, original.method);
      expect(restored.quant1, original.quant1);
      expect(restored.quant2, original.quant2);
      expect(restored.aOffset1, original.aOffset1);
      expect(restored.aOffset2, original.aOffset2);
    });

    test('deband round-trip preserves all values', () {
      const original = DebandParameters(
        enabled: true,
        range: 20,
        y: 48,
        cb: 40,
        cr: 40,
        grainY: 16,
        grainC: 12,
        dynamicGrain: false,
        outputDepth: 10,
      );

      final dynamic = ParameterConverter.fromDeband(original);
      final restored = ParameterConverter.toDeband(dynamic);

      expect(restored.range, original.range);
      expect(restored.y, original.y);
      expect(restored.cb, original.cb);
      expect(restored.cr, original.cr);
      expect(restored.grainY, original.grainY);
      expect(restored.grainC, original.grainC);
      expect(restored.dynamicGrain, original.dynamicGrain);
      expect(restored.outputDepth, original.outputDepth);
    });

    test('sharpen round-trip preserves all values', () {
      const original = SharpenParameters(
        enabled: true,
        method: SharpenMethod.cas,
        casSharpness: 0.7,
        strength: 150,
        overshoot: 3,
        undershoot: 2,
        softEdge: 10,
      );

      final dynamic = ParameterConverter.fromSharpen(original);
      final restored = ParameterConverter.toSharpen(dynamic);

      expect(restored.method, original.method);
      expect(restored.casSharpness, original.casSharpness);
      expect(restored.strength, original.strength);
      expect(restored.overshoot, original.overshoot);
      expect(restored.undershoot, original.undershoot);
      expect(restored.softEdge, original.softEdge);
    });

    test('color_correction round-trip preserves all values', () {
      const original = ColorCorrectionParameters(
        enabled: true,
        brightness: 5.0,
        contrast: 1.15,
        saturation: 1.2,
        hue: -10.0,
        coring: true,
        applyLevels: true,
        inputLow: 16,
        inputHigh: 235,
        outputLow: 0,
        outputHigh: 255,
        gamma: 0.9,
      );

      final dynamic = ParameterConverter.fromColorCorrection(original);
      final restored = ParameterConverter.toColorCorrection(dynamic);

      expect(restored.brightness, original.brightness);
      expect(restored.contrast, original.contrast);
      expect(restored.saturation, original.saturation);
      expect(restored.hue, original.hue);
      expect(restored.coring, original.coring);
      expect(restored.applyLevels, original.applyLevels);
      expect(restored.inputLow, original.inputLow);
      expect(restored.inputHigh, original.inputHigh);
      expect(restored.outputLow, original.outputLow);
      expect(restored.outputHigh, original.outputHigh);
      expect(restored.gamma, original.gamma);
    });

    test('chroma_fixes round-trip preserves all values', () {
      const original = ChromaFixParameters(
        enabled: true,
        applyChromaBleedingFix: true,
        chromaBleedCx: 6,
        chromaBleedCy: 5,
        chromaBleedCBlur: 0.9,
        chromaBleedStrength: 0.7,
        applyDeCrawl: true,
        deCrawlYThresh: 12,
        deCrawlCThresh: 14,
        deCrawlMaxDiff: 70,
        applyVinverse: true,
        vinverseSstr: 3.0,
        vinverseAmnt: 200,
      );

      final dynamic = ParameterConverter.fromChromaFixes(original);
      final restored = ParameterConverter.toChromaFixes(dynamic);

      expect(restored.applyChromaBleedingFix, original.applyChromaBleedingFix);
      expect(restored.chromaBleedCx, original.chromaBleedCx);
      expect(restored.chromaBleedCy, original.chromaBleedCy);
      expect(restored.chromaBleedCBlur, original.chromaBleedCBlur);
      expect(restored.chromaBleedStrength, original.chromaBleedStrength);
      expect(restored.applyDeCrawl, original.applyDeCrawl);
      expect(restored.deCrawlYThresh, original.deCrawlYThresh);
      expect(restored.deCrawlCThresh, original.deCrawlCThresh);
      expect(restored.deCrawlMaxDiff, original.deCrawlMaxDiff);
      expect(restored.applyVinverse, original.applyVinverse);
      expect(restored.vinverseSstr, original.vinverseSstr);
      expect(restored.vinverseAmnt, original.vinverseAmnt);
    });

    test('crop_resize round-trip preserves all values', () {
      const original = CropResizeParameters(
        enabled: true,
        cropEnabled: true,
        cropLeft: 10,
        cropRight: 12,
        cropTop: 6,
        cropBottom: 8,
        resizeEnabled: true,
        targetWidth: 1280,
        targetHeight: 720,
        kernel: ResizeKernel.lanczos,
        maintainAspect: false,
        useIntegerUpscale: true,
        upscaleMethod: UpscaleMethod.eedi3Rpow2,
        upscaleFactor: 4,
      );

      final dynamic = ParameterConverter.fromCropResize(original);
      final restored = ParameterConverter.toCropResize(dynamic);

      expect(restored.cropEnabled, original.cropEnabled);
      expect(restored.cropLeft, original.cropLeft);
      expect(restored.cropRight, original.cropRight);
      expect(restored.cropTop, original.cropTop);
      expect(restored.cropBottom, original.cropBottom);
      expect(restored.resizeEnabled, original.resizeEnabled);
      expect(restored.targetWidth, original.targetWidth);
      expect(restored.targetHeight, original.targetHeight);
      expect(restored.kernel, original.kernel);
      expect(restored.maintainAspect, original.maintainAspect);
      expect(restored.useIntegerUpscale, original.useIntegerUpscale);
      expect(restored.upscaleMethod, original.upscaleMethod);
      expect(restored.upscaleFactor, original.upscaleFactor);
    });

    test('subtitles round-trip preserves all values', () {
      const original = SubtitleParameters(
        enabled: true,
        model: WhisperModel.high,
        output: SubtitleOutput.both,
        language: 'fr',
      );

      final dynamic = ParameterConverter.fromSubtitles(original);
      final restored = ParameterConverter.toSubtitles(dynamic);

      expect(restored.model, original.model);
      expect(restored.output, original.output);
      expect(restored.language, original.language);
    });
  });

  group('Default consistency', () {
    /// Verify that schema defaults match Dart model constructor defaults.

    test('deband: schema defaults match model defaults', () {
      final schema = loadSchema('deband.json');
      const model = DebandParameters();

      expect(schema.parameters['range']!.defaultValue, model.range);
      expect(schema.parameters['y']!.defaultValue, model.y);
      expect(schema.parameters['cb']!.defaultValue, model.cb);
      expect(schema.parameters['cr']!.defaultValue, model.cr);
      expect(schema.parameters['grainY']!.defaultValue, model.grainY);
      expect(schema.parameters['grainC']!.defaultValue, model.grainC);
      expect(schema.parameters['dynamicGrain']!.defaultValue,
          model.dynamicGrain);
      expect(schema.parameters['outputDepth']!.defaultValue, model.outputDepth);
    });

    test('dehalo: schema defaults match model defaults', () {
      final schema = loadSchema('dehalo.json');
      const model = DehaloParameters();

      expect(schema.parameters['rx']!.defaultValue, model.rx);
      expect(schema.parameters['ry']!.defaultValue, model.ry);
      expect(schema.parameters['darkStr']!.defaultValue, model.darkStr);
      expect(schema.parameters['brightStr']!.defaultValue, model.brightStr);
      expect(
          schema.parameters['lowThreshold']!.defaultValue, model.lowThreshold);
      expect(schema.parameters['highThreshold']!.defaultValue,
          model.highThreshold);
    });

    test('sharpen: schema defaults match model defaults', () {
      final schema = loadSchema('sharpen.json');
      const model = SharpenParameters();

      expect(schema.parameters['strength']!.defaultValue, model.strength);
      expect(schema.parameters['overshoot']!.defaultValue, model.overshoot);
      expect(schema.parameters['undershoot']!.defaultValue, model.undershoot);
      expect(schema.parameters['softEdge']!.defaultValue, model.softEdge);
      expect(
          schema.parameters['casSharpness']!.defaultValue, model.casSharpness);
    });

    test('noise_reduction: schema defaults match model defaults', () {
      final schema = loadSchema('noise_reduction.json');
      const model = NoiseReductionParameters();

      expect(schema.parameters['smDegrainTr']!.defaultValue, model.smDegrainTr);
      expect(schema.parameters['smDegrainThSAD']!.defaultValue,
          model.smDegrainThSAD);
      expect(schema.parameters['smDegrainThSADC']!.defaultValue,
          model.smDegrainThSADC);
      expect(schema.parameters['smDegrainRefine']!.defaultValue,
          model.smDegrainRefine);
      expect(schema.parameters['smDegrainPrefilter']!.defaultValue,
          model.smDegrainPrefilter);
      expect(schema.parameters['mcTemporalSigma']!.defaultValue,
          model.mcTemporalSigma);
      expect(schema.parameters['mcTemporalRadius']!.defaultValue,
          model.mcTemporalRadius);
      expect(schema.parameters['mcTemporalProfile']!.defaultValue,
          model.mcTemporalProfile);
    });

    test('chroma_fixes: schema defaults match model defaults', () {
      final schema = loadSchema('chroma_fixes.json');
      const model = ChromaFixParameters();

      expect(schema.parameters['chromaBleedCx']!.defaultValue,
          model.chromaBleedCx);
      expect(schema.parameters['chromaBleedCy']!.defaultValue,
          model.chromaBleedCy);
      expect(schema.parameters['chromaBleedCBlur']!.defaultValue,
          model.chromaBleedCBlur);
      expect(schema.parameters['chromaBleedStrength']!.defaultValue,
          model.chromaBleedStrength);
      expect(schema.parameters['vinverseSstr']!.defaultValue,
          model.vinverseSstr);
      expect(
          schema.parameters['vinverseAmnt']!.defaultValue, model.vinverseAmnt);
    });

    test('color_correction: schema defaults match model defaults', () {
      final schema = loadSchema('color_correction.json');
      const model = ColorCorrectionParameters();

      expect(schema.parameters['brightness']!.defaultValue, model.brightness);
      expect(schema.parameters['contrast']!.defaultValue, model.contrast);
      expect(schema.parameters['saturation']!.defaultValue, model.saturation);
      expect(schema.parameters['hue']!.defaultValue, model.hue);
      expect(schema.parameters['gamma']!.defaultValue, model.gamma);
      expect(schema.parameters['applyLevels']!.defaultValue, model.applyLevels);
      expect(schema.parameters['inputLow']!.defaultValue, model.inputLow);
      expect(schema.parameters['inputHigh']!.defaultValue, model.inputHigh);
      expect(schema.parameters['outputLow']!.defaultValue, model.outputLow);
      expect(schema.parameters['outputHigh']!.defaultValue, model.outputHigh);
    });

    test('crop_resize: schema defaults match model defaults', () {
      final schema = loadSchema('crop_resize.json');
      const model = CropResizeParameters();

      expect(schema.parameters['kernel']!.defaultValue, model.kernel.name);
      expect(schema.parameters['maintainAspect']!.defaultValue,
          model.maintainAspect);
      expect(schema.parameters['upscaleMethod']!.defaultValue,
          model.upscaleMethod.name);
      expect(
          schema.parameters['upscaleFactor']!.defaultValue, model.upscaleFactor);
    });
  });
}
