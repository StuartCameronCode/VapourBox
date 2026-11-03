/// What the worker says it rendered for a preview: its `PREVIEW_INFO:` line.
///
/// A source frame can have several output frames — two under a ×2 frame rate
/// or double-rate deinterlacing, two or three at 24 → 60. [subFrame] is which
/// of them this is, and [generated] whether it was made by interpolation
/// rather than taken from a source frame (issue #129).
class PreviewFrameInfo {
  final int frame;
  final int subFrame;
  final int subFrames;
  final bool generated;

  const PreviewFrameInfo({
    required this.frame,
    this.subFrame = 0,
    this.subFrames = 1,
    this.generated = false,
  });

  /// Whether there is more than one output frame to step through.
  bool get hasSubFrames => subFrames > 1;

  /// The last `PREVIEW_INFO:` line in a worker's stderr, or null if there is
  /// none. A worker from before sub-frames reports only `frame=`, which reads
  /// as a single real frame.
  static PreviewFrameInfo? parse(String stderr) {
    final lines = stderr
        .split('\n')
        .where((l) => l.trimLeft().startsWith('PREVIEW_INFO:'));
    if (lines.isEmpty) return null;
    final fields = <String, int>{};
    for (final pair in lines.last.trim().substring('PREVIEW_INFO:'.length).split(' ')) {
      final kv = pair.split('=');
      final value = kv.length == 2 ? int.tryParse(kv[1]) : null;
      if (value != null) fields[kv[0]] = value;
    }
    final frame = fields['frame'];
    if (frame == null) return null;
    final subFrames = (fields['sub_frames'] ?? 1).clamp(1, 1 << 20);
    return PreviewFrameInfo(
      frame: frame,
      subFrame: (fields['sub_frame'] ?? 0).clamp(0, subFrames - 1),
      subFrames: subFrames,
      generated: fields['generated'] == 1,
    );
  }
}
