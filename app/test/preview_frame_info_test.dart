import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/preview_frame_info.dart';

void main() {
  group('PreviewFrameInfo.parse', () {
    test('reads the worker\'s line among the rest of its stderr', () {
      final info = PreviewFrameInfo.parse('Preview: source frame 12 (...)\n'
          'Generated preview script: "x.vpy"\n'
          'PREVIEW_INFO:frame=12 sub_frame=1 sub_frames=3 generated=1\n')!;
      expect(info.frame, 12);
      expect(info.subFrame, 1);
      expect(info.subFrames, 3);
      expect(info.generated, isTrue);
      expect(info.hasSubFrames, isTrue);
    });

    test('a worker from before sub-frames reads as one real frame', () {
      final info = PreviewFrameInfo.parse('PREVIEW_INFO:frame=7\n')!;
      expect((info.frame, info.subFrame, info.subFrames, info.generated),
          (7, 0, 1, false));
      expect(info.hasSubFrames, isFalse);
    });

    test('no line, or no frame, is no info', () {
      expect(PreviewFrameInfo.parse('Error generating preview: boom'), isNull);
      expect(PreviewFrameInfo.parse('PREVIEW_INFO:sub_frame=1'), isNull);
    });

    test('a sub-frame past the count is clamped', () {
      final info = PreviewFrameInfo.parse(
          'PREVIEW_INFO:frame=3 sub_frame=9 sub_frames=2 generated=0')!;
      expect(info.subFrame, 1);
    });

    // Issue #149: the processed frame is drawn at the aspect the encode will
    // declare, not the source's.
    test('reads the output SAR the encode will declare', () {
      final info = PreviewFrameInfo.parse(
          'PREVIEW_INFO:frame=3 sub_frame=0 sub_frames=1 generated=0 sar=16/15')!;
      expect(info.outputSar, closeTo(16 / 15, 1e-9));
      expect(info.outputDar, isNull);
      // 1920x1080 padded, Preserve kept the PAL 4:3 SAR: wider than 16:9.
      expect(info.displayAspectFor(const Size(1920, 1080)),
          closeTo(1920 / 1080 * 16 / 15, 1e-9));
    });

    test('a forced DAR wins over the frame size', () {
      final info =
          PreviewFrameInfo.parse('PREVIEW_INFO:frame=3 dar=16/9')!;
      expect(info.outputDar, closeTo(16 / 9, 1e-9));
      expect(info.displayAspectFor(const Size(720, 576)), closeTo(16 / 9, 1e-9));
    });

    test('no aspect token means square pixels: the frame\'s own shape', () {
      final info = PreviewFrameInfo.parse(
          'PREVIEW_INFO:frame=3 sub_frame=0 sub_frames=1 generated=0')!;
      expect(info.outputSar, isNull);
      expect(info.outputDar, isNull);
      expect(info.displayAspectFor(const Size(1920, 1080)),
          closeTo(16 / 9, 1e-9));
    });

    test('a malformed aspect is ignored rather than drawn zero-wide', () {
      final info =
          PreviewFrameInfo.parse('PREVIEW_INFO:frame=3 sar=0/1 dar=wide')!;
      expect(info.outputSar, isNull);
      expect(info.outputDar, isNull);
      expect(info.frame, 3);
    });
  });

  group('PreviewFrameInfo.parseRatio', () {
    test('accepts the forms the worker and users write', () {
      expect(PreviewFrameInfo.parseRatio('16/9'), closeTo(16 / 9, 1e-9));
      expect(PreviewFrameInfo.parseRatio('16:9'), closeTo(16 / 9, 1e-9));
      expect(PreviewFrameInfo.parseRatio('1.5'), 1.5);
      for (final junk in [null, '', '16/0', '-4/3', 'wide', '1/2/3']) {
        expect(PreviewFrameInfo.parseRatio(junk), isNull, reason: '$junk');
      }
    });
  });
}
