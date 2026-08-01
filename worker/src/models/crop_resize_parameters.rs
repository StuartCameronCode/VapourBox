//! Crop and resize parameters for video processing.

use serde::{Deserialize, Serialize};

/// Resize kernel/algorithm options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ResizeKernel {
    #[default]
    Spline36,
    Lanczos,
    Bicubic,
    Bilinear,
    Point,
    Spline16,
    Spline64,
    Nnedi3,
    Eedi3,
}

#[allow(dead_code)]
impl ResizeKernel {
    /// The `core.resize` function that implements this kernel.
    ///
    /// Nnedi3/Eedi3 are edge-directed *upscalers*, not resampling kernels —
    /// they belong to the integer-upscale path. Selected here they fall back to
    /// Spline36, which is what an arbitrary resize needs.
    pub fn resize_function(&self) -> &'static str {
        match self {
            ResizeKernel::Spline36 | ResizeKernel::Nnedi3 | ResizeKernel::Eedi3 => "Spline36",
            ResizeKernel::Lanczos => "Lanczos",
            ResizeKernel::Bicubic => "Bicubic",
            ResizeKernel::Bilinear => "Bilinear",
            ResizeKernel::Point => "Point",
            ResizeKernel::Spline16 => "Spline16",
            ResizeKernel::Spline64 => "Spline64",
        }
    }

    /// Get the VapourSynth resize function name.
    pub fn vs_function(&self) -> String {
        match self {
            ResizeKernel::Nnedi3 => "nnedi3_rpow2".to_string(),
            ResizeKernel::Eedi3 => "eedi3_rpow2".to_string(),
            other => format!("core.resize.{}", other.resize_function()),
        }
    }

    /// Whether this kernel reads `filter_param_a` as a b-spline `b` and
    /// `filter_param_b` as `c` (Bicubic) — as opposed to Lanczos, where
    /// `filter_param_a` is the tap count, or the rest, which read neither.
    pub fn takes_bicubic_params(&self) -> bool {
        matches!(self, ResizeKernel::Bicubic)
    }

    /// Whether this kernel reads `filter_param_a` as a tap count.
    pub fn takes_taps(&self) -> bool {
        matches!(self, ResizeKernel::Lanczos)
    }
}

/// Upscale method options (for integer scaling).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum UpscaleMethod {
    #[default]
    Nnedi3Rpow2,
    Eedi3Rpow2,
    Spline36,
}

/// What to do with the pixel aspect ratio (SAR) on output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum PixelAspectMode {
    /// Leave the pixel grid alone and carry the source's SAR through to the
    /// output metadata. Non-square pixels stay non-square.
    #[default]
    Preserve,
    /// Resample so the output has square pixels at the same display shape —
    /// what an anamorphic DVD needs before it looks right in most players and
    /// editors.
    Square,
    /// Stamp an explicit SAR, for a source whose flag is simply wrong.
    Custom,
}

/// Crop/resize preset options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum CropResizePreset {
    #[default]
    Off,
    RemoveOverscan,
    Resize720p,
    Resize1080p,
    Resize4k,
    Custom,
}

