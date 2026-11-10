/// Issue #148: Frame Rate combined with Noise Reduction and Sharpen.
///
/// The report was "black shadow-like patches" in the output once Denoise and
/// Sharpen were added to a frame rate conversion that was clean on its own.
/// It did not reproduce on macOS arm64 (docs/reports/issue-148-frame-rate-
/// combined), so this pins the measured behaviour rather than a fix: adding
/// the default Noise Reduction (SMDegrain) and Sharpen (LSFmod) must not make
/// the synthesized frames any more prone to dark patches than frame rate
/// conversion alone.
///
/// The metric is the share of luma pixels in a synthesized frame that are
/// darker than BOTH real frames either side of it by more than 24/255. An
/// interpolator has nothing to build such a pixel from, so it is the signature
/// of the reported defect. On the fixture it is ~0.001-0.005% whatever the
/// passes; a single black 32x32 block in this 320x240 clip would be 1.3% of
/// the frame it appears in. It is checked two ways: the mean over every
/// synthesized frame (within 0.05 percentage points of frame rate alone), and
/// the worst single frame (within 0.25), because a patch confined to one frame
/// adds only ~0.03 points to a mean over ~40 frames and would pass that alone.
///
/// Heavy (full encodes) — nightly, not the push gate.
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
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/gpu_expectations.dart';
import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/frame_rate_combined';

// small_clip.mp4: 320x240 yuv420p, 29.97 fps, real (film) motion.
const _w = 320, _h = 240, _frames = 40;

/// Percentage points the combined pipeline may exceed frame-rate-only by:
/// the mean over synthesized frames, and the worst single one. Measured
/// worst frames are ~0.02-0.05%, so 0.25 is ~5x above that spread and ~5x
/// below one black 32x32 block.
const _meanTolerance = 0.05, _worstTolerance = 0.25;

typedef _DarkShare = ({double mean, double worst});

VideoJob _job(String label, FrameRateMethod method, {required bool filters}) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: p.join(
          WorkerHarness.repoRoot, 'Tests', 'TestResources', 'small_clip.mp4'),
      outputPath: '$_outDir/$label.mkv',
      processingPipeline: ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        noiseReduction: NoiseReductionParameters(enabled: filters),
        sharpen: SharpenParameters(enabled: filters),
        frameRate: FrameRateParameters(
            enabled: true, target: FrameRateTarget.ntsc5994, method: method),
      ),
      // Lossless, so the measurement sees the pipeline, not the encoder.
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      inputWidth: _w,
      inputHeight: _h,
      inputPixelFormat: 'yuv420p',
      inputFrameRate: 29.97,
      totalFrames: _frames,
      endFrame: _frames - 1,
    );

/// Every frame of [path] as 8-bit luma.
Future<List<Uint8List>> _lumaFrames(String path) async {
  final r = await Process.run(
      WorkerHarness.ffmpegPath,
      ['-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
      stdoutEncoding: null,
      environment: WorkerHarness.ffmpegEnv);
  expect(r.exitCode, 0, reason: r.stderr.toString());
  final bytes = r.stdout as List<int>;
  const size = _w * _h;
  return [
    for (var o = 0; o + size <= bytes.length; o += size)
      Uint8List.fromList(bytes.sublist(o, o + size)),
  ];
}

/// Over the synthesized frames (odd indices at 2x), the mean and the worst
/// percentage of pixels darker than both neighbouring real frames by more
/// than [t].
_DarkShare _darkPatchPercent(List<Uint8List> f, {int t = 24}) {
  var sum = 0.0, worst = 0.0, n = 0;
  for (var m = 1; m + 1 < f.length; m += 2) {
    final a = f[m - 1], y = f[m], b = f[m + 1];
    var dark = 0;
    for (var i = 0; i < y.length; i++) {
      final lo = a[i] < b[i] ? a[i] : b[i];
      if (y[i] < lo - t) dark++;
    }
    final share = dark / y.length;
    sum += share;
    if (share > worst) worst = share;
    n++;
  }
  expect(n, greaterThan(10), reason: 'too few synthesized frames to measure');
  return (mean: 100 * sum / n, worst: 100 * worst);
}

Future<_DarkShare> _measure(String label, FrameRateMethod method,
    {required bool filters}) async {
  final r = await WorkerHarness.runJob(
      _job(label, method, filters: filters).toJson(),
      label: label,
      timeout: const Duration(minutes: 20),
      extraEnv: const {'VAPOURBOX_STALL_TIMEOUT_SECS': '1200'});
  expect(r.success, isTrue, reason: r.error);
  final frames = await _lumaFrames(r.outputPath!);
  // 29.97 -> 59.94 doubles the count exactly.
  expect(frames.length, _frames * 2);
  final d = _darkPatchPercent(frames);
  print('  $label: dark-patch mean ${d.mean.toStringAsFixed(4)}% '
      'worst ${d.worst.toStringAsFixed(4)}%');
  return d;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    Directory(_outDir).createSync(recursive: true);
  });

  for (final method in [FrameRateMethod.flowFps, FrameRateMethod.rife]) {
    test('${method.name}: Noise Reduction + Sharpen add no dark patches',
        () async {
      if (method == FrameRateMethod.rife &&
          !await requireGpuPlugin('--probe-rife')) {
        return;
      }
      final alone =
          await _measure('${method.name}_alone', method, filters: false);
      final combined =
          await _measure('${method.name}_nr_sharpen', method, filters: true);
      expect(combined.mean, lessThan(alone.mean + _meanTolerance),
          reason: 'synthesized frames gained dark patches once Noise '
              'Reduction and Sharpen were added (issue #148): mean '
              '${combined.mean.toStringAsFixed(4)}% vs '
              '${alone.mean.toStringAsFixed(4)}% with frame rate conversion '
              'alone');
      expect(combined.worst, lessThan(alone.worst + _worstTolerance),
          reason: 'a synthesized frame gained dark patches once Noise '
              'Reduction and Sharpen were added (issue #148): worst frame '
              '${combined.worst.toStringAsFixed(4)}% vs '
              '${alone.worst.toStringAsFixed(4)}% with frame rate conversion '
              'alone');
    }, timeout: const Timeout(Duration(minutes: 45)));
  }
}
