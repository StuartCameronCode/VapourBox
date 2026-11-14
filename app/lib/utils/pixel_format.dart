// Utilities for interpreting FFmpeg pixel-format strings (e.g. the `pix_fmt`
// reported by ffprobe: "yuv420p", "yuv422p10le", "yuv420p16le").

import '../models/encoding_settings.dart';
import '../models/video_job.dart';

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
///
/// Silent for ProRes, whose depth is fixed at 10 bits by the encoder rather
/// than chosen: the advice ("Choose Match source") would not apply, and every
/// ProRes 4444 source decodes as 12-bit (`yuv444p12le`) whatever it holds, so
/// a ProRes-to-ProRes job would warn on every run. (With "Match source" it was
/// silent before, too; an explicit selection no longer reaches a ProRes
/// encode at all, and `proresChromaPinWarning` says so.)
String? chromaConversionBitDepthWarning({
  required int? targetBitDepth,
  String? pixelFormat,
  VideoCodec? codec,
}) {
  if (codec != null && codec.isProRes) return null;
  if (targetBitDepth == null || pixelFormat == null) return null;
  final depth = pixelFormatBitDepth(pixelFormat);
  if (depth <= targetBitDepth) return null;
  return 'Your $depth-bit source will be output as $targetBitDepth-bit in this '
      'colour format. Choose "Match source" to keep the source\'s bit depth'
      '${targetBitDepth < 10 ? ', or 4:2:2 10-bit to keep more of it' : ''}.';
}

/// Chroma layout of an FFmpeg pixel-format string, coarse enough for the one
/// question the UI asks of it: can a hardware encoder take this?
///
/// Mirrors `ChromaClass` in `worker/src/pixel_format.rs`, which is the authority
/// — it decides what the worker actually does. This copy only decides what the
/// warning *says*, and `hardware_encoder_chroma_warning_test.dart` pins the two
/// to the same table so they cannot drift into disagreeing on screen.
enum ChromaLayout {
  /// 4:2:0 — one colour sample per 2x2 block.
  c420,

  /// 4:2:2 and anything hardware treats like it (4:4:0, 4:1:1, 4:1:0).
  c422,

  /// 4:4:4, and RGB, which carries full colour resolution by construction.
  c444,
}

/// Best-effort chroma layout for an FFmpeg pixel-format string.
///
/// Unknown and null formats fall back to [ChromaLayout.c420] — the conservative
/// choice here, because 4:2:0 is what every encoder accepts, so an unrecognized
/// format produces no spurious warning. (`pixelFormatBitDepth` falls back the
/// same way and for the same reason.)
ChromaLayout pixelFormatChromaLayout(String? pixFmt) {
  if (pixFmt == null || pixFmt.trim().isEmpty) return ChromaLayout.c420;
  final f = pixFmt.trim().toLowerCase();

  // Planar YUV: the three digits after the family prefix are the subsampling.
  final planar = RegExp(r'^yuv[aj]?(\d{3})').firstMatch(f);
  if (planar != null) {
    switch (planar.group(1)!) {
      case '420':
        return ChromaLayout.c420;
      // 4:1:0 and 4:1:1 subsample more coarsely than 4:2:2 horizontally and
      // 4:4:0 more coarsely vertically, but none of them is 4:2:0, and no
      // hardware encoder takes any of them — so they warn alongside 4:2:2.
      case '410':
      case '411':
      case '422':
      case '440':
        return ChromaLayout.c422;
      default:
        return ChromaLayout.c444;
    }
  }

  // Semi-planar: nv12/nv21 are 4:2:0, nv16 4:2:2, nv24/nv42 4:4:4; p010/p016
  // are 4:2:0, p210/p216 4:2:2, p410/p416 4:4:4 (the middle digit is the
  // subsampling, as in `pixelFormatBitDepth`).
  const semiPlanar = {
    'nv12': ChromaLayout.c420,
    'nv21': ChromaLayout.c420,
    'nv16': ChromaLayout.c422,
    'nv24': ChromaLayout.c444,
    'nv42': ChromaLayout.c444,
  };
  final stem = f.replaceFirst(RegExp(r'(le|be)$'), '');
  final named = semiPlanar[stem];
  if (named != null) return named;
  final p = RegExp(r'^p(\d)(?:10|12|16)$').firstMatch(stem);
  if (p != null) {
    switch (p.group(1)!) {
      case '0':
        return ChromaLayout.c420;
      case '2':
        return ChromaLayout.c422;
      default:
        return ChromaLayout.c444;
    }
  }

  // Gray has no chroma at all, so every encoder can hold it.
  if (stem.startsWith('gray') || stem.startsWith('ya')) return ChromaLayout.c420;

  // RGB and planar GBR carry full colour resolution.
  if (RegExp(r'^(a?rgb|a?bgr|gbra?p)').hasMatch(stem)) return ChromaLayout.c444;

  return ChromaLayout.c420;
}

