/// Frame mapping, verified against what actually comes out of the pipeline.
///
/// `FrameMap` decides two things that are invisible until they are wrong:
/// `output_count` drives the progress total, and `inverse` decides which output
/// frame a preview shows for a given source frame. Both were covered only as
/// arithmetic — `FrameMap::Retime.output_count(97) == 116` and friends — which
/// proves the model is self-consistent and says nothing about whether the
/// plugins agree with it.
///
/// That gap is exactly the failure this repo already documents for custom
/// VapourSynth: a real output length that differs from the declared one "makes
/// the progress bar lie *and* makes frame-accurate preview show a different
/// frame than its label, both silently". Custom code is guarded (the script
/// raises if `len(clip)` changed); the built-in passes that change the count on
/// purpose had no equivalent end-to-end check.
///
/// The counts below are derived by hand from the FrameMap definitions rather
/// than read back from the model, so a change to the model cannot quietly
/// redefine what "correct" means:
///
///   Fanout{factor:2}          75 -> 150,  31 -> 62
///   Decimate{cycle:5,keep:4}  90 -> 72
///   Retime 25 -> 24000/1001   ratio reduces to 960/1001, so 75 -> 71
///                             (75*960/1001 = 71.93, floored)
///
/// Heavy (full encode + preview) — nightly, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/frame_mapping';

String get _interlaced => WorkerHarness.inputFile; // 720x576 yuv422p, 25 fps, 75 frames
String get _telecine => p.join(
    WorkerHarness.repoRoot, 'Tests', 'TestResources', 'hard_telecine_test.avi');

/// The fixtures' real properties, asserted in `setUpAll` so a replaced fixture
/// fails naming itself rather than silently changing every expected count.
const _interlacedFrames = 75;
const _interlacedFps = 25.0;
const _telecineFrames = 90;

