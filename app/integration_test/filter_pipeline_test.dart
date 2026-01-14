/// End-to-end integration tests for the filter pipeline.
/// These tests spawn the actual worker process and run video processing.
/// Each filter test verifies the output differs from a baseline (no filters).
///
/// Run with: flutter test integration_test/filter_pipeline_test.dart
/// Or: dart test integration_test/filter_pipeline_test.dart --chain-stack-traces

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import '../lib/models/chroma_fix_parameters.dart';
import '../lib/models/color_correction_parameters.dart';
import '../lib/models/crop_resize_parameters.dart';
import '../lib/models/deband_parameters.dart';
import '../lib/models/deblock_parameters.dart';
import '../lib/models/dehalo_parameters.dart';
import '../lib/models/encoding_settings.dart';
import '../lib/models/noise_reduction_parameters.dart';
import '../lib/models/qtgmc_parameters.dart';
import '../lib/models/restoration_pipeline.dart';
import '../lib/models/sharpen_parameters.dart';
import '../lib/models/video_job.dart';

/// Test configuration
class TestConfig {
  static final String projectRoot = _findProjectRoot();
  static String get inputFile => '$projectRoot/Tests/TestResources/interlaced_test.avi';
  static String get outputDir => '$projectRoot/Tests/TestOutput';
  static String get workerPath => '$projectRoot/worker/target/release/vapourbox-worker.exe';
  static String get depsDir => '$projectRoot/deps/windows-x64';
  static String get baselineFile => '$outputDir/baseline_deinterlace_only.avi';

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

/// Global baseline frame hash for comparison (visual content only)
String? _baselineFrameHash;

/// Extracts a frame from a video and returns its hash (visual content only)
Future<String> extractFrameHash(String videoPath, {int frameNumber = 5}) async {
  final tempDir = Directory.systemTemp;
  final framePath = '${tempDir.path}/frame_${DateTime.now().millisecondsSinceEpoch}.png';
  final ffmpegPath = '${TestConfig.depsDir}/ffmpeg/ffmpeg.exe';

  try {
    // Extract a specific frame as PNG (lossless, no metadata variation)
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
      throw Exception('Failed to extract frame: ${result.stderr}');
    }

    // Read the frame and compute hash
    final frameFile = File(framePath);
    if (!await frameFile.exists()) {
      throw Exception('Frame extraction produced no output');
    }

    final bytes = await frameFile.readAsBytes();
    final hash = md5.convert(bytes).toString();

    // Cleanup
    await frameFile.delete().catchError((_) => frameFile);

    return hash;
  } catch (e) {
    // Cleanup on error
    final frameFile = File(framePath);
    if (await frameFile.exists()) {
      await frameFile.delete().catchError((_) => frameFile);
    }
    rethrow;
  }
}

/// Verifies that two videos have different visual content
Future<bool> videosAreDifferent(String path1, String path2) async {
  final hash1 = await extractFrameHash(path1);
  final hash2 = await extractFrameHash(path2);
  return hash1 != hash2;
}

/// Verifies output differs from baseline (compares actual video frames)
Future<void> verifyDiffersFromBaseline(String outputPath, String filterName) async {
  if (_baselineFrameHash == null) {
    throw StateError('Baseline not yet generated. Run baseline test first.');
  }

  final outputHash = await extractFrameHash(outputPath);
  if (outputHash == _baselineFrameHash) {
    throw TestFailure(
      '$filterName: Output video frames are IDENTICAL to baseline!\n'
      'This means the filter had NO EFFECT on the visual output.\n'
      'Baseline frame hash: $_baselineFrameHash\n'
      'Output frame hash: $outputHash'
    );
  }
  print('  ✓ Visual output differs from baseline (filter had effect)');
}

/// Global baseline preview hash for comparison
String? _baselinePreviewHash;

/// Result of running a preview test
class PreviewTestResult {
  final bool success;
  final String? previewHash;
  final String? error;
  final Duration duration;
  final List<String> logs;
  final int? exitCode;

  PreviewTestResult({
    required this.success,
    this.previewHash,
    this.error,
    required this.duration,
    required this.logs,
    this.exitCode,
  });
}

