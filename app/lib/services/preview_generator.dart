import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../models/encoding_settings.dart';
import '../models/qtgmc_parameters.dart';
import '../models/restoration_pipeline.dart';
import '../models/video_job.dart';

/// Service for generating video thumbnails and processed previews.
class PreviewGenerator {
  Process? _thumbnailProcess;
  Process? _previewProcess;
  String? _ffmpegPath;
  String? _ffprobePath;
  String? _workerPath;
  String? _tempDir;

  /// Cached thumbnails for the current video.
  final Map<int, Uint8List> _thumbnailCache = {};

  /// Currently loaded video path.
  String? _currentVideoPath;

  /// Video duration in seconds.
  double _duration = 0;

  /// Video frame rate.
  double _frameRate = 29.97;

  /// Total frame count.
  int _totalFrames = 0;

  /// Log messages from preview generation (stderr output).
  final List<String> _previewLog = [];

  /// Last error message from preview generation.
  String? _lastError;

  double get duration => _duration;
  double get frameRate => _frameRate;
  int get totalFrames => _totalFrames;

  /// Get all preview log messages.
  List<String> get previewLog => List.unmodifiable(_previewLog);

  /// Get the last error message.
  String? get lastError => _lastError;

  /// Clear the preview log.
  void clearLog() {
    _previewLog.clear();
    _lastError = null;
  }

  /// Initialize the preview generator with tool paths.
  Future<void> initialize() async {
    _ffmpegPath = await _findTool('ffmpeg');
    _ffprobePath = await _findTool('ffprobe');
    _workerPath = await _findWorker();

    // Create temp directory for thumbnails and previews
    final systemTemp = Directory.systemTemp;
    _tempDir = '${systemTemp.path}/vapourbox_preview_${DateTime.now().millisecondsSinceEpoch}';
    await Directory(_tempDir!).create(recursive: true);
  }

  /// Find the worker executable.
  Future<String?> _findWorker() async {
    final exeDir = path.dirname(Platform.resolvedExecutable);
    final ext = Platform.isWindows ? '.exe' : '';

    // Check bundled locations - include both debug and release builds for development
    // Windows: app/build/windows/x64/runner/Debug/ - 6 levels to project root
    // macOS: app/build/macos/Build/Products/Debug/vapourbox.app/Contents/MacOS - 9 levels to project root
    final bundledPaths = Platform.isWindows
        ? [
            '$exeDir\\vapourbox-worker$ext',
            // Development: go up from app/build/windows/x64/runner/Debug to project root
            '$exeDir\\..\\..\\..\\..\\..\\..\\worker\\target\\release\\vapourbox-worker$ext',
            '$exeDir\\..\\..\\..\\..\\..\\..\\worker\\target\\debug\\vapourbox-worker$ext',
          ]
        : [
            // Production: worker is next to main executable in Contents/MacOS
            '$exeDir/vapourbox-worker',
            // Development: go up from app/build/macos/Build/Products/Debug/vapourbox.app/Contents/MacOS to project root (9 levels)
            '$exeDir/../../../../../../../../../worker/target/release/vapourbox-worker',
            '$exeDir/../../../../../../../../../worker/target/debug/vapourbox-worker',
          ];

    for (final p in bundledPaths) {
      if (await File(p).exists()) {
        return p;
      }
    }

    return null;
  }

  /// Load a video and extract thumbnails for the scrubber.
  Future<List<Uint8List>> loadVideo(String videoPath, {int thumbnailCount = 20}) async {
    if (_ffmpegPath == null || _ffprobePath == null) {
      throw Exception('FFmpeg tools not found');
    }

    _currentVideoPath = videoPath;
    _thumbnailCache.clear();

    // Get video info
    await _probeVideo(videoPath);

    // Generate thumbnails
    return await _extractThumbnails(videoPath, thumbnailCount);
  }

