// The heavy tests compare a preview with a decode of the encode or the source.
// That decode has to convert to RGB as the preview does (task #67), so
// WorkerHarness.previewScaleFilter is a test-side twin of the worker's
// `preview_scale_filter(&swscale_input_opts())`. This pins it to the Rust
// source, so a change to the preview's conversion fails the push gate rather
// than a nightly. No worker or deps needed.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:vapourbox/models/color_tags.dart';

import 'support/worker_harness.dart';

String _repoFile(String rel) => File(p.join(
        Directory.current.path.endsWith('app')
            ? Directory.current.parent.path
            : Directory.current.path,
        rel))
    .readAsStringSync()
    .replaceAll('\r\n', '\n');

/// The body of `fn <name>(` in Rust source, up to the first line that is
/// just `}` at the function's own indentation.
String _rustFn(String src, String name) {
  final m = RegExp('^( *)pub fn $name\\(', multiLine: true).firstMatch(src);
  expect(m, isNotNull, reason: 'fn $name not found');
  final indent = m!.group(1)!;
  final end = src.indexOf('\n$indent}\n', m.start);
  return src.substring(m.start, end);
}

void main() {
  final executor = _repoFile('worker/src/pipeline_executor.rs');
  final colour = _repoFile('worker/src/models/color_metadata.rs');

  test('the options after the input ones are the worker\'s, in order', () {
    final body = _rustFn(executor, 'preview_scale_filter');
    final pushed = RegExp(r'opts\.push\("([^"]*)"\.to_string\(\)\)')
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toList();
    expect(pushed, ['out_range=pc', 'flags=${WorkerHarness.previewScaleFlags}'],
        reason: 'preview_scale_filter appends these after the input options');
    expect(body, contains('format!("scale={}", opts.join(":"))'));
    expect(WorkerHarness.previewScaleFilter(),
        endsWith(':${pushed.join(':')}'));
  });

  test('the input options follow swscale_input_opts', () {
    final body = _rustFn(colour, 'swscale_input_opts');
    // The matrix is swscale_matrix()'s; the range is pc for a full-range tag,
    // tv otherwise. If either rule changes, the twin in
    // WorkerHarness.previewScaleFilter must change with it.
    expect(body, contains('if let Some(m) = self.swscale_matrix()'));
    expect(body, contains('format!("in_color_matrix={m}")'));
    expect(body,
        contains('format!("in_range={}", if full { "pc" } else { "tv" })'));
    expect(_rustFn(colour, 'is_full_range'),
        contains('Some("pc") | Some("jpeg") | Some("full")'));
  });

  test('previewScaleMatrix maps every matrix as swscale_matrix does', () {
    // Each `"tag" => Some("name")` / `=> None` / `=> derived()` arm of the
    // Rust match, read from source, against the twin (task #73).
    final body = _rustFn(colour, 'swscale_matrix');
    final arms = {
      for (final m in RegExp(r'^\s*"([^"]+)" => ([^,]+),$', multiLine: true)
          .allMatches(body))
        m.group(1)!: m.group(2)!.trim(),
    };
    expect(arms.keys.toSet(), ColorTags.matrices.toSet(),
        reason: 'swscale_matrix decides every MATRICES entry');
    for (final MapEntry(key: m, value: arm) in arms.entries) {
      for (final prim in [null, 'bt709', 'bt2020', 'bt470bg']) {
        final String? want = switch (arm) {
          'None' => null,
          'derived()' => prim == 'bt709' || prim == 'bt2020' ? prim : null,
          _ => RegExp(r'^Some\("([^"]+)"\)$').firstMatch(arm)?.group(1) ??
              (fail('unexpected arm $m => $arm')),
        };
        expect(WorkerHarness.previewScaleMatrix(m, prim), want,
            reason: '$m / $prim');
      }
    }
  });

  test('matches the shared case table', () {
    final table = jsonDecode(
            _repoFile('Tests/TestResources/preview_scale_cases.json'))
        as Map<String, dynamic>;
    final cases = (table['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases.length, greaterThan(20));
    for (final c in cases) {
      expect(
          WorkerHarness.previewScaleFilter(
              matrix: c['matrix'] as String?,
              primaries: c['primaries'] as String?,
              range: c['range'] as String?),
          c['filter'],
          reason: '$c');
    }
  });

  // The cases of color_metadata.rs's own tests, plus the raw values
  // ColorMetadata::from_raw drops.
  test('matches the worker\'s cases', () {
    String f({String? m, String? r}) =>
        WorkerHarness.previewScaleFilter(matrix: m, range: r);
    const tail = 'out_range=pc:flags=accurate_rnd+full_chroma_int';
    expect(f(), 'scale=in_range=tv:$tail');
    expect(f(m: 'bt709', r: 'pc'),
        'scale=in_color_matrix=bt709:in_range=pc:$tail');
    expect(f(m: 'BT709', r: ' PC '),
        'scale=in_color_matrix=bt709:in_range=pc:$tail');
    expect(f(m: 'rgb'), 'scale=in_range=tv:$tail');
    expect(f(m: 'bt470bg', r: 'tv'),
        'scale=in_color_matrix=bt470bg:in_range=tv:$tail');
    expect(f(m: 'smpte170m', r: 'jpeg'),
        'scale=in_color_matrix=smpte170m:in_range=pc:$tail');
    expect(f(m: 'unknown', r: 'unknown'), 'scale=in_range=tv:$tail');
    expect(f(m: 'reserved', r: 'full'), 'scale=in_range=pc:$tail');
  });
}
