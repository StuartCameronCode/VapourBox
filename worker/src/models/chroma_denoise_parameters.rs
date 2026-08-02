//! Chroma denoise parameters (CCD — Camcorder Colour Denoise).

use serde::{Deserialize, Serialize};

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
}

fn default_threshold() -> f64 { 4.0 }
fn default_true() -> bool { true }

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
        self.temporal_radius.max(0) as u32
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
