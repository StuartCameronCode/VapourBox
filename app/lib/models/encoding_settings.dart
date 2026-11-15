import 'package:json_annotation/json_annotation.dart';

import '../utils/pixel_format.dart';
import 'video_job.dart';

part 'encoding_settings.g.dart';

/// Audio handling mode for output.
@JsonEnum(valueField: 'value')
enum AudioMode {
  /// Copy audio stream without re-encoding.
  passthrough('passthrough', 'Passthrough'),
  /// Re-encode audio with selected codec and quality.
  convert('convert', 'Convert'),
  /// No audio in output.
  none('none', 'None');

  const AudioMode(this.value, this.displayName);

  final String value;
  final String displayName;
}

/// Audio codecs for re-encoding.
@JsonEnum(valueField: 'value')
enum AudioCodec {
  aac('aac', 'AAC'),
  mp3('libmp3lame', 'MP3'),
  ac3('ac3', 'AC-3 (Dolby Digital)'),
  flac('flac', 'FLAC (Lossless)'),
  opus('libopus', 'Opus'),
  pcm('pcm_s16le', 'PCM (Uncompressed)');

  const AudioCodec(this.value, this.displayName);

  final String value;
  final String displayName;

  /// Whether this is a lossless codec (no quality setting needed).
  bool get isLossless => this == AudioCodec.flac || this == AudioCodec.pcm;

  /// The codec's short name, as messages print it. Twin of the worker's
  /// `AudioCodec::short_name`.
  String get shortName {
    switch (this) {
      case AudioCodec.aac:
        return 'AAC';
      case AudioCodec.mp3:
        return 'MP3';
      case AudioCodec.ac3:
        return 'AC-3';
      case AudioCodec.flac:
        return 'FLAC';
      case AudioCodec.opus:
        return 'Opus';
      case AudioCodec.pcm:
        return 'PCM';
    }
  }

  /// Whether the bundled FFmpeg can mux this codec into [container] (task
  /// #39). MOV takes neither FLAC nor Opus and AVI has no Opus tag; no option
  /// changes that. Twin of the worker's `AudioCodec::supports_container`,
  /// both pinned by `Tests/TestResources/audio_codec_containers.json`, and
  /// checked against the real muxers by `audio_compatibility_test.dart`.
  bool supportsContainer(ContainerFormat container) {
    switch (container) {
      case ContainerFormat.mp4:
      case ContainerFormat.mkv:
        return true;
      case ContainerFormat.mov:
        return this != AudioCodec.flac && this != AudioCodec.opus;
      case ContainerFormat.avi:
        return this != AudioCodec.opus;
    }
  }

  /// The codec to switch to when [container] can't hold this one: itself if
  /// it fits, else PCM for a lossless codec and AAC for a lossy one, so a
  /// lossless choice never silently turns lossy. Every container holds both.
  AudioCodec fallbackFor(ContainerFormat container) {
    if (supportsContainer(container)) return this;
    return isLossless ? AudioCodec.pcm : AudioCodec.aac;
  }

  /// Why this codec can't go into [container], or null when it can. The same
  /// words as the worker's refusal (`AudioCodec::container_problem`).
  String? containerProblem(ContainerFormat container) {
    if (supportsContainer(container)) return null;
    final codecs = container.supportedAudioCodecs.map((c) => c.shortName);
    final containers = ContainerFormat.values
        .where((k) => k != container && supportsContainer(k))
        .map((k) => k.shortName);
    return '$shortName audio can\'t be stored in ${container.shortName} files. '
        'Choose ${_joinOr(codecs)} in Settings \u2192 Audio, '
        'or save as ${_joinOr(containers)}.';
  }
}

/// "A", "A or B", "A, B or C".
String _joinOr(Iterable<String> items) {
  final list = items.toList();
  if (list.length <= 1) return list.join();
  return '${list.sublist(0, list.length - 1).join(', ')} or ${list.last}';
}

/// Audio quality presets (bitrate in kbps).
@JsonEnum(valueField: 'value')
enum AudioQuality {
  low(96, 'Low (96 kbps)'),
  medium(128, 'Medium (128 kbps)'),
  high(192, 'High (192 kbps)'),
  veryHigh(256, 'Very High (256 kbps)');

