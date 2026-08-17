// Packaging lint.
//
// Every packaging script used to copy VapourSynth templates by explicit
// filename. That works right up until someone adds a module: the filter runs
// perfectly in development, because the debug worker searches upward and finds
// `worker/templates/`, and then dies in a release build with a bare
// ModuleNotFoundError from inside vspipe.
//
// Six vendored modules were added in one sitting and all six would have been
// missing from every packaged build. This asserts the scripts glob instead.

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
      throw StateError('could not locate the repo root');
    }
    dir = parent;
  }
}

void main() {
  final root = _repoRoot();

  final modules = Directory(p.join(root, 'worker', 'templates'))
      .listSync()
      .whereType<File>()
      .map((f) => p.basename(f.path))
      .where((n) => n.endsWith('.py'))
      .toList()
    ..sort();

  test('there are vendored modules to package', () {
    // Guards against the assertions below passing vacuously.
    expect(modules.length, greaterThan(2), reason: 'found: $modules');
  });

  for (final script in [
    'Scripts/package-macos.sh',
    'Scripts/package-linux.sh',
    'Scripts/package-windows.ps1',
  ]) {
    test('$script copies every template module, not a hand-written list', () {
      final body = File(p.join(root, script)).readAsStringSync();

      // A glob covers whatever exists now and whatever is added later.
      final globs = RegExp(r'templates[\\/]?["\\]*\*\.py').hasMatch(body) ||
          body.contains('templates/"*.py') ||
          body.contains(r'templates\*.py');
      if (globs) return;

      // Otherwise every module must be named individually — and if that is the
      // approach, adding one silently breaks the release build.
      final missing =
          modules.where((m) => !body.contains(m)).toList(growable: false);
      expect(
        missing,
        isEmpty,
        reason: 'these modules would be absent from the package, so the '
            'filters that import them fail only in a release build: $missing. '
            'Copy templates with a *.py glob instead of naming each file.',
      );
    });
  }
}
