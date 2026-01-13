use serde::{Deserialize, Serialize};

/// Parameters for the debanding pass using f3kdb.
/// Removes banding artifacts (color gradients with visible steps).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DebandParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Banding detection range (8-128, default 15).
    /// Higher values detect wider bands.
    #[serde(default = "default_range")]
    pub range: i32,

    /// Luma debanding strength (0-64, default 32).
    #[serde(default = "default_y")]
    pub y: i32,

    /// Chroma blue debanding strength (0-64, default 32).
    #[serde(default = "default_cb")]
    pub cb: i32,

    /// Chroma red debanding strength (0-64, default 32).
    #[serde(default = "default_cr")]
    pub cr: i32,

    /// Dither grain amount (0-64, default 24).
    /// Adds noise to mask remaining banding.
    #[serde(default = "default_grain_y")]
    pub grain_y: i32,

    /// Chroma dither grain (0-64, default 24).
    #[serde(default = "default_grain_c")]
    pub grain_c: i32,

    /// Use dynamic grain (changes per frame).
    #[serde(default = "default_dynamic_grain")]
    pub dynamic_grain: bool,

    /// Output bit depth (8, 10, 16).
    #[serde(default = "default_output_depth")]
    pub output_depth: i32,
}

fn default_range() -> i32 { 15 }
fn default_y() -> i32 { 32 }
fn default_cb() -> i32 { 32 }
fn default_cr() -> i32 { 32 }
fn default_grain_y() -> i32 { 24 }
fn default_grain_c() -> i32 { 24 }
fn default_dynamic_grain() -> bool { true }
fn default_output_depth() -> i32 { 16 }

impl Default for DebandParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            range: default_range(),
            y: default_y(),
            cb: default_cb(),
            cr: default_cr(),
            grain_y: default_grain_y(),
            grain_c: default_grain_c(),
            dynamic_grain: default_dynamic_grain(),
            output_depth: default_output_depth(),
        }
    }
}
