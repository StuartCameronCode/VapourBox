import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../models/encoding_settings.dart';
import '../models/progress_info.dart';
import '../models/qtgmc_parameters.dart';
import '../models/restoration_pipeline.dart';
import '../models/video_job.dart';
import '../services/field_order_detector.dart';
import '../services/preview_generator.dart';
import '../services/worker_manager.dart';

/// Main view model managing application state.
class MainViewModel extends ChangeNotifier {
  final WorkerManager _workerManager = WorkerManager();
  final FieldOrderDetector _fieldOrderDetector = FieldOrderDetector();
  final PreviewGenerator _previewGenerator = PreviewGenerator();

  // Input state
  String? _inputPath;
  String? _outputPath;
  VideoInfo? _videoInfo;
  bool _isAnalyzing = false;

  // Processing state
  ProcessingState _state = ProcessingState.idle;
  ProgressInfo? _currentProgress;
  final List<LogMessage> _logMessages = [];

  // Settings
  QTGMCParameters _qtgmcParams = const QTGMCParameters();
  EncodingSettings _encodingSettings = const EncodingSettings();
  bool _autoFieldOrder = true;
  FieldOrder _manualFieldOrder = FieldOrder.topFieldFirst;

  // Restoration pipeline
  RestorationPipeline _restorationPipeline = const RestorationPipeline();
  PassType _selectedPass = PassType.deinterlace;
  bool _advancedMode = false;

  // Preview state
  List<Uint8List> _thumbnails = [];
  Uint8List? _currentFrame;
  Uint8List? _processedPreview;
  double _scrubberPosition = 0.0;
  bool _isGeneratingPreview = false;
  CancelToken? _previewCancelToken;
  Timer? _previewDebounceTimer;

  // Timeline zoom state
  double _timelineZoom = 1.0; // 1.0 = full view, 2.0 = 2x zoom, etc.
  double _timelineViewStart = 0.0; // 0.0 to 1.0, normalized start position
  Timer? _zoomDebounceTimer;
  bool _isLoadingZoomedThumbnails = false;

  // Subscriptions
  StreamSubscription<ProgressInfo>? _progressSub;
  StreamSubscription<LogMessage>? _logSub;
  StreamSubscription<CompletionResult>? _completionSub;

  // Getters
  String? get inputPath => _inputPath;
  String? get outputPath => _outputPath;
  VideoInfo? get videoInfo => _videoInfo;
  bool get isAnalyzing => _isAnalyzing;
  ProcessingState get state => _state;
  ProgressInfo? get currentProgress => _currentProgress;
  List<LogMessage> get logMessages => List.unmodifiable(_logMessages);
  QTGMCParameters get qtgmcParams => _qtgmcParams;
  EncodingSettings get encodingSettings => _encodingSettings;
  bool get autoFieldOrder => _autoFieldOrder;
  FieldOrder get manualFieldOrder => _manualFieldOrder;
  RestorationPipeline get restorationPipeline => _restorationPipeline;
  PassType get selectedPass => _selectedPass;
  bool get advancedMode => _advancedMode;

  // Preview getters
  List<Uint8List> get thumbnails => _thumbnails;
  Uint8List? get currentFrame => _currentFrame;
  Uint8List? get processedPreview => _processedPreview;
  double get scrubberPosition => _scrubberPosition;
  bool get isGeneratingPreview => _isGeneratingPreview;
  double get videoDuration => _previewGenerator.duration;
  List<String> get previewLog => _previewGenerator.previewLog;
  String? get previewError => _previewGenerator.lastError;

  // Timeline zoom getters
  double get timelineZoom => _timelineZoom;
  double get timelineViewStart => _timelineViewStart;
  double get timelineViewEnd =>
      (_timelineViewStart + 1.0 / _timelineZoom).clamp(0.0, 1.0);
  bool get isLoadingZoomedThumbnails => _isLoadingZoomedThumbnails;
  double get visibleStartTime => _timelineViewStart * videoDuration;
  double get visibleEndTime => timelineViewEnd * videoDuration;