/// Warning message when the chosen output colour format is one the selected
/// hardware encoder cannot take, and the worker will therefore substitute
/// another — or null when there is nothing to say.
///
/// This is the UI half of issue #74. An encoder's declared format list is
/// compiled into ffmpeg, but NVENC's real capabilities are queried from the
/// driver at open time: a recent ffmpeg advertises `yuv422p` on `h264_nvenc`
/// for Blackwell's 4:2:2 support, and every earlier card then failed the whole
/// job. The worker now substitutes an encodable format instead of failing, so
/// this exists to say so *before* the job runs rather than only in its log.
///
/// **Keep in step with `VideoCodec::forced_pix_fmt` in
/// `worker/src/models/video_job.rs`**, which is what actually happens. The two
/// share a table of cases in their tests.
///
/// [chromaSubsampling] decides the format outright unless it is
/// [ChromaSubsampling.original], in which case the source's [pixelFormat] does.
String? hardwareEncoderChromaWarning({
  required VideoCodec codec,
  required ChromaSubsampling chromaSubsampling,
  String? pixelFormat,
}) {
  // Only NVENC and QSV advertise formats their hardware may not have.
  // VideoToolbox never does, so its negotiation is trustworthy; AMF is pinned
  // to nv12 unconditionally and has been since issue #51, so it converts
  // whatever it is given and there is no surprise to warn about.
  final isNvenc = codec.isNvenc;
  final isQsv = codec == VideoCodec.h264Qsv || codec == VideoCodec.h265Qsv;
  if (!isNvenc && !isQsv) return null;

  // What the encoder will actually be handed: the output conversion when one is
  // selected, the source's own format otherwise.
  final ChromaLayout layout;
  final int depth;
  final String describedAs;
  switch (chromaSubsampling) {
    case ChromaSubsampling.original:
      // Nothing to warn about until a file is loaded and we know its format.
      if (pixelFormat == null) return null;
      layout = pixelFormatChromaLayout(pixelFormat);
      depth = pixelFormatBitDepth(pixelFormat);
      describedAs = 'Your source is $pixelFormat, and "Match source" keeps it';
    default:
      // Derived from the option's own format name rather than enumerated.
      // The hand-written test this replaces returned c422 for anything that
      // was not one of the two 4:2:0 variants, so the 4:4:4 option would have
      // reported "cannot encode 4:2:2 on most GPUs" — the right advice under
      // the wrong reason. `value` is exactly the shape the parser expects
      // (`yuv444p10` -> c444), so a format added later cannot repeat this.
      layout = pixelFormatChromaLayout(chromaSubsampling.value);
      depth = chromaSubsampling.outputBitDepth ?? 8;
      describedAs = '${chromaSubsampling.label} is selected';
  }

  final chromaUnsupported = layout != ChromaLayout.c420;
  // Neither family has a 10-bit H.264 mode at all.
  final depthUnsupported = depth > 8 && codec.isH264;
  if (!chromaUnsupported && !depthUnsupported) return null;

  // Mirrors forced_pix_fmt: H.264 has only 8-bit 4:2:0; HEVC keeps the depth.
  final substitute = codec.isH264
      ? '4:2:0 8-bit'
      : (depth > 8 ? '4:2:0 10-bit' : '4:2:0 8-bit');

  final reason = chromaUnsupported
      ? '${codec.encoderFamily} cannot encode ${layout == ChromaLayout.c444 ? "4:4:4" : "4:2:2"} '
          'on most GPUs'
      : '${codec.encoderFamily} has no 10-bit H.264 mode';

  final advice = codec.isH264 && depth > 8
      ? ' Choose an H.265 encoder to keep the 10-bit grading, or a software '
          'encoder to keep the colour detail as well.'
      : ' Choose a software encoder to keep it as it is.';

  return '$describedAs, but $reason, so the output will be converted to '
      '$substitute.$advice';
}

