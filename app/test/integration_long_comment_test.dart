/// A source's comment tag of any length reaches the output intact (issue #138).
///
/// The worker copies the source's container `comment` into the output,
/// prefixed with `VapourBox <version>`. It used to pass it as
/// `-metadata comment=…`, and AI video tools store their whole workflow
/// (tens of KB of JSON) in that tag: on Windows the encoder's command line
/// then exceeded 32,767 characters and ffmpeg could not be started at all
/// ("The filename or extension is too long", os error 206). The comment now
/// goes to ffmpeg in an FFMETADATA file. The fixture's comment is longer than
/// that limit, so on Windows this reproduces the report; everywhere it checks
/// that the comment arrives byte-for-byte — quotes, `=`, `;`, `#`, `\` and
/// newlines included — and that re-processing an output keeps one prefix.
///
/// Heavy (full encode) — nightly, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/long_comment';

const _width = 320;
const _height = 240;
const _frames = 10;

/// A ComfyUI-style workflow comment, past Windows' command-line limit.
final String _comment = () {
  final b = StringBuffer('{"prompt": "a=b; #tag \\\\ path \\"quoted\\"",\n'
      '"workflow": [');
  var i = 0;
  while (b.length < 40000) {
    b.write('{"id": ${i++}, "type": "KSampler", "widgets": [1, 2.5, "x=y;z#"]}, ');
  }
  b.write('{}]}');
  return b.toString();
}();

/// The worker's version, which prefixes the comment it writes.
String get _workerVersion {
  final toml = File(p.join(WorkerHarness.repoRoot, 'worker', 'Cargo.toml'))
      .readAsStringSync();
  return RegExp(r'^version\s*=\s*"([^"]+)"', multiLine: true)
      .firstMatch(toml)!
      .group(1)!;
}

/// FFMETADATA escaping, so making the fixture does not itself need the
/// comment on a command line.
String _ffmetadata(String comment) {
  final escaped = comment.replaceAllMapped(
      RegExp(r'[=;#\\\n]'), (m) => '\\${m[0]}');
  return ';FFMETADATA1\ncomment=$escaped\n';
}

Future<String> _makeSource() async {
  final meta = File(p.join(_outDir, 'source_meta.txt'));
  await meta.writeAsString(_ffmetadata(_comment));
  final source = p.join(_outDir, 'source.mkv');
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc=size=${_width}x$_height:rate=25:duration=1',
      '-f', 'ffmetadata', '-i', meta.path,
      '-map', '0:v', '-map_metadata:g', '1',
      '-frames:v', '$_frames',
      '-c:v', 'ffv1', '-pix_fmt', 'yuv420p',
      source,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'fixture encode failed: ${r.stderr}');
  return source;
}

/// The container's comment tag, whatever case the muxer stored it in.
Future<String?> _commentOf(String path) async {
  final json = await WorkerHarness.ffprobeJson(
      ['-v', 'error', '-show_entries', 'format_tags', '-of', 'json', path]);
  final tags = ((json['format'] as Map?)?['tags'] as Map?) ?? const {};
  for (final e in tags.entries) {
    if (e.key.toString().toLowerCase() == 'comment') return e.value as String;
  }
  return null;
}

Map<String, dynamic> _job(String input, String name) => VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: const ProcessingPipeline(
        deinterlace: QTGMCParameters(enabled: false),
      ),
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      totalFrames: _frames,
      inputFrameRate: 25.0,
      inputWidth: _width,
      inputHeight: _height,
      inputPixelFormat: 'yuv420p',
    ).toJson();

Future<String> _encode(String input, String name) async {
  final result = await WorkerHarness.runJob(_job(input, name), label: name);
  final tail = result.logs.length > 25
      ? result.logs.sublist(result.logs.length - 25)
      : result.logs;
  expect(result.success, isTrue,
      reason: '$name failed: ${result.error}\n${tail.join('\n')}');
  return result.outputPath!;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  test('a comment longer than the Windows command line reaches the output',
      () async {
    final source = await _makeSource();
    // The fixture really carries the case under test.
    expect(await _commentOf(source), _comment);
    expect(_comment.length, greaterThan(32767));

    final expected = 'VapourBox $_workerVersion | $_comment';
    final out = await _encode(source, 'long_comment');
    expect(await _commentOf(out), expected,
        reason: 'the comment must arrive unaltered, after the version');

    // Re-processing an output keeps one prefix, not two.
    final again = await _encode(out, 'long_comment_again');
    expect(await _commentOf(again), expected);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
