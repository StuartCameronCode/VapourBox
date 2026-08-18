// Every parameter model's `copyWith()` must carry every field.
//
// `copyWith` is how `ProcessingPipeline.togglePass` rebuilds a pass when its
// switch is flicked, so a field the method forgot is a field that silently
// reverts to its default the moment the user turns the pass off and on. Nothing
// fails: no error, no compile break — the pass simply does something different
// from what the panel says it will.
//
// It had happened five times over, all in fields added during the 2026-08-17
// build-out. The worst pair were preset-facing: VHS Cleanup turns on DeDot and
// DV Camcorder Tape turns on automatic chroma alignment, and both were thrown
// away by one click. Colour Correction lost all six of its automatic levels /
// automatic white balance fields the same way, SpotLess lost its `method` (so
// RemoveDirt silently reverted to SpotLess), Noise Reduction lost thirteen
// fields including every mClean and TemporalDegrain2 setting, and Subtitles lost
// the burn-in file path.
//
// So this enumerates the models rather than testing the one that broke: it fills
// every field with a non-default value through `fromJson`, calls `copyWith()`
// with no arguments, and requires the result to serialise identically. A model
// added without an entry here is caught by the count assertion at the end.
//
// Run with: flutter test test/parameter_copy_with_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/anti_alias_parameters.dart';
import 'package:vapourbox/models/chroma_denoise_parameters.dart';
import 'package:vapourbox/models/chroma_fix_parameters.dart';
import 'package:vapourbox/models/color_correction_parameters.dart';
import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/deband_parameters.dart';
import 'package:vapourbox/models/deblock_parameters.dart';
import 'package:vapourbox/models/deflicker_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/descratch_parameters.dart';
import 'package:vapourbox/models/edge_repair_parameters.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/geometry_parameters.dart';
import 'package:vapourbox/models/ghost_removal_parameters.dart';
import 'package:vapourbox/models/grain_parameters.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/spotless_parameters.dart';
import 'package:vapourbox/models/stabilize_parameters.dart';
import 'package:vapourbox/models/subtitle_parameters.dart';

/// One model under test: its defaults, and how to rebuild it from JSON.
class _Model {
  final String name;
  final Map<String, dynamic> Function() defaults;
  final Map<String, dynamic> Function(Map<String, dynamic>) roundTrip;

  const _Model(this.name, this.defaults, this.roundTrip);
}

/// A value different from [value], of the same JSON type.
///
/// Strings are left alone: they are enum wire values here, and an invented one
/// would not decode. Every other field gets a value it cannot hold by accident,
/// so a dropped one shows up as its default rather than as a coincidence.
dynamic _perturb(dynamic value) {
  if (value is bool) return !value;
  if (value is int) return value + 7;
  if (value is double) return value + 0.5;
  return value;
}

