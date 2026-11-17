/// Checks the generated format sweep's cases (task #47) without running the
/// worker: every pass is classified, every method enum agrees with its schema
/// both ways, no variant appears or disappears unnoticed, every hand table
/// names things that exist, every worker format is covered, and the push
/// gate's rows really cover every axis value for every variant.
///
/// Push gate. The sweep itself is `integration_format_sweep_test.dart`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/models/anti_alias_parameters.dart';
import 'package:vapourbox/models/chroma_denoise_parameters.dart';
import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/deblock_parameters.dart';
import 'package:vapourbox/models/deflicker_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/grain_parameters.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/spotless_parameters.dart';
import 'package:vapourbox/views/pass_settings/pass_settings_inline.dart';

import 'support/format_sweep.dart';

/// How many variants each filter generates. A variant that silently
/// disappears fails here; adding a method or sub-feature means changing one
/// number (and, if it is inert on the fixture, an actuation override).
const expectedVariantCounts = <String, int>{
  'deinterlace': 14, // 3 methods + QTGMC's 11 presets
  'unblend': 1,
  'descratch': 1,
  'spotless': 2,
  'noise_reduction': 16,
  'chroma_denoise': 2,
  'dehalo': 9,
  'deblock': 4,
  'deband': 1,
  'sharpen': 3,
  'anti_alias': 3,
  'stabilize': 2, // pitch off / auto
  'geometry': 3,
  'grain': 2,
  'frame_rate': 3,
  'deflicker': 2,
  'edge_repair': 1,
  'ghost_removal': 1,
  'descale': 7, // 6 kernels (one is the base) + detail protection
  'color_correction': 7,
  'chroma_fixes': 8,
  'crop_resize': 14,
  'face_restore': 3,
  'colorize': 2,
};

/// Each method enum, what the converter writes for every value, and the
/// schema parameter it must match (`method` unless said).
final methodEnums = <String,
    ({String filterId, String param, List<Map<String, dynamic>> written})>{
  'DeinterlaceMethod': (
    filterId: 'deinterlace',
    param: 'method',
    written: [
      for (final m in DeinterlaceMethod.values)
        ParameterConverter.fromQTGMC(QTGMCParameters(method: m)).values
    ],
  ),
  'NoiseReductionMethod': (
    filterId: 'noise_reduction',
    param: 'method',
    written: [
      for (final m in NoiseReductionMethod.values)
        ParameterConverter.fromNoiseReduction(NoiseReductionParameters(method: m)).values
    ],
  ),
  'DehaloMethod': (
    filterId: 'dehalo',
    param: 'method',
    written: [
      for (final m in DehaloMethod.values)
        ParameterConverter.fromDehalo(DehaloParameters(method: m)).values
    ],
  ),
  'DeblockMethod': (
    filterId: 'deblock',
    param: 'method',
    written: [
      for (final m in DeblockMethod.values)
        ParameterConverter.fromDeblock(DeblockParameters(method: m)).values
    ],
  ),
  'SharpenMethod': (
    filterId: 'sharpen',
    param: 'method',
    written: [
      for (final m in SharpenMethod.values)
        ParameterConverter.fromSharpen(SharpenParameters(method: m)).values
    ],
  ),
  'AntiAliasMethod': (
    filterId: 'anti_alias',
    param: 'method',
    written: [
      for (final m in AntiAliasMethod.values)
        ParameterConverter.fromAntiAlias(AntiAliasParameters(method: m)).values
    ],
  ),
  'ChromaDenoiseMethod': (
    filterId: 'chroma_denoise',
    param: 'method',
    written: [
      for (final m in ChromaDenoiseMethod.values)
        ParameterConverter.fromChromaDenoise(ChromaDenoiseParameters(method: m)).values
    ],
  ),
  'SpotLessMethod': (
    filterId: 'spotless',
    param: 'method',
    written: [
      for (final m in SpotLessMethod.values)
        ParameterConverter.fromSpotLess(SpotLessParameters(method: m)).values
    ],
  ),
  'GrainMethod': (
    filterId: 'grain',
    param: 'method',
    written: [
      for (final m in GrainMethod.values)
        ParameterConverter.fromGrain(GrainParameters(method: m)).values
    ],
  ),
  'DeflickerMethod': (
    filterId: 'deflicker',
    param: 'method',
    written: [
      for (final m in DeflickerMethod.values)
        ParameterConverter.fromDeflicker(DeflickerParameters(method: m)).values
    ],
  ),
  'FrameRateMethod': (
    filterId: 'frame_rate',
    param: 'method',
    written: [
      for (final m in FrameRateMethod.values)
        ParameterConverter.fromFrameRate(FrameRateParameters(method: m)).values
    ],
  ),
  'UpscaleMethod': (
    filterId: 'crop_resize',
    param: 'upscaleMethod',
    written: [
      for (final m in UpscaleMethod.values)
        ParameterConverter.fromCropResize(CropResizeParameters(upscaleMethod: m)).values
    ],
  ),
};

