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

  Future<void> _probe(String ffmpegPath, VideoCodec codec) async {
    var ok = false;
    try {
      final result = await Process.run(
        ffmpegPath,
        [
          '-hide_banner', '-loglevel', 'error',
          '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=5:d=1',
          '-frames:v', '1',
          '-c:v', codec.value,
          '-f', 'null', '-',
        ],
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      );
      ok = result.exitCode == 0;
    } catch (_) {
      ok = false;
    }
    _state[codec] =
        ok ? EncoderProbeState.available : EncoderProbeState.unavailable;
    if (kDebugMode) {
      print('HardwareEncoderDetector: ${codec.value} -> '
          '${ok ? "available" : "unavailable"}');
    }
    notifyListeners();
  }
}
