import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../services/field_order_detector.dart';
import '../services/timestamp_continuity_service.dart';
import 'noise_halo_report.dart';

/// Status of a queue item.
enum QueueItemStatus {
  pending,
  extracting,
  analyzing,
  ready,
  processing,
  completed,
  failed,
  cancelled,
}

/// Source information for items that came from a DVD.
class DvdSourceInfo {
  final String volumeLabel;
  final int titleIndex;
  final int? startChapter;
  final int? endChapter;
  final String tempFilePath;

  const DvdSourceInfo({
    required this.volumeLabel,
    required this.titleIndex,
    this.startChapter,
    this.endChapter,
    required this.tempFilePath,
  });

  /// Display name for the queue (e.g., "MY_DVD - Title 1").
  String get displayName {
    final chapters = startChapter != null
        ? ' Ch. $startChapter-$endChapter'
        : '';
    return '$volumeLabel - Title $titleIndex$chapters';
  }
}

/// Represents a video in the processing queue with its own state.
class QueueItem {
  final String id;
  final String inputPath;
  String outputPath;
  VideoInfo? videoInfo;

  /// How noisy the source is and how strongly its edges ring, measured in the
  /// background after [videoInfo] (app 1.7.0); null until it comes back.
  /// Transient: only the pass list's suggestions read it.
  NoiseHaloReport? noiseHalo;

  /// Optional DVD source info (for display and temp file cleanup).
  DvdSourceInfo? dvdSourceInfo;

  /// The joined copy this source is decoded from, when its timestamps reset
  /// mid-file (an MPEG-PS/TS, task #21; see `TimestampContinuityService`).
  /// Null for every other source.
  ContinuityProxy? continuityProxy;

  /// Whether the source was scanned for timestamp resets (and, having one,
  /// given a [continuityProxy]). Sent to the worker as `continuityChecked`,
  /// which otherwise scans and warns.
  bool continuityChecked;

  /// Extraction progress (0.0 to 1.0), used during DVD extraction.
  double extractionProgress;

  /// Pitch factor file for the Stabilize pass in "From File" mode. Per video,
  /// because a factor log belongs to one film. Found automatically as a
  /// sidecar when the video is added (see PitchFactorFile).
  String? pitchFactorsPath;

  // Per-video in/out markers (normalized 0.0-1.0)
  double? inPoint;
  double? outPoint;

  // Preview state (transient, not persisted)
  List<Uint8List> thumbnails;
  double scrubberPosition;
  Uint8List? currentFrame;
  Uint8List? processedPreview;

  /// The display aspect [processedPreview] is drawn at: the shape the encode
  /// will have, from the aspect the worker reported for it. Kept with the
  /// image rather than read from the frame info, which is dropped as soon as
  /// the scrubber moves while this image is still on screen (issue #149).
  double? processedPreviewAspect;
  double timelineZoom;
  double timelineViewStart;

  /// The normalized span [thumbnails] were generated for. Zooming or panning
  /// changes the view at once but regenerates thumbnails only after a
  /// debounce, so the strip draws the existing ones stretched to where this
  /// span falls in the new view rather than leaving them in the wrong place.
  double thumbnailRangeStart;
  double thumbnailRangeEnd;

  // Status
  QueueItemStatus status;
  String? errorMessage;

  QueueItem({
    String? id,
    required this.inputPath,
    required this.outputPath,
    this.videoInfo,
    this.dvdSourceInfo,
    this.continuityProxy,
    this.continuityChecked = false,
    this.extractionProgress = 0.0,
    this.pitchFactorsPath,
    this.inPoint,
    this.outPoint,
    List<Uint8List>? thumbnails,
    this.scrubberPosition = 0.0,
    this.currentFrame,
    this.processedPreview,
    this.processedPreviewAspect,
    this.timelineZoom = 1.0,
    this.timelineViewStart = 0.0,
    this.thumbnailRangeStart = 0.0,
    this.thumbnailRangeEnd = 1.0,
    this.status = QueueItemStatus.pending,
    this.errorMessage,
  })  : id = id ?? const Uuid().v4(),
        thumbnails = thumbnails ?? [];

  /// The file every probe and decode reads: the joined copy when the source's
  /// timestamps reset, else [inputPath]. [inputPath] stays the user's file,
  /// for naming the output, display, Show in Folder and sidecar lookups;
  /// `queue_item_decode_path_test.dart` checks every read is one or the other.
  String get decodePath => continuityProxy?.path ?? inputPath;