  bool get canProcess =>
      _inputPath != null &&
      _outputPath != null &&
      _state == ProcessingState.idle;

  bool get isProcessing => _state.isActive;

  FieldOrder get effectiveFieldOrder {
    if (_autoFieldOrder && _videoInfo?.fieldOrder != null) {
      return _videoInfo!.fieldOrder!;
    }
    return _manualFieldOrder;
  }

  MainViewModel() {
    _setupSubscriptions();
    _initializePreviewGenerator();
  }

  Future<void> _initializePreviewGenerator() async {
    try {
      await _previewGenerator.initialize();
    } catch (e) {
      _logMessages.add(LogMessage(
        level: LogLevel.warning,
        message: 'Failed to initialize preview generator: $e',
      ));
    }
  }

  void _setupSubscriptions() {
    _progressSub = _workerManager.progressStream.listen((progress) {
      _currentProgress = progress;
      notifyListeners();
    });

    _logSub = _workerManager.logStream.listen((message) {
      _logMessages.add(message);
      // Keep last 1000 messages
      if (_logMessages.length > 1000) {
        _logMessages.removeRange(0, _logMessages.length - 1000);
      }
      notifyListeners();
    });

    _completionSub = _workerManager.completionStream.listen((result) {
      if (result.cancelled) {
        _state = ProcessingState.idle;
      } else if (result.success) {
        _state = ProcessingState.completed;
      } else {
        _state = ProcessingState.failed;
        _logMessages.add(LogMessage(
          level: LogLevel.error,
          message: result.errorMessage ?? 'Processing failed',
        ));
      }
      notifyListeners();
    });
  }

  /// Sets the input file and analyzes it.
  Future<void> setInputFile(String filePath) async {
    _inputPath = filePath;
    _videoInfo = null;
    _thumbnails = [];
    _currentFrame = null;
    _processedPreview = null;
    _scrubberPosition = 0.0;
    _isAnalyzing = true;
    notifyListeners();

    // Generate default output path
    final inputFile = File(filePath);
    final dir = inputFile.parent.path;
    final baseName = path.basenameWithoutExtension(filePath);
    final ext = _getOutputExtension();
    _outputPath = '$dir/${baseName}_deinterlaced$ext';

    // Analyze video
    try {
      _videoInfo = await _fieldOrderDetector.getVideoInfo(filePath);
    } catch (e) {
      _logMessages.add(LogMessage(
        level: LogLevel.warning,
        message: 'Failed to analyze video: $e',
      ));
    }

    // Load thumbnails for scrubber
    try {
      _thumbnails = await _previewGenerator.loadVideo(filePath);
      // Get initial frame
      _currentFrame = await _previewGenerator.getFrameAt(0);
    } catch (e) {
      _logMessages.add(LogMessage(
        level: LogLevel.warning,
        message: 'Failed to generate thumbnails: $e',
      ));
    }

    _isAnalyzing = false;
    notifyListeners();

    // Generate initial processed preview
    _requestPreviewUpdate();
  }

  /// Sets the output file path.
  void setOutputPath(String filePath) {
    _outputPath = filePath;
    notifyListeners();
  }

  /// Clears the current input.
  void clearInput() {
    _inputPath = null;
    _outputPath = null;
    _videoInfo = null;
    _currentProgress = null;
    _logMessages.clear();
    _state = ProcessingState.idle;
    _thumbnails = [];
    _currentFrame = null;
    _processedPreview = null;
    _scrubberPosition = 0.0;
    _cancelPreviewGeneration();
    notifyListeners();
  }

  /// Sets the scrubber position and updates the preview.
  Future<void> setScrubberPosition(double position) async {
    _scrubberPosition = position.clamp(0.0, 1.0);

    // Update current frame immediately
    final timeSeconds = _scrubberPosition * _previewGenerator.duration;
    _currentFrame = await _previewGenerator.getFrameAt(timeSeconds);
    notifyListeners();

    // Debounce the processed preview generation
    _requestPreviewUpdate();
  }

