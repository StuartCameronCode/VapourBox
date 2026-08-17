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
  });
}
