//! Chroma fix parameters for video restoration.

use serde::{Deserialize, Serialize};

/// Chroma fix preset options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ChromaFixPreset {
    #[default]
    Off,
    VhsCleanup,
    BroadcastFix,
    AnalogRepair,
    Custom,
}

/// Parameters for the chroma fix pass.
/// Includes FixChromaBleedingMod, LUTDeCrawl, and Vinverse filters.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChromaFixParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Preset level for simple mode.
    #[serde(default)]
    pub preset: ChromaFixPreset,

    // --- FixChromaBleedingMod Parameters ---

    /// Whether to apply chroma bleeding fix.
    #[serde(default)]
    pub apply_chroma_bleeding_fix: bool,

    /// Chroma X offset correction.
    #[serde(default = "default_chroma_bleed_offset")]
    pub chroma_bleed_cx: i32,

    /// Chroma Y offset correction.
    #[serde(default = "default_chroma_bleed_offset")]
    pub chroma_bleed_cy: i32,

    /// Chroma blur strength (0.0 to 1.5+).
    #[serde(default = "default_chroma_bleed_blur")]
    pub chroma_bleed_c_blur: f64,

    /// Fix strength (0.0 to 1.0).
    #[serde(default = "default_one_f64")]
    pub chroma_bleed_strength: f64,

    // --- LUTDeCrawl Parameters ---

    /// Whether to apply de-crawl (chroma crawl/dot crawl fix).
    #[serde(default)]
    pub apply_de_crawl: bool,

    /// Luma threshold for de-crawl.
    #[serde(default = "default_de_crawl_thresh")]
    pub de_crawl_y_thresh: i32,

    /// Chroma threshold for de-crawl.
    #[serde(default = "default_de_crawl_thresh")]
    pub de_crawl_c_thresh: i32,

    /// Maximum difference allowed.
    #[serde(default = "default_de_crawl_max_diff")]
    pub de_crawl_max_diff: i32,

    // --- Vinverse Parameters ---

    /// Whether to apply Vinverse (inverted telecine/chroma fix).
    #[serde(default)]
    pub apply_vinverse: bool,

    /// Spatial strength for Vinverse.
    #[serde(default = "default_vinverse_sstr")]
    pub vinverse_sstr: f64,

    /// Amount parameter for Vinverse (0-255).
    #[serde(default = "default_255")]
    pub vinverse_amnt: i32,

    /// Scale parameter for Vinverse.
    #[serde(default = "default_vinverse_scl")]
    pub vinverse_scl: i32,
}

fn default_chroma_bleed_offset() -> i32 { 4 }
fn default_chroma_bleed_blur() -> f64 { 0.7 }
fn default_one_f64() -> f64 { 1.0 }
fn default_de_crawl_thresh() -> i32 { 10 }
fn default_de_crawl_max_diff() -> i32 { 50 }
fn default_vinverse_sstr() -> f64 { 2.7 }
fn default_255() -> i32 { 255 }
fn default_vinverse_scl() -> i32 { 12 }

impl Default for ChromaFixParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            preset: ChromaFixPreset::default(),
            apply_chroma_bleeding_fix: false,
            chroma_bleed_cx: default_chroma_bleed_offset(),
            chroma_bleed_cy: default_chroma_bleed_offset(),
            chroma_bleed_c_blur: default_chroma_bleed_blur(),
            chroma_bleed_strength: default_one_f64(),
            apply_de_crawl: false,
            de_crawl_y_thresh: default_de_crawl_thresh(),
            de_crawl_c_thresh: default_de_crawl_thresh(),
            de_crawl_max_diff: default_de_crawl_max_diff(),
            apply_vinverse: false,
            vinverse_sstr: default_vinverse_sstr(),
            vinverse_amnt: default_255(),
            vinverse_scl: default_vinverse_scl(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_parameters() {
        let params = ChromaFixParameters::default();
        assert!(!params.enabled);
        assert_eq!(params.preset, ChromaFixPreset::Off);
        assert!(!params.apply_chroma_bleeding_fix);
        assert!(!params.apply_de_crawl);
        assert!(!params.apply_vinverse);
    }

    #[test]
    fn test_serialization() {
        let params = ChromaFixParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"chromaBleedCx\":4"));
    }
}
