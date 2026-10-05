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

  // The Linux AppImage embeds update information naming a `.zsync` on the
  // latest GitHub release. Three files have to agree on that name, and nothing
  // fails at build time if they don't — the updater just finds nothing.
  group('Linux AppImage update information', () {
    final package =
        File(p.join(root, 'Scripts', 'package-linux.sh')).readAsStringSync();

    test('names the .zsync the script itself produces', () {
      expect(package, contains(r'APPIMAGE_FILE="$PACKAGE_NAME.AppImage"'));
      expect(package, contains(r'PACKAGE_NAME="VapourBox-$VERSION-linux-$ARCH"'));
      expect(
        package,
        contains(r'|latest|VapourBox-*-linux-$ARCH.AppImage.zsync"'),
        reason: 'the update pattern must be the output filename with the '
            'version wildcarded, plus .zsync',
      );
    });

    test('the release upload carries the AppImage and its .zsync', () {
      final upload = File(p.join(root, 'Scripts', 'ci-build-and-release.sh'))
          .readAsStringSync();
      final finds = upload
          .split('\n')
          .where((l) => l.startsWith('find ') && l.contains('*.tar.gz'))
          .toList();
      expect(finds, isNotEmpty);
      for (final line in finds) {
        expect(line, contains('"*.AppImage"'));
        expect(line, contains('"*.AppImage.zsync"'));
      }

      final workflow =
          File(p.join(root, '.github', 'workflows', 'build-linux.yml'))
              .readAsStringSync();
      for (final arch in ['x64', 'arm64']) {
        expect(workflow, contains('-linux-$arch.AppImage\n'));
        expect(workflow, contains('-linux-$arch.AppImage.zsync\n'));
      }
    });

    test('the desktop entry and icon are named for the application id', () {
      final cmake = File(p.join(root, 'app', 'linux', 'CMakeLists.txt'))
          .readAsStringSync();
      final id = RegExp(r'set\(APPLICATION_ID "([^"]+)"\)')
          .firstMatch(cmake)!
          .group(1)!;
      final dir = p.join(root, 'packaging', 'linux');
      final desktop = File(p.join(dir, '$id.desktop'));
      expect(desktop.existsSync(), isTrue);
      expect(File(p.join(dir, '$id.png')).existsSync(), isTrue);
      final body = desktop.readAsStringSync();
      expect(body, contains('Icon=$id\n'));
      expect(body, contains('StartupWMClass=$id\n'));
      expect(package, contains('APP_ID="$id"'));
    });
  });
}
