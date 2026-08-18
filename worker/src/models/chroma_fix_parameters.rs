//! Chroma fix parameters for video processing.

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

    // --- Chroma Shift (Y/C Delay) Parameters ---

    /// Whether to apply chroma shift (Y/C delay correction).
    #[serde(default)]
    pub apply_chroma_shift: bool,

    /// Horizontal chroma shift in luma pixels (negative = left, positive = right).
    #[serde(default)]
    pub chroma_shift_h: f64,

    /// Vertical chroma shift in luma pixels (negative = up, positive = down).
    #[serde(default)]
    pub chroma_shift_v: f64,

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
    #[serde(default = "default_chroma_bleed_strength")]
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

    // --- LUTDeRainbow (cross-luminance / rainbowing) ---

    /// Apply LUTDeRainbow.
    #[serde(default)]
    pub apply_de_rainbow: bool,

    /// DeDot — temporal dot crawl / rainbow removal on both planes.
    #[serde(default)]
    pub apply_dedot: bool,

    /// Measure the chroma misalignment and correct it automatically.
    #[serde(default)]
    pub apply_auto_chroma: bool,
    /// Largest shift to search for, in pixels.
    #[serde(default = "default_acf_max_shift")]
    pub auto_chroma_max_shift: i32,
    /// Sub-pixel search step.
    #[serde(default = "default_acf_accuracy")]
    pub auto_chroma_accuracy: f64,
    /// Measure once on this frame (-1 measures every frame, ~23x the cost).
    #[serde(default)]
    pub auto_chroma_reference_frame: i32,
    /// Spatial luma threshold (0-510).
    #[serde(default = "default_dedot_luma_2d")]
    pub dedot_luma_2d: i32,
    /// Temporal luma threshold (0-255).
    #[serde(default = "default_dedot_luma_t")]
    pub dedot_luma_t: i32,
    /// Chroma threshold 1 (0-255).
    #[serde(default = "default_dedot_chroma_t1")]
    pub dedot_chroma_t1: i32,
    /// Chroma threshold 2 (0-255). 255 bypasses chroma entirely.
    #[serde(default = "default_dedot_chroma_t2")]
    pub dedot_chroma_t2: i32,

    /// Chroma difference threshold for detecting rainbowing.
    #[serde(default = "default_de_rainbow_cthresh")]
    pub de_rainbow_c_thresh: i32,

    /// Luma difference threshold. Areas moving more than this are left alone.
    #[serde(default = "default_de_rainbow_ythresh")]
    pub de_rainbow_y_thresh: i32,

    /// Use the luma difference in the decision as well as chroma.
    #[serde(default = "default_true")]
    pub de_rainbow_use_luma: bool,

    /// Require both chroma planes to agree before treating a pixel.
    #[serde(default = "default_true")]
    pub de_rainbow_link_uv: bool,

    // --- Bifrost (temporal rainbow removal) ---

    /// Apply Bifrost. Where LUTDeRainbow works within a frame, this compares
    /// across frames, so it catches rainbowing that shimmers rather than sits
    /// still.
    #[serde(default)]
    pub apply_bifrost: bool,

    /// Luma difference above which a block is treated as motion and left alone.
    #[serde(default = "default_bifrost_luma_thresh")]
    pub bifrost_luma_thresh: f64,

    /// How many neighbouring blocks must agree before a pixel is treated
    /// (0-3). Higher is more conservative.
    #[serde(default = "default_bifrost_variation")]
    pub bifrost_variation: i32,

    /// Treat the source as interlaced, comparing fields rather than frames.
    #[serde(default = "default_true")]
    pub bifrost_interlaced: bool,

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
}

fn default_chroma_bleed_offset() -> i32 { 4 }
fn default_chroma_bleed_blur() -> f64 { 0.7 }
fn default_chroma_bleed_strength() -> f64 { 0.8 }
fn default_de_crawl_thresh() -> i32 { 10 }
fn default_de_crawl_max_diff() -> i32 { 50 }
fn default_true() -> bool { true }
fn default_de_rainbow_cthresh() -> i32 { 10 }
fn default_de_rainbow_ythresh() -> i32 { 10 }
fn default_bifrost_luma_thresh() -> f64 { 10.0 }
fn default_bifrost_variation() -> i32 { 5 }
fn default_vinverse_sstr() -> f64 { 2.7 }
fn default_255() -> i32 { 255 }

