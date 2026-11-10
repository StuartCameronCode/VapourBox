// Issue #149: the processed preview is drawn at the shape the encode will
// have, not the source's.
//
// Run with: flutter test test/preview_aspect_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/preview_frame_info.dart';
import 'package:vapourbox/services/field_order_detector.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';

/// Just enough of a PNG for its header to be read: signature, IHDR length and
/// type, width, height.
Uint8List _pngHeader(int width, int height) {
  final b = ByteData(24);
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < 8; i++) {
    b.setUint8(i, sig[i]);
  }
  b.setUint32(8, 13);
  b.setUint32(12, 0x49484452); // "IHDR"
  b.setUint32(16, width);
  b.setUint32(20, height);
  return b.buffer.asUint8List();
}

void main() {
  group('processedDisplayAspect', () {
    final canvas = _pngHeader(1920, 1080);

    test('square pixels: the frame\'s own shape, not the source\'s', () {
      // The reporter's setup with Square pixel aspect: nothing declared.
      final info = PreviewFrameInfo.parse('PREVIEW_INFO:frame=1')!;
      expect(processedDisplayAspect(canvas, info), closeTo(16 / 9, 1e-9));
    });

    test('a declared SAR stretches the stored size', () {
      final info = PreviewFrameInfo.parse('PREVIEW_INFO:frame=1 sar=16/15')!;
      expect(processedDisplayAspect(canvas, info),
          closeTo(1920 * 16 / 15 / 1080, 1e-9));
    });

    test('a declared DAR is used as is', () {
      final info = PreviewFrameInfo.parse('PREVIEW_INFO:frame=1 dar=4/3')!;
      expect(processedDisplayAspect(canvas, info), closeTo(4 / 3, 1e-9));
    });

    test('nothing to go on draws the frame at its own shape', () {
      final info = PreviewFrameInfo.parse('PREVIEW_INFO:frame=1')!;
      expect(processedDisplayAspect(null, info), isNull);
      expect(processedDisplayAspect(canvas, null), isNull);
      expect(processedDisplayAspect(Uint8List.fromList([1, 2, 3]), info),
          isNull);
    });
  });

  group('FieldOrderDetector.normalizeSar', () {
    test('keeps a real SAR', () {
      expect(FieldOrderDetector.normalizeSar('16:15'), '16:15');
      expect(FieldOrderDetector.normalizeSar(' 64:45 '), '64:45');
    });

    test('square, unknown and missing read as none', () {
      for (final raw in [null, '', 'N/A', '1:1', '0:1']) {
        expect(FieldOrderDetector.normalizeSar(raw), isNull, reason: '$raw');
      }
    });
  });
}
