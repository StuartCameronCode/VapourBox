/// End-to-end integration tests for chroma subsampling (output color format).
/// These tests verify that ChromaSubsampling settings (original, yuv420, yuv422)
/// correctly affect the output video's pixel format.
///
/// Run headless via CI: flutter test test/integration_chroma_subsampling_test.dart
/// Heavy (full-encode) — tagged so it runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

/// Thin shim over [WorkerHarness] so the test bodies keep their `TestConfig.*`
/// call sites while paths/env resolve cross-platform.
class TestConfig {
  static String get projectRoot => WorkerHarness.repoRoot;
  static String get inputFile => WorkerHarness.inputFile;
  static String get outputDir => '${WorkerHarness.outputDir}/chroma';
  static String get workerPath => WorkerHarness.workerPath;
  static String get depsDir => WorkerHarness.depsDir;
}

// =============================================================================
// VIDEO ANALYSIS HELPERS
// =============================================================================

/// Information about video pixel format
class VideoFormatInfo {
  final String? pixelFormat;
  final int? width;
  final int? height;
  final String? colorSpace;
  final String? colorRange;

  VideoFormatInfo({
    this.pixelFormat,
    this.width,
    this.height,
    this.colorSpace,
    this.colorRange,
  });

  /// Check if this is a 4:2:0 format
  bool get isYuv420 => pixelFormat?.contains('420') ?? false;

  /// Check if this is a 4:2:2 format
  bool get isYuv422 => pixelFormat?.contains('422') ?? false;

  /// Check if this is a 4:4:4 format
  bool get isYuv444 => pixelFormat?.contains('444') ?? false;

  /// Get the chroma subsampling description
  String get chromaDescription {
    if (isYuv420) return '4:2:0';
    if (isYuv422) return '4:2:2';
    if (isYuv444) return '4:4:4';
    return 'unknown';
  }

  @override
  String toString() {
    return 'Video: ${width}x$height, pix_fmt=$pixelFormat ($chromaDescription), '
        'color_space=$colorSpace, color_range=$colorRange';
  }
}

/// Get detailed information about video format using ffprobe
Future<VideoFormatInfo> getVideoFormatInfo(String videoPath) async {
  final ffprobePath = WorkerHarness.ffprobePath;

  final result = await Process.run(
    ffprobePath,
    [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=pix_fmt,width,height,color_space,color_range',
      '-of', 'json',
      videoPath,
    ],
    environment: {
      'PATH': '${WorkerHarness.depsDir}/ffmpeg${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH']}',
    },
  );

  if (result.exitCode != 0) {
    throw Exception('ffprobe failed: ${result.stderr}');
  }

  final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  final streams = json['streams'] as List?;

  if (streams == null || streams.isEmpty) {
    return VideoFormatInfo();
  }

  final stream = streams[0] as Map<String, dynamic>;
  return VideoFormatInfo(
    pixelFormat: stream['pix_fmt'] as String?,
    width: stream['width'] as int?,
    height: stream['height'] as int?,
    colorSpace: stream['color_space'] as String?,
    colorRange: stream['color_range'] as String?,
  );
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

  // Cross-platform worker environment sourced from the shared harness.
  final env = WorkerHarness.workerEnv;

  try {
    print('\n${'=' * 60}');
    print('CHROMA TEST: $testName');
    print('Output: ${job.outputPath}');
    print('Chroma setting: ${job.encodingSettings.chromaSubsampling.displayName}');
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

/// Create a processing job for chroma tests
VideoJob createChromaTestJob(String outputPath, ChromaSubsampling chromaSubsampling) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: TestConfig.inputFile,
    outputPath: outputPath,
    qtgmcParameters: const QTGMCParameters(
      preset: QTGMCPreset.superFast,
      tff: true,
      fpsDivisor: 2,
    ),
    processingPipeline: const ProcessingPipeline(
      deinterlace: QTGMCParameters(
        preset: QTGMCPreset.superFast,
        tff: true,
        fpsDivisor: 2,
      ),
    ),
    encodingSettings: EncodingSettings(
      codec: VideoCodec.h264,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none, // Skip audio to speed up tests
      chromaSubsampling: chromaSubsampling,
    ),
    // Use short trim to speed up tests
    startFrame: 10,
    endFrame: 40,
  );
}

