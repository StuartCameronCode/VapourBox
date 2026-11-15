/// A failed VapourSynth script is reported as itself, not as the encoder's
/// "Header too large" (task #28).
///
/// When vspipe fails before writing the Y4M header — a Python exception while
/// the script is evaluated — the encoder ffmpeg reads an empty pipe and fails
/// with `Header too large`. The worker used to report that, with ffmpeg's
/// banner, and leave the real cause in debug logs; the templates' own
/// refusals (Custom VapourSynth's frame-count check, Descale, Borders) never
/// reached the user in an encode. An exception on a frame mid-stream left
/// only `vspipe exited with exit code 1`. The encoder's own failures must
/// still be reported first, which the last test holds.
///
/// Heavy (runs vspipe | ffmpeg) — nightly, not the push gate.
@Tags(['heavy'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/script_errors';

const _width = 320;
const _height = 240;
const _frames = 10;

late String _source;

Future<String> _makeSource() async {
  final source = p.join(_outDir, 'source.mkv');
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc=size=${_width}x$_height:rate=25:duration=1',
      '-frames:v', '$_frames',
      '-c:v', 'ffv1', '-pix_fmt', 'yuv420p',
      source,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'fixture encode failed: ${r.stderr}');
  return source;
}

Future<JobResult> _run(String name,
    {String customVapoursynth = '', String customFfmpegArgs = ''}) {
  final job = VideoJob(
    id: const Uuid().v4(),
    inputPath: _source,
    outputPath: '$_outDir/$name.mkv',
    processingPipeline: const ProcessingPipeline(
      deinterlace: QTGMCParameters(enabled: false),
    ),
    encodingSettings: EncodingSettings(
      codec: VideoCodec.ffv1,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none,
      customVapoursynth: customVapoursynth,
      customFfmpegArgs: customFfmpegArgs,
    ),
    totalFrames: _frames,
    inputFrameRate: 25.0,
    inputWidth: _width,
    inputHeight: _height,
    inputPixelFormat: 'yuv420p',
  ).toJson();
  return WorkerHarness.runJob(job, label: name);
}

void _expectFailure(JobResult result) {
  expect(result.success, isFalse,
      reason: 'the job should have failed:\n${result.logs.join('\n')}');
  expect(result.error, isNotNull);
  expect(result.error, isNot(contains('Header too large')),
      reason: 'the encoder\'s empty-pipe error hides the cause');
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    _source = await _makeSource();
  });

  test('an exception while the script is evaluated is the job error', () async {
    final result = await _run('script_raise',
        customVapoursynth: 'raise ValueError("task28 sentinel: script")');
    _expectFailure(result);
    final error = result.error!;
    expect(error.split('\n').first,
        'The VapourSynth script failed: task28 sentinel: script');
    expect(error, contains('raise ValueError("task28 sentinel: script")'),
        reason: 'the traceback names the line that raised');
  });

  test('the template\'s own refusal reaches the user', () async {
    // Custom VapourSynth may not change the frame count; the template raises
    // with an explanation, which only the preview used to show.
    final result =
        await _run('frame_count_refusal', customVapoursynth: 'clip = clip + clip[0]');
    _expectFailure(result);
    expect(result.error!.split('\n').first,
        startsWith('The VapourSynth script failed: Custom VapourSynth: '
            'your code changed the frame count'));
  });

  test('an exception on a frame names the frame', () async {
    const code = '''
def _task28_boom(n, f):
    if n == 3:
        raise RuntimeError("task28 sentinel: frame")
    return f
clip = core.std.ModifyFrame(clip, clip, _task28_boom)''';
    final result = await _run('frame_raise', customVapoursynth: code);
    _expectFailure(result);
    expect(result.error!.split('\n').first,
        'VapourSynth failed on output frame 3: RuntimeError: task28 sentinel: frame');
  });

  test('the encoder\'s own failure is still reported first', () async {
    // Appended after the codec arguments, so it wins: ffmpeg fails on its
    // own and vspipe only loses its reader.
    final result = await _run('unknown_encoder',
        customFfmpegArgs: '-c:v vapourbox_no_such_encoder');
    expect(result.success, isFalse);
    final error = result.error!;
    expect(error, startsWith('ffmpeg exited with'));
    expect(error, contains('vapourbox_no_such_encoder'));
    expect(error, isNot(contains('VapourSynth')));
  });
}
