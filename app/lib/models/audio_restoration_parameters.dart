import 'package:json_annotation/json_annotation.dart';

part 'audio_restoration_parameters.g.dart';

/// The add-on speech enhancement runs (`assets/addons/deepfilternet.json`).
const deepFilterNetAddonId = 'deepfilternet';

/// Whether an edit to [filterId]'s values switches speech enhancement on —
/// the moment the DeepFilterNet add-on is offered.
bool deepFilterChosen(
  String filterId,
  Map<String, dynamic> oldValues,
  Map<String, dynamic> newValues,
) =>
    filterId == 'audio_restoration' &&
    newValues['deepFilter'] == true &&
    oldValues['deepFilter'] != true;

/// What to do about the two channels of a stereo source.
enum ChannelFix {
  @JsonValue('off')
  off('Leave as is'),
  @JsonValue('auto')
  auto('Automatic (fix a silent channel)'),
  @JsonValue('leftOnly')
  leftOnly('Left channel only'),
  @JsonValue('rightOnly')
  rightOnly('Right channel only'),
  @JsonValue('mix')
  mix('Mix both channels');

  const ChannelFix(this.displayName);
  final String displayName;
}

/// Which mains frequency to notch out.
enum HumFrequency {
  @JsonValue('auto')
  auto('Automatic'),
  @JsonValue('50')
  hz50('50 Hz'),
  @JsonValue('60')
  hz60('60 Hz');

  const HumFrequency(this.displayName);
  final String displayName;
}

/// Audio restoration: the one pass that works on the soundtrack.
///
/// Rendered by the worker before the encode (`worker/src/audio_restoration.rs`);
/// nothing here reaches the VapourSynth script, and the preview is picture
/// only. Every step is off by default, so switching the pass on changes
/// nothing until a step is chosen.
@JsonSerializable()
class AudioRestorationParameters {
  final bool enabled;

  /// Which of the source's audio streams to restore (0 = the first).
  final int streamIndex;

  final ChannelFix channelFix;

  /// Positive delays the sound, negative advances it (milliseconds).
  final int offsetMs;

  final bool driftCorrection;

  /// The largest drift corrected, as a percentage of the length.
  final double driftMaxPercent;

  final bool declip;
  final bool declick;

  /// adeclick threshold: lower removes more.
  final double declickThreshold;

  final bool humRemoval;
  final HumFrequency humFrequency;

  final bool rumbleFilter;
  final int rumbleCutoffHz;

  final bool denoise;

  /// afftdn noise reduction in dB.
  final double denoiseStrength;

  /// DeepFilterNet speech enhancement (an add-on).
  final bool deepFilter;

  /// DeepFilterNet's attenuation limit in dB (100 = no limit).
  final int deepFilterAttenuation;

  final bool loudnessNormalize;

  /// Integrated loudness target, LUFS.
  final double loudnessTarget;

  final bool limiter;

  /// Limiter ceiling, dBFS.
  final double limiterCeilingDb;

  const AudioRestorationParameters({
    this.enabled = false,
    this.streamIndex = 0,
    this.channelFix = ChannelFix.off,
    this.offsetMs = 0,
    this.driftCorrection = false,
    this.driftMaxPercent = 0.5,
    this.declip = false,
    this.declick = false,
    this.declickThreshold = 2.0,
    this.humRemoval = false,
    this.humFrequency = HumFrequency.auto,
    this.rumbleFilter = false,
    this.rumbleCutoffHz = 40,
    this.denoise = false,
    this.denoiseStrength = 12.0,
    this.deepFilter = false,
    this.deepFilterAttenuation = 100,
    this.loudnessNormalize = false,
    this.loudnessTarget = -16.0,
    this.limiter = false,
    this.limiterCeilingDb = -1.0,
  });

  AudioRestorationParameters copyWith({
    bool? enabled,
    int? streamIndex,
    ChannelFix? channelFix,
    int? offsetMs,
    bool? driftCorrection,
    double? driftMaxPercent,
    bool? declip,
    bool? declick,
    double? declickThreshold,
    bool? humRemoval,
    HumFrequency? humFrequency,
    bool? rumbleFilter,
    int? rumbleCutoffHz,
    bool? denoise,
    double? denoiseStrength,
    bool? deepFilter,
    int? deepFilterAttenuation,
    bool? loudnessNormalize,
    double? loudnessTarget,
    bool? limiter,
    double? limiterCeilingDb,
  }) =>
      AudioRestorationParameters(
        enabled: enabled ?? this.enabled,
        streamIndex: streamIndex ?? this.streamIndex,
        channelFix: channelFix ?? this.channelFix,
        offsetMs: offsetMs ?? this.offsetMs,
        driftCorrection: driftCorrection ?? this.driftCorrection,
        driftMaxPercent: driftMaxPercent ?? this.driftMaxPercent,
        declip: declip ?? this.declip,
        declick: declick ?? this.declick,
        declickThreshold: declickThreshold ?? this.declickThreshold,
        humRemoval: humRemoval ?? this.humRemoval,
        humFrequency: humFrequency ?? this.humFrequency,
        rumbleFilter: rumbleFilter ?? this.rumbleFilter,
        rumbleCutoffHz: rumbleCutoffHz ?? this.rumbleCutoffHz,
        denoise: denoise ?? this.denoise,
        denoiseStrength: denoiseStrength ?? this.denoiseStrength,
        deepFilter: deepFilter ?? this.deepFilter,
        deepFilterAttenuation:
            deepFilterAttenuation ?? this.deepFilterAttenuation,
        loudnessNormalize: loudnessNormalize ?? this.loudnessNormalize,
        loudnessTarget: loudnessTarget ?? this.loudnessTarget,
        limiter: limiter ?? this.limiter,
        limiterCeilingDb: limiterCeilingDb ?? this.limiterCeilingDb,
      );

  /// On, with at least one step chosen (twin of the worker's `has_effect`).
  bool get hasEffect =>
      enabled &&
      (channelFix != ChannelFix.off ||
          offsetMs != 0 ||
          driftCorrection ||
          declip ||
          declick ||
          humRemoval ||
          rumbleFilter ||
          denoise ||
          deepFilter ||
          loudnessNormalize ||
          limiter);

  /// The steps switched on, in the order they run, for the pass row.
  List<String> get activeSteps => [
        if (channelFix != ChannelFix.off) 'Channels',
        if (declip) 'Declip',
        if (declick) 'Declick',
        if (rumbleFilter) 'Rumble',
        if (humRemoval) 'Hum',
        if (denoise) 'Denoise',
        if (offsetMs != 0) 'Sync ${offsetMs > 0 ? '+' : ''}$offsetMs ms',
        if (driftCorrection) 'Drift',
        if (deepFilter) 'DeepFilterNet',
        if (loudnessNormalize) 'Loudness',
        if (limiter) 'Limiter',
      ];

  String get summary {
    if (!enabled) return 'Off';
    final steps = activeSteps;
    if (steps.isEmpty) return 'Nothing selected';
    if (steps.length <= 3) return steps.join(', ');
    return '${steps.take(2).join(', ')} +${steps.length - 2}';
  }

  factory AudioRestorationParameters.fromJson(Map<String, dynamic> json) =>
      _$AudioRestorationParametersFromJson(json);
  Map<String, dynamic> toJson() => _$AudioRestorationParametersToJson(this);
}
