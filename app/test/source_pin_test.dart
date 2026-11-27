// Every source the deps scripts build or download is pinned (task #110).
//
// An unpinned `git clone --depth 1` builds whatever the upstream branch holds
// the day the bundle is built, so a rebuild of the same deps version can ship
// different code with nothing in the build failing. That is how zimg master
// reached deps 1.18.0-rc3's Linux bundle and aborted every resize (task
// #103, zimg_pin_test.dart), and MVTools master moved between rc2 and rc3.
// So every clone takes a tag or a full commit from a variable defined once as
// a literal, `build_plugin` and `clone_pinned` are never called without one,
// no clone falls back to the default branch, no download names a branch, and
// a plugin both shell scripts build is pinned to the same ref in both.
//
// This reads the scripts only; it needs no deps bundle.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _repoRoot() {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'CLAUDE.md')).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not find the repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.path;
}

String _read(String name) => File(p.join(_repoRoot(), 'Scripts', name))
    .readAsStringSync()
    .replaceAll('\r\n', '\n');

/// Helper functions whose bodies clone from a ref they are passed. Their call
/// sites are checked instead.
const _cloneHelpers = {'clone_pinned', 'build_task98_plugin'};

/// A shell script's lines with each helper's body blanked (line numbers kept).
List<String> _outsideHelpers(String script, [Set<String> helpers = _cloneHelpers]) {
  final lines = script.split('\n');
  String? inside;
  for (var i = 0; i < lines.length; i++) {
    final def = RegExp(r'^(\w+)\(\)\s*\{').firstMatch(lines[i]);
    if (inside == null && def != null && helpers.contains(def.group(1))) {
      inside = def.group(1);
    }
    if (inside != null) {
      final end = lines[i] == '}';
      lines[i] = '';
      if (end) inside = null;
    }
  }
  return lines;
}

/// Logical lines (backslash continuations joined), each with the 1-based
/// number of its first physical line.
List<(int, String)> _logical(List<String> lines) {
  final out = <(int, String)>[];
  var start = 0;
  var buf = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (buf.isEmpty) start = i + 1;
    if (l.endsWith(r'\')) {
      buf.write('${l.substring(0, l.length - 1)} ');
    } else {
      buf.write(l);
      out.add((start, buf.toString()));
      buf = StringBuffer();
    }
  }
  return out;
}

/// Splits a shell command into words, keeping each double-quoted string whole
/// (quotes included, backslash escapes honoured).
List<String> _words(String line) {
  final words = <String>[];
  var i = 0;
  while (i < line.length) {
    if (line[i] == ' ' || line[i] == '\t') {
      i++;
      continue;
    }
    final w = StringBuffer();
    while (i < line.length && line[i] != ' ' && line[i] != '\t') {
      if (line[i] == '"') {
        w.write('"');
        i++;
        while (i < line.length && line[i] != '"') {
          if (line[i] == r'\' && i + 1 < line.length) {
            w.write(line[i]);
            i++;
          }
          w.write(line[i]);
          i++;
        }
        w.write('"');
        i++;
      } else {
        w.write(line[i]);
        i++;
      }
    }
    words.add(w.toString());
  }
  return words;
}

/// The values a script assigns to [name] at the start of a line.
List<String> _definitions(String script, String name) => [
      for (final m in RegExp('^\\s*$name="([^"]*)"', multiLine: true).allMatches(script))
        m.group(1)!,
    ];

final _sha = RegExp(r'^[0-9a-f]{40}$');
bool _isPin(String v) =>
    v.isNotEmpty && !v.contains(r'$') && !{'master', 'main', 'HEAD'}.contains(v);

/// The variable a ref argument names (`"$X"`, `$X`, `${X}`), or null.
String? _varOf(String arg) =>
    RegExp(r'^"?\$\{?([A-Z][A-Z0-9_]*)\}?"?;?$').firstMatch(arg)?.group(1);

