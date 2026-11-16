import 'dart:convert';
import 'dart:io';

import '../models/hdr_display.dart';
import '../models/source_model.dart';
import '../models/video_job.dart';
import 'tool_locator.dart';

/// Detects field order and scan type from video files using ffmpeg idet filter
/// and ffprobe frame analysis.
///
/// Every other fact about a source (size, rate, frame count, where the first
/// picture sits, how it seeks, its colour tags) comes from the worker's
/// [SourceModel] (`--probe-source`, task #50); this class only adds the scan
/// type, which needs a look at the pictures.
class FieldOrderDetector {
  FieldOrderDetector();

  /// The [VideoInfo] for [videoPath]: the worker's [model] of it, plus the
  /// scan type and field order from idet and the repeat flags.
  Future<VideoInfo?> getVideoInfo(String videoPath, SourceModel model) async {
    try {
      final frameRate = model.frameRate;
      final duration = model.containerDuration ?? 0;
      final results = await Future.wait([
        _runIdet(videoPath, duration: duration),
        _detectSoftTelecine(videoPath),
      ]);
      final idet = results[0] as _IdetResult?;
      final hasSoftTelecine = results[1] as bool;

      // Field order: idet first, then the stream's own claim.
      final fieldOrder = idet?.fieldOrder ?? fieldOrderFromMetadata(model);

      final scanType = _classifyScanType(
        idet,
        hasSoftTelecine,
        metadataFieldOrder: model.fieldOrder,
        frameRate: frameRate,
      );

      return VideoInfo(
        width: model.width,
        height: model.height,
        frameRate: frameRate,
        duration: duration,
        frameCount: model.frameCount,
        codec: model.codec ?? 'unknown',
        pixelFormat: model.pixelFormat ?? 'unknown',
        fieldOrder: fieldOrder,
        scanType: scanType,
        hasAudio: model.hasAudio,
        sar: model.sar,
        colorMatrix: model.colorMatrix,
        colorPrimaries: model.colorPrimaries,
        colorTransfer: model.colorTransfer,
        colorRange: model.colorRange,
        dolbyVision: model.dolbyVision,
        videoStartOffset: model.videoStartOffset,
        pulldownRate: model.pulldownRate,
      );
    } catch (e) {
      return null;
    }
  }

  // ============================================================================
  // IDET ANALYSIS
  // ============================================================================

  /// Runs the ffmpeg idet filter to analyze frame content.
  ///
  /// Analyzes up to 200 frames of actual pixel data to detect:
  /// - Interlaced vs progressive content
  /// - Field order (TFF/BFF)
  /// - Repeated fields (indicates hard telecine)
  ///
  /// When [duration] is known and > 4s, skips the first 2s to avoid
  /// VHS leader/tracking instability.
  Future<_IdetResult?> _runIdet(String videoPath, {double? duration}) async {
    final ffmpeg = ToolLocator.instance.ffmpegPath;
    if (ffmpeg == null) return null;

    // Skip first 2s for longer videos to avoid VHS leader/tracking instability
    final skipSeconds = (duration != null && duration > 4.0) ? 2 : 0;

    try {
      final result = await Process.run(
        ffmpeg,
        [
          if (skipSeconds > 0) ...['-ss', '$skipSeconds'],
          '-i', videoPath,
          '-vf', 'idet',
          '-frames:v', '200',
          '-an',
          '-f', 'rawvideo',
          '-y',
          if (Platform.isWindows) 'NUL' else '/dev/null',
        ],
      ).timeout(const Duration(seconds: 15), onTimeout: () {
        return ProcessResult(0, 1, '', 'timeout');
      });

      // idet output goes to stderr
      final stderr = result.stderr as String;
      return _parseIdetOutput(stderr);
    } catch (e) {
      return null;
    }
  }

