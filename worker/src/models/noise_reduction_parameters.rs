//! Noise reduction parameters for video restoration.

use serde::{Deserialize, Serialize};

/// Noise reduction method options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum NoiseReductionMethod {
    #[default]
    SmDegrain,
    McTemporalDenoise,
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
fn default_mc_temporal_profile() -> String { "fast".to_string() }

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
            qtgmc_ez_denoise: 0.0,
            qtgmc_ez_keep_grain: 0.0,
        }
    }
}

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
    fn test_serialization() {
        let params = NoiseReductionParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"smDegrainTr\":2"));
    }
}
