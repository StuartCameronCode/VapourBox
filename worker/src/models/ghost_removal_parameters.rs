//! Ghost Removal (LGhost) — remove the displaced echo of the picture that RF
//! and cable distribution leave behind.
//!
//! Nothing else in the app addresses ghosting, and it is a distinct, frequently
//! reported tape complaint.
//!
//! The cleanest plugin probed for this work: **no format limits found at all**
//! across 8/10/12/16-bit, 4:2:0/4:2:2/4:4:4, GRAY and float, and a clean
//! `_FieldBased` matrix. Its natural interface is a repeating
//! `(mode, shift, intensity)` triple, which is unlike any control in this app —
//! so a short preset list is offered in simple mode and the triple editor sits
//! behind advanced.
//!
//! `opt` is deliberately not exposed: on arm64 every value produces
//! byte-identical output, so it is inert here and a footgun on x86.

use serde::{Deserialize, Serialize};

/// A single ghost to cancel.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GhostSpec {
    /// 1 = edge, 2 = luminance, 3 = rising edge, 4 = falling edge.
    /// 0 is rejected by the plugin.
    pub mode: i32,
    /// Horizontal displacement in pixels; must be less than the frame width.
    pub shift: i32,
    /// -128..127, and never zero — the plugin rejects zero.
    pub intensity: i32,
}

/// Parameters for the ghost removal pass.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GhostRemovalParameters {
    #[serde(default)]
    pub enabled: bool,

    /// The ghosts to cancel. Empty means the pass does nothing.
    #[serde(default)]
    pub ghosts: Vec<GhostSpec>,
}

impl GhostRemovalParameters {
    /// Only the specs the plugin will accept.
    ///
    /// It rejects `mode == 0` and `intensity == 0` at script evaluation rather
    /// than ignoring them, and requires the three arrays to be the same length
    /// — so an unusable entry has to be dropped here, not passed through.
    pub fn valid_ghosts(&self) -> Vec<&GhostSpec> {
        self.ghosts
            .iter()
            .filter(|g| (1..=4).contains(&g.mode) && g.intensity != 0
                && (-128..=127).contains(&g.intensity))
            .collect()
    }

    pub fn has_effect(&self) -> bool {
        self.enabled && !self.valid_ghosts().is_empty()
    }

    /// The three parallel array literals the plugin wants.
    pub fn literals(&self) -> (String, String, String) {
        let g = self.valid_ghosts();
        let join = |v: Vec<String>| format!("[{}]", v.join(", "));
        (
            join(g.iter().map(|x| x.mode.to_string()).collect()),
            join(g.iter().map(|x| x.shift.to_string()).collect()),
            join(g.iter().map(|x| x.intensity.to_string()).collect()),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn g(mode: i32, shift: i32, intensity: i32) -> GhostSpec {
        GhostSpec { mode, shift, intensity }
    }

    #[test]
    fn entries_the_plugin_rejects_are_dropped_not_forwarded() {
        // mode 0 and intensity 0 are hard errors at script evaluation.
        let p = GhostRemovalParameters {
            enabled: true,
            ghosts: vec![g(0, 4, 20), g(2, 4, 0), g(1, 4, 20), g(9, 4, 20)],
        };
        assert_eq!(p.valid_ghosts().len(), 1);
        assert_eq!(p.literals(), ("[1]".into(), "[4]".into(), "[20]".into()));
    }

    #[test]
    fn the_three_arrays_always_match_in_length() {
        // The plugin errors if they do not, so filtering must be simultaneous.
        let p = GhostRemovalParameters {
            enabled: true,
            ghosts: vec![g(1, 4, 20), g(0, 9, 30), g(3, -6, -15)],
        };
        let (m, s, i) = p.literals();
        assert_eq!(m, "[1, 3]");
        assert_eq!(s, "[4, -6]");
        assert_eq!(i, "[20, -15]");
    }

    #[test]
    fn enabled_with_no_usable_ghost_does_nothing() {
        let p = GhostRemovalParameters { enabled: true, ghosts: vec![g(0, 0, 0)] };
        assert!(!p.has_effect());
        assert!(!GhostRemovalParameters { enabled: true, ghosts: vec![] }.has_effect());
    }
}
