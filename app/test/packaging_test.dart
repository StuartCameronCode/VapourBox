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
    final iss = _read(root, ['packaging', 'windows', 'vapourbox.iss']);
    final installer = _read(root, ['Scripts', 'build-windows-installer.ps1']);

    test('installs per-user, because deps download beside the executable', () {
      // dependency_manager.dart puts deps\ next to the exe on Windows; an
      // install under Program Files makes that download fail.
      final deps =
          _read(root, ['app', 'lib', 'services', 'dependency_manager.dart']);
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
      expect(
          iss,
          contains(
              'OutputBaseFilename={#AppName}-{#AppVersion}-windows-x64-setup'));
      expect(installer, contains(r'VapourBox-$Version-windows-x64-setup.exe'));

      final workflow =
          _read(root, ['.github', 'workflows', 'build-windows.yml']);
      expect(workflow, contains('build-windows-installer.ps1'));
      expect(workflow, contains('-windows-x64-setup.exe\n'));
      expect(workflow, contains('-windows-x64.zip\n'));

      final local = _read(root, ['Scripts', 'package-windows.ps1']);
      expect(local, contains('build-windows-installer.ps1'));

      final upload = _read(root, ['Scripts', 'ci-build-and-release.sh']);
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
      expect(package,
          contains(r'APPIMAGE_FILE="VapourBox-$VERSION-$AI_ARCH.AppImage"'));
      expect(
        package,
        contains(r'|latest|VapourBox-*-$AI_ARCH.AppImage.zsync"'),
        reason: 'the update pattern must be the output filename with the '
            'version wildcarded, plus .zsync',
      );
    });

    test('the AppImage is named App-version-arch, without "linux"', () {
      // The AppImage catalog flags "linux" in an AppImage's file name, and
      // wants the machine's own architecture name. The tarball is not an
      // AppImage and keeps linux-<arch>.
      expect(package, contains('AI_ARCH="x86_64"'));
      expect(package, contains('AI_ARCH="aarch64"'));
      expect(
          package, contains(r'PACKAGE_NAME="VapourBox-$VERSION-linux-$ARCH"'));
      expect(package, contains(r'TAR_FILE="$PACKAGE_NAME.tar.gz"'));
    });

    test('1.2.0 can still find its update under the name it embedded', () {
      // 1.2.0 shipped as VapourBox-1.2.0-linux-<arch>.AppImage and looks for
      // VapourBox-*-linux-<arch>.AppImage.zsync on the latest release. That
      // file must keep being published, as a copy of the real .zsync, or
      // every 1.2.0 AppImage silently stops updating.
      expect(
          package,
          contains(
              r'LEGACY_ZSYNC="VapourBox-$VERSION-linux-$ARCH.AppImage.zsync"'));
      expect(package, contains(r'cp "$APPIMAGE_FILE.zsync" "$LEGACY_ZSYNC"'));
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
      for (final arch in {'x64': 'x86_64', 'arm64': 'aarch64'}.entries) {
        expect(workflow, contains('-${arch.value}.AppImage\n'));
        expect(workflow, contains('-${arch.value}.AppImage.zsync\n'));
        expect(workflow, contains('-linux-${arch.key}.AppImage.zsync\n'),
            reason: 'the bridge .zsync for 1.2.0 must be uploaded too');
        expect(workflow, isNot(contains('-linux-${arch.key}.AppImage\n')));
      }
    });

    test('the AppImage bundles the deps zips; the tarball does not', () {
      final workflow = _read(root, ['.github', 'workflows', 'build-linux.yml']);
      expect('--bundle-deps bundled-deps'.allMatches(workflow).length, 2,
          reason: 'both architectures must bundle');
      // Only x64 is tiered, so only x64 carries a v2 delta.
      expect('-v2-delta.zip.sha256.json'.allMatches(workflow).length, 1);
      // The zips go into the AppDir after the tarball's tree was copied into
      // it, never into the tree both are made from.
      expect(package, contains(r'"$APPDIR/usr/lib/vapourbox/bundled-deps"'));
      expect(package, isNot(contains(r'"$PACKAGE_DIR/bundled-deps')));
      // The directory name is the one DependencyManager looks in.
      final manager =
          _read(root, ['app', 'lib', 'services', 'dependency_manager.dart']);
      expect(manager, contains("'bundled-deps'"));
    });

    test('ships AppStream metadata for the application id', () {
      final cmake = _read(root, ['app', 'linux', 'CMakeLists.txt']);
      final id = RegExp(r'set\(APPLICATION_ID "([^"]+)"\)')
          .firstMatch(cmake)!
          .group(1)!;
      // .appdata.xml: the only name the AppImage catalog's lint looks for.
      final appdata = _read(root, ['packaging', 'linux', '$id.appdata.xml']);
      expect(appdata, contains('<id>$id</id>'));
      expect(appdata,
          contains('<launchable type="desktop-id">$id.desktop</launchable>'));
      expect(appdata, contains('<project_license>'));
      // Stamped at package time, so neither can go stale.
      expect(appdata, contains('<release version="@VERSION@" date="@DATE@">'));
      expect(appdata, contains('/v@VERSION@/docs/images/screenshot.png'));
      expect(
          File(p.join(root, 'docs', 'images', 'screenshot.png')).existsSync(),
          isTrue);
      expect(package,
          contains(r'"$APPDIR/usr/share/metainfo/$APP_ID.appdata.xml"'));
      // appimagetool's own validation fetches the screenshot, whose tag does
      // not exist until the release is published.
      expect(package, contains('--no-appstream'));
      expect(package, contains('appstreamcli validate --no-net'));
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
