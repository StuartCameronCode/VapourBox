import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../models/dvd_info.dart';
import '../models/dynamic_parameters.dart';
import '../models/encoding_settings.dart';
import '../models/parameter_converter.dart';
import '../models/progress_info.dart';
import '../models/qtgmc_parameters.dart';
import '../models/queue_item.dart';
import '../models/processing_pipeline.dart';
import '../models/subtitle_parameters.dart';
import '../models/video_job.dart';
import '../models/processing_preset.dart';
import '../services/disc_detector.dart';
import '../services/dvd_service.dart';
import '../services/field_order_detector.dart';
import '../services/frame_math.dart';
import '../services/preset_service.dart';
import '../services/preview_generator.dart';
import '../services/temp_directory_service.dart';
import '../services/worker_manager.dart';

/// Main view model managing application state.
class MainViewModel extends ChangeNotifier {
  final WorkerManager _workerManager = WorkerManager();
  final FieldOrderDetector _fieldOrderDetector = FieldOrderDetector();
  final PreviewGenerator _previewGenerator = PreviewGenerator();
  final DvdService _dvdService = DvdService();
  final DiscDetector _discDetector = DiscDetector();

  // Queue state (replaces single-video state)
  final List<QueueItem> _queue = [];
  String? _selectedItemId;
  bool _isQueueProcessing = false;
  int _currentProcessingIndex = -1;

  // Processing state
  ProcessingState _state = ProcessingState.idle;
  ProgressInfo? _currentProgress;
  final List<LogMessage> _logMessages = [];

  // Settings
  QTGMCParameters _qtgmcParams = const QTGMCParameters();
  EncodingSettings _encodingSettings = const EncodingSettings();
  bool _autoFieldOrder = true;
  FieldOrder _manualFieldOrder = FieldOrder.topFieldFirst;

  // Processing pipeline
  ProcessingPipeline _processingPipeline = const ProcessingPipeline();
  /// Pass whose settings are expanded inline in the pass list, or null when
  /// every pass is collapsed.
  PassType? _selectedPass = PassType.deinterlace;
  bool _advancedMode = false;

  // Scan-type auto-configuration of the deinterlace pipeline runs ONCE, for the
  // first file analyzed into an (otherwise empty) queue. Re-running it for every
  // subsequently dropped file would silently overwrite settings the user has
  // already configured for the queue (issue #12). Reset when the queue empties.
  bool _scanTypeAutoApplied = false;

  // Dynamic parameters for UI state (preserves null values for optional params)
  final Map<String, DynamicParameters> _dynamicParams = {};

  // Track whether the last completed job was subtitle-only
  bool _lastJobSubtitleOnly = false;

  // GPU capabilities probed once at startup via the worker. null = not yet
  // probed; true/false = result. `_openclAvailable` gates the QTGMC OpenCL
  // (NNEDI3CL) warning; `_knlmAvailable` gates the knlmeanscl-denoiser warning
  // (a distinct capability — KNLMeansCL can fail where NNEDI3CL succeeds).
  bool? _openclAvailable;
  bool? _knlmAvailable;

  // Set in dispose() so the async OpenCL probe doesn't notifyListeners() after
  // teardown (the top-level view model normally lives for the app's lifetime).
  bool _disposed = false;

  // Preview generation state (shared across queue items)
  bool _isGeneratingPreview = false;
  CancelToken? _previewCancelToken;
  Timer? _previewDebounceTimer;
  int _previewGeneration = 0;
  Timer? _zoomDebounceTimer;
  bool _isLoadingZoomedThumbnails = false;

  // Subscriptions
  StreamSubscription<ProgressInfo>? _progressSub;
  StreamSubscription<LogMessage>? _logSub;
  StreamSubscription<CompletionResult>? _completionSub;

  // Queue getters
  List<QueueItem> get queue => List.unmodifiable(_queue);
  String? get selectedItemId => _selectedItemId;
  QueueItem? get selectedItem =>
      _selectedItemId != null ? _queue.where((q) => q.id == _selectedItemId).firstOrNull : null;
  bool get isQueueProcessing => _isQueueProcessing;
  int get currentProcessingIndex => _currentProcessingIndex;
  /// Count of items that will be processed when Go is clicked.
  /// Includes ready, failed, completed, and cancelled items.
  int get queueReadyCount =>
      _queue.where((q) => q.canProcess || q.canReprocess).length;
  int get queueCompletedCount => _queue.where((q) => q.status == QueueItemStatus.completed).length;

  // Computed getters that delegate to selected item
  String? get inputPath => selectedItem?.inputPath;
  String? get outputPath => selectedItem?.outputPath;
  VideoInfo? get videoInfo => selectedItem?.videoInfo;
  bool get isExtracting =>
      _queue.any((q) => q.status == QueueItemStatus.extracting);
  bool get isAnalyzing =>
      selectedItem?.status == QueueItemStatus.analyzing ||
      _queue.any((q) => q.status == QueueItemStatus.analyzing);

  // State getters
  ProcessingState get state => _state;
  ProgressInfo? get currentProgress => _currentProgress;
  List<LogMessage> get logMessages => List.unmodifiable(_logMessages);
  QTGMCParameters get qtgmcParams => _qtgmcParams;
  EncodingSettings get encodingSettings => _encodingSettings;
  bool get autoFieldOrder => _autoFieldOrder;
  FieldOrder get manualFieldOrder => _manualFieldOrder;
  ProcessingPipeline get processingPipeline => _processingPipeline;
  PassType? get selectedPass => _selectedPass;
  bool get advancedMode => _advancedMode;

  /// Whether a usable OpenCL device was detected (gates the QTGMC OpenCL
  /// warning). null while the probe is still running.
  bool? get openclAvailable => _openclAvailable;

  /// Whether the knlmeanscl denoiser is usable here (gates its warning). null
  /// while the probe is still running.
  bool? get knlmAvailable => _knlmAvailable;

  /// Label for completion message — context-aware based on last job type.
  String get completionLabel {
    if (_lastJobSubtitleOnly) return 'Subtitles saved to:';
    return 'Output saved to:';
  }

  /// Get dynamic parameters for a filter (UI state).
  /// Returns cached params if available, otherwise converts from typed model.
  DynamicParameters getDynamicParams(String filterId) {
    if (_dynamicParams.containsKey(filterId)) {
      return _dynamicParams[filterId]!;
    }
    // Create from typed model on first access
    final params = _convertToParams(filterId);
    _dynamicParams[filterId] = params;
    return params;
  }

