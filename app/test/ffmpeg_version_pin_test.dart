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
      // "master", "latest" or a full version would each defeat the point: the
      // first two are unpinned, and a full version cannot be held because BtbN
      // garbage-collects old series from its rolling tag.
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

    test('every script verifies what it actually installed', () {
      // The pins above are intent; these assertions are what makes upstream
      // moving the URL a red build instead of silent skew. Losing them would
      // leave the pins as comments.
      for (final entry in {
        'download-deps-linux.sh': 'assert_ffmpeg_series',
        'download-deps-macos.sh': 'assert_ffmpeg_series',
        'download-deps-windows.ps1': r'$FFmpegSeries',
      }.entries) {
        final text = File(p.join(root, 'Scripts', entry.key)).readAsStringSync();
        expect(
          text.contains(entry.value),
          isTrue,
          reason: '${entry.key} no longer checks the installed FFmpeg against '
              'its pin, so a silent upstream change would go unnoticed',
        );
      }
    });
  });
}
