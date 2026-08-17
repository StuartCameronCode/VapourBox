//! Image stabilisation parameters.
//!
//! havsfunc's `Stab` measures global motion with MVTools' Depan family and
//! cancels it, so a shaky capture holds still while intended camera movement
//! survives. Aimed at telecine weave, jittery film scans and handheld camcorder
//! footage.
//!
//! It does not change the frame count, which is why it is an ordinary pass and
//! not one of the frame-rate-changing filters that would touch `FrameMap`.
//!
//! No bit-depth limit — verified against the bundle at 8/10/12/16-bit and 4:2:2.

use serde::{Deserialize, Serialize};

/// Parameters for the stabilisation pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StabilizeParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Maximum horizontal correction in pixels.
    #[serde(default = "default_dxmax")]
    pub dxmax: i32,

    /// Maximum vertical correction in pixels.
    #[serde(default = "default_dymax")]
    pub dymax: i32,

    /// How to fill the edges the shift exposes: 0 none (left black), 1 top and
    /// bottom, 2 left and right, 3 all four. Mirroring saves the user having to
    /// crop afterwards.
    #[serde(default)]
    pub mirror: i32,
}

fn default_dxmax() -> i32 { 4 }
fn default_dymax() -> i32 { 4 }

impl Default for StabilizeParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            dxmax: default_dxmax(),
            dymax: default_dymax(),
            mirror: 0,
        }
    }
}

impl StabilizeParameters {
    /// Edge-fill mode, clamped to the 0-3 DePanStabilise implements.
    pub fn effective_mirror(&self) -> i32 {
        self.mirror.clamp(0, 3)
    }

    /// Maximum horizontal correction, clamped non-negative. A negative value is
    /// accepted by DepanStabilise and disables correction on that axis, which
    /// looks like the filter doing nothing.
    pub fn effective_dxmax(&self) -> i32 {
        self.dxmax.max(0)
    }

    /// See [`Self::effective_dxmax`].
    pub fn effective_dymax(&self) -> i32 {
        self.dymax.max(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults() {
        let p = StabilizeParameters::default();
        assert!(!p.enabled);
        assert_eq!(p.dxmax, 4);
        assert_eq!(p.dymax, 4);
        assert_eq!(p.mirror, 0);
    }

    #[test]
    fn test_parameters_match_the_bundled_havsfunc_signature() {
        // Stab(clp, dxmax=4, dymax=4, mirror=0). There is no `range` argument —
        // an earlier version of this model invented one, and havsfunc rejected
        // it with a TypeError that only the end-to-end test caught. Introspect
        // the signature; do not assume it from another implementation.
        let json = serde_json::to_string(&StabilizeParameters::default()).unwrap();
        assert!(json.contains("\"dxmax\":4"));
        assert!(json.contains("\"dymax\":4"));
        assert!(json.contains("\"mirror\":0"));
        assert!(!json.contains("range"));
    }

    #[test]
    fn test_mirror_is_clamped() {
        let with = |m: i32| StabilizeParameters { mirror: m, ..Default::default() };
        assert_eq!(with(-1).effective_mirror(), 0);
        assert_eq!(with(3).effective_mirror(), 3);
        assert_eq!(with(9).effective_mirror(), 3);
    }

    #[test]
    fn test_negative_limits_would_silently_disable_an_axis() {
        let with = |d: i32| StabilizeParameters {
            dxmax: d,
            dymax: d,
            ..Default::default()
        };
        assert_eq!(with(-1).effective_dxmax(), 0);
        assert_eq!(with(-1).effective_dymax(), 0);
        assert_eq!(with(6).effective_dxmax(), 6);
    }

    #[test]
    fn test_serialization() {
        let json = serde_json::to_string(&StabilizeParameters::default()).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"dxmax\":4"));
    }
}
