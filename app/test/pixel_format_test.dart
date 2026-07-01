import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/utils/pixel_format.dart';

void main() {
  group('pixelFormatBitDepth', () {
    test('8-bit formats', () {
      for (final f in [
        'yuv420p', 'yuv422p', 'yuv444p', 'yuv411p', 'yuv440p',
        'yuvj420p', 'yuvj422p', 'nv12', 'nv21', 'gray', 'rgb24', 'bgr24',
        'rgba', 'bgra', 'gbrp',
      ]) {
        expect(pixelFormatBitDepth(f), 8, reason: f);
      }
    });

    test('10-bit formats', () {
      for (final f in [
        'yuv420p10le', 'yuv422p10le', 'yuv444p10le', 'yuv420p10be',
        'gbrp10le', 'gray10le', 'p010le', 'p210le', 'p410le',
      ]) {
        expect(pixelFormatBitDepth(f), 10, reason: f);
      }
    });

    test('12-bit formats', () {
      for (final f in ['yuv420p12le', 'yuv444p12le', 'gray12le', 'gbrp12le']) {
        expect(pixelFormatBitDepth(f), 12, reason: f);
      }
    });

    test('16-bit formats', () {
      for (final f in [
        'yuv420p16le', 'yuv444p16le', 'gray16le', 'gbrp16le',
        'p016le', 'p216le', 'rgb48le', 'bgr48le', 'rgba64le', 'bgra64be',
      ]) {
        expect(pixelFormatBitDepth(f), 16, reason: f);
      }
    });

    test('null / empty / unknown fall back to 8 (no spurious warning)', () {
      expect(pixelFormatBitDepth(null), 8);
      expect(pixelFormatBitDepth(''), 8);
      expect(pixelFormatBitDepth('  '), 8);
      expect(pixelFormatBitDepth('unknown'), 8);
      expect(pixelFormatBitDepth('some_future_format'), 8);
    });

    test('case and whitespace tolerant', () {
      expect(pixelFormatBitDepth('YUV422P10LE'), 10);
      expect(pixelFormatBitDepth(' yuv420p '), 8);
    });

    test('the ProRes 422 case from the bug report', () {
      // The 10-bit source that triggered the IVTC fix.
      expect(pixelFormatBitDepth('yuv422p10le'), 10);
    });
  });

  group('filterBitDepthWarning', () {
    String? call({
      bool enabled = true,
      int? maxBitDepth = 8,
      String? pixelFormat = 'yuv422p10le',
    }) =>
        filterBitDepthWarning(
          filterName: 'DeScratch',
          enabled: enabled,
          maxBitDepth: maxBitDepth,
          pixelFormat: pixelFormat,
        );

    test('warns for a 10-bit source on an 8-bit-only filter', () {
      final msg = call();
      expect(msg, isNotNull);
      expect(msg, contains('DeScratch'));
      expect(msg, contains('8-bit'));
      expect(msg, contains('10-bit'));
    });

    test('silent when the pass is disabled', () {
      expect(call(enabled: false), isNull);
    });

    test('silent when the filter has no bit-depth ceiling', () {
      expect(call(maxBitDepth: null), isNull);
    });

    test('silent for an 8-bit source', () {
      expect(call(pixelFormat: 'yuv420p'), isNull);
    });

    test('silent when the source fits (depth == ceiling)', () {
      expect(call(maxBitDepth: 10, pixelFormat: 'yuv422p10le'), isNull);
    });

    test('silent when the pixel format is unknown/null', () {
      expect(call(pixelFormat: null), isNull);
    });
  });

  group('chromaConversionBitDepthWarning', () {
    test('warns when converting a >8-bit source', () {
      final msg = chromaConversionBitDepthWarning(
          converting: true, pixelFormat: 'yuv422p10le');
      expect(msg, isNotNull);
      expect(msg, contains('10-bit'));
      expect(msg, contains('8-bit'));
    });

    test('silent when keeping Original (not converting)', () {
      expect(
          chromaConversionBitDepthWarning(
              converting: false, pixelFormat: 'yuv422p10le'),
          isNull);
    });

    test('silent for an 8-bit source even when converting', () {
      expect(
          chromaConversionBitDepthWarning(
              converting: true, pixelFormat: 'yuv420p'),
          isNull);
    });

    test('silent when the pixel format is null', () {
      expect(
          chromaConversionBitDepthWarning(converting: true, pixelFormat: null),
          isNull);
    });
  });
}
