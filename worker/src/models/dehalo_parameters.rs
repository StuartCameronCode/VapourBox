use serde::{Deserialize, Serialize};

/// Dehalo method options.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub enum DehaloMethod {
    #[default]
    #[serde(rename = "DeHalo_alpha")]
    DehaloAlpha,
    #[serde(rename = "FineDehalo")]
    FineDehalo,
    /// Second-stage dehalo for the ringing FineDehalo leaves on sharp edges.
    #[serde(rename = "FineDehalo2")]
    FineDehalo2,
    #[serde(rename = "YAHR")]
    Yahr,
    /// Edge denoising / weak dehaloing via aWarpSharp2.
    #[serde(rename = "EdgeCleaner")]
    EdgeCleaner,
    /// Vertical comb/ghost residue removal (the classic post-deinterlace fix).
    #[serde(rename = "Vinverse")]
    Vinverse,
    /// Vinverse variant that preserves more vertical detail.
    #[serde(rename = "Vinverse2")]
    Vinverse2,
}

#[allow(dead_code)]
impl DehaloMethod {
    pub fn as_str(&self) -> &'static str {
        match self {
            DehaloMethod::DehaloAlpha => "DeHalo_alpha",
            DehaloMethod::FineDehalo => "FineDehalo",
            DehaloMethod::FineDehalo2 => "FineDehalo2",
            DehaloMethod::Yahr => "YAHR",
            DehaloMethod::EdgeCleaner => "EdgeCleaner",
            DehaloMethod::Vinverse => "Vinverse",
            DehaloMethod::Vinverse2 => "Vinverse2",
        }
    }

    /// Whether this method takes the shared DeHalo_alpha/FineDehalo radius and
    /// strength arguments.
    pub fn uses_halo_radius(&self) -> bool {
        matches!(self, DehaloMethod::DehaloAlpha | DehaloMethod::FineDehalo)
    }

    /// Whether this method is one of the two Vinverse variants.
    pub fn is_vinverse(&self) -> bool {
        matches!(self, DehaloMethod::Vinverse | DehaloMethod::Vinverse2)
    }
}

/// Parameters for the dehalo pass.
/// Removes halo artifacts around edges, plus ringing and comb/ghost residue.
///
/// Fields typed `Option<T>` are omitted from the generated script when unset,
/// so havsfunc's own default applies. The non-optional ones predate that and
/// are always passed — changing them to Option would change existing output.
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

    /// Dark halo removal strength (0.0-2.0; above 1.0 overshoots).
    #[serde(default = "default_dark_str")]
    pub dark_str: f64,

    /// Bright halo removal strength (0.0-2.0; above 1.0 overshoots).
    #[serde(default = "default_bright_str")]
    pub bright_str: f64,

    // --- DeHalo_alpha specific ---

    /// Sensitivity to strong halos (havsfunc `lowsens`, 0-100).
    #[serde(default)]
    pub low_sens: Option<i32>,

    /// Sensitivity to weak halos (havsfunc `highsens`, 0-100).
    #[serde(default)]
    pub high_sens: Option<i32>,

    /// Supersampling factor used while removing halos (havsfunc `ss`).
    #[serde(default)]
    pub super_sample: Option<f64>,

    // --- FineDehalo specific ---

    /// Low threshold for halo mask.
    #[serde(default = "default_low_threshold")]
    pub low_threshold: i32,

    /// High threshold for halo mask.
    #[serde(default = "default_high_threshold")]
    pub high_threshold: i32,

    /// Lower limit on how much of a halo may be removed (havsfunc `thlimi`).
    #[serde(default)]
    pub limit_low: Option<i32>,

    /// Upper limit on how much of a halo may be removed (havsfunc `thlima`).
    #[serde(default)]
    pub limit_high: Option<i32>,

    /// Contra-sharpening strength applied after dehaloing (havsfunc `contra`).
    #[serde(default)]
    pub contra: Option<f64>,

    /// Exclude edges that are too close to each other (havsfunc `excl`).
    #[serde(default)]
    pub exclude_close_edges: Option<bool>,

    /// How much edge detail to add back (havsfunc `edgeproc`).
    #[serde(default)]
    pub edge_proc: Option<f64>,

    // --- YAHR specific ---

    /// Blur amount for YAHR (1-3).
    #[serde(default = "default_yahr_blur")]
    pub yahr_blur: i32,

    /// Processing depth for YAHR.
    #[serde(default = "default_yahr_depth")]
    pub yahr_depth: i32,

    // --- EdgeCleaner specific ---

    /// Edge denoising strength (havsfunc `strength`).
    #[serde(default)]
    pub edge_strength: Option<i32>,

    /// Repair the aWarpSharped clip (havsfunc `rep`).
    #[serde(default)]
    pub edge_repair: Option<bool>,

    /// Repair mode (havsfunc `rmode`: 1 mild, 16/18 keep structure, 17 least halo).
    #[serde(default)]
    pub edge_repair_mode: Option<i32>,

    /// Small-particle (star) detection mode (havsfunc `smode`).
    #[serde(default)]
    pub edge_small_mode: Option<i32>,

    /// Remove hot pixels (havsfunc `hot`).
    #[serde(default)]
    pub edge_hot_pixels: Option<bool>,

    // --- Vinverse / Vinverse2 specific ---

    /// Sharpening strength applied to the vertically blurred clip (`sstr`).
    #[serde(default)]
    pub vinverse_strength: Option<f64>,

    /// Maximum change per pixel (havsfunc `amnt`, 255 = unlimited).
    #[serde(default)]
    pub vinverse_amount: Option<i32>,

    /// Process chroma as well as luma (havsfunc `chroma`).
    #[serde(default)]
    pub vinverse_chroma: Option<bool>,
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
            low_sens: None,
            high_sens: None,
            super_sample: None,
            low_threshold: default_low_threshold(),
            high_threshold: default_high_threshold(),
            limit_low: None,
            limit_high: None,
            contra: None,
            exclude_close_edges: None,
            edge_proc: None,
            yahr_blur: default_yahr_blur(),
            yahr_depth: default_yahr_depth(),
            edge_strength: None,
            edge_repair: None,
            edge_repair_mode: None,
            edge_small_mode: None,
            edge_hot_pixels: None,
            vinverse_strength: None,
            vinverse_amount: None,
            vinverse_chroma: None,
        }
    }
}
