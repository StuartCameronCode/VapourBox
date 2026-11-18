// The heavy tests compare a preview with a decode of the encode or the source.
// That decode has to convert to RGB as the preview does (task #67), so
// WorkerHarness.previewScaleFilter is a test-side twin of the worker's
// `preview_scale_filter(&swscale_input_opts())`. This pins it to the Rust
// source, so a change to the preview's conversion fails the push gate rather
// than a nightly. No worker or deps needed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
    // The matrix is stated unless it is the RGB identity; the range is pc
    // for a full-range tag, tv otherwise. If either rule changes, the twin
    // in WorkerHarness.previewScaleFilter must change with it.
    expect(body, contains('if m != "rgb"'));
    expect(body, contains('format!("in_color_matrix={m}")'));
    expect(body,
        contains('format!("in_range={}", if full { "pc" } else { "tv" })'));
    expect(_rustFn(colour, 'is_full_range'),
        contains('Some("pc") | Some("jpeg") | Some("full")'));
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