void main() {
  const shellScripts = ['download-deps-linux.sh', 'download-deps-macos.sh'];
  final scripts = {for (final s in shellScripts) s: _read(s)};
  final windows = _read('download-deps-windows.ps1');

  // Checks that a ref argument names a variable defined once, as a pin.
  void expectPinnedRef(String script, String file, int line, String what, String arg) {
    final name = _varOf(arg);
    if (name == null) {
      expect(_isPin(arg.replaceAll('"', '')), isTrue,
          reason: '$file:$line: $what takes "$arg", which is not a tag or commit');
      return;
    }
    final defs = _definitions(script, name);
    expect(defs, hasLength(1),
        reason: '$file:$line: $what takes \$$name, which must be assigned exactly '
            'once as a literal (found ${defs.length})');
    if (defs.length == 1) {
      expect(_isPin(defs.single), isTrue,
          reason: '$file:$line: \$$name="${defs.single}" is not a tag or full commit');
    }
  }

  for (final file in shellScripts) {
    final script = scripts[file]!;
    final lines = _outsideHelpers(script);
    final logical = _logical(lines);

    group(file, () {
      test('every git clone takes a pinned ref', () {
        var clones = 0;
        for (final (n, l) in logical) {
          if (!RegExp(r'\bgit clone\b').hasMatch(l) || l.trimLeft().startsWith('#')) continue;
          clones++;
          final branch = RegExp(r'--branch\s+(\S+)').firstMatch(l);
          if (branch != null) {
            expectPinnedRef(script, file, n, 'git clone', branch.group(1)!);
            continue;
          }
          // A full clone followed by a checkout of a pin (zimg, task #103).
          final after = lines.skip(n).take(3).join('\n');
          final checkout = RegExp(r'checkout -q (\S+)').firstMatch(after);
          expect(checkout, isNotNull,
              reason: '$file:$n clones a default branch: use clone_pinned, or '
                  'build_plugin with a ref\n$l');
          if (checkout != null) {
            expectPinnedRef(script, file, n, 'git checkout', checkout.group(1)!);
          }
        }
        expect(clones, greaterThan(0));
      });

      test('no clone falls back to the default branch', () {
        for (final (n, l) in logical) {
          expect(l, isNot(matches(RegExp(r'\|\|\s*git clone'))),
              reason: '$file:$n: a failed pinned clone must fail, not clone master');
        }
      });

      test('every build_plugin call passes a pinned ref', () {
        var calls = 0;
        for (final (n, l) in logical) {
          final t = l.trimLeft();
          if (!t.startsWith('build_plugin ')) continue;
          calls++;
          final args = _words(t).skip(1).toList();
          expect(args, hasLength(5),
              reason: '$file:$n: build_plugin takes <name> <repo> <lib> <cmd> <ref>; '
                  'got ${args.length} arguments');
          if (args.length == 5) {
            expectPinnedRef(script, file, n, 'build_plugin ${args[0]}', args[4]);
          }
        }
        expect(calls, greaterThan(0));
      });

      test('every clone_pinned call passes a pinned ref', () {
        // build_plugin's own call passes the ref it was given, which the
        // build_plugin test checks at each call site.
        final callers = _logical(_outsideHelpers(script, {..._cloneHelpers, 'build_plugin'}));
        var calls = 0;
        for (final (n, l) in callers) {
          for (final m in RegExp(r'\bclone_pinned (.*)').allMatches(l)) {
            calls++;
            final args = _words(m.group(1)!);
            expect(args.length, greaterThanOrEqualTo(3),
                reason: '$file:$n: clone_pinned takes <repo> <dir> <ref> [--submodules]');
            if (args.length >= 3) {
              expectPinnedRef(script, file, n, 'clone_pinned ${args[1]}', args[2]);
            }
          }
        }
        expect(calls, greaterThan(0), reason: 'no clone_pinned call found');
      });

      test('build_plugin and clone_pinned refuse an empty ref', () {
        for (final fn in ['build_plugin', 'clone_pinned']) {
          final body = RegExp('^$fn\\(\\) \\{\\n([\\s\\S]*?)\\n\\}', multiLine: true)
              .firstMatch(script)
              ?.group(1);
          expect(body, isNotNull, reason: '$file defines no $fn()');
          expect(body, contains('-z "'), reason: '$file: $fn() must test for an empty ref');
        }
      });
    });
  }

  // Scoped to GitHub's raw and archive URLs: BtbN's FFmpeg `latest` builds
  // are the same kind of exposure and are task #123's, not this test's.
  // An exception names its task.
  const urlExceptions = <String, String>{};
  test('no download names a branch', () {
    final branchUrl = RegExp(
        r'https://(?:github\.com/[^/\s"]+/[^/\s"]+/(?:raw|blob)/(?:master|main|HEAD)/'
        r'|raw\.githubusercontent\.com/[^/\s"]+/[^/\s"]+/(?:master|main|HEAD)/'
        r'|github\.com/[^\s"]*/archive/(?:refs/heads/|(?:master|main)\.))[^\s"]*');
    for (final MapEntry(key: file, value: text) in {
      ...scripts,
      'download-deps-windows.ps1': windows,
    }.entries) {
      for (final m in branchUrl.allMatches(text)) {
        if (urlExceptions.containsKey(m.group(0))) continue;
        final line = '\n'.allMatches(text.substring(0, m.start)).length + 1;
        fail('$file:$line downloads from a branch: ${m.group(0)}');
      }
    }
  });

  // Every plugin both shell scripts build from source, by the variable each
  // uses. A pin missing from one side is a failure too.
  const shared = [
    'VS_TAG', 'MVTOOLS_COMMIT', 'ZNEDI3_COMMIT', 'NNEDI3_COMMIT', 'NNEDI3CL_TAG',
    'TTEMPSMOOTH_TAG', 'MISCFILTERS_COMMIT', 'REMOVEGRAIN_COMMIT', 'RETINEX_COMMIT',
    'ADDGRAIN_TAG', 'VIVTC_COMMIT', 'NEO_F3KDB_TAG', 'CAS_TAG', 'DEBLOCK_TAG',
    'AWARPSHARP2_TAG', 'DESCRATCH_COMMIT', 'FMTCONV_TAG', 'FFT3DFILTER_TAG',
    'DCTFILTER_TAG', 'DFTTEST_COMMIT', 'LGHOST_TAG', 'CTMF_TAG', 'TCANNY_COMMIT',
    'EEDI3_TAG', 'BM3D_TAG', 'KNLM_TAG', 'MVSFUNC_COMMIT', 'ADJUST_COMMIT',
  ];
  test('Linux and macOS pin each shared source to the same ref', () {
    for (final name in shared) {
      final linux = _definitions(scripts['download-deps-linux.sh']!, name);
      final macos = _definitions(scripts['download-deps-macos.sh']!, name);
      expect(linux, hasLength(1), reason: 'download-deps-linux.sh must define $name once');
      expect(macos, hasLength(1), reason: 'download-deps-macos.sh must define $name once');
      if (linux.length == 1 && macos.length == 1) {
        expect(macos.single, linux.single, reason: '$name differs between the scripts');
      }
    }
  });

  // Windows downloads the same three files at the same commits.
  test('Windows downloads mvsfunc, adjust.py and the weights at the same commits', () {
    final linux = scripts['download-deps-linux.sh']!;
    for (final (name, repo) in [
      ('MVSFUNC_COMMIT', 'HomeOfVapourSynthEvolution/mvsfunc'),
      ('ADJUST_COMMIT', 'dubhater/vapoursynth-adjust'),
      ('ZNEDI3_COMMIT', 'sekrit-twc/znedi3'),
    ]) {
      final defs = _definitions(linux, name);
      expect(defs, hasLength(1));
      if (defs.length != 1) continue;
      expect(_sha.hasMatch(defs.single), isTrue, reason: '$name is not a full commit');
      expect(windows, contains(defs.single),
          reason: 'download-deps-windows.ps1 must fetch $repo at $name (${defs.single})');
    }
  });
}