  /// Update dynamic parameters for a filter.
  void updateDynamicParams(String filterId, DynamicParameters params) {
    _dynamicParams[filterId] = params;
    // Also update the typed model in the pipeline
    _updatePipelineFromDynamic(filterId, params);
    // Subtitle output mode changes can affect output file extension
    if (filterId == 'subtitles') {
      _regenerateOutputPath();
    }
    notifyListeners();
    _requestPreviewUpdate();
  }

  DynamicParameters _convertToParams(String filterId) {
    switch (filterId) {
      case 'deinterlace':
        return ParameterConverter.fromQTGMC(_processingPipeline.deinterlace);
      case 'descratch':
        return ParameterConverter.fromDeScratch(_processingPipeline.descratch);
      case 'spotless':
        return ParameterConverter.fromSpotLess(_processingPipeline.spotless);
      case 'noise_reduction':
        return ParameterConverter.fromNoiseReduction(_processingPipeline.noiseReduction);
      case 'dehalo':
        return ParameterConverter.fromDehalo(_processingPipeline.dehalo);
      case 'deblock':
        return ParameterConverter.fromDeblock(_processingPipeline.deblock);
      case 'deband':
        return ParameterConverter.fromDeband(_processingPipeline.deband);
      case 'sharpen':
        return ParameterConverter.fromSharpen(_processingPipeline.sharpen);
      case 'color_correction':
        return ParameterConverter.fromColorCorrection(_processingPipeline.colorCorrection);
      case 'chroma_fixes':
        return ParameterConverter.fromChromaFixes(_processingPipeline.chromaFixes);
      case 'crop_resize':
        return ParameterConverter.fromCropResize(_processingPipeline.cropResize);
      case 'subtitles':
        return ParameterConverter.fromSubtitles(_processingPipeline.subtitles);
      default:
        return DynamicParameters(filterId: filterId);
    }
  }

  void _updatePipelineFromDynamic(String filterId, DynamicParameters params) {
    switch (filterId) {
      case 'deinterlace':
        _processingPipeline = _processingPipeline.copyWith(
          deinterlace: ParameterConverter.toQTGMC(params),
        );
        _qtgmcParams = _processingPipeline.deinterlace;
        break;
      case 'descratch':
        _processingPipeline = _processingPipeline.copyWith(
          descratch: ParameterConverter.toDeScratch(params),
        );
        break;
      case 'spotless':
        _processingPipeline = _processingPipeline.copyWith(
          spotless: ParameterConverter.toSpotLess(params),
        );
        break;
      case 'noise_reduction':
        _processingPipeline = _processingPipeline.copyWith(
          noiseReduction: ParameterConverter.toNoiseReduction(params),
        );
        break;
      case 'dehalo':
        _processingPipeline = _processingPipeline.copyWith(
          dehalo: ParameterConverter.toDehalo(params),
        );
        break;
      case 'deblock':
        _processingPipeline = _processingPipeline.copyWith(
          deblock: ParameterConverter.toDeblock(params),
        );
        break;
      case 'deband':
        _processingPipeline = _processingPipeline.copyWith(
          deband: ParameterConverter.toDeband(params),
        );
        break;
      case 'sharpen':
        _processingPipeline = _processingPipeline.copyWith(
          sharpen: ParameterConverter.toSharpen(params),
        );
        break;
      case 'color_correction':
        _processingPipeline = _processingPipeline.copyWith(
          colorCorrection: ParameterConverter.toColorCorrection(params),
        );
        break;
      case 'chroma_fixes':
        _processingPipeline = _processingPipeline.copyWith(
          chromaFixes: ParameterConverter.toChromaFixes(params),
        );
        break;
      case 'crop_resize':
        _processingPipeline = _processingPipeline.copyWith(
          cropResize: ParameterConverter.toCropResize(params),
        );
        break;
      case 'subtitles':
        _processingPipeline = _processingPipeline.copyWith(
          subtitles: ParameterConverter.toSubtitles(params),
        );
        break;
    }
  }

  // Preview getters (delegate to selected item)
  List<Uint8List> get thumbnails => selectedItem?.thumbnails ?? [];
  Uint8List? get currentFrame => selectedItem?.currentFrame;
  Uint8List? get processedPreview => selectedItem?.processedPreview;
  double get scrubberPosition => selectedItem?.scrubberPosition ?? 0.0;
  bool get isGeneratingPreview => _isGeneratingPreview;
  double get videoDuration => _previewGenerator.duration;
  List<String> get previewLog => _previewGenerator.previewLog;
  String? get previewError => _previewGenerator.lastError;

  /// Total number of source frames in the loaded video (0 if not loaded).
  int get totalFrames => _previewGenerator.totalFrames;

  /// The integer source frame the scrubber currently points at. This is the
  /// authoritative unit for the preview and step/jump controls — the normalized
  /// scrubberPosition is just the gesture representation.
  int get currentFrameIndex => _frameForPosition(scrubberPosition);

  /// Convert a normalized scrubber position (0.0-1.0) to a source frame index.
  int _frameForPosition(double position) =>
      FrameMath.frameForPosition(position, _previewGenerator.totalFrames);

  /// Convert a source frame index to a normalized scrubber position (0.0-1.0).
  double _positionForFrame(int frame) =>
      FrameMath.positionForFrame(frame, _previewGenerator.totalFrames);

  /// Seek to an exact source frame, clamped to the video's range.
  Future<void> seekToFrame(int frame) async {
    final total = _previewGenerator.totalFrames;
    final clamped = total > 0 ? frame.clamp(0, total - 1) : 0;
    await setScrubberPosition(_positionForFrame(clamped));
  }

  /// Step the scrubber by a signed number of frames (e.g. -1 / +1).
  Future<void> stepFrame(int delta) => seekToFrame(currentFrameIndex + delta);

  // Timeline zoom getters (delegate to selected item)
  double get timelineZoom => selectedItem?.timelineZoom ?? 1.0;
  double get timelineViewStart => selectedItem?.timelineViewStart ?? 0.0;
  double get timelineViewEnd => selectedItem?.timelineViewEnd ?? 1.0;
  bool get isLoadingZoomedThumbnails => _isLoadingZoomedThumbnails;
  double get visibleStartTime => timelineViewStart * videoDuration;
  double get visibleEndTime => timelineViewEnd * videoDuration;

