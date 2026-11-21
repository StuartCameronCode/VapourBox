// Task #94: Core ML against the CPU provider for the ai-runtime passes, on a
// macOS x64 machine, through the worker as a user's job runs them.
//
// Copy into app/test/ and run from app/ (probe-coreml-intel.yml does):
//
//   cp docs/reports/task-94-coreml-intel-mps-abort/scripts/coreml_vs_cpu_test.dart app/test/
//   cd app && flutter test test/coreml_vs_cpu_test.dart
//
// For each model (DDColor 512, DeOldify Video, RestoreFormer++), in fresh
// worker processes and in this order:
//   coreml  16 frames  the first Core ML process for this model on the machine
//                      ("cold": Metal compiles its kernels)
//   coreml  16, 4      warm
//   cpu     16, 4      the shipped default on an Intel Mac since task #94
//   coreml  16         warm again
//   cpu     16
// Core ML runs set VAPOURBOX_AI_COREML_ON_INTEL=1 (ai_runtime.py's measuring
// switch, which restores the provider choice before task #94); CPU runs set
// VAPOURBOX_AI_FORCE_CPU=1, which on an Intel Mac is the same provider list as
// the default since task #94 (and makes the script mean the same on arm64). Each run records success, the vspipe failure (the MPS abort is
// `signal 6`), the provider line the pass logged, and the wall time. The 16-
// and 4-frame runs give the time per frame (their difference / 12) and the
// start-up (the rest). Outputs of the first warm Core ML and first CPU 16-frame
// runs are compared: luma must be bit-exact (both passes keep it), chroma
// (Colourisation) or the face (Face Restoration) differ by the mean absolute
// difference reported.
//
// Writes Tests/TestOutput/coreml_probe/results.json (one object per run, plus
// the comparisons) and prints each line as it goes. Never fails on a run that
// fails: the failure is the measurement.
@Tags(['heavy'])
@Timeout(Duration(hours: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/colorize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/face_restore_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

const _w = 640, _h = 480;

String get _dir => p.join(WorkerHarness.outputDir, 'coreml_probe');

class _Model {
  final String name;
  final String fixture;
  final double fps;
  final int start;
  final ProcessingPipeline pipeline;
  const _Model(this.name, this.fixture, this.fps, this.start, this.pipeline);
}

final _models = [
  // The frames the heavy tests encode (integration_colorize_test.dart,
  // integration_face_restore_test.dart).
  _Model('ddcolor', 'colorize_test.mp4', 24, 40,
      const ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false),
          colorize: ColorizeParameters(enabled: true))),
  _Model('deoldify', 'colorize_test.mp4', 24, 40,
      const ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false),
          colorize: ColorizeParameters(enabled: true, model: ColorizeModel.deoldify, temporalRadius: 1))),
  _Model('restoreformer', 'face_restore_test.mp4', 29.97, 30,
      const ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false),
          faceRestore: FaceRestoreParameters(enabled: true))),
];

Map<String, dynamic> _job(_Model m, String name, int frames) => VideoJob(
      id: const Uuid().v4(),
      inputPath: p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', m.fixture),
      outputPath: p.join(_dir, '$name.mkv'),
      processingPipeline: m.pipeline,
      encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
      inputWidth: _w,
      inputHeight: _h,
      inputPixelFormat: 'yuv420p',
      inputFrameRate: m.fps,
      totalFrames: frames,
      startFrame: m.start,
      endFrame: m.start + frames - 1,
    ).toJson();

final _results = <Map<String, dynamic>>[];

Future<void> _save() async {
  await File(p.join(_dir, 'results.json'))
      .writeAsString(const JsonEncoder.withIndent('  ').convert({
    'platform': WorkerHarness.platform,
    'tier': Platform.environment['VAPOURBOX_PROBE_ASSET'] ?? '',
    'runner': Platform.environment['VAPOURBOX_PROBE_RUNNER'] ?? '',
    'runs': _results,
  }));
}

