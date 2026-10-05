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

/// Reads a repo file with LF endings. A Windows checkout gives these files
/// CRLF, so an assertion on a whole line (`'Icon=$id\n'`) fails there only.
String _read(String root, List<String> parts) =>
    File(p.joinAll([root, ...parts]))
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

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

  // The Windows installer is built from the same tree as the zip, by a script
  // of its own that both the local packaging script and CI call.
  group('Windows installer', () {
    final iss = File(p.join(root, 'packaging', 'windows', 'vapourbox.iss'))
        .readAsStringSync();
    final installer =
        File(p.join(root, 'Scripts', 'build-windows-installer.ps1'))
            .readAsStringSync();

    test('installs per-user, because deps download beside the executable', () {
      // dependency_manager.dart puts deps\ next to the exe on Windows; an
      // install under Program Files makes that download fail.
      final deps = File(p.join(
              root, 'app', 'lib', 'services', 'dependency_manager.dart'))
          .readAsStringSync();
      expect(deps, contains("path.join(appDir, 'deps', 'windows-x64')"),
          reason: 'if deps no longer live beside the exe, the per-user '
              'restriction below can be revisited');
      expect(iss, contains('PrivilegesRequired=lowest'));
      expect(iss, isNot(contains('PrivilegesRequiredOverridesAllowed')));
    });

    test('uninstall removes what the app downloaded; upgrade does not', () {
      final uninstall = iss.split('[UninstallDelete]').last;
      expect(uninstall, contains(r'{app}\deps'));
      expect(uninstall, contains(r'{app}\addons'));
      final installDelete =
          iss.split('[InstallDelete]').last.split('[Files]').first;
      expect(installDelete, isNot(contains(r'{app}\deps')));
      expect(installDelete, isNot(contains(r'{app}\addons')));
      expect(installDelete, contains(r'{app}\templates'));
    });

    test('one filename across the .iss, the script, CI and the upload', () {
      expect(iss,
          contains('OutputBaseFilename={#AppName}-{#AppVersion}-windows-x64-setup'));
      expect(installer, contains(r'VapourBox-$Version-windows-x64-setup.exe'));

      final workflow =
          File(p.join(root, '.github', 'workflows', 'build-windows.yml'))
              .readAsStringSync();
      expect(workflow, contains('build-windows-installer.ps1'));
      expect(workflow, contains('-windows-x64-setup.exe\n'));
      expect(workflow, contains('-windows-x64.zip\n'));

      final local = File(p.join(root, 'Scripts', 'package-windows.ps1'))
          .readAsStringSync();
      expect(local, contains('build-windows-installer.ps1'));

      final upload = File(p.join(root, 'Scripts', 'ci-build-and-release.sh'))
          .readAsStringSync();
      final finds = upload
          .split('\n')
          .where((l) => l.startsWith('find ') && l.contains('*.zip'))
          .toList();
      expect(finds, isNotEmpty);
      for (final line in finds) {
        expect(line, contains('"*-setup.exe"'));
      }
    });
  });

  // The Linux AppImage embeds update information naming a `.zsync` on the
  // latest GitHub release. Three files have to agree on that name, and nothing
  // fails at build time if they don't — the updater just finds nothing.
  group('Linux AppImage update information', () {
    final package = _read(root, ['Scripts', 'package-linux.sh']);

    test('names the .zsync the script itself produces', () {
      expect(package, contains(r'APPIMAGE_FILE="$PACKAGE_NAME.AppImage"'));
      expect(
          package, contains(r'PACKAGE_NAME="VapourBox-$VERSION-linux-$ARCH"'));
      expect(
        package,
        contains(r'|latest|VapourBox-*-linux-$ARCH.AppImage.zsync"'),
        reason: 'the update pattern must be the output filename with the '
            'version wildcarded, plus .zsync',
      );
    });

    test('the release upload carries the AppImage and its .zsync', () {
      final upload = _read(root, ['Scripts', 'ci-build-and-release.sh']);
      final finds = upload
          .split('\n')
          .where((l) => l.startsWith('find ') && l.contains('*.tar.gz'))
          .toList();
      expect(finds, isNotEmpty);
      for (final line in finds) {
        expect(line, contains('"*.AppImage"'));
        expect(line, contains('"*.AppImage.zsync"'));
      }

      final workflow = _read(root, ['.github', 'workflows', 'build-linux.yml']);
      for (final arch in ['x64', 'arm64']) {
        expect(workflow, contains('-linux-$arch.AppImage\n'));
        expect(workflow, contains('-linux-$arch.AppImage.zsync\n'));
      }
    });

    test('the desktop entry and icon are named for the application id', () {
      final cmake = _read(root, ['app', 'linux', 'CMakeLists.txt']);
      final id = RegExp(r'set\(APPLICATION_ID "([^"]+)"\)')
          .firstMatch(cmake)!
          .group(1)!;
      final dir = p.join(root, 'packaging', 'linux');
      expect(File(p.join(dir, '$id.desktop')).existsSync(), isTrue);
      expect(File(p.join(dir, '$id.png')).existsSync(), isTrue);
      final body = _read(root, ['packaging', 'linux', '$id.desktop']);
      expect(body, contains('Icon=$id\n'));
      expect(body, contains('StartupWMClass=$id\n'));
      expect(package, contains('APP_ID="$id"'));
    });
  });
}
