// Attribution lint.
//
// Third-party credit lives in three places that drift apart silently:
//
//   * licenses/NOTICES.txt        — the legal notice shipped in every package
//   * app/lib/views/about_dialog.dart — what the user actually reads
//   * Scripts/deps-expected-plugins.json — what is actually in the bundle
//
// Both failure directions have happened. NOTICES kept an entry for ffms2 long
// after the pipe source replaced it, and it named none of Retinex, bifrost,
// fluxsmooth, descratch, VIVTC, TCanny or half a dozen other plugins that were
// added to the bundle. Nothing failed, because nothing checked.
//
// So: every plugin binary the bundle is required to contain must be credited,
// and every component the About dialog names must appear in NOTICES. Adding a
// plugin now means adding an attribution or the build goes red.
//
// Getting a name WRONG is a separate problem this cannot catch — see issue #72,
// where a plausible-sounding but invented author name shipped. Take every
// copyright line from the upstream LICENSE or source header, never from memory.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory(p.join(dir.path, 'worker')).existsSync() &&
        Directory(p.join(dir.path, 'app')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not locate the repo root from ${Directory.current}');
    }
    dir = parent;
  }
}

/// Plugin binary stem (lowercased, `lib` prefix and extension stripped) → the
/// text that must appear in NOTICES.txt for it.
///
/// A stem missing from this map fails the test rather than being skipped: a new
/// plugin has to be credited deliberately, not by whatever its filename happens
/// to be.
const _pluginToNotice = <String, String>{
  'addgrain': 'AddGrain',
  'akarin': 'akarin',
  'awarpsharp2': 'AWarpSharp2',
  'bifrost': 'Bifrost',
  'bm3d': 'BM3D',
  'bwdif': 'Bwdif',
  'cas': 'CAS',
  'ctmf': 'CTMF',
  'dctfilter': 'DCTFilter',
  'deblock': 'Deblock',
  'dedot': 'DeDot',
  'descale': 'descale — MIT',
  'descratch': 'DeScratch',
  'dfttest': 'DFTTest',
  'eedi3m': 'EEDI3',
  'fft3dfilter': 'FFT3DFilter',
  'fillborders': 'FillBorders',
  'fluxsmooth': 'FluxSmooth',
  'fmtconv': 'fmtconv',
  'knlmeanscl': 'KNLMeansCL',
  'lghost': 'LGhost',
  'miscfilters': 'Miscellaneous Filters',
  'mvtools': 'MVTools',
  'neo-f3kdb': 'neo_f3kdb',
  'nnedi3': 'nnedi3',
  'nnedi3cl': 'NNEDI3CL',
  'removedirt': 'RemoveDirt',
  'removegrain': 'RemoveGrain',
  'removegrainvs': 'RemoveGrain',
  'retinex': 'Retinex',
  'tcanny': 'TCanny',
  'temporalmedian': 'TemporalMedian',
  'tmedian': 'TemporalMedian',
  'ttempsmooth': 'TTempSmooth',
  'vivtc': 'VIVTC',
  'vsznedi3': 'znedi3',
  'vszip': 'vszip',
  'znedi3': 'znedi3',
  'zsmooth': 'zsmooth',
  'zstd': 'Zstandard',
};

/// Components removed from the bundle whose credit must not linger. Crediting
/// something that is not shipped is its own kind of inaccuracy.
const _mustNotAppear = <String>['ffms2', 'BestSource'];

String _stem(String filename) {
  var s = filename.toLowerCase();
  final dot = s.lastIndexOf('.');
  if (dot > 0) s = s.substring(0, dot);
  if (s.startsWith('lib') && s.length > 3) s = s.substring(3);
  return s;
}

