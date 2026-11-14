// Integration test: audio restoration's arguments, from the worker itself
// (`--audio-plan`: the probes run on a real source, nothing is rendered).
// Script-level, like integration_filter_parameters_test — runs in the
// per-push gate. The audio itself is measured in
// integration_audio_restoration_test.dart (heavy).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/services/manifest_addon.dart';
import 'dart:io';

import 'support/audio_fixtures.dart';
import 'support/worker_harness.dart';

/// The `-af` argument of an ffmpeg argument list, asserting there is one.
String af(List<dynamic> args) {
  final idx = [for (var i = 0; i < args.length; i++) if (args[i] == '-af') i];
  expect(idx, hasLength(1), reason: 'one -af per ffmpeg run: $args');
  return args[idx.single + 1] as String;
}

void main() {
  late String deadRightHum;
  late String twoStreams;

  setUpAll(() async {
    await WorkerHarness.ensureReady();
    // Left: a 1 kHz tone over 50 Hz hum. Right: nothing.
    deadRightHum = await AudioFixtures.source('plan_dead_right_hum',
        filterComplex: 'sine=f=1000:r=48000:d=6[t];sine=f=50:r=48000:d=6[h];'
            "[t][h]amix=inputs=2:weights='1 0.3':normalize=0,"
            'pan=stereo|c0=c0|c1=0*c0[a]');
    // Two audio streams: mono 48 kHz, then stereo 44.1 kHz.
    twoStreams = await AudioFixtures.source('plan_two_streams',
        audioStreams: 2,
        filterComplex: 'sine=f=440:r=48000:d=6[a0];'
            'sine=f=660:r=44100:d=6,pan=stereo|c0=c0|c1=c0[a1]');
  });

  test('a pass with nothing chosen plans nothing', () async {
    final plan = await AudioFixtures.plan(AudioFixtures.job(deadRightHum, {}));
    expect(plan['active'], isFalse);
  });

  test('automatic channel fix and hum removal follow the source', () async {
    final plan = await AudioFixtures.plan(AudioFixtures.job(deadRightHum, {
      'channelFix': 'auto',
      'humRemoval': true,
      'humFrequency': 'auto',
      'declick': true,
      'declickThreshold': 4,
      'rumbleFilter': true,
      'rumbleCutoffHz': 60,
      'declip': true,
      'denoise': true,
      'denoiseStrength': 20,
      'limiter': true,
      'limiterCeilingDb': -3,
    }));
    expect(plan['active'], isTrue);
    // afftdn's floor is measured from the source (here the tone itself: it
    // has no pauses, so the clamp's -30 dB).
    final chain = af(plan['restore'] as List)
        .replaceAll(RegExp(r'afftdn=nr=20:nf=-\d+'), 'afftdn=nr=20:nf=<measured>');
    expect(af(plan['restore'] as List), contains('afftdn=nr=20:nf=-30'));
    expect(chain.split(','), [
      'aresample=first_pts=0',
      'pan=stereo|c0=c0|c1=c0',
      'adeclip',
      'adeclick=t=4',
      'highpass=f=60:poles=2',
      'bandreject=f=50:width_type=q:w=8',
      'bandreject=f=100:width_type=q:w=8',
      'bandreject=f=150:width_type=q:w=8',
      'afftdn=nr=20:nf=<measured>',
      'atrim=start_sample=1200',
      'asetpts=PTS-STARTPTS',
      'alimiter=limit=0.7079:level=0:latency=1',
      // 6 s at 48 kHz: the picture's length.
      'apad=whole_len=288000',
      'atrim=end_sample=288000',
    ]);
    expect(plan['finish'], isNull, reason: 'one ffmpeg run writes the track');
    expect(plan['notes'], contains(contains('right channel is silent')));
    expect(plan['notes'], contains(contains('50 Hz')));
    expect(plan['notes'], contains(contains('noise floor')));
  });

  test('a negative offset reads later, a positive one adds silence', () async {
    final early = await AudioFixtures.plan(AudioFixtures.job(deadRightHum, {'offsetMs': -400}));
    final restore = (early['restore'] as List).cast<String>();
    expect(restore.indexOf('-ss'), lessThan(restore.indexOf('-i')));
    expect(restore[restore.indexOf('-ss') + 1], '0.400000');
    expect(af(restore), isNot(contains('adelay')));

    final late = await AudioFixtures.plan(AudioFixtures.job(deadRightHum, {'offsetMs': 400}));
    final restoreLate = (late['restore'] as List).cast<String>();
    expect(restoreLate, isNot(contains('-ss')));
    expect(af(restoreLate), contains('adelay=delays=19200S:all=1'));

    // From a trim's in-point at 2 s, a 400 ms delay reads from 1.6 s instead.
    final trimmed = await AudioFixtures.plan(AudioFixtures.job(deadRightHum, {'offsetMs': 400},
        extra: {'startFrame': 50, 'endFrame': 124, 'totalFrames': 75}));
    final restoreTrimmed = (trimmed['restore'] as List).cast<String>();
    expect(restoreTrimmed[restoreTrimmed.indexOf('-ss') + 1], '1.600000');
    expect(af(restoreTrimmed), endsWith('apad=whole_len=144000,atrim=end_sample=144000'));
  });

  test('a video that starts after its sound: kept, or dropped with "start with the picture"',
      () async {
    // late_video.mkv: 100 frames at 25 fps, the video starting 1 s after the
    // sound (Tests/TestResources/generate_video_start_offset.sh).
    final late = p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'late_video.mkv');
    const size = {'inputWidth': 320, 'inputHeight': 240, 'totalFrames': 100};

    // By default the output keeps the sound before the picture, which the
    // encoder delays by as much: the rendered track is that much longer.
    final kept = await AudioFixtures.plan(
        AudioFixtures.job(late, {'limiter': true}, extra: size));
    expect(kept['videoStartOffset'], closeTo(1.0, 1e-6));
    expect(kept['videoDelay'], closeTo(1.0, 1e-6));
    expect(kept['readStart'], 0);
    expect(kept['outSamples'], 5 * 48000);

    // Dropping it reads from the first picture, exactly the picture's length.
    final dropped = await AudioFixtures.plan(
        AudioFixtures.job(late, {'startWithPicture': true}, extra: size));
    expect(dropped['active'], isTrue);
    expect(dropped['videoDelay'], 0);
    expect(dropped['readStart'], closeTo(1.0, 1e-6));
    expect(dropped['outSamples'], 4 * 48000);
    expect((dropped['notes'] as List).join(' '), contains('1.000 s'));

    // A trim reads from the in-point's picture, the gap included.
    final trimmed = await AudioFixtures.plan(AudioFixtures.job(late, {'limiter': true},
        extra: {...size, 'startFrame': 30, 'endFrame': 59, 'totalFrames': 30}));
    expect(trimmed['videoDelay'], 0);
    expect(trimmed['readStart'], closeTo(1.0 + 30 / 25, 1e-6));

    // With nothing to drop, the step alone leaves the sound to the encoder.
    final none = await AudioFixtures.plan(
        AudioFixtures.job(deadRightHum, {'startWithPicture': true}));
    expect(none['active'], isFalse);
  });

  test('the length follows the encoded picture, not the source frame count', () async {
    // Double-rate deinterlacing doubles the frames and the rate: same length.
    final plan = await AudioFixtures.plan(AudioFixtures.job(deadRightHum, {'limiter': true},
        pipeline: {
          'deinterlace': {'enabled': true, 'method': 'bwdif', 'fpsDivisor': 1},
        },
        extra: {'totalFrames': 150}));
    expect(plan['outSamples'], 288000);
  });

  test('loudness and DeepFilterNet split the work into runs', () async {
    final plan = await AudioFixtures.plan(AudioFixtures.job(twoStreams, {
      'streamIndex': 1,
      'denoise': true,
      'loudnessNormalize': true,
      'loudnessTarget': -23,
      'limiter': true,
    }));
    expect(plan['sourceStreams'], 2);
    expect(plan['stream'], 1);
    final restore = (plan['restore'] as List).cast<String>();
    expect(restore[restore.indexOf('-map') + 1], '0:a:1');
    // 44.1 kHz: afftdn's 25 ms is 1103 samples, and the track keeps the rate.
    expect(af(restore), contains('atrim=start_sample=1103'));
    expect(af(restore), endsWith('apad=whole_len=264600,atrim=end_sample=264600'));
    expect(af(plan['measure'] as List), 'loudnorm=I=-23:TP=-1.5:LRA=11:print_format=json');
    expect(af(plan['finish'] as List),
        'aresample=44100,alimiter=limit=0.8913:level=0:latency=1,'
        'apad=whole_len=264600,atrim=end_sample=264600');
    expect(plan['outRate'], 44100);
  });

  test('DeepFilterNet needs its add-on, and runs at 48 kHz with -D', () async {
    final job = AudioFixtures.job(twoStreams, {'streamIndex': 1, 'deepFilter': true, 'deepFilterAttenuation': 24});
    final plan = await AudioFixtures.plan(job);
    final manifest = AddonManifest.loadDirectory(
            Directory(p.join(WorkerHarness.repoRoot, 'app', 'assets', 'addons')))
        .firstWhere((m) => m.id == 'deepfilternet');
    final installed =
        ManifestAddonInstaller(manifest, WorkerHarness.platform).isInstalled(WorkerHarness.addonsDirectory);
    if (!installed) {
      expect(plan['error'], allOf(contains('DeepFilterNet'), contains('Settings → Add-ons')));
      return;
    }
    expect(plan['deepFilter'], ['-D', '-a', '24', '-o', 'dfn', 'restore.wav']);
    expect(plan['outRate'], 48000);
    expect(af(plan['finish'] as List), 'aresample=48000,apad=whole_len=288000,atrim=end_sample=288000');
  });
}
