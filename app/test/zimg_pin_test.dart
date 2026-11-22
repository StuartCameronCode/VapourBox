// The Linux deps build must take zimg at a pinned commit (task #103).
//
// zimg is VapourSynth's own resize. Linux builds it from git, not a release,
// because R78 reads a field (chromatic_adaptation, ZIMG_API_VERSION 2.5) no
// zimg release has. The clone used to be unpinned master: on 2026-11-21
// master's e2e43d09 ("Update graphengine") reached the 1.18.0-rc3 Linux build,
// and every job that resizes aborted with "double free or corruption" in
// vszimg::real_get_frame. Nothing in the build failed; only the bundle did.
// It came in through R78's own subprojects/zimg.wrap (`revision = HEAD`),
// which meson builds and links statically because it finds no zimg.pc.
// This checks the script, with no bundle: the pin variables, the standalone
// clone's checkout, and the wrap's. zimg_colorspace_test.rs checks the
// bundle's behaviour (docs/reports/task-103-linux-zimg-pin).
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

  test('the zimg clone checks out the pin and verifies it', () {
    final clones = [
      for (var i = 0; i < lines.length; i++)
        if (lines[i].contains('git clone') && lines[i].contains('sekrit-twc/zimg')) i,
    ];
    expect(clones, isNotEmpty, reason: 'no clone of zimg found');
    for (final i in clones) {
      expect(lines[i], isNot(contains('--depth')),
          reason: 'a shallow clone of zimg can only be master: line ${i + 1}');
      final after = lines.skip(i + 1).take(12).join('\n');
      expect(after, contains(r'checkout -q "$ZIMG_COMMIT"'),
          reason: 'line ${i + 1} clones zimg without checking out ZIMG_COMMIT');
      expect(after, contains(r'$ZIMG_GRAPHENGINE_COMMIT'),
          reason: 'line ${i + 1}: the graphengine commit is not verified');
    }
  });

  // The zimg VapourSynth's resize actually runs is R78's subprojects/zimg.wrap
  // (`revision = HEAD`), linked statically: that is the copy rc3 got from
  // master. The standalone clone above is not loaded by anything.
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
