//! Anti-aliasing parameters.
//!
//! Removes the stair-stepping ("jaggies") left along diagonal edges by
//! deinterlacing and by upscaling. Both methods work the same way: re-interpolate
//! the frame with an edge-directed kernel and take the smoother of the two
//! results, so the edge is rebuilt rather than blurred.
//!
//! None has a bit-depth limit — verified against the bundle at 8/10/12/16-bit
//! and 4:2:2, so no conversion guard is needed. SangNom's `aa` is in 8-bit
//! units at every depth; the plugin scales it itself.

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
    /// SangNom AA: supersample 2x, SangNom along each axis, back down. The
    /// sharpest of the three, about daa's speed (app 1.7.0, deps 1.16.0).
    #[serde(rename = "sangnom")]
    SangNom,
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
    /// Pinned to `nnedi3` (see [`Self::effective_santiag_type`]).
    #[serde(default = "default_santiag_type")]
    pub santiag_type: String,

    // --- SangNom parameters ---

    /// SangNom's anti-aliasing strength, 0-128 in 8-bit units (the plugin's
    /// default is 48). 0 still re-interpolates every other line; it only stops
    /// SangNom smoothing the edge direction it finds.
    #[serde(default = "default_sangnom_aa")]
    pub sangnom_aa: i32,
}

fn default_strength() -> i32 { 1 }
fn default_santiag_type() -> String { "nnedi3".to_string() }
fn default_sangnom_aa() -> i32 { 48 }

impl Default for AntiAliasParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            method: AntiAliasMethod::default(),
            santiag_strv: default_strength(),
            santiag_strh: default_strength(),
            santiag_type: default_santiag_type(),
            sangnom_aa: default_sangnom_aa(),
        }
    }
}

impl AntiAliasParameters {
    /// santiag's interpolator name, pinned to nnedi3.
    ///
    /// havsfunc accepts `nnedi3`, `eedi2` and `sangnom`. eedi2 is not bundled
    /// (naming it fails at script evaluation with a bare "no attribute"), and
    /// `sangnom`, although SangNom ships from deps 1.16.0, is broken in
    /// havsfunc: its strength-0 step calls `SangNom(order=0)`, which SangNom r45
    /// treats as double-rate and refuses without `_FieldBased` (measured).
    /// SangNom is offered as its own method instead.
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

    /// SangNom's `aa`, clamped to the 0-128 the plugin accepts (it rejects
    /// anything outside with a script error).
    pub fn effective_sangnom_aa(&self) -> i32 {
        self.sangnom_aa.clamp(0, 128)
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
        // eedi2 is not in the deps bundle, and havsfunc's sangnom type calls
        // SangNom(order=0), which SangNom r45 refuses; either would fail at
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
    fn test_sangnom_method_wire_name_and_strength() {
        let p: AntiAliasParameters =
            serde_json::from_str(r#"{"enabled":true,"method":"sangnom","sangnomAa":200}"#).unwrap();
        assert_eq!(p.method, AntiAliasMethod::SangNom);
        assert_eq!(p.effective_sangnom_aa(), 128);
        assert_eq!(AntiAliasParameters::default().sangnom_aa, 48);
        let json = serde_json::to_string(&p).unwrap();
        assert!(json.contains("\"method\":\"sangnom\""), "{json}");
    }

    #[test]
    fn test_serialization() {
        let json = serde_json::to_string(&AntiAliasParameters::default()).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"method\":\"daa\""));
        assert!(json.contains("\"santiagStrv\":1"));
    }
}