/// Runs a preview generation through the worker and returns the result
Future<PreviewTestResult> runPreviewTest(
  String testName,
  VideoJob job, {
  int frameNumber = 5,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final stopwatch = Stopwatch()..start();
  final logs = <String>[];

  // Write job config to temp file
  final configFile = File('${Directory.systemTemp.path}/preview_${job.id}.json');
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
    print('PREVIEW TEST: $testName');
    print('Frame: $frameNumber');
    print('=' * 60);

    // Run worker in preview mode
    final process = await Process.start(
      TestConfig.workerPath,
      ['--config', configFile.path, '--preview', '--frame', frameNumber.toString()],
      environment: env,
      workingDirectory: File(TestConfig.workerPath).parent.path,
    );

    // Collect PNG data from stdout
    final pngData = <int>[];
    process.stdout.listen((data) {
      pngData.addAll(data);
    });

    // Collect stderr for logs
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      logs.add(line);
      if (line.contains('Error') || line.contains('error')) {
        print('  [stderr] $line');
      }
    });

    // Wait for completion
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        throw TimeoutException('Preview timed out after ${timeout.inSeconds}s');
      },
    );

    stopwatch.stop();

    // Clean up
    await configFile.delete().catchError((_) => configFile);

    if (exitCode == 0 && pngData.isNotEmpty) {
      // Compute hash of the preview image
      final hash = md5.convert(pngData).toString();
      print('  Preview generated: ${pngData.length} bytes, hash: $hash');

      return PreviewTestResult(
        success: true,
        previewHash: hash,
        duration: stopwatch.elapsed,
        logs: logs,
        exitCode: exitCode,
      );
    } else {
      return PreviewTestResult(
        success: false,
        error: 'Preview failed with exit code $exitCode (${pngData.length} bytes output)',
        duration: stopwatch.elapsed,
        logs: logs,
        exitCode: exitCode,
      );
    }
  } catch (e) {
    stopwatch.stop();
    await configFile.delete().catchError((_) => configFile);

    return PreviewTestResult(
      success: false,
      error: e.toString(),
      duration: stopwatch.elapsed,
      logs: logs,
    );
  }
}

/// Verifies preview differs from baseline
Future<void> verifyPreviewDiffersFromBaseline(String? previewHash, String filterName) async {
  if (_baselinePreviewHash == null) {
    throw StateError('Baseline preview not yet generated. Run baseline preview test first.');
  }

  if (previewHash == _baselinePreviewHash) {
    throw TestFailure(
      '$filterName: Preview image is IDENTICAL to baseline!\n'
      'This means the filter had NO EFFECT on the preview.\n'
      'Baseline preview hash: $_baselinePreviewHash\n'
      'Output preview hash: $previewHash'
    );
  }
  print('  ✓ Preview differs from baseline (filter had effect)');
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

  @override
  String toString() {
    if (success) {
      return 'SUCCESS in ${duration.inSeconds}s -> $outputPath';
    } else {
      return 'FAILED: $error (exit code: $exitCode)';
    }
  }
}