  const AudioQuality(this.value, this.displayName);

  final int value;
  final String displayName;

  /// Bitrate in kbps.
  int get bitrate => value;
}

/// Output chroma subsampling format.
///
/// Mirrors `ChromaSubsampling` in `worker/src/models/video_job.rs` — the [value]
/// strings must match that enum's serde names.
@JsonEnum(valueField: 'value')
/// The quantisation matrices `prores_ks` accepts by name.
///
/// Mirrors `ProResQuantMat` in `worker/src/models/video_job.rs` — the `value`
/// strings here are the wire format. An enum rather than a free string because
/// ffmpeg rejects an unknown value outright and kills the encode, so a typo in
/// a saved preset would fail the whole job on an option nobody can see.
@JsonEnum(valueField: 'value')
enum ProResQuantMat {
  /// Match the profile — what the encoder does with no option at all.
  auto('auto', 'Auto (match profile)'),
  proxy('proxy', 'Proxy'),
  lt('lt', 'LT'),
  standard('standard', 'Standard'),
  hq('hq', 'HQ');

  const ProResQuantMat(this.value, this.label);

  final String value;
  final String label;
}

enum ChromaSubsampling {
  /// Keep original format (no conversion), bit depth included.
  original('original', 'Match source', null, null),
  /// Convert to 8-bit YUV420 for maximum compatibility (smaller files).
  yuv420('yuv420', '4:2:0 8-bit', 'most compatible', 8),
  /// Convert to 10-bit YUV420. The only 10-bit layout NVENC, QSV and AMF can
  /// encode, so it is the way to keep a 10-bit source's grading on a GPU
  /// encoder — 4:2:2 fails outright on most of them (issue #74).
  yuv420p10('yuv420p10', '4:2:0 10-bit', 'best 10-bit for GPU encoders', 10),
  /// Convert to 8-bit YUV422 for higher chroma quality.
  yuv422('yuv422', '4:2:2 8-bit', 'more colour detail', 8),
  /// Convert to 10-bit YUV422: keeps a 10-bit source's precision while
  /// normalizing chroma, and gives an 8-bit source headroom for gradients.
  yuv422p10('yuv422p10', '4:2:2 10-bit', 'keeps 10-bit precision', 10),
  /// Convert to 10-bit YUV444: full chroma resolution, no subsampling at all.
  /// What ProRes 4444 stores, and what the software x264/x265 encoders can
  /// take. No GPU encoder in this app can (see [hardwareEncoderChromaWarning]).
  yuv444p10('yuv444p10', '4:4:4 10-bit', 'full chroma, no GPU encoders', 10);

  const ChromaSubsampling(
      this.value, this.label, this.blurb, this.outputBitDepth);

  final String value;

  /// Short canonical name, e.g. "4:2:0 8-bit". The one piece of vocabulary the
  /// dropdown, the tooltip and the warnings all share, so they can't drift into
  /// describing the same option three different ways.
  final String label;

  /// Parenthetical hint shown after [label] in the dropdown, if any.
  final String? blurb;

  /// Bit depth the output is converted to, or null for [original], which does
  /// no conversion. Drives the "your source will be reduced" warning, so a new
  /// option gets the right warning without touching the UI.
  final int? outputBitDepth;

  String get displayName => blurb == null ? label : '$label ($blurb)';
}

/// Video encoding settings for FFmpeg output.
@JsonSerializable()
class EncodingSettings {
  final VideoCodec codec;
  final String encoderPreset;
  final int quality;

  /// Target video bitrate in kbps. Used by Intel-Mac VideoToolbox (which has no
  /// constant-quality mode), where the UI exposes a native bitrate control
  /// instead of the CRF slider. Null for all other encoders.
  final int? videoBitrateKbps;

  /// Audio handling mode.
  final AudioMode audioMode;

  /// Audio codec for re-encoding (when audioMode == convert).
  final AudioCodec audioCodec;

  /// Audio quality preset (when audioMode == convert and codec is lossy).
  final AudioQuality audioQuality;

  /// Output chroma subsampling format.
  final ChromaSubsampling chromaSubsampling;

