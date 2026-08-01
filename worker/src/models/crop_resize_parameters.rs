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

#[allow(dead_code)]
impl CropResizeParameters {
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
    fn test_serialization() {
        let params = CropResizeParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"maintainAspect\":true"));
    }
}
