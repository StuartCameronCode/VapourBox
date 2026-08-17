//! Chroma denoise parameters (CCD — Camcorder Colour Denoise).

use serde::{Deserialize, Serialize};

/// Which chroma denoiser to run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum ChromaDenoiseMethod {
    /// CCD — spatial (optionally temporal), averages over a wide radius.
    #[default]
    #[serde(rename = "ccd")]
    Ccd,
    /// Cnr4 — temporal, luma-gated. A different failure mode from CCD: it
    /// targets chroma that swims or shimmers over time rather than blotches
    /// that sit still.
    #[serde(rename = "cnr4")]
    Cnr4,
}

/// Frame height CCD was designed for. Its automatic `scale` is derived from the
/// source height relative to this, and the plugin rejects a scale below 1.0 —
/// so any source shorter than this needs an explicit clamped scale or the job
/// fails with "CCD: scale must be greater than or equal to 1.0".
pub const CCD_REFERENCE_HEIGHT: i32 = 480;

/// Parameters for the chroma denoise pass.
///
/// CCD is a chroma-only spatial (optionally temporal) denoiser, originally a
/// VirtualDub filter by Sergey Stolyarevsky, here via the zsmooth plugin. It is
/// the standard tool for the blotchy colour noise on VHS captures and old
/// camcorder footage, where luma is acceptable but chroma is a mess.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChromaDenoiseParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Which denoiser to run.
    #[serde(default)]
    pub method: ChromaDenoiseMethod,

    /// Euclidean RGB distance below which a neighbouring pixel joins the
    /// average. Higher denoises more.
    #[serde(default = "default_threshold")]
    pub threshold: f64,

    /// Temporal radius. 0 is spatial-only; higher pulls in neighbouring frames.
    #[serde(default)]
    pub temporal_radius: i32,

    /// Use the near reference points of the sampling matrix.
    #[serde(default = "default_true")]
    pub points_low: bool,

    /// Use the mid-distance reference points.
    #[serde(default = "default_true")]
    pub points_medium: bool,

    /// Use the far reference points. Off by default (the plugin's own default).
    #[serde(default)]
    pub points_high: bool,

    /// Sampling-radius multiplier. `None` derives it from the frame height, the
    /// same rule the plugin uses, but clamped so short sources still run.
    #[serde(default)]
    pub scale: Option<f64>,

    // ---- Cnr4 ----------------------------------------------------------
    /// Motion sensitivity. Higher tolerates more movement before it stops
    /// correcting, so higher also risks smearing moving colour.
    #[serde(default = "default_cnr4_sense")]
    pub cnr4_sense: i32,

    /// How far chroma is pulled toward the temporal average. The plugin's own
    /// default sits near the top of the range, so there is far more headroom
    /// downward than up.
    #[serde(default = "default_cnr4_strength")]
    pub cnr4_strength: i32,

    /// Temporal radius, 1-8.
    #[serde(default = "default_cnr4_radius")]
    pub cnr4_radius: i32,

    /// Detail-retention mode, 0-3.
    #[serde(default)]
    pub cnr4_tmode: i32,

    /// Weighting mode, 0-2.
    #[serde(default)]
    pub cnr4_wmode: i32,
}

fn default_threshold() -> f64 { 4.0 }
fn default_true() -> bool { true }
fn default_cnr4_sense() -> i32 { 35 }
fn default_cnr4_strength() -> i32 { 192 }
fn default_cnr4_radius() -> i32 { 2 }

impl Default for ChromaDenoiseParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            threshold: default_threshold(),
            temporal_radius: 0,
            points_low: true,
            points_medium: true,
            points_high: false,
            scale: None,
            method: ChromaDenoiseMethod::default(),
            cnr4_sense: default_cnr4_sense(),
            cnr4_strength: default_cnr4_strength(),
            cnr4_radius: default_cnr4_radius(),
            cnr4_tmode: 0,
            cnr4_wmode: 0,
        }
    }
}

impl ChromaDenoiseParameters {
    /// The `points` array literal for the generated script.
    pub fn points_literal(&self) -> String {
        let f = |b: bool| if b { "True" } else { "False" };
        format!(
            "[{}, {}, {}]",
            f(self.points_low),
            f(self.points_medium),
            f(self.points_high)
        )
    }

    /// Frames of temporal context this pass needs on each side.
    pub fn radius(&self) -> u32 {
        match self.method {
            ChromaDenoiseMethod::Ccd => self.temporal_radius.max(0) as u32,
            ChromaDenoiseMethod::Cnr4 => self.effective_cnr4_radius() as u32,
        }
    }

    /// Cnr4's radius, clamped to what the plugin accepts. Out of range is a
    /// hard error at script evaluation, not a clamp.
    pub fn effective_cnr4_radius(&self) -> i32 {
        self.cnr4_radius.clamp(1, 8)
    }

    /// Per-plane `sense`. Chroma planes get the plugin's own higher defaults
    /// scaled by the user's single control, because exposing three numbers for
    /// what reads as one idea is how this pass would stop being usable.
    pub fn cnr4_sense_literal(&self) -> String {
        let luma = self.cnr4_sense.clamp(0, 255);
        // The plugin's defaults are [35, 47, 47]: chroma is less sensitive than
        // luma by a fixed ratio, preserved here as the slider moves.
        let chroma = ((luma as f64) * 47.0 / 35.0).round().clamp(0.0, 255.0) as i32;
        format!("[{luma}, {chroma}, {chroma}]")
    }

    /// Per-plane `str`, same reasoning as `sense`. Defaults are [192, 255, 255].
    pub fn cnr4_strength_literal(&self) -> String {
        let luma = self.cnr4_strength.clamp(0, 255);
        let chroma = ((luma as f64) * 255.0 / 192.0).round().clamp(0.0, 255.0) as i32;
        format!("[{luma}, {chroma}, {chroma}]")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults_match_the_plugin() {
        let params = ChromaDenoiseParameters::default();
        assert!(!params.enabled);
        assert_eq!(params.threshold, 4.0);
        assert_eq!(params.temporal_radius, 0);
        // zsmooth's own default is [True, True, False].
        assert_eq!(params.points_literal(), "[True, True, False]");
        assert_eq!(params.scale, None);
        assert_eq!(params.radius(), 0);
    }

    #[test]
    fn test_points_literal_follows_the_checkboxes() {
        let params = ChromaDenoiseParameters {
            points_low: false,
            points_medium: true,
            points_high: true,
            ..ChromaDenoiseParameters::default()
        };
        assert_eq!(params.points_literal(), "[False, True, True]");
    }

    #[test]
    fn test_radius_tracks_temporal_radius() {
        let params = ChromaDenoiseParameters {
            temporal_radius: 3,
            ..ChromaDenoiseParameters::default()
        };
        assert_eq!(params.radius(), 3);
    }
}