/// Parameters for the crop and resize pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CropResizeParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Preset for simple mode.
    #[serde(default)]
    pub preset: CropResizePreset,

    // --- Crop Parameters (applied before resize) ---

    /// Whether to apply crop.
    #[serde(default)]
    pub crop_enabled: bool,

    /// Pixels to crop from left edge.
    #[serde(default)]
    pub crop_left: i32,

    /// Pixels to crop from right edge.
    #[serde(default)]
    pub crop_right: i32,

    /// Pixels to crop from top edge.
    #[serde(default)]
    pub crop_top: i32,

    /// Pixels to crop from bottom edge.
    #[serde(default)]
    pub crop_bottom: i32,

    // --- Resize Parameters ---

    /// Whether to apply resize.
    #[serde(default)]
    pub resize_enabled: bool,

    /// Target width (null = auto based on height and aspect).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_width: Option<i32>,

    /// Target height (null = auto based on width and aspect).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_height: Option<i32>,

    /// Resize algorithm to use.
    #[serde(default)]
    pub kernel: ResizeKernel,

    /// Bicubic `b` (blurring), passed as `filter_param_a`.
    #[serde(default)]
    pub bicubic_b: Option<f64>,

    /// Bicubic `c` (ringing), passed as `filter_param_b`.
    #[serde(default)]
    pub bicubic_c: Option<f64>,

    /// Lanczos tap count, passed as `filter_param_a`.
    #[serde(default)]
    pub lanczos_taps: Option<i32>,

    /// Maintain aspect ratio when resizing.
    #[serde(default = "default_true")]
    pub maintain_aspect: bool,

    // --- Aspect ratio ---

    /// What to do with the pixel aspect ratio on output.
    #[serde(default)]
    pub pixel_aspect: PixelAspectMode,

    /// SAR to stamp when `pixel_aspect` is `Custom`, as "N:M" or a decimal.
    #[serde(default)]
    pub custom_sar: Option<String>,

    /// Force a display aspect ratio ("16:9", "4:3", "1.85"), overriding the one
    /// implied by the source's dimensions and SAR. `None` uses the source's.
    #[serde(default)]
    pub display_aspect: Option<String>,

    /// Pad (letterbox/pillarbox) to fill the target box instead of leaving the
    /// fitted image smaller than it in one axis.
    #[serde(default)]
    pub pad_to_aspect: bool,

    // --- Upscale Parameters (for integer scaling) ---

    /// Whether to use integer upscaling (2x, 4x) instead of arbitrary resize.
    #[serde(default)]
    pub use_integer_upscale: bool,

    /// Upscale method for integer scaling.
    #[serde(default)]
    pub upscale_method: UpscaleMethod,

    /// Upscale factor (2 = 2x, 4 = 4x).
    #[serde(default = "default_upscale_factor")]
    pub upscale_factor: i32,

    // --- nnedi3 controls for the edge-directed upscale paths ---
    // With EEDI3 selected these shape the nnedi3 sclip that guides it.

    /// Neighbourhood size / shape (nnedi3 `nsize`, 0-6).
    #[serde(default)]
    pub upscale_nsize: Option<i32>,

    /// Neuron count (nnedi3 `nns`: 0=16, 1=32, 2=64, 3=128, 4=256).
    #[serde(default)]
    pub upscale_neurons: Option<i32>,

    /// Prediction quality (nnedi3 `qual`, 1-2).
    #[serde(default)]
    pub upscale_qual: Option<i32>,

    /// Error metric used to pick the predictor (nnedi3 `etype`, 0-1).
    #[serde(default)]
    pub upscale_etype: Option<i32>,

    /// Prescreener (nnedi3 `pscrn`, 0-4; 0 processes every pixel).
    #[serde(default)]
    pub upscale_pscrn: Option<i32>,

    // --- EEDI3 controls ---

    /// Edge-direction connection cost (EEDI3 `alpha`).
    #[serde(default)]
    pub upscale_alpha: Option<f64>,

    /// Edge-direction smoothness cost (EEDI3 `beta`).
    #[serde(default)]
    pub upscale_beta: Option<f64>,

    /// Penalty for directions away from vertical (EEDI3 `gamma`).
    #[serde(default)]
    pub upscale_gamma: Option<f64>,

    /// Neighbourhood radius for the cost function (EEDI3 `nrad`).
    #[serde(default)]
    pub upscale_nrad: Option<i32>,

    /// Maximum search distance (EEDI3 `mdis`).
    #[serde(default)]
    pub upscale_mdis: Option<i32>,
}

fn default_true() -> bool { true }
fn default_upscale_factor() -> i32 { 2 }

impl Default for CropResizeParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            preset: CropResizePreset::default(),
            crop_enabled: false,
            crop_left: 0,
            crop_right: 0,
            crop_top: 0,
            crop_bottom: 0,
            resize_enabled: false,
            target_width: None,
            target_height: None,
            kernel: ResizeKernel::default(),
            pixel_aspect: PixelAspectMode::default(),
            custom_sar: None,
            display_aspect: None,
            pad_to_aspect: false,
            bicubic_b: None,
            bicubic_c: None,
            lanczos_taps: None,
            maintain_aspect: true,
            use_integer_upscale: false,
            upscale_method: UpscaleMethod::default(),
            upscale_factor: default_upscale_factor(),
            upscale_nsize: None,
            upscale_neurons: None,
            upscale_qual: None,
            upscale_etype: None,
            upscale_pscrn: None,
            upscale_alpha: None,
            upscale_beta: None,
            upscale_gamma: None,
            upscale_nrad: None,
            upscale_mdis: None,
        }
    }
}