  /// Write `apl0` as the ProRes vendor tag instead of ffmpeg's `Lavc`.
  /// A compatibility flag, not a quality one — some Avid and Apple tooling
  /// reads this field, and the decoded frames are identical either way.
  /// Ignored by every non-ProRes codec.
  final bool proresVendorApl0;

  /// ProRes `-bits_per_mb`: the ceiling the encoder may spend per macroblock.
  /// Null leaves it to the profile. Only affects Proxy and LT in practice.
  final int? proresBitsPerMb;

  /// ProRes `-quant_mat`. Null leaves the encoder on `auto`, which picks the
  /// matrix matching the profile.
  final ProResQuantMat? proresQuantMat;

  final String customFfmpegArgs;

  /// User-supplied VapourSynth, injected after every built-in pass. Same
  /// footing as customFfmpegArgs, and gated behind advanced mode.
  final String customVapoursynth;

  /// Override for VapourSynth's frame cache limit (`core.max_cache_size`), in
  /// MB. Null leaves VapourSynth on its own default, which it sizes from the
  /// machine's memory.
  final int? maxCacheSizeMb;
  final ContainerFormat container;

  /// Output directory. If null, uses the same directory as the input file.
  final String? outputDirectory;

  /// Filename pattern for output files. Supports placeholders:
  /// - {input_filename} - Original filename without extension
  /// - {date} - Current date (YYYY-MM-DD)
  /// - {time} - Current time (HH-MM-SS)
  final String filenamePattern;

  const EncodingSettings({
    this.codec = VideoCodec.h264,
    this.encoderPreset = 'medium',
    this.quality = 18,
    this.videoBitrateKbps,
    this.audioMode = AudioMode.passthrough,
    this.audioCodec = AudioCodec.aac,
    this.audioQuality = AudioQuality.high,
    this.chromaSubsampling = ChromaSubsampling.original,
    this.proresVendorApl0 = false,
    this.proresBitsPerMb,
    this.proresQuantMat,
    this.customFfmpegArgs = '',
    this.customVapoursynth = '',
    this.maxCacheSizeMb,
    this.container = ContainerFormat.mkv,
    this.outputDirectory,
    this.filenamePattern = '{input_filename}_processed',
  });

  factory EncodingSettings.fromJson(Map<String, dynamic> json) {
    // Backward compatibility: convert old audioCopy boolean to audioMode
    if (json.containsKey('audioCopy') && !json.containsKey('audioMode')) {
      final audioCopy = json['audioCopy'] as bool? ?? true;
      json['audioMode'] = audioCopy ? 'passthrough' : 'convert';
    }
    // Backward compatibility: convert old string audioCodec to enum
    if (json.containsKey('audioCodec') && json['audioCodec'] is String) {
      final oldCodec = json['audioCodec'] as String;
      // Map old codec strings to new enum values
      const codecMap = {
        'aac': 'aac',
        'libmp3lame': 'libmp3lame',
        'mp3': 'libmp3lame',
        'ac3': 'ac3',
        'flac': 'flac',
        'libopus': 'libopus',
        'opus': 'libopus',
        'pcm_s16le': 'pcm_s16le',
      };
      json['audioCodec'] = codecMap[oldCodec] ?? 'aac';
    }
    // Backward compatibility: convert old audioBitrate to audioQuality
    if (json.containsKey('audioBitrate') && !json.containsKey('audioQuality')) {
      final bitrate = json['audioBitrate'] as int? ?? 192;
      if (bitrate <= 96) {
        json['audioQuality'] = 96;
      } else if (bitrate <= 128) {
        json['audioQuality'] = 128;
      } else if (bitrate <= 192) {
        json['audioQuality'] = 192;
      } else {
        json['audioQuality'] = 256;
      }
    }
    return _$EncodingSettingsFromJson(json);
  }

  Map<String, dynamic> toJson() => _$EncodingSettingsToJson(this);

