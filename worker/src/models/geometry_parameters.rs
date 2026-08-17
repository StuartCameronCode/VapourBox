//! Rotation and flip parameters.
//!
//! Ordinary geometry the app had no way to do: sideways phone footage, mirrored
//! camcorder captures, film scans that came off the scanner rotated.
//!
//! Everything here is `core.std`, so there is no plugin dependency and no
//! bit-depth limit — the operations move samples without touching their values.
//!
//! Runs BEFORE Crop/Resize, because a quarter turn swaps width and height and
//! every later decision about framing and aspect depends on which way round the
//! frame is.

use serde::{Deserialize, Serialize};

/// Quarter-turn rotation, clockwise.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Rotation {
    #[default]
    None,
    /// 90° clockwise. Swaps width and height.
    Cw90,
    /// 180°. Keeps the frame shape.
    Rotate180,
    /// 90° anticlockwise (270° clockwise). Swaps width and height.
    Ccw90,
}

impl Rotation {
    /// The `core.std` function implementing this rotation, if any.
    pub fn function(&self) -> Option<&'static str> {
        match self {
            Rotation::None => None,
            Rotation::Cw90 => Some("Turn90"),
            Rotation::Rotate180 => Some("Turn180"),
            Rotation::Ccw90 => Some("Turn270"),
        }
    }

    /// Whether this rotation exchanges width and height.
    ///
    /// This is what makes the pass more than cosmetic: a quarter turn changes
    /// the frame's shape, so a non-square sample aspect no longer describes it
    /// and every later framing decision sees different dimensions.
    pub fn swaps_axes(&self) -> bool {
        matches!(self, Rotation::Cw90 | Rotation::Ccw90)
    }
}

/// Parameters for the rotate/flip pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeometryParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Quarter-turn rotation.
    #[serde(default)]
    pub rotation: Rotation,

    /// Mirror left-to-right. Applied after the rotation.
    #[serde(default)]
    pub flip_horizontal: bool,

    /// Mirror top-to-bottom. Applied after the rotation.
    #[serde(default)]
    pub flip_vertical: bool,
}

impl Default for GeometryParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            rotation: Rotation::default(),
            flip_horizontal: false,
            flip_vertical: false,
        }
    }
}

impl GeometryParameters {
    /// Whether the pass would actually change anything.
    ///
    /// Enabled with no rotation and no flip is a no-op, and emitting nothing for
    /// it keeps the generated script honest about what runs.
    pub fn has_effect(&self) -> bool {
        self.enabled
            && (self.rotation != Rotation::None || self.flip_horizontal || self.flip_vertical)
    }

    /// Whether this pass exchanges the frame's width and height.
    pub fn swaps_axes(&self) -> bool {
        self.enabled && self.rotation.swaps_axes()
    }

