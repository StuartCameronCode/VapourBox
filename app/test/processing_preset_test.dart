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
import 'package:vapourbox/models/processing_preset.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
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
        expect(restored.pipeline.enabledPassCount,
            preset.pipeline.enabledPassCount);
      }
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
