//! Noise reduction parameters for video processing.

use serde::{Deserialize, Serialize};

/// Noise reduction method options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum NoiseReductionMethod {
    #[default]
    SmDegrain,
    McTemporalDenoise,
    /// Didée's MCDegrainSharp: motion-compensated degrain that sharpens where
    /// the motion match is good and blurs where it is poor.
    McDegrainSharp,
    QtgmcBuiltin,
}

/// Noise reduction preset levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum NoiseReductionPreset {
    #[default]
    Off,
    Light,
    Moderate,
    Heavy,
    Custom,
}

/// Parameters for the noise reduction pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoiseReductionParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Preset level for simple mode.
    #[serde(default)]
    pub preset: NoiseReductionPreset,

    /// Which noise reduction method to use.
    #[serde(default)]
    pub method: NoiseReductionMethod,

    // --- SMDegrain Parameters ---

    /// Temporal radius (1-6). Higher = more temporal smoothing.
    #[serde(default = "default_sm_degrain_tr", rename = "smDegrainTr")]
    pub sm_degrain_tr: i32,

    /// SAD threshold for luma. Higher = more denoising.
    #[serde(default = "default_sm_degrain_th_sad", rename = "smDegrainThSAD")]
    pub sm_degrain_th_sad: i32,

    /// SAD threshold for chroma. Higher = more chroma denoising.
    #[serde(default = "default_sm_degrain_th_sadc", rename = "smDegrainThSADC")]
    pub sm_degrain_th_sadc: i32,

    /// Refine motion vectors for better accuracy.
    #[serde(default = "default_true", rename = "smDegrainRefine")]
    pub sm_degrain_refine: bool,

    /// Prefilter mode (0-4). Higher = stronger prefiltering.
    #[serde(default = "default_sm_degrain_prefilter", rename = "smDegrainPrefilter")]
    pub sm_degrain_prefilter: i32,

    // --- MCTemporalDenoise Parameters ---

    /// Denoise strength/sigma.
    #[serde(default = "default_mc_temporal_sigma")]
    pub mc_temporal_sigma: f64,

    /// Temporal radius for MCTemporalDenoise.
    #[serde(default = "default_mc_temporal_radius")]
    pub mc_temporal_radius: i32,

    /// Profile setting for MCTemporalDenoise.
    #[serde(default = "default_mc_temporal_profile")]
    pub mc_temporal_profile: String,

    // --- MCDegrainSharp Parameters ---

    /// Number of neighbouring frames on each side to degrain against (1-3).
    #[serde(default = "default_mcds_frames")]
    pub mcds_frames: i32,

    /// Blur strength for the poorly-matched areas (0.0-1.58).
    #[serde(default = "default_mcds_blur")]
    pub mcds_blur: f64,

    /// Sharpening strength for the well-matched areas (0.0-1.0).
    #[serde(default = "default_mcds_sharp")]
    pub mcds_sharp: f64,

    /// Run the motion search on the blurred clip, which finds steadier vectors
    /// on noisy sources.
    #[serde(default = "default_true")]
    pub mcds_blur_search: bool,

    /// Block SAD threshold. Low staggers the denoising, high brings ghosting.
    #[serde(default = "default_mcds_th_sad")]
    pub mcds_th_sad: i32,

    /// Planes to process (0 luma, 1 U, 2 V, 3 both chroma, 4 all).
    #[serde(default = "default_mcds_plane")]
    pub mcds_plane: i32,

    // --- QTGMC Built-in Parameters ---

    /// EZDenoise strength (0.0 to 5.0+).
    #[serde(default)]
    pub qtgmc_ez_denoise: f64,

    /// EZKeepGrain amount (0.0 to 1.0).
    #[serde(default)]
    pub qtgmc_ez_keep_grain: f64,
}

fn default_sm_degrain_tr() -> i32 { 2 }
fn default_sm_degrain_th_sad() -> i32 { 300 }
fn default_sm_degrain_th_sadc() -> i32 { 150 }
fn default_true() -> bool { true }
fn default_sm_degrain_prefilter() -> i32 { 2 }
fn default_mc_temporal_sigma() -> f64 { 4.0 }
fn default_mc_temporal_radius() -> i32 { 2 }
fn default_mc_temporal_profile() -> String { "medium".to_string() }
fn default_mcds_frames() -> i32 { 2 }
fn default_mcds_blur() -> f64 { 0.3 }
fn default_mcds_sharp() -> f64 { 0.3 }
fn default_mcds_th_sad() -> i32 { 400 }
fn default_mcds_plane() -> i32 { 4 }

