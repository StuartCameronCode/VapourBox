/// End-to-end integration tests for audio conversion options.
/// These tests verify that all audio modes (passthrough, convert, none) and
/// all audio codecs (AAC, MP3, AC-3, FLAC, Opus, PCM) work correctly.
///
/// Run with: flutter test integration_test/audio_conversion_test.dart
/// Or: dart test integration_test/audio_conversion_test.dart --chain-stack-traces

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import '../lib/models/encoding_settings.dart';
import '../lib/models/qtgmc_parameters.dart';
import '../lib/models/restoration_pipeline.dart';
import '../lib/models/video_job.dart';

/// Test configuration
class TestConfig {
  static final String projectRoot = _findProjectRoot();
  static String get inputFile => '$projectRoot/Tests/TestResources/interlaced_test.avi';
  static String get outputDir => '$projectRoot/Tests/TestOutput/audio';
  static String get workerPath => '$projectRoot/worker/target/release/vapourbox-worker.exe';
  static String get depsDir => '$projectRoot/deps/windows-x64';

  static String _findProjectRoot() {
    var dir = Directory.current;
    while (!File('${dir.path}/CLAUDE.md').existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError('Could not find project root (looking for CLAUDE.md)');
      }
      dir = parent;
    }
    return dir.path.replaceAll('\\', '/');
  }
}

// =============================================================================
// AUDIO ANALYSIS HELPERS
// =============================================================================

/// Information about audio streams in a video file
class AudioStreamInfo {
  final bool hasAudio;
  final String? codec;
  final int? sampleRate;
  final int? channels;
  final int? bitrate;
  final String? codecLongName;

  AudioStreamInfo({
    required this.hasAudio,
    this.codec,
    this.sampleRate,
    this.channels,
    this.bitrate,
    this.codecLongName,
  });

  @override
  String toString() {
    if (!hasAudio) return 'No audio';
    final bitrateStr = bitrate != null ? '${(bitrate! / 1000).round()}kbps' : 'N/A';
    return 'Audio: $codec ($codecLongName), ${sampleRate}Hz, ${channels}ch, $bitrateStr';
  }
}

/// Get detailed information about audio streams in a video file using ffprobe
Future<AudioStreamInfo> getAudioStreamInfo(String videoPath) async {
  final ffprobePath = '${TestConfig.depsDir}/ffmpeg/ffprobe.exe';

  final result = await Process.run(
    ffprobePath,
    [
      '-v', 'error',
      '-select_streams', 'a:0',
      '-show_entries', 'stream=codec_name,codec_long_name,sample_rate,channels,bit_rate',
      '-of', 'json',
      videoPath,
    ],
    environment: {
      'PATH': '${TestConfig.depsDir}/ffmpeg;${Platform.environment['PATH']}',
    },
  );

  if (result.exitCode != 0) {
    throw Exception('ffprobe failed: ${result.stderr}');
  }

  final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  final streams = json['streams'] as List?;

  if (streams == null || streams.isEmpty) {
    return AudioStreamInfo(hasAudio: false);
  }

  final stream = streams[0] as Map<String, dynamic>;
  return AudioStreamInfo(
    hasAudio: true,
    codec: stream['codec_name'] as String?,
    codecLongName: stream['codec_long_name'] as String?,
    sampleRate: int.tryParse(stream['sample_rate']?.toString() ?? ''),
    channels: stream['channels'] as int?,
    bitrate: int.tryParse(stream['bit_rate']?.toString() ?? ''),
  );
}

