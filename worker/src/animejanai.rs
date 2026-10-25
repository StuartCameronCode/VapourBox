//! AnimeJaNai: the-database's 2x Real-ESRGAN Compact models for anime, one of
//! the Crop & Resize AI upscalers.
//!
//! Unlike Real-ESRGAN and Real-CUGAN these are not in the deps bundle. Their
//! licence is CC BY-NC-SA 4.0 — non-commercial use only — which every other
//! file VapourBox ships is free of, so they stay out of the bundle (anyone may
//! redistribute that, commercially included) and are an optional download the
//! app makes when the user picks the method, after saying so: the models come
//! from upstream's own release, pinned by hash in
//! `app/assets/animejanai-addon.json`, into `addons/animejanai/`.
//!
//! They run through the same VSNCNN plugin and script block as the bundled
//! models, so everything in `gpu_plugin.rs` (the Vulkan probe, never
//! autoloading) applies; this module only says where the files are and which
//! one a job runs.

use std::path::{Path, PathBuf};

/// The models' directory under the add-ons directory.
pub const DIR_NAME: &str = "animejanai";

/// Every model the add-on installs. `app/assets/animejanai-addon.json` lists
/// the same files with their hashes (asserted below).
pub const MODELS: &[&str] = &[
    "2x_AnimeJaNai_HD_V3_Compact.onnx",
    "2x_AnimeJaNai_HD_V3_UltraCompact.onnx",
    "2x_AnimeJaNai_HD_V3_SuperUltraCompact.onnx",
    "2x_AnimeJaNai_HD_V3Sharp1_Compact.onnx",
    "2x_AnimeJaNai_HD_V3Sharp1_UltraCompact.onnx",
    "2x_AnimeJaNai_HD_V3Sharp1_SuperUltraCompact.onnx",
    "2x_AnimeJaNai_SD_V1beta34_Compact.onnx",
];

/// The SD model, which upstream trained separately: the HD models were
/// trained on 1080p anime and "don't always work well for SD sources". It
/// comes in one size, with no Sharp variant.
pub const SD_MODEL: &str = "2x_AnimeJaNai_SD_V1beta34_Compact.onnx";

/// The tallest picture the SD model is used for — PAL DVD. The script picks
/// per doubling, so a 4x upscale of a DVD runs the SD model and then an HD one,
/// the stacking upstream suggests for SD to 4K.
pub const SD_MAX_HEIGHT: u32 = 576;

/// What the worker says when a job picks AnimeJaNai and the models are not
/// installed. The app downloads them when the method is chosen, so this is
/// reached only if they were deleted since or the job came from elsewhere.
pub const MISSING_MESSAGE: &str = "AnimeJaNai's models are not installed. They \
    are a separate download, free for non-commercial use only: choose AnimeJaNai \
    in Crop & Resize to download them.";

/// The HD model for a size (`compact`, `ultraCompact`, `superUltraCompact`) and
/// the Sharp variant. An unknown size from a hand-edited preset is Compact.
pub fn hd_model(size: &str, sharp: bool) -> &'static str {
    match (size, sharp) {
        ("ultraCompact", false) => "2x_AnimeJaNai_HD_V3_UltraCompact.onnx",
        ("ultraCompact", true) => "2x_AnimeJaNai_HD_V3Sharp1_UltraCompact.onnx",
        ("superUltraCompact", false) => "2x_AnimeJaNai_HD_V3_SuperUltraCompact.onnx",
        ("superUltraCompact", true) => "2x_AnimeJaNai_HD_V3Sharp1_SuperUltraCompact.onnx",
        (_, false) => "2x_AnimeJaNai_HD_V3_Compact.onnx",
        (_, true) => "2x_AnimeJaNai_HD_V3Sharp1_Compact.onnx",
    }
}

/// The installed models' directory, or the message explaining that they are
/// missing. Every model must be there: the app installs them as a set, so a
/// partial directory is a damaged install rather than a choice.
pub fn runtime(addons_dir: &Path) -> Result<PathBuf, String> {
    let dir = addons_dir.join(DIR_NAME);
    if MODELS.iter().all(|m| dir.join(m).is_file()) {
        Ok(dir)
    } else {
        Err(MISSING_MESSAGE.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn models_match_the_app_manifest() {
        let manifest: serde_json::Value = serde_json::from_str(include_str!(
            "../../app/assets/animejanai-addon.json"
        ))
        .unwrap();
        let mut listed: Vec<&str> = manifest["models"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        listed.sort();
        let mut ours = MODELS.to_vec();
        ours.sort();
        assert_eq!(listed, ours);
        assert!(MODELS.contains(&SD_MODEL));
    }

    #[test]
    fn every_size_and_sharpness_names_an_installed_model() {
        for size in ["compact", "ultraCompact", "superUltraCompact", "huge"] {
            for sharp in [false, true] {
                let m = hd_model(size, sharp);
                assert!(MODELS.contains(&m), "{m}");
                assert_ne!(m, SD_MODEL);
                assert_eq!(m.contains("Sharp1"), sharp, "{m}");
            }
        }
        assert_eq!(hd_model("huge", false), hd_model("compact", false));
    }

    #[test]
    fn runtime_needs_every_model() {
        let tmp = std::env::temp_dir().join(format!("ajn-runtime-{}", std::process::id()));
        let dir = tmp.join(DIR_NAME);
        std::fs::create_dir_all(&dir).unwrap();
        for m in &MODELS[1..] {
            std::fs::write(dir.join(m), b"x").unwrap();
        }
        assert_eq!(runtime(&tmp), Err(MISSING_MESSAGE.to_string()));
        std::fs::write(dir.join(MODELS[0]), b"x").unwrap();
        assert_eq!(runtime(&tmp), Ok(dir));
        std::fs::remove_dir_all(&tmp).unwrap();
    }
}
