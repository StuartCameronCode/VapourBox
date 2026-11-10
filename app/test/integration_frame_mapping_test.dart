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
///   Fanout then Retime to 25  31 -> 62 -> 31 (the retime converts from the
///                             doubled 50p, not the source's 25)
///
/// Heavy (full encode + preview) — nightly, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:convert';
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

import 'support/gpu_expectations.dart';
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

/// Every progress total the worker reported — what the app shows as
/// "frame / total" and derives the percentage and ETA from. The last one is
/// always the frames written (the worker sends a final 100% with the real
/// count), so only the ones before it say whether the total was right while
/// the encode ran. A clip this short may finish before the first poll, leaving
/// none; `video_job.rs`'s frame_rate_progress_tests are the deterministic
/// guard, this one checks the real pipeline agrees whenever it can.
List<int> _progressTotals(JobResult r) {
  final totals = <int>[];
  for (final line in r.logs) {
    if (!line.startsWith('{')) continue;
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      final total = json['totalFrames'];
      if (json['type'] == 'progress' && total is int) totals.add(total);
    } catch (_) {/* not a worker message */}
  }
  return totals;
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
    return await WorkerHarness.imageToRgb24(await out.readAsBytes(),
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
          // No sourceFpsNum/Den: the app never sends them (issue #134), so
          // the worker must work the ratio out from the job's input rate.
          frameRate: FrameRateParameters(
            enabled: true,
            target: FrameRateTarget.film23976,
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
      print('  progress totals: ${_progressTotals(r).toSet()}');
      expect(_progressTotals(r), everyElement(n),
          reason: 'issue #134: a total left at the source count pins '
              'progress at 100% with no ETA for the rest of the encode');
    });

    test('a custom frame rate is the exact rate typed in', () async {
      // Issue #129. 59.94 typed in must run at 60000/1001, not 2997/50: from
      // 25 that is 2400/1001, so 75 -> floor(75 * 2400 / 1001) = 179.
      const expected = _interlacedFrames * 2400 ~/ 1001; // 179
      final job = _job(
        'custom_rate',
        input: _interlaced,
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
          frameRate: FrameRateParameters(
            enabled: true,
            target: FrameRateTarget.custom,
            customFps: 59.94,
          ),
        ),
        width: 720,
        height: 576,
        pixFmt: 'yuv422p',
        fps: _interlacedFps,
        totalFrames: _interlacedFrames,
      );

      // MOV, not the helper's MKV: Matroska's 1/1000 timebase cannot hold
      // 60000/1001, so ffprobe would report an estimate (19001/317) for any
      // NTSC rate, named or typed.
      final json = job.toJson();
      json['outputPath'] = '$_outDir/custom_rate.mov';
      (json['encodingSettings'] as Map<String, dynamic>)['container'] = 'mov';
      final r = await WorkerHarness.runJob(json, label: 'custom_rate');
      expect(r.success, isTrue, reason: r.error);
      final n = await _countFrames(r.outputPath!);
      print('  $_interlacedFrames source -> $n output (expected $expected)');
      expect(n, expected);
      expect(_progressTotals(r), everyElement(n));
      final v = await WorkerHarness.firstStream(r.outputPath!,
          selector: 'v:0', entries: ['r_frame_rate']);
      expect(v?['r_frame_rate'], '60000/1001',
          reason: 'an NTSC decimal must become its 1001 fraction');
    });

    test('a frame rate after double-rate QTGMC converts from the doubled rate',
        () async {
      // 25i doubled to 50p, then to 25: 50 -> 25 halves, so 31 -> 62 -> 31.
      // Taking the ratio against the source's 25 would claim 62.
      const start = 10, end = 40;
      const sourceFrames = end - start + 1; // 31
      final job = _job(
        'double_rate_retime',
        input: _interlaced,
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(
              preset: QTGMCPreset.superFast, tff: true, fpsDivisor: 1),
          frameRate: FrameRateParameters(
            enabled: true,
            target: FrameRateTarget.pal25,
          ),
        ),
        width: 720,
        height: 576,
        pixFmt: 'yuv422p',
        fps: _interlacedFps,
        totalFrames: sourceFrames,
        startFrame: start,
        endFrame: end,
      );

      final r = await WorkerHarness.runJob(job.toJson(),
          label: 'double_rate_retime');
      expect(r.success, isTrue, reason: r.error);
      final n = await _countFrames(r.outputPath!);
      print('  $sourceFrames source -> $n output (expected $sourceFrames)');
      expect(n, sourceFrames);
      print('  progress totals: ${_progressTotals(r).toSet()}');
      expect(_progressTotals(r), everyElement(n));
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

  // Issue #129. A retime's phase depends on where its clip starts, and the
  // preview's clip starts at its window, so at a ratio that is not a whole
  // number the preview generated its frames at different moments than the
  // encode unless the worker pads it back into phase. 25 -> 60 (×2.4, a period
  // of five source frames) with a 5-frame window radius puts every target here
  // at a different padding. Lossless, so the comparison is not measuring the
  // encoder, and FlowFPS, which is deterministic and needs no GPU.
  group('a generated frame previews as the encode makes it', () {
    ProcessingPipeline pipeline() => const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
          frameRate: FrameRateParameters(
            enabled: true,
            target: FrameRateTarget.custom,
            customFps: 60,
          ),
        );
    VideoJob job(String name, {int? start, int? end}) => _job(
          name,
          input: _interlaced,
          pipeline: pipeline(),
          width: 720,
          height: 576,
          pixFmt: 'yuv422p',
          fps: _interlacedFps,
          totalFrames: start == null ? _interlacedFrames : end! - start + 1,
          startFrame: start,
          endFrame: end,
          codec: VideoCodec.ffv1,
        );

    /// Previews every output frame of [sourceFrames] and checks each against
    /// the encode's frame at the same moment: outputs sit at m * 5/12 source
    /// frames from the in-point, so source frame t's are ceil(t * 12/5) on.
    Future<void> check(VideoJob encodeJob, List<int> sourceFrames,
        {int origin = 0}) async {
      final r = await WorkerHarness.runJob(encodeJob.toJson(),
          label: encodeJob.outputPath);
      expect(r.success, isTrue, reason: r.error);
      final pads = <String>{};
      for (final t in sourceFrames) {
        final first = ((t - origin) * 12 + 4) ~/ 5;
        final next = ((t - origin + 1) * 12 + 4) ~/ 5;
        for (var k = 0; k < next - first; k++) {
          final pv = await WorkerHarness.runPreview(encodeJob.toJson(),
              frame: t, subFrame: k, label: 'pv${t}_$k');
          expect(pv.success, isTrue, reason: pv.toString());
          final logs = pv.logs;
          pads.add(RegExp(r'rate pad (\d+)').firstMatch(logs)!.group(1)!);
          final generated = (first + k) * 5 % 12 != 0;
          expect(logs,
              contains('sub_frame=$k sub_frames=${next - first} '
                  'generated=${generated ? 1 : 0}'));

          final preview =
              await WorkerHarness.imageToRgb24(pv.png!, label: 'pv${t}_$k');
          final want = first + k;
          final candidates = <int, double>{
            for (final idx in [want - 1, want, want + 1])
              idx: WorkerHarness.meanAbsDiff(
                  preview, await _frameRgb(r.outputPath!, idx)),
          };
          candidates.forEach((idx, diff) => print('  source $t output $k -> '
              'encode frame $idx: ${diff.toStringAsFixed(2)}'
              '${idx == want ? '   <- expected' : ''}'));
          final best =
              candidates.entries.reduce((a, b) => a.value <= b.value ? a : b);
          expect(best.key, want,
              reason: 'the preview made this frame at a different moment '
                  'than the encode did');
          expect(candidates[want]!, lessThan(6.0));
        }
      }
      expect(pads.length, greaterThan(1),
          reason: 'the targets were chosen to need different padding');
    }

    test('from the start of the source', () async {
      await check(job('subframe_sync'), [12, 13, 21]);
    }, timeout: const Timeout(Duration(minutes: 10)));

    // The in-point is past interlaced_test.avi's leading null frames (stored
    // pts 0, then 5). A seek into that gap rebases to the first stored frame
    // after it (issue #157's PTS reset), so a trim starting at 1..4 is shifted
    // against the untrimmed numbering — the leading-repeat-slots problem of its
    // own, not what this test is about. Same offsets as 3 -> 13, 19.
    test('from an in-point', () async {
      await check(job('subframe_sync_trim', start: 6, end: 53), [16, 22],
          origin: 6);
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  // RIFE needs a Vulkan device, so each test here is tagged `gpu` and the GPU-less
  // CI runners leave the group out, encode included (dart_test.yaml; a group
  // with no selected tests never runs its setUpAll). Elsewhere it skips without a
  // device, or fails under VAPOURBOX_EXPECT_VULKAN=1 (see
  // support/gpu_expectations.dart); integration_gpu_plugins_test.dart covers
  // the refusal. Its count must match FrameMap's
  // Retime exactly — floor(n * 2) here — and since every other output frame is
  // a real one passed through untouched, the preview of source frame S must be
  // output frame 2S, picture for picture.
  group('RIFE', () {
    late bool available;
    late String encoded;

    ProcessingPipeline rifePipeline() => const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
          frameRate: FrameRateParameters(
            enabled: true,
            target: FrameRateTarget.pal50,
            method: FrameRateMethod.rife,
          ),
        );

    VideoJob rifeJob() => _job(
          'rife_2x',
          input: _interlaced,
          pipeline: rifePipeline(),
          width: 720,
          height: 576,
          pixFmt: 'yuv422p',
          fps: _interlacedFps,
          totalFrames: _interlacedFrames,
          codec: VideoCodec.ffv1,
        );

    setUpAll(() async {
      final probe = await Process.run(WorkerHarness.workerPath, ['--probe-rife'],
          environment: WorkerHarness.workerEnv,
          workingDirectory: File(WorkerHarness.workerPath).parent.path);
      available = probe.stdout.toString().contains('"available":true');
      print('  RIFE probe: ${probe.stdout.toString().trim()}');
      if (!available) return;
      // RIFE's model is an add-on (frame-rate-rife), installed with the app's
      // own installer from the URL its manifest pins.
      await WorkerHarness.ensureAddon('frame-rate-rife');
      // On a CPU Vulkan driver (lavapipe) RIFE is slow, alongside
      // the other heavy files. This 75-frame encode passed in under two
      // minutes on one Linux job and hit the default 5 in another, so it gets
      // the AI-upscale encodes' budget.
      final r = await WorkerHarness.runJob(rifeJob().toJson(),
          label: 'rife_2x',
          timeout: const Duration(minutes: 20),
          extraEnv: const {'VAPOURBOX_STALL_TIMEOUT_SECS': '1200'});
      expect(r.success, isTrue, reason: r.error);
      encoded = r.outputPath!;
    });

    test('25 -> 50 emits exactly twice the frames', () async {
      // Skips without a device, unless VAPOURBOX_EXPECT_VULKAN=1.
      if (!available && !await requireGpuPlugin('--probe-rife')) return;
      expect(await _countFrames(encoded), _interlacedFrames * 2);
    }, tags: ['gpu']);

    for (final sourceFrame in [12, 36]) {
      test('source frame $sourceFrame previews as output frame ${sourceFrame * 2}',
          () async {
        if (!available && !await requireGpuPlugin('--probe-rife')) return;
        final pv = await WorkerHarness.runPreview(rifeJob().toJson(),
            frame: sourceFrame, label: 'rife_pv$sourceFrame');
        expect(pv.success, isTrue, reason: pv.toString());
        final preview =
            await WorkerHarness.imageToRgb24(pv.png!, label: 'rife_pv$sourceFrame');
        final expectedIndex = sourceFrame * 2;
        final candidates = <int, double>{};
        for (final offset in [-2, -1, 0, 1, 2]) {
          final idx = expectedIndex + offset;
          candidates[idx] = WorkerHarness.meanAbsDiff(
              preview, await _frameRgb(encoded, idx));
        }
        candidates.forEach((idx, diff) => print(
            '  output frame $idx: meanAbsDiff ${diff.toStringAsFixed(2)}'
            '${idx == expectedIndex ? '   <- expected' : ''}'));
        final best =
            candidates.entries.reduce((a, b) => a.value <= b.value ? a : b);
        expect(best.key, expectedIndex);
        expect(candidates[expectedIndex]!, lessThan(2.0),
            reason: 'output frame $expectedIndex is a real frame passed '
                'through, so the preview should be the same picture');
      }, timeout: const Timeout(Duration(minutes: 6)), tags: ['gpu']);
    }

    // Issue #129: the frame RIFE makes between two source frames can be
    // previewed, and it is the encode's.
    test('source frame 12, output 2, previews as generated frame 25', () async {
      if (!available && !await requireGpuPlugin('--probe-rife')) return;
      final pv = await WorkerHarness.runPreview(rifeJob().toJson(),
          frame: 12, subFrame: 1, label: 'rife_pv12_1');
      expect(pv.success, isTrue, reason: pv.toString());
      expect(pv.logs, contains('sub_frame=1 sub_frames=2 generated=1'));
      final preview =
          await WorkerHarness.imageToRgb24(pv.png!, label: 'rife_pv12_1');
      final candidates = <int, double>{
        for (final idx in [24, 25, 26])
          idx: WorkerHarness.meanAbsDiff(preview, await _frameRgb(encoded, idx)),
      };
      candidates.forEach((idx, diff) => print(
          '  output frame $idx: meanAbsDiff ${diff.toStringAsFixed(2)}'
          '${idx == 25 ? '   <- expected' : ''}'));
      final best =
          candidates.entries.reduce((a, b) => a.value <= b.value ? a : b);
      expect(best.key, 25);
      // RIFE runs on the GPU in fp16; allow its run-to-run noise, no more.
      expect(candidates[25]!, lessThan(2.0));
    }, timeout: const Timeout(Duration(minutes: 6)), tags: ['gpu']);
  });
}
