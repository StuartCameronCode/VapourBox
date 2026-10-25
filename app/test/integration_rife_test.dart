// RIFE frame interpolation, through the real worker binary.
//
// Script-only (no encode), so it runs in the per-push gate on every platform —
// including the hosted runners, which have no GPU. That is the point of two of
// these: RIFE segfaults without a Vulkan device, so what must hold everywhere
// is that the worker *knows* when it can't run and refuses with a message the
// user can act on. The script-content test runs only where the probe says RIFE
// works; the encode itself is in integration_frame_mapping_test.dart (heavy).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/rife_status.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

VideoJob _rifeJob() => VideoJob(
      id: const Uuid().v4(),
      inputPath: WorkerHarness.inputFile,
      outputPath: p.join(WorkerHarness.outputDir, 'rife', 'rife_script.mkv'),
      processingPipeline: const ProcessingPipeline(
        deinterlace: QTGMCParameters(enabled: false),
        frameRate: FrameRateParameters(
          enabled: true,
          target: FrameRateTarget.pal50,
          method: FrameRateMethod.rife,
          sourceFpsNum: 25,
          sourceFpsDen: 1,
        ),
      ),
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

Future<Map<String, dynamic>> _probe({Map<String, String> extraEnv = const {}}) async {
  final r = await Process.run(
    WorkerHarness.workerPath,
    ['--probe-rife'],
    environment: {...WorkerHarness.workerEnv, ...extraEnv},
    workingDirectory: File(WorkerHarness.workerPath).parent.path,
  );
  expect(r.exitCode, 0, reason: '--probe-rife failed: ${r.stderr}');
  final line = const LineSplitter()
      .convert(r.stdout.toString())
      .lastWhere((l) => l.trim().startsWith('{'), orElse: () => '');
  expect(line, isNotEmpty, reason: 'no JSON from --probe-rife: ${r.stdout}');
  return jsonDecode(line) as Map<String, dynamic>;
}

void main() {
  late Map<String, dynamic> probe;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    probe = await _probe();
    // ignore: avoid_print
    print('RIFE probe on this machine: $probe');
  });

  test('--probe-rife answers, and a "no" always comes with a remedy', () {
    expect(probe['available'], isA<bool>());
    final status = RifeStatus.fromJson(probe);
    expect(status.available, probe['available']);
    if (!status.available) {
      expect(probe['reason'], isA<String>());
      expect(status.message, isNotNull);
      expect(status.message!.length, greaterThan(40));
      expect(status.reason, isNot('probeFailed'),
          reason: 'the probe could not even run here, which hides the real '
              'reason from the user: ${status.message}');
    }
  });

  test('a RIFE job where RIFE cannot run is refused with that message', () async {
    final env = {'VAPOURBOX_DISABLE_VULKAN': '1'};
    final disabled = await _probe(extraEnv: env);
    expect(disabled['available'], isFalse);

    // Through the real encode entry point: it must fail before vspipe starts,
    // naming the reason, rather than producing a script that would segfault.
    final saved = Platform.environment['VAPOURBOX_DISABLE_VULKAN'];
    expect(saved, isNull, reason: 'run this test without VAPOURBOX_DISABLE_VULKAN set');
    final job = _rifeJob();
    final configFile = File(p.join(Directory.systemTemp.path, 'vb_rife_${job.id}.json'));
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
      // Whatever the reason here (disabled, or no RIFE build for this
      // platform at all), the refusal is the probe's own wording.
      final reason = RifeStatus.fromJson(disabled).message!;
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

  test('where RIFE runs, the script loads it explicitly and calls it', () async {
    if (probe['available'] != true) {
      markTestSkipped('RIFE is not available here: ${probe['reason']}');
      return;
    }
    final script = await WorkerHarness.generateScript(_rifeJob().toJson());
    expect(script, contains('core.std.LoadPlugin('));
    expect(script, contains('${p.separator}rife${p.separator}'.replaceAll(r'\', r'\\')));
    expect(script, contains('core.rife.RIFE(_rife_rgb, model_path='));
    expect(script, contains('fps_num=50, fps_den=1, sc=True)'));
    expect(script, contains('core.misc.SCDetect(clip, threshold=0.1)'));
    expect(script, isNot(contains('core.mv.FlowFPS(')));
  });
}
