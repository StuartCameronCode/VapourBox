// The Linux deps build must take zimg at a pinned commit (task #103).
//
// zimg is VapourSynth's own resize. Linux builds it from git, not a release,
// because R78 reads a field (chromatic_adaptation, ZIMG_API_VERSION 2.5) no
// zimg release has. The clone used to be unpinned master: on 2026-11-21
// master's e2e43d09 ("Update graphengine") reached the 1.18.0-rc3 Linux build,
// and every job that resizes aborted with "double free or corruption" in
// vszimg::real_get_frame. Nothing in the build failed; only the bundle did.
// It came in through R78's own subprojects/zimg.wrap (`revision = HEAD`),
// which meson builds and links statically because it is offered no zimg.pc.
// That is deliberate (task #111): VapourSynth's meson setup gets no
// environment, and no standalone libzimg.so is built or shipped (the one
// built until #111 was loaded by nothing).
// This checks the script, with no bundle: the pin variables, the wrap's
// pin, that no standalone zimg is built, and that the setup gets no
// PKG_CONFIG_PATH. zimg_colorspace_test.rs checks the bundle's behaviour
// (docs/reports/task-103-linux-zimg-pin, task-111-meson-setup-env).
// Every other source clone and download is checked by source_pin_test.dart
// (task #110).
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

void main() {
  final script = File(p.join(_repoRoot(), 'Scripts', 'download-deps-linux.sh'))
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final lines = script.split('\n');

  String? pinned(String name) =>
      RegExp('^$name="([0-9a-f]{40})"', multiLine: true).firstMatch(script)?.group(1);

  test('zimg and its graphengine are pinned to full commits', () {
    expect(pinned('ZIMG_COMMIT'), isNotNull,
        reason: 'download-deps-linux.sh must declare ZIMG_COMMIT="<40-hex SHA>"');
    expect(pinned('ZIMG_GRAPHENGINE_COMMIT'), isNotNull,
        reason: 'download-deps-linux.sh must declare '
            'ZIMG_GRAPHENGINE_COMMIT="<40-hex SHA>"');
  });

  // Task #111: the standalone libzimg.so was built, shipped and loaded by
  // nothing. A clone of zimg here would be that again.
  test('no standalone zimg is built or shipped', () {
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('#')) continue;
      expect(line.contains('git clone') && line.contains('sekrit-twc/zimg'), isFalse,
          reason: 'line ${i + 1} clones zimg: VapourSynth links the wrap\'s zimg (task #111)');
      expect(line.contains('cp ') && line.contains('libzimg'), isFalse,
          reason: 'line ${i + 1} copies a libzimg into the bundle (task #111)');
      expect(line.contains('zimg.pc') && !line.contains('echo'), isFalse,
          reason: 'line ${i + 1} offers a zimg.pc: meson would link it instead of '
              'the pinned subproject (task #111)');
    }
  });

  // Task #111: the setup's environment used to be lost to a `\` continuation
  // that ended on a comment. Restoring PKG_CONFIG_PATH "fixes" it into linking
  // a different zimg; the setup is meant to get no environment at all.
  test("VapourSynth's meson setup gets no environment", () {
    final setups = [
      for (var i = 0; i < lines.length; i++)
        if (lines[i].contains('mesonbuild.mesonmain setup build')) i,
    ];
    expect(setups, hasLength(1), reason: "expected one meson setup (VapourSynth's)");
    final i = setups.single;
    expect(lines[i].trimLeft(), startsWith(r'"$PYTHON_BIN" -m mesonbuild.mesonmain'),
        reason: 'line ${i + 1}: nothing may precede the meson command');
    expect(lines[i - 1].trimRight().endsWith(r'\'), isFalse,
        reason: 'line $i continues into the meson setup: it must get no prefixes');
    var end = i;
    while (lines[end].trimRight().endsWith(r'\')) {
      end++;
    }
    final command = lines.sublist(i, end + 1).join('\n');
    for (final name in ['PKG_CONFIG_PATH', 'CC=', 'CXX=']) {
      expect(command, isNot(contains(name)),
          reason: 'the VapourSynth meson setup must not set $name (task #111)');
    }
  });

  // The zimg VapourSynth's resize actually runs is R78's subprojects/zimg.wrap
  // (`revision = HEAD`), linked statically: that is the copy rc3 got from
  // master.
  test("VapourSynth's zimg subproject is pinned and verified", () {
    expect(script, contains(r'subprojects/zimg.wrap'),
        reason: 'the VapourSynth block must pin subprojects/zimg.wrap');
    expect(script, contains(r's/^revision = HEAD\$/revision = $ZIMG_COMMIT/'),
        reason: 'the wrap must be rewritten to ZIMG_COMMIT');
    expect(script, contains(r"grep -qx 'revision = HEAD'"),
        reason: 'the rewrite must fail loudly if the wrap no longer says HEAD');
    expect(script, contains(r'git -C subprojects/zimg rev-parse HEAD'),
        reason: 'the subproject zimg meson set up must be checked');
    expect(script, contains(r'git -C subprojects/zimg/graphengine rev-parse HEAD'),
        reason: "the subproject's graphengine must be checked");
  });
}
