import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../models/encoding_settings.dart';
import '../models/processing_pipeline.dart';
import '../models/video_job.dart';
import 'field_order_detector.dart';
import 'temp_directory_service.dart';
import 'process_tree.dart';
import 'tool_locator.dart';

/// Service for generating video thumbnails and processed previews.
class PreviewGenerator {
  Process? _thumbnailProcess;
  Process? _previewProcess;

  /// Every preview worker still running, including ones already superseded.
  ///
  /// `_previewProcess` alone is not enough to guarantee cleanup. It is assigned
  /// *after* `await Process.start(...)` returns, so a seek that arrives inside
  /// that window cancels whatever the field held at the time — not the process
  /// currently being spawned — and the next assignment then overwrites the
  /// reference to it. That process is never tracked and never killed. Scrubbing
  /// the timeline cancels a preview on every move, so those strays accumulate,
  /// which is what "a bunch of vspipe and ffmpeg processes" looks like.
  ///
  /// Registering at spawn and discarding on exit closes that window: a process
  /// is reachable for cancellation from the moment it exists.
  final Set<Process> _livePreviews = {};
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

  /// Video dimensions and pixel format (for pipe source).
  int _videoWidth = 0;
  int _videoHeight = 0;
  String _pixelFormat = 'yuv420p';

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
    final toolLocator = ToolLocator.instance;
    _ffmpegPath = toolLocator.ffmpegPath;
    _ffprobePath = toolLocator.ffprobePath;
    _workerPath = toolLocator.workerPath;

    // Create temp directory for thumbnails and previews
    final tempRoot = await TempDirectoryService.instance.resolve();
    _tempDir =
        '${tempRoot.path}/vapourbox_preview_${DateTime.now().millisecondsSinceEpoch}';
    await Directory(_tempDir!).create(recursive: true);
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

  /// Get the unprocessed source frame at an exact frame index.
  ///
  /// Frame-accurate: seeks to the midpoint of the interval *before* the target
  /// frame ((index - 0.5)/fps) so the first decoded frame (PTS >= seek time) is
  /// exactly `frameIndex`. This matches the worker's preview seek, so the
  /// before/after comparison always shows the same source frame.
  Future<Uint8List?> getFrameAtIndex(int frameIndex) async {
    if (_currentVideoPath == null || _ffmpegPath == null) return null;

    final frame = frameIndex < 0 ? 0 : frameIndex;

    // Check cache
    if (_thumbnailCache.containsKey(frame)) {
      return _thumbnailCache[frame];
    }

    // Extract frame
    final outputPath = '$_tempDir/frame_$frame.jpg';
    final seekTime = ((frame - 0.5) / _frameRate);
    final ss = seekTime < 0 ? 0.0 : seekTime;

    try {
      final result = await Process.run(
        _ffmpegPath!,
        [
          '-y',
          '-ss', ss.toStringAsFixed(6),
          '-i', _currentVideoPath!,
          '-frames:v', '1',
          '-q:v', '2',
          outputPath,
        ],
      );

      if (result.exitCode == 0 && await File(outputPath).exists()) {
        final bytes = await File(outputPath).readAsBytes();
        _thumbnailCache[frame] = bytes;
        return bytes;
      }
    } catch (e) {
      // Ignore errors
    }

    return null;
  }

  /// Generate a processed preview frame at the specified time.
  ///
  /// This runs the full processing pipeline via the worker and returns
  /// the processed frame. Uses the same code path as actual video processing
  /// to ensure preview matches the final output.
  Future<Uint8List?> generateProcessedPreview({
    required int frameNumber,
    required ProcessingPipeline pipeline,
    required FieldOrder fieldOrder,
    required EncodingSettings encodingSettings,
    CancelToken? cancelToken,
  }) async {
    if (_currentVideoPath == null || _workerPath == null) {
      return null;
    }

    // Dimensions come from the ffprobe pass in loadVideo(). If they aren't
    // populated yet (probe still running — e.g. a slow first-run Gatekeeper
    // assessment of freshly-downloaded ffprobe — or the probe failed), skip
    // rather than spawning the worker with a 0x0 job, which fails with a
    // misleading "Invalid video dimensions" error. The preview is requested
    // again once the video is probed, so this self-heals.
    if (_videoWidth <= 0 || _videoHeight <= 0) {
      return null;
    }

    // Cancel any existing preview generation
    await cancelPreviewGeneration();

    if (cancelToken?.isCancelled ?? false) return null;

    // `frameNumber` is the SOURCE frame index, passed straight to the worker
    // (no time round-trip). The worker decodes a window centred on it and emits
    // the exact output frame it maps to — see generate_preview in the worker.
    final frame = frameNumber < 0 ? 0 : frameNumber;
    final configPath = '$_tempDir/preview_config_${DateTime.now().millisecondsSinceEpoch}.json';
    Process? process;

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
        processingPipeline: pipelineWithTff,
        encodingSettings: encodingSettings,
        detectedFieldOrder: fieldOrder,
        inputFrameRate: _frameRate,
        totalFrames: _totalFrames,
        inputWidth: _videoWidth,
        inputHeight: _videoHeight,
        inputPixelFormat: _pixelFormat,
      );

      // Write job config to file
      final configJson = jsonEncode(job.toJson());
      await File(configPath).writeAsString(configJson);

      if (cancelToken?.isCancelled ?? false) return null;

      // Clear log for this preview generation
      _previewLog.clear();
      _lastError = null;
      _previewLog.add('[${DateTime.now().toIso8601String()}] Starting preview generation for frame $frame');

