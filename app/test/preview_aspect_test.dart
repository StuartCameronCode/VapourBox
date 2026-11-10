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
  group('comparison aspects through the view model', viewModelAspects);

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

/// What the comparison panel draws each side at, through the view model it
/// reads — so dropping the stored aspect, or computing it from the frame
/// info (null once the scrubber moves), fails here.
void viewModelAspects() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MainViewModel vm;
  setUp(() => vm = MainViewModel());
  tearDown(() => vm.dispose());

  // NTSC DVD: 720x480 with 32:27 pixels is 16:9 on screen.
  const dvd = 720 / 480 * 32 / 27;

  test('an anamorphic source with no reshaping pass: both sides 16:9', () {
    vm.debugAddQueueItemForTest('/tmp/vb_dvd.mkv',
        width: 720, height: 480, sar: '32:27');
    expect(vm.sourceDisplayAspect, closeTo(dvd, 1e-9));

    // A denoise-only pipeline: the worker re-stamps the source's SAR.
    vm.debugAcceptProcessedPreview(_pngHeader(720, 480),
        PreviewFrameInfo.parse('PREVIEW_INFO:frame=0 sar=32/27'));
    expect(vm.comparisonAfterAspect, closeTo(dvd, 1e-9),
        reason: 'the processed frame must keep the source\'s shape when '
            'nothing reshapes it');
  });

  test('before a processed frame exists the after side is the source\'s',
      () {
    vm.debugAddQueueItemForTest('/tmp/vb_dvd.mkv',
        width: 720, height: 480, sar: '32:27');
    expect(vm.processedPreview, isNull);
    expect(vm.comparisonAfterAspect, closeTo(dvd, 1e-9));
  });

  test('square-pixel source: no correction on either side', () {
    vm.debugAddQueueItemForTest('/tmp/vb_sq.mkv', width: 1920, height: 1080);
    expect(vm.sourceDisplayAspect, isNull);
    vm.debugAcceptProcessedPreview(_pngHeader(1920, 1080),
        PreviewFrameInfo.parse('PREVIEW_INFO:frame=0'));
    expect(vm.comparisonAfterAspect, closeTo(16 / 9, 1e-9));
  });

  test('a reshaped frame is drawn at its own shape, not the source\'s', () {
    vm.debugAddQueueItemForTest('/tmp/vb_pal.mkv',
        width: 720, height: 576, sar: '16:15');
    vm.debugAcceptProcessedPreview(_pngHeader(1920, 1080),
        PreviewFrameInfo.parse('PREVIEW_INFO:frame=0'));
    expect(vm.sourceDisplayAspect, closeTo(4 / 3, 1e-9));
    expect(vm.comparisonAfterAspect, closeTo(16 / 9, 1e-9));
  });

  test('the processed aspect survives a scrubber move', () async {
    vm.debugAddQueueItemForTest('/tmp/vb_pal.mkv',
        width: 720, height: 576, sar: '16:15');
    // Rendered for frame 7; the scrubber then sits somewhere else (with no
    // video loaded every position maps to frame 0).
    vm.debugAcceptProcessedPreview(_pngHeader(1920, 1080),
        PreviewFrameInfo.parse('PREVIEW_INFO:frame=7'));

    // The image stays on screen until the next preview replaces it, but the
    // frame info no longer matches the scrubber's frame.
    await vm.setScrubberPosition(0.5);
    expect(vm.previewFrameInfo, isNull);
    expect(vm.processedPreview, isNotNull);
    expect(vm.comparisonAfterAspect, closeTo(16 / 9, 1e-9));
  });

  test('a failed preview clears the stored aspect with the image', () {
    vm.debugAddQueueItemForTest('/tmp/vb_pal.mkv',
        width: 720, height: 576, sar: '16:15');
    vm.debugAcceptProcessedPreview(_pngHeader(1920, 1080),
        PreviewFrameInfo.parse('PREVIEW_INFO:frame=0'));
    vm.debugAcceptProcessedPreview(null, null);
    expect(vm.processedPreviewAspect, isNull);
    expect(vm.comparisonAfterAspect, closeTo(4 / 3, 1e-9));
  });
}