impl Default for NoiseReductionParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            preset: NoiseReductionPreset::default(),
            method: NoiseReductionMethod::default(),
            sm_degrain_tr: default_sm_degrain_tr(),
            sm_degrain_th_sad: default_sm_degrain_th_sad(),
            sm_degrain_th_sadc: default_sm_degrain_th_sadc(),
            sm_degrain_refine: true,
            sm_degrain_prefilter: default_sm_degrain_prefilter(),
            mc_temporal_sigma: default_mc_temporal_sigma(),
            mc_temporal_radius: default_mc_temporal_radius(),
            mc_temporal_profile: default_mc_temporal_profile(),
            mcds_frames: default_mcds_frames(),
            mcds_blur: default_mcds_blur(),
            mcds_sharp: default_mcds_sharp(),
            mcds_blur_search: true,
            mcds_th_sad: default_mcds_th_sad(),
            mcds_plane: default_mcds_plane(),
            qtgmc_ez_denoise: 0.0,
            qtgmc_ez_keep_grain: 0.0,
        }
    }
}

impl NoiseReductionParameters {
    /// TCanny sigma for the blur step.
    ///
    /// The user-facing 0.0-1.58 range maps onto TCanny's sigma scale, matching
    /// the published MCDegrainSharp so a setting means the same thing here as in
    /// the scripts people copy their numbers from.
    pub fn mcds_blur_sigma(&self) -> f64 {
        self.mcds_blur * MCDS_SIGMA_MAX / MCDS_BLUR_MAX
    }

    /// TCanny sigma for the unsharp-mask step, from the 0.0-1.0 range.
    pub fn mcds_sharp_sigma(&self) -> f64 {
        self.mcds_sharp * MCDS_SIGMA_MAX
    }

    /// The `planes` list literal matching `mcds_plane`.
    ///
    /// mvtools takes a single `plane` selector but TCanny takes a list, so the
    /// two have to agree or the blur/sharpen references would cover different
    /// planes than the degrain does.
    pub fn mcds_planes_literal(&self) -> String {
        match self.mcds_plane {
            0 => "[0]".to_string(),
            1 => "[1]".to_string(),
            2 => "[2]".to_string(),
            3 => "[1, 2]".to_string(),
            _ => "[0, 1, 2]".to_string(),
        }
    }

    /// Degrain frames, clamped to the 1-3 mvtools provides.
    pub fn mcds_effective_frames(&self) -> i32 {
        self.mcds_frames.clamp(1, 3)
    }
}

/// Top of TCanny's useful sigma range for these two steps.
const MCDS_SIGMA_MAX: f64 = 2.83;
/// Top of the user-facing blur range.
const MCDS_BLUR_MAX: f64 = 1.58;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_parameters() {
        let params = NoiseReductionParameters::default();
        assert!(!params.enabled);
        assert_eq!(params.preset, NoiseReductionPreset::Off);
        assert_eq!(params.method, NoiseReductionMethod::SmDegrain);
    }

    #[test]
    fn test_mcdegrainsharp_defaults() {
        let params = NoiseReductionParameters::default();
        assert_eq!(params.mcds_frames, 2);
        assert_eq!(params.mcds_th_sad, 400);
        assert_eq!(params.mcds_plane, 4);
        assert!(params.mcds_blur_search);
        // 0.3 of the way up each range.
        assert!((params.mcds_blur_sigma() - 0.537_341_772).abs() < 1e-6);
        assert!((params.mcds_sharp_sigma() - 0.849).abs() < 1e-9);
    }

    #[test]
    fn test_mcdegrainsharp_planes_literal_matches_plane_selector() {
        let with_plane = |plane: i32| NoiseReductionParameters {
            mcds_plane: plane,
            ..Default::default()
        };
        assert_eq!(with_plane(0).mcds_planes_literal(), "[0]");
        assert_eq!(with_plane(1).mcds_planes_literal(), "[1]");
        assert_eq!(with_plane(2).mcds_planes_literal(), "[2]");
        assert_eq!(with_plane(3).mcds_planes_literal(), "[1, 2]");
        assert_eq!(with_plane(4).mcds_planes_literal(), "[0, 1, 2]");
        // Anything unexpected falls back to all planes rather than none.
        assert_eq!(with_plane(9).mcds_planes_literal(), "[0, 1, 2]");
    }

    #[test]
    fn test_mcdegrainsharp_frames_are_clamped_to_mvtools_range() {
        let with_frames = |frames: i32| NoiseReductionParameters {
            mcds_frames: frames,
            ..Default::default()
        };
        assert_eq!(with_frames(0).mcds_effective_frames(), 1);
        assert_eq!(with_frames(2).mcds_effective_frames(), 2);
        assert_eq!(with_frames(7).mcds_effective_frames(), 3);
    }

    #[test]
    fn test_serialization() {
        let params = NoiseReductionParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"smDegrainTr\":2"));
    }
}
