// Task #120: the two Stabilize failures of the 2026-11-25 Windows v2 nightly,
// run in a loop for `.github/workflows/repro-windows-stabilize.yml`.
//
// - `encode`: the heavy `stabilize: Stab runs end-to-end` job of
//   integration_new_passes_test.dart (interlaced_test.avi, deinterlace off,
//   Stab with mirror 3), which failed with "pipe_source: frame 0 was asked
//   for after it left the cache".
// - `sweep`: the format sweep's `stabilize/pitchMode=auto` preview at
//   `720x480/yuv444p16le/prog`, which hung past its 6-minute limit (it takes
//   2-4 s everywhere else).
//
// Skipped unless `VAPOURBOX_REPRO_STABILIZE=N` is set; then each case runs N
// times, each run its own test and its own verdict (never a retry).
// `VAPOURBOX_REPRO_CASES` (`encode`, `sweep`, or both, comma-separated)
// picks the cases. A hung preview is sampled before it is killed
// (`WorkerHarness.runPreview`, `describeHang`).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/stabilize_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/format_sweep.dart';
import 'support/worker_harness.dart';

final _repeat = int.tryParse(Platform.environment['VAPOURBOX_REPRO_STABILIZE'] ?? '') ?? 0;
final _cases = (Platform.environment['VAPOURBOX_REPRO_CASES'] ?? 'encode,sweep').split(',');

void main() {
  if (_repeat <= 0) {
    test('Stabilize repro (task #120)', () {},
        skip: 'set VAPOURBOX_REPRO_STABILIZE=N to run the cases N times');
    return;
  }

  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  if (_cases.contains('encode')) {
    for (var k = 1; k <= _repeat; k++) {
      test('encode: Stab end-to-end (run $k of $_repeat)', () async {
        final out = Directory('${WorkerHarness.outputDir}/repro_stabilize')
          ..createSync(recursive: true);
        final job = VideoJob(
          id: const Uuid().v4(),
          inputPath: WorkerHarness.inputFile,
          outputPath: '${out.path}/stabilize_$k.mkv',
          processingPipeline: const ProcessingPipeline(
            deinterlace: QTGMCParameters(enabled: false),
            stabilize: StabilizeParameters(enabled: true, mirror: 3),
          ),
          encodingSettings: const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.passthrough,
          ),
        );
        final r = await WorkerHarness.runJob(job.toJson(),
            label: 'stabilize run $k', timeout: const Duration(minutes: 5));
        final tail = r.logs.length > 25 ? r.logs.sublist(r.logs.length - 25) : r.logs;
        expect(r.success, isTrue, reason: '${r.error}\n${tail.join('\n')}');
        File(r.outputPath!).deleteSync();
      }, timeout: const Timeout(Duration(minutes: 6)));
    }
  }

  if (_cases.contains('sweep')) {
    final variant = sweepVariants.firstWhere((v) => v.id == 'stabilize/pitchMode=auto');
    final row = nightlyRows(variant.index)
        .firstWhere((r) => r.key == '720x480/yuv444p16le/prog');
    for (var k = 1; k <= _repeat; k++) {
      test('sweep: ${variant.id} ${row.key} (run $k of $_repeat)', () async {
        final fixture = await sweepFixture(row);
        final job = sweepJob(variant.pipelineFor(row.size.width, row.size.height), row, fixture);
        final watch = Stopwatch()..start();
        final r = await WorkerHarness.runPreview(job.toJson(),
            frame: sweepPreviewFrame,
            label: 'pitch auto run $k',
            timeout: const Duration(minutes: 3));
        // ignore: avoid_print
        print('pitch auto run $k: ${watch.elapsedMilliseconds} ms');
        expect(r.success, isTrue, reason: '${r.error}\n${r.logs}');
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  }
}