  /// Returns the filename from the input path, or DVD display name if from a DVD.
  String get filename {
    if (dvdSourceInfo != null) return dvdSourceInfo!.displayName;
    final parts = inputPath.replaceAll('\\', '/').split('/');
    return parts.isNotEmpty ? parts.last : inputPath;
  }

  /// Returns a short display name (truncated if too long).
  String get displayName {
    final name = filename;
    if (name.length > 40) {
      return '${name.substring(0, 37)}...';
    }
    return name;
  }

  /// Returns the video resolution or empty string if not analyzed.
  String get resolution => videoInfo?.resolution ?? '';

  /// Returns the video duration formatted or empty string if not analyzed.
  String get durationFormatted => videoInfo?.durationFormatted ?? '';

  /// Returns true if the item has in/out markers set.
  bool get hasInOutRange => inPoint != null || outPoint != null;

  /// Returns the effective in point (0.0 if not set).
  double get effectiveInPoint => inPoint ?? 0.0;

  /// Returns the effective out point (1.0 if not set).
  double get effectiveOutPoint => outPoint ?? 1.0;

  /// Returns the in point as a frame number (or null if not set).
  int? get inPointFrame =>
      inPoint != null ? (inPoint! * (videoInfo?.frameCount ?? 0)).round() : null;

  /// Returns the out point as a frame number (or null if not set).
  int? get outPointFrame =>
      outPoint != null ? (outPoint! * (videoInfo?.frameCount ?? 0)).round() : null;

  /// Returns the visible range in formatted time string.
  String get inOutRangeFormatted {
    if (!hasInOutRange || videoInfo == null) return '';
    final duration = videoInfo!.duration;
    final start = effectiveInPoint * duration;
    final end = effectiveOutPoint * duration;
    return '${_formatTime(start)} - ${_formatTime(end)}';
  }

  /// Returns the timeline view end position.
  double get timelineViewEnd =>
      (timelineViewStart + 1.0 / timelineZoom).clamp(0.0, 1.0);

  /// Returns true if the item can be removed (not currently processing or extracting).
  bool get canRemove =>
      status != QueueItemStatus.processing &&
      status != QueueItemStatus.extracting;

  /// Returns true if the item is ready to be processed.
  bool get canProcess =>
      status == QueueItemStatus.ready || status == QueueItemStatus.failed;

  /// Returns true if the item can be reprocessed (already finished).
  bool get canReprocess =>
      status == QueueItemStatus.completed || status == QueueItemStatus.cancelled;

  /// Copies this item with optional new values.
  QueueItem copyWith({
    String? id,
    String? inputPath,
    String? outputPath,
    VideoInfo? videoInfo,
    String? pitchFactorsPath,
    double? inPoint,
    double? outPoint,
    List<Uint8List>? thumbnails,
    double? scrubberPosition,
    Uint8List? currentFrame,
    Uint8List? processedPreview,
    double? processedPreviewAspect,
    double? timelineZoom,
    double? timelineViewStart,
    double? thumbnailRangeStart,
    double? thumbnailRangeEnd,
    QueueItemStatus? status,
    String? errorMessage,
  }) {
    return QueueItem(
      id: id ?? this.id,
      inputPath: inputPath ?? this.inputPath,
      outputPath: outputPath ?? this.outputPath,
      videoInfo: videoInfo ?? this.videoInfo,
      pitchFactorsPath: pitchFactorsPath ?? this.pitchFactorsPath,
      inPoint: inPoint ?? this.inPoint,
      outPoint: outPoint ?? this.outPoint,
      thumbnails: thumbnails ?? this.thumbnails,
      scrubberPosition: scrubberPosition ?? this.scrubberPosition,
      currentFrame: currentFrame ?? this.currentFrame,
      processedPreview: processedPreview ?? this.processedPreview,
      processedPreviewAspect:
          processedPreviewAspect ?? this.processedPreviewAspect,
      timelineZoom: timelineZoom ?? this.timelineZoom,
      timelineViewStart: timelineViewStart ?? this.timelineViewStart,
      thumbnailRangeStart: thumbnailRangeStart ?? this.thumbnailRangeStart,
      thumbnailRangeEnd: thumbnailRangeEnd ?? this.thumbnailRangeEnd,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  String _formatTime(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '0:00';
    final totalSecs = seconds.toInt();
    final minutes = totalSecs ~/ 60;
    final secs = totalSecs % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }
}
