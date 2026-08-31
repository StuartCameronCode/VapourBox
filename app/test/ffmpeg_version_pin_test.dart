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
/// and per host (BtbN asset names, evermeet version paths, a martin-riedl
/// redirect), and the variable is the single thing they are all built from.
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

    test("macOS's exact x64 pin lies within the shared series", () {
      // evermeet publishes per-version URLs and retains them, so that arch pins
      // a full version. It still has to be inside the series everyone else is
      // on, or macOS x64 silently diverges from macOS arm64.
      final text = File(p.join(root, 'Scripts', 'download-deps-macos.sh')).readAsStringSync();
      final series = RegExp(r'^FFMPEG_SERIES="([^"]+)"', multiLine: true).firstMatch(text)!.group(1)!;
      final exact = RegExp(r'^FFMPEG_MACOS_X64_VERSION="([^"]+)"', multiLine: true).firstMatch(text);
      expect(exact, isNotNull, reason: 'download-deps-macos.sh no longer pins an exact x64 version');
      expect(
        exact!.group(1)!,
        startsWith('$series.'),
        reason: 'the pinned evermeet build ${exact.group(1)} is not in the '
            '$series series the other platforms use',
      );
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