  /// Zooms in on the timeline, centering on the current scrubber position.
  void zoomIn() {
    if (_timelineZoom >= 16.0) return; // Max zoom 16x

    final oldZoom = _timelineZoom;
    _timelineZoom = (_timelineZoom * 1.5).clamp(1.0, 16.0);

    // Adjust view start to keep scrubber position centered
    _adjustViewForZoom(oldZoom);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Zooms out on the timeline.
  void zoomOut() {
    if (_timelineZoom <= 1.0) return;

    final oldZoom = _timelineZoom;
    _timelineZoom = (_timelineZoom / 1.5).clamp(1.0, 16.0);

    // Adjust view start to keep scrubber position centered
    _adjustViewForZoom(oldZoom);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Sets the timeline zoom level directly.
  void setTimelineZoom(double zoom) {
    final oldZoom = _timelineZoom;
    _timelineZoom = zoom.clamp(1.0, 16.0);
    _adjustViewForZoom(oldZoom);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Pans the timeline view.
  void panTimeline(double delta) {
    if (_timelineZoom <= 1.0) return;

    final maxStart = 1.0 - (1.0 / _timelineZoom);
    _timelineViewStart = (_timelineViewStart + delta).clamp(0.0, maxStart);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Adjusts the view start to keep the scrubber position stable during zoom.
  void _adjustViewForZoom(double oldZoom) {
    // Calculate the visible range width
    final newViewWidth = 1.0 / _timelineZoom;
    final maxStart = 1.0 - newViewWidth;

    // Try to center on the scrubber position
    final targetCenter = _scrubberPosition;
    _timelineViewStart = (targetCenter - newViewWidth / 2).clamp(0.0, maxStart);
  }

  /// Requests thumbnail regeneration with debouncing.
  void _requestThumbnailRegeneration() {
    _zoomDebounceTimer?.cancel();
    _zoomDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      _regenerateThumbnailsForZoom();
    });
  }

  /// Regenerates thumbnails for the current zoom level.
  Future<void> _regenerateThumbnailsForZoom() async {
    if (_inputPath == null) return;

    _isLoadingZoomedThumbnails = true;
    notifyListeners();

    try {
      _thumbnails = await _previewGenerator.loadVideoRange(
        videoPath: _inputPath!,
        startTime: visibleStartTime,
        endTime: visibleEndTime,
        thumbnailCount: 20,
      );
    } catch (e) {
      // Ignore errors
    }

    _isLoadingZoomedThumbnails = false;
    notifyListeners();
  }

  /// Resets the timeline zoom to 1x.
  void resetTimelineZoom() {
    _timelineZoom = 1.0;
    _timelineViewStart = 0.0;
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Requests a preview update with debouncing.
  void _requestPreviewUpdate() {
    _previewDebounceTimer?.cancel();
    _previewDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      _generateProcessedPreview();
    });
  }

  /// Generates the processed preview at the current scrubber position.
  Future<void> _generateProcessedPreview() async {
    if (_inputPath == null) return;

    // Cancel any existing preview generation
    _cancelPreviewGeneration();

    _isGeneratingPreview = true;
    notifyListeners();

    _previewCancelToken = CancelToken();
    final timeSeconds = _scrubberPosition * _previewGenerator.duration;

    try {
      final preview = await _previewGenerator.generateProcessedPreview(
        timeSeconds: timeSeconds,
        pipeline: _restorationPipeline,
        fieldOrder: effectiveFieldOrder,
        cancelToken: _previewCancelToken,
      );

      if (!(_previewCancelToken?.isCancelled ?? true)) {
        _processedPreview = preview;
      }
    } catch (e) {
      // Ignore errors from cancelled previews
    }

    _isGeneratingPreview = false;
    notifyListeners();
  }

  /// Cancels any ongoing preview generation.
  void _cancelPreviewGeneration() {
    _previewDebounceTimer?.cancel();
    _previewCancelToken?.cancel();
    _previewGenerator.cancelPreviewGeneration();
  }

  /// Updates QTGMC parameters.
  void updateQtgmcParams(QTGMCParameters params) {
    _qtgmcParams = params;
    notifyListeners();
    // Regenerate preview with new settings
    _requestPreviewUpdate();
  }

  /// Updates encoding settings.
  void updateEncodingSettings(EncodingSettings settings) {
    _encodingSettings = settings;
    // Update output extension if format changed
    if (_outputPath != null) {
      final dir = path.dirname(_outputPath!);
      final baseName = path.basenameWithoutExtension(_outputPath!);
      final ext = _getOutputExtension();
      _outputPath = '$dir/$baseName$ext';
    }
    notifyListeners();
  }

  /// Sets auto field order detection mode.
  void setAutoFieldOrder(bool auto) {
    _autoFieldOrder = auto;
    notifyListeners();
    // Regenerate preview with new field order
    _requestPreviewUpdate();
  }

  /// Sets manual field order.
  void setManualFieldOrder(FieldOrder fieldOrder) {
    _manualFieldOrder = fieldOrder;
    notifyListeners();
    // Regenerate preview with new field order
    _requestPreviewUpdate();
  }

  /// Updates the restoration pipeline.
  void updateRestorationPipeline(RestorationPipeline pipeline) {
    _restorationPipeline = pipeline;
    // Keep qtgmcParams in sync with deinterlace settings
    _qtgmcParams = pipeline.deinterlace;
    notifyListeners();
    _requestPreviewUpdate();
  }

  /// Toggles a pass on or off.
  void togglePass(PassType pass, bool enabled) {
    _restorationPipeline = _restorationPipeline.togglePass(pass, enabled);
    // Keep qtgmcParams in sync
    _qtgmcParams = _restorationPipeline.deinterlace;
    notifyListeners();
    _requestPreviewUpdate();
  }

  /// Selects a pass for editing.
  void selectPass(PassType pass) {
    _selectedPass = pass;
    notifyListeners();
  }

  /// Sets the advanced mode.
  void setAdvancedMode(bool advanced) {
    _advancedMode = advanced;
    notifyListeners();
  }

  /// Starts processing.
  Future<void> startProcessing() async {
    if (!canProcess) return;

    _state = ProcessingState.preparingJob;
    _currentProgress = null;
    _logMessages.clear();
    notifyListeners();

    // Build job configuration
    final job = VideoJob(
      id: const Uuid().v4(),
      inputPath: _inputPath!,
      outputPath: _outputPath!,
      qtgmcParameters: _qtgmcParams.copyWith(
        tff: effectiveFieldOrder == FieldOrder.topFieldFirst,
      ),
      restorationPipeline: _restorationPipeline.copyWith(
        deinterlace: _restorationPipeline.deinterlace.copyWith(
          tff: effectiveFieldOrder == FieldOrder.topFieldFirst,
        ),
      ),
      encodingSettings: _encodingSettings,
      totalFrames: _videoInfo?.frameCount,
    );

    try {
      _state = ProcessingState.processing;
      notifyListeners();

      await _workerManager.startJob(job);
    } catch (e) {
      _state = ProcessingState.failed;
      _logMessages.add(LogMessage(
        level: LogLevel.error,
        message: 'Failed to start processing: $e',
      ));
      notifyListeners();
    }
  }

  /// Cancels the current job.
  Future<void> cancelProcessing() async {
    if (!_state.canCancel) return;

    _state = ProcessingState.cancelling;
    notifyListeners();

    await _workerManager.cancel();
  }

  /// Resets after completion or failure.
  void reset() {
    _state = ProcessingState.idle;
    _currentProgress = null;
    notifyListeners();
  }

  String _getOutputExtension() {
    switch (_encodingSettings.container) {
      case ContainerFormat.mp4:
        return '.mp4';
      case ContainerFormat.mkv:
        return '.mkv';
      case ContainerFormat.mov:
        return '.mov';
      case ContainerFormat.avi:
        return '.avi';
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _logSub?.cancel();
    _completionSub?.cancel();
    _previewDebounceTimer?.cancel();
    _zoomDebounceTimer?.cancel();
    _workerManager.dispose();
    _previewGenerator.dispose();
    super.dispose();
  }
}
