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
// PKG_CONFIG_PATH, and that graphengine is not one of task #109's bad commits
// (task #127). zimg_colorspace_test.rs checks the bundle's behaviour
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

// Task #109: graphengine f6211289 ("Exclude fused nodes from buffer sizing
// calculation") leaves a fused error-diffusion node's context out of
// get_tmp_size(), so every error-diffusion conversion writes past its buffer
// and VapourSynth aborts with "double free or corruption" in
// vszimg::real_get_frame (zimg e2e43d09, the 1.18.0-rc3 Linux build). Every
// commit from it to e9b10267 has the bug; 308d3735 fixes it
// (docs/reports/task-109-graphengine-tmp-overrun, task-126-zimg-9806db42).
const _badGraphengine = <String, String>{
  'f6211289743157805780e2d22baa4d59edfc90d7': 'Exclude fused nodes from buffer sizing calculation',
  '734f3bf199a244e91943bc09a9dae3469db9d073': 'Check buffering calculation in test',
  '5c1c79d54796a2c85c6cb44665b602dd0b8f35c2': 'Skip unreachable planes when estimating cache usage',
  'a939a669635c3204c6b140c86c8e945498118d1f': 'Access node registry during simulation through a callback',
  '733d3dc7acdd9e5c7ac149f0c697e6d6ec8864e0': 'Ignore cursor alignment during planar simulation',
  '444ec4c08722461532dbed4fbd9ea50952540829': 'More accurately test buffer sizing',
  '89b10e2938242c034d6f2ea62d4952f2d8e4f39f': 'Sync testcommon libraries',
  '91c6af4c795c5396d8b974f24b4d2e2ecca04e2d': 'Update to C++17 (zimg e2e43d09\'s pin)',
  'e9b10267f052cb34b749b36de863ed9a5bbd614d': 'Fix testapp includes',
};

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

  test("graphengine is not one of task #109's bad commits", () {
    final pin = pinned('ZIMG_GRAPHENGINE_COMMIT');
    expect(pin, isNotNull);
    for (final entry in _badGraphengine.entries) {
      expect(pin!.startsWith(entry.key.substring(0, 8)), isFalse,
          reason: 'ZIMG_GRAPHENGINE_COMMIT is ${entry.key.substring(0, 8)} '
              '("${entry.value}"): graphengine f6211289..e9b10267 leave an '
              "error-diffusion node's context out of get_tmp_size(), so every "
              'error-diffusion resize writes past its buffer and aborts '
              '(task #109). 308d3735 fixes it.');
    }
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