  /// Parses the idet filter output from ffmpeg stderr.
  ///
  /// Example output:
  /// [Parsed_idet_0 @ ...] Multi frame detection: TFF:168 BFF:0 Progressive:0 Undetermined:0
  /// [Parsed_idet_0 @ ...] Repeated Fields: Neither:54 Top:18 Bottom:18
  _IdetResult? _parseIdetOutput(String stderr) {
    int tff = 0, bff = 0, progressive = 0, undetermined = 0;
    int repeatedTop = 0, repeatedBottom = 0;
    bool foundMulti = false;
    bool foundRepeated = false;

    for (final line in stderr.split('\n')) {
      // Use multi-frame detection (more reliable than single frame)
      if (line.contains('Multi frame detection:')) {
        final match = RegExp(
          r'TFF:\s*(\d+)\s+BFF:\s*(\d+)\s+Progressive:\s*(\d+)\s+Undetermined:\s*(\d+)',
        ).firstMatch(line);
        if (match != null) {
          tff = int.parse(match.group(1)!);
          bff = int.parse(match.group(2)!);
          progressive = int.parse(match.group(3)!);
          undetermined = int.parse(match.group(4)!);
          foundMulti = true;
        }
      } else if (line.contains('Repeated Fields:')) {
        final match = RegExp(
          r'Neither:\s*(\d+)\s+Top:\s*(\d+)\s+Bottom:\s*(\d+)',
        ).firstMatch(line);
        if (match != null) {
          repeatedTop = int.parse(match.group(2)!);
          repeatedBottom = int.parse(match.group(3)!);
          foundRepeated = true;
        }
      }
    }

    if (!foundMulti) return null;

    return _IdetResult(
      tff: tff,
      bff: bff,
      progressive: progressive,
      undetermined: undetermined,
      repeatedTop: repeatedTop,
      repeatedBottom: repeatedBottom,
    );
  }

  /// Classifies scan type from idet results, repeat_pict analysis,
  /// and stream metadata context.
  ///
  /// Uses idet as primary signal, but cross-references with metadata
  /// to avoid false positives (e.g., idet detecting combing artifacts
  /// in progressive content as interlaced).
  ScanType _classifyScanType(
    _IdetResult? idet,
    bool hasSoftTelecine, {
    String? metadataFieldOrder,
    double? frameRate,
  }) {
    if (idet == null) {
      // No idet data — fall back to repeat_pict only
      return hasSoftTelecine ? ScanType.softTelecine : ScanType.unknown;
    }

    final total = idet.tff + idet.bff + idet.progressive + idet.undetermined;
    if (total == 0) {
      return hasSoftTelecine ? ScanType.softTelecine : ScanType.unknown;
    }

    final interlacedCount = idet.tff + idet.bff;
    final interlacedRatio = interlacedCount / total;
    final progressiveRatio = idet.progressive / total;
    final repeatedFields = idet.repeatedTop + idet.repeatedBottom;
    final isMetadataProgressive =
        metadataFieldOrder?.toLowerCase() == 'progressive';

    // If metadata says progressive and frame rate is not a typical
    // interlaced rate (~29.97 or ~25), trust metadata over idet.
    // idet can report false interlaced on low-quality progressive content
    // with motion artifacts or residual combing.
    if (isMetadataProgressive && frameRate != null) {
      final isInterlacedRate =
          (frameRate > 24.5 && frameRate < 26.0) || // ~25fps PAL
          (frameRate > 29.0 && frameRate < 30.5);    // ~29.97fps NTSC
      if (!isInterlacedRate) {
        if (hasSoftTelecine) return ScanType.softTelecine;
        return ScanType.progressive;
      }
    }

    // Hard telecine: interlaced frames with significant repeated fields.
    // True 3:2 pulldown shows ~40% repeated fields, 2:2 shows ~50%.
    // Require at least 15% to avoid false positives from VHS tracking
    // artifacts or other analog noise (especially at tape start).
    final repeatedRatio = total > 0 ? repeatedFields / total : 0.0;
    if (interlacedRatio > 0.5 && repeatedRatio > 0.15) {
      return ScanType.telecine;
    }

    // Interlaced: majority interlaced frames, no repeated fields
    if (interlacedRatio > 0.5) {
      // Cross-check: if metadata says progressive at ~29.97fps,
      // this is likely soft telecine with combing artifacts, not true interlace
      if (isMetadataProgressive) {
        if (hasSoftTelecine) return ScanType.softTelecine;
        return ScanType.progressive;
      }
      return ScanType.interlaced;
    }

    // Progressive frames dominant — check for soft telecine via repeat_pict
    if (progressiveRatio > 0.5) {
      if (hasSoftTelecine) return ScanType.softTelecine;
      return ScanType.progressive;
    }

    // Ambiguous — mostly undetermined
    if (hasSoftTelecine) return ScanType.softTelecine;
    return ScanType.unknown;
  }