/// Parse an aspect ratio written as "16:9", "16/9" or "1.7778".
///
/// Returns `None` for anything unparseable or non-positive, so a typo falls back
/// to the source's own aspect instead of producing a zero-width frame.
pub fn parse_ratio(text: &str) -> Option<f64> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }

    let ratio = match text.split_once([':', '/']) {
        Some((num, den)) => {
            let num: f64 = num.trim().parse().ok()?;
            let den: f64 = den.trim().parse().ok()?;
            if den == 0.0 {
                return None;
            }
            num / den
        }
        None => text.parse().ok()?,
    };

    (ratio.is_finite() && ratio > 0.0).then_some(ratio)
}

/// How the output's aspect should be declared to the encoder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AspectDeclaration {
    /// Stamp this sample aspect ratio ("10:11", "1").
    Sar(String),
    /// Stamp this display aspect ratio and let ffmpeg derive the SAR from the
    /// actual output dimensions — which only ffmpeg knows, since the frame size
    /// is computed inside the VapourSynth script.
    Dar(String),
    /// Say nothing; the output keeps square pixels.
    None,
}

#[allow(dead_code)]
impl CropResizeParameters {
    /// Whether the pixel grid itself has to be resampled to square up the
    /// pixels. True even with no target size — "make this anamorphic source
    /// square" is a resize in its own right.
    pub fn squares_pixels(&self) -> bool {
        self.enabled && self.pixel_aspect == PixelAspectMode::Square
    }

    /// The display aspect override, if it parses.
    pub fn display_aspect_ratio(&self) -> Option<f64> {
        self.display_aspect.as_deref().and_then(parse_ratio)
    }

    /// How to declare the output aspect, given the source's SAR.
    ///
    /// `input_sar` is the source's sample aspect ratio as ffprobe reports it
    /// ("10:11"), or `None` for square pixels.
    pub fn aspect_declaration(&self, input_sar: Option<&str>) -> AspectDeclaration {
        if !self.enabled {
            // The pass is off: carry the source's SAR through unchanged. The Y4M
            // pipe strips it, so it has to be re-applied either way.
            return input_sar.map_or(AspectDeclaration::None, |sar| {
                AspectDeclaration::Sar(sar.to_string())
            });
        }

        match self.pixel_aspect {
            // Squaring resamples the grid to the display shape, so the result is
            // square-pixel by construction.
            PixelAspectMode::Square => AspectDeclaration::None,

            PixelAspectMode::Custom => self
                .custom_sar
                .as_deref()
                .map(str::trim)
                .filter(|s| parse_ratio(s).is_some())
                .map_or(AspectDeclaration::None, |sar| {
                    AspectDeclaration::Sar(sar.to_string())
                }),

            PixelAspectMode::Preserve => {
                // A forced display aspect is declared as a DAR: the SAR that
                // produces it depends on the output dimensions, which are
                // computed in the script.
                if let Some(dar) = self.display_aspect.as_deref() {
                    if parse_ratio(dar).is_some() {
                        return AspectDeclaration::Dar(dar.trim().replace(':', "/"));
                    }
                }
                input_sar.map_or(AspectDeclaration::None, |sar| {
                    AspectDeclaration::Sar(sar.to_string())
                })
            }
        }
    }

    /// Get total horizontal crop.
    pub fn total_horizontal_crop(&self) -> i32 {
        self.crop_left + self.crop_right
    }

