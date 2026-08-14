use serde::{Deserialize, Serialize};

/// Sharpening method options.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub enum SharpenMethod {
    #[default]
    #[serde(rename = "LSFmod")]
    LSFmod,
    #[serde(rename = "CAS")]
    CAS,
    /// aWarpSharp2: sharpens by warping pixels toward edges rather than raising
    /// local contrast, so it adds no halos at all. A distinctly different look
    /// from the other two — very effective on soft or upscaled material.
    #[serde(rename = "AWarpSharp2")]
    AWarpSharp2,
}

#[allow(dead_code)]
impl SharpenMethod {
    pub fn as_str(&self) -> &'static str {
        match self {
            SharpenMethod::LSFmod => "LSFmod",
            SharpenMethod::CAS => "CAS",
            SharpenMethod::AWarpSharp2 => "AWarpSharp2",
        }
    }
}

/// Parameters for the sharpening pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SharpenParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Sharpening method to use.
    #[serde(default)]
    pub method: SharpenMethod,

    // --- LSFmod parameters ---

    /// Overall sharpening strength (0-200, default 100).
    #[serde(default = "default_strength")]
    pub strength: i32,

    /// Overshoot limiting for bright edges (0-100).
    #[serde(default = "default_overshoot")]
    pub overshoot: i32,

    /// Undershoot limiting for dark edges (0-100).
    #[serde(default = "default_undershoot")]
    pub undershoot: i32,

    /// Edge detection threshold (soft edge handling).
    #[serde(default)]
    pub soft_edge: i32,

    // --- CAS parameters ---

    /// CAS sharpening amount (0.0-1.0).
    #[serde(default = "default_cas_sharpness")]
    pub cas_sharpness: f64,

    // --- aWarpSharp2 parameters ---

    /// How far pixels may be warped (0-255). The main strength control.
    #[serde(default = "default_warp_depth")]
    pub warp_depth: i32,

    /// Edge mask threshold (0-255). Lower finds more edges to warp toward.
    #[serde(default = "default_warp_thresh")]
    pub warp_thresh: i32,

    /// Mask blur passes (0-3). More blur warps more smoothly.
    #[serde(default = "default_warp_blur")]
    pub warp_blur: i32,

    /// Blur kernel: 0 = radius 6 box (per-pass), 1 = radius 2 box.
    #[serde(default)]
    pub warp_type: i32,
}

fn default_strength() -> i32 { 100 }
fn default_overshoot() -> i32 { 1 }
fn default_undershoot() -> i32 { 1 }
fn default_cas_sharpness() -> f64 { 0.5 }
fn default_warp_depth() -> i32 { 16 }
fn default_warp_thresh() -> i32 { 128 }
fn default_warp_blur() -> i32 { 2 }

impl Default for SharpenParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            method: SharpenMethod::default(),
            strength: default_strength(),
            overshoot: default_overshoot(),
            undershoot: default_undershoot(),
            soft_edge: 0,
            cas_sharpness: default_cas_sharpness(),
            warp_depth: default_warp_depth(),
            warp_thresh: default_warp_thresh(),
            warp_blur: default_warp_blur(),
            warp_type: 0,
        }
    }
}

impl SharpenParameters {
    /// Mask blur passes, clamped to the 0-3 the plugin implements.
    pub fn warp_effective_blur(&self) -> i32 {
        self.warp_blur.clamp(0, 3)
    }
}
