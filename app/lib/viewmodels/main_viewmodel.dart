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

  // Dynamic parameters for UI state (preserves null values for optional params)
  final Map<String, DynamicParameters> _dynamicParams = {};

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

  // In/out point markers (normalized 0.0-1.0)
  double? _inPoint;
  double? _outPoint;

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

  // In/out point getters
  double? get inPoint => _inPoint;
  double? get outPoint => _outPoint;
  double get effectiveInPoint => _inPoint ?? 0.0;
  double get effectiveOutPoint => _outPoint ?? 1.0;
  int? get inPointFrame =>
      _inPoint != null ? (_inPoint! * (videoInfo?.frameCount ?? 0)).round() : null;
  int? get outPointFrame =>
      _outPoint != null ? (_outPoint! * (videoInfo?.frameCount ?? 0)).round() : null;
  bool get hasInOutRange => _inPoint != null || _outPoint != null;

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
    zoomInAt(_scrubberPosition);
  }

  /// Zooms in on the timeline, centering on the specified position.
  void zoomInAt(double centerPosition) {
    if (_timelineZoom >= 16.0) return; // Max zoom 16x

    _timelineZoom = (_timelineZoom * 1.5).clamp(1.0, 16.0);

    // Adjust view start to keep center position stable
    _adjustViewForZoomAt(centerPosition);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Zooms out on the timeline.
  void zoomOut() {
    zoomOutAt(_scrubberPosition);
  }

  /// Zooms out on the timeline, centering on the specified position.
  void zoomOutAt(double centerPosition) {
    if (_timelineZoom <= 1.0) return;

    _timelineZoom = (_timelineZoom / 1.5).clamp(1.0, 16.0);

    // Adjust view start to keep center position stable
    _adjustViewForZoomAt(centerPosition);
    notifyListeners();
    _requestThumbnailRegeneration();
  }

  /// Sets the timeline zoom level directly.
  void setTimelineZoom(double zoom) {
    _timelineZoom = zoom.clamp(1.0, 16.0);
    _adjustViewForZoomAt(_scrubberPosition);
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

  /// Adjusts the view start to keep the specified position stable during zoom.
  void _adjustViewForZoomAt(double centerPosition) {
    // Calculate the visible range width
    final newViewWidth = 1.0 / _timelineZoom;
    final maxStart = 1.0 - newViewWidth;

    // Try to center on the specified position
    _timelineViewStart = (centerPosition - newViewWidth / 2).clamp(0.0, maxStart);
  }

  /// Sets the in point to the current scrubber position.
  void setInPointToCurrent() {
    _inPoint = _scrubberPosition;
    // Ensure in point is before out point
    if (_outPoint != null && _inPoint! > _outPoint!) {
      _outPoint = null;
    }
    notifyListeners();
  }

  /// Sets the out point to the current scrubber position.
  void setOutPointToCurrent() {
    _outPoint = _scrubberPosition;
    // Ensure out point is after in point
    if (_inPoint != null && _outPoint! < _inPoint!) {
      _inPoint = null;
    }
    notifyListeners();
  }

  /// Sets the in point directly (normalized 0.0-1.0).
  void setInPoint(double position) {
    _inPoint = position.clamp(0.0, 1.0);
    if (_outPoint != null && _inPoint! > _outPoint!) {
      _outPoint = null;
    }
    notifyListeners();
  }

  /// Sets the out point directly (normalized 0.0-1.0).
  void setOutPoint(double position) {
    _outPoint = position.clamp(0.0, 1.0);
    if (_inPoint != null && _outPoint! < _inPoint!) {
      _inPoint = null;
    }
    notifyListeners();
  }

  /// Clears both in and out points.
  void clearInOutPoints() {
    _inPoint = null;
    _outPoint = null;
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

  /// Starts processing.
  Future<void> startProcessing() async {
    if (!canProcess) return;

    _state = ProcessingState.preparingJob;
    _currentProgress = null;
    _logMessages.clear();
    notifyListeners();

    // Calculate frame range from in/out points
    int? startFrame;
    int? endFrame;
    if (_inPoint != null || _outPoint != null) {
      final frameCount = _videoInfo?.frameCount ?? 0;
      if (_inPoint != null) {
        startFrame = (_inPoint! * frameCount).round();
      }
      if (_outPoint != null) {
        endFrame = (_outPoint! * frameCount).round();
      }
    }

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
      startFrame: startFrame,
      endFrame: endFrame,
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
