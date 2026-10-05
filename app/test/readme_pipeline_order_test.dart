// The README's "The filter pipeline" table is where users are told what order
// the filters run in. It is prose, so nothing stops it drifting from the
// pipeline — and a documented order that is wrong is worse than none: issue
// #109 was a user reasoning from an in-app message that misstated the order.
//
// This pins the table, row for row, to PassListPanel.stages, which
// pass_list_stages_test.dart in turn pins to the pipeline.
//
// Run with: flutter test test/readme_pipeline_order_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/views/pass_list/pass_list_panel.dart';

/// The README writes a couple of names differently from the pass list.
const _readmeNames = {
  PassType.cropResize: 'Crop & Resize',
};

void main() {
  final readme = File('../README.md').readAsLinesSync();
  final row = RegExp(r'^\| (\d+) \| \*\*(.+?)\*\* \|');

  final start = readme.indexOf('## The filter pipeline');
  final rows = [
    for (final line in readme.skip(start + 1).takeWhile((l) => !l.startsWith('## ')))
      if (row.firstMatch(line) case final m?) (int.parse(m.group(1)!), m.group(2)!),
  ];

  test('the README has a filter pipeline table', () {
    expect(start, isNonNegative);
    expect(rows, isNotEmpty);
  });

  test('the table lists every filter in the order it runs', () {
    final expected = [
      for (final stage in PassListPanel.stages)
        for (final pass in stage.passes)
          _readmeNames[pass] ?? pass.displayName,
    ];
    expect(rows.map((r) => r.$2).toList(), expected,
        reason: 'README.md "The filter pipeline" must list the filters in '
            'pipeline order — see PassListPanel.stages');
  });

  test('the rows are numbered 1..n without gaps', () {
    expect(rows.map((r) => r.$1).toList(),
        [for (var i = 1; i <= rows.length; i++) i]);
  });
}
