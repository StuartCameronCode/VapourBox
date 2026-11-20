// Colour tags FFmpeg 9's scaler can't convert, checked against each
// platform's bundled ffmpeg (task #76).
//
// The scaler converts a frame from only some matrices (its negotiation lists
// unknown, gbr, bt709, fcc, bt470bg, smpte170m, smpte240m, bt2020nc). A frame
// TAGGED ycgco, bt2020c, smpte2085, chroma-derived-* or ictcp failed every
// decode that converts its pixel format, and every encode whose encoder had
// to convert. The fixes are the decode neutraliser (ColorTags.decodeNeutraliser
// and the worker's decode_tag_neutraliser) and the encoder's matrix bridge
// (ColorMetadata::encoder_matrix_bridge). The Rust tests pin the list
// (SCALER_MATRICES) from one build; this runs the fixes through the build each
// platform ships. docs/reports/task-76-unconvertible-matrix-tags.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/models/color_tags.dart';
import 'package:vapourbox/models/hdr_display.dart';

import 'support/worker_harness.dart';

/// The worker's `encoder_matrix_bridge` format string, filled for [standIn]
/// and [tag], read from the Rust source so the two can't drift.
String _bridge(String standIn, String tag) {
  final src = File(p.join(
          WorkerHarness.repoRoot, 'worker/src/models/color_metadata.rs'))
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final fn = src.substring(src.indexOf('pub fn encoder_matrix_bridge'));
  final m = RegExp(r'"(setparams=colorspace=\{stand_in\}[^"]*)"').firstMatch(fn);
  expect(m, isNotNull, reason: 'encoder_matrix_bridge format string not found');
  return m!.group(1)!.replaceAll('{stand_in}', standIn).replaceAll('{tag}', tag);
}

