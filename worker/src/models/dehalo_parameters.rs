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
    /// HQDeringmod: masked ring removal. Smooths the overshoot beside an edge
    /// while protecting the edge itself, which is a different target from
    /// dehalo's wider bright band.
    #[serde(rename = "HQDeringmod")]
    HqDeringmod,
    /// vine: dehalo by non-local-means filtering of the error (vs-jetpack's
    /// vine_dehalo, ported into the templates). Keeps the edge detail the halo
    /// rides on rather than blurring the band (app 1.7.0, deps 1.16.0: needs
    /// vszip's NLMeans).
    #[serde(rename = "vine")]
    Vine,
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
            DehaloMethod::HqDeringmod => "HQDeringmod",
            DehaloMethod::Vine => "vine",
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

    // --- HQDeringmod parameters ---

    /// Ring mask radius. 1 is the default; 2 catches wider rings.
    #[serde(default)]
    pub dering_mrad: Option<i32>,

    /// Mask smoothing radius, which softens where the mask takes effect.
    #[serde(default)]
    pub dering_msmooth: Option<i32>,

    /// Edge-mask threshold (0-255). Lower finds more edges to protect.
    #[serde(default)]
    pub dering_mthr: Option<i32>,

    /// Limit on how far a pixel may be changed, in 8-bit levels.
    #[serde(default)]
    pub dering_thr: Option<f64>,

    /// Separate limit for the dark side of an edge; defaults to `thr / 4`
    /// inside havsfunc, which is usually what you want.
    #[serde(default)]
    pub dering_darkthr: Option<f64>,

    // --- vine parameters ---

    /// NLMeans strength (vs-jetpack's `strength`, default 16). Depth-independent.
    #[serde(default = "default_vine_strength")]
    pub vine_strength: f64,

    /// How much of the supersampled pass to blend in (`sharp`, default 0.5).
    #[serde(default = "default_vine_sharp")]
    pub vine_sharp: f64,

    /// Gaussian sigma of the low/high frequency split (`sigma`, default 1.0).
    #[serde(default = "default_vine_sigma")]
    pub vine_sigma: f64,
}

fn default_rx() -> f64 { 2.0 }
fn default_ry() -> f64 { 2.0 }
fn default_dark_str() -> f64 { 1.0 }
fn default_bright_str() -> f64 { 1.0 }
fn default_low_threshold() -> i32 { 80 }
fn default_high_threshold() -> i32 { 128 }
fn default_yahr_blur() -> i32 { 2 }
fn default_yahr_depth() -> i32 { 32 }
fn default_vine_strength() -> f64 { 16.0 }
fn default_vine_sharp() -> f64 { 0.5 }
fn default_vine_sigma() -> f64 { 1.0 }

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
            dering_mrad: None,
            dering_msmooth: None,
            dering_mthr: None,
            dering_thr: None,
            dering_darkthr: None,
            vine_strength: default_vine_strength(),
            vine_sharp: default_vine_sharp(),
            vine_sigma: default_vine_sigma(),
        }
    }
}

impl DehaloParameters {
    /// vine's (strength, sharp, sigma), clamped to what the script can take:
    /// NLMeans needs h > 0; vs-jetpack refuses sharp <= 0 and caps its effect
    /// at 1; the Gaussian kernel is limited to 25 taps (sigma 4). A non-finite
    /// value falls back to the default rather than reaching the script.
    pub fn vine_effective(&self) -> (f64, f64, f64) {
        let pick = |v: f64, d: f64, lo: f64, hi: f64| if v.is_finite() { v.clamp(lo, hi) } else { d };
        (
            pick(self.vine_strength, default_vine_strength(), 1.0, 64.0),
            pick(self.vine_sharp, default_vine_sharp(), 0.05, 1.0),
            pick(self.vine_sigma, default_vine_sigma(), 0.3, 4.0),
        )
    }
}