  // In/out point getters (delegate to selected item)
  double? get inPoint => selectedItem?.inPoint;
  double? get outPoint => selectedItem?.outPoint;
  double get effectiveInPoint => selectedItem?.effectiveInPoint ?? 0.0;
  double get effectiveOutPoint => selectedItem?.effectiveOutPoint ?? 1.0;
  int? get inPointFrame => selectedItem?.inPointFrame;
  int? get outPointFrame => selectedItem?.outPointFrame;
  bool get hasInOutRange => selectedItem?.hasInOutRange ?? false;

  bool get canProcess =>
      _queue.isNotEmpty &&
      queueReadyCount > 0 &&
      _state == ProcessingState.idle;

  bool get isProcessing => _state.isActive;

  FieldOrder get effectiveFieldOrder {
    final item = selectedItem;
    if (_autoFieldOrder && item?.videoInfo?.fieldOrder != null) {
      return item!.videoInfo!.fieldOrder!;
    }
    return _manualFieldOrder;
  }

  MainViewModel() {
    _setupSubscriptions();
    _initializePreviewGenerator();
    _probeGpuCapabilities();
  }

  /// Probe GPU capabilities once at startup so the UI can warn when an
  /// OpenCL-only option is selected on a machine without a usable device.
  Future<void> _probeGpuCapabilities() async {
    final caps = await WorkerManager.probeGpuCapabilities();
    if (_disposed) return;
    _openclAvailable = caps.opencl;
    _knlmAvailable = caps.knlm;
    notifyListeners();
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
      if (_isQueueProcessing) {
        // Queue processing mode
        _handleQueueItemCompletion(result);
      } else {
        // Single video processing mode (legacy)
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
      }
    });
  }

  // ============================================================================
  // QUEUE MANAGEMENT
  // ============================================================================

  /// Adds a single video to the queue.
  Future<void> addToQueue(String filePath) async {
    await addMultipleToQueue([filePath]);
  }

  /// Adds multiple videos to the queue.
  Future<void> addMultipleToQueue(List<String> filePaths) async {
    if (filePaths.isEmpty) return;

    final newItems = <QueueItem>[];
    for (final filePath in filePaths) {
      // Skip if already in queue
      if (_queue.any((q) => q.inputPath == filePath)) continue;

      final outputPath = _generateOutputPath(filePath);
      final item = QueueItem(
        inputPath: filePath,
        outputPath: outputPath,
        status: QueueItemStatus.pending,
      );
      newItems.add(item);
      _queue.add(item);
    }

    // Select first new item if nothing selected
    if (_selectedItemId == null && newItems.isNotEmpty) {
      _selectedItemId = newItems.first.id;
    }

    notifyListeners();

    // Analyze all new items
    for (final item in newItems) {
      await _analyzeQueueItem(item);
    }
  }

  /// Analyzes a queue item (loads video info and thumbnails).
  Future<void> _analyzeQueueItem(QueueItem item) async {
    final index = _queue.indexWhere((q) => q.id == item.id);
    if (index == -1) return;

    _queue[index].status = QueueItemStatus.analyzing;
    notifyListeners();

    // Analyze video
    try {
      _queue[index].videoInfo = await _fieldOrderDetector.getVideoInfo(item.inputPath);
    } catch (e) {
      _logMessages.add(LogMessage(
        level: LogLevel.warning,
        message: 'Failed to analyze ${item.filename}: $e',
      ));
    }

    // Auto-switch deinterlace method based on detected scan type. Only do this
    // ONCE (for the first analyzed file) so that dropping additional files does
    // not silently overwrite the pipeline the user has already configured for
    // the queue (issue #12).
    final videoInfo = _queue[index].videoInfo;
    if (videoInfo != null && !_scanTypeAutoApplied) {
      DeinterlaceMethod? targetMethod;
      bool? targetEnabled;
      String? logMsg;

      switch (videoInfo.scanType) {
        case ScanType.softTelecine:
          targetMethod = DeinterlaceMethod.softTelecine;
          targetEnabled = true;
          logMsg = 'Soft telecine detected \u2014 switched to Soft Telecine';
          break;
        case ScanType.telecine:
          targetMethod = DeinterlaceMethod.ivtc;
          targetEnabled = true;
          logMsg = 'Hard telecine detected \u2014 switched to IVTC';
          break;
        case ScanType.interlaced:
          targetMethod = DeinterlaceMethod.qtgmc;
          targetEnabled = true;
          logMsg = 'Interlaced content detected \u2014 switched to QTGMC';
          break;
        case ScanType.progressive:
          targetEnabled = false;
          logMsg = 'Progressive content detected \u2014 deinterlacing disabled';
          break;
        case ScanType.unknown:
          targetMethod = DeinterlaceMethod.qtgmc;
          targetEnabled = true;
          logMsg = 'Scan type unknown \u2014 defaulting to QTGMC';
          break;
      }

      if (targetMethod != null || targetEnabled != null) {
        _processingPipeline = _processingPipeline.copyWith(
          deinterlace: _processingPipeline.deinterlace.copyWith(
            method: targetMethod ?? _processingPipeline.deinterlace.method,
            enabled: targetEnabled ?? _processingPipeline.deinterlace.enabled,
          ),
        );
        _qtgmcParams = _processingPipeline.deinterlace;
        // Auto-config has now been applied; later dropped files won't re-trigger
        // it and clobber the user's configuration (issue #12).
        _scanTypeAutoApplied = true;
        // Sync dynamic params cache and notify UI immediately
        _dynamicParams.remove('deinterlace');
        // Deinterlace toggle changes subtitle-only detection and output extension
        _regenerateOutputPath();
        _logMessages.add(LogMessage(
          level: LogLevel.info,
          message: logMsg!,
        ));
        notifyListeners();
      }
    }

    // Load thumbnails if this is the selected item
    if (_selectedItemId == item.id) {
      try {
        _queue[index].thumbnails = await _previewGenerator.loadVideo(item.inputPath);
        _queue[index].currentFrame = await _previewGenerator.getFrameAtIndex(0);
      } catch (e) {
        _logMessages.add(LogMessage(
          level: LogLevel.warning,
          message: 'Failed to generate thumbnails for ${item.filename}: $e',
        ));
      }
    }

    _queue[index].status = QueueItemStatus.ready;
    notifyListeners();

    // Generate initial processed preview if selected
    if (_selectedItemId == item.id) {
      _requestPreviewUpdate();
    }
  }

  /// Removes a video from the queue.
  void removeFromQueue(String itemId) {
    final index = _queue.indexWhere((q) => q.id == itemId);
    if (index == -1) return;

    // Don't remove if currently processing
    if (_queue[index].status == QueueItemStatus.processing) return;

    // Clean up DVD temp file when item leaves the queue
    _cleanupDvdTempFile(_queue[index]);

    _queue.removeAt(index);

    // Empty queue: allow scan-type auto-config to run again for the next file.
    if (_queue.isEmpty) {
      _scanTypeAutoApplied = false;
    }

    // Update selection if removed item was selected
    if (_selectedItemId == itemId) {
      if (_queue.isEmpty) {
        _selectedItemId = null;
        _cancelPreviewGeneration();
      } else {
        // Select next item or previous if at end
        final newIndex = index.clamp(0, _queue.length - 1);
        _selectedItemId = _queue[newIndex].id;
        _loadSelectedItemPreview();
      }
    }

    notifyListeners();
  }

  /// Selects a queue item for preview.
  Future<void> selectQueueItem(String itemId) async {
    if (_selectedItemId == itemId) return;

    final item = _queue.where((q) => q.id == itemId).firstOrNull;
    if (item == null) return;

    _selectedItemId = itemId;
    _cancelPreviewGeneration();
    notifyListeners();

    await _loadSelectedItemPreview();
  }

  /// Loads preview data for the selected item.
  Future<void> _loadSelectedItemPreview() async {
    final item = selectedItem;
    if (item == null) return;

    // Load thumbnails if not already loaded
    if (item.thumbnails.isEmpty && item.status != QueueItemStatus.analyzing) {
      try {
        item.thumbnails = await _previewGenerator.loadVideo(item.inputPath);
        item.currentFrame = await _previewGenerator.getFrameAtIndex(
          _frameForPosition(item.scrubberPosition),
        );
        notifyListeners();
      } catch (e) {
        _logMessages.add(LogMessage(
          level: LogLevel.warning,
          message: 'Failed to load thumbnails: $e',
        ));
      }
    } else if (item.thumbnails.isNotEmpty) {
      // Reload video in preview generator to sync duration
      try {
        await _previewGenerator.loadVideo(item.inputPath);
      } catch (e) {
        // Ignore errors
      }
    }

    _requestPreviewUpdate();
  }

  /// Clears all items from the queue.
  void clearQueue() {
    // Don't clear if processing
    if (_isQueueProcessing) return;

    // Clean up DVD temp files before clearing
    _cleanupDvdTempFiles();

    _queue.clear();
    _selectedItemId = null;
    _cancelPreviewGeneration();
    _state = ProcessingState.idle;
    // Empty queue: allow scan-type auto-config to run again for the next file.
    _scanTypeAutoApplied = false;
    notifyListeners();
  }

  /// Requeues a completed, failed, or cancelled item for reprocessing.
  void requeueItem(String itemId) {
    final item = _queue.where((q) => q.id == itemId).firstOrNull;
    if (item == null) return;

    // Only allow requeueing items that have finished processing
    if (item.status == QueueItemStatus.completed ||
        item.status == QueueItemStatus.failed ||
        item.status == QueueItemStatus.cancelled) {
      item.status = QueueItemStatus.ready;
      item.errorMessage = null;
      notifyListeners();
    }
  }

  /// Legacy method for compatibility - adds to queue instead.
  Future<void> setInputFile(String filePath) async {
    await addToQueue(filePath);
  }

  /// Sets the output file path for the selected item.
  void setOutputPath(String filePath) {
    final item = selectedItem;
    if (item == null) return;
    item.outputPath = filePath;
    notifyListeners();
  }

  /// Clears the current input (alias for clearQueue).
  void clearInput() {
    clearQueue();
  }

  /// Sets the scrubber position and updates the preview.
  Future<void> setScrubberPosition(double position) async {
    final item = selectedItem;
    if (item == null) return;

    item.scrubberPosition = position.clamp(0.0, 1.0);

    // Update the unprocessed source frame immediately, seeking to the exact
    // frame the scrubber maps to (same index the processed preview uses, so the
    // before/after comparison stays aligned).
    item.currentFrame =
        await _previewGenerator.getFrameAtIndex(_frameForPosition(item.scrubberPosition));
    notifyListeners();

    // Debounce the processed preview generation
    _requestPreviewUpdate();
  }

  /// Zooms in on the timeline, centering on the current scrubber position.
  void zoomIn() {
    zoomInAt(scrubberPosition);
  }

  /// Zooms in on the timeline, centering on the specified position.
  void zoomInAt(double centerPosition) {
    final item = selectedItem;
    if (item == null) return;
    if (item.timelineZoom >= 16.0) return; // Max zoom 16x

    item.timelineZoom = (item.timelineZoom * 1.5).clamp(1.0, 16.0);

    // Adjust view start to keep center position stable
    _adjustViewForZoomAt(centerPosition);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Zooms out on the timeline.
  void zoomOut() {
    zoomOutAt(scrubberPosition);
  }

  /// Zooms out on the timeline, centering on the specified position.
  void zoomOutAt(double centerPosition) {
    final item = selectedItem;
    if (item == null) return;
    if (item.timelineZoom <= 1.0) return;

    item.timelineZoom = (item.timelineZoom / 1.5).clamp(1.0, 16.0);

    // Adjust view start to keep center position stable
    _adjustViewForZoomAt(centerPosition);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Sets the timeline zoom level directly.
  void setTimelineZoom(double zoom) {
    final item = selectedItem;
    if (item == null) return;

    item.timelineZoom = zoom.clamp(1.0, 16.0);
    _adjustViewForZoomAt(item.scrubberPosition);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Pans the timeline view.
  void panTimeline(double delta) {
    final item = selectedItem;
    if (item == null) return;
    if (item.timelineZoom <= 1.0) return;

    final maxStart = 1.0 - (1.0 / item.timelineZoom);
    item.timelineViewStart = (item.timelineViewStart + delta).clamp(0.0, maxStart);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Adjusts the view start to keep the specified position stable during zoom.
  void _adjustViewForZoomAt(double centerPosition) {
    final item = selectedItem;
    if (item == null) return;

    // Calculate the visible range width
    final newViewWidth = 1.0 / item.timelineZoom;
    final maxStart = 1.0 - newViewWidth;

    // Try to center on the specified position
    item.timelineViewStart = (centerPosition - newViewWidth / 2).clamp(0.0, maxStart);
  }

  /// Sets the in point to the current scrubber position.
  void setInPointToCurrent() {
    final item = selectedItem;
    if (item == null) return;

    item.inPoint = item.scrubberPosition;
    // Ensure in point is before out point
    if (item.outPoint != null && item.inPoint! > item.outPoint!) {
      item.outPoint = null;
    }
    notifyListeners();
  }

  /// Sets the out point to the current scrubber position.
  void setOutPointToCurrent() {
    final item = selectedItem;
    if (item == null) return;

    item.outPoint = item.scrubberPosition;
    // Ensure out point is after in point
    if (item.inPoint != null && item.outPoint! < item.inPoint!) {
      item.inPoint = null;
    }
    notifyListeners();
  }

  /// Sets the in point directly (normalized 0.0-1.0).
  void setInPoint(double position) {
    final item = selectedItem;
    if (item == null) return;

    item.inPoint = position.clamp(0.0, 1.0);
    if (item.outPoint != null && item.inPoint! > item.outPoint!) {
      item.outPoint = null;
    }
    notifyListeners();
  }

  /// Sets the out point directly (normalized 0.0-1.0).
  void setOutPoint(double position) {
    final item = selectedItem;
    if (item == null) return;

    item.outPoint = position.clamp(0.0, 1.0);
    if (item.inPoint != null && item.outPoint! < item.inPoint!) {
      item.inPoint = null;
    }
    notifyListeners();
  }

  /// Clears both in and out points.
  void clearInOutPoints() {
    final item = selectedItem;
    if (item == null) return;

    item.inPoint = null;
    item.outPoint = null;
    notifyListeners();
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
    final item = selectedItem;
    if (item == null) return;

    _isLoadingZoomedThumbnails = true;
    notifyListeners();

    try {
      item.thumbnails = await _previewGenerator.loadVideoRange(
        videoPath: item.inputPath,
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
    final item = selectedItem;
    if (item == null) return;

    item.timelineZoom = 1.0;
    item.timelineViewStart = 0.0;
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
  ///
  /// Uses a generation counter to handle concurrent calls safely. The timer
  /// callback cannot await this async method, so multiple calls can overlap
  /// when filters are toggled rapidly. Only the most recent generation is
  /// allowed to update shared state (_isGeneratingPreview, processedPreview).
  Future<void> _generateProcessedPreview() async {
    final item = selectedItem;
    if (item == null) return;

    // Cancel any existing preview generation
    _cancelPreviewGeneration();

    final generation = ++_previewGeneration;

    _isGeneratingPreview = true;
    notifyListeners();

    final cancelToken = CancelToken();
    _previewCancelToken = cancelToken;
    final frameNumber = _frameForPosition(item.scrubberPosition);

    try {
      final preview = await _previewGenerator.generateProcessedPreview(
        frameNumber: frameNumber,
        pipeline: _processingPipeline,
        fieldOrder: effectiveFieldOrder,
        encodingSettings: _encodingSettings,
        cancelToken: cancelToken,
      );

      if (generation == _previewGeneration && !cancelToken.isCancelled) {
        item.processedPreview = preview;
      }
    } catch (e) {
      // Ignore errors from cancelled previews
    }

    // Only clear the generating flag if this is still the latest generation.
    // Otherwise a newer call is in flight and owns the flag.
    if (generation == _previewGeneration) {
      _isGeneratingPreview = false;
      notifyListeners();
    }
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
    final previous = _encodingSettings;
    _encodingSettings = settings;
    // Log audio setting changes so a recurrence of the "audio reverted to copy"
    // class of bug (issue #12) is diagnosable from a user's log.
    if (previous.audioMode != settings.audioMode ||
        previous.audioCodec != settings.audioCodec ||
        previous.audioQuality != settings.audioQuality) {
      _logMessages.add(LogMessage(
        level: LogLevel.info,
        message: 'Audio settings changed: '
            '${_audioSettingsSummary(previous)} -> '
            '${_audioSettingsSummary(settings)}',
      ));
    }
    // Regenerate output path with new settings
    _regenerateOutputPath();
    notifyListeners();
  }

  /// Human-readable one-line summary of the audio portion of [s], for logging.
  String _audioSettingsSummary(EncodingSettings s) {
    switch (s.audioMode) {
      case AudioMode.passthrough:
        return 'passthrough (copy original)';
      case AudioMode.none:
        return 'none (no audio)';
      case AudioMode.convert:
        final bitrate =
            s.audioCodec.isLossless ? '' : ' @ ${s.audioQuality.bitrate}kbps';
        return 'convert -> ${s.audioCodec.displayName}$bitrate';
    }
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

  /// Updates the processing pipeline.
  void updateProcessingPipeline(ProcessingPipeline pipeline) {
    _processingPipeline = pipeline;
    // Keep qtgmcParams in sync with deinterlace settings
    _qtgmcParams = pipeline.deinterlace;
    // Pipeline changes affect subtitle-only detection and output extension
    _regenerateOutputPath();
    notifyListeners();
    _requestPreviewUpdate();
  }

  /// Toggles a pass on or off.
  void togglePass(PassType pass, bool enabled) {
    _processingPipeline = _processingPipeline.togglePass(pass, enabled);
    // Keep qtgmcParams in sync
    _qtgmcParams = _processingPipeline.deinterlace;
    // Sync dynamic params cache with new enabled state
    final filterId = _passTypeToFilterId(pass);
    if (_dynamicParams.containsKey(filterId)) {
      _dynamicParams[filterId] = _dynamicParams[filterId]!.withEnabled(enabled);
    }
    // Regenerate output paths (subtitle-only changes the extension)
    _regenerateOutputPath();
    notifyListeners();
    _requestPreviewUpdate();
  }

  /// Convert PassType to filter ID.
  String _passTypeToFilterId(PassType pass) {
    switch (pass) {
      case PassType.deinterlace:
        return 'deinterlace';
      case PassType.descratch:
        return 'descratch';
      case PassType.spotless:
        return 'spotless';
      case PassType.noiseReduction:
        return 'noise_reduction';
      case PassType.dehalo:
        return 'dehalo';
      case PassType.deblock:
        return 'deblock';
      case PassType.deband:
        return 'deband';
      case PassType.sharpen:
        return 'sharpen';
      case PassType.colorCorrection:
        return 'color_correction';
      case PassType.chromaFixes:
        return 'chroma_fixes';
      case PassType.cropResize:
        return 'crop_resize';
      case PassType.subtitles:
        return 'subtitles';
    }
  }

  /// Expands a pass's settings inline, collapsing whichever was open. Selecting
  /// the pass that is already expanded collapses it.
  void selectPass(PassType pass) {
    _selectedPass = _selectedPass == pass ? null : pass;
    notifyListeners();
  }

  /// Sets the advanced mode.
  void setAdvancedMode(bool advanced) {
    _advancedMode = advanced;
    notifyListeners();
  }

  // ============================================================================
  // QUEUE PROCESSING
  // ============================================================================

  /// Starts processing all ready items in the queue.
  Future<void> startQueueProcessing() async {
    if (!canProcess || _isQueueProcessing) return;

    // Reset completed/cancelled items to ready so they get reprocessed
    for (final item in _queue) {
      if (item.canReprocess) {
        item.status = QueueItemStatus.ready;
        item.errorMessage = null;
      }
    }

    _isQueueProcessing = true;
    _currentProcessingIndex = -1;
    _logMessages.clear();
    notifyListeners();

    await _processNextItem();
  }

  /// Processes the next ready item in the queue.
  Future<void> _processNextItem() async {
    // Find next ready item (not failed — failed items require explicit retry)
    final nextIndex = _queue.indexWhere((q) => q.status == QueueItemStatus.ready);

    if (nextIndex == -1) {
      // No more items to process
      _isQueueProcessing = false;
      _currentProcessingIndex = -1;
      // Show failed state if any items failed, otherwise completed
      final hasFailed = _queue.any((q) => q.status == QueueItemStatus.failed);
      _state = hasFailed ? ProcessingState.failed : ProcessingState.completed;
      notifyListeners();
      return;
    }

    _currentProcessingIndex = nextIndex;
    final item = _queue[nextIndex];

    // Mark as processing
    item.status = QueueItemStatus.processing;
    _state = ProcessingState.preparingJob;
    _currentProgress = null;
    notifyListeners();

    // Calculate frame range from in/out points
    int? startFrame;
    int? endFrame;
    int? trimmedFrameCount;
    if (item.inPoint != null || item.outPoint != null) {
      final frameCount = item.videoInfo?.frameCount ?? 0;
      if (item.inPoint != null) {
        startFrame = (item.inPoint! * frameCount).round();
      }
      if (item.outPoint != null) {
        endFrame = (item.outPoint! * frameCount).round();
      }
      // Use trimmed frame count so pipe_source creates the correct clip length
      // and progress tracking shows accurate percentages
      final effectiveStart = startFrame ?? 0;
      final effectiveEnd = endFrame ?? (frameCount - 1);
      trimmedFrameCount = effectiveEnd - effectiveStart + 1;
    }

    // Subtitle-only mode: no video processing passes enabled, only subtitles
    final isSubtitleOnly = _processingPipeline.subtitles.enabled &&
        _processingPipeline.enabledPasses.isEmpty;
    _lastJobSubtitleOnly = isSubtitleOnly &&
        _processingPipeline.subtitles.output == SubtitleOutput.srtFile;

    // Ensure output path matches current settings (guards against stale extensions)
    item.outputPath = _generateOutputPath(item.inputPath);

    // Build job configuration
    final job = VideoJob(
      id: item.id,
      inputPath: item.inputPath,
      outputPath: item.outputPath,
      qtgmcParameters: _qtgmcParams.copyWith(
        tff: _getEffectiveFieldOrder(item) == FieldOrder.topFieldFirst,
      ),
      processingPipeline: _processingPipeline.copyWith(
        deinterlace: _processingPipeline.deinterlace.copyWith(
          tff: _getEffectiveFieldOrder(item) == FieldOrder.topFieldFirst,
        ),
      ),
      encodingSettings: _encodingSettings,
      detectedFieldOrder: _getEffectiveFieldOrder(item),
      totalFrames: trimmedFrameCount ?? item.videoInfo?.frameCount,
      inputFrameRate: item.videoInfo?.frameRate,
      inputWidth: item.videoInfo?.width,
      inputHeight: item.videoInfo?.height,
      inputPixelFormat: item.videoInfo?.pixelFormat,
      startFrame: startFrame,
      endFrame: endFrame,
      subtitleSettings: _processingPipeline.subtitles.enabled
          ? SubtitleSettingsDto.fromSubtitleParameters(
              _processingPipeline.subtitles)
          : null,
      subtitleOnly: isSubtitleOnly,
      inputSar: item.videoInfo?.sar,
    );

    // Record the audio config each file is actually encoded with. If a file's
    // audio unexpectedly reverts to copy (issue #12), this line pins down which
    // file and what settings were used, directly from the user's log.
    _logMessages.add(LogMessage(
      level: LogLevel.info,
      message: 'Encoding ${item.filename} audio: '
          '${_audioSettingsSummary(_encodingSettings)}',
    ));

    try {
      _state = ProcessingState.processing;
      notifyListeners();

      await _workerManager.startJob(job);
    } catch (e) {
      item.status = QueueItemStatus.failed;
      item.errorMessage = 'Failed to start processing: $e';
      _logMessages.add(LogMessage(
        level: LogLevel.error,
        message: 'Failed to start processing ${item.filename}: $e',
      ));
      // Continue with next item
      await _processNextItem();
    }
  }

  /// Handles completion of a queue item.
  Future<void> _handleQueueItemCompletion(CompletionResult result) async {
    if (_currentProcessingIndex < 0 || _currentProcessingIndex >= _queue.length) {
      return;
    }

    final item = _queue[_currentProcessingIndex];

    if (result.cancelled) {
      item.status = QueueItemStatus.cancelled;
      _isQueueProcessing = false;
      _currentProcessingIndex = -1;
      _state = ProcessingState.idle;
    } else if (result.success) {
      item.status = QueueItemStatus.completed;
      // Process next item
      await _processNextItem();
      return; // Don't notify yet, _processNextItem will
    } else {
      item.status = QueueItemStatus.failed;
      item.errorMessage = result.errorMessage ?? 'Processing failed';
      _logMessages.add(LogMessage(
        level: LogLevel.error,
        message: '${item.filename}: ${item.errorMessage}',
      ));
      // Process next item
      await _processNextItem();
      return; // Don't notify yet, _processNextItem will
    }

    notifyListeners();
  }

  /// Gets the effective field order for a queue item.
  FieldOrder _getEffectiveFieldOrder(QueueItem item) {
    if (_autoFieldOrder && item.videoInfo?.fieldOrder != null) {
      return item.videoInfo!.fieldOrder!;
    }
    return _manualFieldOrder;
  }

  /// Cancels queue processing.
  Future<void> cancelQueueProcessing() async {
    if (!_isQueueProcessing) return;

    await _workerManager.cancel();
  }

  /// Legacy method for compatibility - starts queue processing.
  Future<void> startProcessing() async {
    await startQueueProcessing();
  }

  /// Cancels the current job.
  Future<void> cancelProcessing() async {
    if (!_state.canCancel) return;

    _state = ProcessingState.cancelling;
    notifyListeners();

    if (_isQueueProcessing) {
      await cancelQueueProcessing();
    } else {
      await _workerManager.cancel();
    }
  }

  /// Retries all failed items in the queue.
  Future<void> retryFailed() async {
    if (_isQueueProcessing) return;

    // Reset failed items to ready
    for (final item in _queue) {
      if (item.status == QueueItemStatus.failed) {
        item.status = QueueItemStatus.ready;
        item.errorMessage = null;
      }
    }

    _isQueueProcessing = true;
    _currentProcessingIndex = -1;
    _logMessages.clear();
    _state = ProcessingState.preparingJob;
    notifyListeners();

    await _processNextItem();
  }

  /// Resets after completion or failure.
  void reset() {
    _state = ProcessingState.idle;
    _currentProgress = null;
    _isQueueProcessing = false;
    _currentProcessingIndex = -1;

    // Reset queue item statuses for failed/cancelled items to ready
    for (final item in _queue) {
      if (item.status == QueueItemStatus.failed ||
          item.status == QueueItemStatus.cancelled) {
        item.status = QueueItemStatus.ready;
        item.errorMessage = null;
      }
    }

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

  /// Generates the output path based on encoding settings and input path.
  String _generateOutputPath(String inputPath) {
    final inputFile = File(inputPath);
    final inputBaseName = path.basenameWithoutExtension(inputPath);

    // Use custom output directory or same as input
    final outputDir = _encodingSettings.outputDirectory ?? inputFile.parent.path;

    // Generate filename from pattern
    final outputFilename = _encodingSettings.generateOutputFilename(inputBaseName);

    // Subtitle-only with SRT output: use .srt extension
    final isSubtitleOnly = _processingPipeline.subtitles.enabled &&
        _processingPipeline.videoPassCount == 0;
    if (isSubtitleOnly && _processingPipeline.subtitles.output == SubtitleOutput.srtFile) {
      return path.join(outputDir, '$outputFilename.srt');
    }

    // Add extension based on container
    final ext = _getOutputExtension();

    // Use path.join so the separator matches the platform (backslash on Windows)
    // instead of producing mixed separators like "D:\dir/file.mov".
    return path.join(outputDir, '$outputFilename$ext');
  }

  /// Regenerates the output paths for all queue items when settings change.
  void _regenerateOutputPath() {
    for (final item in _queue) {
      item.outputPath = _generateOutputPath(item.inputPath);
    }
  }

  // ============================================================================
  // DVD AND FOLDER IMPORT
  // ============================================================================

  /// Detect mounted DVD discs.
  Future<List<DvdDisc>> detectDiscs() async {
    return _discDetector.detectDiscs();
  }

  /// Open a DVD disc: enumerate titles, show picker, extract, add to queue.
  /// Returns the DvdInfo for the caller to show the title picker.
  Future<DvdInfo> getDvdInfo(String mountPoint) async {
    return _dvdService.getTitleInfo(mountPoint);
  }

  /// Extract a DVD title and add the extracted file to the queue.
  Future<void> addDvdTitle({
    required DvdInfo dvdInfo,
    required int titleIndex,
    int? startChapter,
    int? endChapter,
  }) async {
    // Create temp file for the extraction.
    // Sanitize volume label to remove characters illegal in filenames (e.g., ":" from "D:\").
    final safeLabel = dvdInfo.volumeLabel.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final tempFile = File(
      await TempDirectoryService.instance.filePath(
        'vapourbox_dvd_${safeLabel}_t${titleIndex}_${DateTime.now().millisecondsSinceEpoch}.mpg',
      ),
    );

    final dvdSourceInfo = DvdSourceInfo(
      volumeLabel: dvdInfo.volumeLabel,
      titleIndex: titleIndex,
      startChapter: startChapter,
      endChapter: endChapter,
      tempFilePath: tempFile.path,
    );

    // Create queue item with "extracting" status
    final outputPath = _generateOutputPath(tempFile.path);
    final item = QueueItem(
      inputPath: tempFile.path,
      outputPath: outputPath,
      dvdSourceInfo: dvdSourceInfo,
      status: QueueItemStatus.pending,
    );
    _queue.add(item);

    _selectedItemId ??= item.id;

    notifyListeners();

    // Extract the title
    item.status = QueueItemStatus.extracting;
    item.extractionProgress = 0.0;
    _logMessages.add(LogMessage(
      level: LogLevel.info,
      message: 'Extracting ${dvdSourceInfo.displayName}...',
    ));
    notifyListeners();

    final extractionLog = <String>[];

    try {
      await for (final progress in _dvdService.extractTitle(
        mountPoint: dvdInfo.devicePath,
        titleIndex: titleIndex,
        startChapter: startChapter,
        endChapter: endChapter,
        outputPath: tempFile.path,
      )) {
        if (progress.isLog) {
          // Forward worker log messages to both the app log and the extraction log
          final level = LogLevel.fromString(progress.logLevel ?? 'info');
          _logMessages.add(LogMessage(
            level: level,
            message: progress.logMessage ?? '',
          ));
          extractionLog.add('[${progress.logLevel}] ${progress.logMessage}');
          notifyListeners();
          continue;
        }

        if (progress.isError) {
          extractionLog.add('[error] ${progress.error}');
          item.status = QueueItemStatus.failed;
          item.errorMessage = _buildExtractionErrorMessage(
            progress.error ?? 'Extraction failed',
            extractionLog,
          );
          _logMessages.add(LogMessage(
            level: LogLevel.error,
            message: 'DVD extraction failed: ${progress.error}',
          ));
          notifyListeners();
          return;
        }

        // Update extraction progress on the queue item
        item.extractionProgress = progress.progress;
        notifyListeners();
      }

      _logMessages.add(LogMessage(
        level: LogLevel.info,
        message: 'Extraction complete: ${dvdSourceInfo.displayName}',
      ));

      // Now analyze the extracted file
      await _analyzeQueueItem(item);
    } catch (e) {
      extractionLog.add('[exception] $e');
      item.status = QueueItemStatus.failed;
      item.errorMessage = _buildExtractionErrorMessage(
        'Extraction failed: $e',
        extractionLog,
      );
      _logMessages.add(LogMessage(
        level: LogLevel.error,
        message: 'DVD extraction failed: $e',
      ));
      notifyListeners();
    }
  }

  /// Add a folder: if it's a VIDEO_TS folder, treat as DVD; otherwise scan for videos.
  Future<void> addFolder(String folderPath) async {
    // Check if this is a DVD folder (contains VIDEO_TS)
    final dvdMountPoint = await DiscDetector.findVideoTsParent(folderPath);
    if (dvdMountPoint != null) {
      // Route to DVD enumeration flow — caller should show title picker
      // We throw a special exception that the UI can catch to show the DVD picker
      throw DvdFolderDetected(mountPoint: dvdMountPoint);
    }

    // Generic folder: scan for video files
    final videoPaths = await _scanFolderForVideos(folderPath);
    if (videoPaths.isEmpty) {
      _logMessages.add(LogMessage(
        level: LogLevel.warning,
        message: 'No video files found in folder',
      ));
      notifyListeners();
      return;
    }

    await addMultipleToQueue(videoPaths);
  }

  /// Recursively scan a folder for video files.
  Future<List<String>> _scanFolderForVideos(String folderPath) async {
    final videoExtensions = {
      '.avi', '.mov', '.mp4', '.mkv', '.mxf', '.m2v', '.mpg', '.mpeg',
      '.ts', '.vob', '.dv', '.mts', '.m2ts', '.wmv', '.webm', '.flv',
    };

    final videoPaths = <String>[];
    final dir = Directory(folderPath);

    if (!await dir.exists()) return videoPaths;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final ext = path.extension(entity.path).toLowerCase();
        if (videoExtensions.contains(ext)) {
          videoPaths.add(entity.path);
        }
      }
    }

    // Sort by name for consistent ordering
    videoPaths.sort();
    return videoPaths;
  }

  /// Build a detailed error message that includes the extraction log trail.
  String _buildExtractionErrorMessage(String summary, List<String> log) {
    if (log.isEmpty) return summary;
    return '$summary\n\nExtraction log:\n${log.join('\n')}';
  }

  /// Delete the extracted temp file for a single DVD queue item.
  void _cleanupDvdTempFile(QueueItem item) {
    if (item.dvdSourceInfo == null) return;
    final tempFile = File(item.dvdSourceInfo!.tempFilePath);
    if (tempFile.existsSync()) {
      try {
        tempFile.deleteSync();
      } catch (_) {
        // Ignore cleanup errors
      }
    }
  }

  /// Clean up any remaining DVD temp files (called on dispose).
  void _cleanupDvdTempFiles() {
    for (final item in _queue) {
      if (item.dvdSourceInfo != null) {
        _cleanupDvdTempFile(item);
      }
    }
  }

  // ============================================================================
  // PRESET MANAGEMENT
  // ============================================================================

  /// Get all available presets.
  List<ProcessingPreset> get availablePresets => PresetService.instance.presets;

  /// Load a preset, applying its settings.
  void loadPreset(ProcessingPreset preset) {
    _processingPipeline = preset.pipeline;
    _qtgmcParams = preset.pipeline.deinterlace;
    _encodingSettings = preset.encodingSettings;

    // Clear dynamic params cache to force refresh
    _dynamicParams.clear();

    // Preset application replaces audio settings wholesale; log the result so
    // an unexpected audio config is traceable from the log (issue #12).
    _logMessages.add(LogMessage(
      level: LogLevel.info,
      message: 'Preset "${preset.name}" applied; audio now: '
          '${_audioSettingsSummary(_encodingSettings)}',
    ));

    notifyListeners();
    _requestPreviewUpdate();
  }

  /// Save current settings as a new preset.
  Future<ProcessingPreset> saveAsPreset(String name, {String? description}) async {
    final preset = ProcessingPreset(
      name: name,
      description: description,
      pipeline: _processingPipeline,
      encodingSettings: _encodingSettings,
    );

    await PresetService.instance.savePreset(preset);
    return preset;
  }

  /// Update an existing user preset with current settings.
  Future<void> updatePreset(ProcessingPreset existing) async {
    final updated = existing.copyWith(
      pipeline: _processingPipeline,
      encodingSettings: _encodingSettings,
    );
    await PresetService.instance.savePreset(updated);
    notifyListeners();
  }

  /// Delete a user preset.
  Future<void> deletePreset(ProcessingPreset preset) async {
    if (preset.isBuiltIn) return;
    await PresetService.instance.deletePreset(preset);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _progressSub?.cancel();
    _logSub?.cancel();
    _completionSub?.cancel();
    _previewDebounceTimer?.cancel();
    _zoomDebounceTimer?.cancel();
    _workerManager.dispose();
    _previewGenerator.dispose();
    _cleanupDvdTempFiles();
    super.dispose();
  }
}

/// Exception thrown when a dropped folder turns out to be a DVD (VIDEO_TS).
/// The UI catches this to show the DVD title picker instead.
class DvdFolderDetected implements Exception {
  final String mountPoint;
  const DvdFolderDetected({required this.mountPoint});

  @override
  String toString() => 'DvdFolderDetected: $mountPoint';
}
