// RIFE and AI upscaling (Real-ESRGAN / Real-CUGAN / AnimeJaNai), through the
// real worker. Every model is an add-on (the plugins are in the deps bundle,
// their models not): the harness installs each with the app's own installer
// from the URL its manifest pins, so this also checks that the pinned URLs and
// hashes still hold — and the probes must answer before any is installed,
// since they run a stand-in network of their own.
//
// Both run a network through ncnn on Vulkan, and ncnn segfaults without a
// Vulkan device rather than raising. So what must hold on EVERY platform is
// that the worker knows when it can't run and refuses with a message the user
// can act on; and where it can run — which CI makes true on every platform that
// ships it, with a software Vulkan driver on the GPU-less runners (see
// support/gpu_expectations.dart) — that the script loads the plugin explicitly
// and a real frame comes out of the GPU at the right size.
//
// Runs in the per-push gate. Full encodes, frame counts and pixel checks are in
// integration_frame_mapping_test.dart (RIFE) and integration_ai_upscale_test.dart
// (heavy).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/gpu_plugin_status.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/gpu_expectations.dart';
import 'support/worker_harness.dart';

VideoJob _job(String name, ProcessingPipeline pipeline) => VideoJob(
      id: const Uuid().v4(),
      inputPath: WorkerHarness.inputFile,
      outputPath: p.join(WorkerHarness.outputDir, 'gpu', '$name.mkv'),
      processingPipeline: pipeline,
      encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.none,
      ),
      inputWidth: 720,
      inputHeight: 576,
      inputPixelFormat: 'yuv422p',
      inputFrameRate: 25.0,
      totalFrames: 75,
    );

VideoJob _rifeJob() => _job(
      'rife',
      const ProcessingPipeline(
        deinterlace: QTGMCParameters(enabled: false),
        frameRate: FrameRateParameters(
          enabled: true,
          target: FrameRateTarget.pal50,
          method: FrameRateMethod.rife,
          sourceFpsNum: 25,
          sourceFpsDen: 1,
        ),
      ),
    );

VideoJob _upscaleJob(UpscaleMethod method, {String noise = 'conservative'}) => _job(
      'upscale_${method.name}',
      ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        // Cropped to 120x96 first: on a CPU Vulkan driver (Windows lavapipe,
        // which CI once used) one whole 720x576 Real-CUGAN frame took over
        // five minutes on Windows, and even 240x192 took 2.5 to over 5. This
        // test only needs a real frame out of the GPU at the right size;
        // full-size encodes are the heavy suite's.
        cropResize: CropResizeParameters(
          enabled: true,
          cropEnabled: true,
          cropLeft: 300,
          cropRight: 300,
          cropTop: 240,
          cropBottom: 240,
          useIntegerUpscale: true,
          upscaleMethod: method,
          upscaleFactor: 2,
          cuganNoise: noise,
        ),
      ),
    );

/// Width and height from a PNG's IHDR chunk.
(int, int) _pngSize(Uint8List png) {
  final b = ByteData.sublistView(png);
  return (b.getUint32(16), b.getUint32(20));
}

class _Feature {
  final GpuPlugin plugin;
  final VideoJob Function() job;

  /// The plugin's directory in the deps bundle.
  final String dir;

  /// The add-on holding its models, which the script must read them from.
  final String addon;
  final List<String> scriptMust;
  final (int, int) previewSize;
  const _Feature(this.plugin, this.job, this.dir, this.addon, this.scriptMust, this.previewSize);

  Future<void> install() => addon == 'animejanai'
      ? WorkerHarness.ensureAnimeJanai()
      : WorkerHarness.ensureAddon(addon);
}