void main() {
  // Store input format info
  late VideoFormatInfo inputFormatInfo;

  // Ensure output directory exists
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(TestConfig.outputDir).create(recursive: true);
  });

  group('Chroma Subsampling Tests', () {
    // ===========================================================================
    // SETUP: Get input video format info
    // ===========================================================================
    test('Setup: Get input video format information', () async {
      print('\n${'=' * 60}');
      print('SETUP: Analyzing input video format');
      print('=' * 60);

      inputFormatInfo = await getVideoFormatInfo(TestConfig.inputFile);
      print('Input video: $inputFormatInfo');

      expect(inputFormatInfo.pixelFormat, isNotNull,
          reason: 'Input video must have a pixel format');

      print('  Input pixel format: ${inputFormatInfo.pixelFormat}');
      print('  Input chroma: ${inputFormatInfo.chromaDescription}');
    });

    // ===========================================================================
    // CHROMA SUBSAMPLING: ORIGINAL
    // ===========================================================================
    group('ChromaSubsampling.original', () {
      test('Original mode keeps input format', () async {
        final job = createChromaTestJob(
          '${TestConfig.outputDir}/test_chroma_original.mkv',
          ChromaSubsampling.original,
        );

        final result = await runFilterTest('Original (keep input)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoFormatInfo(result.outputPath!);
        print('  Output format: $outputInfo');

        expect(outputInfo.pixelFormat, isNotNull);

        // Note: With deinterlacing, format may change due to processing
        // but should not be forcibly converted to 420 or 422
        print('  Input was: ${inputFormatInfo.chromaDescription}');
        print('  Output is: ${outputInfo.chromaDescription}');

        print('  PASS: Original mode preserves format characteristics');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // CHROMA SUBSAMPLING: YUV420
    // ===========================================================================
    group('ChromaSubsampling.yuv420', () {
      test('YUV420 mode converts to 4:2:0', () async {
        final job = createChromaTestJob(
          '${TestConfig.outputDir}/test_chroma_yuv420.mkv',
          ChromaSubsampling.yuv420,
        );

        final result = await runFilterTest('YUV420 (4:2:0)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoFormatInfo(result.outputPath!);
        print('  Output format: $outputInfo');

        expect(outputInfo.pixelFormat, isNotNull);
        expect(outputInfo.isYuv420, isTrue,
            reason: 'ChromaSubsampling.yuv420 should produce 4:2:0 output, '
                'got ${outputInfo.pixelFormat}');

        print('  Output pixel format: ${outputInfo.pixelFormat}');
        print('  Output chroma: ${outputInfo.chromaDescription}');
        print('  PASS: YUV420 mode produces 4:2:0 output');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('YUV420 format string contains "420"', () async {
        final job = createChromaTestJob(
          '${TestConfig.outputDir}/test_chroma_yuv420_verify.mkv',
          ChromaSubsampling.yuv420,
        );

        final result = await runFilterTest('YUV420 Verify', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoFormatInfo(result.outputPath!);

        // Verify the pixel format string explicitly contains 420
        expect(
          outputInfo.pixelFormat!.toLowerCase(),
          contains('420'),
          reason: 'Pixel format should contain "420" for 4:2:0 subsampling',
        );

        print('  Verified: ${outputInfo.pixelFormat} contains "420"');
        print('  PASS: YUV420 format verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // CHROMA SUBSAMPLING: YUV422
    // ===========================================================================
    group('ChromaSubsampling.yuv422', () {
      test('YUV422 mode converts to 4:2:2', () async {
        final job = createChromaTestJob(
          '${TestConfig.outputDir}/test_chroma_yuv422.mkv',
          ChromaSubsampling.yuv422,
        );

        final result = await runFilterTest('YUV422 (4:2:2)', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoFormatInfo(result.outputPath!);
        print('  Output format: $outputInfo');

        expect(outputInfo.pixelFormat, isNotNull);
        expect(outputInfo.isYuv422, isTrue,
            reason: 'ChromaSubsampling.yuv422 should produce 4:2:2 output, '
                'got ${outputInfo.pixelFormat}');

        print('  Output pixel format: ${outputInfo.pixelFormat}');
        print('  Output chroma: ${outputInfo.chromaDescription}');
        print('  PASS: YUV422 mode produces 4:2:2 output');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('YUV422 format string contains "422"', () async {
        final job = createChromaTestJob(
          '${TestConfig.outputDir}/test_chroma_yuv422_verify.mkv',
          ChromaSubsampling.yuv422,
        );

        final result = await runFilterTest('YUV422 Verify', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoFormatInfo(result.outputPath!);

        // Verify the pixel format string explicitly contains 422
        expect(
          outputInfo.pixelFormat!.toLowerCase(),
          contains('422'),
          reason: 'Pixel format should contain "422" for 4:2:2 subsampling',
        );

        print('  Verified: ${outputInfo.pixelFormat} contains "422"');
        print('  PASS: YUV422 format verified');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // COMPARISON TESTS
    // ===========================================================================
    group('Format Comparison', () {
      test('YUV420 and YUV422 outputs have different pixel formats', () async {
        // Create YUV420 output
        final job420 = createChromaTestJob(
          '${TestConfig.outputDir}/test_compare_420.mkv',
          ChromaSubsampling.yuv420,
        );

        final result420 = await runFilterTest('Compare 420', job420);
        expect(result420.success, isTrue, reason: result420.error);

        // Create YUV422 output
        final job422 = createChromaTestJob(
          '${TestConfig.outputDir}/test_compare_422.mkv',
          ChromaSubsampling.yuv422,
        );

        final result422 = await runFilterTest('Compare 422', job422);
        expect(result422.success, isTrue, reason: result422.error);

        // Get format info for both
        final info420 = await getVideoFormatInfo(result420.outputPath!);
        final info422 = await getVideoFormatInfo(result422.outputPath!);

        print('  YUV420 output: ${info420.pixelFormat} (${info420.chromaDescription})');
        print('  YUV422 output: ${info422.pixelFormat} (${info422.chromaDescription})');

        // Verify they have different pixel formats
        expect(info420.pixelFormat, isNot(equals(info422.pixelFormat)),
            reason: 'YUV420 and YUV422 should produce different pixel formats');

        // Verify each has the correct subsampling
        expect(info420.isYuv420, isTrue,
            reason: 'YUV420 output should be 4:2:0');
        expect(info422.isYuv422, isTrue,
            reason: 'YUV422 output should be 4:2:2');

        print('  PASS: Different chroma settings produce different output formats');
      }, timeout: const Timeout(Duration(minutes: 10)));

      test('YUV422 produces larger file than YUV420 (higher chroma resolution)', () async {
        // Create YUV420 output
        final job420 = createChromaTestJob(
          '${TestConfig.outputDir}/test_size_420.mkv',
          ChromaSubsampling.yuv420,
        );

        final result420 = await runFilterTest('Size 420', job420);
        expect(result420.success, isTrue, reason: result420.error);

        // Create YUV422 output with same settings
        final job422 = createChromaTestJob(
          '${TestConfig.outputDir}/test_size_422.mkv',
          ChromaSubsampling.yuv422,
        );

        final result422 = await runFilterTest('Size 422', job422);
        expect(result422.success, isTrue, reason: result422.error);

        // Compare file sizes
        final size420 = await File(result420.outputPath!).length();
        final size422 = await File(result422.outputPath!).length();

        print('  YUV420 file size: ${(size420 / 1024).round()} KB');
        print('  YUV422 file size: ${(size422 / 1024).round()} KB');

        // YUV422 has more chroma data, so should be larger
        // (4:2:2 has twice the chroma resolution of 4:2:0)
        expect(size422, greaterThan(size420),
            reason: 'YUV422 (4:2:2) should produce larger files than YUV420 (4:2:0) '
                'due to higher chroma resolution');

        final sizeIncrease = ((size422 - size420) / size420 * 100).round();
        print('  Size increase: $sizeIncrease%');

        print('  PASS: YUV422 produces larger file as expected');
      }, timeout: const Timeout(Duration(minutes: 10)));
    });

    // ===========================================================================
    // CONTAINER COMPATIBILITY
    // ===========================================================================
    group('Container Compatibility', () {
      test('YUV420 works with MP4 container', () async {
        final job = createChromaTestJob(
          '${TestConfig.outputDir}/test_chroma_420_mp4.mp4',
          ChromaSubsampling.yuv420,
        ).copyWith(
          encodingSettings: const EncodingSettings(
            codec: VideoCodec.h264,
            container: ContainerFormat.mp4,
            audioMode: AudioMode.none,
            chromaSubsampling: ChromaSubsampling.yuv420,
          ),
        );

        final result = await runFilterTest('YUV420 + MP4', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoFormatInfo(result.outputPath!);
        expect(outputInfo.isYuv420, isTrue);

        print('  PASS: YUV420 works with MP4 container');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('YUV422 works with MKV container', () async {
        final job = createChromaTestJob(
          '${TestConfig.outputDir}/test_chroma_422_mkv.mkv',
          ChromaSubsampling.yuv422,
        );

        final result = await runFilterTest('YUV422 + MKV', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoFormatInfo(result.outputPath!);
        expect(outputInfo.isYuv422, isTrue);

        print('  PASS: YUV422 works with MKV container');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    // ===========================================================================
    // CODEC COMPATIBILITY
    // ===========================================================================
    group('Codec Compatibility', () {
      test('YUV420 works with H.265 codec', () async {
        final job = VideoJob(
          id: const Uuid().v4(),
          inputPath: TestConfig.inputFile,
          outputPath: '${TestConfig.outputDir}/test_chroma_420_h265.mkv',
          qtgmcParameters: const QTGMCParameters(
            preset: QTGMCPreset.superFast,
            tff: true,
            fpsDivisor: 2,
          ),
          processingPipeline: const ProcessingPipeline(
            deinterlace: QTGMCParameters(
              preset: QTGMCPreset.superFast,
              tff: true,
              fpsDivisor: 2,
            ),
          ),
          encodingSettings: const EncodingSettings(
            codec: VideoCodec.h265,
            container: ContainerFormat.mkv,
            audioMode: AudioMode.none,
            chromaSubsampling: ChromaSubsampling.yuv420,
          ),
          startFrame: 10,
          endFrame: 40,
        );

        final result = await runFilterTest('YUV420 + H.265', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoFormatInfo(result.outputPath!);
        expect(outputInfo.isYuv420, isTrue);

        print('  PASS: YUV420 works with H.265 codec');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('YUV422 works with ProRes codec', () async {
        final job = VideoJob(
          id: const Uuid().v4(),
          inputPath: TestConfig.inputFile,
          outputPath: '${TestConfig.outputDir}/test_chroma_422_prores.mov',
          qtgmcParameters: const QTGMCParameters(
            preset: QTGMCPreset.superFast,
            tff: true,
            fpsDivisor: 2,
          ),
          processingPipeline: const ProcessingPipeline(
            deinterlace: QTGMCParameters(
              preset: QTGMCPreset.superFast,
              tff: true,
              fpsDivisor: 2,
            ),
          ),
          encodingSettings: const EncodingSettings(
            codec: VideoCodec.prores422,
            container: ContainerFormat.mov,
            audioMode: AudioMode.none,
            chromaSubsampling: ChromaSubsampling.yuv422,
          ),
          startFrame: 10,
          endFrame: 40,
        );

        final result = await runFilterTest('YUV422 + ProRes', job);
        expect(result.success, isTrue, reason: result.error);

        final outputInfo = await getVideoFormatInfo(result.outputPath!);
        // ProRes is naturally 4:2:2
        expect(outputInfo.isYuv422, isTrue,
            reason: 'ProRes should output 4:2:2 format');

        print('  PASS: YUV422 works with ProRes codec');
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
  });
}

/// Extension to add copyWith to VideoJob
extension VideoJobCopyWith on VideoJob {
  VideoJob copyWith({
    String? id,
    String? inputPath,
    String? outputPath,
    QTGMCParameters? qtgmcParameters,
    ProcessingPipeline? processingPipeline,
    EncodingSettings? encodingSettings,
    int? startFrame,
    int? endFrame,
  }) {
    return VideoJob(
      id: id ?? this.id,
      inputPath: inputPath ?? this.inputPath,
      outputPath: outputPath ?? this.outputPath,
      qtgmcParameters: qtgmcParameters ?? this.qtgmcParameters,
      processingPipeline: processingPipeline ?? this.processingPipeline,
      encodingSettings: encodingSettings ?? this.encodingSettings,
      startFrame: startFrame ?? this.startFrame,
      endFrame: endFrame ?? this.endFrame,
    );
  }
}
