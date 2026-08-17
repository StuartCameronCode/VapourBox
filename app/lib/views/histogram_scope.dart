import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'histogram_data.dart';

/// A histogram overlay for the preview.
///
/// Forum advice on setting levels is literally "watch the histogram", and this
/// app has colour controls with no way to see what they are doing — plus
/// automatic levels and automatic white balance on the way, which a user needs
/// to be able to sanity-check.
///
/// It bins the preview image the app already holds, so it costs no worker round
/// trip and refreshes whenever the preview does. Binning happens once per image
/// (in [didUpdateWidget]), never per repaint.
class HistogramScope extends StatefulWidget {
  /// Encoded preview image (PNG). Null or empty renders the empty state.
  final Uint8List? imageBytes;

  /// Invoked by the card's close button, if provided.
  final VoidCallback? onClose;

  /// Width of the scope card.
  final double width;

  /// Height of the plot area (excluding header and footer).
  final double plotHeight;

  const HistogramScope({
    super.key,
    required this.imageBytes,
    this.onClose,
    this.width = 232,
    this.plotHeight = 88,
  });

  @override
  State<HistogramScope> createState() => _HistogramScopeState();
}

enum _ScopeMode { luma, rgb }

class _HistogramScopeState extends State<HistogramScope> {
  HistogramData? _data;
  _ScopeMode _mode = _ScopeMode.luma;

  /// Guards against an older decode finishing after a newer one.
  int _requestToken = 0;
  bool _isBinning = false;

  @override
  void initState() {
    super.initState();
    _rebin();
  }

  @override
  void didUpdateWidget(covariant HistogramScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new preview is always a new buffer, so identity is the right test —
    // and it keeps a rebuild from re-decoding the same bytes.
    if (!identical(oldWidget.imageBytes, widget.imageBytes)) {
      _rebin();
    }
  }

  Future<void> _rebin() async {
    final bytes = widget.imageBytes;
    final token = ++_requestToken;

    if (bytes == null || bytes.isEmpty) {
      if (mounted && _data != null) setState(() => _data = null);
      return;
    }

    if (mounted && !_isBinning) setState(() => _isBinning = true);

    final data = await _binEncodedImage(bytes);

    if (!mounted || token != _requestToken) return;
    setState(() {
      _data = data;
      _isBinning = false;
    });
  }