Future<Map<String, dynamic>> _run(_Model m, String provider, int frames, String label) async {
  final name = '${m.name}_${provider}_${frames}_$label';
  final r = await WorkerHarness.runJob(_job(m, name, frames),
      label: name,
      timeout: const Duration(minutes: 40),
      extraEnv: {
        'VAPOURBOX_STALL_TIMEOUT_SECS': '2400',
        if (provider == 'coreml') 'VAPOURBOX_AI_COREML_ON_INTEL': '1',
        if (provider == 'cpu') 'VAPOURBOX_AI_FORCE_CPU': '1',
      });
  final providerLine = r.logs.lastWhere(
      (l) => l.contains('Colourisation: ${m.name} at') || l.contains('Face restoration:'),
      orElse: () => '');
  final mps = r.logs.where((l) => RegExp(r'MPS|Compilation failed|unable to load function|MTLReportFailure')
      .hasMatch(l)).take(5).toList();
  final row = {
    'model': m.name,
    'provider': provider,
    'frames': frames,
    'label': label,
    'success': r.success,
    'seconds': r.duration.inMilliseconds / 1000,
    'providerLine': providerLine.trim(),
    if (!r.success) 'error': (r.error ?? '').split('\n').take(6).join('\n'),
    if (mps.isNotEmpty) 'mpsLines': mps,
    'output': r.success ? (r.outputPath ?? p.join(_dir, '$name.mkv')) : null,
  };
  _results.add(row);
  await _save();
  // ignore: avoid_print
  print('RESULT ${jsonEncode(row)}');
  return row;
}

Future<Uint8List> _raw(String path) async {
  final r = await Process.run(WorkerHarness.ffmpegPath,
      ['-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-'],
      environment: WorkerHarness.ffmpegEnv, stdoutEncoding: null);
  return Uint8List.fromList(r.stdout as List<int>);
}

Future<void> _compare(_Model m, Map<String, dynamic> a, Map<String, dynamic> b) async {
  if (a['output'] == null || b['output'] == null) return;
  final x = await _raw(a['output'] as String), y = await _raw(b['output'] as String);
  final luma = _w * _h, frame = luma * 3 ~/ 2;
  var lumaChanged = 0, lumaDiff = 0.0, chromaDiff = 0.0;
  final frames = x.length ~/ frame;
  for (var f = 0; f < frames; f++) {
    for (var i = f * frame; i < f * frame + luma; i++) {
      final d = (x[i] - y[i]).abs();
      if (d != 0) lumaChanged++;
      lumaDiff += d;
    }
    for (var i = f * frame + luma; i < (f + 1) * frame; i++) {
      chromaDiff += (x[i] - y[i]).abs();
    }
  }
  final row = {
    'compare': m.name,
    'a': a['label'],
    'b': b['label'],
    'frames': frames,
    'sameSize': x.length == y.length,
    'lumaSamplesChanged': lumaChanged,
    'lumaMeanAbsDiff': lumaDiff / (frames * luma),
    'chromaMeanAbsDiff': chromaDiff / (frames * luma / 2),
  };
  _results.add(row);
  await _save();
  // ignore: avoid_print
  print('RESULT ${jsonEncode(row)}');
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
    await WorkerHarness.ensureAddon('colorize-ddcolor');
    await WorkerHarness.ensureAddon('colorize-deoldify');
    await WorkerHarness.ensureAddon('face-restoration');
  });

  for (final m in _models) {
    test('${m.name}: Core ML (cold, warm) against the CPU', () async {
      await _run(m, 'coreml', 16, 'cold');
      final warm = await _run(m, 'coreml', 16, 'warm1');
      await _run(m, 'coreml', 4, 'warm');
      final cpu = await _run(m, 'cpu', 16, 'cpu1');
      await _run(m, 'cpu', 4, 'cpu');
      await _run(m, 'coreml', 16, 'warm2');
      await _run(m, 'cpu', 16, 'cpu2');
      await _compare(m, warm, cpu);
    });
  }
}
