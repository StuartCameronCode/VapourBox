// Tests for the built-in presets.
//
// Most of these assert that a preset does what its *name* promises. That is the
// whole contract of a source-shaped preset: someone who knows they captured a
// DV tape picks "DV Camcorder Tape" and gets deinterlacing and chroma work, and
// someone who scanned Super 8 picks the film preset and does NOT get their
// progressive scan deinterlaced. A preset that quietly stops matching its name
// is worse than no preset, because the user has no reason to check.
//
// Run with: flutter test test/processing_preset_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/processing_preset.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

void main() {
  final presets = ProcessingPreset.builtInPresets();

  ProcessingPreset byId(String id) => presets.firstWhere((p) => p.id == id);

  group('the built-in set', () {
    test('every preset is registered', () {
      // A factory that never reaches builtInPresets() is invisible — nothing
      // else picks it up. See the "Adding a New Built-in Preset" checklist.
      expect(
        presets.map((p) => p.id).toSet(),
        {
          'builtin-fast',
          'builtin-balanced',
          'builtin-high-quality',
          'builtin-vhs-cleanup',
          'builtin-dv-camcorder',
          'builtin-pal-dvd',
          'builtin-dvd-ivtc',
          'builtin-anime-dvd',
          'builtin-film-scan',
        },
      );
    });

    test('ids are unique', () {
      final ids = presets.map((p) => p.id).toList();
      expect(ids.length, ids.toSet().length);
    });

    test('all are marked built-in, named and described', () {
      for (final preset in presets) {
        expect(preset.isBuiltIn, true, reason: preset.id);
        expect(preset.name.trim(), isNotEmpty, reason: preset.id);
        expect(preset.description?.trim() ?? '', isNotEmpty, reason: preset.id);
      }
    });

    test('every preset actually does something', () {
      for (final preset in presets) {
        expect(preset.pipeline.enabledPassCount, greaterThan(0),
            reason: '${preset.id} enables no passes, so it only re-encodes');
      }
    });

    test('ids survive a round trip, so saved jobs keep resolving', () {
      for (final preset in presets) {
        final restored = ProcessingPreset.fromJson(preset.toJson());
        expect(restored.id, preset.id);
        expect(restored.name, preset.name);
        expect(restored.category, preset.category);
        expect(restored.pipeline.enabledPassCount,
            preset.pipeline.enabledPassCount);
      }
    });
  });

  group('menu grouping', () {
    test('every built-in declares a category', () {
      // The menu groups on this. A built-in left as `custom` would be filed
      // under the source presets, which is the safe fallback but still wrong.
      for (final preset in presets) {
        expect(preset.category, isNot(PresetCategory.custom), reason: preset.id);
      }
    });

    test('the quality tiers are the only quality-category presets', () {
      expect(
        presets
            .where((p) => p.category == PresetCategory.quality)
            .map((p) => p.id)
            .toSet(),
        {'builtin-fast', 'builtin-balanced', 'builtin-high-quality'},
      );
    });

    test('every other built-in is a source preset', () {
      final bySource = presets
          .where((p) => p.category == PresetCategory.source)
          .map((p) => p.id)
          .toSet();
      expect(bySource, {
        'builtin-vhs-cleanup',
        'builtin-dv-camcorder',
        'builtin-pal-dvd',
        'builtin-dvd-ivtc',
        'builtin-anime-dvd',
        'builtin-film-scan',
      });
      // Source presets should outnumber the tiers — the whole point is that
      // naming the source is what a user can actually answer.
      expect(bySource.length, greaterThan(3));
    });

    test('a user-saved preset defaults to custom', () {
      final saved = ProcessingPreset(
        name: 'My settings',
        pipeline: const ProcessingPipeline(),
        encodingSettings: EncodingSettings(),
      );
      expect(saved.category, PresetCategory.custom);
      expect(saved.isBuiltIn, false);
    });

    test('a preset saved before the field existed loads as custom', () {
      // Old user presets on disk have no `category` key.
      final json = presets.first.toJson()..remove('category');
      expect(ProcessingPreset.fromJson(json).category, PresetCategory.custom);
    });
  });

  group('presets match their names', () {
    test('film scan does not deinterlace a progressive source', () {
      final preset = byId('builtin-film-scan');
      expect(preset.pipeline.deinterlace.enabled, false,
          reason: 'a film scan is already progressive — deinterlacing it would '
              'only soften the picture');
      // What film has instead is physical damage.
      expect(preset.pipeline.descratch.enabled, true);
      expect(preset.pipeline.spotless.enabled, true);
      // Gate weave is the first thing anyone notices on a cine scan. This pass
      // shipped for exactly this source and no preset used it for two batches.
      expect(preset.pipeline.stabilize.enabled, true,
          reason: 'a film scan without stabilisation is the most obviously '
              'incomplete preset in the set');
      // And a scan is a master, so it should be archival.
      expect(preset.encodingSettings.codec, VideoCodec.ffv1);
    });

    test('anime DVD inverse-telecines rather than deinterlacing', () {
      final preset = byId('builtin-anime-dvd');
      expect(preset.pipeline.deinterlace.enabled, true);
      expect(preset.pipeline.deinterlace.method, DeinterlaceMethod.ivtc);
      // Line art shows halos and banding that live action mostly hides.
      expect(preset.pipeline.dehalo.enabled, true);
      expect(preset.pipeline.dehalo.method, DehaloMethod.fineDehalo);
      expect(preset.pipeline.deband.enabled, true);
      // Composite-mastered discs rainbow on fine line art.
      expect(preset.pipeline.chromaFixes.enabled, true);
      expect(preset.pipeline.chromaFixes.applyDeRainbow, true);
    });

    test('PAL DVD deblocks but does not denoise', () {
      final preset = byId('builtin-pal-dvd');
      expect(preset.pipeline.deinterlace.enabled, true);
      expect(preset.pipeline.deblock.enabled, true);
      expect(preset.pipeline.noiseReduction.enabled, false,
          reason: 'a DVD is usually clean; denoising costs detail for nothing');
    });

    test('DV camcorder fixes chroma, which is DV\'s actual weakness', () {
      final preset = byId('builtin-dv-camcorder');
      expect(preset.pipeline.deinterlace.enabled, true);
      expect(preset.pipeline.chromaFixes.enabled, true);
      expect(preset.pipeline.chromaFixes.applyChromaBleedingFix, true);
      // 4:1:1 / 4:2:0 chroma is stored per field, so upsample before bobbing.
      expect(preset.pipeline.deinterlace.chromaUpsampleFix, true);
      // The light luma denoise deliberately leaves chroma alone, so chroma
      // noise needs its own pass.
      expect(preset.pipeline.chromaDenoise.enabled, true);
    });

    test('VHS cleanup is the heaviest denoise of the tape presets', () {
      final vhs = byId('builtin-vhs-cleanup');
      final dv = byId('builtin-dv-camcorder');
      expect(vhs.pipeline.noiseReduction.enabled, true);
      expect(dv.pipeline.noiseReduction.enabled, true);
      expect(
        vhs.pipeline.noiseReduction.smDegrainThSAD,
        greaterThan(dv.pipeline.noiseReduction.smDegrainThSAD),
        reason: 'VHS is far noisier than DV tape; if these ever match, one of '
            'the two presets is miscalibrated',
      );
    });

    test('VHS cleanup uses the two filters the community prescribes most', () {
      // CCD and LSFmod are what restoration regulars reach for on tape, and
      // both shipped unused while this preset ran SMDegrain and DeHalo_alpha
      // alone. Chroma noise is a different failure from luma grain, so the
      // denoiser above does not cover it.
      final vhs = byId('builtin-vhs-cleanup');
      expect(vhs.pipeline.chromaDenoise.enabled, true);
      expect(vhs.pipeline.sharpen.enabled, true);
      expect(vhs.pipeline.sharpen.method, SharpenMethod.lsfmod,
          reason: 'LSFmod is chosen because it does not add halos, which '
              'matters when the dehalo pass has just removed some');
    });

    test('sharpening a tape preset stays modest, because it follows a denoise', () {
      // Sharpening a denoised picture hard is how a capture ends up looking
      // artificial. This bounds it rather than pinning an exact value.
      final vhs = byId('builtin-vhs-cleanup');
      expect(vhs.pipeline.sharpen.strength, lessThan(100),
          reason: 'default strength or above, after SMDegrain, oversharpens');
    });

    test('Fast actually is fast, not just a cheaper QTGMC', () {
      // Measured 622 fps against QTGMC Fast's 150. Before Bwdif this tier was
      // only a lower QTGMC preset, which is not what the name promises.
      final fast = byId('builtin-fast');
      expect(fast.pipeline.deinterlace.method, DeinterlaceMethod.bwdif);
    });

    test('VHS cleanup repairs the edges rather than cropping them', () {
      final vhs = byId('builtin-vhs-cleanup');
      expect(vhs.pipeline.edgeRepair.hasEffect, true,
          reason: 'dirty edge rows are near-universal on tape, and cropping '
              'them throws picture away');
      // Even counts, which is what keeps chroma aligned on subsampled video.
      for (final v in [
        vhs.pipeline.edgeRepair.left,
        vhs.pipeline.edgeRepair.right,
        vhs.pipeline.edgeRepair.top,
        vhs.pipeline.edgeRepair.bottom,
      ]) {
        expect(v.isEven, true, reason: 'edge widths must be even');
      }
      expect(vhs.pipeline.chromaFixes.applyDedot, true,
          reason: 'dot crawl is the signature composite-capture artefact');
    });

    test('the film scan preset fixes both faults cine film has', () {
      // Gate weave and brightness pulsing. It addressed neither until now.
      final film = byId('builtin-film-scan');
      expect(film.pipeline.stabilize.enabled, true);
      expect(film.pipeline.deflicker.enabled, true);
    });

    test('DV camcorder measures its chroma shift rather than guessing', () {
      final dv = byId('builtin-dv-camcorder');
      expect(dv.pipeline.chromaFixes.applyAutoChroma, true);
    });

    test('the quality tiers differ in quality, not in what they fix', () {
      final fast = byId('builtin-fast');
      final balanced = byId('builtin-balanced');
      final high = byId('builtin-high-quality');

      // Lower CRF is better quality.
      expect(fast.encodingSettings.quality,
          greaterThan(balanced.encodingSettings.quality));
      expect(balanced.encodingSettings.quality,
          greaterThan(high.encodingSettings.quality));

      for (final preset in [fast, balanced, high]) {
        expect(preset.pipeline.enabledPassCount, 1,
            reason: '${preset.id} is a quality tier — it should only '
                'deinterlace, or it stops being comparable to the others');
      }
    });
  });

  group('switching a pass off and on keeps what the preset configured', () {
    // togglePass rebuilds the pass through copyWith, so a copyWith missing a
    // field silently discards it. ChromaFixParameters.copyWith never took
    // applyAutoChroma or applyDedot, which meant flicking the Chroma Fixes
    // switch threw away the DeDot that VHS Cleanup turns on and the automatic
    // alignment that DV Camcorder Tape turns on — no error, and the pass
    // afterwards just did nothing.
    test('chroma fixes survives a round trip through togglePass', () {
      for (final id in ['builtin-vhs-cleanup', 'builtin-dv-camcorder', 'builtin-anime-dvd']) {
        final before = byId(id).pipeline;
        final after = before
            .togglePass(PassType.chromaFixes, false)
            .togglePass(PassType.chromaFixes, true);

        expect(after.chromaFixes.toJson(), before.chromaFixes.toJson(),
            reason: '$id lost chroma-fix settings by switching the pass off '
                'and on again');
      }
    });
  });

  group('QTGMC presets are ordered fast to slow', () {
    // The source presets pick a QTGMC preset by name, so this pins the meaning
    // of those names not drifting underneath them.
    test('fast uses a faster QTGMC preset than high quality', () {
      expect(
        QTGMCPreset.values.indexOf(byId('builtin-fast').pipeline.deinterlace.preset),
        greaterThan(
          QTGMCPreset.values
              .indexOf(byId('builtin-high-quality').pipeline.deinterlace.preset),
        ),
        reason: 'QTGMCPreset is declared slowest-first (placebo … draft)',
      );
    });
  });
}