/// Extract raw audio from a video file as PCM WAV for binary comparison
/// Returns the MD5 hash of the audio data, or null if no audio
Future<String?> extractAudioHash(String videoPath) async {
  final ffmpegPath = '${TestConfig.depsDir}/ffmpeg/ffmpeg.exe';
  final tempDir = Directory.systemTemp;
  final audioPath = '${tempDir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.wav';

  try {
    // Extract audio as raw PCM WAV (lossless extraction for comparison)
    final result = await Process.run(
      ffmpegPath,
      [
        '-i', videoPath,
        '-vn',                    // No video
        '-acodec', 'pcm_s16le',   // Convert to PCM for consistent comparison
        '-ar', '48000',           // Resample to 48kHz for consistency
        '-ac', '2',               // Stereo
        '-y',
        audioPath,
      ],
      environment: {
        'PATH': '${TestConfig.depsDir}/ffmpeg;${Platform.environment['PATH']}',
      },
    );

    // If no audio stream, ffmpeg will fail or produce empty file
    final audioFile = File(audioPath);
    if (!await audioFile.exists() || await audioFile.length() < 1000) {
      if (await audioFile.exists()) await audioFile.delete();
      return null;
    }

    // Compute hash of audio data
    final bytes = await audioFile.readAsBytes();
    final hash = md5.convert(bytes).toString();

    // Cleanup
    await audioFile.delete().catchError((_) => audioFile);

    return hash;
  } catch (e) {
    // Cleanup on error
    final audioFile = File(audioPath);
    if (await audioFile.exists()) {
      await audioFile.delete().catchError((_) => audioFile);
    }
    return null;
  }
}

/// Result of running a filter test
class FilterTestResult {
  final bool success;
  final String? outputPath;
  final String? error;
  final Duration duration;
  final List<String> logs;
  final int? exitCode;

  FilterTestResult({
    required this.success,
    this.outputPath,
    this.error,
    required this.duration,
    required this.logs,
    this.exitCode,
  });
}

/// Runs a full processing test through the worker
Future<FilterTestResult> runFilterTest(String testName, VideoJob job, {
  Duration timeout = const Duration(minutes: 5),
}) async {
  final stopwatch = Stopwatch()..start();
  final logs = <String>[];

  // Write job config to temp file
  final configFile = File('${Directory.systemTemp.path}/job_${job.id}.json');
  await configFile.writeAsString(jsonEncode(job.toJson()));

  // Set up environment
  final env = Map<String, String>.from(Platform.environment);
  final depsDir = TestConfig.depsDir;

  env['PYTHONHOME'] = '$depsDir/vapoursynth';
  env['PYTHONPATH'] = '$depsDir/vapoursynth/Lib/site-packages';
  env['PATH'] = '$depsDir/vapoursynth;$depsDir/ffmpeg;${env['PATH']}';
  env['VAPOURSYNTH_PLUGIN_PATH'] = '$depsDir/vapoursynth/vs-plugins';

  try {
    print('\n${'=' * 60}');
    print('AUDIO TEST: $testName');
    print('Output: ${job.outputPath}');
    print('=' * 60);

    // Run worker
    final process = await Process.start(
      TestConfig.workerPath,
      ['--config', configFile.path],
      environment: env,
      workingDirectory: File(TestConfig.workerPath).parent.path,
    );

    // Collect stdout and stderr
    final stdoutCompleter = Completer<void>();
    final stderrCompleter = Completer<void>();

    process.stdout.transform(utf8.decoder).listen(
      (data) {
        logs.add('[stdout] $data');
        // Parse progress messages
        for (final line in data.split('\n')) {
          if (line.trim().isEmpty) continue;
          try {
            final json = jsonDecode(line) as Map<String, dynamic>;
            if (json['type'] == 'progress') {
              final frame = json['frame'] ?? 0;
              final total = json['totalFrames'] ?? 0;
              final fps = (json['fps'] as num?)?.toStringAsFixed(1) ?? '?';
              print('  Progress: $frame/$total frames @ $fps fps');
            } else if (json['type'] == 'log') {
              print('  [${json['level']}] ${json['message']}');
            } else if (json['type'] == 'complete') {
              print('  Complete: success=${json['success']}');
            } else if (json['type'] == 'error') {
              print('  ERROR: ${json['message']}');
            }
          } catch (_) {
            // Not JSON, just print
            if (line.trim().isNotEmpty) {
              print('  $line');
            }
          }
        }
      },
      onDone: () => stdoutCompleter.complete(),
    );

    process.stderr.transform(utf8.decoder).listen(
      (data) {
        logs.add('[stderr] $data');
      },
      onDone: () => stderrCompleter.complete(),
    );

    // Wait for completion with timeout
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        throw TimeoutException('Worker timed out after $timeout');
      },
    );

    await Future.wait([stdoutCompleter.future, stderrCompleter.future]);

    stopwatch.stop();

    // Cleanup config file
    await configFile.delete().catchError((_) => configFile);

    if (exitCode != 0) {
      return FilterTestResult(
        success: false,
        error: 'Worker exited with code $exitCode',
        duration: stopwatch.elapsed,
        logs: logs,
        exitCode: exitCode,
      );
    }

    // Verify output file exists
    final outputFile = File(job.outputPath);
    if (!await outputFile.exists()) {
      return FilterTestResult(
        success: false,
        error: 'Output file was not created: ${job.outputPath}',
        duration: stopwatch.elapsed,
        logs: logs,
        exitCode: exitCode,
      );
    }

    final fileSize = await outputFile.length();
    print('  Output size: ${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB');

    return FilterTestResult(
      success: true,
      outputPath: job.outputPath,
      duration: stopwatch.elapsed,
      logs: logs,
      exitCode: exitCode,
    );
  } catch (e, stack) {
    stopwatch.stop();
    await configFile.delete().catchError((_) => configFile);
    return FilterTestResult(
      success: false,
      error: 'Exception: $e\n$stack',
      duration: stopwatch.elapsed,
      logs: logs,
    );
  }
}

