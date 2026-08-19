import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/utils/pixel_format.dart';
import 'package:vapourbox/models/encoding_settings.dart';

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
    test('warns when an 8-bit output format would reduce a 10-bit source', () {
      final msg = chromaConversionBitDepthWarning(
          targetBitDepth: 8, pixelFormat: 'yuv422p10le');
      expect(msg, isNotNull);
      expect(msg, contains('10-bit'));
      expect(msg, contains('8-bit'));
      // The 8-bit formats are no longer the only way to normalize chroma, so
      // the warning points at the option that keeps the precision.
      expect(msg, contains('4:2:2 10-bit'));
    });

    test('silent when keeping the source format (no conversion)', () {
      expect(
          chromaConversionBitDepthWarning(
              targetBitDepth: null, pixelFormat: 'yuv422p10le'),
          isNull);
    });

    test('silent for an 8-bit source even when converting', () {
      expect(
          chromaConversionBitDepthWarning(
              targetBitDepth: 8, pixelFormat: 'yuv420p'),
          isNull);
    });

    test('silent when a 10-bit target holds a 10-bit source', () {
      expect(
          chromaConversionBitDepthWarning(
              targetBitDepth: 10, pixelFormat: 'yuv422p10le'),
          isNull);
    });

    test('a 10-bit target still warns about a deeper source, naming 10-bit', () {
      // 12-bit ProRes 4444 XQ into the 10-bit format: a real reduction, but not
      // to 8-bit — the message has to say which.
      final msg = chromaConversionBitDepthWarning(
          targetBitDepth: 10, pixelFormat: 'yuv444p12le');
      expect(msg, isNotNull);
      expect(msg, contains('12-bit'));
      expect(msg, contains('10-bit'));
      expect(msg, isNot(contains('8-bit')));
      // Nothing deeper is on offer, so don't advertise a better option.
      expect(msg, isNot(contains('4:2:2 10-bit')));
    });

    test('silent when the pixel format is null', () {
      expect(
          chromaConversionBitDepthWarning(targetBitDepth: 8, pixelFormat: null),
          isNull);
    });
  });

  group('ChromaSubsampling output depth', () {
    test('every option declares the depth it converts to', () {
      // The warning above is driven entirely by this field, so a new option
      // that forgets it would silently stop warning.
      expect(ChromaSubsampling.original.outputBitDepth, isNull);
      expect(ChromaSubsampling.yuv420.outputBitDepth, 8);
      expect(ChromaSubsampling.yuv420p10.outputBitDepth, 10);
      expect(ChromaSubsampling.yuv422.outputBitDepth, 8);
      expect(ChromaSubsampling.yuv422p10.outputBitDepth, 10);
    });

    test('values match the worker enum serde names', () {
      // ChromaSubsampling in worker/src/models/video_job.rs uses
      // rename_all = "lowercase" over the variant names, so these strings are
      // the wire format. A mismatch makes the worker reject the job config.
      expect(ChromaSubsampling.original.value, 'original');
      expect(ChromaSubsampling.yuv420.value, 'yuv420');
      expect(ChromaSubsampling.yuv420p10.value, 'yuv420p10');
      expect(ChromaSubsampling.yuv422.value, 'yuv422');
      expect(ChromaSubsampling.yuv422p10.value, 'yuv422p10');
    });
  });
}