    /// Get total vertical crop.
    pub fn total_vertical_crop(&self) -> i32 {
        self.crop_top + self.crop_bottom
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_parameters() {
        let params = CropResizeParameters::default();
        assert!(!params.enabled);
        assert_eq!(params.preset, CropResizePreset::Off);
        assert!(!params.crop_enabled);
        assert!(!params.resize_enabled);
        assert_eq!(params.upscale_factor, 2);
    }

    #[test]
    fn test_parse_ratio_accepts_the_forms_people_write() {
        assert_eq!(parse_ratio("16:9"), Some(16.0 / 9.0));
        assert_eq!(parse_ratio("16/9"), Some(16.0 / 9.0));
        assert_eq!(parse_ratio(" 4 : 3 "), Some(4.0 / 3.0));
        assert_eq!(parse_ratio("1.85"), Some(1.85));
        // Unparseable or degenerate input must not reach the script.
        assert_eq!(parse_ratio(""), None);
        assert_eq!(parse_ratio("16:0"), None);
        assert_eq!(parse_ratio("widescreen"), None);
        assert_eq!(parse_ratio("-4:3"), None);
        assert_eq!(parse_ratio("0"), None);
    }

    #[test]
    fn test_disabled_pass_still_carries_the_source_sar() {
        // The Y4M pipe strips SAR, so it has to be re-applied even when this
        // pass does nothing at all.
        let params = CropResizeParameters::default();
        assert_eq!(
            params.aspect_declaration(Some("10:11")),
            AspectDeclaration::Sar("10:11".to_string())
        );
        assert_eq!(params.aspect_declaration(None), AspectDeclaration::None);
    }

    #[test]
    fn test_preserve_keeps_the_source_sar_even_when_resizing() {
        // The bug this fixes: SAR used to be dropped whenever a resize ran, so
        // an anamorphic source came out geometrically wrong.
        let params = CropResizeParameters {
            enabled: true,
            resize_enabled: true,
            target_width: Some(1920),
            ..CropResizeParameters::default()
        };
        assert_eq!(
            params.aspect_declaration(Some("16:11")),
            AspectDeclaration::Sar("16:11".to_string())
        );
    }

    #[test]
    fn test_square_declares_nothing_because_the_grid_is_resampled() {
        let params = CropResizeParameters {
            enabled: true,
            pixel_aspect: PixelAspectMode::Square,
            ..CropResizeParameters::default()
        };
        assert!(params.squares_pixels());
        assert_eq!(params.aspect_declaration(Some("16:11")), AspectDeclaration::None);
    }

    #[test]
    fn test_forced_display_aspect_becomes_a_dar_declaration() {
        // Output dimensions are computed inside the script, so the SAR that
        // yields a given DAR is not knowable here — ffmpeg derives it.
        let params = CropResizeParameters {
            enabled: true,
            display_aspect: Some("16:9".to_string()),
            ..CropResizeParameters::default()
        };
        assert_eq!(
            params.aspect_declaration(Some("10:11")),
            AspectDeclaration::Dar("16/9".to_string())
        );
        assert_eq!(params.display_aspect_ratio(), Some(16.0 / 9.0));

        // A typo falls back to the source's SAR rather than a broken filter arg.
        let params = CropResizeParameters {
            enabled: true,
            display_aspect: Some("wide".to_string()),
            ..CropResizeParameters::default()
        };
        assert_eq!(
            params.aspect_declaration(Some("10:11")),
            AspectDeclaration::Sar("10:11".to_string())
        );
        assert_eq!(params.display_aspect_ratio(), None);
    }

    #[test]
    fn test_custom_sar_is_validated() {
        let params = CropResizeParameters {
            enabled: true,
            pixel_aspect: PixelAspectMode::Custom,
            custom_sar: Some("64:45".to_string()),
            ..CropResizeParameters::default()
        };
        assert_eq!(
            params.aspect_declaration(Some("10:11")),
            AspectDeclaration::Sar("64:45".to_string())
        );

        // Nonsense is dropped rather than passed to ffmpeg.
        let params = CropResizeParameters {
            enabled: true,
            pixel_aspect: PixelAspectMode::Custom,
            custom_sar: Some("??".to_string()),
            ..CropResizeParameters::default()
        };
        assert_eq!(params.aspect_declaration(Some("10:11")), AspectDeclaration::None);
    }

    #[test]
    fn test_serialization() {
        let params = CropResizeParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"maintainAspect\":true"));
    }
}