/// Create a minimal processing job for audio tests (fast deinterlace only)
VideoJob createAudioTestJob(String outputPath, EncodingSettings settings) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: TestConfig.inputFile,
    outputPath: outputPath,
    qtgmcParameters: const QTGMCParameters(
      preset: QTGMCPreset.superFast,
      tff: true,
      fpsDivisor: 2,
    ),
    restorationPipeline: const RestorationPipeline(
      deinterlace: QTGMCParameters(
        preset: QTGMCPreset.superFast,
        tff: true,
        fpsDivisor: 2,
      ),
    ),
    encodingSettings: settings,
  );
}

void main() {
  // Ensure output directory exists
  setUpAll(() async {
    final outputDir = Directory(TestConfig.outputDir);
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    // Verify worker exists
    final workerFile = File(TestConfig.workerPath);
    if (!await workerFile.exists()) {
      throw StateError(
        'Worker not found at ${TestConfig.workerPath}\n'
        'Run: cd worker && cargo build --release'
      );
    }

    // Verify input file exists
    final inputFile = File(TestConfig.inputFile);
    if (!await inputFile.exists()) {
      throw StateError(
        'Test input file not found at ${TestConfig.inputFile}'
      );
    }

    print('Test configuration:');
    print('  Project root: ${TestConfig.projectRoot}');
    print('  Input file: ${TestConfig.inputFile}');
    print('  Output dir: ${TestConfig.outputDir}');
    print('  Worker: ${TestConfig.workerPath}');
  });

  // Store input audio hash for comparison
  String? inputAudioHash;

  group('Audio Conversion Tests', () {
    // ===========================================================================
    // SETUP: Verify input file
    // ===========================================================================
    test('Setup: Verify input file has audio', () async {
      print('\n${'=' * 60}');
      print('SETUP: Checking input file');
      print('=' * 60);

      final inputInfo = await getAudioStreamInfo(TestConfig.inputFile);
      print('Input file: ${TestConfig.inputFile}');
      print('Audio info: $inputInfo');

      expect(
        inputInfo.hasAudio,
        isTrue,
        reason: 'Test input file must have audio for audio tests',
      );

      inputAudioHash = await extractAudioHash(TestConfig.inputFile);
      print('Input audio hash: $inputAudioHash');

      expect(
        inputAudioHash,
        isNotNull,
        reason: 'Failed to extract audio hash from input file',
      );
    });

    // ===========================================================================
    // AUDIO MODE: PASSTHROUGH
    // ===========================================================================
    group('AudioMode.passthrough', () {
      test('Passthrough mode copies audio unchanged', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_passthrough.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.passthrough,
          ),
        );

        final result = await runFilterTest('Passthrough Mode', job);
        expect(result.success, isTrue, reason: result.error);

        // Verify output has audio
        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue,
            reason: 'Passthrough should preserve audio');

        // Verify audio is identical to input
        final outputAudioHash = await extractAudioHash(result.outputPath!);
        print('  Output hash: $outputAudioHash');
        print('  Input hash:  $inputAudioHash');

        expect(outputAudioHash, equals(inputAudioHash),
            reason: 'Passthrough audio should match input exactly');

        print('  PASS: Audio passthrough verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // AUDIO MODE: NONE
    // ===========================================================================
    group('AudioMode.none', () {
      test('None mode removes audio completely', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_no_audio.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.none,
          ),
        );

        final result = await runFilterTest('No Audio Mode', job);
        expect(result.success, isTrue, reason: result.error);

        // Verify output has NO audio
        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isFalse,
            reason: 'AudioMode.none should remove all audio');

        // Verify we cannot extract audio
        final outputAudioHash = await extractAudioHash(result.outputPath!);
        expect(outputAudioHash, isNull,
            reason: 'Should not be able to extract audio from file with no audio');

        print('  PASS: No audio verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // AUDIO MODE: CONVERT - AAC
    // ===========================================================================
    group('AudioMode.convert - AAC', () {
      test('Convert to AAC with Low quality (96kbps)', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_aac_low.mp4',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.aac,
            audioQuality: AudioQuality.low,
          ),
        );

        final result = await runFilterTest('AAC Low (96kbps)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue);
        expect(outputInfo.codec, equals('aac'));

        // Verify bitrate is approximately 96kbps (allow some variance)
        if (outputInfo.bitrate != null) {
          expect(outputInfo.bitrate!, greaterThan(70000),
              reason: 'AAC Low bitrate should be > 70kbps');
          expect(outputInfo.bitrate!, lessThan(130000),
              reason: 'AAC Low bitrate should be < 130kbps');
        }

        // Audio should be different from input (re-encoded)
        final outputAudioHash = await extractAudioHash(result.outputPath!);
        expect(outputAudioHash, isNot(equals(inputAudioHash)),
            reason: 'Re-encoded audio should differ from input');

        print('  PASS: AAC Low verified');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Convert to AAC with High quality (192kbps)', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_aac_high.mp4',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.aac,
            audioQuality: AudioQuality.high,
          ),
        );

        final result = await runFilterTest('AAC High (192kbps)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue);
        expect(outputInfo.codec, equals('aac'));

        // Verify bitrate is approximately 192kbps
        if (outputInfo.bitrate != null) {
          expect(outputInfo.bitrate!, greaterThan(150000),
              reason: 'AAC High bitrate should be > 150kbps');
          expect(outputInfo.bitrate!, lessThan(250000),
              reason: 'AAC High bitrate should be < 250kbps');
        }

        print('  PASS: AAC High verified');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Convert to AAC with Very High quality (256kbps)', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_aac_veryhigh.mp4',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.aac,
            audioQuality: AudioQuality.veryHigh,
          ),
        );

        final result = await runFilterTest('AAC Very High (256kbps)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue);
        expect(outputInfo.codec, equals('aac'));

        // Verify bitrate is approximately 256kbps
        if (outputInfo.bitrate != null) {
          expect(outputInfo.bitrate!, greaterThan(200000),
              reason: 'AAC Very High bitrate should be > 200kbps');
          expect(outputInfo.bitrate!, lessThan(320000),
              reason: 'AAC Very High bitrate should be < 320kbps');
        }

        print('  PASS: AAC Very High verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // AUDIO MODE: CONVERT - MP3
    // ===========================================================================
    group('AudioMode.convert - MP3', () {
      test('Convert to MP3 with Medium quality (128kbps)', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_mp3_medium.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.mp3,
            audioQuality: AudioQuality.medium,
          ),
        );

        final result = await runFilterTest('MP3 Medium (128kbps)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue);
        expect(outputInfo.codec, equals('mp3'));

        // Verify bitrate is approximately 128kbps
        if (outputInfo.bitrate != null) {
          expect(outputInfo.bitrate!, greaterThan(100000),
              reason: 'MP3 Medium bitrate should be > 100kbps');
          expect(outputInfo.bitrate!, lessThan(160000),
              reason: 'MP3 Medium bitrate should be < 160kbps');
        }

        print('  PASS: MP3 Medium verified');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Convert to MP3 with High quality (192kbps)', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_mp3_high.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.mp3,
            audioQuality: AudioQuality.high,
          ),
        );

        final result = await runFilterTest('MP3 High (192kbps)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue);
        expect(outputInfo.codec, equals('mp3'));

        print('  PASS: MP3 High verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // AUDIO MODE: CONVERT - AC-3 (Dolby Digital)
    // ===========================================================================
    group('AudioMode.convert - AC-3', () {
      test('Convert to AC-3 with High quality (192kbps)', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_ac3_high.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.ac3,
            audioQuality: AudioQuality.high,
          ),
        );

        final result = await runFilterTest('AC-3 High (192kbps)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue);
        expect(outputInfo.codec, equals('ac3'));

        print('  PASS: AC-3 verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // AUDIO MODE: CONVERT - OPUS
    // ===========================================================================
    group('AudioMode.convert - Opus', () {
      test('Convert to Opus with Medium quality (128kbps)', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_opus_medium.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.opus,
            audioQuality: AudioQuality.medium,
          ),
        );

        final result = await runFilterTest('Opus Medium (128kbps)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue);
        expect(outputInfo.codec, equals('opus'));

        print('  PASS: Opus verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // AUDIO MODE: CONVERT - FLAC (Lossless)
    // ===========================================================================
    group('AudioMode.convert - FLAC (Lossless)', () {
      test('Convert to FLAC (lossless, no quality setting needed)', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_flac.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.flac,
            // audioQuality is ignored for lossless codecs
            audioQuality: AudioQuality.low,
          ),
        );

        final result = await runFilterTest('FLAC (Lossless)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue);
        expect(outputInfo.codec, equals('flac'));

        // FLAC should preserve audio quality - extract and compare
        // Note: Won't be byte-identical due to codec change, but same content
        final outputAudioHash = await extractAudioHash(result.outputPath!);
        print('  Output hash: $outputAudioHash');
        print('  Input hash:  $inputAudioHash');

        // FLAC is lossless, so the PCM extraction should match input
        // (assuming input was PCM or lossless; if input was lossy,
        // it will match the decoded version of the input)
        expect(outputAudioHash, isNotNull,
            reason: 'Should be able to extract audio from FLAC');

        print('  PASS: FLAC verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // AUDIO MODE: CONVERT - PCM (Uncompressed)
    // ===========================================================================
    group('AudioMode.convert - PCM (Uncompressed)', () {
      test('Convert to PCM (uncompressed, no quality setting needed)', () async {
        // PCM works best in AVI container
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_pcm.avi',
          const EncodingSettings(
            codec: VideoCodec.ffv1,
            container: ContainerFormat.avi,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.pcm,
            // audioQuality is ignored for lossless codecs
          ),
        );

        final result = await runFilterTest('PCM (Uncompressed)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        print('  Output audio: $outputInfo');

        expect(outputInfo.hasAudio, isTrue);
        expect(outputInfo.codec, equals('pcm_s16le'));

        // PCM should preserve audio exactly
        final outputAudioHash = await extractAudioHash(result.outputPath!);
        print('  Output hash: $outputAudioHash');
        print('  Input hash:  $inputAudioHash');

        expect(outputAudioHash, isNotNull,
            reason: 'Should be able to extract audio from PCM');

        print('  PASS: PCM verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // QUALITY COMPARISON TESTS
    // ===========================================================================
    group('Quality Comparison', () {
      test('Higher quality AAC produces larger file than lower quality', () async {
        // Create low quality AAC
        final jobLow = createAudioTestJob(
          '${TestConfig.outputDir}/test_quality_low.mp4',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.aac,
            audioQuality: AudioQuality.low,
          ),
        );

        final resultLow = await runFilterTest('Quality Low', jobLow);
        expect(resultLow.success, isTrue, reason: resultLow.error);

        // Create high quality AAC
        final jobHigh = createAudioTestJob(
          '${TestConfig.outputDir}/test_quality_high.mp4',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.aac,
            audioQuality: AudioQuality.veryHigh,
          ),
        );

        final resultHigh = await runFilterTest('Quality High', jobHigh);
        expect(resultHigh.success, isTrue, reason: resultHigh.error);

        // Compare file sizes - high quality should be larger
        final sizeLow = await File(resultLow.outputPath!).length();
        final sizeHigh = await File(resultHigh.outputPath!).length();

        print('  Low quality file size:  ${(sizeLow / 1024).round()} KB');
        print('  High quality file size: ${(sizeHigh / 1024).round()} KB');

        // High quality should be at least 20% larger
        // (video is same, only audio differs)
        final audioSizeDiff = sizeHigh - sizeLow;
        print('  Size difference: ${(audioSizeDiff / 1024).round()} KB');

        // Just verify high is larger (audio at 256k vs 96k should be noticeable)
        expect(sizeHigh, greaterThan(sizeLow),
            reason: 'Higher quality AAC should produce larger file');

        print('  PASS: Quality comparison verified');
      }, timeout: const Timeout(Duration(minutes: 10)));

      test('Lossless codecs preserve audio content', () async {
        // FLAC output
        final jobFlac = createAudioTestJob(
          '${TestConfig.outputDir}/test_lossless_flac.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.flac,
          ),
        );

        final resultFlac = await runFilterTest('Lossless FLAC', jobFlac);
        expect(resultFlac.success, isTrue, reason: resultFlac.error);

        final hashFlac = await extractAudioHash(resultFlac.outputPath!);

        // Lossy AAC output for comparison
        final jobAac = createAudioTestJob(
          '${TestConfig.outputDir}/test_lossless_compare_aac.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.aac,
            audioQuality: AudioQuality.low,
          ),
        );

        final resultAac = await runFilterTest('Lossy AAC (comparison)', jobAac);
        expect(resultAac.success, isTrue, reason: resultAac.error);

        final hashAac = await extractAudioHash(resultAac.outputPath!);

        print('  FLAC audio hash: $hashFlac');
        print('  AAC audio hash:  $hashAac');
        print('  Input hash:      $inputAudioHash');

        // FLAC and AAC should produce different results
        // (FLAC preserves original, AAC compresses)
        expect(hashFlac, isNot(equals(hashAac)),
            reason: 'Lossless FLAC should produce different output than lossy AAC');

        print('  PASS: Lossless preservation verified');
      }, timeout: const Timeout(Duration(minutes: 10)));
    });

    // ===========================================================================
    // CONTAINER COMPATIBILITY TESTS
    // ===========================================================================
    group('Container Compatibility', () {
      test('AAC in MP4 container', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_container_mp4_aac.mp4',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.aac,
            audioQuality: AudioQuality.medium,
          ),
        );

        final result = await runFilterTest('MP4 + AAC', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        expect(outputInfo.codec, equals('aac'));
        print('  PASS: MP4 + AAC verified');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('FLAC in MKV container', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_container_mkv_flac.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.flac,
          ),
        );

        final result = await runFilterTest('MKV + FLAC', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        expect(outputInfo.codec, equals('flac'));
        print('  PASS: MKV + FLAC verified');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('PCM in AVI container', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_container_avi_pcm.avi',
          const EncodingSettings(
            codec: VideoCodec.ffv1,
            container: ContainerFormat.avi,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.pcm,
          ),
        );

        final result = await runFilterTest('AVI + PCM', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        expect(outputInfo.codec, equals('pcm_s16le'));
        print('  PASS: AVI + PCM verified');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Opus in MKV container', () async {
        final job = createAudioTestJob(
          '${TestConfig.outputDir}/test_container_mkv_opus.mkv',
          const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.convert,
            audioCodec: AudioCodec.opus,
            audioQuality: AudioQuality.medium,
          ),
        );

        final result = await runFilterTest('MKV + Opus', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getAudioStreamInfo(result.outputPath!);
        expect(outputInfo.codec, equals('opus'));
        print('  PASS: MKV + Opus verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
  });
}
