//! Face Restoration: find the faces in each frame and restore them with a
//! neural network (RestoreFormer++, GFPGAN or CodeFormer), blended back into
//! the frame at the clip's own resolution. Runs on ONNX Runtime from the
//! ai-runtime add-on; the models are add-ons too (`face-restoration`, the
//! base with the detector, parser and RestoreFormer++; `face-gfpgan` and
//! `face-codeformer`, each non-commercial). See `worker/templates/face_restore.py`.

use serde::{Deserialize, Serialize};

/// The base add-on: RetinaFace, BiSeNet and RestoreFormer++.
pub const FACE_RESTORATION_ADDON: &str = "face-restoration";
pub const FACE_GFPGAN_ADDON: &str = "face-gfpgan";
pub const FACE_CODEFORMER_ADDON: &str = "face-codeformer";

/// Model files, as the add-on manifests (`app/assets/addons/`) name them.
pub const FACE_DETECTOR_FILE: &str = "face-restoration-retinaface-r50.onnx";
pub const FACE_PARSER_FILE: &str = "face-restoration-bisenet.onnx";

/// The temporal radius smoothing uses: landmarks smoothed over, and restored
/// faces blended with, one frame either side. Measured against 0 and 2 in
/// docs/reports/2026-11-face-restoration.
pub const FACE_SMOOTHING_RADIUS: u32 = 1;

/// Which network restores the faces.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum FaceRestoreModel {
    /// RestoreFormer++ (Apache-2.0): the default, in the base add-on.
    #[default]
    RestoreFormer,
    /// GFPGAN v1.4 (non-commercial): its own add-on.
    Gfpgan,
    /// CodeFormer (S-Lab License, non-commercial): its own add-on, with a
    /// fidelity control.
    CodeFormer,
}

impl FaceRestoreModel {
    /// The add-on holding this model's file.
    pub fn addon(&self) -> &'static str {
        match self {
            FaceRestoreModel::RestoreFormer => FACE_RESTORATION_ADDON,
            FaceRestoreModel::Gfpgan => FACE_GFPGAN_ADDON,
            FaceRestoreModel::CodeFormer => FACE_CODEFORMER_ADDON,
        }
    }

    /// The model's file in that add-on.
    pub fn file(&self) -> &'static str {
        match self {
            FaceRestoreModel::RestoreFormer => "face-restoration-restoreformerpp.onnx",
            FaceRestoreModel::Gfpgan => "face-gfpgan-v1.4.onnx",
            FaceRestoreModel::CodeFormer => "face-codeformer-v0.1.0.onnx",
        }
    }

    /// The name `face_restore.restore_faces(model=...)` takes.
    pub fn script_name(&self) -> &'static str {
        match self {
            FaceRestoreModel::RestoreFormer => "restoreformer",
            FaceRestoreModel::Gfpgan => "gfpgan",
            FaceRestoreModel::CodeFormer => "codeformer",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FaceRestoreParameters {
    #[serde(default)]
    pub enabled: bool,

    #[serde(default)]
    pub model: FaceRestoreModel,

    /// How much of the restored face replaces the original (0-1).
    #[serde(default = "default_strength")]
    pub strength: f64,

    /// CodeFormer's fidelity weight `w`: 0 trusts its learned faces, 1 stays
    /// closest to the picture. Ignored by the other models.
    #[serde(default = "default_fidelity")]
    pub code_former_fidelity: f64,

    /// The detector score (0-1) a face needs.
    #[serde(default = "default_threshold")]
    pub detection_threshold: f64,

    /// Faces smaller than this (pixels, the larger side of the detected box,
    /// at the pass's resolution) are left alone: there is too little in them
    /// to restore, and a restorer invents a face rather than recovering one.
    #[serde(default = "default_min_face")]
    pub min_face_size: i32,

    /// At most this many faces (the largest) are restored per frame.
    #[serde(default = "default_max_faces")]
    pub max_faces: i32,

    /// Average each face's landmarks with its neighbours' (one frame either
    /// side) and bridge one-frame detection gaps, so the restored face does
    /// not jitter or blink.
    #[serde(default = "default_true")]
    pub temporal_smoothing: bool,
}

fn default_strength() -> f64 { 0.8 }
fn default_fidelity() -> f64 { 0.7 }
fn default_threshold() -> f64 { 0.8 }
fn default_min_face() -> i32 { 32 }
fn default_max_faces() -> i32 { 8 }
fn default_true() -> bool { true }

impl Default for FaceRestoreParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            model: FaceRestoreModel::default(),
            strength: default_strength(),
            code_former_fidelity: default_fidelity(),
            detection_threshold: default_threshold(),
            min_face_size: default_min_face(),
            max_faces: default_max_faces(),
            temporal_smoothing: true,
        }
    }
}

