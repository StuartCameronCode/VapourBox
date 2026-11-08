//! The Crop & Resize AI upscalers whose models are manifest add-ons
//! (`app/assets/addons/upscale-*.json`, see `addons.rs` and docs/ADDONS.md):
//! Real-ESRGAN's general-purpose model, a live-action SPAN model, and
//! Real-ESRGAN's large x4plus/x2plus models.
//!
//! They run through the same VSNCNN plugin and `{{#UPSCALE_AI}}` block as the
//! bundled anime models, so everything in `gpu_plugin.rs` (the Vulkan probe,
//! never autoloading) applies — none of them needs the ONNX Runtime add-on.
//! This module only says which add-on holds which file, what each network's
//! own factor is, and how large a tile it can run in.
//!
//! Every model is an add-on, never part of the deps bundle (docs/ADDONS.md).
//! Real-ESRGAN publishes `.pth` checkpoints only, so those are converted by
//! `Scripts/models/convert_realesrgan.py` and hosted on this project's
//! `addon-models-v1` release; the SPAN model is upstream's own ONNX.

/// Real-ESRGAN General (`realesr-general-x4v3` and its denoise variant) and
/// 2xLiveActionV1_SPAN: both small, both for real-world footage.
pub const GENERAL_ADDON: &str = "upscale-general";

/// Real-ESRGAN x4plus / x2plus: the original 23-block RRDB networks — the
/// most detailed of the Real-ESRGAN family, and about 40x slower.
pub const ESRGAN_PLUS_ADDON: &str = "upscale-esrgan-plus";

/// `realesr-general-x4v3` (SRVGGNetCompact, 4x).
pub const GENERAL_X4: &str = "upscale-realesr-general-x4v3.onnx";
/// `realesr-general-wdn-x4v3`: the same network trained to remove noise too
/// ("wdn": with denoise).
pub const GENERAL_WDN_X4: &str = "upscale-realesr-general-wdn-x4v3.onnx";
/// jcj83429's 2xLiveActionV1_SPAN (SPAN, 2x).
pub const LIVE_ACTION_X2: &str = "2xLiveActionV1_SPAN_490000.onnx";
/// `RealESRGAN_x4plus` (RRDBNet, 4x).
pub const PLUS_X4: &str = "upscale-RealESRGAN_x4plus.onnx";
/// `RealESRGAN_x2plus` (RRDBNet, 2x).
pub const PLUS_X2: &str = "upscale-RealESRGAN_x2plus.onnx";

/// Every model file, with the add-on that installs it and the network's own
/// scale factor. The manifests list the same files (asserted below).
pub const MODELS: &[(&str, &str, u32)] = &[
    (GENERAL_ADDON, GENERAL_X4, 4),
    (GENERAL_ADDON, GENERAL_WDN_X4, 4),
    (GENERAL_ADDON, LIVE_ACTION_X2, 2),
    (ESRGAN_PLUS_ADDON, PLUS_X4, 4),
    (ESRGAN_PLUS_ADDON, PLUS_X2, 2),
];

/// A model file's own scale factor (2 for an unknown name, which no job can
/// reach: every name comes from [`MODELS`]).
pub fn scale_of(file: &str) -> u32 {
    MODELS.iter().find(|(_, f, _)| *f == file).map(|(_, _, s)| *s).unwrap_or(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn models_match_the_manifests() {
        for addon in [GENERAL_ADDON, ESRGAN_PLUS_ADDON] {
            let m = crate::addons::manifest(addon).unwrap_or_else(|| panic!("no manifest {addon}"));
            let mut listed: Vec<String> = m
                .expected_paths("macos-arm64")
                .into_iter()
                .filter(|p| p.ends_with(".onnx"))
                .collect();
            listed.sort();
            let mut ours: Vec<String> =
                MODELS.iter().filter(|(a, _, _)| *a == addon).map(|(_, f, _)| f.to_string()).collect();
            ours.sort();
            assert_eq!(listed, ours, "{addon}");
            // VSNCNN ships on exactly these platforms, so the models are
            // offered on exactly these.
            for p in crate::addons::PLATFORMS {
                assert_eq!(m.supports(p), crate::gpu_plugin::platform_ships_upscale(p), "{addon} {p}");
            }
            // They run on VSNCNN, not ONNX Runtime.
            assert!(!crate::addons::needs_ai_runtime(&[addon]), "{addon}");
        }
    }

    #[test]
    fn scales() {
        assert_eq!(scale_of(GENERAL_X4), 4);
        assert_eq!(scale_of(LIVE_ACTION_X2), 2);
        assert_eq!(scale_of(PLUS_X4), 4);
        assert_eq!(scale_of(PLUS_X2), 2);
    }
}
