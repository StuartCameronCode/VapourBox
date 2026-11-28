// Issue #266: a source with subtitles came out of a Passthrough encode with
// its sound written far ahead of its picture (~38 s in an MKV), and players
// dropped the sound in stretches; remuxing it fixed it. The subtitles shared
// the sound's input: between cues the sparse subtitle stream is the one
// FFmpeg's scheduler waits for, so the source's sound ran ahead of the
// picture vspipe was still making and the muxer flushed it out ahead. The
// subtitles now come from an input of their own (pipeline_executor.rs,
// `subtitle_mapping`). A trimmed encode was never affected (`-shortest`'s
// sync queue holds the streams together); it stays here to check that the
// subtitle input is seeked as the sound's. See
// docs/reports/issue-266-subtitle-interleave.
@Tags(['heavy'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/av_sync.dart';
import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/subtitle_interleave';

final _source = p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'sparse_subs.mkv');
const _fps = 25.0;
const _frames = 1000;
const _off = QTGMCParameters(enabled: false);

/// The most the sound may run ahead of the picture in file order. The fixed
/// encode measures ~0.04 s (the encoder's own delay); before the fix ~34 s.
const _maxLead = 1.0;

VideoJob _job(String name, ContainerFormat container, {int? start, int? end}) => VideoJob(
      id: const Uuid().v4(),
      inputPath: _source,
      outputPath: '$_outDir/$name.${container.extension}',
      qtgmcParameters: _off,
      processingPipeline: const ProcessingPipeline(deinterlace: _off),
      encodingSettings: EncodingSettings(
        codec: VideoCodec.h264,
        container: container,
        audioMode: AudioMode.passthrough,
      ),
      inputWidth: 160,
      inputHeight: 120,
      inputPixelFormat: 'yuv420p',
      inputFrameRate: _fps,
      startFrame: start,
      endFrame: end,
      totalFrames: start != null && end != null ? end - start + 1 : _frames,
    );

/// Each cue's start time: the subtitle packets that carry text (mov_text
/// fills the gaps between cues with empty, 2-byte samples).
Future<List<double>> _cues(String path) async {
  final j = await WorkerHarness.ffprobeJson([
    '-v', 'error', '-select_streams', 's:0', '-show_entries', 'packet=pts_time,size',
    '-of', 'json', path,
  ]);
  return [
    for (final pk in j['packets'] as List)
      if (int.parse('${pk['size']}') > 2) double.parse('${pk['pts_time']}'),
  ];
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
    expect(await File(_source).exists(), isTrue,
        reason: 'missing $_source (Tests/TestResources/generate_sparse_subtitle_test.sh)');
    expect(await _cues(_source), [1.0, 35.0], reason: 'the fixture must have two cues 34 s apart');
  });

  for (final container in [ContainerFormat.mkv, ContainerFormat.mp4]) {
    final name = container.extension;
    test('$name: the sound stays with the picture and the cues keep their times', () async {
      final r = await WorkerHarness.runJob(_job('passthrough_$name', container).toJson(),
          label: 'subtitle_interleave_$name', timeout: const Duration(minutes: 4));
      expect(r.success, isTrue, reason: r.error);
      final out = r.outputPath!;
      final lead = await soundLeadInFileOrder(out);
      // ignore: avoid_print
      print('$name: sound ahead of the picture in file order: ${lead.toStringAsFixed(3)} s');
      expect(lead, lessThan(_maxLead),
          reason: '$name: the sound is stored ${lead.toStringAsFixed(2)} s ahead of its picture');
      final cues = await _cues(out);
      expect(cues.length, 2, reason: '$name: both cues copied');
      expect(cues[0], closeTo(1.0, 0.01));
      expect(cues[1], closeTo(35.0, 0.01));
    });
  }

  test('mkv trimmed from 5 s: the second cue moves with the trim', () async {
    final r = await WorkerHarness.runJob(
        _job('passthrough_trim', ContainerFormat.mkv, start: 125, end: 999).toJson(),
        label: 'subtitle_interleave_trim', timeout: const Duration(minutes: 4));
    expect(r.success, isTrue, reason: r.error);
    final out = r.outputPath!;
    final lead = await soundLeadInFileOrder(out);
    // ignore: avoid_print
    print('trimmed: sound ahead of the picture in file order: ${lead.toStringAsFixed(3)} s');
    expect(lead, lessThan(_maxLead));
    // A trimmed copy into MKV keeps the sound from the keyframe before the
    // in-point and stores the picture that much later (task #24), so the
    // cue is measured from the first picture.
    final cues = await _cues(out);
    final first = await WorkerHarness.ffprobeJson([
      '-v', 'error', '-select_streams', 'v:0', '-read_intervals', '%+#1',
      '-show_entries', 'packet=pts_time', '-of', 'json', out,
    ]);
    final videoStart = double.parse('${(first['packets'] as List).first['pts_time']}');
    expect(cues.last - videoStart, closeTo(30.0, 0.02), reason: 'the 35 s cue, 5 s into the trim');
  });
}
