// The three download-deps-* scripts must pin the SAME FFmpeg series.
//
// A per-OS FFmpeg is a per-OS encoder. Everything in `pipeline_executor.rs`
// — the accumulated `-vf` chain, the colour metadata flags, `-ss`/`-frames:v`
// trimming, the hardware-encoder options — is interpreted by whichever binary
// the bundle happens to carry, so a version skew means the same job produces
// subtly different output depending on where it ran. That is the same class of
// bug the fmtconv and zsmooth version pins exist to prevent, and it is harder
// to spot because nothing fails.
//
// This is not hypothetical. Measured 2026-08-31, before this test existed:
//
//   Windows    master N-125978 (post-9.0)   BtbN `master-latest`, UNPINNED
//   macOS x64  9.0.1                        evermeet `getrelease`, UNPINNED
//   macOS arm64 9.0.1                       martin-riedl `latest`, UNPINNED
//   Linux      7.1                          BtbN `n7.1`, pinned — two majors behind
//
// Three of the four floated on "latest" URLs and the fourth was pinned to a
// series that upstream then garbage-collected, which 404'd the Linux deps build
// outright. Both failure modes are caught here: an unpinned URL has no series
// to find, and a pin that drifts stops matching its siblings.
//
// A series pin against a rolling tag still moves within the series: BtbN's
// `n9.0-latest` went from n9.0.2-61 (deps 1.18.0-rc3) to n9.0.2-963 (rc4),
// whose swscale broke a heavy test (task #123). So every platform also pins
// one exact build with a SHA-256: macOS by martin-riedl build ID, Windows and
// Linux by BtbN build string, mirrored on our `ffmpeg-mirror-v1` release.
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

/// The series each script pins, by the assignment it declares.
///
/// Deliberately reads the *variable*, not the URL: the URLs differ per platform
/// and per host (BtbN asset names, a martin-riedl build ID or redirect), and
/// the variable is the single thing they are all built from.
({String script, String series}) _pin(String root, String file, RegExp pattern) {
  final text = File(p.join(root, 'Scripts', file)).readAsStringSync();
  final match = pattern.firstMatch(text);
  expect(
    match,
    isNotNull,
    reason: 'Scripts/$file declares no FFmpeg series pin matching '
        '${pattern.pattern}. If the URL was changed to an unpinned "latest" '
        'build, pin it instead — that is how the platforms drifted apart before.',
  );
  return (script: file, series: match!.group(1)!);
}

