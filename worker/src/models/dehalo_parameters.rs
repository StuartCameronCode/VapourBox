use serde::{Deserialize, Serialize};

/// Dehalo method options.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub enum DehaloMethod {
    #[default]
    #[serde(rename = "DeHalo_alpha")]
    DehaloAlpha,
    #[serde(rename = "FineDehalo")]
    FineDehalo,
    #[serde(rename = "YAHR")]
    Yahr,
}

impl DehaloMethod {
    pub fn as_str(&self) -> &'static str {
        match self {
            DehaloMethod::DehaloAlpha => "DeHalo_alpha",
            DehaloMethod::FineDehalo => "FineDehalo",
            DehaloMethod::Yahr => "YAHR",
        }
    }
}

/// Parameters for the dehalo pass.
/// Removes halo artifacts around edges.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DehaloParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Dehalo method to use.
    #[serde(default)]
    pub method: DehaloMethod,

    // --- DeHalo_alpha / FineDehalo parameters ---

    /// Horizontal radius for halo detection (1.0-3.0).
    #[serde(default = "default_rx")]
    pub rx: f64,

    /// Vertical radius for halo detection (1.0-3.0).
    #[serde(default = "default_ry")]
    pub ry: f64,

    /// Dark halo removal strength (0.0-1.0).
    #[serde(default = "default_dark_str")]
    pub dark_str: f64,

    /// Bright halo removal strength (0.0-1.0).
    #[serde(default = "default_bright_str")]
    pub bright_str: f64,

    // --- FineDehalo specific ---

    /// Low threshold for halo mask.
    #[serde(default = "default_low_threshold")]
    pub low_threshold: i32,

    /// High threshold for halo mask.
    #[serde(default = "default_high_threshold")]
    pub high_threshold: i32,

    // --- YAHR specific ---

    /// Blur amount for YAHR (1-3).
    #[serde(default = "default_yahr_blur")]
    pub yahr_blur: i32,

    /// Processing depth for YAHR.
    #[serde(default = "default_yahr_depth")]
    pub yahr_depth: i32,
}

fn default_rx() -> f64 { 2.0 }
fn default_ry() -> f64 { 2.0 }
fn default_dark_str() -> f64 { 1.0 }
fn default_bright_str() -> f64 { 1.0 }
fn default_low_threshold() -> i32 { 50 }
fn default_high_threshold() -> i32 { 100 }
fn default_yahr_blur() -> i32 { 2 }
fn default_yahr_depth() -> i32 { 32 }

impl Default for DehaloParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            method: DehaloMethod::default(),
            rx: default_rx(),
            ry: default_ry(),
            dark_str: default_dark_str(),
            bright_str: default_bright_str(),
            low_threshold: default_low_threshold(),
            high_threshold: default_high_threshold(),
            yahr_blur: default_yahr_blur(),
            yahr_depth: default_yahr_depth(),
        }
    }
}
