//! Crop and resize parameters for video restoration.

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
    Nnedi3,
    Eedi3,
}

impl ResizeKernel {
    /// Get the VapourSynth resize function name.
    pub fn vs_function(&self) -> &'static str {
        match self {
            ResizeKernel::Spline36 => "core.resize.Spline36",
            ResizeKernel::Lanczos => "core.resize.Lanczos",
            ResizeKernel::Bicubic => "core.resize.Bicubic",
            ResizeKernel::Bilinear => "core.resize.Bilinear",
            ResizeKernel::Nnedi3 => "nnedi3_rpow2",
            ResizeKernel::Eedi3 => "eedi3_rpow2",
        }
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
            maintain_aspect: true,
            use_integer_upscale: false,
            upscale_method: UpscaleMethod::default(),
            upscale_factor: default_upscale_factor(),
        }
    }
}

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