  /// Load thumbnails for a specific time range of the video.
  ///
  /// Used for zoomed timeline views where we want higher density thumbnails
  /// for a portion of the video.
  Future<List<Uint8List>> loadVideoRange({
    required String videoPath,
    required double startTime,
    required double endTime,
    required int thumbnailCount,
  }) async {
    if (_ffmpegPath == null || _ffprobePath == null) {
      throw Exception('FFmpeg tools not found');
    }

    // Ensure video info is loaded
    if (_currentVideoPath != videoPath) {
      _currentVideoPath = videoPath;
      await _probeVideo(videoPath);
    }

    // Extract thumbnails for the specified range
    return await _extractThumbnailsForRange(
      videoPath,
      startTime,
      endTime,
      thumbnailCount,
    );
  }

  Future<List<Uint8List>> _extractThumbnailsForRange(
    String videoPath,
    double startTime,
    double endTime,
    int count,
  ) async {
    final thumbnails = <Uint8List>[];
    final duration = endTime - startTime;
    final interval = duration / count;

    // Use ffmpeg to extract thumbnails in parallel
    final futures = <Future<Uint8List?>>[];

    for (var i = 0; i < count; i++) {
      final time = startTime + i * interval;
      futures.add(_extractSingleThumbnail(videoPath, time, i));
    }

    final results = await Future.wait(futures);

    for (final result in results) {
      if (result != null) {
        thumbnails.add(result);
      }
    }

    return thumbnails;
  }

  /// Get a single frame at a specific time position.
  Future<Uint8List?> getFrameAt(double timeSeconds) async {
    if (_currentVideoPath == null || _ffmpegPath == null) return null;

    final frameIndex = (timeSeconds * _frameRate).round();

    // Check cache
    if (_thumbnailCache.containsKey(frameIndex)) {
      return _thumbnailCache[frameIndex];
    }

    // Extract frame
    final outputPath = '$_tempDir/frame_${frameIndex}.jpg';

    try {
      final result = await Process.run(
        _ffmpegPath!,
        [
          '-y',
          '-ss', timeSeconds.toStringAsFixed(3),
          '-i', _currentVideoPath!,
          '-vframes', '1',
          '-q:v', '2',
          outputPath,
        ],
      );

      if (result.exitCode == 0 && await File(outputPath).exists()) {
        final bytes = await File(outputPath).readAsBytes();
        _thumbnailCache[frameIndex] = bytes;
        return bytes;
      }
    } catch (e) {
      // Ignore errors
    }

    return null;
  }

  /// Generate a processed preview frame at the specified time.
  ///
  /// This runs the full restoration pipeline via the worker and returns
  /// the processed frame. Uses the same code path as actual video processing
  /// to ensure preview matches the final output.
  Future<Uint8List?> generateProcessedPreview({
    required double timeSeconds,
    required RestorationPipeline pipeline,
    required FieldOrder fieldOrder,
    CancelToken? cancelToken,
  }) async {
    if (_currentVideoPath == null || _workerPath == null) {
      return null;
    }

    // Cancel any existing preview generation
    await cancelPreviewGeneration();

    if (cancelToken?.isCancelled ?? false) return null;

    // Calculate frame number in the SOURCE video (not output)
    // We no longer double for FPSDivisor=1 because we're seeking in the source
    final frameNumber = (timeSeconds * _frameRate).round();
    final configPath = '$_tempDir/preview_config_${DateTime.now().millisecondsSinceEpoch}.json';

    try {
      // Set TFF based on field order for QTGMC
      final tff = fieldOrder == FieldOrder.topFieldFirst;
      final deinterlaceWithTff = pipeline.deinterlace.copyWith(tff: tff);
      final pipelineWithTff = pipeline.copyWith(deinterlace: deinterlaceWithTff);

      // Create a job config for the worker
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: _currentVideoPath!,
        outputPath: '$_tempDir/preview_output.avi', // Not used in preview mode
        qtgmcParameters: deinterlaceWithTff,
        restorationPipeline: pipelineWithTff,
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.avi,
        ),
        detectedFieldOrder: fieldOrder,
        inputFrameRate: _frameRate,
      );

