import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../models/dynamic_parameters.dart';
import '../models/encoding_settings.dart';
import '../models/parameter_converter.dart';
import '../models/progress_info.dart';
import '../models/qtgmc_parameters.dart';
import '../models/queue_item.dart';
import '../models/restoration_pipeline.dart';
import '../models/video_job.dart';
import '../models/processing_preset.dart';
import '../services/field_order_detector.dart';
import '../services/preset_service.dart';
import '../services/preview_generator.dart';
import '../services/worker_manager.dart';

/// Main view model managing application state.
class MainViewModel extends ChangeNotifier {
  final WorkerManager _workerManager = WorkerManager();
  final FieldOrderDetector _fieldOrderDetector = FieldOrderDetector();
  final PreviewGenerator _previewGenerator = PreviewGenerator();

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

  // Restoration pipeline
  RestorationPipeline _restorationPipeline = const RestorationPipeline();
  PassType _selectedPass = PassType.deinterlace;
  bool _advancedMode = false;

  // Dynamic parameters for UI state (preserves null values for optional params)
  final Map<String, DynamicParameters> _dynamicParams = {};

  // Preview generation state (shared across queue items)
  bool _isGeneratingPreview = false;
  CancelToken? _previewCancelToken;
  Timer? _previewDebounceTimer;
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
  RestorationPipeline get restorationPipeline => _restorationPipeline;
  PassType get selectedPass => _selectedPass;
  bool get advancedMode => _advancedMode;

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
    notifyListeners();
    _requestPreviewUpdate();
  }

  DynamicParameters _convertToParams(String filterId) {
    switch (filterId) {
      case 'deinterlace':
        return ParameterConverter.fromQTGMC(_restorationPipeline.deinterlace);
      case 'noise_reduction':
        return ParameterConverter.fromNoiseReduction(_restorationPipeline.noiseReduction);
      case 'dehalo':
        return ParameterConverter.fromDehalo(_restorationPipeline.dehalo);
      case 'deblock':
        return ParameterConverter.fromDeblock(_restorationPipeline.deblock);
      case 'deband':
        return ParameterConverter.fromDeband(_restorationPipeline.deband);
      case 'sharpen':
        return ParameterConverter.fromSharpen(_restorationPipeline.sharpen);
      case 'color_correction':
        return ParameterConverter.fromColorCorrection(_restorationPipeline.colorCorrection);
      case 'chroma_fixes':
        return ParameterConverter.fromChromaFixes(_restorationPipeline.chromaFixes);
      case 'crop_resize':
        return ParameterConverter.fromCropResize(_restorationPipeline.cropResize);
      default:
        return DynamicParameters(filterId: filterId);
    }
  }

  void _updatePipelineFromDynamic(String filterId, DynamicParameters params) {
    switch (filterId) {
      case 'deinterlace':
        _restorationPipeline = _restorationPipeline.copyWith(
          deinterlace: ParameterConverter.toQTGMC(params),
        );
        break;
      case 'noise_reduction':
        _restorationPipeline = _restorationPipeline.copyWith(
          noiseReduction: ParameterConverter.toNoiseReduction(params),
        );
        break;
      case 'dehalo':
        _restorationPipeline = _restorationPipeline.copyWith(
          dehalo: ParameterConverter.toDehalo(params),
        );
        break;
      case 'deblock':
        _restorationPipeline = _restorationPipeline.copyWith(
          deblock: ParameterConverter.toDeblock(params),
        );
        break;
      case 'deband':
        _restorationPipeline = _restorationPipeline.copyWith(
          deband: ParameterConverter.toDeband(params),
        );
        break;
      case 'sharpen':
        _restorationPipeline = _restorationPipeline.copyWith(
          sharpen: ParameterConverter.toSharpen(params),
        );
        break;
      case 'color_correction':
        _restorationPipeline = _restorationPipeline.copyWith(
          colorCorrection: ParameterConverter.toColorCorrection(params),
        );
        break;
      case 'chroma_fixes':
        _restorationPipeline = _restorationPipeline.copyWith(
          chromaFixes: ParameterConverter.toChromaFixes(params),
        );
        break;
      case 'crop_resize':
        _restorationPipeline = _restorationPipeline.copyWith(
          cropResize: ParameterConverter.toCropResize(params),
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

    // Load thumbnails if this is the selected item
    if (_selectedItemId == item.id) {
      try {
        _queue[index].thumbnails = await _previewGenerator.loadVideo(item.inputPath);
        _queue[index].currentFrame = await _previewGenerator.getFrameAt(0);
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

    _queue.removeAt(index);

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
        item.currentFrame = await _previewGenerator.getFrameAt(
          item.scrubberPosition * _previewGenerator.duration,
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

    _queue.clear();
    _selectedItemId = null;
    _cancelPreviewGeneration();
    _state = ProcessingState.idle;
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

    // Update current frame immediately
    final timeSeconds = item.scrubberPosition * _previewGenerator.duration;
    item.currentFrame = await _previewGenerator.getFrameAt(timeSeconds);
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
  Future<void> _generateProcessedPreview() async {
    final item = selectedItem;
    if (item == null) return;

    // Cancel any existing preview generation
    _cancelPreviewGeneration();

    _isGeneratingPreview = true;
    notifyListeners();

    _previewCancelToken = CancelToken();
    final timeSeconds = item.scrubberPosition * _previewGenerator.duration;

    try {
      final preview = await _previewGenerator.generateProcessedPreview(
        timeSeconds: timeSeconds,
        pipeline: _restorationPipeline,
        fieldOrder: effectiveFieldOrder,
        cancelToken: _previewCancelToken,
      );

      if (!(_previewCancelToken?.isCancelled ?? true)) {
        item.processedPreview = preview;
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
    // Regenerate output path with new settings
    _regenerateOutputPath();
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
    // Sync dynamic params cache with new enabled state
    final filterId = _passTypeToFilterId(pass);
    if (_dynamicParams.containsKey(filterId)) {
      _dynamicParams[filterId] = _dynamicParams[filterId]!.withEnabled(enabled);
    }
    notifyListeners();
    _requestPreviewUpdate();
  }

  /// Convert PassType to filter ID.
  String _passTypeToFilterId(PassType pass) {
    switch (pass) {
      case PassType.deinterlace:
        return 'deinterlace';
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
    }
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
    // Find next item that can be processed (ready or failed only)
    final nextIndex = _queue.indexWhere((q) => q.canProcess);

    if (nextIndex == -1) {
      // No more items to process
      _isQueueProcessing = false;
      _currentProcessingIndex = -1;
      _state = ProcessingState.completed;
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
    if (item.inPoint != null || item.outPoint != null) {
      final frameCount = item.videoInfo?.frameCount ?? 0;
      if (item.inPoint != null) {
        startFrame = (item.inPoint! * frameCount).round();
      }
      if (item.outPoint != null) {
        endFrame = (item.outPoint! * frameCount).round();
      }
    }

    // Build job configuration
    final job = VideoJob(
      id: item.id,
      inputPath: item.inputPath,
      outputPath: item.outputPath,
      qtgmcParameters: _qtgmcParams.copyWith(
        tff: _getEffectiveFieldOrder(item) == FieldOrder.topFieldFirst,
      ),
      restorationPipeline: _restorationPipeline.copyWith(
        deinterlace: _restorationPipeline.deinterlace.copyWith(
          tff: _getEffectiveFieldOrder(item) == FieldOrder.topFieldFirst,
        ),
      ),
      encodingSettings: _encodingSettings,
      totalFrames: item.videoInfo?.frameCount,
      startFrame: startFrame,
      endFrame: endFrame,
    );

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

    // Add extension based on container
    final ext = _getOutputExtension();

    return '$outputDir/$outputFilename$ext';
  }

  /// Regenerates the output paths for all queue items when settings change.
  void _regenerateOutputPath() {
    for (final item in _queue) {
      item.outputPath = _generateOutputPath(item.inputPath);
    }
  }

  // ============================================================================
  // PRESET MANAGEMENT
  // ============================================================================

  /// Get all available presets.
  List<ProcessingPreset> get availablePresets => PresetService.instance.presets;

  /// Load a preset, applying its settings.
  void loadPreset(ProcessingPreset preset) {
    _restorationPipeline = preset.pipeline;
    _qtgmcParams = preset.pipeline.deinterlace;
    _encodingSettings = preset.encodingSettings;

    // Clear dynamic params cache to force refresh
    _dynamicParams.clear();

    notifyListeners();
    _requestPreviewUpdate();
  }

  /// Save current settings as a new preset.
  Future<ProcessingPreset> saveAsPreset(String name, {String? description}) async {
    final preset = ProcessingPreset(
      name: name,
      description: description,
      pipeline: _restorationPipeline,
      encodingSettings: _encodingSettings,
    );

    await PresetService.instance.savePreset(preset);
    return preset;
  }

  /// Delete a user preset.
  Future<void> deletePreset(ProcessingPreset preset) async {
    if (preset.isBuiltIn) return;
    await PresetService.instance.deletePreset(preset);
    notifyListeners();
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