final _features = <String, _Feature>{
  'RIFE': _Feature(GpuPlugin.rife, _rifeJob, 'rife', rifeAddonId, [
    'core.rife.RIFE(_rife_rgb, model_path=',
    'rife-v4.26_ensembleFalse',
    'fps_num=50, fps_den=1, sc=True)',
    'core.misc.SCDetect(clip, threshold=0.1)',
  ], (720, 576)),
  'Real-ESRGAN': _Feature(GpuPlugin.upscale, () => _upscaleJob(UpscaleMethod.realEsrgan), 'ncnn',
      'upscale-anime', [
    'upscale-RealESRGANv2-animevideo-xsx2.onnx',
    'core.ncnn.Model(_ai_rgb, network_path=_ai_model, fp16=True',
  ], (240, 192)),
  'Real-CUGAN': _Feature(GpuPlugin.upscale, () => _upscaleJob(UpscaleMethod.realCugan, noise: 'denoise3x'),
      'ncnn', 'upscale-anime', [
    'upscale-cugan-up2x-latest-denoise3x.onnx',
    'core.ncnn.Model(_ai_rgb, network_path=_ai_model, fp16=True',
  ], (240, 192)),
  'AnimeJaNai': _Feature(GpuPlugin.upscale, () => _upscaleJob(UpscaleMethod.animeJanai), 'ncnn',
      'animejanai', [
    '2x_AnimeJaNai_SD_V1beta34_Compact.onnx',
    '2x_AnimeJaNai_HD_V3_Compact.onnx',
    '_ai_model = _ai_model[0] if _ai_rgb.height <= 576 else _ai_model[1]',
    'core.ncnn.Model(_ai_rgb, network_path=_ai_model, fp16=True',
  ], (240, 192)),
};

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    // ignore: avoid_print
    print('GPU plugins on $platformId (expect Vulkan: $expectVulkan)');
  });

  for (final plugin in GpuPlugin.values) {
    group('${plugin.label} probe', () {
      test('answers, consistently with where it ships', () async {
        final probe = await probeGpuPlugin(plugin.probeFlag);
        // ignore: avoid_print
        print('  ${plugin.probeFlag}: $probe');
        expect(probe['available'], isA<bool>());
        if (!platformShipsGpuPlugins) {
          expect(probe['reason'], 'unsupportedPlatform',
              reason: '$platformId ships no ${plugin.label}, and must say so');
        } else if (expectVulkan) {
          expect(probe['available'], isTrue,
              reason: 'VAPOURBOX_EXPECT_VULKAN=1: ${probe['message']}');
        }
        if (probe['available'] != true) {
          final status = GpuPluginStatus.fromJson(plugin, probe);
          expect(status.message, isNotNull);
          expect(status.message!.length, greaterThan(40));
          expect(status.message, contains(plugin.label));
          expect(status.reason, isNot('probeFailed'),
              reason: 'the probe could not even run here, which hides the real '
                  'reason from the user: ${status.message}');
        }
        // The first probe initialises the device and compiles shaders; on a
        // CPU Vulkan driver (Mesa's lavapipe) that took 30.4 s on Windows.
      }, timeout: const Timeout(Duration(minutes: 3)));
    });
  }

  for (final MapEntry(key: name, value: f) in _features.entries) {
    group(name, () {
      test('a job where it cannot run is refused with the probe\'s message', () async {
        const env = {'VAPOURBOX_DISABLE_VULKAN': '1'};
        final disabled = await probeGpuPlugin(f.plugin.probeFlag, extraEnv: env);
        expect(disabled['available'], isFalse);
        expect(Platform.environment['VAPOURBOX_DISABLE_VULKAN'], isNull,
            reason: 'run this test without VAPOURBOX_DISABLE_VULKAN set');
        // Through the real encode entry point: it must fail before vspipe
        // starts, naming the reason, rather than produce a script that would
        // segfault.
        final job = f.job();
        final configFile = File(p.join(Directory.systemTemp.path, 'vb_gpu_${job.id}.json'));
        await configFile.writeAsString(jsonEncode(job.toJson()));
        try {
          final r = await Process.run(
            WorkerHarness.workerPath,
            ['--config', configFile.path],
            environment: {...WorkerHarness.workerEnv, ...env},
            workingDirectory: File(WorkerHarness.workerPath).parent.path,
          );
          final errors = const LineSplitter()
              .convert(r.stdout.toString())
              .where((l) => l.contains('"type":"error"'))
              .toList();
          expect(errors, isNotEmpty, reason: 'the job was not refused: ${r.stdout}');
          // Whatever the reason (disabled, or no build for this platform),
          // the refusal is the probe's own wording.
          final reason = GpuPluginStatus.fromJson(f.plugin, disabled).message!;
          final messages = errors
              .map((l) => (jsonDecode(l) as Map<String, dynamic>)['message'] as String)
              .join('\n');
          expect(messages, contains(reason));
          expect(File(p.join(Directory.systemTemp.path, '${job.id}.vpy')).existsSync(), isFalse,
              reason: 'a script was written for a job that cannot run');
        } finally {
          await configFile.delete().catchError((_) => configFile);
        }
      });

      test('where it runs, the script loads it explicitly and calls it', () async {
        if (!await requireGpuPlugin(f.plugin.probeFlag)) return;
        await f.install();
        final script = await WorkerHarness.generateScript(f.job().toJson());
        expect(script, contains('core.std.LoadPlugin('));
        String inPath(String s) => s.replaceAll(r'\', r'\\');
        expect(script, contains(inPath('${p.separator}${f.dir}${p.separator}')));
        for (final must in f.scriptMust) {
          expect(script, contains(must));
        }
        // The model comes from its add-on, never from the deps bundle (which
        // carried RIFE's and the anime upscalers' until deps 1.16.0).
        expect(script, contains(inPath('${p.separator}addons${p.separator}${f.addon}${p.separator}')));
        expect(script, isNot(contains(inPath('${p.separator}models${p.separator}'))),
            reason: 'a model path inside the deps bundle');
        if (platformId.startsWith('macos')) {
          expect(script, contains('moltenvk'), reason: 'MoltenVK must be preloaded on macOS');
        }
      }, timeout: const Timeout(Duration(minutes: 5)), tags: ['gpu']);

      test('where it runs, a real frame comes out of the GPU at the right size', () async {
        if (!await requireGpuPlugin(f.plugin.probeFlag)) return;
        await f.install();
        final pv = await WorkerHarness.runPreview(f.job().toJson(), frame: 21, label: 'gpu_$name');
        expect(pv.success, isTrue, reason: pv.errorTail);
        expect(_pngSize(pv.png!), f.previewSize);
      }, timeout: const Timeout(Duration(minutes: 5)), tags: ['gpu']);
    });
  }
}