      // Write job config to file
      final configJson = jsonEncode(job.toJson());
      await File(configPath).writeAsString(configJson);

      if (cancelToken?.isCancelled ?? false) return null;

      // Clear log for this preview generation
      _previewLog.clear();
      _lastError = null;
      _previewLog.add('[${DateTime.now().toIso8601String()}] Starting preview generation for frame $frameNumber');

      // Run worker in preview mode
      // Use local variable to avoid race conditions when another preview request cancels this one
      // Set workingDirectory to the worker's parent directory so relative deps paths resolve correctly
      final process = await Process.start(
        _workerPath!,
        [
          '--config', configPath,
          '--preview',
          '--frame', frameNumber.toString(),
        ],
        workingDirectory: path.dirname(_workerPath!),
      );
      _previewProcess = process;

      if (cancelToken?.isCancelled ?? false) {
        process.kill();
        _previewProcess = null;
        return null;
      }

      // Collect PNG output from stdout and capture stderr for logging
      final pngBytes = <int>[];
      final stderrBuffer = StringBuffer();

      // Listen to stderr asynchronously (use local variable to avoid race conditions)
      final stderrFuture = process.stderr
          .transform(utf8.decoder)
          .forEach((data) {
        stderrBuffer.write(data);
        // Add each line to the log
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            _previewLog.add(line);
          }
        }
      });

      await for (final chunk in process.stdout) {
        if (cancelToken?.isCancelled ?? false) {
          process.kill();
          _previewProcess = null;
          return null;
        }
        pngBytes.addAll(chunk);
      }

      // Wait for stderr to finish
      await stderrFuture;

      // Wait for process to complete (use local variable to avoid race conditions)
      final exitCode = await process.exitCode;
      _previewProcess = null;

      // Log the result
      _previewLog.add('[${DateTime.now().toIso8601String()}] Process exited with code $exitCode, output size: ${pngBytes.length} bytes');

      // Clean up config file
      await File(configPath).delete().catchError((_) => File(configPath));

      if (cancelToken?.isCancelled ?? false) return null;

      if (exitCode == 0 && pngBytes.isNotEmpty) {
        return Uint8List.fromList(pngBytes);
      } else if (exitCode != 0) {
        _lastError = 'Preview generation failed (exit code $exitCode)';
        if (stderrBuffer.isNotEmpty) {
          _lastError = '$_lastError:\n$stderrBuffer';
        }
      }
    } catch (e) {
      _lastError = 'Preview generation error: $e';
      _previewLog.add('[ERROR] $e');
    } finally {
      _previewProcess = null;
      // Clean up config file on error
      try {
        await File(configPath).delete();
      } catch (_) {}
    }

    return null;
  }

  /// Cancel any ongoing preview generation.
  Future<void> cancelPreviewGeneration() async {
    if (_previewProcess != null) {
      _previewProcess!.kill();
      _previewProcess = null;
    }
    if (_thumbnailProcess != null) {
      _thumbnailProcess!.kill();
      _thumbnailProcess = null;
    }
  }

  /// Clean up resources.
  Future<void> dispose() async {
    await cancelPreviewGeneration();
    _thumbnailCache.clear();

    // Clean up temp directory
    if (_tempDir != null) {
      try {
        await Directory(_tempDir!).delete(recursive: true);
      } catch (e) {
        // Ignore cleanup errors
      }
    }
  }

  Future<void> _probeVideo(String videoPath) async {
    final result = await Process.run(
      _ffprobePath!,
      [
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_streams',
        '-show_format',
        '-select_streams', 'v:0',
        videoPath,
      ],
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to probe video');
    }

    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final streams = json['streams'] as List<dynamic>?;
    final format = json['format'] as Map<String, dynamic>?;

    if (streams == null || streams.isEmpty) {
      throw Exception('No video stream found');
    }

    final videoStream = streams[0] as Map<String, dynamic>;

    // Parse duration
    _duration = double.tryParse(format?['duration']?.toString() ?? '') ?? 0;

    // Parse frame rate
    final rFrameRate = videoStream['r_frame_rate'] as String?;
    if (rFrameRate != null) {
      final parts = rFrameRate.split('/');
      if (parts.length == 2) {
        final num = double.tryParse(parts[0]);
        final den = double.tryParse(parts[1]);
        if (num != null && den != null && den != 0) {
          _frameRate = num / den;
        }
      }
    }

    // Parse frame count
    _totalFrames = int.tryParse(videoStream['nb_frames']?.toString() ?? '') ??
        (_duration * _frameRate).round();
  }

  Future<List<Uint8List>> _extractThumbnails(String videoPath, int count) async {
    final thumbnails = <Uint8List>[];
    final interval = _duration / count;

    // Use ffmpeg to extract thumbnails in parallel batches
    final futures = <Future<Uint8List?>>[];

    for (var i = 0; i < count; i++) {
      final time = i * interval;
      futures.add(_extractSingleThumbnail(videoPath, time, i));
    }

    final results = await Future.wait(futures);

    for (final result in results) {
      if (result != null) {
        thumbnails.add(result);
      }
    }

    return thumbnails;
  }

  Future<Uint8List?> _extractSingleThumbnail(String videoPath, double time, int index) async {
    final outputPath = '$_tempDir/thumb_$index.jpg';

    try {
      final result = await Process.run(
        _ffmpegPath!,
        [
          '-y',
          '-ss', time.toStringAsFixed(3),
          '-i', videoPath,
          '-vframes', '1',
          '-vf', 'scale=160:-1',
          '-q:v', '5',
          outputPath,
        ],
      );

      if (result.exitCode == 0 && await File(outputPath).exists()) {
        return await File(outputPath).readAsBytes();
      }
    } catch (e) {
      // Ignore errors
    }

    return null;
  }

  Future<String?> _findTool(String name) async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final ext = Platform.isWindows ? '.exe' : '';
    final platformDir = _getPlatformSuffix();

    // Check bundled locations (platform-specific subdirectory)
    final home = Platform.environment['HOME'] ?? '';
    final List<String> bundledPaths;

    if (Platform.isWindows) {
      bundledPaths = [
        '$exeDir\\deps\\$platformDir\\ffmpeg\\$name$ext',
        '$exeDir\\deps\\$platformDir\\vapoursynth\\$name$ext',
        // VSPipe is capitalized on Windows
        '$exeDir\\deps\\$platformDir\\vapoursynth\\VSPipe$ext',
      ];
    } else {
      bundledPaths = [
        // Development only: relative paths to project root
        if (kDebugMode) ...[
          '$exeDir/../../../../../../../../../deps/$platformDir/ffmpeg/$name',
          '$exeDir/../../../../../../../../../deps/$platformDir/vapoursynth/$name',
        ],
        // Application Support (where downloaded deps go on macOS)
        '$home/Library/Application Support/VapourBox/deps/$platformDir/ffmpeg/$name',
        '$home/Library/Application Support/VapourBox/deps/$platformDir/vapoursynth/$name',
      ];
    }

    for (final p in bundledPaths) {
      if (await File(p).exists()) {
        return p;
      }
    }

    // Try system PATH
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [name],
      );
      if (result.exitCode == 0) {
        return (result.stdout as String).trim().split('\n').first;
      }
    } catch (e) {
      // Ignore
    }

    return null;
  }

  /// Get the platform suffix for the deps directory (e.g., "windows-x64", "macos-arm64").
  String _getPlatformSuffix() {
    if (Platform.isWindows) {
      return 'windows-x64'; // TODO: detect ARM64 when Flutter supports it
    } else if (Platform.isMacOS) {
      // Detect ARM64 vs x64 on macOS
      return Platform.version.contains('arm64') ? 'macos-arm64' : 'macos-x64';
    }
    return 'unknown';
  }
}

/// Token for cancelling preview generation.
class CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}