/// Warning when a ProRes profile overrides the chosen output colour format or
/// changes the source's chroma, or `null` when there is nothing to say.
///
/// A ProRes profile stores one format: 10-bit 4:2:2 (Proxy, LT, 422, 422 HQ)
/// or 10-bit 4:4:4 (4444, 4444 XQ). The worker converts to exactly that in the
/// script, whatever Color Format is selected
/// (`EncodingSettings::effective_chroma_subsampling`), so that the conversion
/// of an interlaced source is field-aware (ffmpeg's `-pix_fmt` blended the two
/// fields' chroma). The selection is therefore ignored rather than applied and
/// then padded or reduced, and what is lost or padded depends on the
/// **source** alone.
///
/// A deliberate sibling of [hardwareEncoderChromaWarning] rather than an
/// extension of it, because the two make opposite claims. That one says the
/// hardware *cannot* encode what you asked for and something will be lost.
/// This one says the profile *defines* what is stored — ProRes 4444 pads 4:2:0
/// up rather than losing anything, and the cost is file size, not detail.
///
/// **It is a second implementation of the worker's decision, and that is the
/// risk.** If the two disagree the interface promises one thing and the encode
/// does another, which is worse than either being wrong alone. Both sides are
/// pinned to the same table of cases:
/// `prores_converts_to_its_profile_format_whatever_is_selected` in
/// `worker/src/models/video_job.rs` against
/// `app/test/prores_chroma_pin_warning_test.dart`. Change one, change both.
///
/// Deliberately silent about bit depth on its own. ProRes is always 10-bit, so
/// an 8-bit selection into any profile is overridden — warning about depth
/// alone would fire on the majority of ProRes jobs, and a banner that is
/// always there is wallpaper. A 4:2:0 source into a 4:2:2 profile with "Match
/// source" stays quiet for the same reason: it is the ordinary capture case.
String? proresChromaPinWarning({
  required VideoCodec codec,
  required ChromaSubsampling chromaSubsampling,
  String? pixelFormat,
}) {
  if (!codec.isProRes) return null;
  return _fixedFormatWarning(
    codec: codec,
    stored: codec.fixedOutputFormat!,
    selection: chromaSubsampling,
    pixelFormat: pixelFormat,
  );
}

/// The shared body of [proresChromaPinWarning] and [v210ChromaPinWarning]:
/// [codec] stores [stored] whatever [selection] is. Three facts, each its own
/// sentence, the same three the worker's tables assert:
///   * ignored — a selection other than "Match source" or [stored] itself;
///   * lost    — [stored] is 4:2:2 and the source is 4:4:4;
///   * padded  — [stored] is 4:4:4 and the source is narrower.
/// Lost and padded need the source's format, so before a file is loaded only
/// "ignored" can be said.
String? _fixedFormatWarning({
  required VideoCodec codec,
  required ChromaSubsampling stored,
  required ChromaSubsampling selection,
  String? pixelFormat,
}) {
  final stores444 = stored == ChromaSubsampling.yuv444p10;
  final storedName = stores444 ? '4:4:4' : '4:2:2';
  final source = pixelFormat == null ? null : pixelFormatChromaLayout(pixelFormat);
  final ignored =
      selection != ChromaSubsampling.original && selection != stored;
  final lost = !stores444 && source == ChromaLayout.c444;
  final padded = stores444 && source != null && source != ChromaLayout.c444;

  final parts = <String>[];
  if (ignored) {
    parts.add('${selection.label} is selected, but ${codec.displayName} '
        'always stores 10-bit $storedName, so this setting is ignored: the '
        'picture goes to 10-bit $storedName directly.');
  }
  if (lost) {
    parts.add('Your source is $pixelFormat, and ${codec.displayName} stores '
        '4:2:2, so its chroma will be resampled down to it. Choose ProRes 4444 '
        'to keep the full chroma.');
  } else if (ignored &&
      !stores444 &&
      pixelFormatChromaLayout(selection.value) == ChromaLayout.c444) {
    // Asked for 4:4:4 from a source that may not have it: name the way to
    // get 4:4:4 without claiming anything is lost.
    parts.add('Choose ProRes 4444 to store 4:4:4.');
  }
  if (padded) {
    parts.add('Your source is $pixelFormat, so ${codec.displayName} pads its '
        'chroma up to 4:4:4. Nothing is lost, but the file is much larger '
        'than the colour detail in it warrants — ProRes 422 HQ is the 4:2:2 '
        'equivalent.');
  }
  return parts.isEmpty ? null : parts.join(' ');
}

/// Warning when v210 overrides the chosen output colour format or changes the
/// source's chroma, or `null` when there is nothing to say.
///
/// v210 stores uncompressed 10-bit 4:2:2 and nothing else, so the worker
/// converts to exactly that in the script, whatever Color Format is selected
/// (`EncodingSettings::effective_chroma_subsampling`). A sibling of
/// [proresChromaPinWarning], with the same rules and the same silences:
/// padding 4:2:0 up loses nothing, and depth on its own is not mentioned (the
/// bit-depth warning covers a source deeper than 10 bits, from the effective
/// format).
///
/// **A second implementation of the worker's decision.** Pinned case for case
/// to `v210_stores_422_10_whatever_is_selected` in
/// `worker/src/models/video_job.rs` by `app/test/v210_test.dart`.
/// Change one, change both.
String? v210ChromaPinWarning({
  required VideoCodec codec,
  required ChromaSubsampling chromaSubsampling,
  String? pixelFormat,
}) {
  if (!codec.isUncompressed) return null;
  return _fixedFormatWarning(
    codec: codec,
    stored: ChromaSubsampling.yuv422p10,
    selection: chromaSubsampling,
    pixelFormat: pixelFormat,
  );
}
