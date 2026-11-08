import 'package:json_annotation/json_annotation.dart';

part 'colorize_parameters.g.dart';

/// Which network predicts the colour. Each lives in its own add-on; the wire
/// names match the worker's `ColorizeModel`
/// (`worker/src/models/colorize_parameters.rs`) and the schema's method ids.
enum ColorizeModel {
  /// DDColor-T (Apache-2.0): vivid, predicted per frame.
  @JsonValue('ddcolor')
  ddcolor('DDColor', 'colorize-ddcolor'),

  /// DeOldify's Video model (MIT): muted, steady from frame to frame.
  @JsonValue('deoldify')
  deoldify('DeOldify Video', 'colorize-deoldify');

  const ColorizeModel(this.displayName, this.addonId);
  final String displayName;

  /// The add-on holding this model's file.
  final String addonId;

  /// The wire value, which is also the schema's method id.
  String get value => switch (this) {
        ColorizeModel.ddcolor => 'ddcolor',
        ColorizeModel.deoldify => 'deoldify',
      };

  static ColorizeModel fromValue(String? value) =>
      ColorizeModel.values.firstWhere((m) => m.value == value, orElse: () => ColorizeModel.ddcolor);
}

/// What the add-on prompt says the download is for.
const colorizeAddonReason = 'Colourisation needs its AI model.';

/// The add-on the Colourisation panel's current [values] need, or null for
/// any other panel, or while the pass is off. The worker refuses a job
/// without it (`ColorizeParameters::required_addons`); the manifests'
/// `requires` bring in the AI runtime.
String? colorizeAddonSelectedBy(String filterId, bool enabled, Map<String, dynamic> values) =>
    filterId == 'colorize' && enabled ? ColorizeModel.fromValue(values['method'] as String?).addonId : null;

/// Colourisation: colour black-and-white footage with a neural network,
/// keeping the source's luma exactly and replacing only its chroma.
@JsonSerializable()
class ColorizeParameters {
  final bool enabled;
  final ColorizeModel model;

  /// DDColor's input size in pixels (a square; a multiple of 32).
  final int ddcolorRenderSize;

  /// DeOldify's render factor: the model sees a square of 16x this.
  final int deoldifyRenderFactor;

  /// How much of the predicted colour is applied: 0 grey, 1 as predicted,
  /// above 1 more saturated.
  final double strength;

  /// Frames either side each frame's colour is averaged with, where the
  /// picture did not move, so it does not flicker. 0 colours every frame on
  /// its own.
  final int temporalRadius;

  const ColorizeParameters({
    this.enabled = false,
    this.model = ColorizeModel.ddcolor,
    this.ddcolorRenderSize = 512,
    this.deoldifyRenderFactor = 21,
    this.strength = 1.0,
    this.temporalRadius = 2,
  });

  ColorizeParameters copyWith({
    bool? enabled,
    ColorizeModel? model,
    int? ddcolorRenderSize,
    int? deoldifyRenderFactor,
    double? strength,
    int? temporalRadius,
  }) {
    return ColorizeParameters(
      enabled: enabled ?? this.enabled,
      model: model ?? this.model,
      ddcolorRenderSize: ddcolorRenderSize ?? this.ddcolorRenderSize,
      deoldifyRenderFactor: deoldifyRenderFactor ?? this.deoldifyRenderFactor,
      strength: strength ?? this.strength,
      temporalRadius: temporalRadius ?? this.temporalRadius,
    );
  }

  /// The add-on this configuration needs.
  String get addonId => model.addonId;

  String get summary => enabled ? model.displayName : 'Off';

  factory ColorizeParameters.fromJson(Map<String, dynamic> json) => _$ColorizeParametersFromJson(json);
  Map<String, dynamic> toJson() => _$ColorizeParametersToJson(this);
}
