/// What `vapourbox-worker --detect-crop` found at the edges of a video: black
/// borders and analog blanking, letterbox / pillarbox bars, and the
/// head-switching band at the bottom of a tape capture, for Crop & Resize
/// (`worker/src/crop_detect.rs`, app 1.7.0).
///
/// Advisory: the panel shows it, and only an Apply puts it into the controls.
library;

/// Four sides of a crop (or of Edge Repair's widths).
class CropSides {
  final int left;
  final int right;
  final int top;
  final int bottom;

  const CropSides({this.left = 0, this.right = 0, this.top = 0, this.bottom = 0});

  static CropSides? fromJson(Object? json) {
    if (json is! Map) return null;
    int v(String k) => (json[k] as num?)?.toInt() ?? 0;
    return CropSides(left: v('left'), right: v('right'), top: v('top'), bottom: v('bottom'));
  }

  bool get isZero => left == 0 && right == 0 && top == 0 && bottom == 0;

  @override
  String toString() => 'L $left, R $right, T $top, B $bottom';

  @override
  bool operator ==(Object other) =>
      other is CropSides &&
      other.left == left &&
      other.right == right &&
      other.top == top &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, right, top, bottom);
}

/// What one edge was found to be.
enum CropEdgeKind {
  none,

  /// A narrow black border or analog blanking: cropped.
  blanking,

  /// A letterbox / pillarbox bar: the picture's framing, cropped only on
  /// request.
  bar,

  /// The torn band at the bottom of a tape capture.
  headSwitching;

  static CropEdgeKind parse(Object? value) =>
      CropEdgeKind.values.firstWhere((k) => k.name == value, orElse: () => CropEdgeKind.none);
}

/// One edge as measured, in the orientation the Crop pass sees.
class CropEdge {
  final CropEdgeKind kind;

  /// Dark, flat lines from the frame edge.
  final int blank;

  /// The dim ramp beside them.
  final int ramp;

  /// Head-switching lines (bottom of the source).
  final int band;

  /// The width of a bar.
  final int bar;

  /// Fraction of usable frames that agree with this edge.
  final double confidence;

  const CropEdge({
    this.kind = CropEdgeKind.none,
    this.blank = 0,
    this.ramp = 0,
    this.band = 0,
    this.bar = 0,
    this.confidence = 1,
  });

  factory CropEdge.fromJson(Object? json) {
    if (json is! Map) return const CropEdge();
    int v(String k) => (json[k] as num?)?.toInt() ?? 0;
    return CropEdge(
      kind: CropEdgeKind.parse(json['kind']),
      blank: v('blank'),
      ramp: v('ramp'),
      band: v('band'),
      bar: v('bar'),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1,
    );
  }

  /// "12 px of blanking and a 3-px soft edge", for the panel.
  String describe({required bool horizontal}) {
    final unit = horizontal ? 'px' : 'lines';
    switch (kind) {
      case CropEdgeKind.none:
        return 'nothing to crop';
      case CropEdgeKind.blanking:
        final soft = ramp > 0 ? ' and a $ramp-${horizontal ? 'px' : 'line'} soft edge' : '';
        return '$blank $unit of black / blanking$soft';
      case CropEdgeKind.bar:
        return '$bar-${horizontal ? 'px' : 'line'} ${horizontal ? 'pillarbox' : 'letterbox'} bar';
      case CropEdgeKind.headSwitching:
        final barNote = bar > 0 ? ', under a $bar-line letterbox bar' : '';
        return '$band lines of head-switching noise$barNote';
    }
  }
}

class CropDetectReport {
  /// Whether anything worth cropping was found.
  final bool found;

  /// The recommended crop: blanking, soft edges and the head-switching band,
  /// not bars. Rounded to steps the Crop pass accepts.
  final CropSides crop;

  /// The same with the letterbox / pillarbox bars included; null without bars.
  final CropSides? cropWithBars;

  /// Edge Repair's widths for repairing the head-switching band instead of
  /// cropping it, and the crop that goes with that; null without a band.
  final CropSides? edgeRepair;
  final CropSides? cropWithRepair;

  final CropEdge left;
  final CropEdge right;
  final CropEdge top;
  final CropEdge bottom;

  /// The lowest confidence among the edges that found something.
  final double confidence;

  final int usableFrames;
  final int sampledFrames;

  /// Why nothing was found, or why the analysis failed.
  final String? message;
  final String? error;

  const CropDetectReport({
    required this.found,
    this.crop = const CropSides(),
    this.cropWithBars,
    this.edgeRepair,
    this.cropWithRepair,
    this.left = const CropEdge(),
    this.right = const CropEdge(),
    this.top = const CropEdge(),
    this.bottom = const CropEdge(),
    this.confidence = 1,
    this.usableFrames = 0,
    this.sampledFrames = 0,
    this.message,
    this.error,
  });

  const CropDetectReport.failed(String this.error)
      : found = false,
        crop = const CropSides(),
        cropWithBars = null,
        edgeRepair = null,
        cropWithRepair = null,
        left = const CropEdge(),
        right = const CropEdge(),
        top = const CropEdge(),
        bottom = const CropEdge(),
        confidence = 0,
        usableFrames = 0,
        sampledFrames = 0,
        message = null;

  factory CropDetectReport.fromJson(Map<String, dynamic> json) {
    if (json['error'] is String) return CropDetectReport.failed(json['error'] as String);
    final edges = json['edges'] is Map ? json['edges'] as Map : const {};
    return CropDetectReport(
      found: json['found'] == true,
      crop: CropSides.fromJson(json['crop']) ?? const CropSides(),
      cropWithBars: CropSides.fromJson(json['cropWithBars']),
      edgeRepair: CropSides.fromJson(json['edgeRepair']),
      cropWithRepair: CropSides.fromJson(json['cropWithRepair']),
      left: CropEdge.fromJson(edges['left']),
      right: CropEdge.fromJson(edges['right']),
      top: CropEdge.fromJson(edges['top']),
      bottom: CropEdge.fromJson(edges['bottom']),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1,
      usableFrames: (json['usableFrames'] as num?)?.toInt() ?? 0,
      sampledFrames: (json['frames'] as List?)?.length ?? 0,
      message: json['message'] as String?,
    );
  }

  /// Below this the panel says the edges were hard to judge: fewer than one
  /// sampled frame in four shows picture right up to an edge it found. The
  /// rest are not contradicting it — their picture is dark there too — but
  /// the evidence is thin (a dark film, or dark scenery beside a letterbox).
  static const lowConfidence = 0.25;

  bool get isLowConfidence => confidence < lowConfidence;

  /// Each side that found something, described.
  List<(String, String)> get findings => [
        for (final (name, edge, horizontal) in [
          ('Left', left, true),
          ('Right', right, true),
          ('Top', top, false),
          ('Bottom', bottom, false),
        ])
          if (edge.kind != CropEdgeKind.none) (name, edge.describe(horizontal: horizontal)),
      ];
}

/// Which of the report's suggestions to apply.
enum CropApply {
  /// The recommended crop.
  crop,

  /// The crop with the letterbox / pillarbox bars too.
  cropWithBars,

  /// Repair the head-switching band with Edge Repair; crop the rest.
  repairBand,
}
