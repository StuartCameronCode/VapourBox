use serde::{Deserialize, Serialize};

/// Sharpening method options.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub enum SharpenMethod {
    #[default]
    #[serde(rename = "LSFmod")]
    LSFmod,
    #[serde(rename = "CAS")]
    CAS,
}

impl SharpenMethod {
    pub fn as_str(&self) -> &'static str {
        match self {
            SharpenMethod::LSFmod => "LSFmod",
            SharpenMethod::CAS => "CAS",
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
}

fn default_strength() -> i32 { 100 }
fn default_overshoot() -> i32 { 1 }
fn default_undershoot() -> i32 { 1 }
fn default_cas_sharpness() -> f64 { 0.5 }

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
        }
    }
}
