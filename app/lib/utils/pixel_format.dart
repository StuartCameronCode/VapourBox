// Utilities for interpreting FFmpeg pixel-format strings (e.g. the `pix_fmt`
// reported by ffprobe: "yuv420p", "yuv422p10le", "yuv420p16le").

/// Best-effort per-component bit depth for an FFmpeg pixel-format string.
///
/// Returns 8 for the common 8-bit formats (yuv420p, yuv422p, nv12, rgb24, …),
/// and the explicit depth for higher-precision formats (yuv422p10le → 10,
/// yuv420p16le → 16, p010le → 10, rgb48le → 16, gray12le → 12).
///
/// Unknown or null formats fall back to 8 — the conservative choice, so an
/// unrecognized format never produces a spurious "quality will be reduced"
/// warning.
int pixelFormatBitDepth(String? pixFmt) {
  if (pixFmt == null || pixFmt.trim().isEmpty) return 8;
  final f = pixFmt.trim().toLowerCase();

  // Planar YUV/GBR/gray with an explicit per-component depth suffix:
  // yuv422p10le, yuv420p16le, gbrp12le, gray10le, gray16be, …
  final planar = RegExp(r'(?:p|gray|gbrp?)(\d{1,2})(?:le|be)?$').firstMatch(f);
  if (planar != null) return int.parse(planar.group(1)!);

  // Semi-planar high-depth: p010le, p016le, p210le, p410le, p216le, …
  // (the middle digit is the subsampling, the last two are the depth).
  final semi = RegExp(r'^p\d(10|12|16)(?:le|be)?$').firstMatch(f);
  if (semi != null) return int.parse(semi.group(1)!);

  // Packed high-depth RGB: rgb48/bgr48 and rgba64/bgra64 are 16-bit/component.
  if (RegExp(r'(?:48|64)(?:le|be)?$').hasMatch(f) &&
      RegExp(r'^[argb]{3,4}').hasMatch(f)) {
    return 16;
  }

  // Everything else (yuv420p, yuv422p, yuv411p, nv12, gray, rgb24, …) is 8-bit.
  return 8;
}

/// Warning message when an enabled filter with a native [maxBitDepth] ceiling
/// will down-convert a higher-bit-depth [pixelFormat] source (a lossy 8-bit
/// round-trip), or null when no warning is warranted (pass off, no ceiling,
/// unknown format, or the source already fits).
String? filterBitDepthWarning({
  required String filterName,
  required bool enabled,
  int? maxBitDepth,
  String? pixelFormat,
}) {
  if (!enabled || maxBitDepth == null || pixelFormat == null) return null;
  final depth = pixelFormatBitDepth(pixelFormat);
  if (depth <= maxBitDepth) return null;
  return '$filterName only processes in $maxBitDepth-bit. Your $depth-bit '
      'source will be converted to $maxBitDepth-bit for this pass and back, '
      'reducing colour precision.';
}

/// Warning message when the chosen output colour format would reduce a
/// higher-bit-depth [pixelFormat] source's precision.
///
/// [targetBitDepth] is the depth the output format converts to, or null when no
/// conversion happens ("Match source"). Returns null when nothing needs saying:
/// no conversion, unknown format, or the target is deep enough to hold the
/// source — so choosing 4:2:2 10-bit for a 10-bit source stays silent, while
/// choosing it for a 12-bit source correctly says 10-bit rather than 8-bit.
String? chromaConversionBitDepthWarning({
  required int? targetBitDepth,
  String? pixelFormat,
}) {
  if (targetBitDepth == null || pixelFormat == null) return null;
  final depth = pixelFormatBitDepth(pixelFormat);
  if (depth <= targetBitDepth) return null;
  return 'Your $depth-bit source will be output as $targetBitDepth-bit in this '
      'colour format. Choose "Match source" to keep the source\'s bit depth'
      '${targetBitDepth < 10 ? ', or 4:2:2 10-bit to keep more of it' : ''}.';
}
