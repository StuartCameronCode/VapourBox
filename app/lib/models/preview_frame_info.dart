import 'dart:ui' show Size;

/// What the worker says it rendered for a preview: its `PREVIEW_INFO:` line.
///
/// A source frame can have several output frames — two under a ×2 frame rate
/// or double-rate deinterlacing, two or three at 24 → 60. [subFrame] is which
/// of them this is, and [generated] whether it was made by interpolation
/// rather than taken from a source frame (issue #129).
///
/// The line also carries the aspect the encode will declare for the frame —
/// `sar=16/15` or `dar=16/9`, absent for square pixels — because the PNG
/// carries none (issue #149).
class PreviewFrameInfo {
  final int frame;
  final int subFrame;
  final int subFrames;
  final bool generated;

  /// The sample aspect ratio the encode stamps on the output, or null for
  /// square pixels.
  final double? outputSar;

  /// A forced display aspect the encode stamps instead of a SAR, or null.
  final double? outputDar;

  const PreviewFrameInfo({
    required this.frame,
    this.subFrame = 0,
    this.subFrames = 1,
    this.generated = false,
    this.outputSar,
    this.outputDar,
  });

  /// Whether there is more than one output frame to step through.
  bool get hasSubFrames => subFrames > 1;

  /// The shape the rendered frame has on screen, given its stored size: the
  /// display aspect the encode will have. A worker that reports no aspect
  /// reads as square pixels — the frame's own shape.
  double displayAspectFor(Size pixels) =>
      outputDar ?? pixels.width / pixels.height * (outputSar ?? 1.0);

  /// The last `PREVIEW_INFO:` line in a worker's stderr, or null if there is
  /// none. A worker from before sub-frames reports only `frame=`, which reads
  /// as a single real frame.
  static PreviewFrameInfo? parse(String stderr) {
    final lines = stderr
        .split('\n')
        .where((l) => l.trimLeft().startsWith('PREVIEW_INFO:'));
    if (lines.isEmpty) return null;
    final fields = <String, String>{};
    for (final pair in lines.last.trim().substring('PREVIEW_INFO:'.length).split(' ')) {
      final kv = pair.split('=');
      if (kv.length == 2) fields[kv[0]] = kv[1];
    }
    int? integer(String key) {
      final v = fields[key];
      return v == null ? null : int.tryParse(v);
    }

    final frame = integer('frame');
    if (frame == null) return null;
    final subFrames = (integer('sub_frames') ?? 1).clamp(1, 1 << 20);
    return PreviewFrameInfo(
      frame: frame,
      subFrame: (integer('sub_frame') ?? 0).clamp(0, subFrames - 1),
      subFrames: subFrames,
      generated: integer('generated') == 1,
      outputSar: parseRatio(fields['sar']),
      outputDar: parseRatio(fields['dar']),
    );
  }

  /// A ratio written `16/9`, `16:9` or `1.7778`, or null for anything that is
  /// not a finite positive number — so a malformed token falls back to the
  /// frame's own shape instead of drawing it zero-wide.
  static double? parseRatio(String? text) {
    if (text == null) return null;
    final t = text.trim();
    if (t.isEmpty) return null;
    final parts = t.split(RegExp('[:/]'));
    double? ratio;
    if (parts.length == 2) {
      final num = double.tryParse(parts[0].trim());
      final den = double.tryParse(parts[1].trim());
      if (num == null || den == null || den == 0) return null;
      ratio = num / den;
    } else if (parts.length == 1) {
      ratio = double.tryParse(t);
    }
    return ratio != null && ratio.isFinite && ratio > 0 ? ratio : null;
  }
}
