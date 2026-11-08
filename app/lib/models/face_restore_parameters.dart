import 'package:json_annotation/json_annotation.dart';

part 'face_restore_parameters.g.dart';

/// Which network restores the faces. Each lives in an add-on (see
/// [FaceRestoreModel.addonIds]); the wire names match the worker's
/// `FaceRestoreModel` (`worker/src/models/face_restore_parameters.rs`).
enum FaceRestoreModel {
  /// RestoreFormer++ (Apache-2.0), in the base `face-restoration` add-on.
  @JsonValue('restoreFormer')
  restoreFormer('RestoreFormer++', 'face-restoration'),

  /// GFPGAN v1.4: non-commercial (NVIDIA's licence on its StyleGAN2 code).
  @JsonValue('gfpgan')
  gfpgan('GFPGAN v1.4', 'face-gfpgan'),

  /// CodeFormer: non-commercial (S-Lab License 1.0), with a fidelity control.
  @JsonValue('codeFormer')
  codeFormer('CodeFormer', 'face-codeformer');

  const FaceRestoreModel(this.displayName, this.addonId);
  final String displayName;

  /// The add-on holding this model's file.
  final String addonId;

  /// The wire value (`restoreFormer`, `gfpgan`, `codeFormer`).
  String get value => switch (this) {
        FaceRestoreModel.restoreFormer => 'restoreFormer',
        FaceRestoreModel.gfpgan => 'gfpgan',
        FaceRestoreModel.codeFormer => 'codeFormer',
      };

  static FaceRestoreModel fromValue(String? value) => FaceRestoreModel.values
      .firstWhere((m) => m.value == value, orElse: () => FaceRestoreModel.restoreFormer);
}

/// The base add-on: the face detector, the face parser and RestoreFormer++.
const faceRestorationAddonId = 'face-restoration';

/// The add-ons a Face Restoration job with [model] needs: the base always
/// (detector and parser), plus the model's own. The worker refuses a job
/// without them (`FaceRestoreParameters::required_addons`); the manifests'
/// `requires` bring in the AI runtime.
List<String> faceRestoreAddonIds(FaceRestoreModel model) => [
      faceRestorationAddonId,
      if (model.addonId != faceRestorationAddonId) model.addonId,
    ];

/// What the add-on prompt says the download is for.
const faceRestoreAddonReason = 'Face restoration needs its AI models.';

/// The add-ons the Face Restoration panel's current [values] need, or null
/// for any other panel, or while the pass is off.
List<String>? faceRestoreAddonsSelectedBy(String filterId, bool enabled, Map<String, dynamic> values) =>
    filterId == 'face_restore' && enabled
        ? faceRestoreAddonIds(FaceRestoreModel.fromValue(values['model'] as String?))
        : null;

/// Face Restoration: find the faces in each frame and restore them with a
/// neural network, blended back at the clip's own resolution.
@JsonSerializable()
class FaceRestoreParameters {
  final bool enabled;
  final FaceRestoreModel model;

  /// How much of the restored face replaces the original (0-1).
  final double strength;

  /// CodeFormer's fidelity weight: 0 trusts its learned faces, 1 stays
  /// closest to the picture. Ignored by the other models.
  final double codeFormerFidelity;

  /// The detector score (0-1) a face needs.
  final double detectionThreshold;

  /// Faces smaller than this (pixels, the larger side of the face's box) are
  /// left alone.
  final int minFaceSize;

  /// At most this many faces (the largest) are restored per frame.
  final int maxFaces;

  /// Steady each face over the frames either side: smooth its landmarks,
  /// bridge one-frame detection gaps, and average the restored face with its
  /// neighbours' where the picture is still, so it doesn't jitter, blink or
  /// shimmer.
  final bool temporalSmoothing;

  const FaceRestoreParameters({
    this.enabled = false,
    this.model = FaceRestoreModel.restoreFormer,
    this.strength = 0.8,
    this.codeFormerFidelity = 0.7,
    this.detectionThreshold = 0.8,
    this.minFaceSize = 32,
    this.maxFaces = 8,
    this.temporalSmoothing = true,
  });

  FaceRestoreParameters copyWith({
    bool? enabled,
    FaceRestoreModel? model,
    double? strength,
    double? codeFormerFidelity,
    double? detectionThreshold,
    int? minFaceSize,
    int? maxFaces,
    bool? temporalSmoothing,
  }) {
    return FaceRestoreParameters(
      enabled: enabled ?? this.enabled,
      model: model ?? this.model,
      strength: strength ?? this.strength,
      codeFormerFidelity: codeFormerFidelity ?? this.codeFormerFidelity,
      detectionThreshold: detectionThreshold ?? this.detectionThreshold,
      minFaceSize: minFaceSize ?? this.minFaceSize,
      maxFaces: maxFaces ?? this.maxFaces,
      temporalSmoothing: temporalSmoothing ?? this.temporalSmoothing,
    );
  }

  /// The add-ons this configuration needs.
  List<String> get addonIds => faceRestoreAddonIds(model);

  String get summary => enabled ? model.displayName : 'Off';

  factory FaceRestoreParameters.fromJson(Map<String, dynamic> json) =>
      _$FaceRestoreParametersFromJson(json);
  Map<String, dynamic> toJson() => _$FaceRestoreParametersToJson(this);
}
