//! Color correction parameters for video processing.

use serde::{Deserialize, Serialize};

/// Color correction preset options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ColorCorrectionPreset {
    #[default]
    Off,
    BroadcastSafe,
    EnhanceColors,
    Desaturate,
    Custom,
}

/// Parameters for the color correction pass.
/// Uses adjust.Tweak and SmoothLevels from havsfunc.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColorCorrectionParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Stretch luma to the target black/white points, measured per frame.
    #[serde(default)]
    pub apply_auto_levels: bool,
    /// Target black point, 8-bit UI units; scaled to the clip format in-script.
    #[serde(default = "default_auto_black")]
    pub auto_levels_black: i32,
    /// Target white point, 8-bit UI units.
    #[serde(default = "default_auto_white_point")]
    pub auto_levels_white: i32,
    /// 0-1 blend against the untouched clip.
    #[serde(default = "default_auto_strength")]
    pub auto_levels_strength: f64,

    /// Grey-world automatic white balance.
    #[serde(default)]
    pub apply_auto_white_balance: bool,
    /// 0-1 blend for the chroma shift.
    #[serde(default = "default_auto_strength")]
    pub auto_white_balance_strength: f64,

    /// Preset level for simple mode.
    #[serde(default)]
    pub preset: ColorCorrectionPreset,

    // --- Tweak Parameters (from adjust.py) ---

    /// Brightness adjustment (-255 to 255).
    #[serde(default)]
    pub brightness: f64,

    /// Contrast adjustment (0.0 to 10.0, 1.0 = no change).
    #[serde(default = "default_one_f64")]
    pub contrast: f64,

    /// Hue rotation in degrees (-180 to 180).
    #[serde(default)]
    pub hue: f64,

    /// Saturation adjustment (0.0 to 10.0, 1.0 = no change).
    #[serde(default = "default_one_f64")]
    pub saturation: f64,

    /// Coring - clamp output to TV range (16-235).
    #[serde(default)]
    pub coring: bool,

    // --- SmoothLevels Parameters ---

    /// Whether to apply levels adjustment.
    #[serde(default)]
    pub apply_levels: bool,

    /// Use havsfunc's SmoothLevels instead of plain `std.Levels`.
    ///
    /// Same curve, but dithered and limited as it goes, so stretching a narrow
    /// range does not band. Measured on a shallow gradient stretched to full
    /// range: distinct output levels go from 47 to 135.
    #[serde(default)]
    pub smooth_levels: bool,

    // --- Retinex (shadow detail) ---

    /// Lift shadow detail with multi-scale retinex.
    ///
    /// Run on luma only. `retinex.MSRCP` rejects subsampled formats outright
    /// ("sub-sampled format is not supported"), and every source this app
    /// handles is 4:2:0 or 4:2:2 — so rather than round-trip the whole clip
    /// through 4:4:4 and resample chroma twice, the luma plane is extracted as
    /// greyscale, processed, and put back. Colour is left bit-identical.
    #[serde(default)]
    pub apply_shadow_detail: bool,

    /// Retinex scale, in pixels. Larger looks at a wider neighbourhood, so it
    /// lifts broad shadow areas rather than local texture.
    #[serde(default = "default_shadow_sigma")]
    pub shadow_sigma: f64,

    /// Fraction of the darkest pixels ignored when rescaling, which stops a few
    /// black pixels dragging the whole result.
    #[serde(default = "default_shadow_lower")]
    pub shadow_lower_thr: f64,

    /// Same at the bright end.
    #[serde(default = "default_shadow_upper")]
    pub shadow_upper_thr: f64,

    /// Input black level (0-255).
    #[serde(default)]
    pub input_low: i32,

    /// Input white level (0-255).
    #[serde(default = "default_255")]
    pub input_high: i32,

    /// Output black level (0-255).
    #[serde(default)]
    pub output_low: i32,

    /// Output white level (0-255).
    #[serde(default = "default_255")]
    pub output_high: i32,

    /// Gamma adjustment (0.1 to 10.0, 1.0 = no change).
    #[serde(default = "default_one_f64")]
    pub gamma: f64,

    // --- White balance ---

    /// Colour temperature, -100 (cool/blue) to +100 (warm/amber). 0 = no change.
    #[serde(default)]
    pub temperature: f64,

    /// Tint, -100 (green) to +100 (magenta). 0 = no change.
    #[serde(default)]
    pub tint: f64,
}

/// The four input/output points of a levels adjustment, in 8-bit UI units.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LevelsPoints {
    pub input_low: i32,
    pub input_high: i32,
    pub output_low: i32,
    pub output_high: i32,
}

/// Chroma levels shifted per unit of temperature/tint, at 8-bit scale.
///
/// A full-scale slider therefore moves chroma by 25 levels — a strong but still
/// corrective shift, rather than a stylistic one.
pub const WHITE_BALANCE_UNIT: f64 = 0.25;

