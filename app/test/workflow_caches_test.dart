// What the workflows may keep in the repository's 10 GB of Actions caches.
//
// The Flutter SDK is never cached (tasks #84, #121): ~2 GB a platform pushed
// the repository past its budget, every cache was evicted in turn, and a hit
// saved under a minute. Task #84 removed it from ci-test.yml and nightly.yml,
// and the release builds kept it until task #121, so this checks every
// workflow, including ones added later.
//
// And no cache key hashes Cargo.lock: worker/Cargo.lock is gitignored, so
// `hashFiles('**/Cargo.lock')` is empty and the key never changes; an exact
// hit on it restores a stale target/ forever (task #121).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/worker_harness.dart';

/// The steps of a workflow file, each as its lines: a step starts at a
/// `- ` list item under a `steps:` key and runs to the next line indented no
/// deeper than its dash.
List<List<String>> workflowSteps(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final steps = <List<String>>[];
  int indentOf(String l) => l.length - l.trimLeft().length;
  var i = 0;
  while (i < lines.length) {
    final l = lines[i];
    if (l.trim() == 'steps:') {
      final keyIndent = indentOf(l);
      i++;
      while (i < lines.length) {
        final s = lines[i];
        if (s.trim().isEmpty || s.trimLeft().startsWith('#')) {
          i++;
          continue;
        }
        if (indentOf(s) <= keyIndent) break;
        if (s.trimLeft().startsWith('- ')) {
          final dash = indentOf(s);
          final step = <String>[s];
          i++;
          while (i < lines.length) {
            final t = lines[i];
            if (t.trim().isNotEmpty && !t.trimLeft().startsWith('#') && indentOf(t) <= dash) break;
            step.add(t);
            i++;
          }
          steps.add(step);
        } else {
          i++;
        }
      }
    } else {
      i++;
    }
  }
  return steps;
}

/// Problems with the caches a workflow keeps, one line each.
List<String> cacheProblems(String name, String text) {
  final problems = <String>[];
  for (final step in workflowSteps(text)) {
    final code = step.where((l) => !l.trimLeft().startsWith('#')).toList();
    final usesFlutter = code.any((l) => l.contains('subosito/flutter-action'));
    if (usesFlutter && !code.any((l) => RegExp(r'^\s*cache:\s*false\s*$').hasMatch(l))) {
      problems.add('$name: "${step.first.trim()}" uses subosito/flutter-action without '
          '`cache: false` (the Flutter SDK is never cached, tasks #84 and #121)');
    }
    if (code.any((l) => l.contains('Cargo.lock'))) {
      problems.add('$name: "${step.first.trim()}" keys on Cargo.lock, which is gitignored, '
          'so the key never changes (task #121)');
    }
  }
  return problems;
}

void main() {
  final dir = Directory(p.join(WorkerHarness.repoRoot, '.github', 'workflows'));
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('no workflow caches the Flutter SDK or keys a cache on Cargo.lock', () {
    expect(files, isNotEmpty);
    var flutterSteps = 0;
    final problems = <String>[];
    for (final f in files) {
      final text = f.readAsStringSync();
      flutterSteps += workflowSteps(text)
          .where((s) => s.any((l) => !l.trimLeft().startsWith('#') && l.contains('subosito/flutter-action')))
          .length;
      problems.addAll(cacheProblems(p.basename(f.path), text));
    }
    // The step reader found the flutter-action steps (ci-test, nightly, the
    // release builds, the repro workflows), so an empty list means something.
    expect(flutterSteps, greaterThanOrEqualTo(6));
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the check catches a cached SDK, a missing cache key and a Cargo.lock key', () {
    const bad = '''
jobs:
  a:
    steps:
      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - name: Setup Flutter again
        # cache: false
        uses: subosito/flutter-action@v2
      - name: Cache Rust
        uses: actions/cache@v5
        with:
          key: x-\${{ hashFiles('**/Cargo.lock') }}
      - name: Setup Flutter right
        uses: subosito/flutter-action@v2
        with:
          cache: false
''';
    final problems = cacheProblems('bad.yml', bad);
    expect(problems, hasLength(3), reason: problems.join('\n'));
    expect(problems[0], contains('Setup Flutter'));
    expect(problems[1], contains('Setup Flutter again'));
    expect(problems[2], contains('Cargo.lock'));
  });
}