  /// Decodes [bytes] and bins the result.
  ///
  /// The decode goes through `instantiateImageCodec`, which normalises to 8-bit
  /// RGBA. That matters here: a >8-bit source gives an `rgb48be` preview PNG
  /// (16 bits per channel), so the encoded file has no 4-byte stride to assume.
  static Future<HistogramData?> _binEncodedImage(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;
      final rgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      return computeHistogramFromRgba(
        rgba,
        pixelStride: pixelStrideFor(image.width * image.height),
      );
    } catch (_) {
      // A truncated or unreadable preview must not take the panel down.
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final data = _data;

    return Container(
      width: widget.width,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        // Sits on top of the image, so it needs its own ground rather than
        // borrowing whatever pixels are behind it.
        color: colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 6,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          const SizedBox(height: 4),
          SizedBox(
            height: widget.plotHeight,
            child: data == null || data.isEmpty
                ? _buildEmptyPlot(context)
                : CustomPaint(
                    painter: _HistogramPainter(
                      data: data,
                      channels: _mode == _ScopeMode.luma
                          ? const [HistogramChannel.luma]
                          : const [
                              HistogramChannel.red,
                              HistogramChannel.green,
                              HistogramChannel.blue,
                            ],
                      traceColors: _mode == _ScopeMode.luma
                          ? [colorScheme.onSurface]
                          : _rgbTraceColors(theme.brightness),
                      gridColor: colorScheme.outline.withValues(alpha: 0.25),
                      borderColor: colorScheme.outline.withValues(alpha: 0.5),
                    ),
                    child: const SizedBox.expand(),
                  ),
          ),
          const SizedBox(height: 4),
          _buildFooter(context, data),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      children: [
        Expanded(
          child: Text(
            'Histogram',
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.8),
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        _buildModeButton(context, _ScopeMode.luma, 'Luma'),
        const SizedBox(width: 2),
        _buildModeButton(context, _ScopeMode.rgb, 'RGB'),
        if (widget.onClose != null) ...[
          const SizedBox(width: 2),
          Tooltip(
            message: 'Hide histogram',
            child: InkWell(
              onTap: widget.onClose,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.close,
                  size: 14,
                  color: colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildModeButton(BuildContext context, _ScopeMode mode, String label) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = _mode == mode;

    return InkWell(
      onTap: selected ? null : () => setState(() => _mode = mode),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: selected ? colorScheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: selected
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurface.withValues(alpha: 0.6),
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyPlot(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: Center(
        child: Text(
          _isBinning ? 'Reading preview...' : 'No preview yet',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context, HistogramData? data) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: colorScheme.onSurface.withValues(alpha: 0.6),
    );

    final clipped = data != null && !data.isEmpty
        ? 'clip ${_percent(data.shadowClipFraction)} / '
            '${_percent(data.highlightClipFraction)}'
        : '';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('0', style: style),
        // Flexible + ellipsis: the readout is the only variable-width thing
        // here, and a large text scale must not overflow the card.
        Flexible(
          child: Tooltip(
            message: 'Pixels at black (0) / at white (255)',
            child: Text(
              clipped,
              style: style,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        Text('255', style: style),
      ],
    );
  }

  static String _percent(double fraction) {
    final value = fraction * 100;
    if (value <= 0) return '0%';
    if (value < 0.1) return '<0.1%';
    final text = value.toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}%';
  }

  /// The three channel traces are the one place a literal colour is right: the
  /// channel *is* the colour, so a themed accent would be meaningless. These
  /// are Material palette entries (the same source as the in/out markers in
  /// the scrubber), picked per brightness so they stay legible on both themes.
  static List<Color> _rgbTraceColors(Brightness brightness) {
    return brightness == Brightness.dark
        ? [Colors.red.shade400, Colors.green.shade400, Colors.blue.shade400]
        : [Colors.red.shade700, Colors.green.shade800, Colors.blue.shade800];
  }
}

/// Paints one or more channel traces into the plot rect.
///
/// The painter does no binning — it reads counts that were computed once when
/// the image changed, so a resize or a theme change is a cheap repaint.
class _HistogramPainter extends CustomPainter {
  final HistogramData data;
  final List<HistogramChannel> channels;
  final List<Color> traceColors;
  final Color gridColor;
  final Color borderColor;

  _HistogramPainter({
    required this.data,
    required this.channels,
    required this.traceColors,
    required this.gridColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.save();
    canvas.clipRRect(rrect);

    // Quarter-tone gridlines, the reference marks for judging a level move.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    for (var c = 0; c < channels.length; c++) {
      final channel = channels[c];
      final color = traceColors[c % traceColors.length];
      final scale = data.plotScale(channel);
      if (scale <= 0) continue;
      _paintChannel(canvas, size, data.bins(channel), scale, color,
          filled: channels.length == 1);
    }

    canvas.restore();
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _paintChannel(
    Canvas canvas,
    Size size,
    Uint32List bins,
    int scale,
    Color color, {
    required bool filled,
  }) {
    final binWidth = size.width / HistogramData.binCount;
    final path = Path()..moveTo(0, size.height);

    for (var i = 0; i < HistogramData.binCount; i++) {
      // Bins 0 and 255 can tower over the rest; clamping keeps the plot's
      // shape readable while still showing that they are pegged.
      final normalized = (bins[i] / scale).clamp(0.0, 1.0);
      final y = size.height - normalized * size.height;
      final x0 = i * binWidth;
      path.lineTo(x0, y);
      path.lineTo(x0 + binWidth, y);
    }
    path.lineTo(size.width, size.height);

    if (filled) {
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.35));
    } else {
      // Overlapping channels: additive-ish fills so neutral areas read as a
      // single stack rather than whichever channel was painted last.
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.22));
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter oldDelegate) {
    return !identical(oldDelegate.data, data) ||
        !listEquals(oldDelegate.channels, channels) ||
        !listEquals(oldDelegate.traceColors, traceColors) ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.borderColor != borderColor;
  }
}
