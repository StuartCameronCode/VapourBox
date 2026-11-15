// AV1 output through SVT-AV1 (task #40).
//
// The model's half: containers, presets, quality scale, the codec switch, the
// availability check and the colour format limit. The limit and its warning
// are a second implementation of the worker's decision
// (`VideoJob::output_chroma_subsampling`), so the table below is pinned case
// for case to `av1_stores_420_up_to_10_bits` in
// worker/src/models/video_job.rs. Change one, change both.
//
// Run with: flutter test test/av1_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/hardware_encoder_detector.dart';
import 'package:vapourbox/utils/pixel_format.dart';

String _workerSource(String relative) {
  // Tests run from app/; the worker is a sibling.
  final file = File('../worker/src/$relative');
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

void main() {
  group('VideoCodec.av1', () {
    test('wire value and name match the worker', () {
      expect(VideoCodec.av1.value, 'libsvtav1');
      expect(VideoCodec.av1.displayName, 'AV1 (SVT-AV1)');
      final rust = _workerSource('models/video_job.rs');
      expect(rust, contains('#[serde(rename = "libsvtav1")]\n    Av1,'));
      expect(rust, contains('VideoCodec::Av1 => "AV1 (SVT-AV1)"'));
    });

    test('is software, its own family, and the only AV1 codec', () {
      for (final codec in VideoCodec.values) {
        expect(codec.isAv1, codec == VideoCodec.av1, reason: codec.displayName);
        expect(codec.limitsTo420Up10, codec == VideoCodec.av1,
            reason: codec.displayName);
      }
      expect(VideoCodec.av1.isHardwareEncoder, isFalse);
      expect(VideoCodec.av1.isLossless, isFalse);
      expect(VideoCodec.av1.hasQualityControl, isTrue);
      expect(VideoCodec.av1.encoderFamily, 'SVT-AV1');
      expect(VideoCodec.av1.encoderFamily, isNot(VideoCodec.h264.encoderFamily));
    });

    test('MP4 by default; MP4 and MKV only', () {
      expect(VideoCodec.av1.preferredContainer, ContainerFormat.mp4);
      final supported = {
        for (final c in ContainerFormat.values)
          if (VideoCodec.av1.supportsContainer(c)) c
      };
      // FFmpeg refuses AV1 in MOV; AVI has no standard AV1 tag.
      expect(supported, {ContainerFormat.mp4, ContainerFormat.mkv});
      final rust = _workerSource('models/video_job.rs');
      expect(
          rust,
          contains(
              'matches!(container, ContainerFormat::Mp4 | ContainerFormat::Mkv)'));
    });

    test('presets and default agree with the worker', () {
      expect(VideoCodec.av1.availablePresets,
          ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10']);
      expect(VideoCodec.av1.defaultPreset, '6');
      final rust = _workerSource('models/video_job.rs');
      final list = RegExp(r'EncoderFamily::SvtAv1 => &\[([^\]]*)\]')
          .firstMatch(rust)!
          .group(1)!;
      final rustPresets =
          RegExp(r'"([^"]+)"').allMatches(list).map((m) => m.group(1)).toList();
      expect(rustPresets, VideoCodec.av1.availablePresets);
      expect(rust, contains('pub const SVT_AV1_DEFAULT_PRESET: &str = "6";'));
      expect(VideoCodec.av1.presetLabel('6'), '6 (balanced)');
      expect(VideoCodec.h264.presetLabel('medium'), 'medium');
    });

    test('quality scale is CRF 0-63, default 28', () {
      expect(VideoCodec.av1.maxQuality, 63);
      expect(VideoCodec.av1.defaultQuality, 28);
      expect(VideoCodec.h264.maxQuality, 51);
      expect(_workerSource('models/video_job.rs'), contains('(0, 63)'));
      final s = EncodingSettings(codec: VideoCodec.av1, quality: 28);
      expect(s.qualityDescription, 'Medium (CRF 28)');
      expect(s.copyWith(quality: 20).qualityDescription, 'Very High (CRF 20)');
      expect(s.copyWith(quality: 50).qualityDescription, 'Very Low (CRF 50)');
    });
  });

  group('EncodingSettings.withCodec', () {
    test('switching to AV1 resets preset and quality', () {
      final x264 = EncodingSettings(
          codec: VideoCodec.h264, encoderPreset: 'slow', quality: 18);
      final av1 = x264.withCodec(VideoCodec.av1);
      expect(av1.codec, VideoCodec.av1);
      expect(av1.encoderPreset, '6');
      expect(av1.quality, 28);
      // And back.
      final back = av1.copyWith(quality: 35).withCodec(VideoCodec.h265);
      expect(back.encoderPreset, 'medium');
      expect(back.quality, 18);
    });

    test('a switch within a family keeps preset and quality', () {
      final s = EncodingSettings(
          codec: VideoCodec.h264, encoderPreset: 'slow', quality: 22);
      final h265 = s.withCodec(VideoCodec.h265);
      expect(h265.encoderPreset, 'slow');
      expect(h265.quality, 22);
      // A hardware family resets the preset but keeps the 0-51 quality.
      final nvenc = s.withCodec(VideoCodec.h265Nvenc);
      expect(nvenc.encoderPreset, 'p4');
      expect(nvenc.quality, 22);
    });

    test('a container change can carry the codec switch', () {
      final s = EncodingSettings(codec: VideoCodec.av1, quality: 30)
          .withCodec(VideoCodec.h264, container: ContainerFormat.mov);
      expect(s.container, ContainerFormat.mov);
      expect(s.quality, 18);
    });
  });

  group('AV1 colour format (pinned to av1_stores_420_up_to_10_bits)', () {
    const c = ChromaSubsampling.values;
    ChromaSubsampling cs(String v) => c.firstWhere((x) => x.value == v);
    // (selection, source format, stored) — MIRRORS the Rust table.
    final rows = <(ChromaSubsampling, String, ChromaSubsampling)>[
      (ChromaSubsampling.original, 'yuv420p', ChromaSubsampling.original),
      (ChromaSubsampling.original, 'yuvj420p', ChromaSubsampling.original),
      (ChromaSubsampling.original, 'yuv420p10le', ChromaSubsampling.original),
      (ChromaSubsampling.original, 'yuv411p', ChromaSubsampling.yuv420),
      (ChromaSubsampling.original, 'yuv422p', ChromaSubsampling.yuv420),
      (ChromaSubsampling.original, 'yuv444p', ChromaSubsampling.yuv420),
      (ChromaSubsampling.original, 'yuv420p12le', ChromaSubsampling.yuv420p10),
      (ChromaSubsampling.original, 'yuv422p10le', ChromaSubsampling.yuv420p10),
      (ChromaSubsampling.original, 'yuv444p12le', ChromaSubsampling.yuv420p10),
      (ChromaSubsampling.original, 'yuv422p16le', ChromaSubsampling.yuv420p10),
      (ChromaSubsampling.yuv420, 'yuv422p10le', ChromaSubsampling.yuv420),
      (ChromaSubsampling.yuv420p10, 'yuv420p', ChromaSubsampling.yuv420p10),
      (ChromaSubsampling.yuv422, 'yuv420p', ChromaSubsampling.yuv420),
      (ChromaSubsampling.yuv422p10, 'yuv420p', ChromaSubsampling.yuv420p10),
      (ChromaSubsampling.yuv444p10, 'yuv444p12le', ChromaSubsampling.yuv420p10),
    ];

    test('the table matches the Rust test row for row', () {
      final rust = _workerSource('models/video_job.rs');
      final start = rust.indexOf('fn av1_stores_420_up_to_10_bits');
      final body = rust.substring(start, rust.indexOf('];', start));
      final rustRows = RegExp(r'\(C::(\w+), "(\w+)", C::(\w+)\)')
          .allMatches(body)
          .map((m) => '${m[1]!.toLowerCase()} ${m[2]} ${m[3]!.toLowerCase()}')
          .toList();
      final dartRows = rows
          .map((r) => '${r.$1.value} ${r.$2} ${r.$3.value}')
          .toList();
      expect(dartRows, rustRows);
      expect(cs('yuv420p10'), ChromaSubsampling.yuv420p10);
    });

    test('outputChromaSubsamplingFor follows the table', () {
      for (final (selection, src, stored) in rows) {
        final s = EncodingSettings(
            codec: VideoCodec.av1, chromaSubsampling: selection);
        expect(s.outputChromaSubsamplingFor(src), stored,
            reason: '$selection from $src');
      }
    });

    test('other codecs keep the selection', () {
      for (final codec in VideoCodec.values.where((c) => !c.isAv1)) {
        for (final selection in ChromaSubsampling.values) {
          final s = EncodingSettings(codec: codec, chromaSubsampling: selection);
          expect(s.outputChromaSubsamplingFor('yuv422p10le'),
              s.effectiveChromaSubsampling);
        }
      }
    });

    test('the warning appears exactly when the format changes', () {
      for (final (selection, src, stored) in rows) {
        final msg = av1ChromaWarning(
            codec: VideoCodec.av1, chromaSubsampling: selection, pixelFormat: src);
        expect(msg != null, stored != selection, reason: '$selection from $src');
        if (msg != null) expect(msg, contains(stored.label));
      }
      expect(
          av1ChromaWarning(
              codec: VideoCodec.h265,
              chromaSubsampling: ChromaSubsampling.original,
              pixelFormat: 'yuv422p10le'),
          isNull);
      // Nothing to say before a file is loaded.
      expect(
          av1ChromaWarning(
              codec: VideoCodec.av1,
              chromaSubsampling: ChromaSubsampling.original,
              pixelFormat: null),
          isNull);
    });

    test('says what is lost', () {
      expect(
          av1ChromaWarning(
              codec: VideoCodec.av1,
              chromaSubsampling: ChromaSubsampling.original,
              pixelFormat: 'yuv422p10le'),
          contains('colour detail beyond 4:2:0 is lost'));
      expect(
          av1ChromaWarning(
              codec: VideoCodec.av1,
              chromaSubsampling: ChromaSubsampling.original,
              pixelFormat: 'yuv420p12le'),
          contains('12-bit precision is reduced'));
    });

    test('the bit-depth warning leaves AV1 to its own warning', () {
      expect(
          chromaConversionBitDepthWarning(
              targetBitDepth: 10,
              pixelFormat: 'yuv420p12le',
              codec: VideoCodec.av1),
          isNull);
    });
  });

  group('availability', () {
    test('AV1 is checked like the hardware encoders', () {
      expect(VideoCodec.av1.needsAvailabilityCheck, isTrue);
      expect(VideoCodec.h265.needsAvailabilityCheck, isFalse);
      for (final c in VideoCodec.values.where((c) => c.isHardwareEncoder)) {
        expect(c.needsAvailabilityCheck, isTrue, reason: c.displayName);
      }
    });

    test('unavailable when libsvtav1 is not in the listing', () {
      final detector = HardwareEncoderDetector.instance;
      // The macOS x64 (evermeet) FFmpeg: libaom only.
      detector.debugSetEncoderListing('''
 V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC (codec h264)
 V....D libx265              libx265 H.265 / HEVC (codec hevc)
 V....D libaom-av1           libaom AV1 (codec av1)
''');
      expect(detector.isCompiledIn(VideoCodec.av1), isFalse);
      expect(detector.isAvailable(VideoCodec.av1), isFalse);
      expect(detector.isAvailable(VideoCodec.h265), isTrue);

      detector.debugSetEncoderListing('''
 V....D libaom-av1           libaom AV1 (codec av1)
 V..... libsvtav1            SVT-AV1(Scalable Video Technology for AV1) encoder (codec av1)
''');
      expect(detector.isCompiledIn(VideoCodec.av1), isTrue);
      expect(detector.isAvailable(VideoCodec.av1), isTrue);
    });
  });
}
