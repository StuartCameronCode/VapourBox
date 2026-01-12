import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../models/qtgmc_parameters.dart';
import '../models/video_job.dart';

/// Service for generating video thumbnails and processed previews.
class PreviewGenerator {
  Process? _thumbnailProcess;
  Process? _previewProcess;
  String? _ffmpegPath;
  String? _ffprobePath;
  String? _vspipePath;
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

  double get duration => _duration;
  double get frameRate => _frameRate;
  int get totalFrames => _totalFrames;

  /// Initialize the preview generator with tool paths.
  Future<void> initialize() async {
    _ffmpegPath = await _findTool('ffmpeg');
    _ffprobePath = await _findTool('ffprobe');
    _vspipePath = await _findTool('vspipe');

    // Create temp directory for thumbnails and previews
    final systemTemp = Directory.systemTemp;
    _tempDir = '${systemTemp.path}/ideinterlace_preview_${DateTime.now().millisecondsSinceEpoch}';
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
  /// This runs the full QTGMC pipeline on a small segment around the
  /// specified time and returns the processed frame.
  Future<Uint8List?> generateProcessedPreview({
    required double timeSeconds,
    required QTGMCParameters qtgmcParams,
    required FieldOrder fieldOrder,
    CancelToken? cancelToken,
  }) async {
    if (_currentVideoPath == null || _vspipePath == null || _ffmpegPath == null) {
      return null;
    }

    // Cancel any existing preview generation
    await cancelPreviewGeneration();

    if (cancelToken?.isCancelled ?? false) return null;

    final frameNumber = (timeSeconds * _frameRate).round();
    final outputPath = '$_tempDir/preview_${DateTime.now().millisecondsSinceEpoch}.png';
    final scriptPath = '$_tempDir/preview_script.vpy';

    try {
      // Generate VapourSynth script for single frame extraction
      final script = _generatePreviewScript(
        inputPath: _currentVideoPath!,
        frameNumber: frameNumber,
        qtgmcParams: qtgmcParams,
        fieldOrder: fieldOrder,
      );

      await File(scriptPath).writeAsString(script);

      if (cancelToken?.isCancelled ?? false) return null;

      // Run vspipe to get the frame, pipe through ffmpeg to encode as PNG
      _previewProcess = await Process.start(
        _vspipePath!,
        [
          '--start', frameNumber.toString(),
          '--end', frameNumber.toString(),
          '--outputindex', '0',
          '-c', 'y4m',
          scriptPath,
          '-',
        ],
        environment: await _getEnvironment(),
      );

      if (cancelToken?.isCancelled ?? false) {
        _previewProcess?.kill();
        return null;
      }

      // Pipe to ffmpeg for PNG encoding
      final ffmpegProcess = await Process.start(
        _ffmpegPath!,
        [
          '-y',
          '-i', 'pipe:0',
          '-vframes', '1',
          '-f', 'image2',
          outputPath,
        ],
      );

      // Connect the pipes
      _previewProcess!.stdout.pipe(ffmpegProcess.stdin);

      // Wait for completion
      final results = await Future.wait([
        _previewProcess!.exitCode,
        ffmpegProcess.exitCode,
      ]);

      _previewProcess = null;

      if (cancelToken?.isCancelled ?? false) return null;

      if (results[0] == 0 && results[1] == 0 && await File(outputPath).exists()) {
        final bytes = await File(outputPath).readAsBytes();
        // Clean up
        await File(outputPath).delete().catchError((_) => File(outputPath));
        return bytes;
      }
    } catch (e) {
      // Ignore errors
    } finally {
      _previewProcess = null;
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

  String _generatePreviewScript({
    required String inputPath,
    required int frameNumber,
    required QTGMCParameters qtgmcParams,
    required FieldOrder fieldOrder,
  }) {
    final escapedPath = inputPath.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    final tff = fieldOrder == FieldOrder.topFieldFirst;

    return '''
import vapoursynth as vs
from vapoursynth import core
import havsfunc as haf

# Load video
clip = core.ffms2.Source(source=r'$escapedPath')

# Convert to YUV420P8 for QTGMC
clip = core.resize.Bicubic(clip, format=vs.YUV420P8)

# Apply QTGMC
clip = haf.QTGMC(
    clip,
    Preset="${qtgmcParams.preset.displayName}",
    TFF=$tff,
    FPSDivisor=${qtgmcParams.fpsDivisor},
    opencl=${qtgmcParams.opencl}
)

# Output single frame
clip.set_output()
''';
  }

  /// Get the platform suffix for the deps directory (e.g., "windows-x64", "macos-arm64").
  String _getPlatformSuffix() {
    if (Platform.isWindows) {
      return 'windows-x64'; // TODO: detect ARM64 when Flutter supports it
    } else if (Platform.isMacOS) {
      // Detect ARM64 vs x64 on macOS
      // Process.run returns the architecture
      return Platform.version.contains('arm64') ? 'macos-arm64' : 'macos-x64';
    }
    return 'unknown';
  }

  Future<String?> _findTool(String name) async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final ext = Platform.isWindows ? '.exe' : '';
    final platformDir = _getPlatformSuffix();

    // Check bundled locations (platform-specific subdirectory)
    final bundledPaths = Platform.isWindows
        ? [
            '$exeDir\\deps\\$platformDir\\ffmpeg\\$name$ext',
            '$exeDir\\deps\\$platformDir\\vapoursynth\\$name$ext',
            // VSPipe is capitalized on Windows
            '$exeDir\\deps\\$platformDir\\vapoursynth\\VSPipe$ext',
          ]
        : ['$exeDir/../Helpers/$name', '$exeDir/../Frameworks/bin/$name'];

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

  Future<Map<String, String>> _getEnvironment() async {
    final env = Map<String, String>.from(Platform.environment);
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final platformDir = _getPlatformSuffix();

    if (Platform.isWindows) {
      // Windows uses deps/{platform}/ structure with VapourSynth portable
      // Python 3.8 is bundled inside the VapourSynth directory
      final depsDir = '$exeDir\\deps\\$platformDir';
      final vsDir = '$depsDir\\vapoursynth';
      env['PYTHONHOME'] = vsDir;
      env['PYTHONPATH'] = '$vsDir\\Lib\\site-packages';
      env['PYTHONNOUSERSITE'] = '1';
      env['PATH'] = '$vsDir;$depsDir\\ffmpeg;${env['PATH'] ?? ''}';
      env['VAPOURSYNTH_PLUGIN_PATH'] = '$vsDir\\vs-plugins';
    } else if (Platform.isMacOS) {
      // macOS app bundle structure
      final contentsDir = '$exeDir/..';
      env['PYTHONHOME'] = '$contentsDir/Frameworks/Python.framework/Versions/Current';
      env['PYTHONPATH'] = '$contentsDir/Resources/PythonPackages';
      env['PYTHONNOUSERSITE'] = '1';
      env['VAPOURSYNTH_PLUGIN_PATH'] = '$contentsDir/Frameworks/VapourSynth';
      env['DYLD_LIBRARY_PATH'] = '$contentsDir/Frameworks';
      env['PATH'] = '$contentsDir/Helpers:${env['PATH'] ?? ''}';
    }

    return env;
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
