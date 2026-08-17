import 'dart:typed_data';

/// Histogram binning for the preview scope.
///
/// Why this exists: forum advice on setting levels is literally "watch the
/// histogram", and this app ships colour controls (Levels, Tweak, white
/// balance) with no way to see what they are doing. Automatic levels and
/// automatic white balance are coming too, and a user needs to be able to
/// sanity-check what they decided.
///
/// Why it is computed here rather than in VapourSynth: the app already holds
/// the processed preview as PNG bytes, so binning it costs no worker round
/// trip, no template change and no deps release, and it refreshes exactly when
/// the preview does.
///
/// This file is deliberately pure — no Flutter imports, no I/O — so the
/// binning can be unit-tested without a widget.

/// The channels a scope can display.
enum HistogramChannel { luma, red, green, blue }

/// Bin counts for one decoded frame.
///
/// Every channel has [binCount] bins, indexed by the 8-bit sample value.
class HistogramData {
  /// Number of bins per channel — one per 8-bit level.
  static const int binCount = 256;

  /// Rec.709 luma weights, pre-multiplied by 256 so luma can be derived with
  /// integer math. They sum to exactly 256, so a neutral grey `v` maps back to
  /// bin `v` with no drift.
  static const int _lumaR = 54; // 0.2126 * 256
  static const int _lumaG = 183; // 0.7152 * 256
  static const int _lumaB = 19; // 0.0722 * 256

  final Uint32List _luma;
  final Uint32List _red;
  final Uint32List _green;
  final Uint32List _blue;

  /// How many pixels were counted. Zero for [HistogramData.empty].
  final int sampleCount;

  const HistogramData._(
    this._luma,
    this._red,
    this._green,
    this._blue,
    this.sampleCount,
  );

  /// A histogram with no samples — the "no preview yet" state.
  factory HistogramData.empty() => HistogramData._(
        Uint32List(binCount),
        Uint32List(binCount),
        Uint32List(binCount),
        Uint32List(binCount),
        0,
      );

  /// True when nothing was counted, so painters can draw an empty state
  /// instead of dividing by zero.
  bool get isEmpty => sampleCount == 0;

  /// The bins for [channel]. The returned list is the live backing store —
  /// treat it as read-only.
  Uint32List bins(HistogramChannel channel) {
    switch (channel) {
      case HistogramChannel.luma:
        return _luma;
      case HistogramChannel.red:
        return _red;
      case HistogramChannel.green:
        return _green;
      case HistogramChannel.blue:
        return _blue;
    }
  }

  /// The tallest bin in [channel], including the clipping bins at 0 and 255.
  int peak(HistogramChannel channel) {
    final b = bins(channel);
    var maximum = 0;
    for (var i = 0; i < binCount; i++) {
      if (b[i] > maximum) maximum = b[i];
    }
    return maximum;
  }

  /// The tallest bin in [channel] ignoring the two clipping bins.
  ///
  /// A letterboxed or heavily crushed frame piles an enormous count into bin 0,
  /// and scaling the plot to that flattens everything else into invisibility.
  /// Scaling to the interior peak instead keeps the shape of the picture
  /// readable; the clipping bins are drawn clamped to the top of the plot.
  int interiorPeak(HistogramChannel channel) {
    final b = bins(channel);
    var maximum = 0;
    for (var i = 1; i < binCount - 1; i++) {
      if (b[i] > maximum) maximum = b[i];
    }
    return maximum;
  }

  /// The scale a plot of [channel] should use: the interior peak, falling back
  /// to the overall peak for a frame that is nothing but clipped values.
  int plotScale(HistogramChannel channel) {
    final interior = interiorPeak(channel);
    return interior > 0 ? interior : peak(channel);
  }

  /// Fraction of pixels sitting at luma 0 (crushed blacks), 0.0 to 1.0.
  double get shadowClipFraction =>
      sampleCount == 0 ? 0.0 : _luma[0] / sampleCount;

  /// Fraction of pixels sitting at luma 255 (blown highlights), 0.0 to 1.0.
  double get highlightClipFraction =>
      sampleCount == 0 ? 0.0 : _luma[binCount - 1] / sampleCount;
}

/// Bins raw RGBA bytes into per-channel counts.
///
/// [rgba] is tightly packed 8-bit RGBA, four bytes per pixel — exactly what
/// `ui.Image.toByteData(format: ImageByteFormat.rawRgba)` returns. Decoding
/// through `dart:ui` is what makes this safe for VapourBox's high-bit-depth
/// path: a >8-bit source produces an `rgb48be` preview PNG (16 bits per
/// channel), so the *file* has no 4-byte RGBA stride. The codec normalises it
/// to 8-bit RGBA before we ever see it.
///
/// [pixelStride] counts every Nth pixel, for capping the cost on large frames.
/// Values below 1 are treated as 1. A trailing partial pixel is ignored, and
/// the alpha byte is ignored entirely (previews are opaque).
///
/// An empty or sub-pixel-sized buffer yields [HistogramData.empty] rather than
/// throwing, so the "no preview yet" state needs no special case at the call
/// site.
HistogramData computeHistogramFromRgba(
  Uint8List rgba, {
  int pixelStride = 1,
}) {
  final stride = pixelStride < 1 ? 1 : pixelStride;
  final pixelCount = rgba.length ~/ 4;
  if (pixelCount == 0) return HistogramData.empty();

  final luma = Uint32List(HistogramData.binCount);
  final red = Uint32List(HistogramData.binCount);
  final green = Uint32List(HistogramData.binCount);
  final blue = Uint32List(HistogramData.binCount);

  final byteStride = stride * 4;
  var samples = 0;
  for (var i = 0; i + 3 < rgba.length; i += byteStride) {
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    red[r]++;
    green[g]++;
    blue[b]++;
    // +128 rounds to nearest rather than truncating, so grey stays put.
    luma[(HistogramData._lumaR * r +
            HistogramData._lumaG * g +
            HistogramData._lumaB * b +
            128) >>
        8]++;
    samples++;
  }

  return HistogramData._(luma, red, green, blue, samples);
}

/// Picks a [pixelStride] that keeps binning to roughly [maxSamples] pixels.
///
/// Binning is O(pixels) on the UI isolate, so a 4K preview is capped rather
/// than counted in full. The shape of a histogram is unchanged by sampling
/// every Nth pixel; only the absolute counts shrink, and nothing here reads
/// those as absolutes.
///
/// The default cap is set above a full PAL/NTSC/720p frame, so this app's
/// usual sources are counted in full and only large previews subsample.
int pixelStrideFor(int pixelCount, {int maxSamples = 500000}) {
  if (pixelCount <= maxSamples || maxSamples < 1) return 1;
  return (pixelCount / maxSamples).ceil();
}