      // Run worker in preview mode
      // Use local variable to avoid race conditions when another preview request cancels this one
      // Set workingDirectory to the worker's parent directory so relative deps paths resolve correctly
      process = await Process.start(
        _workerPath!,
        [
          '--config', configPath,
          '--preview',
          '--frame', frame.toString(),
        ],
        environment: ToolLocator.instance.workerEnvironment,
        workingDirectory: path.dirname(_workerPath!),
      );
      _previewProcess = process;
      _livePreviews.add(process);

      if (cancelToken?.isCancelled ?? false) {
        // Whole group: killing the worker alone strands vspipe/ffmpeg.
        ProcessTree.killTree(process);
        _previewProcess = null;
        _livePreviews.remove(process);
        await ProcessTree.waitForExit(process);
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
          // Whole group: killing the worker alone strands vspipe/ffmpeg.
          ProcessTree.killTree(process);
          _previewProcess = null;
          _livePreviews.remove(process);
        _livePreviews.remove(process);
          await ProcessTree.waitForExit(process);
          return null;
        }
        pngBytes.addAll(chunk);
      }

      // Wait for stderr to finish
      await stderrFuture;

      // Wait for process to complete (use local variable to avoid race conditions)
      final exitCode = await process.exitCode;
      if (_previewProcess == process) {
        _previewProcess = null;
        _livePreviews.remove(process);
      }

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
      if (_previewProcess == process) {
        _previewProcess = null;
        _livePreviews.remove(process);
      }
      // Clean up config file on error
      try {
        await File(configPath).delete();
      } catch (_) {}
    }

    return null;
  }

  /// Cancel any ongoing preview generation.
  ///
  /// Seeking the scrubber cancels the in-flight preview on every move, so this
  /// runs far more often than a job cancel does — and anything it fails to clean
  /// up accumulates. Killing the worker's pid alone left `vspipe` and `ffmpeg`
  /// running: preview mode installs no signal handler (it returns before ctrlc
  /// is set up in `worker/src/main.rs`), so SIGTERM kills the worker outright
  /// without unwinding, and `generate_preview` holds its children in locals that
  /// `PipelineExecutor::terminate()` never sees. Nothing killed them
  /// deliberately; they just tended to die on EPIPE once their pipes closed,
  /// which does not happen while they are blocked reading a slow source.
  ///
  /// Signal the whole process group instead, and wait for the worker to actually
  /// go — a fire-and-forget kill cannot tell a clean shutdown from a stray.
  /// Signals every live preview and returns as soon as they have been told to
  /// stop — it does NOT wait for them to exit.
  ///
  /// A seek calls this before starting the next preview, so blocking here would
  /// add the full shutdown grace to every scrubber movement and make seeking
  /// feel broken. Signalling is immediate and ordered; reaping is not, so it
  /// runs unawaited. Use [awaitPreviewShutdown] when the wait actually matters.
  Future<void> cancelPreviewGeneration() async {
    final doomed = <Process>{
      ..._livePreviews,
      if (_previewProcess != null) _previewProcess!,
      if (_thumbnailProcess != null) _thumbnailProcess!,
    };
    _livePreviews.clear();
    _previewProcess = null;
    _thumbnailProcess = null;

    for (final p in doomed) {
      // The whole group: signalling the worker alone strands vspipe/ffmpeg,
      // and preview mode has no handler that would clean up after itself.
      ProcessTree.killTree(p);
      // Reap in the background so a slow shutdown cannot stall the next seek.
      unawaited(ProcessTree.waitForExit(p));
    }
  }

  /// Cancel and wait for everything to actually be gone.
  ///
  /// For shutdown, where leaving strays behind is worse than a brief pause.
  Future<void> awaitPreviewShutdown() async {
    final doomed = <Process>{
      ..._livePreviews,
      if (_previewProcess != null) _previewProcess!,
      if (_thumbnailProcess != null) _thumbnailProcess!,
    };
    await cancelPreviewGeneration();
    await Future.wait(doomed.map(ProcessTree.waitForExit));
  }

  /// Clean up resources.
  Future<void> dispose() async {
    // Shutdown is the one place the wait is worth it: strays outlive the app.
    await awaitPreviewShutdown();
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

    // Parse frame rate. Prefer the picture rate (avg_frame_rate) over the
    // field/base rate (r_frame_rate) for field-coded interlaced sources — see
    // FieldOrderDetector.selectFrameRate (issue #13).
    final rFrameRate = _parseRational(videoStream['r_frame_rate'] as String?);
    final avgFrameRate = _parseRational(videoStream['avg_frame_rate'] as String?);
    final selected = FieldOrderDetector.selectFrameRate(rFrameRate, avgFrameRate);
    if (selected != null && selected > 0) {
      _frameRate = selected;
    }

    // Parse frame count
    _totalFrames = int.tryParse(videoStream['nb_frames']?.toString() ?? '') ??
        (_duration * _frameRate).round();

    // Parse video dimensions and pixel format
    _videoWidth = videoStream['width'] as int? ?? 0;
    _videoHeight = videoStream['height'] as int? ?? 0;
    _pixelFormat = videoStream['pix_fmt'] as String? ?? 'yuv420p';
  }

  /// Parses an ffprobe rational frame-rate string (e.g. "25/1") to a double.
  /// Returns null for null/"0/0"/unparseable input.
  double? _parseRational(String? rateStr) {
    if (rateStr == null) return null;
    final parts = rateStr.split('/');
    if (parts.length == 2) {
      final num = double.tryParse(parts[0]);
      final den = double.tryParse(parts[1]);
      if (num != null && den != null && den != 0) {
        return num / den;
      }
      return null;
    }
    return double.tryParse(rateStr);
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

}

/// Token for cancelling preview generation.
class CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}
