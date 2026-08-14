// Lints every built-in filter schema against the rules that keep the method
// dropdowns usable as filters are added. These are cheap assertions over the
// shipped JSON, and they exist because each rule has a silent failure mode:
// break one and the UI still renders, just wrongly.
//
// Rules and why:
//   - The first method is the resolved default (`methods.first` is what an unset
//     `method` falls back to), so marking it advancedOnly would default every
//     user to a method most of them can't see.
//   - At least one method must be visible in simple mode, or simple mode shows
//     an arbitrary single choice with no dropdown at all.
//   - Every method needs a description, because that is the only guidance shown
//     beside it in the dropdown. A dropdown of sixteen bare names is worse than
//     one of four.
//
// Run with: flutter test test/filter_schema_curation_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/filter_schema.dart';

void main() {
  final manifest = (jsonDecode(
    File('assets/filters/manifest.json').readAsStringSync(),
  ) as List)
      .cast<String>();

  final schemas = <FilterSchema>[
    for (final filename in manifest)
      FilterSchema.fromJson(
        jsonDecode(File('assets/filters/core/$filename').readAsStringSync())
            as Map<String, dynamic>,
      ),
  ];

  test('the manifest lists every schema file', () {
    final onDisk = Directory('assets/filters/core')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.json'))
        .toSet();

    expect(onDisk.difference(manifest.toSet()), isEmpty,
        reason: 'a schema file exists but nothing loads it');
  });

  group('method curation', () {
    for (final schema in schemas) {
      test('${schema.id}: first method is never advanced-only', () {
        expect(schema.methods.first.advancedOnly, false,
            reason: '${schema.methods.first.id} is the default method, so '
                'hiding it in simple mode would default users to a method '
                'they cannot see');
      });

      test('${schema.id}: something is visible in simple mode', () {
        expect(schema.visibleMethods(showAdvanced: false), isNotEmpty);
      });

      test('${schema.id}: every method has guidance', () {
        for (final method in schema.methods) {
          expect(method.description?.trim() ?? '', isNotEmpty,
              reason: '${method.id} has no description, so the dropdown shows '
                  'a bare name with no hint of when to choose it');
        }
      });
    }
  });

  group('curation actually shortens the long dropdowns', () {
    // Pins the decisions made when advanced mode landed. Adding methods is
    // expected; letting a simple-mode dropdown grow without curating is not.
    // A count here going up means the curation was not extended along with the
    // new methods.
    const maxSimpleMethods = 4;

    for (final schema in schemas) {
      test('${schema.id}: at most $maxSimpleMethods methods in simple mode',
          () {
        final visible = schema.visibleMethods(showAdvanced: false);
        expect(visible.length, lessThanOrEqualTo(maxSimpleMethods),
            reason: 'simple mode offers ${visible.map((m) => m.id).toList()}; '
                'mark the specialist ones advancedOnly');
      });
    }

    test('dehalo hides its specialist and duplicated methods', () {
      final dehalo = schemas.firstWhere((s) => s.id == 'dehalo');
      expect(
        dehalo.visibleMethods(showAdvanced: false).map((m) => m.id),
        ['dehalo_alpha', 'fine_dehalo', 'yahr'],
      );
      // Vinverse is offered by Chroma Fixes too; Fine Dehalo 2 is a follow-up
      // pass rather than a first choice.
      expect(dehalo.methods.length, 7);
    });
  });
}