/// Runs a video job through the worker and returns the result
Future<FilterTestResult> runFilterTest(
  String testName,
  VideoJob job, {
  Duration timeout = const Duration(minutes: 5),
}) async {
  final stopwatch = Stopwatch()..start();
  final logs = <String>[];

  // Write job config to temp file
  final configFile = File('${Directory.systemTemp.path}/test_${job.id}.json');
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
    print('TEST: $testName');
    print('Output: ${job.outputPath}');
    print('=' * 60);

    final process = await Process.start(
      TestConfig.workerPath,
      ['--config', configFile.path],
      environment: env,
      workingDirectory: File(TestConfig.workerPath).parent.path,
    );

    String? outputPath;
    bool? jobSuccess;
    String? errorMessage;

    // Listen to stdout
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      logs.add(line);

      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final type = json['type'] as String?;

        if (type == 'progress') {
          final frame = json['frame'] as int?;
          final total = json['totalFrames'] as int?;
          final fps = json['fps'] as num?;
          if (frame != null && total != null) {
            final pct = ((frame / total) * 100).toStringAsFixed(1);
            stdout.write('\rProgress: $pct% (${fps?.toStringAsFixed(1) ?? '?'} fps)');
          }
        } else if (type == 'complete') {
          jobSuccess = json['success'] as bool?;
          outputPath = json['outputPath'] as String?;
        } else if (type == 'error') {
          errorMessage = json['message'] as String?;
          print('\nERROR: $errorMessage');
        } else if (type == 'log') {
          final level = json['level'] as String?;
          final message = json['message'] as String?;
          if (level == 'error' || level == 'warning') {
            print('\n[$level] $message');
          }
        }
      } catch (_) {
        // Not JSON, print if it looks important
        if (line.contains('Error') || line.contains('error') || line.contains('Exception')) {
          print('\n$line');
        }
      }
    });

    // Listen to stderr
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      logs.add('[stderr] $line');
      if (line.contains('Error') || line.contains('Exception') || line.contains('Failed')) {
        print('\n[stderr] $line');
      }
    });

    // Wait for completion with timeout
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        throw TimeoutException('Test timed out after ${timeout.inSeconds}s');
      },
    );

    stopwatch.stop();
    print('\nCompleted in ${stopwatch.elapsed.inSeconds}s with exit code $exitCode');

    // Clean up config file
    await configFile.delete().catchError((_) => configFile);

    if (exitCode == 0 && jobSuccess == true) {
      return FilterTestResult(
        success: true,
        outputPath: outputPath,
        duration: stopwatch.elapsed,
        logs: logs,
        exitCode: exitCode,
      );
    } else {
      return FilterTestResult(
        success: false,
        error: errorMessage ?? 'Worker exited with code $exitCode',
        duration: stopwatch.elapsed,
        logs: logs,
        exitCode: exitCode,
      );
    }
  } catch (e) {
    stopwatch.stop();
    await configFile.delete().catchError((_) => configFile);

    return FilterTestResult(
      success: false,
      error: e.toString(),
      duration: stopwatch.elapsed,
      logs: logs,
    );
  }
}

/// Creates a base video job for testing
VideoJob createTestJob(String outputName, {String extension = 'avi'}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: TestConfig.inputFile,
    outputPath: '${TestConfig.outputDir}/$outputName.$extension',
    qtgmcParameters: const QTGMCParameters(
      preset: QTGMCPreset.fast,
      tff: true,
      fpsDivisor: 2,
    ),
    restorationPipeline: const RestorationPipeline(
      deinterlace: QTGMCParameters(
        preset: QTGMCPreset.fast,
        tff: true,
        fpsDivisor: 2,
      ),
    ),
    encodingSettings: const EncodingSettings(
      codec: VideoCodec.ffv1,
      container: ContainerFormat.avi,
    ),
  );
}

