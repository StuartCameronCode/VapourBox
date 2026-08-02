import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/video_job.dart';
import 'tool_locator.dart';

/// Per-codec availability state.
enum EncoderProbeState {
  /// A functional probe is still running for this encoder.
  probing,

  /// The encoder initialized successfully on this machine.
  available,

  /// The encoder is not compiled into this build, or the probe failed
  /// (e.g. no GPU/driver present).
  unavailable,
}

/// Detects which video encoders are actually usable on this machine.
///
/// Two stages:
///  1. `ffmpeg -encoders` — cheap; tells us which encoders are *compiled into*
///     the bundled ffmpeg. This says nothing about the GPU/driver at runtime.
///  2. A concurrent *functional probe* per compiled-in hardware encoder — a
///     throwaway one-frame encode. Exit 0 means the encoder really initialized
///     (driver + device present); non-zero means it can't run here. ffmpeg does
///     the driver detection; we just read pass/fail.
///
/// Probes run concurrently and update state as each finishes; the detector is a
/// [ChangeNotifier] so the UI can show a busy indicator while a codec is still
/// being queried and resolve it live.
class HardwareEncoderDetector extends ChangeNotifier {
  HardwareEncoderDetector._();

  static final HardwareEncoderDetector instance = HardwareEncoderDetector._();

  final Set<String> _compiledIn = {};
  final Map<VideoCodec, EncoderProbeState> _state = {};
  // Error output captured from a failed functional probe, kept so the UI can
  // surface *why* an encoder check failed (the encoder stays selectable).
  final Map<VideoCodec, String> _probeErrors = {};
  bool _initialized = false;

  /// Whether the encoder is compiled into the bundled ffmpeg. Always true for
  /// non-hardware codecs (software, ProRes, lossless).
  bool isCompiledIn(VideoCodec codec) =>
      !codec.isHardwareEncoder || _compiledIn.contains(codec.value);

  /// Current probe state for a codec. Non-hardware codecs are always available.
  /// Hardware codecs default to [EncoderProbeState.probing] until resolved.
  EncoderProbeState probeState(VideoCodec codec) {
    if (!codec.isHardwareEncoder) return EncoderProbeState.available;
    return _state[codec] ?? EncoderProbeState.probing;
  }

  bool isProbing(VideoCodec codec) =>
      probeState(codec) == EncoderProbeState.probing;

  /// Whether the codec is usable on this machine right now (non-hardware codecs,
  /// or hardware codecs whose functional probe succeeded).
  bool isAvailable(VideoCodec codec) =>
      probeState(codec) == EncoderProbeState.available;

  /// The error output from this codec's functional probe, if it failed. Null
  /// when the probe passed (or hasn't run). Shown via the per-codec info button.
  String? probeError(VideoCodec codec) => _probeErrors[codec];

  /// Probe the bundled ffmpeg for available encoders. Idempotent.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    final hwCodecs =
        VideoCodec.values.where((c) => c.isHardwareEncoder).toList();

    final ffmpegPath = ToolLocator.instance.ffmpegPath;
    if (ffmpegPath == null) {
      for (final c in hwCodecs) {
        _state[c] = EncoderProbeState.unavailable;
      }
      notifyListeners();
      return;
    }

    // Stage 1: which encoders are compiled into the binary.
    try {
      final result = await Process.run(
        ffmpegPath,
        ['-encoders', '-hide_banner'],
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      );
      if (result.exitCode == 0) {
        for (final line in (result.stdout as String).split('\n')) {
          final trimmed = line.trim();
          // Encoder lines start with a flags field like "V....D" then the name.
          if (trimmed.startsWith('V')) {
            final parts = trimmed.split(RegExp(r'\s+'));
            if (parts.length >= 2) _compiledIn.add(parts[1]);
          }
        }
      }
    } catch (_) {
      // ffmpeg missing/failed — _compiledIn stays empty, everything hw is out.
    }

    // Stage 2: a compiled-in hardware encoder still needs a working device.
    final toProbe = <VideoCodec>[];
    for (final codec in hwCodecs) {
      if (_compiledIn.contains(codec.value)) {
        _state[codec] = EncoderProbeState.probing;
        toProbe.add(codec);
      } else {
        _state[codec] = EncoderProbeState.unavailable;
      }
    }
    notifyListeners();

    // Run the functional probes concurrently; each resolves independently.
    for (final codec in toProbe) {
      unawaited(_probe(ffmpegPath, codec));
    }
  }

  /// Frame size for the functional probe.
  ///
  /// Hardware encoders have minimum dimensions and a tiny frame makes them
  /// report a *false* failure: AMD AMF rejects 64x64, which had VapourBox
  /// marking working AMF encoders as broken (issue #51). AMF's minimum is
  /// 192x128 on some ASICs, and NVENC/QSV have their own floors, so probe at a
  /// size comfortably above all of them. One frame, so the cost is unchanged.
  static const int probeFrameSize = 512;

  /// The ffmpeg arguments used to functionally probe [codecValue]. Exposed for
  /// tests so the frame-size guarantee above can't silently regress.
  static List<String> probeArgs(String codecValue) => <String>[
        '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi',
        '-i', 'color=c=black:s=${probeFrameSize}x$probeFrameSize:r=5:d=1',
        '-frames:v', '1',
        '-c:v', codecValue,
        '-f', 'null', '-',
      ];

  Future<void> _probe(String ffmpegPath, VideoCodec codec) async {
    final args = probeArgs(codec.value);
    var ok = false;
    String? errorLog;
    try {
      final result = await Process.run(
        ffmpegPath,
        args,
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      );
      ok = result.exitCode == 0;
      if (!ok) {
        final err = (result.stderr as String).trim();
        final out = (result.stdout as String).trim();
        final detail =
            err.isNotEmpty ? err : (out.isNotEmpty ? out : '(no output captured)');
        errorLog = 'Probe command:\n'
            '  ffmpeg ${args.join(' ')}\n\n'
            'Exit code: ${result.exitCode}\n\n'
            '$detail';
      }
    } catch (e) {
      ok = false;
      errorLog = 'Probe command:\n'
          '  ffmpeg ${args.join(' ')}\n\n'
          'Failed to run probe: $e';
    }
    _state[codec] =
        ok ? EncoderProbeState.available : EncoderProbeState.unavailable;
    if (errorLog != null) {
      _probeErrors[codec] = errorLog;
    } else {
      _probeErrors.remove(codec);
    }
    if (kDebugMode) {
      print('HardwareEncoderDetector: ${codec.value} -> '
          '${ok ? "available" : "unavailable"}');
    }
    notifyListeners();
  }
}
