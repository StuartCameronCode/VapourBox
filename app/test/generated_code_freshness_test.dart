/// Guards against a stale `.g.dart`.
///
/// `app/lib/**/*.g.dart` is gitignored, and every CI job runs
/// `dart run build_runner build` immediately before testing — so CI regenerates
/// unconditionally and can *never* reproduce this failure. It only ever happens
/// on a developer machine: add a field to a model, forget to rebuild, and
/// `_$XToJson` keeps emitting the old key set.
///
/// The symptom is why this is worth a test. A dropped key isn't an error
/// anywhere — the worker's serde models carry `#[serde(default)]`, so the field
/// arrives as its default and the pass silently runs with the wrong settings.
/// You end up debugging the template.
///
/// **Why field names and not mtimes.** The obvious check — is the `.g.dart`
/// newer than its source — is wrong, and measurably so: build_runner is
/// incremental and does not rewrite a generated file whose *output* is
/// unchanged, so eight models fail an mtime check straight after a clean build.
/// Comparing the declared fields against the generated ones tests the actual
/// hazard instead of a proxy for it.
///
/// Unlike `WorkerHarness._warnIfWorkerIsStale()`, which warns, this **fails**.
/// That check tolerates a stale binary because a false positive would break the
/// suite over something it cannot fix; here the fix is one command, printed in
/// the failure message.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Walk up from the test's CWD to the directory holding `pubspec.yaml`.
String _appRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('could not locate the app directory (no pubspec.yaml above '
      '${Directory.current.path})');
}

/// `final <Type> <name>;` — instance fields only. Getters have no `final`, and
/// `static`/`const` are excluded explicitly below.
final _field = RegExp(r'^\s*final\s+[\w<>,\s?.]+?\s+(\w+)\s*;');

/// A field json_serializable is told to leave out. Any of these on the field's
/// own line or the annotation above it means the generator won't reference it.
final _excluded = RegExp(
  r'includeToJson:\s*false|includeFromJson:\s*false|ignore:\s*true',
);

/// Names of the fields json_serializable should have generated code for, in
/// every `@JsonSerializable` class in [source].
List<String> _serializedFields(String source) {
  final names = <String>[];
  final lines = source.split('\n');

  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].trimLeft().startsWith('@JsonSerializable')) continue;

    // Walk to the class body, then track brace depth to find its end.
    var depth = 0;
    var started = false;
    var previous = '';
    for (var j = i + 1; j < lines.length; j++) {
      final line = lines[j];
      for (final ch in line.codeUnits) {
        if (ch == 0x7B) {
          depth++;
          started = true;
        } else if (ch == 0x7D) {
          depth--;
        }
      }
      if (started && depth <= 0) break;

      // Only top-level members of the class — depth 1 — so fields of a nested
      // closure or collection literal can't be mistaken for declarations.
      if (depth == 1 && !line.contains('static') && !line.contains('const ')) {
        final match = _field.firstMatch(line);
        if (match != null &&
            !_excluded.hasMatch(line) &&
            !_excluded.hasMatch(previous)) {
          names.add(match.group(1)!);
        }
      }
      if (line.trim().isNotEmpty) previous = line;
    }
  }
  return names;
}

void main() {
  test('every generated .g.dart covers the fields its source declares', () {
    final appRoot = _appRoot();
    final libDir = Directory(p.join(appRoot, 'lib'));
    expect(libDir.existsSync(), isTrue, reason: 'app/lib should exist');

    final missingFile = <String>[];
    final missingFields = <String>[];
    var checked = 0;

    for (final file in libDir.listSync(recursive: true).whereType<File>()) {
      final path = file.path;
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;

      // Only files that actually declare a part directive generate one.
      final basename = p.basenameWithoutExtension(path);
      final source = file.readAsStringSync();
      if (!source.contains("part '$basename.g.dart';")) continue;

      checked++;
      final rel = p.relative(path, from: appRoot);
      final generated = File(p.setExtension(path, '.g.dart'));
      if (!generated.existsSync()) {
        missingFile.add(rel);
        continue;
      }

      final code = generated.readAsStringSync();
      for (final field in _serializedFields(source)) {
        // Every included field is read back as `instance.<name>` in the
        // toJson half, whatever `@JsonKey(name:)` renamed its JSON key to.
        if (!code.contains('instance.$field')) {
          missingFields.add('$rel: $field');
        }
      }
    }

    // A collector that matched nothing would pass vacuously; there are 28
    // generated models.
    expect(checked, greaterThan(20),
        reason: 'expected to find the generated models under app/lib');

    expect(
      [...missingFile, ...missingFields],
      isEmpty,
      reason: '\n'
          '*** Generated serialization code is out of date ***\n'
          '${missingFile.isEmpty ? '' : '  never generated: ${missingFile.join(', ')}\n'}'
          '${missingFields.isEmpty ? '' : '  fields with no generated code:\n    ${missingFields.join('\n    ')}\n'}'
          '\n'
          'A stale .g.dart drops the new fields from toJson() silently: the\n'
          'worker receives JSON without them, serde fills in defaults, and the\n'
          'pass runs with the wrong settings and no error anywhere.\n'
          '\n'
          'Fix:\n'
          '  cd app && dart run build_runner build --delete-conflicting-outputs\n',
    );
  });
}
