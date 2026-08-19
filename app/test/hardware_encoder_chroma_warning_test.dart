// The UI half of issue #74.
//
// A hardware encoder advertises the formats its driver was *built* against, not
// the ones the card actually has: a recent ffmpeg lists `yuv422p` on
// `h264_nvenc` for Blackwell, and every earlier NVIDIA card then failed the
// whole job at encoder open. The worker substitutes an encodable format instead
// of failing; this warning is what tells the user before the job runs.
//
// The substitution table below is the same one asserted in Rust by
// `test_nvenc_cannot_be_handed_422` and its neighbours in
// `worker/src/models/video_job.rs`. If the two disagree, the interface promises
// one thing and the encode does another — which is worse than either being
// wrong on its own, so both sides are pinned to the same cases.

import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/utils/pixel_format.dart';

void main() {
  group('pixelFormatChromaLayout', () {
    test('reads planar YUV subsampling', () {
      expect(pixelFormatChromaLayout('yuv420p'), ChromaLayout.c420);
      expect(pixelFormatChromaLayout('yuv420p10le'), ChromaLayout.c420);
      expect(pixelFormatChromaLayout('yuv422p'), ChromaLayout.c422);
      expect(pixelFormatChromaLayout('yuv422p10le'), ChromaLayout.c422);
      expect(pixelFormatChromaLayout('yuv444p12le'), ChromaLayout.c444);
      expect(pixelFormatChromaLayout('yuvj420p'), ChromaLayout.c420);
      expect(pixelFormatChromaLayout('yuva444p10le'), ChromaLayout.c444);
    });

    test('the coarse layouts warn alongside 4:2:2', () {
      // No hardware encoder takes any of these either, and calling them 4:2:2
      // in a warning is close enough to be useful and never wrong about the
      // conclusion.
      expect(pixelFormatChromaLayout('yuv411p'), ChromaLayout.c422);
      expect(pixelFormatChromaLayout('yuv410p'), ChromaLayout.c422);
      expect(pixelFormatChromaLayout('yuv440p'), ChromaLayout.c422);
    });

    test('reads semi-planar and packed formats', () {
      expect(pixelFormatChromaLayout('nv12'), ChromaLayout.c420);
      expect(pixelFormatChromaLayout('nv16'), ChromaLayout.c422);
      expect(pixelFormatChromaLayout('nv24'), ChromaLayout.c444);
      expect(pixelFormatChromaLayout('p010le'), ChromaLayout.c420);
      expect(pixelFormatChromaLayout('p210le'), ChromaLayout.c422);
      expect(pixelFormatChromaLayout('p410le'), ChromaLayout.c444);
      expect(pixelFormatChromaLayout('rgb24'), ChromaLayout.c444);
      expect(pixelFormatChromaLayout('gbrp'), ChromaLayout.c444);
    });

    test('unknown and gray formats fall back to the encodable layout', () {
      // The fallback must never invent a warning: 4:2:0 is what every encoder
      // takes, so an unrecognised name stays silent.
      expect(pixelFormatChromaLayout(null), ChromaLayout.c420);
      expect(pixelFormatChromaLayout(''), ChromaLayout.c420);
      expect(pixelFormatChromaLayout('something_new'), ChromaLayout.c420);
      expect(pixelFormatChromaLayout('gray10le'), ChromaLayout.c420);
    });
  });

  group('hardwareEncoderChromaWarning', () {
    String? warn(VideoCodec codec, String? pixFmt,
            [ChromaSubsampling cs = ChromaSubsampling.original]) =>
        hardwareEncoderChromaWarning(
          codec: codec,
          chromaSubsampling: cs,
          pixelFormat: pixFmt,
        );

    test('the reported case warns and names the substitute', () {
      // CineForm yuv422p10le -> h264_nvenc at "Match source", on an RTX 4070
      // Super. This produced zero frames and "No capable devices found".
      final msg = warn(VideoCodec.h264Nvenc, 'yuv422p10le');
      expect(msg, isNotNull);
      expect(msg, contains('yuv422p10le'));
      expect(msg, contains('4:2:0 8-bit'));
      expect(msg, contains('NVIDIA NVENC'));
    });

    test('substitutions match the worker, case for case', () {
      // MIRRORS the Rust table in worker/src/models/video_job.rs. The right
      // column is the format `forced_pix_fmt` returns, spelled the way this
      // warning says it.
      const cases = <(VideoCodec, String, String?)>[
        // 4:2:2 in — H.264 loses the depth too, H.265 keeps it.
        (VideoCodec.h264Nvenc, 'yuv422p10le', '4:2:0 8-bit'), // -> yuv420p
        (VideoCodec.h265Nvenc, 'yuv422p10le', '4:2:0 10-bit'), // -> p010le
        (VideoCodec.h265Nvenc, 'yuv422p', '4:2:0 8-bit'), // -> yuv420p
        (VideoCodec.h264Nvenc, 'yuv444p', '4:2:0 8-bit'), // -> yuv420p
        // 10-bit 4:2:0 in — only H.264 has a problem with it.
        (VideoCodec.h264Nvenc, 'yuv420p10le', '4:2:0 8-bit'), // -> yuv420p
        (VideoCodec.h265Nvenc, 'yuv420p10le', null), // -> None
        // 8-bit 4:2:0 in — nothing to do on either.
        (VideoCodec.h264Nvenc, 'yuv420p', null), // -> None
        (VideoCodec.h265Nvenc, 'yuv420p', null), // -> None
        // QSV takes the same decisions (nv12/p010le on the worker side).
        (VideoCodec.h264Qsv, 'yuv422p', '4:2:0 8-bit'), // -> nv12
        (VideoCodec.h265Qsv, 'yuv422p10le', '4:2:0 10-bit'), // -> p010le
        (VideoCodec.h264Qsv, 'yuv420p', null), // -> None
      ];

      for (final (codec, pixFmt, expected) in cases) {
        final msg = warn(codec, pixFmt);
        if (expected == null) {
          expect(msg, isNull,
              reason: '$pixFmt into ${codec.value} is encodable as-is');
        } else {
          expect(msg, isNotNull,
              reason: '$pixFmt into ${codec.value} must warn');
          expect(msg, contains(expected),
              reason: '$pixFmt into ${codec.value} converts to $expected');
        }
      }
    });

    test('encoders that negotiate correctly are never warned about', () {
      // VideoToolbox never advertises a mode it lacks. AMF has been pinned to
      // nv12 unconditionally since issue #51, so it always converts and there
      // is no surprise. Software and ProRes take 4:2:2 natively.
      for (final codec in [
        VideoCodec.h264,
        VideoCodec.h265,
        VideoCodec.h264Videotoolbox,
        VideoCodec.h265Videotoolbox,
        VideoCodec.h264Amf,
        VideoCodec.h265Amf,
        VideoCodec.prores422,
        VideoCodec.ffv1,
      ]) {
        expect(warn(codec, 'yuv422p10le'), isNull,
            reason: '${codec.value} should not warn');
      }
    });

    test('an explicit 4:2:2 choice warns whatever the source was', () {
      // The conversion is done by the pipeline, so a 4:2:0 source reaches the
      // encoder as 4:2:2 all the same — this is the second route into #74.
      final msg =
          warn(VideoCodec.h265Nvenc, 'yuv420p', ChromaSubsampling.yuv422p10);
      expect(msg, isNotNull);
      expect(msg, contains('4:2:2 10-bit'));
      expect(msg, contains('4:2:0 10-bit'));
    });

    test('the new 4:2:0 10-bit option is the way out, and is silent', () {
      // The whole point of adding it: a 10-bit source keeping its grading on a
      // GPU encoder, with nothing to warn about.
      expect(
          warn(VideoCodec.h265Nvenc, 'yuv422p10le',
              ChromaSubsampling.yuv420p10),
          isNull);
      // H.264 still cannot do 10-bit, so it still warns.
      expect(
          warn(VideoCodec.h264Nvenc, 'yuv422p10le',
              ChromaSubsampling.yuv420p10),
          contains('4:2:0 8-bit'));
    });

    test('4:2:0 8-bit is always safe', () {
      for (final codec in [
        VideoCodec.h264Nvenc,
        VideoCodec.h265Nvenc,
        VideoCodec.h264Qsv,
        VideoCodec.h265Qsv,
      ]) {
        expect(warn(codec, 'yuv422p10le', ChromaSubsampling.yuv420), isNull);
      }
    });

    test('silent before a file is loaded', () {
      // "Match source" cannot be judged without knowing the source.
      expect(warn(VideoCodec.h264Nvenc, null), isNull);
      // But an explicit choice can be, and still warns.
      expect(
          warn(VideoCodec.h264Nvenc, null, ChromaSubsampling.yuv422), isNotNull);
    });

    test('H.264 is told which way out actually helps', () {
      // Switching to H.265 keeps the depth; only software keeps the chroma.
      final msg = warn(VideoCodec.h264Nvenc, 'yuv422p10le');
      expect(msg, contains('H.265'));
      final chromaOnly = warn(VideoCodec.h265Nvenc, 'yuv422p');
      expect(chromaOnly, contains('software'));
      expect(chromaOnly, isNot(contains('H.265')));
    });
  });
}
