//! Film grain parameters.
//!
//! Re-adds grain after denoising, so a cleaned picture does not look plastic,
//! and masks the banding a shallow gradient shows once the noise that was
//! dithering it has been removed. Measured on a shallow 8-bit ramp: columns
//! showing any variation go from 0% to 100% even at the lowest useful strength.
//!
//! Runs LAST among the video passes. Grain added before a resize is resampled
//! away, and before a deband is smoothed away, so anything else would quietly
//! undo it.
//!
//! Neither method needs a bit-depth guard or 8-bit parameter scaling — verified
//! against the bundle at 8/10/12/16-bit and 4:2:2. `var` is already expressed in
//! 8-bit units and the plugin scales it internally, so applying the
//! `_levels_8bit()` treatment used elsewhere would quadruple the grain at
//! 10-bit.

use serde::{Deserialize, Serialize};

/// Grain generation method.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum GrainMethod {
    /// `core.grain.Add` — one strength control, grains luma and chroma, and can
    /// be static or animated.
    #[default]
    AddGrain,
    /// havsfunc `GrainFactory3` — three grain layers selected by luma level, so
    /// shadows get more grain than highlights. Closer to real film stock.
    ///
    /// Two limitations, both measured: it is **luma-only** (chroma comes back
    /// bit-identical), and it is **always animated** with no way to hold the
    /// pattern still.
    GrainFactory3,
}

/// Parameters for the grain pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GrainParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Which method to use.
    #[serde(default)]
    pub method: GrainMethod,

    // --- AddGrain ---

    /// Luma grain strength as a variance: the standard deviation of the noise
    /// is its square root, so 4 gives σ=2. 0 disables the pass entirely.
    #[serde(default = "default_var")]
    pub var: f64,

    /// Chroma grain strength, same units. 0 leaves chroma bit-identical.
    #[serde(default)]
    pub uvar: f64,

    /// Spatial correlation (0.0-0.9), which makes the grain coarser and more
    /// film-like. It also *reduces amplitude*, by
    /// `sqrt((1-c)/(1+c))` per axis — measured, not assumed.
    #[serde(default)]
    pub corr: f64,

    /// Hold the same grain pattern on every frame. Off by default: static grain
    /// over moving video reads as dirt on the lens.
    #[serde(default)]
    pub constant: bool,

    // --- GrainFactory3 ---

    /// Grain strength in the shadows.
    #[serde(default = "default_g1")]
    pub g1str: f64,

    /// Grain strength in the midtones.
    #[serde(default = "default_g2")]
    pub g2str: f64,

    /// Grain strength in the highlights.
    #[serde(default = "default_g3")]
    pub g3str: f64,

    /// Blends the grain with a 3-frame average, damping the animation. 0-100.
    #[serde(default)]
    pub temp_avg: i32,
}

fn default_var() -> f64 { 4.0 }
fn default_g1() -> f64 { 4.0 }
fn default_g2() -> f64 { 3.0 }
fn default_g3() -> f64 { 2.0 }

impl Default for GrainParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            method: GrainMethod::default(),
            var: default_var(),
            uvar: 0.0,
            corr: 0.0,
            constant: false,
            g1str: default_g1(),
            g2str: default_g2(),
            g3str: default_g3(),
            temp_avg: 0,
        }
    }
}

impl GrainParameters {
    /// Correlation clamped below 1.0.
    ///
    /// The plugin rejects anything outside 0.0-1.0 outright, and 1.0 itself is
    /// degenerate — it wraps back to uncorrelated noise at full amplitude, so a
    /// user dragging the slider to the top would get the opposite of what the
    /// control implies. Capped at 0.9, which is where it still behaves.
    pub fn effective_corr(&self) -> f64 {
        self.corr.clamp(0.0, 0.9)
    }

    /// Temporal averaging, clamped to the 0-100 havsfunc accepts.
    pub fn effective_temp_avg(&self) -> i32 {
        self.temp_avg.clamp(0, 100)
    }

    /// Whether the pass would actually change the picture.
    ///
    /// AddGrain with both strengths at zero is a measured no-op, so it emits
    /// nothing rather than an identity call.
    pub fn has_effect(&self) -> bool {
        if !self.enabled {
            return false;
        }
        match self.method {
            GrainMethod::AddGrain => self.var > 0.0 || self.uvar > 0.0,
            GrainMethod::GrainFactory3 => {
                self.g1str > 0.0 || self.g2str > 0.0 || self.g3str > 0.0
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults() {
        let p = GrainParameters::default();
        assert!(!p.enabled);
        assert_eq!(p.method, GrainMethod::AddGrain);
        // sigma = sqrt(var), so 4.0 is a subtle sigma of 2.
        assert_eq!(p.var, 4.0);
        assert_eq!(p.uvar, 0.0);
        assert!(!p.constant, "grain should animate by default");
    }

    #[test]
    fn test_correlation_is_capped_below_the_degenerate_value() {
        // corr = 1.0 is accepted by the plugin but wraps back to uncorrelated
        // noise at full amplitude — the opposite of what the control implies.
        let with = |c: f64| GrainParameters { corr: c, ..Default::default() };
        assert_eq!(with(0.0).effective_corr(), 0.0);
        assert_eq!(with(0.5).effective_corr(), 0.5);
        assert_eq!(with(1.0).effective_corr(), 0.9);
        assert_eq!(with(-2.0).effective_corr(), 0.0);
    }

    #[test]
    fn test_zero_strength_is_a_no_op_and_emits_nothing() {
        let silent = GrainParameters {
            enabled: true,
            var: 0.0,
            uvar: 0.0,
            ..Default::default()
        };
        assert!(!silent.has_effect());

        // Chroma-only grain still counts as an effect.
        let chroma_only = GrainParameters {
            enabled: true,
            var: 0.0,
            uvar: 2.0,
            ..Default::default()
        };
        assert!(chroma_only.has_effect());
    }

    #[test]
    fn test_grainfactory3_effect_keys_off_its_own_strengths() {
        let p = GrainParameters {
            enabled: true,
            method: GrainMethod::GrainFactory3,
            var: 0.0,
            uvar: 0.0,
            g1str: 4.0,
            ..Default::default()
        };
        assert!(p.has_effect(), "AddGrain's var must not gate GrainFactory3");

        let silent = GrainParameters {
            enabled: true,
            method: GrainMethod::GrainFactory3,
            g1str: 0.0,
            g2str: 0.0,
            g3str: 0.0,
            ..Default::default()
        };
        assert!(!silent.has_effect());
    }

    #[test]
    fn test_temp_avg_is_clamped() {
        let with = |t: i32| GrainParameters { temp_avg: t, ..Default::default() };
        assert_eq!(with(-5).effective_temp_avg(), 0);
        assert_eq!(with(50).effective_temp_avg(), 50);
        assert_eq!(with(500).effective_temp_avg(), 100);
    }

    #[test]
    fn test_serialization() {
        let json = serde_json::to_string(&GrainParameters::default()).unwrap();
        assert!(json.contains("\"method\":\"addGrain\""));
        assert!(json.contains("\"var\":4.0"));
    }
}
