// Sources whose video starts after their audio (every DVB-T capture): frame N
// counts from the video's first picture, and the output keeps sound and
// picture in step.
//
// An input -ss counts from the container's start, which is the earliest
// stream's. With the sound 1 s ahead, the preview, the app's before frame and
// a trim all showed frame N-25; an untrimmed MKV/MP4 decode put 25 copies of
// the first picture in front (and an MP4 lost its last second to -frames:v);
// and an untrimmed TS encode came out with the sound 1 s late. Every check
// here is against an independent reference: a sequential decode of the
// source picked by index, and, for sync, the output file's own timestamps.
//
// Fixtures: Tests/TestResources/generate_video_start_offset.sh (a white frame
// at source frames 25 and 75, a 1 kHz beep at the same moments, the video
// starting 1 s after the audio). late_video_intra.ts is all-intra, so its
// seeks land on the frame asked for; late_video_gop.ts has 25-frame GOPs, so
// its seeks need the seek plan too (issue #169: an MPEG-TS seek otherwise
// lands on the next keyframe). See docs/reports/2026-11-video-start-offset
// and docs/reports/issue-169-mpeg-seek.
@Tags(['heavy'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/audio_restoration_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/models/source_model.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/services/preview_generator.dart';

import 'support/av_sync.dart';
import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/video_start_offset';

String _resource(String name) =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', name);

const _fixtures = ['late_video_intra.ts', 'late_video_gop.ts', 'late_video.mkv', 'late_video.mp4'];
const _frames = 100;
const _fps = 25.0;
const _previewFrames = [0, 1, 24, 25, 26, 60, 99];
const _trimStart = 30;
const _trimEnd = 59;

/// Half a frame: the most a stamped delay may be off.
const _syncTolerance = 0.5 / _fps;

const _off = QTGMCParameters(enabled: false);

VideoJob _job(
  String input,
  String name, {
  int? start,
  int? end,
  AudioMode audio = AudioMode.none,
  AudioCodec audioCodec = AudioCodec.aac,
  AudioQuality audioQuality = AudioQuality.high,
  AudioRestorationParameters audioPass = const AudioRestorationParameters(),
  ContainerFormat container = ContainerFormat.mkv,
  VideoCodec codec = VideoCodec.ffv1,
}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: input,
    outputPath: '$_outDir/$name.${container.extension}',
    qtgmcParameters: _off,
    processingPipeline: ProcessingPipeline(deinterlace: _off, audio: audioPass),
    encodingSettings: EncodingSettings(
      codec: codec,
      container: container,
      audioMode: audio,
      audioCodec: audioCodec,
      audioQuality: audioQuality,
    ),
    inputWidth: 320,
    inputHeight: 240,
    inputPixelFormat: 'yuv420p',
    inputFrameRate: _fps,
    startFrame: start,
    endFrame: end,
    totalFrames: start != null && end != null ? end - start + 1 : _frames,
  );
}

/// The app's before picture of [frame], through `beforeFrameArgs` (PNG).
Future<Uint8List> _beforeFrame(String video, int frame, double offset, SeekPlan? plan) async {
  final out = File(p.join(Directory.systemTemp.path,
      'vb_vstart_before_${DateTime.now().microsecondsSinceEpoch}.png'));
  try {
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      PreviewGenerator.beforeFrameArgs(
        videoPath: video,
        frameIndex: frame,
        frameRate: _fps,
        videoStartOffset: offset,
        seekPlan: plan,
        outputPath: out.path,
      ),
      environment: WorkerHarness.ffmpegEnv,
    );
    expect(r.exitCode, 0, reason: 'before frame $frame: ${r.stderr}');
    return await WorkerHarness.imageToRgb24(await out.readAsBytes(), label: 'before');
  } finally {
    if (await out.exists()) await out.delete().catchError((_) => out);
  }
}