fn default_acf_max_shift() -> i32 { 2 }
fn default_acf_accuracy() -> f64 { 0.25 }
fn default_dedot_luma_2d() -> i32 { 20 }
fn default_dedot_luma_t() -> i32 { 20 }
fn default_dedot_chroma_t1() -> i32 { 15 }
fn default_dedot_chroma_t2() -> i32 { 5 }

impl Default for ChromaFixParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            preset: ChromaFixPreset::default(),
            apply_chroma_shift: false,
            chroma_shift_h: 0.0,
            chroma_shift_v: 0.0,
            apply_chroma_bleeding_fix: false,
            chroma_bleed_cx: default_chroma_bleed_offset(),
            chroma_bleed_cy: default_chroma_bleed_offset(),
            chroma_bleed_c_blur: default_chroma_bleed_blur(),
            chroma_bleed_strength: default_chroma_bleed_strength(),
            apply_de_crawl: false,
            apply_de_rainbow: false,
            apply_dedot: false,
            apply_auto_chroma: false,
            auto_chroma_max_shift: default_acf_max_shift(),
            auto_chroma_accuracy: default_acf_accuracy(),
            auto_chroma_reference_frame: 0,
            dedot_luma_2d: default_dedot_luma_2d(),
            dedot_luma_t: default_dedot_luma_t(),
            dedot_chroma_t1: default_dedot_chroma_t1(),
            dedot_chroma_t2: default_dedot_chroma_t2(),
            de_rainbow_c_thresh: default_de_rainbow_cthresh(),
            de_rainbow_y_thresh: default_de_rainbow_ythresh(),
            de_rainbow_use_luma: true,
            de_rainbow_link_uv: true,
            apply_bifrost: false,
            bifrost_luma_thresh: default_bifrost_luma_thresh(),
            bifrost_variation: default_bifrost_variation(),
            bifrost_interlaced: true,
            de_crawl_y_thresh: default_de_crawl_thresh(),
            de_crawl_c_thresh: default_de_crawl_thresh(),
            de_crawl_max_diff: default_de_crawl_max_diff(),
            apply_vinverse: false,
            vinverse_sstr: default_vinverse_sstr(),
            vinverse_amnt: default_255(),
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
        assert!(!params.apply_chroma_shift);
        assert_eq!(params.chroma_shift_h, 0.0);
        assert_eq!(params.chroma_shift_v, 0.0);
        assert!(!params.apply_chroma_bleeding_fix);
        assert!(!params.apply_de_crawl);
        assert!(!params.apply_vinverse);
    }

    #[test]
    fn test_automatic_alignment_supersedes_the_manual_shift() {
        let mut params = ChromaFixParameters {
            apply_chroma_shift: true,
            chroma_shift_h: 2.0,
            ..ChromaFixParameters::default()
        };
        assert!(params.effective_apply_chroma_shift());

        params.apply_auto_chroma = true;
        assert!(
            !params.effective_apply_chroma_shift(),
            "the automatic pass already corrects the shift; applying the manual \
             one on top would double-correct it"
        );
        // The user's own setting survives, so unticking automatic restores it.
        assert!(params.apply_chroma_shift);
        assert_eq!(params.chroma_shift_h, 2.0);
    }

    #[test]
    fn test_serialization() {
        let params = ChromaFixParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"chromaBleedCx\":4"));
    }
}

impl ChromaFixParameters {
    /// Bifrost's `variation`, clamped to the range it accepts.
    pub fn bifrost_effective_variation(&self) -> i32 {
        self.bifrost_variation.clamp(0, 10)
    }

    /// Whether the manual Y/C delay shift reaches the script.
    ///
    /// Automatic alignment measures the misalignment and corrects it, and its
    /// block runs *before* the manual shift — so with both set the picture is
    /// shifted twice, the second time by a number the user guessed on top of a
    /// correction that was already measured. The automatic measurement wins:
    /// the panel hides the manual controls while it is on
    /// (`chroma_fixes.json`, `visibleWhen: {applyAutoChroma: false}`) and this
    /// keeps the generated script agreeing with what the panel shows.
    ///
    /// It deliberately does not clear `apply_chroma_shift` in the job, so
    /// turning automatic alignment off restores what the user set by hand.
    /// `ChromaFixParameters.effectiveApplyChromaShift` is the Dart twin.
    pub fn effective_apply_chroma_shift(&self) -> bool {
        self.apply_chroma_shift && !self.apply_auto_chroma
    }
}