VideoJob _job(
  String name, {
  required String input,
  required ProcessingPipeline pipeline,
  required int width,
  required int height,
  required String pixFmt,
  required double fps,
  required int totalFrames,
  int? startFrame,
  int? endFrame,
  VideoCodec codec = VideoCodec.h264,
}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: '$_outDir/$name.mkv',
      processingPipeline: pipeline,
      encodingSettings: EncodingSettings(
        codec: codec,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      // Set explicitly rather than left to the worker's 720x480 / yuv420p
      // fallbacks: the preview and the encode must read the source through the
      // same geometry or the comparison below is meaningless.
      //
      // `totalFrames` is the count the decoder will actually pipe, i.e. the
      // POST-TRIM count — trimming is decoder-side (`-ss` + `-frames:v`) and
      // pipe_source builds a fixed-length clip from this number. The app sets
      // it that way (`main_viewmodel.dart`: `effectiveEnd - effectiveStart + 1`)
      // and the worker computes the same thing when it is absent
      // (`main.rs`: "effective after trim").
      //
      // Passing the full source length alongside a trim declares a clip longer
      // than the data: pipe_source hits EOF and repeats the last real frame to
      // pad, so the output is full-length with a frozen tail and every count
      // here is wrong by the padding. That is not a hypothetical — this test
      // was written that way first and reported 150 frames for a 31-frame trim.
      inputWidth: width,
      inputHeight: height,
      inputPixelFormat: pixFmt,
      inputFrameRate: fps,
      totalFrames: totalFrames,
      startFrame: startFrame,
      endFrame: endFrame,
    );

/// Frames actually present in a file, counted rather than read from a header.
Future<int> _countFrames(String path) async {
  final v = await WorkerHarness.firstStream(path,
      selector: 'v:0', entries: ['nb_read_frames'], countFrames: true);
  expect(v, isNotNull, reason: 'no video stream in $path');
  final n = int.tryParse(v!['nb_read_frames']?.toString() ?? '');
  expect(n, isNotNull, reason: 'ffprobe returned no frame count for $path');
  return n!;
}

/// One frame of a video as packed rgb24, by absolute frame index.
Future<Uint8List> _frameRgb(String path, int index) async {
  final out = File(p.join(Directory.systemTemp.path,
      'vb_fm_${DateTime.now().microsecondsSinceEpoch}_$index.png'));
  try {
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      [
        '-y', '-v', 'error',
        '-i', path,
        // Decode from the start and pick by index — accurate, unlike an input
        // seek, and these clips are short enough that it costs little.
        '-vf', 'select=eq(n\\,$index)',
        '-frames:v', '1',
        out.path,
      ],
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: 'extracting frame $index: ${r.stderr}');
    expect(await out.exists(), isTrue, reason: 'no frame $index in $path');
    return WorkerHarness.imageToRgb24(await out.readAsBytes(),
        label: 'out$index');
  } finally {
    if (await out.exists()) await out.delete().catchError((_) => out);
  }
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);

    // Every expected number below is a function of the fixtures' lengths, so
    // pin those first — otherwise a re-encoded fixture turns these into
    // confidently wrong assertions.
    expect(await _countFrames(_interlaced), _interlacedFrames,
        reason: 'interlaced_test.avi changed length; the expected output '
            'counts in this file are derived from it');
    expect(await _countFrames(_telecine), _telecineFrames,
        reason: 'hard_telecine_test.avi changed length');
  });

  group('a pass that changes the frame count actually changes it', () {
    test('double-rate QTGMC emits two frames per source frame', () async {
      // Fanout{factor: 2}. Trimmed to 31 source frames, so 62 out.
      const start = 10, end = 40;
      const sourceFrames = end - start + 1; // 31
      final job = _job(
        'double_rate',
        input: _interlaced,
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
              preset: QTGMCPreset.superFast, tff: true, fpsDivisor: 1),
        ),
        width: 720,
        height: 576,
        pixFmt: 'yuv422p',
        fps: _interlacedFps,
        // Post-trim, per the contract above.
        totalFrames: sourceFrames,
        startFrame: start,
        endFrame: end,
      );

      final r = await WorkerHarness.runJob(job.toJson(), label: 'double_rate');
      expect(r.success, isTrue, reason: r.error);
      final n = await _countFrames(r.outputPath!);
      print('  $sourceFrames source -> $n output (expected 62)');
      expect(n, sourceFrames * 2,
          reason: 'double-rate QTGMC must emit one frame per field. A count '
              'equal to the source length means FPSDivisor was ignored and '
              'the progress total is now double the real work.');
    });

    test('single-rate QTGMC leaves the count alone', () async {
      // The control. Without it, a broken assertion that always sees the source
      // count would still pass the test above on a pipeline that fanned out
      // nothing.
      const start = 10, end = 40;
      const sourceFrames = end - start + 1;
      final job = _job(
        'single_rate',
        input: _interlaced,
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
              preset: QTGMCPreset.superFast, tff: true, fpsDivisor: 2),
        ),
        width: 720,
        height: 576,
        pixFmt: 'yuv422p',
        fps: _interlacedFps,
        // Post-trim, per the contract above.
        totalFrames: sourceFrames,
        startFrame: start,
        endFrame: end,
      );

      final r = await WorkerHarness.runJob(job.toJson(), label: 'single_rate');
      expect(r.success, isTrue, reason: r.error);
      final n = await _countFrames(r.outputPath!);
      print('  $sourceFrames source -> $n output (expected $sourceFrames)');
      expect(n, sourceFrames);
    });

    test('IVTC decimates 5 frames to 4', () async {
      // Decimate{cycle: 5, keep: 4}: 90 telecined frames -> 72 film frames.
      final job = _job(
        'ivtc',
        input: _telecine,
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
            enabled: true,
            method: DeinterlaceMethod.ivtc,
            tff: true,
            ivtcCycle: 5,
          ),
        ),
        width: 720,
        height: 480,
        pixFmt: 'yuv420p',
        fps: 30000 / 1001,
        totalFrames: _telecineFrames,
      );

      final r = await WorkerHarness.runJob(job.toJson(), label: 'ivtc');
      expect(r.success, isTrue, reason: r.error);
      final n = await _countFrames(r.outputPath!);
      print('  $_telecineFrames source -> $n output (expected 72)');
      expect(n, _telecineFrames * 4 ~/ 5,
          reason: 'IVTC must remove the pulldown-duplicated frame from every '
              'cycle of five. The source count means VDecimate did nothing.');
    });

    test('frame rate conversion retimes by the reduced ratio', () async {
      // Retime. 25 -> 24000/1001 reduces to 960/1001, so 75 -> 71.
      //
      // Deinterlacing is disabled *explicitly*: ProcessingPipeline()'s default
      // has QTGMC enabled, which would fan the count out by two and make this
      // assertion about the composition rather than about FlowFPS.
      const expected = _interlacedFrames * 960 ~/ 1001; // 71
      final job = _job(
        'retime',
        input: _interlaced,
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
          frameRate: FrameRateParameters(
            enabled: true,
            target: FrameRateTarget.film23976,
            sourceFpsNum: 25,
            sourceFpsDen: 1,
          ),
        ),
        width: 720,
        height: 576,
        pixFmt: 'yuv422p',
        fps: _interlacedFps,
        totalFrames: _interlacedFrames,
      );

      final r = await WorkerHarness.runJob(job.toJson(), label: 'retime');
      expect(r.success, isTrue, reason: r.error);
      final n = await _countFrames(r.outputPath!);
      print('  $_interlacedFrames source -> $n output (expected $expected)');
      expect(n, expected,
          reason: 'FlowFPS was chosen over BlockFPS precisely because its '
              'output count is n*num/den exactly, where BlockFPS is '
              'floor((n-1)*r)+1. A count of ${expected + 1} means the '
              'BlockFPS arithmetic is in play and every retimed job reports a '
              'progress total one frame out.');
    });
  });

  group('the preview shows the frame it claims to', () {
    // `--frame S` is a SOURCE index (the worker logs "Preview: source frame
    // S"), and the target's output index is output_count(local). So under
    // double-rate the preview of source frame S must be output frame 2S.
    //
    // The assertion is deliberately RELATIVE — the correct output frame must be
    // closer to the preview than its neighbours are. An absolute tolerance
    // would have to absorb the encoder, the colour conversion and the window
    // edges, and picking one loose enough to be safe would also be loose enough
    // to pass on a preview that is off by a frame. The fixture moves ~12/255
    // per source frame, so neighbours are comfortably distinguishable.
    late String encoded;

    setUpAll(() async {
      // Untrimmed, so output frame index is exactly output_count(source index)
      // with no start offset to reason about. Lossless, so the comparison is
      // not measuring H.264.
      final job = _job(
        'preview_sync',
        input: _interlaced,
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
              preset: QTGMCPreset.superFast, tff: true, fpsDivisor: 1),
        ),
        width: 720,
        height: 576,
        pixFmt: 'yuv422p',
        fps: _interlacedFps,
        totalFrames: _interlacedFrames,
        codec: VideoCodec.ffv1,
      );
      final r = await WorkerHarness.runJob(job.toJson(), label: 'preview_sync');
      expect(r.success, isTrue, reason: r.error);
      encoded = r.outputPath!;
      expect(await _countFrames(encoded), _interlacedFrames * 2);
    });

    /// The job used for the preview must match the encode exactly, or any
    /// difference measured is the job's, not the mapping's.
    VideoJob previewJob() => _job(
          'preview_sync',
          input: _interlaced,
          pipeline: const ProcessingPipeline(
            deinterlace: QTGMCParameters(
                preset: QTGMCPreset.superFast, tff: true, fpsDivisor: 1),
          ),
          width: 720,
          height: 576,
          pixFmt: 'yuv422p',
          fps: _interlacedFps,
          totalFrames: _interlacedFrames,
          codec: VideoCodec.ffv1,
        );

    for (final sourceFrame in [12, 24, 36]) {
      test('source frame $sourceFrame previews as output frame '
          '${sourceFrame * 2}', () async {
        final pv = await WorkerHarness.runPreview(previewJob().toJson(),
            frame: sourceFrame, label: 'pv$sourceFrame');
        expect(pv.success, isTrue, reason: pv.toString());
        final preview =
            await WorkerHarness.imageToRgb24(pv.png!, label: 'pv$sourceFrame');

        final expectedIndex = sourceFrame * 2;
        // ±4 output frames is ±2 source frames — far enough that motion is
        // unambiguous, near enough to catch an off-by-one-source-frame error.
        final candidates = <int, double>{};
        for (final offset in [-4, -2, 0, 2, 4]) {
          final idx = expectedIndex + offset;
          candidates[idx] = WorkerHarness.meanAbsDiff(
              preview, await _frameRgb(encoded, idx));
        }
        candidates.forEach((idx, diff) => print(
            '  output frame $idx: meanAbsDiff ${diff.toStringAsFixed(2)}'
            '${idx == expectedIndex ? '   <- expected' : ''}'));

        final best =
            candidates.entries.reduce((a, b) => a.value <= b.value ? a : b);
        expect(best.key, expectedIndex,
            reason: 'the preview of source frame $sourceFrame matched output '
                'frame ${best.key} more closely than $expectedIndex, so the '
                'preview and the render disagree about which frame this is');

        // And it must actually be the same picture, not merely the closest of
        // five wrong ones.
        expect(candidates[expectedIndex]!, lessThan(6.0),
            reason: 'the preview is nearest the right frame but still differs '
                'from it substantially, which points at the pass rendering '
                'differently in the two paths rather than at the mapping');
      }, timeout: const Timeout(Duration(minutes: 6)));
    }
  });
}