  /// The colour format the script actually converts to: [chromaSubsampling],
  /// except for a codec that stores one format and nothing else (v210, every
  /// ProRes profile: [VideoCodec.fixedOutputFormat]), which the worker
  /// converts to whatever is selected (field-aware, in the script). Mirrors
  /// `EncodingSettings::effective_chroma_subsampling`; see
  /// `proresChromaPinWarning` / `v210ChromaPinWarning` for what the user is
  /// told.
  ChromaSubsampling get effectiveChromaSubsampling =>
      codec.fixedOutputFormat ?? chromaSubsampling;

  /// These settings with [newContainer], and every codec the container can't
  /// hold switched: the video codec to the container's first (through
  /// [withCodec], so its preset and quality reset with it: AV1 into MOV
  /// becomes H.264 at CRF 18, task #40), the Convert audio codec to
  /// [AudioCodec.fallbackFor] (task #39). What the Settings container switch
  /// applies.
  EncodingSettings withContainer(ContainerFormat newContainer) => withCodec(
        codec.supportsContainer(newContainer)
            ? codec
            : newContainer.supportedCodecs.first,
        container: newContainer,
      ).copyWith(audioCodec: audioCodec.fallbackFor(newContainer));

  /// Why this job's audio can't be written, or null (task #39): only a
  /// Convert codec the container can't hold. Twin of the worker's
  /// `EncodingSettings::audio_container_problem`, which refuses such a job.
  String? get audioContainerProblem => audioMode == AudioMode.convert
      ? audioCodec.containerProblem(container)
      : null;

  /// The colour format the script converts to for a source whose pipe format
  /// is [pixelFormat] (null before a file is analysed). The same as
  /// [effectiveChromaSubsampling], except for a codec limited to 4:2:0 at 8
  /// or 10 bits ([VideoCodec.limitsTo420Up10], AV1): a format that already
  /// fits is kept, anything else becomes 4:2:0 at 8 bits (8-bit content) or
  /// 10 bits (deeper). Mirrors `VideoJob::output_chroma_subsampling`; without
  /// a source format under Original it returns Original.
  ChromaSubsampling outputChromaSubsamplingFor(String? pixelFormat) {
    final selected = effectiveChromaSubsampling;
    if (!codec.limitsTo420Up10) return selected;
    return limitTo420Up10(selected, pixelFormat);
  }

  /// These settings with [newCodec] selected. Switching encoder family resets
  /// the preset to the new family's default (vocabularies don't overlap), and
  /// switching between quality scales (AV1's CRF 0-63 vs x264's 0-51, whose
  /// numbers mean different things) resets the quality to the new codec's
  /// default — x264's 18 would otherwise be a near-lossless AV1 encode several
  /// times the intended size.
  EncodingSettings withCodec(VideoCodec newCodec, {ContainerFormat? container}) {
    final familyChanged = codec.encoderFamily != newCodec.encoderFamily;
    final scaleChanged = codec.isAv1 != newCodec.isAv1;
    return copyWith(
      codec: newCodec,
      container: container,
      encoderPreset: familyChanged ? newCodec.defaultPreset : null,
      quality: scaleChanged ? newCodec.defaultQuality : null,
    );
  }

  /// Backward compatibility: alias for audioMode == passthrough.
  @Deprecated('Use audioMode instead')
  bool get audioCopy => audioMode == AudioMode.passthrough;

  /// Backward compatibility: alias for audioMode == passthrough.
  @Deprecated('Use audioMode instead')
  bool get copyAudio => audioCopy;