impl FaceRestoreParameters {
    /// The add-ons a job with this pass needs: the base (detector and parser)
    /// always, and the chosen model's own add-on.
    pub fn required_addons(&self) -> Vec<&'static str> {
        let mut ids = vec![FACE_RESTORATION_ADDON];
        if self.model.addon() != FACE_RESTORATION_ADDON {
            ids.push(self.model.addon());
        }
        ids
    }

    /// The smoothing radius `restore_faces(temporal_radius=...)` takes: each
    /// face's landmarks are smoothed, and each restored face blended, over
    /// this many frames either side. 0 restores every frame on its own.
    pub fn temporal_radius(&self) -> u32 {
        if self.temporal_smoothing { FACE_SMOOTHING_RADIUS } else { 0 }
    }

    /// Frames read either side of the one being restored (the preview's
    /// temporal context): the blend reads `temporal_radius` neighbours, and
    /// their landmarks are smoothed over `temporal_radius` more.
    pub fn frames_read_either_side(&self) -> u32 {
        self.temporal_radius() * 2
    }

    pub fn clamped_strength(&self) -> f64 { self.strength.clamp(0.0, 1.0) }
    pub fn clamped_fidelity(&self) -> f64 { self.code_former_fidelity.clamp(0.0, 1.0) }
    pub fn clamped_threshold(&self) -> f64 { self.detection_threshold.clamp(0.3, 0.99) }
    pub fn clamped_min_face(&self) -> i32 { self.min_face_size.clamp(8, 1024) }
    pub fn clamped_max_faces(&self) -> i32 { self.max_faces.clamp(1, 64) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_and_wire_names() {
        let p: FaceRestoreParameters = serde_json::from_str("{}").unwrap();
        assert_eq!(p, FaceRestoreParameters::default());
        assert!(!p.enabled);
        assert_eq!(p.model, FaceRestoreModel::RestoreFormer);
        let json = serde_json::to_value(FaceRestoreParameters { model: FaceRestoreModel::CodeFormer, ..Default::default() }).unwrap();
        assert_eq!(json["model"], "codeFormer");
        assert_eq!(json["codeFormerFidelity"], 0.7);
        assert_eq!(json["temporalSmoothing"], true);
        for (m, name) in [
            (FaceRestoreModel::RestoreFormer, "\"restoreFormer\""),
            (FaceRestoreModel::Gfpgan, "\"gfpgan\""),
            (FaceRestoreModel::CodeFormer, "\"codeFormer\""),
        ] {
            assert_eq!(serde_json::to_string(&m).unwrap(), name);
        }
    }

    /// Every model needs the base add-on (detector and parser); the
    /// non-commercial ones need their own as well.
    #[test]
    fn required_addons_per_model() {
        let with = |model| FaceRestoreParameters { model, ..Default::default() }.required_addons();
        assert_eq!(with(FaceRestoreModel::RestoreFormer), vec!["face-restoration"]);
        assert_eq!(with(FaceRestoreModel::Gfpgan), vec!["face-restoration", "face-gfpgan"]);
        assert_eq!(with(FaceRestoreModel::CodeFormer), vec!["face-restoration", "face-codeformer"]);
    }

    /// The files named here are the ones the manifests install.
    #[test]
    fn model_files_are_in_their_manifests() {
        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        let read = |id: &str| std::fs::read_to_string(repo.join("app/assets/addons").join(format!("{id}.json"))).unwrap();
        for m in [FaceRestoreModel::RestoreFormer, FaceRestoreModel::Gfpgan, FaceRestoreModel::CodeFormer] {
            assert!(read(m.addon()).contains(&format!("\"name\": \"{}\"", m.file())), "{m:?}");
        }
        let base = read(FACE_RESTORATION_ADDON);
        assert!(base.contains(&format!("\"name\": \"{FACE_DETECTOR_FILE}\"")));
        assert!(base.contains(&format!("\"name\": \"{FACE_PARSER_FILE}\"")));
    }
}
