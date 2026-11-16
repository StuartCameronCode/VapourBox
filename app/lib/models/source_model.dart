/// What the worker found out about a source (`vapourbox-worker
/// --probe-source`, `worker/src/source_model.rs`, task #50): size, rate,
/// frame count, where the first picture sits, how its decodes seek, its
/// colour tags and audio streams.
///
/// The worker is the only place these are computed. The app reads them and
/// sends the model back, unchanged, in every job ([toJson] returns exactly
/// the JSON the worker printed), so a field the app does not know about
/// still reaches the worker. Nothing here derives a source fact.
library;

import 'dart:convert';
import 'dart:io';

import '../services/field_order_detector.dart' show SeekPlan, SourceGrid;
import '../services/timestamp_continuity_service.dart' show ContinuityScan;
import 'hdr_display.dart' show DolbyVisionInfo;

/// One audio stream of the source.
class SourceAudioStream {
  final int index;
  final String? codec;
  final int? sampleRate;
  final int? channels;
  final String? channelLayout;
  final int? bitRate;

  const SourceAudioStream({
    required this.index,
    this.codec,
    this.sampleRate,
    this.channels,
    this.channelLayout,
    this.bitRate,
  });

  factory SourceAudioStream.fromJson(Map<String, dynamic> j) => SourceAudioStream(
        index: (j['index'] as num?)?.toInt() ?? 0,
        codec: j['codec'] as String?,
        sampleRate: (j['sampleRate'] as num?)?.toInt(),
        channels: (j['channels'] as num?)?.toInt(),
        channelLayout: j['channelLayout'] as String?,
        bitRate: (j['bitRate'] as num?)?.toInt(),
      );
}

class SourceModel {
  /// The worker's model schema this app understands.
  static const schema = 1;

  final Map<String, dynamic> _json;

  SourceModel._(this._json);

  /// Null when [json] is not a model (an `{"error": …}` answer) or has
  /// another schema.
  static SourceModel? fromJson(Map<String, dynamic> json) {
    if (json['schema'] != schema || json['video'] is! Map) return null;
    return SourceModel._(json);
  }

  /// Parses the worker's one-line answer.
  static SourceModel? parse(String text) {
    for (final line in const LineSplitter().convert(text)) {
      final t = line.trim();
      if (!t.startsWith('{')) continue;
      try {
        return fromJson(jsonDecode(t) as Map<String, dynamic>);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// The JSON exactly as the worker printed it.
  Map<String, dynamic> toJson() => _json;

  Map<String, dynamic> get _video => _json['video'] as Map<String, dynamic>;

  double? _num(Map<String, dynamic> m, String k) => (m[k] as num?)?.toDouble();

  /// The file the model describes.
  String get path => (_json['identity'] as Map?)?['path'] as String? ?? '';
  String get formatName => _json['formatName'] as String? ?? '';
  double? get containerDuration => _num(_json, 'duration');

  int get width => (_video['width'] as num?)?.toInt() ?? 0;
  int get height => (_video['height'] as num?)?.toInt() ?? 0;
  String? get codec => _video['codec'] as String?;
  String? get codecTagString => _video['codecTagString'] as String?;
  String? get pixelFormat => _video['pixelFormat'] as String?;

  /// Null for square pixels.
  String? get sar => _video['sar'] as String?;

  /// ffprobe's `field_order` claim (`tt`, `bb`, `progressive`, …).
  String? get fieldOrder => _video['fieldOrder'] as String?;

  /// `r_frame_rate` as a number (the container's tick rate).
  double? get rFrameRate => _rational(_video['rFrameRate'] as String?);

  /// The picture rate every job runs at.
  double get frameRate => _num(_video, 'frameRate') ?? 0;

  /// The length in frames every decoder, trim and timeline counts in.
  int get frameCount => (_video['frameCount'] as num?)?.toInt() ?? 0;

  /// Seconds the first picture starts after the file's start.
  double get videoStartOffset => _num(_video, 'videoStartOffset') ?? 0;

  /// Frames late the decoder stamps each picture of a delayed AVI.
  int get decoderDelayFrames => (_video['decoderDelayFrames'] as num?)?.toInt() ?? 0;

  SeekPlan? get seekPlan {
    final p = _video['seekPlan'];
    if (p is! Map) return null;
    return SeekPlan(
      preroll: (p['preroll'] as num).toDouble(),
      containerStart: (p['containerStart'] as num).toDouble(),
    );
  }

  SourceGrid? get sourceGrid {
    final g = _video['sourceGrid'];
    if (g is! Map) return null;
    return SourceGrid(
      rateNum: (g['rateNum'] as num).toInt(),
      rateDen: (g['rateDen'] as num).toInt(),
      origin: (g['origin'] as num).toDouble(),
    );
  }

  /// Whether a soft-telecine decode at this rate holds 3:2 repeats
  /// (`soft_telecine_decimates_at`).
  bool get pulldownRate => _video['pulldownRate'] as bool? ?? false;

  String? get colorMatrix => _video['colorMatrix'] as String?;
  String? get colorPrimaries => _video['colorPrimaries'] as String?;
  String? get colorTransfer => _video['colorTransfer'] as String?;
  String? get colorRange => _video['colorRange'] as String?;

  DolbyVisionInfo? get dolbyVision {
    final d = _video['dolbyVision'];
    if (d is! Map) return null;
    return DolbyVisionInfo(
      profile: (d['profile'] as num?)?.toInt(),
      compatibilityId: (d['compatibilityId'] as num?)?.toInt(),
    );
  }

  List<SourceAudioStream> get audioStreams => [
        for (final a in (_json['audioStreams'] as List? ?? const []))
          SourceAudioStream.fromJson(a as Map<String, dynamic>),
      ];

  bool get hasAudio => audioStreams.isNotEmpty;

  /// The timestamp-reset scan, null when it could not be made.
  ContinuityScan? get continuity {
    final c = _json['continuity'];
    return c is Map<String, dynamic> ? ContinuityScan.fromJson(c) : null;
  }

  /// The timeline's length in seconds: frames over rate, so a late-starting
  /// picture's head of sound is not counted.
  double get duration {
    final d = containerDuration ?? 0;
    if (videoStartOffset > 0 && frameRate > 0) return frameCount / frameRate;
    return d;
  }

  /// Writes the model to [file], for `--source`.
  Future<void> writeTo(File file) => file.writeAsString(jsonEncode(_json));

  static double? _rational(String? s) {
    final parts = s?.split('/');
    if (parts == null || parts.length != 2) return null;
    final n = double.tryParse(parts[0]);
    final d = double.tryParse(parts[1]);
    return n != null && d != null && d != 0 ? n / d : null;
  }
}