impl ColorCorrectionParameters {
    /// The chroma plane offsets (U, V) for the current temperature and tint, in
    /// 8-bit levels. The template scales them to the working bit depth.
    ///
    /// U carries blue-yellow and V carries red-cyan, so warming the image (more
    /// red, less blue) means -U and +V, while magenta tint raises both.
    pub fn chroma_offsets(&self) -> (f64, f64) {
        let temp = self.temperature * WHITE_BALANCE_UNIT;
        let tint = self.tint * WHITE_BALANCE_UNIT;
        (tint - temp, tint + temp)
    }

    /// Whether white balance would change anything.
    pub fn has_white_balance(&self) -> bool {
        self.temperature.abs() > 0.001 || self.tint.abs() > 0.001
    }
}

fn default_shadow_sigma() -> f64 { 100.0 }
fn default_shadow_lower() -> f64 { 0.001 }
fn default_shadow_upper() -> f64 { 0.001 }
fn default_one_f64() -> f64 { 1.0 }
fn default_255() -> i32 { 255 }

fn default_auto_black() -> i32 { 16 }
fn default_auto_white_point() -> i32 { 235 }
fn default_auto_strength() -> f64 { 1.0 }

impl Default for ColorCorrectionParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            apply_auto_levels: false,
            auto_levels_black: default_auto_black(),
            auto_levels_white: default_auto_white_point(),
            auto_levels_strength: default_auto_strength(),
            apply_auto_white_balance: false,
            auto_white_balance_strength: default_auto_strength(),
            preset: ColorCorrectionPreset::default(),
            brightness: 0.0,
            contrast: 1.0,
            hue: 0.0,
            saturation: 1.0,
            coring: false,
            apply_levels: false,
            smooth_levels: false,
            apply_shadow_detail: false,
            shadow_sigma: default_shadow_sigma(),
            shadow_lower_thr: default_shadow_lower(),
            shadow_upper_thr: default_shadow_upper(),
            input_low: 0,
            input_high: 255,
            output_low: 0,
            output_high: 255,
            gamma: 1.0,
            temperature: 0.0,
            tint: 0.0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_parameters() {
        let params = ColorCorrectionParameters::default();
        assert!(!params.enabled);
        assert_eq!(params.preset, ColorCorrectionPreset::Off);
        assert_eq!(params.contrast, 1.0);
        assert_eq!(params.saturation, 1.0);
    }

    #[test]
    fn test_white_balance_is_off_by_default() {
        let params = ColorCorrectionParameters::default();
        assert!(!params.has_white_balance());
        assert_eq!(params.chroma_offsets(), (0.0, 0.0));
    }

    #[test]
    fn test_chroma_offsets_directions() {
        // Warm: less blue (U down), more red (V up).
        let warm = ColorCorrectionParameters { temperature: 100.0, ..Default::default() };
        let (u, v) = warm.chroma_offsets();
        assert_eq!((u, v), (-25.0, 25.0));

        // Cool is the mirror image.
        let cool = ColorCorrectionParameters { temperature: -100.0, ..Default::default() };
        assert_eq!(cool.chroma_offsets(), (25.0, -25.0));

        // Magenta tint raises both planes; green lowers both.
        let magenta = ColorCorrectionParameters { tint: 100.0, ..Default::default() };
        assert_eq!(magenta.chroma_offsets(), (25.0, 25.0));
        let green = ColorCorrectionParameters { tint: -40.0, ..Default::default() };
        assert_eq!(green.chroma_offsets(), (-10.0, -10.0));

        // Temperature and tint compose: warm + magenta cancels on U, adds on V.
        let both = ColorCorrectionParameters { temperature: 40.0, tint: 40.0, ..Default::default() };
        assert_eq!(both.chroma_offsets(), (0.0, 20.0));
    }

    #[test]
    fn test_serialization() {
        let params = ColorCorrectionParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"contrast\":1.0"));
    }
}

impl ColorCorrectionParameters {
    /// The input/output points the levels block actually applies.
    ///
    /// Automatic levels measures the picture and places black and white itself,
    /// and it runs **before** this block — so a manual mapping on top is applied
    /// to an already-graded picture, where the numbers no longer mean what their
    /// labels say ("input black = 16" was measured against the original). The
    /// panel hides those four sliders while automatic levels is on
    /// (`visibleWhen: {"applyAutoLevels": false}` in color_correction.json) and
    /// this is what keeps the script agreeing with it.
    ///
    /// Gamma is deliberately **not** dropped: automatic levels does not touch
    /// the midtones, so it is the one levels control that still means something
    /// afterwards — and the only place in the app to reach it.
    pub fn effective_levels_points(&self) -> LevelsPoints {
        if self.apply_auto_levels {
            LevelsPoints { input_low: 0, input_high: 255, output_low: 0, output_high: 255 }
        } else {
            LevelsPoints {
                input_low: self.input_low,
                input_high: self.input_high,
                output_low: self.output_low,
                output_high: self.output_high,
            }
        }
    }

