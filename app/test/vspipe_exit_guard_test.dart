// Task #122: a vspipe that has printed its final line but does not exit is
// stopped after the grace, and the preview / encode still finish.
//
// On Windows runners vspipe was seen stuck in ExitProcess, its pipes open,
// so the worker's wait never returned. Here a wrapper stands in for that:
// it runs the real vspipe, then becomes a `sleep` holding vspipe's stdout
// and stderr, which is what the worker and the encoder see of a vspipe that
// cannot finish exiting. The worker finds the wrapper through
// `VAPOURBOX_VSPIPE` (debug builds only).
//
// Not on Windows: there the wrapper would be a batch file whose child keeps
// the pipes after cmd.exe is killed, which is not the case under test. The
// worker's own unit tests (`vspipe_exit::tests`) run the guard against a
// hanging process on every platform, and the Windows repro workflow
// measures the real case.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

const _graceSecs = 3;

void main() {
  late Map<String, String> env;
  late Directory scratch;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    scratch = Directory.systemTemp.createTempSync('vb_vspipe_exit_');
    final vs = p.join(WorkerHarness.depsDir, 'vapoursynth');
    final real = File(p.join(vs, 'vspipe-bin')).existsSync()
        ? p.join(vs, 'vspipe-bin')
        : p.join(vs, 'vspipe');
    final wrapper = File(p.join(scratch.path, 'vspipe-hangs-after-exit'));
    // `exec`: the process the worker holds is the one keeping the pipes,
    // so killing it closes them (as a real kill of vspipe would).
    wrapper.writeAsStringSync('#!/bin/sh\n'
        '"$real" "\$@"\n'
        'exec sleep 600\n');
    await Process.run('chmod', ['+x', wrapper.path]);
    env = {
      'VAPOURBOX_VSPIPE': wrapper.path,
      'VAPOURBOX_VSPIPE_EXIT_GRACE_SECS': '$_graceSecs',
    };
  });

  tearDownAll(() {
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  VideoJob job(String output) => VideoJob(
        id: const Uuid().v4(),
        inputPath: WorkerHarness.inputFile,
        outputPath: output,
        processingPipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
        ),
      );

  test('a preview whose vspipe does not exit comes back after the grace',
      () async {
    final watch = Stopwatch()..start();
    final r = await WorkerHarness.runPreview(
      job(p.join(scratch.path, 'unused.mkv')).toJson(),
      frame: 10,
      label: 'preview, vspipe hangs after exit',
      timeout: const Duration(seconds: 60),
      extraEnv: env,
    );
    watch.stop();
    expect(r.success, isTrue, reason: '${r.error}\n${r.logs}');
    expect(r.logs, contains('Output 1 frames in'),
        reason: 'the preview echoes vspipe\'s lines as they arrive');
    expect(r.logs, contains('but had not exited'),
        reason: 'the preview says it stopped vspipe');
    expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: _graceSecs)));
    expect(watch.elapsed, lessThan(const Duration(seconds: 45)));
  }, skip: Platform.isWindows ? 'see the header' : false,
      timeout: const Timeout(Duration(minutes: 2)));

  test('an encode whose vspipe does not exit finishes after the grace',
      () async {
    final out = p.join(scratch.path, 'guarded.mkv');
    final watch = Stopwatch()..start();
    final r = await WorkerHarness.runJob(
      job(out).toJson(),
      label: 'encode, vspipe hangs after exit',
      timeout: const Duration(seconds: 120),
      extraEnv: env,
    );
    watch.stop();
    final tail = r.logs.length > 30 ? r.logs.sublist(r.logs.length - 30) : r.logs;
    expect(r.success, isTrue, reason: '${r.error}\n${tail.join('\n')}');
    expect(r.logs.join('\n'), contains('but had not exited'));
    final frames = await WorkerHarness.ffprobeJson([
      '-v', 'error', '-count_frames', '-select_streams', 'v:0',
      '-show_entries', 'stream=nb_read_frames', '-of', 'json', out,
    ]);
    final read = int.parse(
        ((frames['streams'] as List).first as Map)['nb_read_frames'].toString());
    expect(read, greaterThan(70), reason: 'the whole clip was encoded');
  }, skip: Platform.isWindows ? 'see the header' : false,
      timeout: const Timeout(Duration(minutes: 3)));
}
