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
  });
}
