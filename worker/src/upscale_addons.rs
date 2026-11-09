//! The Crop & Resize AI upscalers whose models are manifest add-ons
//! (`app/assets/addons/upscale-*.json`, see `addons.rs` and docs/ADDONS.md):
//! Real-ESRGAN's anime video model and Real-CUGAN, Real-ESRGAN's
//! general-purpose model, a live-action SPAN model, and Real-ESRGAN's large
//! x4plus/x2plus models. (AnimeJaNai's hand-written add-on is `animejanai.rs`.)
//!
//! They all run through the VSNCNN plugin and `{{#UPSCALE_AI}}` block, so
//! everything in `gpu_plugin.rs` (the Vulkan probe, never autoloading) applies
//! — none of them needs the ONNX Runtime add-on. This module only says which
//! add-on holds which file and what each network's own factor is.
//!
//! Every model is an add-on, never part of the deps bundle (docs/ADDONS.md).
//! The anime models are vs-mlrt's ONNX conversions, published only inside its
//! ~810 MB `models.v15.16.7z`, so they are hosted individually by this project,
//! byte for byte as vs-mlrt ships them. Real-ESRGAN publishes `.pth`
//! checkpoints only, so those are converted by
//! `Scripts/models/convert_realesrgan.py` and hosted the same way; the SPAN
//! model is upstream's own ONNX.

/// Real-ESRGAN's anime video model (`realesr-animevideov3`) and Real-CUGAN:
/// the anime upscalers, deps-bundled until deps 1.16.0.
pub const ANIME_ADDON: &str = "upscale-anime";

/// Real-ESRGAN General (`realesr-general-x4v3` and its denoise variant) and
/// 2xLiveActionV1_SPAN: both small, both for real-world footage.
pub const GENERAL_ADDON: &str = "upscale-general";

/// Real-ESRGAN x4plus / x2plus: the original 23-block RRDB networks — the
/// most detailed of the Real-ESRGAN family, and about 40x slower.
pub const ESRGAN_PLUS_ADDON: &str = "upscale-esrgan-plus";

/// vs-mlrt's `RealESRGANv2-animevideo-xsx2` (SRVGGNetCompact, 2x).
pub const ANIME_ESRGAN_X2: &str = "upscale-RealESRGANv2-animevideo-xsx2.onnx";
/// vs-mlrt's `RealESRGANv2-animevideo-xsx4` (4x).
pub const ANIME_ESRGAN_X4: &str = "upscale-RealESRGANv2-animevideo-xsx4.onnx";
/// Real-CUGAN 2x without denoising (vs-mlrt's `up2x-latest-no-denoise`).
pub const CUGAN_NO_DENOISE: &str = "upscale-cugan-up2x-latest-no-denoise.onnx";
/// Real-CUGAN 2x, conservative (the default strength).
pub const CUGAN_CONSERVATIVE: &str = "upscale-cugan-up2x-latest-conservative.onnx";
/// Real-CUGAN 2x, strongest denoising.
pub const CUGAN_DENOISE3X: &str = "upscale-cugan-up2x-latest-denoise3x.onnx";

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
    (ANIME_ADDON, ANIME_ESRGAN_X2, 2),
    (ANIME_ADDON, ANIME_ESRGAN_X4, 4),
    (ANIME_ADDON, CUGAN_NO_DENOISE, 2),
    (ANIME_ADDON, CUGAN_CONSERVATIVE, 2),
    (ANIME_ADDON, CUGAN_DENOISE3X, 2),
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
        for addon in [ANIME_ADDON, GENERAL_ADDON, ESRGAN_PLUS_ADDON] {
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
        assert_eq!(scale_of(ANIME_ESRGAN_X2), 2);
        assert_eq!(scale_of(ANIME_ESRGAN_X4), 4);
        assert_eq!(scale_of(CUGAN_DENOISE3X), 2);
        assert_eq!(scale_of(GENERAL_X4), 4);
        assert_eq!(scale_of(LIVE_ACTION_X2), 2);
        assert_eq!(scale_of(PLUS_X4), 4);
        assert_eq!(scale_of(PLUS_X2), 2);
    }
}
