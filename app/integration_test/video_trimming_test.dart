/// End-to-end integration tests for video trimming functionality.
/// These tests verify that startFrame/endFrame parameters correctly trim
/// the output video to the expected length and that frames differ across
/// the output (not just repeating the same frame).
///
/// Run with: flutter test integration_test/video_trimming_test.dart
/// Or: dart test integration_test/video_trimming_test.dart --chain-stack-traces

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
  static String get outputDir => '$projectRoot/Tests/TestOutput/trimming';
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
// VIDEO ANALYSIS HELPERS
// =============================================================================

/// Information about video streams
class VideoStreamInfo {
  final int? frameCount;
  final double? frameRate;
  final double? duration;
  final int? width;
  final int? height;
  final String? codec;

  VideoStreamInfo({
    this.frameCount,
    this.frameRate,
    this.duration,
    this.width,
    this.height,
    this.codec,
  });

  @override
  String toString() {
    return 'Video: ${width}x$height, $frameCount frames, ${frameRate?.toStringAsFixed(2)} fps, '
        '${duration?.toStringAsFixed(2)}s, $codec';
  }
}

/// Get detailed information about video streams using ffprobe
Future<VideoStreamInfo> getVideoStreamInfo(String videoPath) async {
  final ffprobePath = '${TestConfig.depsDir}/ffmpeg/ffprobe.exe';

  final result = await Process.run(
    ffprobePath,
    [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-count_frames',
      '-show_entries', 'stream=nb_read_frames,r_frame_rate,duration,width,height,codec_name',
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
    return VideoStreamInfo();
  }

  final stream = streams[0] as Map<String, dynamic>;

  // Parse frame rate (e.g., "25/1" or "30000/1001")
  double? frameRate;
  final frameRateStr = stream['r_frame_rate'] as String?;
  if (frameRateStr != null && frameRateStr.contains('/')) {
    final parts = frameRateStr.split('/');
    if (parts.length == 2) {
      final num = double.tryParse(parts[0]);
      final den = double.tryParse(parts[1]);
      if (num != null && den != null && den > 0) {
        frameRate = num / den;
      }
    }
  }

  return VideoStreamInfo(
    frameCount: int.tryParse(stream['nb_read_frames']?.toString() ?? ''),
    frameRate: frameRate,
    duration: double.tryParse(stream['duration']?.toString() ?? ''),
    width: stream['width'] as int?,
    height: stream['height'] as int?,
    codec: stream['codec_name'] as String?,
  );
}

/// Extract a specific frame from a video and return its hash
Future<String> extractFrameHash(String videoPath, int frameNumber) async {
  final tempDir = Directory.systemTemp;
  final framePath = '${tempDir.path}/frame_${DateTime.now().millisecondsSinceEpoch}_$frameNumber.png';
  final ffmpegPath = '${TestConfig.depsDir}/ffmpeg/ffmpeg.exe';

  try {
    final result = await Process.run(
      ffmpegPath,
      [
        '-i', videoPath,
        '-vf', 'select=eq(n\\,$frameNumber)',
        '-vframes', '1',
        '-y',
        framePath,
      ],
      environment: {
        'PATH': '${TestConfig.depsDir}/ffmpeg;${Platform.environment['PATH']}',
      },
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to extract frame $frameNumber: ${result.stderr}');
    }

    final frameFile = File(framePath);
    if (!await frameFile.exists()) {
      throw Exception('Frame extraction produced no output for frame $frameNumber');
    }

    final bytes = await frameFile.readAsBytes();
    final hash = md5.convert(bytes).toString();

    await frameFile.delete().catchError((_) => frameFile);

    return hash;
  } catch (e) {
    final frameFile = File(framePath);
    if (await frameFile.exists()) {
      await frameFile.delete().catchError((_) => frameFile);
    }
    rethrow;
  }
}

/// Extract multiple frames and return their hashes
Future<List<String>> extractMultipleFrameHashes(String videoPath, List<int> frameNumbers) async {
  final hashes = <String>[];
  for (final frameNumber in frameNumbers) {
    try {
      final hash = await extractFrameHash(videoPath, frameNumber);
      hashes.add(hash);
    } catch (e) {
      // Frame might not exist if video is shorter
      hashes.add('FRAME_NOT_FOUND');
    }
  }
  return hashes;
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
    print('TRIM TEST: $testName');
    print('Output: ${job.outputPath}');
    if (job.startFrame != null || job.endFrame != null) {
      print('Trim: frames ${job.startFrame ?? 0} to ${job.endFrame ?? "end"}');
    }
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

/// Create a minimal processing job for trim tests
VideoJob createTrimTestJob(String outputPath, {int? startFrame, int? endFrame}) {
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
    encodingSettings: const EncodingSettings(
      codec: VideoCodec.h264,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none, // Skip audio to speed up tests
    ),
    startFrame: startFrame,
    endFrame: endFrame,
  );
}

void main() {
  // Store input video info
  late VideoStreamInfo inputInfo;

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

  group('Video Trimming Tests', () {
    // ===========================================================================
    // SETUP: Get input video info
    // ===========================================================================
    test('Setup: Get input video information', () async {
      print('\n${'=' * 60}');
      print('SETUP: Analyzing input video');
      print('=' * 60);

      inputInfo = await getVideoStreamInfo(TestConfig.inputFile);
      print('Input video: $inputInfo');

      expect(inputInfo.frameCount, isNotNull,
          reason: 'Input video must have countable frames');
      expect(inputInfo.frameCount, greaterThan(50),
          reason: 'Input video must have enough frames for trimming tests (need >50)');

      print('  Input has ${inputInfo.frameCount} frames');
    });

    // ===========================================================================
    // BASELINE: Full video (no trimming)
    // ===========================================================================
    group('Baseline (no trimming)', () {
      late String baselineOutputPath;
      late VideoStreamInfo baselineInfo;
      late List<String> baselineFrameHashes;

      test('Process full video without trimming', () async {
        baselineOutputPath = '${TestConfig.outputDir}/baseline_full.mkv';
        final job = createTrimTestJob(baselineOutputPath);

        final result = await runFilterTest('Full Video (no trim)', job);
        expect(result.success, isTrue, reason: result.error);

        baselineInfo = await getVideoStreamInfo(result.outputPath!);
        print('  Output video: $baselineInfo');

        expect(baselineInfo.frameCount, isNotNull);
        print('  Full video has ${baselineInfo.frameCount} frames');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Verify frames differ across full video', () async {
        // Extract frames at 10%, 30%, 50%, 70%, 90% of the video
        final totalFrames = baselineInfo.frameCount!;
        final framesToCheck = [
          (totalFrames * 0.1).round(),
          (totalFrames * 0.3).round(),
          (totalFrames * 0.5).round(),
          (totalFrames * 0.7).round(),
          (totalFrames * 0.9).round(),
        ];

        print('  Extracting frames at positions: $framesToCheck');
        baselineFrameHashes = await extractMultipleFrameHashes(baselineOutputPath, framesToCheck);

        print('  Frame hashes:');
        for (var i = 0; i < framesToCheck.length; i++) {
          print('    Frame ${framesToCheck[i]}: ${baselineFrameHashes[i].substring(0, 8)}...');
        }

        // Verify frames are different (video has motion)
        final uniqueHashes = baselineFrameHashes.toSet();
        expect(uniqueHashes.length, greaterThan(1),
            reason: 'Different positions in video should have different frames');

        print('  PASS: ${uniqueHashes.length}/${baselineFrameHashes.length} unique frames');
      }, timeout: const Timeout(Duration(minutes: 2)));
    });

    // ===========================================================================
    // TRIM FROM START
    // ===========================================================================
    group('Trim from start', () {
      test('Trim first 10 frames (startFrame=10)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_start_10.mkv',
          startFrame: 10,
        );

        final result = await runFilterTest('Trim Start (frame 10+)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        print('  Output video: $outputInfo');

        // Output should have (original - 10) frames
        // Note: With fpsDivisor=2, we're doing single-rate deinterlace
        // The input is interlaced, so frame count may differ
        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        // Verify the output is shorter than not trimming would produce
        // (We can't easily compare to baseline due to deinterlacing)
        print('  Output has ${outputInfo.frameCount} frames (trimmed from frame 10)');
        print('  PASS: Trimmed video created successfully');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Trim first 25 frames (startFrame=25)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_start_25.mkv',
          startFrame: 25,
        );

        final result = await runFilterTest('Trim Start (frame 25+)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        print('  Output video: $outputInfo');

        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        print('  Output has ${outputInfo.frameCount} frames');
        print('  PASS: Trimmed video created successfully');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // TRIM FROM END
    // ===========================================================================
    group('Trim from end', () {
      test('Trim to frame 50 (endFrame=50)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_end_50.mkv',
          endFrame: 50,
        );

        final result = await runFilterTest('Trim End (to frame 50)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        print('  Output video: $outputInfo');

        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        // Output should be approximately 50 frames (before deinterlacing adjustments)
        print('  Output has ${outputInfo.frameCount} frames (trimmed to frame 50)');
        print('  PASS: Trimmed video created successfully');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Trim to frame 100 (endFrame=100)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_end_100.mkv',
          endFrame: 100,
        );

        final result = await runFilterTest('Trim End (to frame 100)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        print('  Output video: $outputInfo');

        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        print('  Output has ${outputInfo.frameCount} frames');
        print('  PASS: Trimmed video created successfully');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // TRIM BOTH ENDS
    // ===========================================================================
    group('Trim both ends', () {
      test('Trim frames 20-60 (startFrame=20, endFrame=60)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_both_20_60.mkv',
          startFrame: 20,
          endFrame: 60,
        );

        final result = await runFilterTest('Trim Both (20-60)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        print('  Output video: $outputInfo');

        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        // Should have approximately 40 frames (60-20=40)
        // Allowing for deinterlacing variations
        print('  Output has ${outputInfo.frameCount} frames (range 20-60)');
        print('  PASS: Trimmed video created successfully');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Trim frames 10-30 (short segment)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_both_10_30.mkv',
          startFrame: 10,
          endFrame: 30,
        );

        final result = await runFilterTest('Trim Both (10-30)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        print('  Output video: $outputInfo');

        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        // Should have approximately 20 frames (30-10=20)
        print('  Output has ${outputInfo.frameCount} frames (range 10-30)');
        print('  PASS: Trimmed video created successfully');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // FRAME CONTENT VERIFICATION
    // ===========================================================================
    group('Frame content verification', () {
      test('Trimmed video has different frames throughout', () async {
        // Create a trimmed video with known range
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_verify_content.mkv',
          startFrame: 10,
          endFrame: 60,
        );

        final result = await runFilterTest('Content Verification', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(5),
            reason: 'Need at least 5 frames to verify content variation');

        // Extract frames at different positions
        final totalFrames = outputInfo.frameCount!;
        final framesToCheck = <int>[];

        // Sample frames evenly across the video
        for (int i = 0; i < 5; i++) {
          final frameNum = (totalFrames * i / 5).floor();
          if (frameNum < totalFrames) {
            framesToCheck.add(frameNum);
          }
        }

        print('  Checking frames: $framesToCheck');
        final hashes = await extractMultipleFrameHashes(result.outputPath!, framesToCheck);

        print('  Frame hashes:');
        for (var i = 0; i < framesToCheck.length; i++) {
          print('    Frame ${framesToCheck[i]}: ${hashes[i].substring(0, 12)}...');
        }

        // Verify we got valid hashes (not "FRAME_NOT_FOUND")
        final validHashes = hashes.where((h) => h != 'FRAME_NOT_FOUND').toList();
        expect(validHashes.length, greaterThan(2),
            reason: 'Should be able to extract at least 3 valid frames');

        // Verify frames differ (video has motion)
        final uniqueHashes = validHashes.toSet();
        print('  Unique frames: ${uniqueHashes.length}/${validHashes.length}');

        // At least some frames should be different
        // (unless the video segment is extremely static)
        expect(uniqueHashes.length, greaterThan(1),
            reason: 'Trimmed video should have varying frame content');

        print('  PASS: Frames vary across trimmed video');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Different trim ranges produce different first frames', () async {
        // Create two videos with different start points
        final job1 = createTrimTestJob(
          '${TestConfig.outputDir}/trim_compare_1.mkv',
          startFrame: 0,
          endFrame: 30,
        );
        final job2 = createTrimTestJob(
          '${TestConfig.outputDir}/trim_compare_2.mkv',
          startFrame: 20,
          endFrame: 50,
        );

        final result1 = await runFilterTest('Compare Range 0-30', job1);
        expect(result1.success, isTrue, reason: result1.error);

        final result2 = await runFilterTest('Compare Range 20-50', job2);
        expect(result2.success, isTrue, reason: result2.error);

        // Extract first frame from each
        final hash1 = await extractFrameHash(result1.outputPath!, 0);
        final hash2 = await extractFrameHash(result2.outputPath!, 0);

        print('  Video 1 (0-30) first frame: ${hash1.substring(0, 12)}...');
        print('  Video 2 (20-50) first frame: ${hash2.substring(0, 12)}...');

        // First frames should be different since they start at different points
        expect(hash1, isNot(equals(hash2)),
            reason: 'Different trim ranges should produce different first frames');

        print('  PASS: Different trim ranges produce different content');
      }, timeout: const Timeout(Duration(minutes: 10)));
    });

    // ===========================================================================
    // FRAME COUNT VERIFICATION
    // ===========================================================================
    group('Frame count verification', () {
      test('Shorter trim range produces fewer output frames', () async {
        // Create a short video (20 frames)
        final jobShort = createTrimTestJob(
          '${TestConfig.outputDir}/trim_count_short.mkv',
          startFrame: 10,
          endFrame: 30,
        );

        // Create a long video (60 frames)
        final jobLong = createTrimTestJob(
          '${TestConfig.outputDir}/trim_count_long.mkv',
          startFrame: 10,
          endFrame: 70,
        );

        final resultShort = await runFilterTest('Short Range (20 frames)', jobShort);
        expect(resultShort.success, isTrue, reason: resultShort.error);

        final resultLong = await runFilterTest('Long Range (60 frames)', jobLong);
        expect(resultLong.success, isTrue, reason: resultLong.error);

        final infoShort = await getVideoStreamInfo(resultShort.outputPath!);
        final infoLong = await getVideoStreamInfo(resultLong.outputPath!);

        print('  Short video (30-10=20 input frames): ${infoShort.frameCount} output frames');
        print('  Long video (70-10=60 input frames): ${infoLong.frameCount} output frames');

        expect(infoShort.frameCount, isNotNull);
        expect(infoLong.frameCount, isNotNull);

        // Long video should have more frames than short video
        expect(infoLong.frameCount!, greaterThan(infoShort.frameCount!),
            reason: 'Longer trim range should produce more output frames');

        print('  PASS: Frame count scales with trim range');
      }, timeout: const Timeout(Duration(minutes: 10)));

      test('Output frame count approximately matches expected trim length', () async {
        // We're using fpsDivisor=2, so single-rate deinterlace
        // Input frame count -> output frame count (roughly equal)

        // Trim exactly 40 input frames
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_count_exact.mkv',
          startFrame: 20,
          endFrame: 60,
        );

        final result = await runFilterTest('Exact 40 frames', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        print('  Input range: frames 20-60 (40 frames)');
        print('  Output frames: ${outputInfo.frameCount}');

        expect(outputInfo.frameCount, isNotNull);

        // With fpsDivisor=2 (single-rate deinterlace), output frames ≈ input frames
        // Allow some tolerance for rounding
        final expectedMinFrames = 35; // Allow some variance
        final expectedMaxFrames = 45;

        expect(outputInfo.frameCount, greaterThanOrEqualTo(expectedMinFrames),
            reason: 'Output should have at least $expectedMinFrames frames');
        expect(outputInfo.frameCount, lessThanOrEqualTo(expectedMaxFrames),
            reason: 'Output should have at most $expectedMaxFrames frames');

        print('  PASS: Output frame count (${outputInfo.frameCount}) is within expected range ($expectedMinFrames-$expectedMaxFrames)');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // EDGE CASES
    // ===========================================================================
    group('Edge cases', () {
      test('Start at frame 0 (no effective start trim)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_edge_start0.mkv',
          startFrame: 0,
          endFrame: 50,
        );

        final result = await runFilterTest('Start at 0', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        print('  Output has ${outputInfo.frameCount} frames');
        print('  PASS: Start at frame 0 works correctly');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Very short trim (10 frames)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_edge_short.mkv',
          startFrame: 30,
          endFrame: 40,
        );

        final result = await runFilterTest('Very Short (10 frames)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        print('  Output has ${outputInfo.frameCount} frames');
        print('  PASS: Very short trim works correctly');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Only startFrame specified (trim to end)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_edge_no_end.mkv',
          startFrame: 50,
          // endFrame not specified - should process to end
        );

        final result = await runFilterTest('No End Frame', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        print('  Output has ${outputInfo.frameCount} frames');
        print('  PASS: Trim to end works correctly');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('Only endFrame specified (trim from start)', () async {
        final job = createTrimTestJob(
          '${TestConfig.outputDir}/trim_edge_no_start.mkv',
          // startFrame not specified - should start from 0
          endFrame: 40,
        );

        final result = await runFilterTest('No Start Frame', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoStreamInfo(result.outputPath!);
        expect(outputInfo.frameCount, isNotNull);
        expect(outputInfo.frameCount, greaterThan(0));

        print('  Output has ${outputInfo.frameCount} frames');
        print('  PASS: Trim from start works correctly');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
  });
}
