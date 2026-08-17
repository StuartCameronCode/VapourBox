import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/views/histogram_data.dart';

/// Builds a tightly packed RGBA buffer from a list of [r, g, b] triples.
Uint8List rgba(List<List<int>> pixels, {int alpha = 255}) {
  final out = Uint8List(pixels.length * 4);
  for (var i = 0; i < pixels.length; i++) {
    out[i * 4] = pixels[i][0];
    out[i * 4 + 1] = pixels[i][1];
    out[i * 4 + 2] = pixels[i][2];
    out[i * 4 + 3] = alpha;
  }
  return out;
}

Uint8List solid(int r, int g, int b, int count) =>
    rgba(List.generate(count, (_) => [r, g, b]));

void main() {
  group('computeHistogramFromRgba', () {
    test('empty buffer yields the empty histogram, not an exception', () {
      final h = computeHistogramFromRgba(Uint8List(0));

      expect(h.isEmpty, isTrue);
      expect(h.sampleCount, 0);
      expect(h.shadowClipFraction, 0.0);
      expect(h.highlightClipFraction, 0.0);
      expect(h.peak(HistogramChannel.luma), 0);
      expect(h.plotScale(HistogramChannel.luma), 0);
      for (final channel in HistogramChannel.values) {
        expect(h.bins(channel).length, HistogramData.binCount);
        expect(h.bins(channel).any((c) => c != 0), isFalse);
      }
    });

    test('a buffer too short for one pixel is empty', () {
      expect(computeHistogramFromRgba(Uint8List(3)).isEmpty, isTrue);
    });

    test('all-black image piles every channel into bin 0', () {
      final h = computeHistogramFromRgba(solid(0, 0, 0, 16));

      expect(h.sampleCount, 16);
      expect(h.isEmpty, isFalse);
      for (final channel in HistogramChannel.values) {
        expect(h.bins(channel)[0], 16);
        expect(h.bins(channel)[255], 0);
        // Nothing outside bin 0.
        expect(h.bins(channel).skip(1).any((c) => c != 0), isFalse);
      }
      expect(h.shadowClipFraction, 1.0);
      expect(h.highlightClipFraction, 0.0);
      // The interior is empty, so the plot falls back to the overall peak
      // rather than trying to scale by zero.
      expect(h.interiorPeak(HistogramChannel.luma), 0);
      expect(h.peak(HistogramChannel.luma), 16);
      expect(h.plotScale(HistogramChannel.luma), 16);
    });

    test('all-white image piles every channel into bin 255', () {
      final h = computeHistogramFromRgba(solid(255, 255, 255, 10));

      expect(h.sampleCount, 10);
      for (final channel in HistogramChannel.values) {
        expect(h.bins(channel)[255], 10);
        expect(h.bins(channel)[0], 0);
      }
      expect(h.shadowClipFraction, 0.0);
      expect(h.highlightClipFraction, 1.0);
    });

    test('known 4-pixel image bins each channel independently', () {
      // Pure red, pure green, pure blue, mid grey.
      final h = computeHistogramFromRgba(rgba([
        [255, 0, 0],
        [0, 255, 0],
        [0, 0, 255],
        [128, 128, 128],
      ]));

      expect(h.sampleCount, 4);

      final red = h.bins(HistogramChannel.red);
      expect(red[255], 1); // the red pixel
      expect(red[0], 2); // green + blue pixels
      expect(red[128], 1); // the grey pixel

      final green = h.bins(HistogramChannel.green);
      expect(green[255], 1);
      expect(green[0], 2);
      expect(green[128], 1);

      final blue = h.bins(HistogramChannel.blue);
      expect(blue[255], 1);
      expect(blue[0], 2);
      expect(blue[128], 1);

      // Rec.709 weights, applied with 8.8 fixed point:
      //   red   -> (54*255 + 128) >> 8 == 54
      //   green -> (183*255 + 128) >> 8 == 182
      //   blue  -> (19*255 + 128) >> 8 == 19
      //   grey  -> 128 exactly
      final luma = h.bins(HistogramChannel.luma);
      expect(luma[54], 1);
      expect(luma[182], 1);
      expect(luma[19], 1);
      expect(luma[128], 1);
      expect(luma.fold<int>(0, (a, b) => a + b), 4);
      expect(luma[0], 0);
      expect(luma[255], 0);
    });

    test('neutral grey maps to its own bin at every level', () {
      // Grey must not drift: the weights sum to exactly 256 and rounding is
      // to nearest, so a grey ramp lands one sample in each bin.
      final ramp = rgba(List.generate(256, (v) => [v, v, v]));
      final h = computeHistogramFromRgba(ramp);

      expect(h.sampleCount, 256);
      final luma = h.bins(HistogramChannel.luma);
      for (var v = 0; v < 256; v++) {
        expect(luma[v], 1, reason: 'grey $v should land in bin $v');
      }
    });

    test('alpha is ignored', () {
      final opaque = computeHistogramFromRgba(rgba([
        [10, 20, 30]
      ], alpha: 255));
      final transparent = computeHistogramFromRgba(rgba([
        [10, 20, 30]
      ], alpha: 0));

      expect(transparent.sampleCount, opaque.sampleCount);
      for (final channel in HistogramChannel.values) {
        expect(transparent.bins(channel), opaque.bins(channel));
      }
    });

    test('a trailing partial pixel is ignored', () {
      final bytes = Uint8List.fromList([
        ...solid(0, 0, 0, 2),
        1, 2, 3, // half a pixel
      ]);

      expect(computeHistogramFromRgba(bytes).sampleCount, 2);
    });

    test('pixelStride samples every Nth pixel', () {
      final h = computeHistogramFromRgba(
        rgba([
          [0, 0, 0],
          [255, 255, 255],
          [0, 0, 0],
          [255, 255, 255],
          [0, 0, 0],
          [255, 255, 255],
        ]),
        pixelStride: 2,
      );

      expect(h.sampleCount, 3);
      expect(h.bins(HistogramChannel.luma)[0], 3);
      expect(h.bins(HistogramChannel.luma)[255], 0);
    });

    test('a stride below 1 is treated as 1 rather than looping forever', () {
      final h = computeHistogramFromRgba(solid(0, 0, 0, 4), pixelStride: 0);
      expect(h.sampleCount, 4);
    });

    test('interiorPeak ignores the clipping bins', () {
      // 100 crushed-black pixels swamping 3 mid-grey ones: scaling to the
      // overall peak would flatten the picture's actual shape to nothing.
      final h = computeHistogramFromRgba(rgba([
        ...List.generate(100, (_) => [0, 0, 0]),
        ...List.generate(3, (_) => [128, 128, 128]),
      ]));

      expect(h.peak(HistogramChannel.luma), 100);
      expect(h.interiorPeak(HistogramChannel.luma), 3);
      expect(h.plotScale(HistogramChannel.luma), 3);
      expect(h.shadowClipFraction, closeTo(100 / 103, 1e-9));
    });
  });

  group('pixelStrideFor', () {
    test('does not subsample a frame under the cap', () {
      // PAL and NTSC — this app's usual sources — count in full.
      expect(pixelStrideFor(720 * 576), 1);
      expect(pixelStrideFor(720 * 480), 1);
      expect(pixelStrideFor(500000), 1);
      expect(pixelStrideFor(0), 1);

      // Larger frames do subsample, which only scales the counts.
      expect(pixelStrideFor(1280 * 720), greaterThan(1));
    });

    test('subsamples enough to stay under the cap', () {
      expect(pixelStrideFor(1000000, maxSamples: 250000), 4);
      expect(pixelStrideFor(3840 * 2160, maxSamples: 250000), 34);

      for (final pixels in [1920 * 1080, 3840 * 2160, 7680 * 4320]) {
        final stride = pixelStrideFor(pixels, maxSamples: 250000);
        expect(pixels / stride, lessThanOrEqualTo(250000),
            reason: '$pixels px at stride $stride should stay under the cap');
      }
    });
  });
}