void main() {
  final root = _repoRoot();
  final notices = File(p.join(root, 'licenses', 'NOTICES.txt')).readAsStringSync();

  group('licenses/NOTICES.txt', () {
    test('credits every plugin the bundle is required to ship', () {
      final manifest = jsonDecode(
        File(p.join(root, 'Scripts', 'deps-expected-plugins.json')).readAsStringSync(),
      ) as Map<String, dynamic>;

      final uncredited = <String>{};
      final unmapped = <String>{};

      for (final entry in manifest.entries) {
        if (entry.key.startsWith('_')) continue; // "_comment"
        for (final filename in (entry.value as List).cast<String>()) {
          final stem = _stem(filename);
          final needle = _pluginToNotice[stem];
          if (needle == null) {
            unmapped.add('$filename (stem "$stem")');
          } else if (!notices.contains(needle)) {
            uncredited.add('$filename -> expected "$needle" in NOTICES.txt');
          }
        }
      }

      expect(
        unmapped,
        isEmpty,
        reason: 'Plugin(s) with no entry in _pluginToNotice. Add the plugin to '
            'licenses/NOTICES.txt with its real upstream copyright holder and '
            'licence, then map it here.',
      );
      expect(
        uncredited,
        isEmpty,
        reason: 'Plugin(s) shipped but not credited in licenses/NOTICES.txt.',
      );
    });

    test('both CPU tiers of an x64 bundle ship the same plugins', () {
      // The v2 bundle (issue #92) differs from v3 in how some plugins are
      // BUILT, never in which ones ship: a plugin missing from v2 would just
      // be a pass that fails on older machines. The packaging guard checks
      // each list separately, so only this keeps the two lists in step.
      final manifest = jsonDecode(
        File(p.join(root, 'Scripts', 'deps-expected-plugins.json')).readAsStringSync(),
      ) as Map<String, dynamic>;
      for (final platform in ['macos-x64', 'windows-x64', 'linux-x64']) {
        expect(manifest['$platform-v2'], isNotNull, reason: 'no $platform-v2 list');
        expect(
          (manifest['$platform-v2'] as List).toSet(),
          (manifest[platform] as List).toSet(),
          reason: '$platform-v2 must list exactly the plugins $platform does',
        );
      }
    });

    test('credits every file the bundle carries outside the plugin directory', () {
      // The ncnn plugins live outside the autoload directory (RIFE in
      // vapoursynth/rife/, VSNCNN and its models in vapoursynth/ncnn/, MoltenVK
      // in vapoursynth/moltenvk/), so they are listed under _extraFiles rather
      // than in the per-platform lists.
      final manifest = jsonDecode(
        File(p.join(root, 'Scripts', 'deps-expected-plugins.json')).readAsStringSync(),
      ) as Map<String, dynamic>;
      final extra = (manifest['_extraFiles'] as Map<String, dynamic>);
      // Matched by prefix of the file's stem: the model files share one per family.
      const fileToNotice = <String, String>{
        'librife': 'RIFE (VapourSynth-RIFE-ncnn-Vulkan)',
        'libmoltenvk': 'MoltenVK',
        'flownet': 'RIFE 4.26 model',
        'libvsncnn': 'VSNCNN (vs-mlrt)',
        'vsncnn': 'VSNCNN (vs-mlrt)',
        'realesrganv2-animevideo': 'Real-ESRGAN anime video model',
        'up2x-latest': 'Real-CUGAN models',
      };
      for (final entry in extra.entries) {
        for (final path in (entry.value as List).cast<String>()) {
          final stem = p.basenameWithoutExtension(path).toLowerCase();
          final key = fileToNotice.keys
              .where((k) => stem == k || stem.startsWith('$k-'))
              .firstOrNull;
          final needle = key == null ? null : fileToNotice[key];
          expect(needle, isNotNull,
              reason: '${entry.key}: $path has no entry in fileToNotice; credit it '
                  'in NOTICES.txt from its upstream LICENSE, then map it here.');
          expect(notices, contains(needle),
              reason: '${entry.key}: $path is shipped but "$needle" is not in NOTICES.txt');
        }
      }
    });

    // The worker reports "not available for this platform" from
    // gpu_plugin::platform_ships_*; a bundle that ships a plugin where the
    // worker says it can't (or the reverse) is a feature nobody can reach, or a
    // probe that blames an "older bundle" that is in fact current.
    for (final (name, dir, fn) in [
      ('RIFE', '/rife/', 'platform_ships_rife'),
      ('AI upscaling', '/ncnn/', 'platform_ships_upscale'),
    ]) {
      test('$name ships exactly where the worker says it does', () {
        final manifest = jsonDecode(
          File(p.join(root, 'Scripts', 'deps-expected-plugins.json')).readAsStringSync(),
        ) as Map<String, dynamic>;
        final bundles = (manifest['_extraFiles'] as Map<String, dynamic>)
            .entries
            .where((e) => (e.value as List).any((f) => f.toString().contains(dir)))
            .map((e) => e.key.replaceAll(RegExp(r'-v2$'), ''))
            .toSet();
        final source =
            File(p.join(root, 'worker', 'src', 'gpu_plugin.rs')).readAsStringSync();
        final match = RegExp('fn $fn[^{]*\\{\\s*matches!\\(platform_suffix,([^)]*)\\)')
            .firstMatch(source);
        expect(match, isNotNull, reason: 'could not parse $fn');
        final worker = RegExp(r'"([a-z0-9-]+)"')
            .allMatches(match!.group(1)!)
            .map((m) => m.group(1)!)
            .toSet();
        expect(bundles, worker);
        // And both tiers of an x64 platform carry it, or v2 users lose it.
        for (final platform in worker.where((p) => p.endsWith('-x64'))) {
          if (platform.startsWith('macos')) continue;
          expect(manifest['_extraFiles']['$platform-v2'], manifest['_extraFiles'][platform],
              reason: '$platform-v2 must carry the same files as $platform');
        }
        // macOS resolves Vulkan from the shared MoltenVK.
        if (worker.contains('macos-arm64')) {
          expect(manifest['_extraFiles']['macos-arm64'],
              contains('vapoursynth/moltenvk/libMoltenVK.dylib'));
        }
      });
    }

    test('does not credit components that are no longer shipped', () {
      for (final gone in _mustNotAppear) {
        expect(
          notices.contains(gone),
          isFalse,
          reason: '"$gone" is not bundled any more; remove its NOTICES entry.',
        );
      }
    });

    test('points at the licence texts it references', () {
      final referenced = RegExp(r'Licence text:\s*([A-Za-z0-9.\-]+\.txt)')
          .allMatches(notices)
          .map((m) => m.group(1)!)
          .toSet();

      for (final file in referenced) {
        expect(
          File(p.join(root, 'licenses', file)).existsSync(),
          isTrue,
          reason: 'NOTICES.txt references licenses/$file, which does not exist.',
        );
      }
      expect(referenced, isNotEmpty);
    });
  });

  group('About dialog', () {
    test('names only components that NOTICES.txt also credits', () {
      final source = File(
        p.join(root, 'app', 'lib', 'views', 'about_dialog.dart'),
      ).readAsStringSync();

      final names = RegExp(r"name:\s*'([^']+)'")
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toSet();

      expect(
        names.length,
        greaterThan(20),
        reason: 'the component list looks truncated — did the parse break?',
      );

      // "RemoveGrain / Repair" and the like carry a qualifier the notice file
      // spells differently, so match on the first word of the component name.
      final missing = names.where((n) {
        final head = n.split(RegExp(r'[ /]')).first;
        return !notices.contains(head);
      }).toList();

      expect(
        missing,
        isEmpty,
        reason: 'About dialog names component(s) absent from NOTICES.txt.',
      );
    });

    // Names alone matched, so a tile could state a different licence from its
    // NOTICES entry and pass (RemoveGrain's tile dropped its MIT component).
    // Spellings differ ("BSL 1.0" / "Boost Software License 1.0"), so compare
    // the licence families each names.
    test('states the same licence as its NOTICES entry', () {
      final source = File(
        p.join(root, 'app', 'lib', 'views', 'about_dialog.dart'),
      ).readAsStringSync();
      final tiles = RegExp(r"name:\s*'([^']+)',\s*license:\s*'([^']+)'")
          .allMatches(source)
          .map((m) => (m.group(1)!, m.group(2)!))
          .toList();
      final headings = <String, String>{
        for (final m in RegExp(r'^(\S[^\n]*?) — ([^\n]+)$', multiLine: true).allMatches(notices))
          m.group(1)!.trim(): m.group(2)!.trim(),
      };
      String key(String name) =>
          name.split(' (').first.split(' / ').first.trim().toLowerCase();

      final checked = <String>[];
      final disagree = <String>[];
      for (final (name, licence) in tiles) {
        final entry = headings.entries.where((h) => key(h.key) == key(name)).firstOrNull;
        if (entry == null) continue; // matched by its first word above
        checked.add(name);
        final a = _licenceFamilies(licence), b = _licenceFamilies(entry.value);
        // The same licences on both sides: a qualifier ("public domain
        // dedication") is not a licence family, so it may differ; a component
        // under its own licence (RemoveGrain's MIT Clense) may not.
        if (a.isEmpty || !(a.containsAll(b) && b.containsAll(a))) {
          disagree.add('$name: About "$licence", NOTICES "${entry.value}"');
        }
      }
      expect(checked.length, greaterThan(40), reason: 'the pairing looks broken');
      expect(disagree, isEmpty);
    });
  });
}

/// The licences a licence statement names, as families.
Set<String> _licenceFamilies(String text) {
  final t = text.toLowerCase();
  const words = {
    'lgpl': 'lgpl', 'cc by-nc-sa': 'cc-by-nc-sa', 'wtfpl': 'wtfpl', 'mit': 'mit',
    'bsd': 'bsd', 'apache': 'apache', 'isc': 'isc', 'boost': 'bsl', 'bsl': 'bsl',
    'psf': 'psf', 'python software': 'psf', 'zlib': 'zlib', 'unlicense': 'unlicense',
    'no licence': 'none stated', 'no license': 'none stated', 'no copyright': 'no copyright',
  };
  final out = {for (final MapEntry(key: w, value: f) in words.entries) if (t.contains(w)) f};
  for (final m in RegExp(r'(?<!l)gpl[ -]?v?([23])').allMatches(t)) {
    out.add('gpl${m.group(1)}');
  }
  // "dual-licensed BSD/GPL-2.0 upstream" is a note on the source, not the
  // licence VapourBox ships it under.
  if (t.contains('dual-licensed') && out.contains('bsd')) out.remove('gpl2');
  return out;
}