    /// Whether the manual levels block runs at all.
    ///
    /// `apply_levels` is the switch in the panel, and it used to be **ignored
    /// here**: the block was emitted whenever any level differed from its
    /// default, so unticking the switch left the adjustment running with no
    /// control on screen that could turn it off. The switch decides now, and it
    /// still needs something to do — an identity mapping is emitted as nothing
    /// rather than as a no-op filter.
    pub fn effective_apply_levels(&self) -> bool {
        if !self.apply_levels {
            return false;
        }
        let p = self.effective_levels_points();
        p.input_low != 0
            || p.input_high != 255
            || p.output_low != 0
            || p.output_high != 255
            || (self.gamma - 1.0).abs() > 0.001
    }

    /// The black point actually passed to SmoothLevels.
    ///
    /// havsfunc builds its lookup table over the whole `0..peak` domain and
    /// raises `x - input_low` to `1/gamma`. For `x < input_low` that base is
    /// negative, and a fractional exponent on a negative base yields a Python
    /// `complex` — which fails the LUT with `TypeError: must be real number, not
    /// complex`. Measured: it crashes whenever `input_low > 0` and `1/gamma` is
    /// not an integer, i.e. for essentially every useful gamma.
    ///
    /// Rather than refuse the combination, the black point is dropped for that
    /// case. Losing the lift is visible; a failed job is worse, and the plain
    /// Levels mode still does both together.
    pub fn smooth_levels_input_low(&self) -> i32 {
        if (self.gamma - 1.0).abs() > f64::EPSILON {
            0
        } else {
            self.effective_levels_points().input_low
        }
    }

    /// Whether the gamma guard above actually dropped anything, so the UI can
    /// say so rather than silently ignoring a control the user set.
    pub fn smooth_levels_drops_black_point(&self) -> bool {
        self.smooth_levels
            && self.apply_levels
            && self.effective_levels_points().input_low > 0
            && (self.gamma - 1.0).abs() > f64::EPSILON
    }
}

#[cfg(test)]
mod smooth_levels_tests {
    use super::*;

    #[test]
    fn test_black_point_survives_when_gamma_is_neutral() {
        let p = ColorCorrectionParameters {
            input_low: 16,
            gamma: 1.0,
            ..Default::default()
        };
        assert_eq!(p.smooth_levels_input_low(), 16);
        assert!(!p.smooth_levels_drops_black_point());
    }

    #[test]
    fn test_black_point_is_dropped_when_gamma_would_crash_the_lut() {
        // havsfunc raises a negative base to a fractional power for x below
        // input_low, which yields a complex number and fails the LUT.
        for gamma in [0.6, 0.8, 1.2, 2.2] {
            let p = ColorCorrectionParameters {
                apply_levels: true,
                smooth_levels: true,
                input_low: 16,
                gamma,
                ..Default::default()
            };
            assert_eq!(p.smooth_levels_input_low(), 0, "gamma {gamma}");
            assert!(p.smooth_levels_drops_black_point(), "gamma {gamma}");
        }
    }

    #[test]
    fn test_nothing_is_dropped_when_the_black_point_is_already_zero() {
        let p = ColorCorrectionParameters {
            apply_levels: true,
            smooth_levels: true,
            input_low: 0,
            gamma: 0.6,
            ..Default::default()
        };
        assert_eq!(p.smooth_levels_input_low(), 0);
        assert!(!p.smooth_levels_drops_black_point());
    }

    #[test]
    fn test_plain_levels_mode_never_reports_a_dropped_black_point() {
        let p = ColorCorrectionParameters {
            apply_levels: true,
            smooth_levels: false,
            apply_shadow_detail: false,
            shadow_sigma: default_shadow_sigma(),
            shadow_lower_thr: default_shadow_lower(),
            shadow_upper_thr: default_shadow_upper(),
            input_low: 16,
            gamma: 0.6,
            ..Default::default()
        };
        assert!(!p.smooth_levels_drops_black_point());
    }
}

impl ColorCorrectionParameters {
    /// Retinex scale, clamped to something meaningful for SD and HD frames.
    pub fn shadow_effective_sigma(&self) -> f64 {
        self.shadow_sigma.clamp(1.0, 500.0)
    }

    /// The clipping thresholds, kept inside the 0-1 fraction the plugin wants
    /// and away from the degenerate ends.
    pub fn shadow_effective_lower(&self) -> f64 {
        self.shadow_lower_thr.clamp(0.0, 0.1)
    }

    /// See [`Self::shadow_effective_lower`].
    pub fn shadow_effective_upper(&self) -> f64 {
        self.shadow_upper_thr.clamp(0.0, 0.1)
    }
}

#[cfg(test)]
mod shadow_detail_tests {
    use super::*;

    #[test]
    fn test_defaults_are_off_and_conservative() {
        let p = ColorCorrectionParameters::default();
        assert!(!p.apply_shadow_detail);
        assert_eq!(p.shadow_sigma, 100.0);
    }

    #[test]
    fn test_sigma_and_thresholds_are_clamped() {
        let p = ColorCorrectionParameters {
            shadow_sigma: 9000.0,
            shadow_lower_thr: 0.9,
            shadow_upper_thr: -1.0,
            ..Default::default()
        };
        assert_eq!(p.shadow_effective_sigma(), 500.0);
        assert_eq!(p.shadow_effective_lower(), 0.1);
        assert_eq!(p.shadow_effective_upper(), 0.0);
    }
}
