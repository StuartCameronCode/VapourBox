use serde::{Deserialize, Serialize};

/// Deblocking method options.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub enum DeblockMethod {
    #[default]
    #[serde(rename = "Deblock_QED")]
    DeblockQed,
    #[serde(rename = "Deblock")]
    Deblock,
    /// DCTFilter: attenuates chosen DCT frequency bands directly. Targets
    /// ringing and mosquito noise rather than block edges.
    #[serde(rename = "DCTFilter")]
    DctFilter,
}

#[allow(dead_code)]
impl DeblockMethod {
    pub fn as_str(&self) -> &'static str {
        match self {
            DeblockMethod::DeblockQed => "Deblock_QED",
            DeblockMethod::Deblock => "Deblock",
            DeblockMethod::DctFilter => "DCTFilter",
        }
    }
}

/// Parameters for the deblocking pass.
/// Removes block artifacts from compressed video.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeblockParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Deblocking method to use.
    #[serde(default)]
    pub method: DeblockMethod,

    // --- Deblock_QED parameters ---

    /// Quant1: Strength for edges (0-60, default 24).
    #[serde(default = "default_quant1")]
    pub quant1: i32,

    /// Quant2: Strength for non-edges (0-60, default 26).
    #[serde(default = "default_quant2")]
    pub quant2: i32,

    /// Analyze planes offset 1.
    #[serde(default = "default_a_offset")]
    pub a_offset1: i32,

    /// Analyze planes offset 2.
    #[serde(default = "default_a_offset")]
    pub a_offset2: i32,

    // --- DCTFilter parameters ---

    /// Lowest frequency band left untouched (0-7). Everything above it is
    /// attenuated. Higher keeps more detail.
    #[serde(default = "default_dct_cutoff")]
    pub dct_cutoff: i32,

    /// How hard the bands above the cutoff are attenuated (0.0-1.0), where 1.0
    /// removes them entirely.
    #[serde(default = "default_dct_strength")]
    pub dct_strength: f64,

    /// Planes to filter: 0 luma only, 1 chroma only, 2 both.
    #[serde(default = "default_dct_planes")]
    pub dct_planes: i32,
}

fn default_quant1() -> i32 { 24 }
fn default_quant2() -> i32 { 26 }
fn default_dct_cutoff() -> i32 { 5 }
fn default_dct_strength() -> f64 { 0.6 }
fn default_dct_planes() -> i32 { 0 }
fn default_a_offset() -> i32 { 1 }

impl Default for DeblockParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            method: DeblockMethod::default(),
            quant1: default_quant1(),
            quant2: default_quant2(),
            a_offset1: default_a_offset(),
            a_offset2: default_a_offset(),
            dct_cutoff: default_dct_cutoff(),
            dct_strength: default_dct_strength(),
            dct_planes: default_dct_planes(),
        }
    }
}

impl DeblockParameters {
    /// The eight DCTFilter coefficients, as a Python list literal.
    ///
    /// DCTFilter takes exactly eight factors and applies them **separably** —
    /// coefficient (u, v) is scaled by `factors[u] * factors[v]`, measured, not
    /// the `max(u, v)` the Avisynth filter of the same name uses. So band k
    /// affects a whole row *and* column, and the DC term is scaled by
    /// `factors[0]` squared. Exposing eight raw sliders would be both
    /// unusable and misleading, so the UI has a cutoff and a strength and this
    /// builds the curve.
    ///
    /// Bands up to and including the cutoff stay at 1.0; above it they ramp down
    /// linearly to `1.0 - strength`. All 1.0 is a verified exact no-op.
    ///
    /// Every value is clamped into [0.0, 1.0] and any non-finite value becomes
    /// 1.0: **DCTFilter's own range check lets NaN through** (`nan < 0.0` and
    /// `nan > 1.0` are both false) and a NaN factor silently blackens the entire
    /// frame with no error anywhere.
    pub fn dct_factors_literal(&self) -> String {
        let cutoff = self.dct_cutoff.clamp(0, 7);
        let strength = if self.dct_strength.is_finite() {
            self.dct_strength.clamp(0.0, 1.0)
        } else {
            0.0
        };

        let above = 7 - cutoff;
        let factors: Vec<String> = (0..8)
            .map(|band| {
                let value = if band <= cutoff || above == 0 {
                    1.0
                } else {
                    let step = (band - cutoff) as f64 / above as f64;
                    1.0 - strength * step
                };
                let value = if value.is_finite() { value.clamp(0.0, 1.0) } else { 1.0 };
                format!("{:.4}", value)
            })
            .collect();
        format!("[{}]", factors.join(", "))
    }

    /// The `planes` list literal for DCTFilter.
    pub fn dct_planes_literal(&self) -> &'static str {
        match self.dct_planes {
            1 => "[1, 2]",
            2 => "[0, 1, 2]",
            _ => "[0]",
        }
    }
}

#[cfg(test)]
mod dct_tests {
    use super::*;

    #[test]
    fn test_default_factors_attenuate_only_the_top_bands() {
        let p = DeblockParameters::default();
        let f = p.dct_factors_literal();
        // cutoff 5 leaves bands 0-5 alone and ramps 6 and 7 down.
        assert!(f.starts_with("[1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000,"));
        assert!(f.ends_with("0.4000]"), "got {f}");
    }

    #[test]
    fn test_zero_strength_is_an_exact_no_op() {
        // All 1.0 is a verified bit-exact identity on integer formats, so a
        // strength of zero must produce exactly that.
        let p = DeblockParameters { dct_strength: 0.0, ..Default::default() };
        assert_eq!(
            p.dct_factors_literal(),
            "[1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000]"
        );
    }

    #[test]
    fn test_nan_strength_cannot_reach_the_plugin() {
        // DCTFilter's own bounds check lets NaN through — nan < 0.0 and
        // nan > 1.0 are both false — and a NaN factor silently blackens the
        // whole frame with no error anywhere.
        let p = DeblockParameters { dct_strength: f64::NAN, ..Default::default() };
        let f = p.dct_factors_literal();
        assert!(!f.to_lowercase().contains("nan"), "got {f}");
        assert_eq!(
            f,
            "[1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000]",
            "a non-finite strength must fall back to the no-op curve"
        );

        for bad in [f64::INFINITY, f64::NEG_INFINITY] {
            let p = DeblockParameters { dct_strength: bad, ..Default::default() };
            assert!(!p.dct_factors_literal().to_lowercase().contains("inf"));
        }
    }

    #[test]
    fn test_every_factor_stays_inside_the_accepted_range() {
        for cutoff in -3..=10 {
            for strength in [-1.0, 0.0, 0.5, 1.0, 2.0] {
                let p = DeblockParameters {
                    dct_cutoff: cutoff,
                    dct_strength: strength,
                    ..Default::default()
                };
                let literal = p.dct_factors_literal();
                let values: Vec<f64> = literal
                    .trim_matches(|c| c == '[' || c == ']')
                    .split(", ")
                    .map(|v| v.parse().unwrap())
                    .collect();
                assert_eq!(values.len(), 8, "DCTFilter requires exactly 8 factors");
                for v in values {
                    assert!((0.0..=1.0).contains(&v), "{v} out of range in {literal}");
                }
            }
        }
    }

    #[test]
    fn test_cutoff_seven_leaves_everything_alone() {
        let p = DeblockParameters { dct_cutoff: 7, dct_strength: 1.0, ..Default::default() };
        assert_eq!(
            p.dct_factors_literal(),
            "[1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000]"
        );
    }
}
