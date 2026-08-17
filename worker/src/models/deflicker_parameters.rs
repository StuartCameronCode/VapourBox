//! Deflicker — remove brightness pulsing between frames.
//!
//! Two methods, because they address different faults and the measurements say
//! so. **Global** fits a gain and an offset per frame against a windowed
//! neighbourhood average: measured 83.5% of injected flicker removed, against
//! the local method's ~50%. **Local** damps per-region oscillation the global
//! one cannot see, because a whole-frame statistic cannot represent it.
//!
//! Global is the default. Cine-film flicker — the complaint this pass exists
//! for — is a whole-frame exposure fault.
//!
//! Note the plugin is deliberately unused. ReduceFlicker's non-SIMD path reads
//! the wrong neighbour frame, and its SIMD block is x86-only, so the ARM
//! bundles would have produced different pictures from the x86 ones. The local
//! method is a transcription validated against a numpy model of the C
//! semantics at zero levels of difference.

use serde::{Deserialize, Serialize};

/// Which deflicker to run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum DeflickerMethod {
    /// Whole-frame exposure correction. Removes ~83% of global flicker.
    #[default]
    #[serde(rename = "global")]
    Global,
    /// Local oscillation damper, for flicker that varies across the frame.
    #[serde(rename = "local")]
    Local,
}

/// Parameters for the deflicker pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeflickerParameters {
    #[serde(default)]
    pub enabled: bool,

    #[serde(default)]
    pub method: DeflickerMethod,

    /// Global: how far the correction is applied, 0-1.
    #[serde(default = "default_strength")]
    pub strength: f64,

    /// Global: frames either side used for the reference average.
    #[serde(default = "default_window")]
    pub window: i32,

    /// Local: 1-3. Higher compares against more distant frames.
    #[serde(default = "default_local_strength")]
    pub local_strength: i32,

    /// Local: asymmetric fold, stronger but less conservative.
    #[serde(default)]
    pub aggressive: bool,
}

fn default_strength() -> f64 { 1.0 }
fn default_window() -> i32 { 5 }
fn default_local_strength() -> i32 { 2 }

impl Default for DeflickerParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            method: DeflickerMethod::default(),
            strength: default_strength(),
            window: default_window(),
            local_strength: default_local_strength(),
            aggressive: false,
        }
    }
}

impl DeflickerParameters {
    /// Window clamped to what the module accepts; out of range raises.
    pub fn effective_window(&self) -> i32 {
        self.window.clamp(1, 12)
    }

    /// Local strength clamped to 1-3.
    pub fn effective_local_strength(&self) -> i32 {
        self.local_strength.clamp(1, 3)
    }

    /// Frames of temporal context needed either side, for preview windowing.
    pub fn radius(&self) -> u32 {
        match self.method {
            DeflickerMethod::Global => self.effective_window() as u32,
            // strength k compares against pairs up to +/-(k+1)
            DeflickerMethod::Local => (self.effective_local_strength() + 1) as u32,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn global_is_the_default_because_it_removes_more() {
        // 83.5% vs ~50% on injected whole-frame flicker, measured. Cine film
        // flicker is a whole-frame exposure fault.
        assert_eq!(DeflickerParameters::default().method, DeflickerMethod::Global);
    }

    #[test]
    fn out_of_range_values_are_clamped_rather_than_passed_through() {
        // The module raises ValueError rather than clamping, so a saved job
        // with a stale value would fail the whole encode.
        let p = DeflickerParameters { window: 99, local_strength: 9, ..Default::default() };
        assert_eq!(p.effective_window(), 12);
        assert_eq!(p.effective_local_strength(), 3);
        let n = DeflickerParameters { window: 0, local_strength: 0, ..Default::default() };
        assert_eq!(n.effective_window(), 1);
        assert_eq!(n.effective_local_strength(), 1);
    }

    #[test]
    fn radius_follows_the_method() {
        let g = DeflickerParameters { window: 5, ..Default::default() };
        assert_eq!(g.radius(), 5);
        let l = DeflickerParameters {
            method: DeflickerMethod::Local, local_strength: 2, ..Default::default()
        };
        assert_eq!(l.radius(), 3, "strength k reaches +/-(k+1)");
    }
}
