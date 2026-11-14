// v210: uncompressed 10-bit 4:2:2 output (task 7, forum thread 419911).
//
// The model's half: containers, data rate, and the Color Format pin. The pin
// warning is a second implementation of the worker's decision
// (`EncodingSettings::effective_chroma_subsampling`), so its table is pinned
// case for case to `v210_stores_422_10_whatever_is_selected` in
// worker/src/models/video_job.rs. Change one, change both.
//
// Run with: flutter test test/v210_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/utils/pixel_format.dart';

void main() {
  group('VideoCodec.v210', () {
    test('wire value matches the worker serde name', () {
      expect(VideoCodec.v210.value, 'v210');
      expect(VideoCodec.v210.displayName, 'Uncompressed 10-bit 4:2:2 (v210)');
    });

    test('is uncompressed, alone, and not lossless or ProRes', () {
      for (final codec in VideoCodec.values) {
        expect(codec.isUncompressed, codec == VideoCodec.v210,
            reason: codec.displayName);
      }
      expect(VideoCodec.v210.isLossless, isFalse);
      expect(VideoCodec.v210.isProRes, isFalse);
      expect(VideoCodec.v210.isHardwareEncoder, isFalse);
      expect(VideoCodec.v210.availablePresets, isNull);
      expect(VideoCodec.v210.encoderFamily, 'Uncompressed');
    });

    test('MOV by default; MOV, MKV and AVI, never MP4', () {
      expect(VideoCodec.v210.preferredContainer, ContainerFormat.mov);
      final supported = {
        for (final c in ContainerFormat.values)
          if (VideoCodec.v210.supportsContainer(c)) c
      };
      // MP4 has no tag for v210: ffmpeg refuses the mux outright.
      expect(supported,
          {ContainerFormat.mov, ContainerFormat.mkv, ContainerFormat.avi});
      expect(ContainerFormat.mov.supportedCodecs, contains(VideoCodec.v210));
      expect(ContainerFormat.mp4.supportedCodecs, isNot(contains(VideoCodec.v210)));
    });

    test('description states the data rate', () {
      expect(VideoCodec.v210.description, contains('221 Mbit/s'));
      expect(VideoCodec.v210.description, contains('1.1 Gbit/s'));
    });

    test('quality description names no number', () {
      final s = EncodingSettings(codec: VideoCodec.v210, quality: 37);
      expect(s.qualityDescription, 'Uncompressed');
    });
  });

  group('v210BitsPerSecond', () {
    test('matches the encoder (48-pixel line padding)', () {
      // What ffmpeg reports for a 720x576 25p v210 stream: 221184 kb/s.
      expect(v210BitsPerSecond(720, 576, 25), 221184000);
      expect(v210BitsPerSecond(1920, 1080, 25), 1105920000);
      // 1280 is not a multiple of 48: the line is padded to 1296 pixels.
      expect(v210BitsPerSecond(1280, 720, 25), (27 * 128) * 720 * 8 * 25);
    });
  });

  group('effectiveChromaSubsampling', () {
    test('v210 always converts to 10-bit 4:2:2; other codecs keep the choice',
        () {
      for (final cs in ChromaSubsampling.values) {
        expect(
          EncodingSettings(codec: VideoCodec.v210, chromaSubsampling: cs)
              .effectiveChromaSubsampling,
          ChromaSubsampling.yuv422p10,
          reason: cs.value,
        );
        expect(
          EncodingSettings(codec: VideoCodec.proresHQ, chromaSubsampling: cs)
              .effectiveChromaSubsampling,
          cs,
        );
      }
    });
  });

  group('v210ChromaPinWarning (pinned to the worker table)', () {
    // (selection, source) -> (chroma lost, selection ignored). The same rows
    // as `v210_stores_422_10_whatever_is_selected`.
    const sources = [
      'yuv420p',
      'yuv411p',
      'yuv422p',
      'yuv422p10le',
      'yuv444p10le',
      'yuv422p16le',
    ];
    (bool, bool) expected(ChromaSubsampling cs, String src) {
      switch (cs) {
        case ChromaSubsampling.original:
          return (src == 'yuv444p10le', false);
        case ChromaSubsampling.yuv422p10:
          return (false, false);
        case ChromaSubsampling.yuv444p10:
          return (true, true);
        case ChromaSubsampling.yuv420:
        case ChromaSubsampling.yuv420p10:
        case ChromaSubsampling.yuv422:
          return (false, true);
      }
    }

    test('speaks exactly where chroma is lost or the choice is ignored', () {
      for (final cs in ChromaSubsampling.values) {
        for (final src in sources) {
          final (lost, ignored) = expected(cs, src);
          final message = v210ChromaPinWarning(
            codec: VideoCodec.v210,
            chromaSubsampling: cs,
            pixelFormat: src,
          );
          final ctx = '${cs.value} from $src: $message';
          expect(message != null, lost || ignored, reason: ctx);
          if (message == null) continue;
          expect(message, contains('4:2:2'), reason: ctx);
          expect(message.contains('ignored'), ignored, reason: ctx);
          expect(message.contains('resampled down'), lost, reason: ctx);
        }
      }
    });

    test('silent before a file is loaded with Match source', () {
      expect(
        v210ChromaPinWarning(
          codec: VideoCodec.v210,
          chromaSubsampling: ChromaSubsampling.original,
        ),
        isNull,
      );
    });

    test('never fires for another codec', () {
      for (final codec in VideoCodec.values.where((c) => !c.isUncompressed)) {
        for (final cs in ChromaSubsampling.values) {
          expect(
            v210ChromaPinWarning(
              codec: codec,
              chromaSubsampling: cs,
              pixelFormat: 'yuv444p10le',
            ),
            isNull,
            reason: '${codec.displayName} ${cs.value}',
          );
        }
      }
    });

    test('the ProRes warning stays silent for v210', () {
      for (final cs in ChromaSubsampling.values) {
        expect(
          proresChromaPinWarning(
            codec: VideoCodec.v210,
            chromaSubsampling: cs,
            pixelFormat: 'yuv444p10le',
          ),
          isNull,
        );
      }
    });
  });
}