void main() {
  final models = <_Model>[
    _Model('AntiAliasParameters', () => const AntiAliasParameters().toJson(),
        (j) => AntiAliasParameters.fromJson(j).copyWith().toJson()),
    _Model('ChromaDenoiseParameters',
        () => const ChromaDenoiseParameters().toJson(),
        (j) => ChromaDenoiseParameters.fromJson(j).copyWith().toJson()),
    _Model('ChromaFixParameters', () => const ChromaFixParameters().toJson(),
        (j) => ChromaFixParameters.fromJson(j).copyWith().toJson()),
    _Model('ColorCorrectionParameters',
        () => const ColorCorrectionParameters().toJson(),
        (j) => ColorCorrectionParameters.fromJson(j).copyWith().toJson()),
    _Model('CropResizeParameters', () => const CropResizeParameters().toJson(),
        (j) => CropResizeParameters.fromJson(j).copyWith().toJson()),
    _Model('DebandParameters', () => const DebandParameters().toJson(),
        (j) => DebandParameters.fromJson(j).copyWith().toJson()),
    _Model('DeblockParameters', () => const DeblockParameters().toJson(),
        (j) => DeblockParameters.fromJson(j).copyWith().toJson()),
    _Model('DeflickerParameters', () => const DeflickerParameters().toJson(),
        (j) => DeflickerParameters.fromJson(j).copyWith().toJson()),
    _Model('DehaloParameters', () => const DehaloParameters().toJson(),
        (j) => DehaloParameters.fromJson(j).copyWith().toJson()),
    _Model('DeScratchParameters', () => const DeScratchParameters().toJson(),
        (j) => DeScratchParameters.fromJson(j).copyWith().toJson()),
    _Model('EdgeRepairParameters', () => const EdgeRepairParameters().toJson(),
        (j) => EdgeRepairParameters.fromJson(j).copyWith().toJson()),
    _Model('FrameRateParameters', () => const FrameRateParameters().toJson(),
        (j) => FrameRateParameters.fromJson(j).copyWith().toJson()),
    _Model('GeometryParameters', () => const GeometryParameters().toJson(),
        (j) => GeometryParameters.fromJson(j).copyWith().toJson()),
    _Model('GhostRemovalParameters',
        () => const GhostRemovalParameters().toJson(),
        (j) => GhostRemovalParameters.fromJson(j).copyWith().toJson()),
    _Model('GrainParameters', () => const GrainParameters().toJson(),
        (j) => GrainParameters.fromJson(j).copyWith().toJson()),
    _Model('NoiseReductionParameters',
        () => const NoiseReductionParameters().toJson(),
        (j) => NoiseReductionParameters.fromJson(j).copyWith().toJson()),
    _Model('QTGMCParameters', () => const QTGMCParameters().toJson(),
        (j) => QTGMCParameters.fromJson(j).copyWith().toJson()),
    _Model('SharpenParameters', () => const SharpenParameters().toJson(),
        (j) => SharpenParameters.fromJson(j).copyWith().toJson()),
    _Model('SpotLessParameters', () => const SpotLessParameters().toJson(),
        (j) => SpotLessParameters.fromJson(j).copyWith().toJson()),
    _Model('StabilizeParameters', () => const StabilizeParameters().toJson(),
        (j) => StabilizeParameters.fromJson(j).copyWith().toJson()),
    _Model('SubtitleParameters', () => const SubtitleParameters().toJson(),
        (j) => SubtitleParameters.fromJson(j).copyWith().toJson()),
  ];

  group('copyWith() carries every field', () {
    for (final model in models) {
      test(model.name, () {
        final filled = {
          for (final entry in model.defaults().entries)
            entry.key: _perturb(entry.value),
        };

        final copied = model.roundTrip(Map<String, dynamic>.from(filled));

        // Compare field by field so a failure names the field, not the map.
        for (final entry in filled.entries) {
          expect(copied[entry.key], entry.value,
              reason: '${model.name}.copyWith() dropped "${entry.key}" — add it '
                  'to both the parameter list and the constructor call');
        }
      });
    }

    test('every parameter model is covered', () {
      // The count is the guard: a new model with a forgetful copyWith would
      // otherwise be caught by nothing at all.
      expect(models.length, 21,
          reason: 'a parameter model was added or removed — add it to this '
              'list and update the count');
    });
  });

  // The pass above cannot see string or enum fields: a perturbed enum value
  // would not decode, so it is left alone and a dropped one still matches. That
  // is not hypothetical — SpotLess dropped `method`, which is exactly that
  // shape, and Subtitles dropped a plain `String`. So the same rule is also
  // checked against the source, where the type does not matter.
  group('copyWith() names every field, whatever its type', () {
    final files = Directory('lib/models')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('_parameters.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final name = file.uri.pathSegments.last;

      test(name, () {
        final source = file.readAsStringSync();

        // The parameter class only — enums declared in the same file carry
        // `final` members of their own (`displayName`, `value`), and those are
        // no business of copyWith.
        final classBody = RegExp(
          r'^class (\w*Parameters) \{$(.*?)^\}$',
          multiLine: true,
          dotAll: true,
        ).firstMatch(source);
        if (classBody == null) return; // dynamic_parameters.dart has no copyWith

        final body = classBody.group(2)!;
        final copyWith = RegExp(
          r'\w+ copyWith\(\{(.*?)\}\) \{(.*?)\n  \}',
          dotAll: true,
        ).firstMatch(body);
        if (copyWith == null) return;

        final fields = RegExp(r'^  final [\w<>,? ]+? (\w+);', multiLine: true)
            .allMatches(body)
            .map((m) => m.group(1)!)
            .toSet();
        final assigned =
            RegExp(r'^      (\w+):', multiLine: true)
                .allMatches(copyWith.group(2)!)
                .map((m) => m.group(1)!)
                .toSet();

        expect(fields.difference(assigned), isEmpty,
            reason: 'copyWith() in $name does not carry these fields, so '
                'toggling the pass resets them to their defaults');
      });
    }
  });
}
