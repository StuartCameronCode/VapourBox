// Guards the hardware-encoder functional probe against regressing to a frame
// size that hardware encoders reject (issue #51: AMD AMF fails at 64x64, so
// working AMF encoders were reported as broken).
//
// Run with: flutter test test/hardware_encoder_probe_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/hardware_encoder_detector.dart';

void main() {
  /// The largest minimum-dimension any bundled hardware encoder imposes. AMF is
  /// the strictest at 192x128 on some ASICs; the probe must clear it with room
  /// to spare on both axes.
  const int strictestEncoderMinimum = 192;

  test('probes at a frame size every hardware encoder accepts', () {
    expect(
      HardwareEncoderDetector.probeFrameSize,
      greaterThan(strictestEncoderMinimum),
      reason: 'a frame below the encoder minimum makes a working encoder '
          'report failure (issue #51)',
    );
    // Odd dimensions are their own source of encoder rejections.
    expect(HardwareEncoderDetector.probeFrameSize.isEven, isTrue);
  });

  test('probe args encode one frame with the requested codec', () {
    final args = HardwareEncoderDetector.probeArgs('hevc_amf');

    final size = HardwareEncoderDetector.probeFrameSize;
    expect(args, containsAllInOrder(['-i', 'color=c=black:s=${size}x$size:r=5:d=1']));
    expect(args, containsAllInOrder(['-c:v', 'hevc_amf']));
    expect(args, containsAllInOrder(['-frames:v', '1']));
    // Discard the output — the probe only cares whether the encoder opens.
    expect(args, containsAllInOrder(['-f', 'null', '-']));
  });
}
