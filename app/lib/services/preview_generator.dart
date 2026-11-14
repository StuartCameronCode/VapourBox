import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../models/color_tags.dart';
import '../models/encoding_settings.dart';
import '../models/hdr_display.dart';
import '../models/preview_frame_info.dart';
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

  /// Input options (before `-i`) for every ffmpeg that shows the user the
  /// source picture: decode the full stored frame, ignoring container cropping
  /// (a QuickTime clean aperture, a Matroska PixelCrop). The worker decodes the
  /// same way (`worker/src/source_decode.rs`), so the "before" frame is the
  /// same picture — same width, same columns — as the processed "after", and
  /// the size ffprobe reports is the size shown. Left at ffmpeg's default, a
  /// 720x576 clean-aperture source would show 702 columns here and 720 there.
  static const sourceDecodeOptions = ['-apply_cropping', 'codec'];

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

  /// Seconds the video's first picture starts after the file's start (its
  /// sound starts first; see [VideoStart]). Every seek of the source adds it.
  double _videoStartOffset = 0;

  /// How seeks reach a frame on an MPEG-TS/PS (issue #169), null for every
  /// other format. See [SeekPlan].
  SeekPlan? _seekPlan;

  /// Video dimensions and pixel format (for pipe source).
  int _videoWidth = 0;
  int _videoHeight = 0;
  String _pixelFormat = 'yuv420p';

  /// Source colour tags, as ffprobe reports them (null when untagged). The
  /// preview job carries them so the worker converts the "after" frame with
  /// the source's real matrix and range — the "before" frame's ffmpeg reads
  /// them from the file — and, for an HDR source, tone-maps it the same way
  /// as the "before" frame and the timeline (issue #133).
  String? _colorMatrix;
  String? _colorPrimaries;
  String? _colorTransfer;
  String? _colorRange;

  /// Source sample aspect ratio ("16:15"), null for square pixels. Sent with
  /// the preview job so the script fits the frame by the same display aspect
  /// as the encode — without it `{{SOURCE_SAR}}` fell back to 1, and Square
  /// pixel aspect previewed a different frame from the one encoded (#149).
  String? _sar;

  /// The display tone-map for the loaded source, or null for SDR. Applied to
  /// every picture of the source the app draws itself.
  String? get _toneMap => HdrDisplay.toneMapFilter(
        matrix: _colorMatrix,
        primaries: _colorPrimaries,
        transfer: _colorTransfer,
        range: _colorRange,
      );

  /// Clears a colour tag FFmpeg's scaler refuses (`reserved`), or null when
  /// every tag is usable. See [ColorTags.decodeNeutraliser].
  String? get _tagFix => ColorTags.decodeNeutraliser(
        matrix: _colorMatrix,
        primaries: _colorPrimaries,
        transfer: _colorTransfer,
      );

  /// The ffmpeg arguments for one timeline thumbnail at [time] seconds on
  /// the video's own timeline (0 = its first picture). [videoStartOffset] is
  /// added because `-ss` counts from the file's start. [tagFix] precedes
  /// `scale`, which is the step that converts. On an MPEG-TS/PS, [seekPlan]
  /// seeks a GOP early and trims to the moment (issue #169): a plain seek
  /// there decodes from the next keyframe, and past the last one, nothing.
  static List<String> thumbnailArgs({
    required String videoPath,
    required double time,
    double videoStartOffset = 0,
    String? toneMap,
    String? tagFix,
    SeekPlan? seekPlan,
    required String outputPath,
  }) {
    final target = time + videoStartOffset;
    final planned = seekPlan == null ? null : SeekPlan.seekArgs(target, seekPlan);
    return [
      '-y',
      ...?planned?.input,
      if (planned == null) ...['-ss', target.toStringAsFixed(3)],
      ...sourceDecodeOptions,
      '-i', videoPath,
      '-vframes', '1',
      // Scaled first: tone-mapping a 4K frame in float costs far more
      // than the 160-pixel thumbnail it ends up as.
      '-vf', [
        if (tagFix != null) tagFix,
        if (planned?.trim != null) planned!.trim!,
        'scale=160:-1',
        if (toneMap != null) toneMap,
      ].join(','),
      '-q:v', '5',
      outputPath,
    ];
  }

  /// Log messages from preview generation (stderr output).
  final List<String> _previewLog = [];

  /// Last error message from preview generation.
  String? _lastError;

  /// What the last successful processed preview showed, as the worker
  /// reported it. Null until one has rendered, or after one failed.
  PreviewFrameInfo? _lastFrameInfo;

  double get duration => _duration;
  double get frameRate => _frameRate;
  int get totalFrames => _totalFrames;
  double get videoStartOffset => _videoStartOffset;
  SeekPlan? get seekPlan => _seekPlan;

  /// Get all preview log messages.
  List<String> get previewLog => List.unmodifiable(_previewLog);

  /// Get the last error message.
  String? get lastError => _lastError;

  /// See [_lastFrameInfo].
  PreviewFrameInfo? get lastFrameInfo => _lastFrameInfo;

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

  /// The ffmpeg arguments that write source frame [frameIndex] (the "before"
  /// picture) to [outputPath].
  ///
  /// Frame-accurate: seeks to the midpoint of the interval *before* the target
  /// frame ((index - 0.5)/fps) so the first decoded frame (PTS >= seek time) is
  /// exactly `frameIndex`. This matches the worker's preview seek
  /// (`source_decode::seek_time`), so the before/after comparison always shows
  /// the same source frame. Like it, frame 0 does not seek at all (a seek on
  /// an MPEG-TS drops an open GOP's leading pictures), and every other seek
  /// adds [videoStartOffset]: frame N counts from the video's first picture,
  /// while `-ss` counts from the file's start, which is the sound's on a
  /// broadcast capture (see [VideoStart]). An image
  /// output is written with passthrough timing, so unlike the worker's
  /// `rawvideo` decoders it needs no PTS reset after the seek (issue #157).
  ///
  /// On an MPEG-TS/PS, [seekPlan] seeks a GOP early with `-copyts` and drops
  /// to the frame with an absolute `trim` (issue #169): a plain seek there
  /// starts at the next keyframe. Twin of the worker's
  /// `source_decode::decoder_seek`; null leaves the arguments as they were.
  ///
  /// [tagFix] goes first in the one `-vf`: the JPEG/PNG encode converts the
  /// pixel format, which fails on a `reserved` tag. The trim follows it,
  /// ahead of the tone map, so dropped frames are never tone-mapped.
  ///
  /// `integration_seek_alignment_test.dart` and
  /// `integration_reserved_colour_tags_test.dart` run exactly these arguments
  /// (with a PNG [outputPath]), so keep every decode option here rather than at
  /// the call site.
  static List<String> beforeFrameArgs({
    required String videoPath,
    required int frameIndex,
    required double frameRate,
    double videoStartOffset = 0,
    String? toneMap,
    String? tagFix,
    SeekPlan? seekPlan,
    required String outputPath,
  }) {
    final frame = frameIndex < 0 ? 0 : frameIndex;
    final offset = videoStartOffset > 0 ? videoStartOffset : 0.0;
    final seek = frame > 0
        ? SeekPlan.seekArgs((frame - 0.5) / frameRate + offset, seekPlan)
        : null;
    final vf = [
      if (tagFix != null) tagFix,
      if (seek?.trim != null) seek!.trim!,
      if (toneMap != null) toneMap,
    ];
    return [
      '-y',
      ...?seek?.input,
      ...sourceDecodeOptions,
      '-i', videoPath,
      '-frames:v', '1',
      if (vf.isNotEmpty) ...['-vf', vf.join(',')],
      '-q:v', '2',
      outputPath,
    ];
  }

  /// Get the unprocessed source frame at an exact frame index — see
  /// [beforeFrameArgs].
  Future<Uint8List?> getFrameAtIndex(int frameIndex) async {
    if (_currentVideoPath == null || _ffmpegPath == null) return null;

    final frame = frameIndex < 0 ? 0 : frameIndex;

    // Check cache
    if (_thumbnailCache.containsKey(frame)) {
      return _thumbnailCache[frame];
    }

    // Extract frame
    final outputPath = '$_tempDir/frame_$frame.jpg';

    try {
      final result = await Process.run(
        _ffmpegPath!,
        beforeFrameArgs(
          videoPath: _currentVideoPath!,
          frameIndex: frame,
          frameRate: _frameRate,
          videoStartOffset: _videoStartOffset,
          toneMap: _toneMap,
          tagFix: _tagFix,
          seekPlan: _seekPlan,
          outputPath: outputPath,
        ),
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
    int subFrame = 0,
    int? startFrame,
    String? pitchFactorsPath,
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
        inputColorMatrix: _colorMatrix,
        inputColorPrimaries: _colorPrimaries,
        inputColorTransfer: _colorTransfer,
        inputColorRange: _colorRange,
        inputSar: _sar,
        // Not a trim: the worker's preview only uses it as the point the
        // encode's retime starts from, so a generated frame is previewed at
        // the moment the encode makes it.
        startFrame: startFrame,
        // The selected video's factor file for Stabilize's "From File" pitch
        // mode, so the preview corrects with the same factors as the encode.
        pitchFactorsPath: pitchFactorsPath,
      );

      // Write job config to file
      final configJson = jsonEncode(job.toJson());
      await File(configPath).writeAsString(configJson);

      if (cancelToken?.isCancelled ?? false) return null;

      // Clear log for this preview generation
      _previewLog.clear();
      _lastError = null;
      _lastFrameInfo = null;
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
          '--sub-frame', subFrame.toString(),
        ],
        environment: ToolLocator.instance.workerEnvironment,
        workingDirectory: path.dirname(_workerPath!),
      );
      _previewProcess = process;
      _livePreviews.add(process);

      if (cancelToken?.isCancelled ?? false) {
        // Whole tree: killing the worker alone strands vspipe/ffmpeg.
        await ProcessTree.killTree(process);
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
          await ProcessTree.killTree(process);
          _previewProcess = null;
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
        _lastFrameInfo = PreviewFrameInfo.parse(stderrBuffer.toString());
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
      await ProcessTree.killTree(p);
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

    // Where the video's first picture sits: frame N counts from it, so every
    // seek adds the offset (FieldOrderDetector's twin of the worker's probe).
    final videoStart = await FieldOrderDetector.probeVideoStart(
      _ffprobePath!,
      videoPath,
      streamStart: double.tryParse('${videoStream['start_time']}'),
      containerStart: double.tryParse('${format?['start_time']}'),
    );
    _videoStartOffset = videoStart.offset;

    // An MPEG-TS/PS has no keyframe index, so its seeks start a GOP early
    // and trim to the frame (the twin of the worker's seek plan, #169).
    _seekPlan = await FieldOrderDetector.probeSeekPlan(
      _ffprobePath!,
      videoPath,
      formatName: format?['format_name'] as String?,
    );

    // Parse frame count: the same length the job is built with, which for a
    // variable-frame-rate source is its duration, not its stored frames.
    final streamDuration =
        double.tryParse(videoStream['duration']?.toString() ?? '');
    _totalFrames = FieldOrderDetector.frameCountFor(
          storedFrames:
              int.tryParse(videoStream['nb_frames']?.toString() ?? ''),
          rFrameRate: rFrameRate,
          avgFrameRate: avgFrameRate,
          duration: streamDuration ?? _duration,
          frameRate: _frameRate,
        ) ??
        FieldOrderDetector.frameCountFromDuration(
          streamDuration: streamDuration,
          containerDuration: _duration,
          start: videoStart,
          frameRate: _frameRate,
        );

    // The timeline is the video's: with the sound starting first, the file's
    // duration includes time before the first picture, which no frame shows.
    if (_videoStartOffset > 0 && _frameRate > 0) {
      _duration = _totalFrames / _frameRate;
    }

    // Parse video dimensions and pixel format
    _videoWidth = videoStream['width'] as int? ?? 0;
    _videoHeight = videoStream['height'] as int? ?? 0;
    _pixelFormat = videoStream['pix_fmt'] as String? ?? 'yuv420p';

    _colorMatrix = colorTag(videoStream, 'color_space');
    _colorPrimaries = colorTag(videoStream, 'color_primaries');
    _colorTransfer = colorTag(videoStream, 'color_transfer');
    _colorRange = colorTag(videoStream, 'color_range');
    _sar = FieldOrderDetector.normalizeSar(
        videoStream['sample_aspect_ratio'] as String?);
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
        thumbnailArgs(
          videoPath: videoPath,
          time: time,
          videoStartOffset: _videoStartOffset,
          toneMap: _toneMap,
          tagFix: _tagFix,
          seekPlan: _seekPlan,
          outputPath: outputPath,
        ),
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