/// [img] is source frame [n]: the closest of n-1..n+1, and nearly identical.
/// Every frame of the fixture differs (testsrc2), and the old fault was 25
/// frames off, so the neighbours tell a shift from a colour conversion.
Future<void> _expectFrame(String what, Uint8List img, String video, int n,
    {double maxDiff = 1.0}) async {
  final diffs = <int, double>{
    for (final k in [n - 1, n, n + 1])
      if (k >= 0 && k < _frames)
        k: WorkerHarness.meanAbsDiff(img, await WorkerHarness.frameRgb24(video, k, label: 'src')),
  };
  final best = diffs.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
  final table = diffs.entries.map((e) => '${e.key}: ${e.value.toStringAsFixed(2)}').join(', ');
  expect(best, n, reason: '$what is source frame $best, not $n ($table)');
  expect(diffs[n]!, lessThan(maxDiff), reason: '$what is not source frame $n ($table)');
}

/// Luma MD5s of the last [n] pictures [path] decodes.
Future<List<String>> _lastLumaHashes(String path, int n) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-sseof', '-2', '-i', path, '-map', '0:v:0',
     '-fps_mode', 'passthrough', '-pix_fmt', 'gray', '-f', 'framemd5', '-'],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: 'framemd5 of $path: ${r.stderr}');
  final hashes = [
    for (final line in (r.stdout as String).split('\n'))
      if (line.isNotEmpty && !line.startsWith('#')) line.split(',').last.trim(),
  ];
  expect(hashes.length, greaterThanOrEqualTo(n));
  return hashes.sublist(hashes.length - n);
}