void main() {
  // Ensure output directory exists
  setUpAll(() async {
    final outputDir = Directory(TestConfig.outputDir);
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    // Verify prerequisites
    final workerFile = File(TestConfig.workerPath);
    if (!await workerFile.exists()) {
      fail('Worker not found at ${TestConfig.workerPath}. Run: cd worker && cargo build --release');
    }

    final inputFile = File(TestConfig.inputFile);
    if (!await inputFile.exists()) {
      fail('Test input not found at ${TestConfig.inputFile}');
    }

    final depsDir = Directory(TestConfig.depsDir);
    if (!await depsDir.exists()) {
      fail('Dependencies not found at ${TestConfig.depsDir}. Run download-deps-windows.ps1');
    }

    print('Project root: ${TestConfig.projectRoot}');
    print('Input file: ${TestConfig.inputFile}');
    print('Output dir: ${TestConfig.outputDir}');
    print('Worker: ${TestConfig.workerPath}');
  });

  // BASELINE TEST - Must run first to establish comparison reference
  group('Baseline', () {
    test('Generate baseline (deinterlace only, no filters)', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: TestConfig.baselineFile,
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          // NO other filters enabled - this is our baseline
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runFilterTest('Baseline (no filters)', job);
      expect(result.success, isTrue, reason: result.error);
      expect(File(result.outputPath!).existsSync(), isTrue);

      // Store baseline frame hash for comparison
      _baselineFrameHash = await extractFrameHash(result.outputPath!);
      print('  Baseline frame hash: $_baselineFrameHash');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Control: Second baseline export matches first (validates comparison)', () async {
      // This test validates our comparison mechanism works correctly
      // Two exports with identical parameters should produce identical visual output
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/baseline_control.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runFilterTest('Baseline Control', job);
      expect(result.success, isTrue, reason: result.error);

      // Verify this matches the first baseline
      final controlHash = await extractFrameHash(result.outputPath!);
      expect(
        controlHash,
        equals(_baselineFrameHash),
        reason: 'Control export should match baseline exactly!\n'
            'Baseline hash: $_baselineFrameHash\n'
            'Control hash: $controlHash\n'
            'If these differ, the comparison mechanism may be unreliable.',
      );
      print('  ✓ Control export matches baseline (comparison mechanism is valid)');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Deinterlace Filters', () {
    test('Deinterlace - Fast preset', () async {
      final job = createTestJob('test_deinterlace_fast');
      final result = await runFilterTest('Deinterlace Fast', job);
      expect(result.success, isTrue, reason: result.error);
      expect(File(result.outputPath!).existsSync(), isTrue);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Deinterlace - Medium preset with double rate', () async {
      var job = createTestJob('test_deinterlace_medium_double');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.medium,
          tff: true,
          fpsDivisor: 1, // Double rate
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.medium,
            tff: true,
            fpsDivisor: 1,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Deinterlace Medium (Double Rate)', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('Deinterlace - Slow preset with source match', () async {
      var job = createTestJob('test_deinterlace_slow');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.slow,
          tff: true,
          fpsDivisor: 2,
          sourceMatch: 1,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.slow,
            tff: true,
            fpsDivisor: 2,
            sourceMatch: 1,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Deinterlace Slow (Source Match)', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 15)));
  });

  group('Noise Reduction Filters', () {
    test('Noise Reduction - SMDegrain Light', () async {
      var job = createTestJob('test_nr_smdegrain_light');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.smDegrain,
            smDegrainTr: 1,
            smDegrainThSAD: 150,
            smDegrainThSADC: 75,
            smDegrainRefine: false,
            smDegrainPrefilter: 1,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('SMDegrain Light', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'SMDegrain Light');
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('Noise Reduction - SMDegrain Heavy', () async {
      var job = createTestJob('test_nr_smdegrain_heavy');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.smDegrain,
            smDegrainTr: 3,
            smDegrainThSAD: 400,
            smDegrainThSADC: 200,
            smDegrainRefine: true,
            smDegrainPrefilter: 3,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('SMDegrain Heavy', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 15)));

    test('Noise Reduction - MCTemporalDenoise', () async {
      var job = createTestJob('test_nr_mctemporal');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.mcTemporalDenoise,
            mcTemporalSigma: 4.0,
            mcTemporalRadius: 2,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('MCTemporalDenoise', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('Color Correction Filters', () {
    test('Color Correction - Brightness/Contrast', () async {
      var job = createTestJob('test_color_brightness');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          colorCorrection: const ColorCorrectionParameters(
            enabled: true,
            brightness: 10.0,
            contrast: 1.1,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Brightness/Contrast', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Color Correction - Saturation', () async {
      var job = createTestJob('test_color_saturation');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          colorCorrection: const ColorCorrectionParameters(
            enabled: true,
            saturation: 1.3,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Saturation Boost', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Color Correction - Levels', () async {
      var job = createTestJob('test_color_levels');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          colorCorrection: const ColorCorrectionParameters(
            enabled: true,
            applyLevels: true,
            inputLow: 16,
            inputHigh: 235,
            outputLow: 0,
            outputHigh: 255,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Levels Correction', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Chroma Fix Filters', () {
    test('Chroma Fix - Bleeding Fix', () async {
      var job = createTestJob('test_chroma_bleeding');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          chromaFixes: const ChromaFixParameters(
            enabled: true,
            applyChromaBleedingFix: true,
            chromaBleedCx: 4,
            chromaBleedCy: 4,
            chromaBleedCBlur: 0.7,
            chromaBleedStrength: 1.0,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Chroma Bleeding Fix', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Chroma Fix - DeCrawl', () async {
      var job = createTestJob('test_chroma_decrawl');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          chromaFixes: const ChromaFixParameters(
            enabled: true,
            applyDeCrawl: true,
            deCrawlYThresh: 10,
            deCrawlCThresh: 10,
            deCrawlMaxDiff: 50,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('DeCrawl', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Chroma Fix - Vinverse', () async {
      var job = createTestJob('test_chroma_vinverse');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          chromaFixes: const ChromaFixParameters(
            enabled: true,
            applyVinverse: true,
            vinverseSstr: 2.0,
            vinverseAmnt: 200,
            vinverseScl: 12,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Vinverse', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Dehalo Filters', () {
    test('Dehalo - DeHalo_alpha', () async {
      var job = createTestJob('test_dehalo_alpha');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          dehalo: const DehaloParameters(
            enabled: true,
            method: DehaloMethod.dehaloAlpha,
            rx: 2.0,
            ry: 2.0,
            darkStr: 1.0,
            brightStr: 1.0,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('DeHalo_alpha', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'DeHalo_alpha');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Dehalo - FineDehalo', () async {
      var job = createTestJob('test_dehalo_fine');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          dehalo: const DehaloParameters(
            enabled: true,
            method: DehaloMethod.fineDehalo,
            rx: 2.0,
            ry: 2.0,
            darkStr: 0.8,
            brightStr: 0.8,
            lowThreshold: 50,
            highThreshold: 100,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('FineDehalo', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'FineDehalo');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Dehalo - YAHR', () async {
      var job = createTestJob('test_dehalo_yahr');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          dehalo: const DehaloParameters(
            enabled: true,
            method: DehaloMethod.yahr,
            yahrBlur: 2,
            yahrDepth: 32,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('YAHR', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'YAHR');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Deblock Filters', () {
    test('Deblock - Deblock_QED', () async {
      var job = createTestJob('test_deblock_qed');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          deblock: const DeblockParameters(
            enabled: true,
            method: DeblockMethod.deblockQed,
            quant1: 24,
            quant2: 26,
            aOffset1: 1,
            aOffset2: 1,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Deblock_QED', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'Deblock_QED');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Deblock - Simple Deblock', () async {
      var job = createTestJob('test_deblock_simple');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          deblock: const DeblockParameters(
            enabled: true,
            method: DeblockMethod.deblock,
            quant1: 30,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Simple Deblock', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'Simple Deblock');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Deband Filters', () {
    test('Deband - f3kdb Light', () async {
      var job = createTestJob('test_deband_light');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          deband: const DebandParameters(
            enabled: true,
            range: 15,
            y: 16,
            cb: 16,
            cr: 16,
            grainY: 16,
            grainC: 16,
            dynamicGrain: true,
            outputDepth: 16,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('f3kdb Light', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'f3kdb Light');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Deband - f3kdb Heavy', () async {
      var job = createTestJob('test_deband_heavy');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          deband: const DebandParameters(
            enabled: true,
            range: 24,
            y: 48,
            cb: 48,
            cr: 48,
            grainY: 32,
            grainC: 32,
            dynamicGrain: true,
            outputDepth: 16,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('f3kdb Heavy', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'f3kdb Heavy');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Sharpen Filters', () {
    test('Sharpen - LSFmod', () async {
      var job = createTestJob('test_sharpen_lsfmod');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          sharpen: const SharpenParameters(
            enabled: true,
            method: SharpenMethod.lsfmod,
            strength: 100,
            overshoot: 1,
            undershoot: 1,
            softEdge: 0,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('LSFmod', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'LSFmod');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Sharpen - CAS', () async {
      var job = createTestJob('test_sharpen_cas');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          sharpen: const SharpenParameters(
            enabled: true,
            method: SharpenMethod.cas,
            casSharpness: 0.5,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('CAS', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyDiffersFromBaseline(result.outputPath!, 'CAS');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Crop/Resize Filters', () {
    test('Crop - Remove Overscan', () async {
      var job = createTestJob('test_crop_overscan');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          cropResize: const CropResizeParameters(
            enabled: true,
            cropEnabled: true,
            cropLeft: 8,
            cropRight: 8,
            cropTop: 8,
            cropBottom: 8,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Crop Overscan', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Resize - 720p Spline36', () async {
      var job = createTestJob('test_resize_720p');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          cropResize: const CropResizeParameters(
            enabled: true,
            resizeEnabled: true,
            targetWidth: 1280,
            targetHeight: 720,
            kernel: ResizeKernel.spline36,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Resize 720p Spline36', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Resize - 1080p Lanczos', () async {
      var job = createTestJob('test_resize_1080p');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: RestorationPipeline(
          deinterlace: job.qtgmcParameters,
          cropResize: const CropResizeParameters(
            enabled: true,
            resizeEnabled: true,
            targetWidth: 1920,
            targetHeight: 1080,
            kernel: ResizeKernel.lanczos,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('Resize 1080p Lanczos', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Codec Tests', () {
    test('Codec - FFV1 (AVI)', () async {
      var job = createTestJob('test_codec_ffv1', extension: 'avi');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: job.restorationPipeline,
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runFilterTest('FFV1 Codec', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Codec - H.264 CRF 18 (MP4)', () async {
      var job = createTestJob('test_codec_h264', extension: 'mp4');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: job.restorationPipeline,
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.h264,
          container: ContainerFormat.mp4,
          quality: 18,
        ),
      );
      final result = await runFilterTest('H.264 CRF 18', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Codec - H.265 CRF 20 (MP4)', () async {
      var job = createTestJob('test_codec_h265', extension: 'mp4');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: job.restorationPipeline,
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.h265,
          container: ContainerFormat.mp4,
          quality: 20,
        ),
      );
      final result = await runFilterTest('H.265 CRF 20', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Codec - ProRes 422 HQ (MOV)', () async {
      var job = createTestJob('test_codec_prores', extension: 'mov');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: job.qtgmcParameters,
        restorationPipeline: job.restorationPipeline,
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.proresHQ,
          container: ContainerFormat.mov,
        ),
      );
      final result = await runFilterTest('ProRes 422 HQ', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('Combined Filters', () {
    test('Combined - All Filters Active', () async {
      var job = createTestJob('test_combined_all');
      job = VideoJob(
        id: job.id,
        inputPath: job.inputPath,
        outputPath: job.outputPath,
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.medium,
          tff: true,
          fpsDivisor: 2,
          sourceMatch: 1,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.medium,
            tff: true,
            fpsDivisor: 2,
            sourceMatch: 1,
          ),
          noiseReduction: NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.smDegrain,
            smDegrainTr: 2,
            smDegrainThSAD: 250,
            smDegrainThSADC: 125,
            smDegrainRefine: true,
            smDegrainPrefilter: 2,
          ),
          dehalo: DehaloParameters(
            enabled: true,
            method: DehaloMethod.dehaloAlpha,
            rx: 2.0,
            ry: 2.0,
            darkStr: 0.8,
            brightStr: 0.8,
          ),
          deblock: DeblockParameters(
            enabled: true,
            method: DeblockMethod.deblockQed,
            quant1: 20,
            quant2: 22,
          ),
          deband: DebandParameters(
            enabled: true,
            range: 15,
            y: 24,
            cb: 24,
            cr: 24,
            grainY: 16,
            grainC: 16,
          ),
          sharpen: SharpenParameters(
            enabled: true,
            method: SharpenMethod.cas,
            casSharpness: 0.4,
          ),
          colorCorrection: ColorCorrectionParameters(
            enabled: true,
            brightness: 5.0,
            contrast: 1.05,
            saturation: 1.1,
          ),
          chromaFixes: ChromaFixParameters(
            enabled: true,
            applyChromaBleedingFix: true,
            chromaBleedCx: 4,
            chromaBleedCy: 4,
            chromaBleedCBlur: 0.7,
            chromaBleedStrength: 0.8,
            applyVinverse: true,
            vinverseSstr: 2.0,
            vinverseAmnt: 200,
            vinverseScl: 12,
          ),
          cropResize: CropResizeParameters(
            enabled: true,
            resizeEnabled: true,
            targetWidth: 1280,
            targetHeight: 720,
            kernel: ResizeKernel.spline36,
          ),
        ),
        encodingSettings: job.encodingSettings,
      );
      final result = await runFilterTest('All Filters Combined', job);
      expect(result.success, isTrue, reason: result.error);
    }, timeout: const Timeout(Duration(minutes: 15)));
  });

  // =========================================================================
  // PREVIEW PIPELINE TESTS
  // These tests verify the preview generation uses the correct filter pipeline
  // =========================================================================
  group('Preview Pipeline', () {
    test('Preview Baseline (deinterlace only)', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_baseline.avi', // Not used for preview
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Baseline', job);
      expect(result.success, isTrue, reason: result.error);
      expect(result.previewHash, isNotNull);

      // Store baseline preview hash
      _baselinePreviewHash = result.previewHash;
      print('  Baseline preview hash: $_baselinePreviewHash');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview Control: Second baseline matches first', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_control.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Control', job);
      expect(result.success, isTrue, reason: result.error);
      expect(
        result.previewHash,
        equals(_baselinePreviewHash),
        reason: 'Control preview should match baseline exactly!',
      );
      print('  ✓ Control preview matches baseline (comparison is valid)');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // =========================================================================
    // NOISE REDUCTION PREVIEW TESTS
    // =========================================================================
    test('Preview - SMDegrain Light', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_nr_smdegrain_light.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          noiseReduction: NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.smDegrain,
            smDegrainTr: 1,
            smDegrainThSAD: 150,
            smDegrainThSADC: 75,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview SMDegrain Light', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'SMDegrain Light');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - SMDegrain Heavy', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_nr_smdegrain_heavy.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          noiseReduction: NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.smDegrain,
            smDegrainTr: 3,
            smDegrainThSAD: 400,
            smDegrainThSADC: 200,
            smDegrainRefine: true,
            smDegrainPrefilter: 3,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview SMDegrain Heavy', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'SMDegrain Heavy');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - MCTemporalDenoise', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_nr_mctemporal.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          noiseReduction: NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.mcTemporalDenoise,
            mcTemporalSigma: 4.0,
            mcTemporalRadius: 2,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview MCTemporalDenoise', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'MCTemporalDenoise');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // =========================================================================
    // COLOR CORRECTION PREVIEW TESTS
    // =========================================================================
    test('Preview - Brightness/Contrast', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_color_brightness.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          colorCorrection: ColorCorrectionParameters(
            enabled: true,
            brightness: 10.0,
            contrast: 1.1,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Brightness/Contrast', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Brightness/Contrast');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - Saturation', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_color_saturation.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          colorCorrection: ColorCorrectionParameters(
            enabled: true,
            saturation: 1.3,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Saturation', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Saturation');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - Levels', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_color_levels.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          colorCorrection: ColorCorrectionParameters(
            enabled: true,
            applyLevels: true,
            inputLow: 16,
            inputHigh: 235,
            outputLow: 0,
            outputHigh: 255,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Levels', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Levels');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // =========================================================================
    // CHROMA FIX PREVIEW TESTS
    // =========================================================================
    test('Preview - Chroma Bleeding Fix', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_chroma_bleeding.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          chromaFixes: ChromaFixParameters(
            enabled: true,
            applyChromaBleedingFix: true,
            chromaBleedCx: 4,
            chromaBleedCy: 4,
            chromaBleedCBlur: 0.7,
            chromaBleedStrength: 1.0,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Chroma Bleeding', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Chroma Bleeding Fix');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - DeCrawl', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_chroma_decrawl.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          chromaFixes: ChromaFixParameters(
            enabled: true,
            applyDeCrawl: true,
            deCrawlYThresh: 10,
            deCrawlCThresh: 10,
            deCrawlMaxDiff: 50,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview DeCrawl', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'DeCrawl');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - Vinverse', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_chroma_vinverse.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          chromaFixes: ChromaFixParameters(
            enabled: true,
            applyVinverse: true,
            vinverseSstr: 2.0,
            vinverseAmnt: 200,
            vinverseScl: 12,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Vinverse', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Vinverse');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // =========================================================================
    // DEHALO PREVIEW TESTS
    // =========================================================================
    test('Preview - Sharpen LSFmod', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_sharpen_lsfmod.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          sharpen: SharpenParameters(
            enabled: true,
            method: SharpenMethod.lsfmod,
            strength: 100,
            overshoot: 1,
            undershoot: 1,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Sharpen LSFmod', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Sharpen LSFmod');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - Sharpen CAS', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_sharpen_cas.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          sharpen: SharpenParameters(
            enabled: true,
            method: SharpenMethod.cas,
            casSharpness: 0.8,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Sharpen CAS', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Sharpen CAS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - Dehalo Alpha', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_dehalo.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          dehalo: DehaloParameters(
            enabled: true,
            method: DehaloMethod.dehaloAlpha,
            rx: 2.0,
            ry: 2.0,
            darkStr: 1.0,
            brightStr: 1.0,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Dehalo Alpha', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Dehalo Alpha');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - Deblock QED', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_deblock.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          deblock: DeblockParameters(
            enabled: true,
            method: DeblockMethod.deblockQed,
            quant1: 24,
            quant2: 26,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Deblock QED', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Deblock QED');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - Deband f3kdb', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_deband.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          deband: DebandParameters(
            enabled: true,
            range: 15,
            y: 32,
            cb: 32,
            cr: 32,
            grainY: 16,
            grainC: 16,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Deband f3kdb', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Deband f3kdb');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - All Filters Combined', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_all_filters.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          sharpen: SharpenParameters(
            enabled: true,
            method: SharpenMethod.cas,
            casSharpness: 0.5,
          ),
          dehalo: DehaloParameters(
            enabled: true,
            method: DehaloMethod.dehaloAlpha,
            rx: 2.0,
            ry: 2.0,
          ),
          deblock: DeblockParameters(
            enabled: true,
            method: DeblockMethod.deblockQed,
            quant1: 20,
            quant2: 22,
          ),
          deband: DebandParameters(
            enabled: true,
            range: 15,
            y: 24,
            cb: 24,
            cr: 24,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview All Filters', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'All Filters Combined');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // =========================================================================
    // ADDITIONAL DEHALO PREVIEW TESTS
    // =========================================================================
    test('Preview - FineDehalo', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_dehalo_fine.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          dehalo: DehaloParameters(
            enabled: true,
            method: DehaloMethod.fineDehalo,
            rx: 2.0,
            ry: 2.0,
            darkStr: 0.8,
            brightStr: 0.8,
            lowThreshold: 50,
            highThreshold: 100,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview FineDehalo', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'FineDehalo');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - YAHR', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_dehalo_yahr.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          dehalo: DehaloParameters(
            enabled: true,
            method: DehaloMethod.yahr,
            yahrBlur: 2,
            yahrDepth: 32,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview YAHR', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'YAHR');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // =========================================================================
    // ADDITIONAL DEBLOCK PREVIEW TESTS
    // =========================================================================
    test('Preview - Simple Deblock', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_deblock_simple.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          deblock: DeblockParameters(
            enabled: true,
            method: DeblockMethod.deblock,
            quant1: 30,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Simple Deblock', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Simple Deblock');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // =========================================================================
    // ADDITIONAL DEBAND PREVIEW TESTS
    // =========================================================================
    test('Preview - f3kdb Heavy', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_deband_heavy.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          deband: DebandParameters(
            enabled: true,
            range: 24,
            y: 48,
            cb: 48,
            cr: 48,
            grainY: 32,
            grainC: 32,
            dynamicGrain: true,
            outputDepth: 16,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview f3kdb Heavy', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'f3kdb Heavy');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // =========================================================================
    // CROP/RESIZE PREVIEW TESTS
    // =========================================================================
    test('Preview - Crop Overscan', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_crop_overscan.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          cropResize: CropResizeParameters(
            enabled: true,
            cropEnabled: true,
            cropLeft: 8,
            cropRight: 8,
            cropTop: 8,
            cropBottom: 8,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Crop Overscan', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Crop Overscan');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - Resize 720p Spline36', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_resize_720p.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          cropResize: CropResizeParameters(
            enabled: true,
            resizeEnabled: true,
            targetWidth: 1280,
            targetHeight: 720,
            kernel: ResizeKernel.spline36,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Resize 720p', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Resize 720p Spline36');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Preview - Resize 1080p Lanczos', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/preview_resize_1080p.avi',
        qtgmcParameters: const QTGMCParameters(
          preset: QTGMCPreset.fast,
          tff: true,
          fpsDivisor: 2,
        ),
        restorationPipeline: const RestorationPipeline(
          deinterlace: QTGMCParameters(
            preset: QTGMCPreset.fast,
            tff: true,
            fpsDivisor: 2,
          ),
          cropResize: CropResizeParameters(
            enabled: true,
            resizeEnabled: true,
            targetWidth: 1920,
            targetHeight: 1080,
            kernel: ResizeKernel.lanczos,
          ),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
      );
      final result = await runPreviewTest('Preview Resize 1080p', job);
      expect(result.success, isTrue, reason: result.error);
      await verifyPreviewDiffersFromBaseline(result.previewHash, 'Resize 1080p Lanczos');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
