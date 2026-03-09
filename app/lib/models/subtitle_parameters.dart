import 'package:json_annotation/json_annotation.dart';

part 'subtitle_parameters.g.dart';

/// Whisper model sizes for subtitle generation.
@JsonEnum(valueField: 'value')
enum WhisperModel {
  @JsonValue('small')
  small('small', 'Small (466 MB)'),
  @JsonValue('medium')
  medium('medium', 'Medium (1.5 GB)'),
  @JsonValue('large-v3-turbo')
  high('large-v3-turbo', 'High (1.6 GB)');

  const WhisperModel(this.value, this.displayName);
  final String value;
  final String displayName;
}

/// Subtitle output mode.
@JsonEnum(valueField: 'value')
enum SubtitleOutput {
  @JsonValue('srt_file')
  srtFile('srt_file', 'SRT File'),
  @JsonValue('embed')
  embed('embed', 'Embed in Video'),
  @JsonValue('both')
  both('both', 'Both');

  const SubtitleOutput(this.value, this.displayName);
  final String value;
  final String displayName;
}

/// Parameters for the subtitle generation pass.
@JsonSerializable()
class SubtitleParameters {
  /// Whether this pass is enabled.
  final bool enabled;

  /// Whisper model to use.
  final WhisperModel model;

  /// Subtitle output mode.
  final SubtitleOutput output;

  /// Language hint for speech recognition (null = auto-detect).
  final String? language;

  const SubtitleParameters({
    this.enabled = false,
    this.model = WhisperModel.medium,
    this.output = SubtitleOutput.srtFile,
    this.language,
  });

  SubtitleParameters copyWith({
    bool? enabled,
    WhisperModel? model,
    SubtitleOutput? output,
    String? language,
  }) {
    return SubtitleParameters(
      enabled: enabled ?? this.enabled,
      model: model ?? this.model,
      output: output ?? this.output,
      language: language ?? this.language,
    );
  }

  /// Get a summary string for display.
  String get summary {
    if (!enabled) return 'Off';
    return 'Whisper (${model.displayName.split(' ').first})';
  }

  factory SubtitleParameters.fromJson(Map<String, dynamic> json) =>
      _$SubtitleParametersFromJson(json);
  Map<String, dynamic> toJson() => _$SubtitleParametersToJson(this);
}