    /// The source's sample aspect as it applies *after* this pass.
    ///
    /// SAR is the ratio of a pixel's width to its height, so a quarter turn
    /// inverts it: the 10:11 of a PAL DVD becomes 11:10 once the frame is on its
    /// side. The Y4M pipe strips aspect metadata, so the worker re-declares it to
    /// ffmpeg from this value — and declaring the un-inverted ratio would stretch
    /// a rotated anamorphic source by the square of its own aspect.
    ///
    /// A half turn and the flips leave pixel shape alone.
    pub fn adjusted_sar(&self, input_sar: Option<&str>) -> Option<String> {
        let sar = input_sar?.trim();
        if !self.swaps_axes() {
            return Some(sar.to_string());
        }
        // Anything that is not a ratio is passed through untouched rather than
        // dropped: losing the declaration entirely would leave ffmpeg with no
        // aspect at all, which is worse than leaving an odd one alone.
        let Some((num, den)) = sar.split_once(':').or_else(|| sar.split_once('/')) else {
            return Some(sar.to_string());
        };
        let (num, den) = (num.trim(), den.trim());
        // Only invert something that actually parses as a ratio; anything else
        // is passed through untouched rather than turned into a broken argument.
        if num.parse::<f64>().is_err() || den.parse::<f64>().is_err() {
            return Some(sar.to_string());
        }
        Some(format!("{}:{}", den, num))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults_are_a_no_op() {
        let p = GeometryParameters::default();
        assert!(!p.enabled);
        assert!(!p.has_effect());
        assert!(!p.swaps_axes());
    }

    #[test]
    fn test_enabled_but_unset_is_still_a_no_op() {
        // Turning the pass on without choosing anything must not emit a
        // rotation call — the script should say what actually runs.
        let p = GeometryParameters {
            enabled: true,
            ..Default::default()
        };
        assert!(!p.has_effect());
    }

    #[test]
    fn test_quarter_turns_swap_axes_and_half_turns_do_not() {
        let with = |r: Rotation| GeometryParameters {
            enabled: true,
            rotation: r,
            ..Default::default()
        };
        assert!(with(Rotation::Cw90).swaps_axes());
        assert!(with(Rotation::Ccw90).swaps_axes());
        assert!(!with(Rotation::Rotate180).swaps_axes());
        assert!(!with(Rotation::None).swaps_axes());
    }

    #[test]
    fn test_a_disabled_pass_never_reports_swapped_axes() {
        // The aspect logic keys off this, so a disabled pass claiming a swap
        // would mis-shape the output.
        let p = GeometryParameters {
            enabled: false,
            rotation: Rotation::Cw90,
            ..Default::default()
        };
        assert!(!p.swaps_axes());
    }

    #[test]
    fn test_rotation_functions() {
        assert_eq!(Rotation::None.function(), None);
        assert_eq!(Rotation::Cw90.function(), Some("Turn90"));
        assert_eq!(Rotation::Rotate180.function(), Some("Turn180"));
        assert_eq!(Rotation::Ccw90.function(), Some("Turn270"));
    }

    #[test]
    fn test_sar_inverts_on_a_quarter_turn() {
        // SAR is pixel width : height, so turning the frame on its side swaps
        // them. Declaring the un-inverted ratio would stretch a rotated
        // anamorphic source by the square of its own aspect.
        let turned = GeometryParameters {
            enabled: true,
            rotation: Rotation::Cw90,
            ..Default::default()
        };
        assert_eq!(turned.adjusted_sar(Some("10:11")).as_deref(), Some("11:10"));
        assert_eq!(turned.adjusted_sar(Some("16/11")).as_deref(), Some("11:16"));
        assert_eq!(turned.adjusted_sar(None), None);
    }

    #[test]
    fn test_sar_is_untouched_by_half_turns_flips_and_a_disabled_pass() {
        let cases = [
            GeometryParameters { enabled: true, rotation: Rotation::Rotate180, ..Default::default() },
            GeometryParameters { enabled: true, flip_horizontal: true, ..Default::default() },
            GeometryParameters { enabled: true, flip_vertical: true, ..Default::default() },
            GeometryParameters { enabled: false, rotation: Rotation::Cw90, ..Default::default() },
        ];
        for p in cases {
            assert_eq!(p.adjusted_sar(Some("10:11")).as_deref(), Some("10:11"));
        }
    }

    #[test]
    fn test_an_unparseable_sar_is_passed_through_not_mangled() {
        let turned = GeometryParameters {
            enabled: true,
            rotation: Rotation::Ccw90,
            ..Default::default()
        };
        assert_eq!(turned.adjusted_sar(Some("garbage")).as_deref(), Some("garbage"));
        assert_eq!(turned.adjusted_sar(Some("a:b")).as_deref(), Some("a:b"));
    }

    #[test]
    fn test_serialization() {
        let json = serde_json::to_string(&GeometryParameters::default()).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"rotation\":\"none\""));
        assert!(json.contains("\"flipHorizontal\":false"));
    }
}
