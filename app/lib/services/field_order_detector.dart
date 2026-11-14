import 'dart:convert';
import 'dart:io';

import '../models/hdr_display.dart';
import '../models/video_job.dart';
import 'tool_locator.dart';

/// Detects field order and scan type from video files using ffmpeg idet filter
/// and ffprobe frame analysis.
class FieldOrderDetector {
  FieldOrderDetector();

  /// Detects the field order of a video file using idet pixel analysis.
  ///
  /// Returns [FieldOrder.topFieldFirst], [FieldOrder.bottomFieldFirst], or [FieldOrder.progressive]
  /// based on actual frame content. Returns null if detection fails.
  Future<FieldOrder?> detect(String videoPath) async {
    final idet = await _runIdet(videoPath);
    if (idet != null) {
      return idet.fieldOrder;
    }

    // Fall back to metadata-based detection
    return _detectFieldOrderFromMetadata(videoPath);
  }

  /// Gets detailed video information for display.
  Future<VideoInfo?> getVideoInfo(String videoPath) async {
    final ffprobe = ToolLocator.instance.ffprobePath;
    if (ffprobe == null) {
      return null;
    }

    try {
      final result = await Process.run(
        ffprobe,
        [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_streams',
          '-show_format',
          videoPath,
        ],
      );

      if (result.exitCode != 0) {
        return null;
      }

      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final streams = json['streams'] as List<dynamic>?;
      final format = json['format'] as Map<String, dynamic>?;

      if (streams == null || streams.isEmpty) {
        return null;
      }

      // Find video stream
      Map<String, dynamic>? videoStream;
      Map<String, dynamic>? audioStream;

      for (final stream in streams) {
        final s = stream as Map<String, dynamic>;
        final codecType = s['codec_type'] as String?;
        if (codecType == 'video' && videoStream == null) {
          videoStream = s;
        } else if (codecType == 'audio' && audioStream == null) {
          audioStream = s;
        }
      }

      if (videoStream == null) {
        return null;
      }

      final width = videoStream['width'] as int?;
      final height = videoStream['height'] as int?;
      final rFrameRate = _parseFrameRate(videoStream['r_frame_rate'] as String?);
      final avgFrameRate =
          _parseFrameRate(videoStream['avg_frame_rate'] as String?);
      final frameRate = selectFrameRate(rFrameRate, avgFrameRate);
      final duration = _parseDuration(format?['duration'] as String?);
      final frameCount = frameCountFor(
        storedFrames: _parseFrameCount(videoStream['nb_frames'] as String?),
        rFrameRate: rFrameRate,
        avgFrameRate: avgFrameRate,
        duration: _parseDuration(videoStream['duration'] as String?) ?? duration,
        frameRate: frameRate,
      );
      final videoStart = await probeVideoStart(
        ffprobe,
        videoPath,
        streamStart: double.tryParse('${videoStream['start_time']}'),
        containerStart: double.tryParse('${format?['start_time']}'),
      );
      final codec = videoStream['codec_name'] as String?;
      final pixelFormat = videoStream['pix_fmt'] as String?;

      // Extract sample aspect ratio (SAR) — null if square pixels or unavailable
      final sar = normalizeSar(videoStream['sample_aspect_ratio'] as String?);

      // Get metadata field order for context
      final metadataFieldOrder = videoStream['field_order'] as String?;

      // Run idet and repeat_pict analysis in parallel
      final results = await Future.wait([
        _runIdet(videoPath, duration: duration),
        _detectSoftTelecine(videoPath),
      ]);
      final idet = results[0] as _IdetResult?;
      final hasSoftTelecine = results[1] as bool;

      // Determine field order: prefer idet, fall back to metadata
      FieldOrder? fieldOrder;
      if (idet != null) {
        fieldOrder = idet.fieldOrder;
      }
      fieldOrder ??= await _detectFieldOrderFromMetadata(videoPath);

      // Determine scan type from idet + repeat_pict + metadata context
      final scanType = _classifyScanType(
        idet, hasSoftTelecine,
        metadataFieldOrder: metadataFieldOrder,
        frameRate: frameRate,
      );

      return VideoInfo(
        width: width ?? 0,
        height: height ?? 0,
        frameRate: frameRate ?? 0,
        duration: duration ?? 0,
        frameCount: frameCount ??
            frameCountFromDuration(
              streamDuration: _parseDuration(videoStream['duration'] as String?),
              containerDuration: duration,
              start: videoStart,
              frameRate: frameRate,
            ),
        codec: codec ?? 'unknown',
        pixelFormat: pixelFormat ?? 'unknown',
        fieldOrder: fieldOrder,
        scanType: scanType,
        hasAudio: audioStream != null,
        sar: sar,
        colorMatrix: colorTag(videoStream, 'color_space'),
        colorPrimaries: colorTag(videoStream, 'color_primaries'),
        colorTransfer: colorTag(videoStream, 'color_transfer'),
        colorRange: colorTag(videoStream, 'color_range'),
        dolbyVision: DolbyVisionInfo.fromStream(videoStream),
        videoStartOffset: videoStart.offset,
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

  /// Detects field order from stream metadata (fallback when idet unavailable).
  Future<FieldOrder?> _detectFieldOrderFromMetadata(String videoPath) async {
    final ffprobe = ToolLocator.instance.ffprobePath;
    if (ffprobe == null) return null;

    try {
      final result = await Process.run(
        ffprobe,
        [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_streams',
          '-select_streams', 'v:0',
          videoPath,
        ],
      );

      if (result.exitCode != 0) return null;

      final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final streams = json['streams'] as List<dynamic>?;
      if (streams == null || streams.isEmpty) return null;

      final videoStream = streams[0] as Map<String, dynamic>;

      // Check field_order tag
      final fieldOrder = videoStream['field_order'] as String?;
      if (fieldOrder != null) {
        switch (fieldOrder.toLowerCase()) {
          case 'tt':
          case 'tb':
            return FieldOrder.topFieldFirst;
          case 'bb':
          case 'bt':
            return FieldOrder.bottomFieldFirst;
          case 'progressive':
            return FieldOrder.progressive;
        }
      }

      // Fallback: check codec tags
      final codecTagString = videoStream['codec_tag_string'] as String?;
      if (codecTagString != null) {
        if (codecTagString.toLowerCase().contains('dv')) {
          final frameRate = _parseFrameRate(videoStream['r_frame_rate'] as String?);
          if (frameRate != null && frameRate < 26) {
            return FieldOrder.topFieldFirst;
          } else {
            return FieldOrder.bottomFieldFirst;
          }
        }
      }

      // Check if interlaced based on codec
      final codecName = videoStream['codec_name'] as String?;
      if (codecName != null && codecName.toLowerCase() == 'mpeg2video') {
        return FieldOrder.topFieldFirst;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  // ============================================================================
  // UTILITIES
  // ============================================================================

  /// ffprobe's `sample_aspect_ratio` as the job carries it: null for square
  /// pixels or when there is none to read (`N/A`, `1:1`, and `0:1`, which is
  /// ffprobe's "unknown"). The encode and the preview jobs both go through
  /// this, so the preview fits the frame with the same SAR as the encode
  /// (issue #149).
  static String? normalizeSar(String? raw) {
    final sar = raw?.trim();
    if (sar == null || sar.isEmpty || sar == 'N/A' || sar == '1:1') return null;
    final parts = sar.split(':');
    if (parts.length == 2 && (double.tryParse(parts[0]) ?? 0) <= 0) return null;
    return sar;
  }

  /// Picks the true picture frame rate from the container's `r_frame_rate`
  /// (the stream's base/tick rate) and `avg_frame_rate` (the average displayed
  /// rate).
  ///
  /// Field-coded interlaced H.264 — e.g. a DVB-T PAL rip stored as "separated
  /// fields" — reports `r_frame_rate` as the *field* rate (50 for 25fps PAL,
  /// 59.94 for 29.97fps NTSC) while `avg_frame_rate` reports the real picture
  /// rate (25 / 29.97). Trusting the field rate makes VapourBox think the
  /// source is 50p, so QTGMC "Double Rate" deinterlacing targets 100fps and
  /// the pipe-source clip is built at the wrong rate (issue #13).
  ///
  /// When `avg` is roughly half of `r` (the field-coded signature), trust
  /// `avg`. Otherwise keep `r` — it's the reliable rate for CFR progressive
  /// and frame-coded interlaced content, and `avg` can be 0/0 or skewed by
  /// VFR/duration rounding.
  static double? selectFrameRate(double? rFrameRate, double? avgFrameRate) {
    if (rFrameRate == null || rFrameRate <= 0) return avgFrameRate;
    if (avgFrameRate == null || avgFrameRate <= 0) return rFrameRate;
    final ratio = rFrameRate / avgFrameRate;
    if (ratio > 1.8 && ratio < 2.2) {
      return avgFrameRate;
    }
    return rFrameRate;
  }

  /// Relative difference between `r_frame_rate` and `avg_frame_rate` above
  /// which a source may have a variable frame rate. The worker's
  /// `source_timing::VFR_RATE_TOLERANCE` — keep the two equal.
  static const double vfrRateTolerance = 0.0002;

  /// Whether ffprobe's two rates say the source may have a variable frame
  /// rate (a phone or screen recording that slows down). Field-coded
  /// interlaced video's 2:1 ratio (see [selectFrameRate]) is constant-rate.
  static bool isVariableRate(double? rFrameRate, double? avgFrameRate) {
    if (rFrameRate == null || avgFrameRate == null) return false;
    if (rFrameRate <= 0 || avgFrameRate <= 0) return false;
    final ratio = rFrameRate / avgFrameRate;
    if (ratio > 1.8 && ratio < 2.2) return false;
    return ((rFrameRate - avgFrameRate) / rFrameRate).abs() > vfrRateTolerance;
  }

  /// The source's length in frames at [frameRate] — the count the timeline,
  /// trims and the worker's pipe all work in.
  ///
  /// `nb_frames` is the number of frames *stored*. For a variable-frame-rate
  /// source that is fewer than its duration holds at the nominal rate: the
  /// gaps where the camera slowed down have no frame of their own. Counting
  /// stored frames made the timeline short, put every trim point early, and
  /// cut the end off the encode (issue #137), so such a source is counted
  /// by duration instead; the worker places its frames on the same grid.
  static int? frameCountFor({
    required int? storedFrames,
    required double? rFrameRate,
    required double? avgFrameRate,
    required double? duration,
    required double? frameRate,
  }) {
    if (isVariableRate(rFrameRate, avgFrameRate) &&
        duration != null &&
        duration > 0 &&
        frameRate != null &&
        frameRate > 0) {
      return (duration * frameRate).round();
    }
    return storedFrames;
  }

  double? _parseFrameRate(String? rateStr) {
    if (rateStr == null) return null;

    final parts = rateStr.split('/');
    if (parts.length == 2) {
      final num = double.tryParse(parts[0]);
      final den = double.tryParse(parts[1]);
      if (num != null && den != null && den != 0) {
        return num / den;
      }
    }
    return double.tryParse(rateStr);
  }

  double? _parseDuration(String? durationStr) {
    if (durationStr == null) return null;
    return double.tryParse(durationStr);
  }

  int? _parseFrameCount(String? countStr) {
    if (countStr == null) return null;
    return int.tryParse(countStr);
  }

  /// The length in frames of a constant-rate source with no stored count
  /// (`nb_frames` absent: TS, most MKV), counted from the video's first
  /// picture, as the worker decodes it:
  ///
  /// 1. the video stream's own duration plus its leading pictures (an open
  ///    GOP's B pictures shown before the stream's `start_time`);
  /// 2. else the container's duration less the video's start offset.
  ///
  /// The container's duration alone runs from the earliest stream: on a DVB-T
  /// capture whose sound starts 1.2 s first it counted 158 frames for a
  /// 128-frame video, and the encode padded the difference with repeats.
  static int frameCountFromDuration({
    required double? streamDuration,
    required double? containerDuration,
    required VideoStart start,
    required double? frameRate,
  }) {
    if (frameRate == null || frameRate <= 0) return 0;
    if (streamDuration != null && streamDuration > 0) {
      return ((streamDuration + start.leading) * frameRate).round();
    }
    if (containerDuration == null) return 0;
    final d = containerDuration - start.offset;
    return d > 0 ? (d * frameRate).round() : 0;
  }

  /// ffprobe's arguments (before the input) for [videoStartFromProbe]: the
  /// worker's `source_decode::VIDEO_START_PROBE_ARGS`, word for word.
  static const videoStartProbeArgs = [
    '-v', 'error',
    '-select_streams', 'v:0',
    '-show_entries', 'packet=pts_time:stream=start_time:format=start_time',
    '-read_intervals', '%+#64',
    '-of', 'json',
  ];

  /// Where the video's first picture sits (see [VideoStart]), from ffprobe's
  /// answer to [videoStartProbeArgs]: the earlier of the stream's
  /// `start_time` and the smallest PTS among its first packets (an open GOP
  /// shows pictures stored after the first packet; MPEG-2 in AVI stores
  /// packets with no PTS at all), less the container's `start_time`.
  /// Twin of the worker's `source_decode::video_start_from_probe`; both read
  /// `Tests/TestResources/video_start_probe_dvbt.json` in their tests.
  static VideoStart videoStartFromProbe(Map<String, dynamic> json) {
    double? num(Object? v) => v == null ? null : double.tryParse('$v');
    final format = json['format'] as Map<String, dynamic>?;
    final container = num(format?['start_time']);
    final streams = (json['streams'] as List<dynamic>?) ?? const [];
    final streamStart = streams.isEmpty
        ? null
        : num((streams.first as Map<String, dynamic>)['start_time']);
    final packets = (json['packets'] as List<dynamic>?) ?? const [];
    double? first = streamStart;
    for (final p in packets) {
      final t = num((p as Map<String, dynamic>)['pts_time']);
      if (t != null && t.isFinite && (first == null || t < first)) first = t;
    }
    if (first == null) return VideoStart.none;
    final offset =
        container != null && first > container ? first - container : 0.0;
    final leading =
        streamStart != null && streamStart > first ? streamStart - first : 0.0;
    return VideoStart(offset: offset, leading: leading);
  }

  /// Formats seeked by a timestamp search rather than an index, as
  /// ffprobe's `format_name` names them: the worker's
  /// `source_decode::TIMESTAMP_SEARCH_FORMATS`.
  static const timestampSearchFormats = ['mpegts', 'mpeg'];

  /// Seconds of video [seekProbeArgs] reads (`SEEK_PROBE_SECONDS`).
  static const seekProbeSeconds = 20;

  /// Added to the measured GOP and reorder delay (`SEEK_PREROLL_MARGIN`).
  static const seekPrerollMargin = 0.5;

  /// The smallest preroll (`SEEK_PREROLL_MIN`).
  static const seekPrerollMin = 1.0;

  /// ffprobe's arguments (before the input) for [seekPlanFromProbe]: the
  /// worker's `source_decode::SEEK_PROBE_ARGS`, word for word.
  static const seekProbeArgs = [
    '-v', 'error',
    '-select_streams', 'v:0',
    '-show_entries', 'packet=pts_time,dts_time,flags:format=format_name,start_time',
    '-read_intervals', '%+20',
    '-of', 'json',
  ];

  /// Whether a container (ffprobe's comma-separated `format_name`) seeks by
  /// timestamp search, so its decodes need a [SeekPlan].
  static bool seeksByTimestampSearch(String? formatName) =>
      formatName != null &&
      formatName
          .split(',')
          .any((n) => timestampSearchFormats.contains(n.trim()));

  /// The [SeekPlan] for a source from ffprobe's answer to [seekProbeArgs], or
  /// null when its format seeks by index. Twin of the worker's
  /// `source_decode::seek_plan_from_probe`: the preroll is the largest gap
  /// between keyframes, plus the largest PTS - DTS and [seekPrerollMargin],
  /// at least [seekPrerollMin]; the whole window with fewer than two
  /// keyframes. Both read `Tests/TestResources/seek_probe_dvbt.json` in their
  /// tests.
  static SeekPlan? seekPlanFromProbe(Map<String, dynamic> json) {
    final format = json['format'] as Map<String, dynamic>?;
    if (!seeksByTimestampSearch(format?['format_name'] as String?)) return null;
    double? num(Object? v) {
      final d = v == null ? null : double.tryParse('$v');
      return d != null && d.isFinite ? d : null;
    }

    final containerStart = num(format?['start_time']) ?? 0.0;
    final packets = (json['packets'] as List<dynamic>?) ?? const [];
    final keys = <double>[];
    var reorder = 0.0;
    for (final p in packets) {
      final m = p as Map<String, dynamic>;
      final pts = num(m['pts_time']);
      final dts = num(m['dts_time']);
      if (pts != null && dts != null && pts - dts > reorder) reorder = pts - dts;
      final key = (m['flags'] as String?)?.startsWith('K') ?? false;
      final t = pts ?? dts;
      if (key && t != null) keys.add(t);
    }
    var gop = seekProbeSeconds.toDouble();
    if (keys.length >= 2) {
      gop = 0.0;
      for (var i = 1; i < keys.length; i++) {
        if (keys[i] - keys[i - 1] > gop) gop = keys[i] - keys[i - 1];
      }
    }
    final preroll = gop + reorder + seekPrerollMargin;
    return SeekPlan(
      preroll: preroll < seekPrerollMin ? seekPrerollMin : preroll,
      containerStart: containerStart,
    );
  }

  /// Probe the [SeekPlan], but only when [formatName] (from the probe the
  /// caller already ran) is an MPEG-TS/PS: every other source gets null, at
  /// no cost, and seeks as before. Null on any failure too.
  static Future<SeekPlan?> probeSeekPlan(
    String ffprobe,
    String videoPath, {
    required String? formatName,
  }) async {
    if (!seeksByTimestampSearch(formatName)) return null;
    try {
      final result = await Process.run(ffprobe, [...seekProbeArgs, videoPath]);
      if (result.exitCode != 0) return null;
      return seekPlanFromProbe(
          jsonDecode(result.stdout as String) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Probe where the video's first picture sits, but only when the video
  /// stream starts after the container (its sound starts first): the first
  /// picture is never later than the stream's `start_time`, so otherwise
  /// there is nothing to find. Then, and on any failure, [VideoStart.none]:
  /// frame N means what it always meant.
  static Future<VideoStart> probeVideoStart(
    String ffprobe,
    String videoPath, {
    required double? streamStart,
    required double? containerStart,
  }) async {
    if (streamStart == null ||
        containerStart == null ||
        streamStart <= containerStart) {
      return VideoStart.none;
    }
    try {
      final result =
          await Process.run(ffprobe, [...videoStartProbeArgs, videoPath]);
      if (result.exitCode != 0) return VideoStart.none;
      return videoStartFromProbe(
          jsonDecode(result.stdout as String) as Map<String, dynamic>);
    } catch (_) {
      return VideoStart.none;
    }
  }
}

/// How the source's decodes seek an MPEG-TS/PS, which has no keyframe index
/// (issue #169): [preroll] seconds before the target, keeping the file's own
/// timestamps (`-copyts`), then an absolute `trim` at [containerStart] plus
/// the target. Twin of the worker's `source_decode::SeekPlan`.
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
      return (input: ['-ss', target.toStringAsFixed(6)], trim: null);
    }
    final early = target - plan.preroll;
    return (
      input: ['-copyts', if (early > 0) ...['-ss', early.toStringAsFixed(6)]],
      trim: 'trim=start=${(plan.containerStart + target).toStringAsFixed(6)}',
    );
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

/// Where a source's video starts, for a file whose sound starts first (a
/// broadcast capture). Frame N counts from the video's first picture, so
/// every seek of the source adds [offset]: an input `-ss` is measured from
/// the container's start, which is the earliest stream's.
class VideoStart {
  /// Seconds from the container's start to the first picture shown (the
  /// smallest PTS among the first packets), never negative.
  final double offset;

  /// Seconds the first picture comes before the stream's `start_time`, which
  /// is its first *packet*: an open GOP shows B pictures stored after it.
  final double leading;

  const VideoStart({required this.offset, required this.leading});

  static const none = VideoStart(offset: 0, leading: 0);
}

/// Results from ffmpeg idet filter analysis.
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

/// Read one ffprobe colour tag, treating "unknown"/"N/A" as absent.
///
/// ffprobe reports the literal string `unknown` for an untagged stream, and
/// forwarding that as though it were a value would put nonsense on the encoder
/// command line. Anything unrecognised is dropped again worker-side, in
/// `ColorMetadata::from_raw`, so a surprising value cannot reach ffmpeg.
/// `PreviewGenerator` reads the tags with this too.
///
/// A value FFmpeg rejects, such as ProRes's `reserved`, is **forwarded on
/// purpose**, not dropped here: FFmpeg's decoder reads the tag from the stream
/// whatever the job says, so every decode that converts the pixel format has
/// to know the tag is invalid to clear it first (`ColorTags.decodeNeutraliser`,
/// and the worker's `VideoJob::decode_tag_neutraliser` from the job's tags).
/// The encoder's tags still drop it, in `ColorMetadata::from_raw`.
String? colorTag(Map<String, dynamic> stream, String key) {
  final value = (stream[key] as String?)?.trim();
  if (value == null || value.isEmpty || value == 'unknown' || value == 'N/A') {
    return null;
  }
  return value;
}

/// Video file information.
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
  });

  String get resolution => '${width}x$height';

  /// "HDR10", "HLG", "Dolby Vision 8.1", or null for SDR.
  String? get dynamicRangeLabel => HdrDisplay.rangeLabel(
        transfer: colorTransfer,
        dolbyVision: dolbyVision,
      );

  /// The actual content frame rate, which may differ from the container rate.
  /// - Soft telecine: container is ~29.97fps, content is ~23.976fps
  /// - Hard telecine: container is ~29.97fps, content is ~23.976fps (after IVTC)
  /// - Progressive/interlaced: same as container rate
  double get contentFrameRate {
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