Future<String> _encode(VideoJob job, String label) async {
  final r = await WorkerHarness.runJob(job.toJson(), label: label);
  expect(r.success, isTrue, reason: r.error);
  return r.outputPath!;
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  for (final file in _fixtures) {
    group(file, () {
      final video = _resource(file);
      final stem = p.basenameWithoutExtension(file);
      late SourceModel model;
      late SeekPlan? plan;

      setUpAll(() async {
        expect(await File(video).exists(), isTrue, reason: 'missing $video');
        model = await WorkerHarness.sourceModel(video);
        plan = model.seekPlan;
        expect(plan != null, file.endsWith('.ts'),
            reason: 'a TS seeks with a plan, nothing else does ($plan)');
      });

      test('the app finds the 1 s gap and counts the video, not the file', () async {
        // TS muxing adds ~10 ms between the streams.
        expect(model.videoStartOffset, closeTo(1.0, 0.02));
        final count = model.frameCount;
        expect(count, _frames);
      });

      for (final n in _previewFrames) {
        test('frame $n: the preview and the before frame are source frame $n', () async {
          final pv = await WorkerHarness.runPreview(_job(video, 'preview').toJson(),
              frame: n, label: 'vstart_preview_$n');
          expect(pv.success, isTrue, reason: '${pv.error}\n${pv.errorTail}');
          await _expectFrame('the preview', await WorkerHarness.imageToRgb24(pv.png!), video, n);
          await _expectFrame(
              'the before frame', await _beforeFrame(video, n, model.videoStartOffset, plan), video, n);
        });
      }

      test('a trim of $_trimStart..$_trimEnd is exactly those frames', () async {
        final out = await _encode(
            _job(video, 'trim_$stem', start: _trimStart, end: _trimEnd), 'vstart_trim');
        expect(await countFrames(out), _trimEnd - _trimStart + 1);
        for (final i in [0, 1, _trimEnd - _trimStart]) {
          await _expectFrame('output frame $i of the trim',
              await WorkerHarness.frameRgb24(out, i, label: 'trim'), video, _trimStart + i);
        }
      });

      test('an untrimmed encode is every picture once, from the first', () async {
        final out = await _encode(_job(video, 'full_$stem'), 'vstart_full');
        expect(await countFrames(out), _frames);
        for (final i in [0, 1, _frames - 1]) {
          await _expectFrame('output frame $i',
              await WorkerHarness.frameRgb24(out, i, label: 'full'), video, i);
        }
      });

      test('untrimmed, sound copied: in sync, the picture joining 1 s in', () async {
        final out = await _encode(
            _job(video, 'sync_copy_$stem', audio: AudioMode.passthrough), 'vstart_sync_copy');
        await expectInSync('copied', out, flashes: 2);
        final e = await events(out);
        expect(e.videoStart, closeTo(model.videoStartOffset, _syncTolerance),
            reason: 'the output keeps the source\'s layout');
      });

      test('untrimmed, "start the sound with the picture": in sync from 0', () async {
        final out = await _encode(
            _job(video, 'sync_start_$stem',
                audio: AudioMode.passthrough,
                audioPass: const AudioRestorationParameters(
                    enabled: true, startWithPicture: true)),
            'vstart_sync_start');
        await expectInSync('start with the picture', out, flashes: 2);
        final e = await events(out);
        expect(e.videoStart, closeTo(0, _syncTolerance));
        final a = await WorkerHarness.firstStream(out,
            selector: 'a:0', entries: ['duration', 'start_time']);
        // Matroska stores no audio duration, so read it from the last packet.
        final d = double.tryParse('${a?['duration']}');
        if (d != null) expect(d, closeTo(_frames / _fps, 0.1));
      });

      // Task #30: AVI cannot store a picture that starts after its sound
      // (avienc wrote null frames at 1/600 and held the first picture from
      // 0), so an untrimmed AVI starts both with the picture.
      for (final codec in [VideoCodec.ffv1, VideoCodec.huffyuv]) {
        test('untrimmed to AVI (${codec.value}): a constant-rate file, every picture once',
            () async {
          final out = await _encode(
              _job(video, 'avi_${codec.value}_$stem',
                  audio: AudioMode.passthrough, container: ContainerFormat.avi, codec: codec),
              'vstart_avi');
          final v = await aviVideo(out);
          expect(v.rate, '25/1');
          expect(v.stored, _frames, reason: 'stored frames, null frames included');
          expect(v.pts.take(2).toList(), [0.0, 0.04]);
          for (final i in [0, 1, _frames - 1]) {
            // HuffYUV stores 4:2:2, so its chroma is resampled (~1.2 levels).
            await _expectFrame('output frame $i of the AVI',
                await WorkerHarness.frameRgb24(out, i, label: 'avi'), video, i,
                maxDiff: codec == VideoCodec.huffyuv ? 2.0 : 1.0);
          }
        });
      }

      test('untrimmed to AVI: in sync from the first picture, copied and restored',
          () async {
        final half = await halfPacket(video);
        final copied = await _encode(
            _job(video, 'avi_sync_copy_$stem',
                audio: AudioMode.passthrough, container: ContainerFormat.avi),
            'vstart_avi_sync_copy');
        // PCM is re-written to the sample; a compressed copy is cut at the
        // packet nearest the first picture.
        await expectInSync('AVI, copied', copied, flashes: 2, tolerance: half + 0.001);
        for (final (label, job) in [
          ('restored', _job(video, 'avi_sync_restored_$stem',
              audio: AudioMode.passthrough,
              container: ContainerFormat.avi,
              audioPass: const AudioRestorationParameters(enabled: true, limiter: true))),
        ]) {
          final out = await _encode(job, 'vstart_avi_sync_$label');
          await expectInSync('AVI, $label', out, flashes: 2, tolerance: 0.001);
          final e = await events(out);
          expect(e.flashes.first, closeTo(1.0, 0.001), reason: 'frame 25 at 1 s');
          final a = await WorkerHarness.firstStream(out, selector: 'a:0', entries: ['duration']);
          final d = double.tryParse('${a?['duration']}');
          if (d != null) expect(d, closeTo(_frames / _fps, 0.05), reason: 'AVI, $label');
        }
      });

      // Task #38: AVI cannot mark a lossy encoder's start-up (priming).
      // ffmpeg shifted every stream by it, which wrote a null frame at the
      // head (AAC, MP3), and the player played the priming as sound: AAC
      // 18.6 ms early, MP3 16.9 ms early, AC-3 5.4 ms late. The encode now
      // reads the sound later by the measured priming and keeps every
      // stream's timestamps (docs/reports/2026-11-avi-convert-priming).
      // At the default quality (High): a mono AAC packet over the 768 bytes
      // avienc declares is covered by the task #41 group below.
      test('untrimmed to AVI with Convert (aac, libmp3lame, ac3): every picture once, in sync',
          () async {
        for (final ac in [AudioCodec.aac, AudioCodec.mp3, AudioCodec.ac3]) {
          final out = await _encode(
              _job(video, 'avi_convert_${ac.name}_$stem',
                  audio: AudioMode.convert,
                  audioCodec: ac,
                  container: ContainerFormat.avi),
              'vstart_avi_convert_${ac.name}');
          final v = await aviVideo(out);
          expect(v.stored, _frames, reason: '${ac.value}: stored frames, null frames included');
          expect(v.pts.take(2).toList(), [0.0, 0.04], reason: ac.value);
          await expectInSync('AVI, Convert ${ac.value}', out, flashes: 2, tolerance: 0.001);
          if (ac == AudioCodec.aac) await expectAacTimedOnce('AVI, Convert aac', out);
          final e = await events(out);
          expect(e.flashes.first, closeTo(1.0, 0.001), reason: '${ac.value}: frame 25 at 1 s');
        }
      });

      test('to AVI with Convert AAC, restored and trimmed: in sync', () async {
        for (final (label, job) in [
          ('restored', _job(video, 'avi_convert_restored_$stem',
              audio: AudioMode.convert,
              container: ContainerFormat.avi,
              audioPass: const AudioRestorationParameters(enabled: true, limiter: true))),
          ('trimmed', _job(video, 'avi_convert_trim_$stem',
              start: _trimStart,
              end: 89,
              audio: AudioMode.convert,
              container: ContainerFormat.avi)),
        ]) {
          final out = await _encode(job, 'vstart_avi_convert_$label');
          final pictures = label == 'trimmed' ? 89 - _trimStart + 1 : _frames;
          final v = await aviVideo(out);
          expect(v.stored, pictures, reason: '$label: stored frames, null frames included');
          expect(v.pts.take(2).toList(), [0.0, 0.04], reason: label);
          await expectInSync('AVI, Convert AAC, $label', out,
              flashes: label == 'trimmed' ? 1 : 2, tolerance: 0.001);
          await expectAacTimedOnce('AVI, Convert AAC, $label', out);
        }
      });

      test('trimmed $_trimStart..89, sound copied and restored: in sync', () async {
        final copied = await _encode(
            _job(video, 'sync_trim_copy_$stem',
                start: _trimStart, end: 89, audio: AudioMode.passthrough),
            'vstart_sync_trim_copy');
        await expectInSync('trimmed, copied', copied, flashes: 1);
        final restored = await _encode(
            _job(video, 'sync_trim_restored_$stem',
                start: _trimStart,
                end: 89,
                audio: AudioMode.passthrough,
                audioPass: const AudioRestorationParameters(enabled: true, limiter: true)),
            'vstart_sync_trim_restored');
        await expectInSync('trimmed, restored', restored, flashes: 1);
      });
    });
  }

  // The job carries no count, so it takes the source model's: 128, the grid's
  // slots (task #54). Two slots repeat the picture before them, where the
  // field-coded stream leaves a gap; `-count_frames`, which such a job used
  // before, counted the 126 decoded pictures. An app job has always sent 128.
  test('the DVB-T capture to AVI: its 128 slots at 25/1, the first at 0 (task #30)', () async {
    final video = _resource('pal-dvbt-fieldcoded-25i.ts');
    final job = VideoJob(
      id: const Uuid().v4(),
      inputPath: video,
      outputPath: '$_outDir/dvbt.avi',
      qtgmcParameters: _off,
      processingPipeline: const ProcessingPipeline(deinterlace: _off),
      encodingSettings: EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.avi,
        audioMode: AudioMode.passthrough,
      ),
      inputFrameRate: _fps,
    );
    final v = await aviVideo(await _encode(job, 'vstart_dvbt_avi'));
    expect(v.rate, '25/1');
    expect(v.stored, 128, reason: 'every slot once, no null frames');
    expect(v.pts.take(2).toList(), [0.0, 0.04]);
  });

  // Task #38's own repro: AAC in AVI stored 51 frames for 50.
  test('small_clip trimmed 0..49 to AVI with Convert AAC stores its 50 pictures', () async {
    final job = VideoJob(
      id: const Uuid().v4(),
      inputPath: _resource('small_clip.mp4'),
      outputPath: '$_outDir/small_clip_convert.avi',
      qtgmcParameters: _off,
      processingPipeline: const ProcessingPipeline(deinterlace: _off),
      encodingSettings: EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.avi,
        audioMode: AudioMode.convert,
        audioCodec: AudioCodec.aac,
      ),
      inputFrameRate: 2997 / 100,
      startFrame: 0,
      endFrame: 49,
      totalFrames: 50,
    );
    final out = await _encode(job, 'vstart_small_clip_convert');
    final v = await aviVideo(out);
    // Stereo at High: 96 kbps a channel, no packet over 1536, header untouched.
    expect(await expectAacTimedOnce('small_clip, Convert AAC', out), 0);
    expect(v.stored, 50, reason: 'stored frames, null frames included');
    expect(v.pts.first, 0.0);
  });

  test('a source whose streams start together gets no delay', () async {
    final video = _resource('seek_timebase_2997.mov');
    expect((await WorkerHarness.sourceModel(video)).videoStartOffset, 0);
    final job = VideoJob(
      id: const Uuid().v4(),
      inputPath: video,
      outputPath: '$_outDir/control.mkv',
      qtgmcParameters: _off,
      processingPipeline: const ProcessingPipeline(deinterlace: _off),
      encodingSettings: EncodingSettings(
        codec: VideoCodec.ffv1,
        container: ContainerFormat.mkv,
        audioMode: AudioMode.passthrough,
      ),
      inputFrameRate: 30000 / 1001,
    );
    final out = await _encode(job, 'vstart_control');
    final e = await events(out);
    expect(e.videoStart, 0);
  });

  // Task #41: avienc declares an AAC stream's block size as 768 bytes per
  // channel, and ffmpeg's AAC encoder writes bigger packets at 192 kbps per
  // channel and more (mono at High and Very High). A reader times a chunk as
  // ceil(size / block size) packets (ffmpeg, VLC, DirectShow; Media
  // Foundation split it in two), so the sound ran a packet later after each
  // one. The worker now raises the block size to the largest packet
  // (docs/reports/issue-41-aac-avi-block-align). Each case first checks that
  // oversized packets were written, or it would prove nothing.
  group('mono AAC over 768 bytes a packet into AVI (task #41)', () {
    final video = _resource('avi_aac_overshoot.mkv');
    const frames = 200;
    const trimStart = 30;

    VideoJob job(String name, AudioMode audio, AudioQuality quality, {bool trim = false}) =>
        VideoJob(
          id: const Uuid().v4(),
          inputPath: video,
          outputPath: '$_outDir/$name.avi',
          qtgmcParameters: _off,
          processingPipeline: const ProcessingPipeline(deinterlace: _off),
          encodingSettings: EncodingSettings(
            codec: VideoCodec.ffv1,
            container: ContainerFormat.avi,
            audioMode: audio,
            audioCodec: AudioCodec.aac,
            audioQuality: quality,
          ),
          inputWidth: 320,
          inputHeight: 240,
          inputPixelFormat: 'yuv420p',
          inputFrameRate: _fps,
          startFrame: trim ? trimStart : null,
          endFrame: trim ? frames - 1 : null,
          totalFrames: trim ? frames - trimStart : frames,
        );

    /// Encodes [j], checks the header and packet timing, and that the beeps
    /// stay 2 s apart: a packet timed as two moves every later beep 21.3 ms.
    /// With [inSync], each beep also lands on its white frame within 1 ms.
    Future<void> check(String what, VideoJob j,
        {required bool mustOvershoot, bool inSync = true}) async {
      final r = await WorkerHarness.runJob(j.toJson(), label: 'aac_overshoot');
      expect(r.success, isTrue, reason: r.error);
      final out = r.outputPath!;
      final over = await expectAacTimedOnce(what, out);
      if (mustOvershoot) {
        expect(over, greaterThan(0),
            reason: '$what: no packet over 768 bytes was written, so this case tests nothing');
        expect(r.logs.any((l) => l.contains("larger than AVI's declared block size")), isTrue,
            reason: '$what: the job log says the block size was raised');
      }
      final trimmed = j.startFrame != null;
      // The first beep is 0.8 s in or later; a noise burst at the very start
      // can pass the detector's level once it has been through the encoder.
      final beeps = (await events(out)).beeps.where((b) => b > 0.5).toList();
      expect(beeps, hasLength(trimmed ? 3 : 4), reason: '$what: beeps at $beeps');
      for (var i = 1; i < beeps.length; i++) {
        expect(beeps[i] - beeps[0], closeTo(2.0 * i, 0.001),
            reason: '$what: beep $i drifted (beeps at $beeps)');
      }
      if (inSync) await expectInSync(what, out, flashes: trimmed ? 3 : 4, tolerance: 0.001);
    }

    test('converted at High and Very High, untrimmed and trimmed: every beep on its flash',
        () async {
      for (final (quality, trim, must) in [
        (AudioQuality.high, false, false), // overshoots little or not at all
        (AudioQuality.high, true, true),
        (AudioQuality.veryHigh, false, true),
        (AudioQuality.veryHigh, true, true),
      ]) {
        final name = 'aac_overshoot_${quality.name}${trim ? '_trim' : ''}';
        await check('Convert AAC ${quality.name}${trim ? ', trimmed' : ''}',
            job(name, AudioMode.convert, quality, trim: trim), mustOvershoot: must);
      }
    });

    test('a 256 kbps mono AAC source copied into AVI: every beep on its flash', () async {
      await Directory(_outDir).create(recursive: true);
      final source = '$_outDir/aac_overshoot_source.mkv';
      final r = await Process.run(
        WorkerHarness.ffmpegPath,
        ['-v', 'error', '-y', '-i', video, '-map', '0', '-c:v', 'copy', '-c:a', 'aac',
         '-b:a', '256k', source],
        environment: WorkerHarness.ffmpegEnv,
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final copied = job('aac_overshoot_copy', AudioMode.passthrough, AudioQuality.high);
      // The source's AAC is primed: its head is cut at the packet nearest
      // the first picture (task #43), so the beeps land on their flashes too.
      await check('Passthrough of 256 kbps mono AAC',
          VideoJob.fromJson({...copied.toJson(), 'inputPath': source}),
          mustOvershoot: true);
    });
  });

  // Task #43: a source whose sound ffmpeg encoded (AAC, MP3 in MKV/MP4)
  // starts it with the encoder's priming at a negative timestamp. Copied
  // untrimmed into AVI, which cannot store one, ffmpeg shifted every stream
  // by it: a null frame at the head (101 stored frames for 100) and the
  // priming played as sound, AAC 18.6 ms and MP3 16.9 ms early. The copy is
  // now cut at the packet nearest the first picture
  // (docs/reports/2026-11-avi-copy-priming).
  group('a primed sound copied untrimmed into AVI (task #43)', () {
    for (final (file, tolerance) in [
      ('primed_aac.mkv', 0.001), // the next packet starts at 0
      ('primed_mp3.mp4', 0.0015), // the next packet starts 47 samples after 0
    ]) {
      test('$file: every picture once, from 0, in sync', () async {
        final video = _resource(file);
        final stem = p.basenameWithoutExtension(file);
        final first = await WorkerHarness.ffprobeJson([
          '-v', 'error', '-select_streams', 'a:0', '-read_intervals', '%+#1',
          '-show_entries', 'packet=pts_time', '-of', 'json', video,
        ]);
        expect(double.parse('${(first['packets'] as List).first['pts_time']}'), lessThan(-0.02),
            reason: '$file: the sound must start with a priming, or this case tests nothing');

        final r = await WorkerHarness.runJob(
            _job(video, 'avi_primed_copy_$stem',
                    audio: AudioMode.passthrough, container: ContainerFormat.avi)
                .toJson(),
            label: 'vstart_avi_primed_copy');
        expect(r.success, isTrue, reason: r.error);
        final out = r.outputPath!;
        final v = await aviVideo(out);
        expect(v.stored, _frames, reason: '$file: stored frames, null frames included');
        expect(v.pts.take(2).toList(), [0.0, 0.04], reason: file);
        await expectInSync('AVI, copied $file', out, flashes: 2, tolerance: tolerance);
        final e = await events(out);
        expect(e.flashes.first, closeTo(1.0, 0.001), reason: '$file: frame 25 at 1 s');
        expect(r.logs.any((l) => l.contains('copied from the packet nearest the first picture')), isTrue,
            reason: '$file: the job log says the head was cut');

        // Trimmed, the seeked cut of task #24: unchanged, and in sync.
        final trimmed = await _encode(
            _job(video, 'avi_primed_copy_trim_$stem',
                start: _trimStart,
                end: 89,
                audio: AudioMode.passthrough,
                container: ContainerFormat.avi),
            'vstart_avi_primed_copy_trim');
        final tv = await aviVideo(trimmed);
        expect(tv.stored, 60, reason: '$file trimmed: stored frames');
        await expectInSync('AVI, copied $file, trimmed', trimmed,
            flashes: 1, tolerance: await halfPacket(video) + 0.001);

        // MKV stores where a stream starts: nothing to cut, in sync.
        final mkv = await _encode(
            _job(video, 'mkv_primed_copy_$stem', audio: AudioMode.passthrough),
            'vstart_mkv_primed_copy');
        await expectInSync('MKV, copied $file', mkv, flashes: 2, tolerance: 0.001);
      });
    }

    // small_clip's AAC starts 5.1 ms before 0 (a partial priming): the
    // nearest packet is the one it starts with, so its timing is as before,
    // and no null frame.
    test('small_clip.mp4 copied untrimmed into AVI: its 3151 pictures, the first at 0', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: _resource('small_clip.mp4'),
        outputPath: '$_outDir/small_clip_copy.avi',
        qtgmcParameters: _off,
        processingPipeline: const ProcessingPipeline(deinterlace: _off),
        encodingSettings: EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
          audioMode: AudioMode.passthrough,
        ),
        inputFrameRate: 2997 / 100,
      );
      final out = await _encode(job, 'vstart_small_clip_copy');
      final v = await aviVideo(out);
      expect(v.stored, 3151, reason: 'stored frames, null frames included');
      expect(v.pts.first, 0.0);
      // The count is the model's (task #54), which no longer counts the edit
      // list's 3 discarded packets: the output ends on the source's last
      // picture, not on 3 copies of it.
      expect(await _lastLumaHashes(out, 4),
          await _lastLumaHashes(_resource('small_clip.mp4'), 4),
          reason: 'the last pictures are the source\'s last pictures');
    });
  });
}