Set<String> _schemaOptions(String filterId, String param) {
  final schema = loadSchemaJson(filterId);
  if (param == 'method' && schemaMethodIds(schema).isNotEmpty) {
    return schemaMethodIds(schema).toSet();
  }
  final def = (schema['parameters'] as Map)[param] as Map;
  return {for (final o in def['options'] as List) (o is Map ? o['value'] : o) as String};
}

void main() {
  group('passes', () {
    test('every PassType is classified, and every swept one has a schema', () {
      for (final type in PassType.values) {
        final c = sweepClassOf(type);
        if (!c.swept) {
          expect(c.excludedBecause, isNotEmpty);
          continue;
        }
        final id = PassSettingsInline.filterIdFor(type);
        expect(File('assets/filters/core/$id.json').existsSync(), isTrue,
            reason: '$type has no schema at $id');
      }
      expect(sweptPassTypes, hasLength(24));
    });

    test('every swept pass has at least one variant', () {
      for (final type in sweptPassTypes) {
        expect(sweepVariants.where((v) => v.type == type), isNotEmpty, reason: '$type');
      }
    });
  });

  group('method enums agree with their schemas', () {
    for (final MapEntry(key: name, value: e) in methodEnums.entries) {
      test(name, () {
        final options = _schemaOptions(e.filterId, e.param);
        final written = {for (final v in e.written) v[e.param] as String};
        expect(written, options,
            reason: '$name and ${e.filterId}.json\'s ${e.param} must name the '
                'same methods, both ways');
        expect(written, hasLength(e.written.length),
            reason: 'two $name values are written as one schema id');
      });
    }

    test('every enum named *Method in lib/models is listed above', () {
      final names = <String>{};
      for (final f in Directory('lib/models').listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        for (final m in RegExp(r'^enum (\w+Method)\b', multiLine: true)
            .allMatches(f.readAsStringSync())) {
          names.add(m.group(1)!);
        }
      }
      expect(names, methodEnums.keys.toSet(),
          reason: 'a new method enum must be checked against its schema here');
    });

    test('every method the converter writes comes back through toPipeline', () {
      for (final v in sweepVariants.where((v) => v.values.containsKey('method'))) {
        final back = v.panelValues(96, 64)['method'];
        expect(back, v.values['method'], reason: '${v.id}: the converter lost the method');
      }
    });
  });

  group('variants', () {
    test('counts per filter', () {
      final counts = <String, int>{};
      for (final v in sweepVariants) {
        counts[v.filterId] = (counts[v.filterId] ?? 0) + 1;
      }
      expect(counts, expectedVariantCounts,
          reason: 'variants by filter:\n${sweepVariants.map((v) => v.id).join('\n')}');
    });

    test('ids are unique and every variant switches its pass on', () {
      expect(sweepVariants.map((v) => v.id).toSet(), hasLength(sweepVariants.length));
      for (final v in sweepVariants) {
        final enabled = ParameterConverter.fromPipeline(v.pipelineFor(96, 64))
            .enabledFilterIds;
        expect(enabled, contains(v.filterId), reason: v.id);
        final others = enabled.where((id) =>
            id != v.filterId && !(prerequisites[v.id]?.containsKey(id) ?? false));
        expect(others, isEmpty, reason: '${v.id} switched on other passes');
      }
    });

    test('each variant\'s own values survive the converter', () {
      final schemaParams = <String, Map>{};
      for (final v in sweepVariants) {
        final params = schemaParams[v.filterId] ??=
            loadSchemaJson(v.filterId)['parameters'] as Map;
        final back = v.panelValues(96, 64);
        for (final MapEntry(:key, :value) in v.values.entries) {
          if (key == 'method' && !params.containsKey('method')) continue;
          expect(back[key], value, reason: '${v.id}: $key did not round-trip');
        }
      }
    });

    test('the CPU variants that need nothing run in the push gate', () {
      final anywhere = sweepVariants.where((v) => v.runsAnywhere).length;
      // RIFE and the six AI upscalers need a GPU; Face Restoration and
      // Colourisation need add-ons.
      expect(anywhere, sweepVariants.length - 7 - 5);
    });
  });

  group('hand tables name real things', () {
    final ids = sweepVariants.map((v) => v.id).toSet();
    final filterIds = sweepVariants.map((v) => v.filterId).toSet();

    test('enum axes', () {
      for (final a in enumAxes) {
        final def = (loadSchemaJson(a.filterId)['parameters'] as Map)[a.param] as Map?;
        expect(def?['type'], 'enum', reason: '${a.filterId}.${a.param}');
        final options = {for (final o in def!['options'] as List) o is Map ? o['value'] : o};
        expect(options, containsAll(a.exclude));
        if (a.onlyMethod != null) {
          expect(schemaMethodIds(loadSchemaJson(a.filterId)), contains(a.onlyMethod));
        }
      }
    });

    test('actuation overrides', () {
      for (final MapEntry(:key, :value) in actuationOverrides.entries) {
        expect(ids.contains(key) || filterIds.contains(key), isTrue,
            reason: 'override key $key is no variant or filter');
        final filterId = key.split('/').first;
        final params = loadSchemaJson(filterId)['parameters'] as Map;
        for (final param in value.values(96, 64).keys) {
          expect(params, contains(param), reason: '$key sets $param, not in $filterId.json');
        }
        expect(value.reason, isNotEmpty);
      }
    });

    test('prerequisites', () {
      for (final MapEntry(:key, :value) in prerequisites.entries) {
        expect(ids, contains(key));
        for (final MapEntry(key: f, value: values) in value.entries) {
          final params = loadSchemaJson(f)['parameters'] as Map;
          for (final param in values.keys) {
            expect(params, contains(param), reason: '$key: $f.$param');
          }
        }
      }
    });

    test('tolerances, inert allowlist, delta-only, known failures', () {
      for (final key in parityTolerances.keys) {
        expect(ids.any((id) => id == key || id.startsWith(key)), isTrue, reason: key);
      }
      for (final key in inertOnFixture.keys) {
        // An allowlisted variant that no longer exists must go too.
        expect(ids, contains(key), reason: key);
      }
      for (final key in deltaOnly.keys) {
        expect(ids, contains(key));
      }
      for (final k in knownFailures) {
        expect(ids.any((id) => id == k.variant || (k.variant.endsWith('/') && id.startsWith(k.variant))),
            isTrue, reason: k.variant);
        expect(k.error, isNotEmpty);
      }
    });
  });

  group('formats', () {
    test('every product format is native or mapped by the decoder', () {
      final native = workerNativeFormats().toSet();
      for (final f in productFormats) {
        expect(native, contains(f.pipedName), reason: '$f pipes as ${f.pipedName}');
        if (f.depth == 9 || f.depth == 14) {
          expect(native, isNot(contains(f.name)),
              reason: '$f must be decoded at ${f.pipedDepth} bits (tasks #23, #31)');
        }
      }
    });

    test('every native format is swept', () {
      final swept = {...productFormats, ...extraFormats}.map((f) => f.name).toSet();
      expect(swept, containsAll(workerNativeFormats()));
      // yuv411p and the three yuvj formats, today.
      expect(extraFormats, hasLength(4));
    });

    test('the deep fixture chain rounds back to every shallower depth', () {
      for (var s = 0; s < 256; s += 5) {
        for (final (x, y, n, plane) in [(0, 0, 0, 0), (3, 7, 2, 1), (5, 2, 9, 2), (6, 6, 6, 0)]) {
          int at(int d) => chainSample(s, d, x, y, n, plane);
          for (final (deep, shallow) in [(10, 8), (12, 10), (12, 8), (16, 12), (16, 10), (16, 8), (14, 8), (14, 10), (14, 12)]) {
            final shift = deep - shallow;
            expect(at(deep) >> shift, at(shallow), reason: 'floor $deep -> $shallow');
            expect((at(deep) + (1 << (shift - 1))) >> shift, at(shallow),
                reason: 'nearest $deep -> $shallow');
          }
          expect(at(9) >> 1, s);
          expect(at(16) - 256 * s, inInclusiveRange(0, 127));
        }
      }
    });

    test('the deep fixtures carry real sub-8-bit content', () {
      for (final d in [9, 10, 12, 14, 16]) {
        final lows = {
          for (var x = 0; x < 8; x++)
            for (var y = 0; y < 8; y++) chainSample(100, d, x, y, 0, 0) & ((1 << (d - 8)) - 1)
        };
        expect(lows.length, greaterThan(1), reason: '$d-bit');
      }
    });
  });

  group('rows', () {
    test('every variant meets every subsampling, field, size and field x size in the gate', () {
      for (final v in sweepVariants) {
        final rows = gateRows(v.index).where((r) => r.format.inProduct);
        expect(rows.map((r) => r.format.subsampling).toSet(), sweepSubsamplings.toSet(), reason: v.id);
        expect(
            rows.where((r) => tinySizes.contains(r.size)).map((r) => (r.field, r.size)).toSet(),
            hasLength(4),
            reason: v.id);
        // One 4:2:0 row at a height 2 mod 4 (task #57).
        expect(rows.where((r) => r.size == SweepSize.heightTwoMod4).map((r) => r.format.subsampling),
            ['420'], reason: v.id);
        expect(rows.map((r) => r.format.depth).toSet(), {8, 10, 12, 16}, reason: v.id);
      }
    });

    test('no row pairs a format with a width its chroma grid can\'t hold', () {
      for (final v in sweepVariants) {
        for (final r in [...gateRows(v.index), ...nightlyRows(v.index)]) {
          expect(r.size.width % r.format.chromaShift.$1, 0, reason: '${v.id} ${r.key}');
        }
      }
    });

    test('the gate spreads the extra native formats over the variants', () {
      final extras = {
        for (final v in sweepVariants)
          ...gateRows(v.index).where((r) => !r.format.inProduct).map((r) => r.format)
      };
      expect(extras, extraFormats.toSet());
    });

    test('the nightly rows hold the full tiny product, 9/14-bit, every extra format and SD', () {
      for (final v in sweepVariants) {
        final rows = nightlyRows(v.index);
        expect(rows.toSet(), hasLength(rows.length), reason: 'duplicate rows');
        for (final size in tinySizes) {
          for (final field in SweepField.values) {
            for (final f in productFormats.where((f) => f.depth == f.pipedDepth)) {
              expect(rows, contains(SweepRow(f, field, size)));
            }
          }
        }
        expect(rows.map((r) => r.format.depth), containsAll([9, 14]));
        expect(rows.map((r) => r.format).toSet(), containsAll(extraFormats));
        expect(rows.where((r) => r.size == SweepSize.sd).map((r) => r.format.subsampling).toSet(),
            sweepSubsamplings.toSet());
        // 4:2:0 at a height 2 mod 4, every piped depth, both fields (task #57).
        expect(rows.where((r) => r.size == SweepSize.heightTwoMod4), hasLength(8));
        // Every 9/14-bit row has its 8-bit pair for the parity check.
        for (final r in rows.where((r) => r.format.depth != r.format.pipedDepth)) {
          expect(rows, contains(r.at(SweepFormat.of(r.format.subsampling, 8))));
        }
      }
    });
  });

  test('DynamicParameters built by the sweep keep the base\'s optional state', () {
    // The sweep sets values the way the panel does (on the filter's
    // DynamicParameters, then toPipeline); a lost optional set would turn a
    // parameter off behind the variant's back.
    final base = ParameterConverter.fromPipeline(sweepBasePipeline);
    for (final v in sweepVariants) {
      final built = ParameterConverter.fromPipeline(v.pipelineFor(96, 64)).get(v.filterId)!;
      final DynamicParameters b = base.get(v.filterId)!;
      expect(built.enabledOptionalParams, containsAll(b.enabledOptionalParams), reason: v.id);
    }
  });
}