void main() {
  late Directory dir;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    dir = await Directory.systemTemp.createTemp('vb_colour_tags');
  });
  tearDownAll(() => dir.delete(recursive: true));

  Future<ProcessResult> ffmpeg(List<String> args) => Process.run(
      WorkerHarness.ffmpegPath, ['-v', 'error', '-y', ...args],
      environment: WorkerHarness.ffmpegEnv);

  /// A 32x16 FFV1 file whose frames carry [matrix] / [primaries] / [transfer],
  /// tagged with setparams so no sample is converted.
  Future<String> tagged(String name, String matrix,
      {String primaries = 'bt709', String transfer = 'bt709',
      String pixFmt = 'yuv420p'}) async {
    final out = p.join(dir.path, '$name.mkv');
    final r = await ffmpeg([
      '-f', 'lavfi', '-i', 'testsrc2=s=32x16', '-frames:v', '2',
      '-vf', 'format=$pixFmt,setparams=colorspace=$matrix'
          ':color_primaries=$primaries:color_trc=$transfer:range=tv',
      '-c:v', 'ffv1', out,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return out;
  }

  // Every matrix, and chroma-derived with each primaries rule: with the
  // neutraliser first, every converting decode the app and worker make (and
  // RGB, which only tests make) gives a picture.
  test('the neutraliser lets every converting decode run', () async {
    final cases = [
      for (final m in ColorTags.matrices.where((m) => m != 'rgb')) (m, 'bt709'),
      ('chroma-derived-nc', 'bt2020'),
      ('chroma-derived-c', 'bt470bg'),
    ];
    final outputs = [
      ['-f', 'image2', '-c:v', 'mjpeg', 'o.jpg'],
      ['-pix_fmt', 'rgb24', '-f', 'rawvideo', 'o.raw'],
      ['-pix_fmt', 'yuv444p', '-f', 'rawvideo', 'o.raw'],
      ['-pix_fmt', 'yuv420p10le', '-f', 'rawvideo', 'o.raw'],
    ];
    final failures = <String>[];
    final stillRefused = <String>[];
    for (final (m, prim) in cases) {
      final src = await tagged('d_${m}_$prim', m, primaries: prim);
      final fix = ColorTags.decodeNeutraliser(
          matrix: m, primaries: prim, transfer: 'bt709');
      expect(fix == null, ColorTags.scalerMatrices.contains(m), reason: m);
      for (final out in outputs) {
        final o = [...out]..last = p.join(dir.path, out.last);
        final r = await ffmpeg([
          '-i', src, '-frames:v', '1',
          if (fix != null) ...['-vf', fix],
          ...o,
        ]);
        if (r.exitCode != 0) failures.add('$m/$prim ${out.first}: ${r.stderr}');
        if (fix != null) {
          final bare = await ffmpeg(['-i', src, '-frames:v', '1', ...o]);
          if (bare.exitCode != 0) stillRefused.add('$m ${out[1]}');
        }
      }
    }
    // Informational: a newer FFmpeg that learns these matrices shows here.
    print('  without the neutraliser, still refused: ${stillRefused.length} '
        'decodes (${stillRefused.take(4).join(', ')}…)');
    expect(failures, isEmpty);
  });

  // An encoder that converts (a forced -pix_fmt, or one that refuses the
  // pipe's format) keeps the tag and gives an untagged encode's samples.
  test('the encoder bridge converts, keeps the tag and every sample', () async {
    Future<String> samples(String path, String pixFmt) async {
      final r = await Process.run(
          WorkerHarness.ffmpegPath,
          [
            '-v', 'error', '-i', path, '-vf', 'setparams=colorspace=unknown',
            '-f', 'rawvideo', '-pix_fmt', pixFmt, '-',
          ],
          environment: WorkerHarness.ffmpegEnv,
          stdoutEncoding: null);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return md5.convert(r.stdout as List<int>).toString();
    }

    final y4m = p.join(dir.path, 'in.y4m');
    expect((await ffmpeg([
      '-f', 'lavfi', '-i', 'testsrc2=s=32x16', '-frames:v', '2',
      '-pix_fmt', 'yuv420p', y4m,
    ])).exitCode, 0);

    // (codec, extra output args, stored pix_fmt)
    const encoders = [
      // a forced conversion (AMF's nv12 pin), lossless so samples compare
      ('libx264', ['-pix_fmt', 'nv12', '-qp', '0', '-preset', 'ultrafast'], 'yuv420p'),
      ('huffyuv', <String>[], 'yuv422p'), // the encoder refuses yuv420p
    ];
    for (final (codec, extra, stored) in encoders) {
      const ext = 'mkv';
      final plain = p.join(dir.path, 'plain_$codec.$ext');
      final r0 = await ffmpeg(
          ['-f', 'yuv4mpegpipe', '-i', y4m, ...extra, '-c:v', codec, plain]);
      expect(r0.exitCode, 0, reason: '${r0.stderr}');
      final want = await samples(plain, stored);

      for (final m in ColorTags.matrices
          .where((m) => !ColorTags.scalerMatrices.contains(m))) {
        final standIn = ColorTags.scalerStandIn(m, 'bt709')!;
        final out = p.join(dir.path, 'bridged_${codec}_$m.$ext');
        final declare = ['-colorspace', m];
        final broken = await ffmpeg([
          '-f', 'yuv4mpegpipe', ...declare, '-i', y4m, ...extra, ...declare,
          '-c:v', codec, p.join(dir.path, 'broken.$ext'),
        ]);
        if (broken.exitCode == 0) {
          print('  note: $codec converts $m without the bridge in this ffmpeg');
        }
        final r = await ffmpeg([
          '-f', 'yuv4mpegpipe', ...declare, '-i', y4m,
          '-vf', _bridge(standIn, m), ...extra, ...declare,
          '-c:v', codec, out,
        ]);
        expect(r.exitCode, 0, reason: '$codec $m: ${r.stderr}');
        final s = await WorkerHarness.firstStream(out,
            selector: 'v:0', entries: ['color_space', 'pix_fmt']);
        expect(s!['color_space'], m, reason: '$codec keeps the tag');
        expect(s['pix_fmt'], stored, reason: codec);
        expect(await samples(out, stored), want, reason: '$codec $m samples');
      }
    }
  });

  // zimg refuses constant luminance with PQ/HLG; the display tone map reads
  // bt2020c as NCL (both twins).
  test('the HDR tone map gives a picture for bt2020c', () async {
    for (final t in ['smpte2084', 'arib-std-b67']) {
      final src = await tagged('hdr_$t', 'bt2020c',
          primaries: 'bt2020', transfer: t, pixFmt: 'yuv420p10le');
      final fix = ColorTags.decodeNeutraliser(
          matrix: 'bt2020c', primaries: 'bt2020', transfer: t)!;
      final tm = HdrDisplay.toneMapFilter(
          matrix: 'bt2020c', primaries: 'bt2020', transfer: t)!;
      final r = await ffmpeg([
        '-i', src, '-frames:v', '1', '-vf', '$fix,$tm',
        p.join(dir.path, 'hdr_$t.png'),
      ]);
      expect(r.exitCode, 0, reason: '$t: ${r.stderr}');
    }
  });
}