  // ============================================================================
  // SOFT TELECINE DETECTION (repeat_pict)
  // ============================================================================

  /// Check for soft telecine by analyzing frame repeat_pict flags.
  ///
  /// Soft telecine uses repeat_pict to indicate which fields should be
  /// repeated to create 3:2 or 2:2 pulldown. idet can't detect this because
  /// the actual frames are progressive — only the repeat flags reveal it.
  Future<bool> _detectSoftTelecine(String videoPath) async {
    final ffprobe = ToolLocator.instance.ffprobePath;
    if (ffprobe == null) return false;

    try {
      final result = await Process.run(
        ffprobe,
        [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_frames',
          '-select_streams', 'v:0',
          '-read_intervals', '%+#30', // Sample first ~30 frames
          videoPath,
        ],
      ).timeout(const Duration(seconds: 15), onTimeout: () {
        return ProcessResult(0, 1, '', 'timeout');
      });

      if (result.exitCode != 0) return false;

      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final frames = json['frames'] as List<dynamic>?;
      if (frames == null || frames.length < 10) return false;

      // Count frames with repeat_pict > 0
      int repeatCount = 0;
      int totalFrames = 0;

      for (final frame in frames) {
        final f = frame as Map<String, dynamic>;
        if (f['media_type'] != 'video') continue;
        totalFrames++;

        final repeatPict = f['repeat_pict'] as int? ?? 0;
        if (repeatPict > 0) {
          repeatCount++;
        }
      }

      // Soft telecine patterns:
      // - 3:2 pulldown: ~40% of frames have repeat_pict > 0 (2 out of 5)
      // - 2:2 pulldown: ~50% of frames have repeat_pict > 0 (every other)
      if (totalFrames >= 10) {
        final ratio = repeatCount / totalFrames;
        if (ratio > 0.25 && ratio < 0.65) {
          return true;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  // ============================================================================
  // METADATA FALLBACK
  // ============================================================================

  /// The field order the stream's metadata claims (fallback when idet has
  /// no answer): its `field_order`, else a DV codec tag (TFF below 26 fps,
  /// BFF above), else TFF for MPEG-2.
  static FieldOrder? fieldOrderFromMetadata(SourceModel model) {
    switch (model.fieldOrder?.toLowerCase()) {
      case 'tt':
      case 'tb':
        return FieldOrder.topFieldFirst;
      case 'bb':
      case 'bt':
        return FieldOrder.bottomFieldFirst;
      case 'progressive':
        return FieldOrder.progressive;
    }
    if (model.codecTagString?.toLowerCase().contains('dv') ?? false) {
      final rate = model.rFrameRate;
      return rate != null && rate < 26
          ? FieldOrder.topFieldFirst
          : FieldOrder.bottomFieldFirst;
    }
    if (model.codec?.toLowerCase() == 'mpeg2video') {
      return FieldOrder.topFieldFirst;
    }
    return null;
  }
}

/// How the source's decodes seek an MPEG-TS/PS, which has no keyframe index
/// (issue #169): [preroll] seconds before the target, keeping the file's own
/// timestamps (`-copyts`), then an absolute `trim` at [containerStart] plus
/// the target. The worker computes it (`source_decode::SeekPlan`, in the
/// [SourceModel]); the arguments built from it here are a twin of the
/// worker's until the app's source pictures go through the worker.
class SeekPlan {
  /// Seconds to seek before the target: one GOP plus the reorder delay, so a
  /// keyframe is decoded before the target is.
  final double preroll;

  /// The container's `start_time`, what `-ss` counts from.
  final double containerStart;

  const SeekPlan({required this.preroll, required this.containerStart});

  /// The `-copyts` / `-ss` input options and the `trim` filter that make
  /// [target] (a container-relative seek time, as `-ss` takes it) the first
  /// frame decoded. Without a plan, the plain `-ss` it always was and no
  /// trim. Twin of the worker's `source_decode::decoder_seek`.
  static ({List<String> input, String? trim}) seekArgs(
      double target, SeekPlan? plan) {
    if (plan == null ||
        !plan.preroll.isFinite ||
        plan.preroll <= 0 ||
        !plan.containerStart.isFinite) {
      return (input: ['-ss', formatSeek(target)], trim: null);
    }
    final early = target - plan.preroll;
    return (
      input: ['-copyts', if (early > 0) ...['-ss', formatSeek(early)]],
      trim: 'trim=start=${formatSeek(plan.containerStart + target)}',
    );
  }

  /// A seek time as ffmpeg takes it: seconds to the microsecond, rounded
  /// **up** (issue #173). An AVI's tick is one frame, so `(N - 0.5) / fps`
  /// sits exactly on half a tick; to the nearest microsecond it often fell
  /// below the half and the decode began a frame early. The 1 ns allowance
  /// keeps whole microseconds as they are. Twin of the worker's
  /// `source_decode::seek_arg`.
  static String formatSeek(double t) =>
      ((t * 1e6 - 1e-3).ceil() / 1e6).toStringAsFixed(6);

  /// Below this seek time a source with a decoder delay decodes from the
  /// start and drops pictures by count (`COUNT_SEEK_BELOW`): an AVI cannot
  /// seek there, since ffmpeg starts such a seek 3/23 s early.
  static const countSeekBelow = 0.5;

  /// The largest decoder delay believed (`MAX_DECODER_DELAY`).
  static const maxDecoderDelay = 4;

  /// The input options and `trim` that make source frame [frame] the first
  /// one decoded, or null for frame 0 (never seeks). [decoderDelayFrames] is
  /// added to the frame (an AVI stamps each picture that many frames late),
  /// except under a [plan]; with a delay, a seek before [countSeekBelow]
  /// becomes no seek and `trim=start_frame=`[frame]. Twin of the worker's
  /// `source_decode::source_seek`; both check
  /// `Tests/TestResources/seek_arg_cases.json`.
  static ({List<String> input, String? trim})? frameSeekArgs({
    required int frame,
    required double frameRate,
    double videoStartOffset = 0,
    int decoderDelayFrames = 0,
    SeekPlan? plan,
  }) {
    if (frame <= 0) return null;
    final fps = frameRate > 0 ? frameRate : 29.97;
    final usable = plan != null &&
        plan.preroll.isFinite &&
        plan.preroll > 0 &&
        plan.containerStart.isFinite;
    final delay = usable
        ? 0
        : decoderDelayFrames.clamp(0, maxDecoderDelay);
    final offset = videoStartOffset > 0 ? videoStartOffset : 0.0;
    final target = (frame + delay - 0.5) / fps + offset;
    if (delay > 0 && target < countSeekBelow) {
      return (input: const <String>[], trim: 'trim=start_frame=$frame');
    }
    return seekArgs(target, usable ? plan : null);
  }

  @override
  bool operator ==(Object other) =>
      other is SeekPlan &&
      other.preroll == preroll &&
      other.containerStart == containerStart;

  @override
  int get hashCode => Object.hash(preroll, containerStart);

  @override
  String toString() =>
      'SeekPlan(preroll: $preroll, containerStart: $containerStart)';
}

/// The constant-rate grid every decode of the source places its frames on
/// (issue #174): the job's rate as the stream's exact fraction, from the
/// video's first picture. The worker computes it (`source_decode::SourceGrid`,
/// in the [SourceModel]); [startAt] is a twin of its `decode_start`. Frame
/// N is slot N, so a null frame or a pulldown repeat is a slot that
/// shows the stored frame before it, and every decode, preview, encode, the
/// Original and the thumbnails, agrees on which picture that is.
class SourceGrid {
  final int rateNum;
  final int rateDen;

  /// The first picture's presentation time, in the file's own timestamps.
  final double origin;

  const SourceGrid(
      {required this.rateNum, required this.rateDen, required this.origin});

  /// Slots a decode starting at frame N begins before it: the worker's
  /// `GRID_LOOKBACK_SLOTS`.
  static const lookbackSlots = 8;

  /// The worker's `GRID_RATE_TOLERANCE`.
  static const rateTolerance = 0.001;

  double get fps => rateNum / rateDen;

  bool get isValid => rateNum > 0 && rateDen > 0 && origin.isFinite;

  /// The filters that place frames on the grid and keep slots from [first]:
  /// the worker's `SourceGrid::filters`, character for character.
  List<String> filters(int first) => [
        'setpts=PTS-${origin.toStringAsFixed(6)}/TB',
        'fps=$rateNum/$rateDen',
        'trim=start_pts=${first < 0 ? 0 : first}',
        'setpts=PTS-STARTPTS',
      ];

  /// The `-copyts`/`-ss` input options and the filters (ahead of anything
  /// else after the tag fix) that start a decode at source frame [frame]:
  /// the worker's `source_decode::decode_start` with a grid.
  ({List<String> input, List<String> filters}) startAt(
      int frame, double videoStartOffset, SeekPlan? plan) {
    final f = frame < 0 ? 0 : frame;
    final back = f - lookbackSlots;
    double? ss = back > 0
        ? (back - 0.5) / fps + (videoStartOffset > 0 ? videoStartOffset : 0)
        : null;
    final usablePlan = plan != null &&
        plan.preroll.isFinite &&
        plan.preroll > 0 &&
        plan.containerStart.isFinite;
    // Frame 0 of a TS/PS keeps ffmpeg's discontinuity correction (no
    // -copyts; a clock reset stopped the decode there) and anchors the grid
    // at its first picture with STARTPTS: the worker's
    // `SourceGrid::filters_from_first_picture`.
    if (f == 0 && usablePlan) {
      return (
        input: const <String>[],
        filters: ['setpts=PTS-STARTPTS', ...filters(0).skip(1)],
      );
    }
    if (ss != null && usablePlan) ss -= plan.preroll;
    if (ss != null && ss <= 0) ss = null;
    return (
      input: ['-copyts', if (ss != null) ...['-ss', SeekPlan.formatSeek(ss)]],
      filters: filters(f),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SourceGrid &&
      other.rateNum == rateNum &&
      other.rateDen == rateDen &&
      other.origin == origin;

  @override
  int get hashCode => Object.hash(rateNum, rateDen, origin);

  @override
  String toString() => 'SourceGrid($rateNum/$rateDen from $origin)';
}

/// Where a source's video starts, for a file whose sound starts first (a
/// broadcast capture). Frame N counts from the video's first picture, so
/// every seek of the source adds [offset]: an input `-ss` is measured from
/// the container's start, which is the earliest stream's.
class _IdetResult {
  final int tff;
  final int bff;
  final int progressive;
  final int undetermined;
  final int repeatedTop;
  final int repeatedBottom;

  const _IdetResult({
    required this.tff,
    required this.bff,
    required this.progressive,
    required this.undetermined,
    required this.repeatedTop,
    required this.repeatedBottom,
  });

  /// Determines field order from idet frame counts.
  FieldOrder? get fieldOrder {
    final total = tff + bff + progressive + undetermined;
    if (total == 0) return null;

    final interlacedCount = tff + bff;
    if (interlacedCount > progressive) {
      // Interlaced content — determine TFF vs BFF
      if (tff > bff) return FieldOrder.topFieldFirst;
      if (bff > tff) return FieldOrder.bottomFieldFirst;
      return FieldOrder.topFieldFirst; // Default to TFF if equal
    }

    if (progressive > interlacedCount) {
      return FieldOrder.progressive;
    }

    return null;
  }
}

/// Detected scan type of the video content.
enum ScanType {
  /// Standard interlaced content (e.g., 50i/60i broadcast).
  interlaced,
  /// Hard telecined content (interlaced fields with 3:2 pulldown, e.g., NTSC DVD).
  telecine,
  /// Soft telecine: progressive frames with pulldown flags (real rate ~23.976fps).
  softTelecine,
  /// Progressive content (no interlacing).
  progressive,
  /// Could not determine scan type.
  unknown;

  String get displayName {
    switch (this) {
      case ScanType.interlaced:
        return 'Interlaced';
      case ScanType.telecine:
        return 'Hard Telecine (3:2 pulldown)';
      case ScanType.softTelecine:
        return 'Soft Telecine';
      case ScanType.progressive:
        return 'Progressive';
      case ScanType.unknown:
        return 'Unknown';
    }
  }
}

class VideoInfo {
  final int width;
  final int height;
  final double frameRate;
  final double duration;
  final int frameCount;
  final String codec;
  final String pixelFormat;
  final FieldOrder? fieldOrder;
  final ScanType scanType;
  final bool hasAudio;
  /// Sample aspect ratio from the input (e.g. "10:11"), null if 1:1 or unknown.
  final String? sar;

  /// Colour tags as reported by ffprobe, null when the stream is untagged.
  /// These are carried to the encoder and re-declared there: the Y4M pipe from
  /// vspipe strips them exactly as it strips SAR, and an untagged output is
  /// read as BT.601 limited by every player.
  final String? colorMatrix;
  final String? colorPrimaries;
  final String? colorTransfer;
  final String? colorRange;

  /// The Dolby Vision configuration record, null for any other source.
  /// Only Profile 5 changes what VapourBox can do (see
  /// [DolbyVisionInfo.baseLayerIsUndecodable]); every other profile's base
  /// layer is ordinary HDR10, HLG or SDR.
  final DolbyVisionInfo? dolbyVision;

  /// Seconds the video's first picture starts after the file's start (its
  /// sound starts first), 0 for most files. See [VideoStart]. The output
  /// keeps that layout unless Audio Restoration's "start the sound with the
  /// picture" drops the sound before the picture.
  final double videoStartOffset;

  /// Whether a soft-telecine decode at [frameRate] holds 3:2 repeats: only
  /// at 29.97 or 30 fps (issue #174; the worker's
  /// `soft_telecine_decimates_at`, reported in the [SourceModel]). A stream
  /// stored at its film rate decodes to the film frames already.
  final bool pulldownRate;

  const VideoInfo({
    required this.width,
    required this.height,
    required this.frameRate,
    required this.duration,
    required this.frameCount,
    required this.codec,
    required this.pixelFormat,
    this.fieldOrder,
    this.scanType = ScanType.unknown,
    required this.hasAudio,
    this.sar,
    this.colorMatrix,
    this.colorPrimaries,
    this.colorTransfer,
    this.colorRange,
    this.dolbyVision,
    this.videoStartOffset = 0,
    this.pulldownRate = false,
  });

  String get resolution => '${width}x$height';

  /// "HDR10", "HLG", "Dolby Vision 8.1", or null for SDR.
  String? get dynamicRangeLabel => HdrDisplay.rangeLabel(
        transfer: colorTransfer,
        dolbyVision: dolbyVision,
      );

  /// Whether the Soft Telecine method has pulldown repeats to remove from
  /// this source: a soft-telecine scan at a rate the worker says holds them
  /// ([pulldownRate], issue #174).
  bool get softTelecineDecimates =>
      scanType == ScanType.softTelecine && pulldownRate;

  /// The actual content frame rate, which may differ from the container rate.
  /// - Soft telecine: container is ~29.97fps, content is ~23.976fps
  /// - Hard telecine: container is ~29.97fps, content is ~23.976fps (after IVTC)
  /// - Progressive/interlaced: same as container rate

  double get contentFrameRate {
    if (scanType == ScanType.softTelecine && !softTelecineDecimates) {
      return frameRate;
    }
    if (scanType == ScanType.softTelecine || scanType == ScanType.telecine) {
      // 3:2 pulldown: 4 content frames displayed as 5 container frames
      // 29.97 * 4/5 = 23.976
      return frameRate * 4.0 / 5.0;
    }
    return frameRate;
  }

  String get frameRateFormatted {
    final content = contentFrameRate;
    if ((content - frameRate).abs() > 0.5) {
      return '${frameRate.toStringAsFixed(2)} fps (content ~${content.toStringAsFixed(2)} fps)';
    }
    return '${frameRate.toStringAsFixed(2)} fps';
  }

  String get durationFormatted {
    final totalSecs = duration.toInt();
    final hours = totalSecs ~/ 3600;
    final minutes = (totalSecs % 3600) ~/ 60;
    final seconds = totalSecs % 60;

    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    } else {
      return '${seconds}s';
    }
  }

  String get fieldOrderDescription {
    switch (fieldOrder) {
      case FieldOrder.topFieldFirst:
        return 'Top Field First (interlaced)';
      case FieldOrder.bottomFieldFirst:
        return 'Bottom Field First (interlaced)';
      case FieldOrder.progressive:
        return 'Progressive';
      case FieldOrder.unknown:
      case null:
        return 'Unknown';
    }
  }
}
