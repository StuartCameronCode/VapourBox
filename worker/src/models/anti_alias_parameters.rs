//! Anti-aliasing parameters.
//!
//! Removes the stair-stepping ("jaggies") left along diagonal edges by
//! deinterlacing and by upscaling. Both methods work the same way: re-interpolate
//! the frame with an edge-directed kernel and take the smoother of the two
//! results, so the edge is rebuilt rather than blurred.
//!
//! Neither has a bit-depth limit — verified against the bundle at 8/10/12/16-bit
//! and 4:2:2, so no conversion guard is needed.

use serde::{Deserialize, Serialize};

/// Anti-aliasing method options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum AntiAliasMethod {
    /// Double-rate anti-aliasing: interpolates both fields with nnedi3 and
    /// averages. The usual choice, and the gentler of the two.
    #[default]
    Daa,
    /// santiag: separate horizontal and vertical strength, so it can be aimed
    /// at one axis. Stronger, and slower.
    Santiag,
}

/// Parameters for the anti-aliasing pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AntiAliasParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Which method to use.
    #[serde(default)]
    pub method: AntiAliasMethod,

    // --- santiag parameters ---

    /// Vertical strength (0 disables the vertical pass).
    #[serde(default = "default_strength")]
    pub santiag_strv: i32,

    /// Horizontal strength (0 disables the horizontal pass).
    #[serde(default = "default_strength")]
    pub santiag_strh: i32,

    /// Interpolator for the vertical pass: `nnedi3`, `eedi2` or `sangnom`.
    /// Only `nnedi3` is bundled, so the others are not offered.
    #[serde(default = "default_santiag_type")]
    pub santiag_type: String,
}

fn default_strength() -> i32 { 1 }
fn default_santiag_type() -> String { "nnedi3".to_string() }

impl Default for AntiAliasParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            method: AntiAliasMethod::default(),
            santiag_strv: default_strength(),
            santiag_strh: default_strength(),
            santiag_type: default_santiag_type(),
        }
    }
}

impl AntiAliasParameters {
    /// santiag's interpolator name, restricted to what is bundled.
    ///
    /// havsfunc accepts `nnedi3`, `eedi2` and `sangnom`; only nnedi3 ships here,
    /// and naming an absent one fails at script evaluation with a bare "no
    /// attribute" error. Anything unrecognised falls back to nnedi3 rather than
    /// reaching havsfunc.
    pub fn effective_santiag_type(&self) -> &'static str {
        match self.santiag_type.to_ascii_lowercase().as_str() {
            "nnedi3" => "nnedi3",
            _ => "nnedi3",
        }
    }

    /// Strengths clamped to the 0-3 havsfunc implements.
    pub fn effective_strv(&self) -> i32 {
        self.santiag_strv.clamp(0, 3)
    }

    /// See [`Self::effective_strv`].
    pub fn effective_strh(&self) -> i32 {
        self.santiag_strh.clamp(0, 3)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults() {
        let p = AntiAliasParameters::default();
        assert!(!p.enabled);
        assert_eq!(p.method, AntiAliasMethod::Daa);
        assert_eq!(p.santiag_strv, 1);
        assert_eq!(p.santiag_strh, 1);
    }

    #[test]
    fn test_santiag_type_is_restricted_to_what_is_bundled() {
        // eedi2 and sangnom are not in the deps bundle; naming one would fail at
        // script evaluation rather than degrade.
        let with = |t: &str| AntiAliasParameters {
            santiag_type: t.to_string(),
            ..Default::default()
        };
        assert_eq!(with("nnedi3").effective_santiag_type(), "nnedi3");
        assert_eq!(with("eedi2").effective_santiag_type(), "nnedi3");
        assert_eq!(with("sangnom").effective_santiag_type(), "nnedi3");
        assert_eq!(with("").effective_santiag_type(), "nnedi3");
    }

    #[test]
    fn test_strengths_are_clamped() {
        let with = |v: i32| AntiAliasParameters {
            santiag_strv: v,
            santiag_strh: v,
            ..Default::default()
        };
        assert_eq!(with(-2).effective_strv(), 0);
        assert_eq!(with(1).effective_strv(), 1);
        assert_eq!(with(9).effective_strh(), 3);
    }

    #[test]
    fn test_serialization() {
        let json = serde_json::to_string(&AntiAliasParameters::default()).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"method\":\"daa\""));
        assert!(json.contains("\"santiagStrv\":1"));
    }
}
