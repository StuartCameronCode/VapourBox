//! Color correction parameters for video restoration.

use serde::{Deserialize, Serialize};

/// Color correction preset options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ColorCorrectionPreset {
    #[default]
    Off,
    BroadcastSafe,
    EnhanceColors,
    Desaturate,
    Custom,
}

/// Parameters for the color correction pass.
/// Uses adjust.Tweak and SmoothLevels from havsfunc.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColorCorrectionParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Preset level for simple mode.
    #[serde(default)]
    pub preset: ColorCorrectionPreset,

    // --- Tweak Parameters (from adjust.py) ---

    /// Brightness adjustment (-255 to 255).
    #[serde(default)]
    pub brightness: f64,

    /// Contrast adjustment (0.0 to 10.0, 1.0 = no change).
    #[serde(default = "default_one_f64")]
    pub contrast: f64,

    /// Hue rotation in degrees (-180 to 180).
    #[serde(default)]
    pub hue: f64,

    /// Saturation adjustment (0.0 to 10.0, 1.0 = no change).
    #[serde(default = "default_one_f64")]
    pub saturation: f64,

    /// Coring - clamp output to TV range (16-235).
    #[serde(default)]
    pub coring: bool,

    // --- SmoothLevels Parameters ---

    /// Whether to apply levels adjustment.
    #[serde(default)]
    pub apply_levels: bool,

    /// Input black level (0-255).
    #[serde(default)]
    pub input_low: i32,

    /// Input white level (0-255).
    #[serde(default = "default_255")]
    pub input_high: i32,

    /// Output black level (0-255).
    #[serde(default)]
    pub output_low: i32,

    /// Output white level (0-255).
    #[serde(default = "default_255")]
    pub output_high: i32,

    /// Gamma adjustment (0.1 to 10.0, 1.0 = no change).
    #[serde(default = "default_one_f64")]
    pub gamma: f64,
}

fn default_one_f64() -> f64 { 1.0 }
fn default_255() -> i32 { 255 }

impl Default for ColorCorrectionParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            preset: ColorCorrectionPreset::default(),
            brightness: 0.0,
            contrast: 1.0,
            hue: 0.0,
            saturation: 1.0,
            coring: false,
            apply_levels: false,
            input_low: 0,
            input_high: 255,
            output_low: 0,
            output_high: 255,
            gamma: 1.0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_parameters() {
        let params = ColorCorrectionParameters::default();
        assert!(!params.enabled);
        assert_eq!(params.preset, ColorCorrectionPreset::Off);
        assert_eq!(params.contrast, 1.0);
        assert_eq!(params.saturation, 1.0);
    }

    #[test]
    fn test_serialization() {
        let params = ColorCorrectionParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"contrast\":1.0"));
    }
}
