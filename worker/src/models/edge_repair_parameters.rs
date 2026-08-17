//! Edge Repair — rebuild the dirty rows and columns at the frame border.
//!
//! Near-universal on tape captures, and today the only remedy is to crop them
//! away, which throws picture away with them.
//!
//! FillBorders won a measured three-way against EdgeFixer and bbmod. Its error
//! is **constant at 1.29 across three different damage models** — the signature
//! of a filter that discards the border entirely and rebuilds from the interior.
//! That is exactly the property a non-expert control needs: the result does not
//! depend on how bad the damage is, so it cannot fail badly. EdgeFixer beat it
//! in one case by 0.38/255 and lost catastrophically in another (30.81 at the
//! wrong radius), and is luma-only besides — it leaves the coloured fringe that
//! makes a tape edge obvious. bbmod lost every case and costs 19 parameters.
//!
//! **Widths are even, and that is load-bearing.** The bundle pins FillBorders
//! v2, the newest tag with published binaries. v2 and v4 are bit-identical at
//! even widths; they differ only at odd widths, where v2 leaves subsampled
//! chroma unrepaired. `crop_resize` already steps every crop control by 2 for
//! the same chroma-alignment reason, so the constraint costs nothing.

use serde::{Deserialize, Serialize};

/// Parameters for the edge repair pass.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EdgeRepairParameters {
    #[serde(default)]
    pub enabled: bool,

    #[serde(default)]
    pub left: i32,
    #[serde(default)]
    pub right: i32,
    #[serde(default)]
    pub top: i32,
    #[serde(default)]
    pub bottom: i32,

    /// `fillmargins` or `repeat` or `mirror`. Advanced: the measured difference
    /// between the first two is 1.29 against 1.29.
    #[serde(default = "default_mode")]
    pub mode: String,
}

fn default_mode() -> String { "fillmargins".to_string() }

impl EdgeRepairParameters {
    /// Each edge rounded down to an even count and bounded.
    ///
    /// Even is what makes v2 bit-identical to v4 on subsampled chroma; the
    /// bound stops a value from a stale saved job eating the picture.
    pub fn even(value: i32) -> i32 {
        (value.clamp(0, 64) / 2) * 2
    }

    /// True when at least one edge would actually be repaired.
    pub fn has_effect(&self) -> bool {
        self.enabled
            && [self.left, self.right, self.top, self.bottom]
                .iter()
                .any(|v| Self::even(*v) > 0)
    }

    /// Only the modes the plugin accepts; anything else falls back to the
    /// default rather than reaching the plugin as a broken argument.
    pub fn effective_mode(&self) -> &str {
        match self.mode.as_str() {
            "repeat" | "mirror" | "fillmargins" => self.mode.as_str(),
            _ => "fillmargins",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widths_are_forced_even() {
        // Odd widths are the only case where the pinned v2 differs from v4:
        // it leaves subsampled chroma unrepaired there.
        assert_eq!(EdgeRepairParameters::even(3), 2);
        assert_eq!(EdgeRepairParameters::even(1), 0);
        assert_eq!(EdgeRepairParameters::even(4), 4);
    }

    #[test]
    fn widths_are_bounded_and_never_negative() {
        assert_eq!(EdgeRepairParameters::even(-8), 0);
        assert_eq!(EdgeRepairParameters::even(9999), 64);
    }

    #[test]
    fn enabled_with_every_edge_zero_does_nothing() {
        // Otherwise the pass row claims to be doing something it is not.
        let p = EdgeRepairParameters { enabled: true, ..Default::default() };
        assert!(!p.has_effect());
        let p = EdgeRepairParameters { enabled: true, top: 2, ..Default::default() };
        assert!(p.has_effect());
        // An odd 1 rounds to 0, so it also has no effect.
        let p = EdgeRepairParameters { enabled: true, top: 1, ..Default::default() };
        assert!(!p.has_effect());
    }

    #[test]
    fn an_unknown_mode_falls_back_rather_than_reaching_the_plugin() {
        let p = EdgeRepairParameters { mode: "nonsense".into(), ..Default::default() };
        assert_eq!(p.effective_mode(), "fillmargins");
    }
}