  /// Human-readable quality description.
  String get qualityDescription {
    // Codecs whose quality the worker never reads must not be described in
    // terms of a number that does nothing. ProRes is set by its profile;
    // lossless has no quality at all.
    if (!codec.hasQualityControl) {
      if (codec.isProRes) return 'Fixed by the ${codec.displayName} profile';
      if (codec.isUncompressed) return 'Uncompressed';
      return 'Lossless';
    }
    if (codec == VideoCodec.h264Videotoolbox || codec == VideoCodec.h265Videotoolbox) {
      // VideoToolbox: CRF is remapped to q:v (inverted scale) in the worker.
      // Show quality in user-friendly terms based on the CRF value.
      if (quality <= 15) return 'Very High (Quality $quality)';
      if (quality <= 20) return 'High (Quality $quality)';
      if (quality <= 25) return 'Medium (Quality $quality)';
      if (quality <= 30) return 'Low (Quality $quality)';
      return 'Very Low (Quality $quality)';
    }
    if (codec.isAv1) {
      // SVT-AV1's CRF runs 0-63 and its numbers mean less than x264's.
      if (quality <= 20) return 'Very High (CRF $quality)';
      if (quality <= 26) return 'High (CRF $quality)';
      if (quality <= 32) return 'Medium (CRF $quality)';
      if (quality <= 40) return 'Low (CRF $quality)';
      return 'Very Low (CRF $quality)';
    }
    // NVENC uses CQ (constant quality) in VBR mode, not CRF
    final label = codec.isNvenc ? 'CQ' : 'CRF';
    if (quality <= 15) return 'Very High ($label $quality)';
    if (quality <= 20) return 'High ($label $quality)';
    if (quality <= 25) return 'Medium ($label $quality)';
    if (quality <= 30) return 'Low ($label $quality)';
    return 'Very Low ($label $quality)';
  }

  EncodingSettings copyWith({
    VideoCodec? codec,
    String? encoderPreset,
    int? quality,
    int? videoBitrateKbps,
    AudioMode? audioMode,
    AudioCodec? audioCodec,
    AudioQuality? audioQuality,
    ChromaSubsampling? chromaSubsampling,
    bool? proresVendorApl0,
    int? proresBitsPerMb,
    // Nullable settings need an explicit clear, or unticking the override in
    // the UI can never put them back to null and the value sticks forever,
    // silently applied to every later ProRes encode. `outputDirectory` is the
    // precedent; `videoBitrateKbps` is the counter-example that has to work
    // around its own absence in _buildCodecRadio.
    bool clearProresBitsPerMb = false,
    ProResQuantMat? proresQuantMat,
    bool clearProresQuantMat = false,
    String? customFfmpegArgs,
    String? customVapoursynth,
    int? maxCacheSizeMb,
    bool clearMaxCacheSizeMb = false,
    ContainerFormat? container,
    String? outputDirectory,
    bool clearOutputDirectory = false,
    String? filenamePattern,
    // Backward compatibility
    @Deprecated('Use audioMode instead') bool? copyAudio,
  }) {
    // Handle backward compatibility for copyAudio parameter
    var effectiveAudioMode = audioMode ?? this.audioMode;
    if (copyAudio != null && audioMode == null) {
      effectiveAudioMode = copyAudio ? AudioMode.passthrough : AudioMode.convert;
    }

    return EncodingSettings(
      codec: codec ?? this.codec,
      encoderPreset: encoderPreset ?? this.encoderPreset,
      quality: quality ?? this.quality,
      videoBitrateKbps: videoBitrateKbps ?? this.videoBitrateKbps,
      audioMode: effectiveAudioMode,
      audioCodec: audioCodec ?? this.audioCodec,
      audioQuality: audioQuality ?? this.audioQuality,
      chromaSubsampling: chromaSubsampling ?? this.chromaSubsampling,
      proresVendorApl0: proresVendorApl0 ?? this.proresVendorApl0,
      proresBitsPerMb: clearProresBitsPerMb
          ? null
          : (proresBitsPerMb ?? this.proresBitsPerMb),
      proresQuantMat:
          clearProresQuantMat ? null : (proresQuantMat ?? this.proresQuantMat),
      customFfmpegArgs: customFfmpegArgs ?? this.customFfmpegArgs,
      customVapoursynth: customVapoursynth ?? this.customVapoursynth,
      maxCacheSizeMb:
          clearMaxCacheSizeMb ? null : (maxCacheSizeMb ?? this.maxCacheSizeMb),
      container: container ?? this.container,
      outputDirectory: clearOutputDirectory ? null : (outputDirectory ?? this.outputDirectory),
      filenamePattern: filenamePattern ?? this.filenamePattern,
    );
  }

  /// Generate the output filename from a pattern and input filename.
  String generateOutputFilename(String inputFilename) {
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr = '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}';

    return filenamePattern
        .replaceAll('{input_filename}', inputFilename)
        .replaceAll('{date}', dateStr)
        .replaceAll('{time}', timeStr);
  }
}
