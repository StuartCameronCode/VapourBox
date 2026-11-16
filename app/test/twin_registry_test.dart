// Every Rust <-> Dart twin is registered in docs/TWINS.md with a disposition
// (task #42 plan, R5; task #50). A file in app/lib that says it is a twin of
// the worker's code, mirrors it or keeps in step with it must be listed
// there, so a new twin is a decision someone wrote down rather than a copy
// nobody knows about.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final registry = File('../docs/TWINS.md').readAsStringSync();
  final listed = RegExp(r'`(app/lib/[^`]+\.dart)`')
      .allMatches(registry)
      .map((m) => m.group(1)!)
      .toSet();
  final marker = RegExp(
      r'[Tt]win of|[Mm]irrors|second implementation|[Ii]n step with|[Kk]eep in step');

  test('every app file that declares a twin is registered', () {
    final unlisted = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('.g.dart')) continue;
      final path = 'app/${f.path.replaceAll('\\', '/')}';
      if (marker.hasMatch(f.readAsStringSync()) && !listed.contains(path)) {
        unlisted.add(path);
      }
    }
    expect(unlisted, isEmpty,
        reason: 'list each in docs/TWINS.md with its disposition: deleted '
            '(worker call), one data file, or kept + pinned with a reason');
  });

  test('every registered file exists', () {
    final missing = [
      for (final p in listed)
        if (!File('../$p').existsSync()) p,
    ];
    expect(missing, isEmpty, reason: 'remove stale rows from docs/TWINS.md');
  });
}