void main() {
  final root = _repoRoot();

  group('FFmpeg version pins', () {
    test('all three download scripts pin the same series', () {
      final pins = <({String script, String series})>[
        _pin(root, 'download-deps-linux.sh', RegExp(r'^FFMPEG_SERIES="([^"]+)"', multiLine: true)),
        _pin(root, 'download-deps-macos.sh', RegExp(r'^FFMPEG_SERIES="([^"]+)"', multiLine: true)),
        _pin(root, 'download-deps-windows.ps1', RegExp(r'^\$FFmpegSeries = "([^"]+)"', multiLine: true)),
      ];

      final distinct = pins.map((e) => e.series).toSet();
      expect(
        distinct,
        hasLength(1),
        reason: 'the deps scripts pin different FFmpeg series: '
            '${pins.map((e) => "${e.script}=${e.series}").join(", ")}. '
            'Bump them together or the same job encodes differently per OS.',
      );
    });

    test('the series is a bare major.minor, not a moving target', () {
      // "master" or "latest" would defeat the point: both are unpinned. The
      // exact build is pinned beside it (FFMPEG_BTBN_BUILD, the macOS build
      // IDs); the series is what the platforms must agree on.
      final linux = _pin(
        root,
        'download-deps-linux.sh',
        RegExp(r'^FFMPEG_SERIES="([^"]+)"', multiLine: true),
      );
      expect(
        linux.series,
        matches(RegExp(r'^\d+\.\d+$')),
        reason: 'FFMPEG_SERIES should be a major.minor like "9.0", got '
            '"${linux.series}"',
      );
    });

    test("macOS's exact pins lie within the shared series", () {
      // martin-riedl.de keeps every build-ID URL (<id>_<version>), so each
      // arch is pinned exactly, with a SHA-256 per zip (x64: task #45; arm64
      // since its `latest` moved to 9.1, deps 1.18.0-rc3). Each still has to be
      // inside the series everyone else is on, or macOS silently diverges.
      final text = File(p.join(root, 'Scripts', 'download-deps-macos.sh')).readAsStringSync();
      final series = RegExp(r'^FFMPEG_SERIES="([^"]+)"', multiLine: true).firstMatch(text)!.group(1)!;
      for (final arch in ['X64', 'ARM64']) {
        final build = RegExp('^FFMPEG_MACOS_${arch}_BUILD="(\\d+)_([^"]+)"', multiLine: true).firstMatch(text);
        expect(build, isNotNull,
            reason: 'download-deps-macos.sh no longer pins an exact $arch build '
                '(FFMPEG_MACOS_${arch}_BUILD="<id>_<version>")');
        expect(
          build!.group(2)!,
          startsWith('$series.'),
          reason: 'the pinned $arch build ${build.group(0)} is not in the '
              '$series series the other platforms use',
        );
        for (final name in ['FFMPEG_MACOS_${arch}_FFMPEG_SHA256', 'FFMPEG_MACOS_${arch}_FFPROBE_SHA256']) {
          expect(
            RegExp('^$name="[0-9a-f]{64}"\$', multiLine: true).hasMatch(text),
            isTrue,
            reason: 'download-deps-macos.sh must pin $name as a SHA-256',
          );
        }
      }
    });

    test("BtbN builds are pinned exactly, within the series, with a SHA-256", () {
      // Task #123: BtbN's rolling `latest` moved within 9.0 between two deps
      // builds. Windows and Linux pin the same build string, fetched from our
      // mirror or BtbN's dated autobuild tag, each asset by its SHA-256.
      final linux = File(p.join(root, 'Scripts', 'download-deps-linux.sh')).readAsStringSync();
      final windows = File(p.join(root, 'Scripts', 'download-deps-windows.ps1')).readAsStringSync();
      String shVar(String name) {
        final m = RegExp('^$name="([^"]*)"\$', multiLine: true).firstMatch(linux);
        expect(m, isNotNull, reason: 'download-deps-linux.sh must declare $name');
        return m!.group(1)!;
      }
      String psVar(String name) {
        final m = RegExp('^\\\$$name = "([^"]*)"', multiLine: true).firstMatch(windows);
        expect(m, isNotNull, reason: 'download-deps-windows.ps1 must declare \$$name');
        return m!.group(1)!;
      }

      final series = shVar('FFMPEG_SERIES');
      final build = shVar('FFMPEG_BTBN_BUILD');
      expect(build, matches(RegExp('^n${RegExp.escape(series)}\\.\\d+(-\\d+-g[0-9a-f]{10})?\$')),
          reason: 'FFMPEG_BTBN_BUILD "$build" must be an exact BtbN build in the $series series');
      expect(psVar('FFmpegBtbnBuild'), build,
          reason: 'Windows and Linux must ship the same BtbN build');

      final tag = shVar('FFMPEG_BTBN_AUTOBUILD');
      expect(tag, matches(RegExp(r'^autobuild-\d{4}-\d\d-\d\d-\d\d-\d\d$')),
          reason: 'the fallback must be a dated BtbN autobuild tag, not latest');
      expect(psVar('FFmpegBtbnAutobuild'), tag);

      final mirror = shVar('FFMPEG_BTBN_MIRROR');
      expect(mirror, endsWith('/releases/download/ffmpeg-mirror-v1'));
      expect(psVar('FFmpegBtbnMirror'), mirror);

      final sha = RegExp(r'^[0-9a-f]{64}$');
      expect(shVar('FFMPEG_BTBN_LINUX64_SHA256'), matches(sha));
      expect(shVar('FFMPEG_BTBN_LINUXARM64_SHA256'), matches(sha));
      expect(psVar('FFmpegBtbnWin64Sha256'), matches(sha));

      for (final (name, text) in [('download-deps-linux.sh', linux), ('download-deps-windows.ps1', windows)]) {
        expect(text.contains('FFmpeg-Builds/releases/download/latest'), isFalse,
            reason: '$name still fetches BtbN\'s rolling latest');
        expect(RegExp(r'ffmpeg-n[^\s"]*-latest-').hasMatch(text), isFalse,
            reason: '$name still names a -latest- FFmpeg asset');
      }
    });

    test('every script verifies what it actually installed', () {
      // The pins above are intent; these assertions are what makes upstream
      // moving the URL a red build instead of silent skew. Losing them would
      // leave the pins as comments.
      for (final (file, check) in [
        ('download-deps-linux.sh', 'assert_ffmpeg_series "'),
        ('download-deps-linux.sh', 'assert_ffmpeg_build "'),
        ('download-deps-macos.sh', 'assert_ffmpeg_series'),
        ('download-deps-windows.ps1', r'$FFmpegSeries'),
        ('download-deps-windows.ps1', r'Test-PinnedFFmpeg $InstalledFFmpeg'),
      ]) {
        final text = File(p.join(root, 'Scripts', file)).readAsStringSync();
        expect(
          text.contains(check),
          isTrue,
          reason: '$file no longer checks the installed FFmpeg against '
              'its pin ($check), so a silent upstream change would go unnoticed',
        );
      }
    });
  });
}
