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
    /// Real-ESRGAN's anime video model (BSD-3), on the GPU through VSNCNN.
    /// Its models are an add-on (`upscale-anime`) — see `upscale_addons.rs`.
    RealEsrgan,
    /// Real-CUGAN (MIT, bilibili), on the GPU through VSNCNN. Add-on, as above.
    RealCugan,
    /// AnimeJaNai (the-database, CC BY-NC-SA 4.0), on the GPU through VSNCNN.
    /// Its models are an optional download, not in the deps bundle — see
    /// `animejanai.rs`.
    AnimeJanai,
    /// Real-ESRGAN's general model for real-world footage (`realesr-general-x4v3`,
    /// BSD-3), 4x native; a 2x upscale runs it at 4x and resamples down. Its
    /// model is an add-on — see `upscale_addons.rs`.
    RealEsrganGeneral,
    /// jcj83429's 2xLiveActionV1_SPAN (Apache-2.0), 2x native, for live
    /// action; 4x runs it twice. Add-on, as above.
    LiveAction,
    /// Real-ESRGAN x4plus / x2plus (BSD-3), the large RRDB networks, chosen by
    /// factor. Add-on, as above.
    RealEsrganPlus,
}

impl UpscaleMethod {
    /// Whether this is one of the neural upscalers that need the VSNCNN plugin
    /// and a Vulkan device (see `gpu_plugin.rs`).
    pub fn is_ai(self) -> bool {
        matches!(
            self,
            UpscaleMethod::RealEsrgan
                | UpscaleMethod::RealCugan
                | UpscaleMethod::AnimeJanai
                | UpscaleMethod::RealEsrganGeneral
                | UpscaleMethod::LiveAction
                | UpscaleMethod::RealEsrganPlus
        )
    }

    /// The manifest add-on holding this method's models, and the feature name
    /// the worker's refusal starts with when it is missing. `None` for the
    /// methods that run no model (and for AnimeJaNai, whose hand-written
    /// add-on is checked separately — see `animejanai.rs`).
    pub fn addon(self) -> Option<(&'static str, &'static str)> {
        use crate::upscale_addons::{ANIME_ADDON, ESRGAN_PLUS_ADDON, GENERAL_ADDON};
        match self {
            UpscaleMethod::RealEsrgan => Some((ANIME_ADDON, "Real-ESRGAN upscaling")),
            UpscaleMethod::RealCugan => Some((ANIME_ADDON, "Real-CUGAN upscaling")),
            UpscaleMethod::RealEsrganGeneral => Some((GENERAL_ADDON, "Real-ESRGAN General upscaling")),
            UpscaleMethod::LiveAction => Some((GENERAL_ADDON, "Live-action upscaling")),
            UpscaleMethod::RealEsrganPlus => Some((ESRGAN_PLUS_ADDON, "Real-ESRGAN x4plus upscaling")),
            _ => None,
        }
    }
}

/// One network an AI upscale runs. None is in the deps bundle: every model
/// is an add-on (docs/ADDONS.md).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiModel {
    /// An AnimeJaNai model pair under the add-on directory: the script runs
    /// `sd` on a picture at most `animejanai::SD_MAX_HEIGHT` tall, else `hd`.
    /// Decided in the script, per doubling, because only it knows the height
    /// after cropping (and after a first doubling).
    AnimeJanai { sd: &'static str, hd: &'static str },
    /// A model from a manifest add-on: `addons/<addon>/<file>` (see
    /// `upscale_addons.rs`).
    Addon { addon: &'static str, file: &'static str },
}

impl AiModel {
    /// The network's own scale factor. AnimeJaNai's double; manifest
    /// add-on models say (`upscale_addons::MODELS`).
    pub fn scale(&self) -> u32 {
        match self {
            AiModel::AnimeJanai { .. } => 2,
            AiModel::Addon { file, .. } => crate::upscale_addons::scale_of(file),
        }
    }
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

/// Fill colour for letterbox/pillarbox bars (issue #86).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum BorderColor {
    #[default]
    Black,
    Grey,
    White,
    /// An `#RRGGBB` value from `pad_custom_color`.
    Custom,
}

/// Parse `#RRGGBB` (the `#` optional) into 8-bit RGB. `None` for anything else,
/// so a typo falls back to black rather than reaching the script.
pub fn parse_hex_color(text: &str) -> Option<[u8; 3]> {
    let hex = text.trim();
    let hex = hex.strip_prefix('#').unwrap_or(hex);
    if hex.len() != 6 || !hex.is_ascii() {
        return None;
    }
    let channel = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16).ok();
    Some([channel(0)?, channel(2)?, channel(4)?])
}

/// Whether an SD (BT.601) source is converted to BT.709 colour (app 1.7.0).
///
/// An SD source upscaled to HD keeps its BT.601 matrix unless something
/// converts it. The tag on the file says 601, which is correct, but many
/// players and TVs ignore the tag on an HD-sized picture and decode it as 709,
/// shifting greens by up to 40 levels and reds by up to 25 (measured: 75%
/// green comes back as 161 instead of 191). Converting the samples and
/// declaring 709 makes every player agree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Bt709Conversion {
    /// Convert a BT.601 source when the output is HD-sized
    /// (`HD_MIN_HEIGHT` lines or `HD_MIN_WIDTH` columns).
    #[default]
    Auto,
    /// Convert a BT.601 source whatever the output size.
    On,
    /// Never convert: the output keeps the source's matrix and tags.
    Off,
}

/// The smallest output that counts as HD for [`Bt709Conversion::Auto`]: 720
/// lines, or 1280 columns for a wide picture cropped short (1280x536 scope).
/// The same height `ColorMetadata::zimg_matrix` guesses 709 from, and the
/// definition players use when they pick a matrix by size.
pub const HD_MIN_HEIGHT: i32 = 720;
pub const HD_MIN_WIDTH: i32 = 1280;

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

    // --- Borders (issue #86) ---

    /// Add bars out to a fixed canvas size, without rescaling the picture.
    #[serde(default)]
    pub pad_enabled: bool,

    /// Canvas width. `None` leaves the width at the picture's own.
    #[serde(default)]
    pub pad_width: Option<i32>,

    /// Canvas height. `None` leaves the height at the picture's own.
    #[serde(default)]
    pub pad_height: Option<i32>,

    /// Fill colour for every bar this pass adds, Pad to Fill's included.
    #[serde(default)]
    pub pad_color: BorderColor,

    /// `#RRGGBB` used when `pad_color` is `Custom`.
    #[serde(default)]
    pub pad_custom_color: Option<String>,

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

    /// Real-CUGAN's denoise strength: "none", "conservative" or "denoise3x" —
    /// the three bundled 2x models.
    #[serde(default = "default_cugan_noise")]
    pub cugan_noise: String,

    /// AnimeJaNai's HD model size: "compact" (the best), "ultraCompact" or
    /// "superUltraCompact" (the fastest).
    #[serde(default = "default_animejanai_model")]
    pub animejanai_model: String,

    /// AnimeJaNai's Sharp variant of the HD model.
    #[serde(default)]
    pub animejanai_sharp: bool,

    /// Real-ESRGAN General's denoise variant (`realesr-general-wdn-x4v3`),
    /// which also removes noise as it upscales.
    #[serde(default)]
    pub general_denoise: bool,

    /// How much of an AI upscale to keep, 0.0-1.0: the result is blended with
    /// a Spline36 upscale of the same frame (`std.Merge`) at the clip's own
    /// format. 1.0 (the default) is the network's output alone, and leaves the
    /// script exactly as it was before this setting existed.
    #[serde(default = "default_ai_strength")]
    pub ai_strength: f64,

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

    /// BT.601 -> BT.709 colour conversion (app 1.7.0). Absent in a job or
    /// preset saved before it existed, which therefore gets `Auto`.
    #[serde(default)]
    pub convert_to_bt709: Bt709Conversion,
}

fn default_true() -> bool { true }
fn default_upscale_factor() -> i32 { 2 }
fn default_cugan_noise() -> String { "conservative".to_string() }
fn default_animejanai_model() -> String { "compact".to_string() }
fn default_ai_strength() -> f64 { 1.0 }

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
            pad_enabled: false,
            pad_width: None,
            pad_height: None,
            pad_color: BorderColor::default(),
            pad_custom_color: None,
            bicubic_b: None,
            bicubic_c: None,
            lanczos_taps: None,
            maintain_aspect: true,
            use_integer_upscale: false,
            upscale_method: UpscaleMethod::default(),
            upscale_factor: default_upscale_factor(),
            cugan_noise: default_cugan_noise(),
            animejanai_model: default_animejanai_model(),
            animejanai_sharp: false,
            general_denoise: false,
            ai_strength: default_ai_strength(),
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
            convert_to_bt709: Bt709Conversion::default(),
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

impl AspectDeclaration {
    /// The `key=value` token the preview reports on its `PREVIEW_INFO:` line,
    /// or `None` for square pixels: `sar=16/15` or `dar=16/9`. The app draws
    /// the processed frame at this shape; without it the frame was drawn at
    /// the *source's* display aspect, squashing anything a pass reshaped
    /// (issue #149). '/' as the separator, matching what ffmpeg is given.
    pub fn preview_token(&self) -> Option<String> {
        match self {
            AspectDeclaration::Sar(sar) => Some(format!("sar={}", sar.trim().replace(':', "/"))),
            AspectDeclaration::Dar(dar) => Some(format!("dar={}", dar.trim().replace(':', "/"))),
            AspectDeclaration::None => None,
        }
    }
}

#[allow(dead_code)]
impl CropResizeParameters {
    /// Whether this pass upscales with a neural model, which needs the VSNCNN
    /// plugin and a working Vulkan device.
    pub fn uses_ai_upscale(&self) -> bool {
        self.enabled && self.use_integer_upscale && self.upscale_method.is_ai()
    }

    /// Whether this pass upscales with AnimeJaNai, whose models must also be
    /// installed as an add-on.
    pub fn uses_animejanai(&self) -> bool {
        self.uses_ai_upscale() && self.upscale_method == UpscaleMethod::AnimeJanai
    }

    /// The manifest add-on this pass's AI upscale needs, with the feature name
    /// for the refusal (see `UpscaleMethod::addon`).
    pub fn upscale_addon(&self) -> Option<(&'static str, &'static str)> {
        if self.uses_ai_upscale() { self.upscale_method.addon() } else { None }
    }

    /// The models an AI upscale runs, in order, each a file in an add-on's
    /// directory. Factors follow the edge-directed path's
    /// rule (3x behaves as 2x). Real-ESRGAN has a 4x model; Real-CUGAN's
    /// models are 2x only, so 4x runs it twice, denoising on the first
    /// pass only — a second denoise pass would smooth the result twice.
    /// AnimeJaNai is 2x only, so 4x is two doublings; the script picks SD or
    /// HD for each, so a DVD runs the SD model and then an HD one.
    pub fn ai_upscale_models(&self) -> Vec<AiModel> {
        let four = self.upscale_factor >= 4;
        let anime = |names: Vec<&'static str>| {
            names
                .into_iter()
                .map(|file| AiModel::Addon { addon: crate::upscale_addons::ANIME_ADDON, file })
                .collect()
        };
        match self.upscale_method {
            UpscaleMethod::AnimeJanai => {
                let pair = AiModel::AnimeJanai {
                    sd: crate::animejanai::SD_MODEL,
                    hd: crate::animejanai::hd_model(&self.animejanai_model, self.animejanai_sharp),
                };
                vec![pair; if four { 2 } else { 1 }]
            }
            UpscaleMethod::RealEsrgan => {
                use crate::upscale_addons::{ANIME_ESRGAN_X2, ANIME_ESRGAN_X4};
                anime(vec![if four { ANIME_ESRGAN_X4 } else { ANIME_ESRGAN_X2 }])
            }
            UpscaleMethod::RealCugan => {
                use crate::upscale_addons::{CUGAN_CONSERVATIVE, CUGAN_DENOISE3X, CUGAN_NO_DENOISE};
                let first = match self.cugan_noise.as_str() {
                    "none" => CUGAN_NO_DENOISE,
                    "denoise3x" => CUGAN_DENOISE3X,
                    _ => CUGAN_CONSERVATIVE,
                };
                anime(if four { vec![first, CUGAN_NO_DENOISE] } else { vec![first] })
            }
            UpscaleMethod::RealEsrganGeneral => {
                use crate::upscale_addons::{GENERAL_ADDON, GENERAL_WDN_X4, GENERAL_X4};
                let file = if self.general_denoise { GENERAL_WDN_X4 } else { GENERAL_X4 };
                // 4x only: a 2x upscale resamples its result down (see
                // `ai_resample_to`).
                vec![AiModel::Addon { addon: GENERAL_ADDON, file }]
            }
            UpscaleMethod::LiveAction => {
                use crate::upscale_addons::{GENERAL_ADDON, LIVE_ACTION_X2};
                let m = AiModel::Addon { addon: GENERAL_ADDON, file: LIVE_ACTION_X2 };
                vec![m; if four { 2 } else { 1 }]
            }
            UpscaleMethod::RealEsrganPlus => {
                use crate::upscale_addons::{ESRGAN_PLUS_ADDON, PLUS_X2, PLUS_X4};
                vec![AiModel::Addon { addon: ESRGAN_PLUS_ADDON, file: if four { PLUS_X4 } else { PLUS_X2 } }]
            }
            _ => Vec::new(),
        }
    }

    /// The factor an AI upscale delivers: 4 for 4x, else 2 (3x behaves as 2x,
    /// as on the edge-directed path).
    pub fn ai_upscale_factor(&self) -> u32 {
        if self.upscale_factor >= 4 { 4 } else { 2 }
    }

    /// When the networks enlarge further than asked — Real-ESRGAN General is
    /// 4x only, so a 2x job runs it at 4x — the factor to resample their
    /// result down to (Spline36, in the networks' float RGB, before the
    /// conversion back). `None` when the networks land on the factor exactly,
    /// which leaves the script as it was. Upstream does the same for its own
    /// `--outscale` (4x, then a Lanczos resize); see the report in
    /// docs/reports/2026-11-ai-upscale-addons/ for the kernel comparison.
    pub fn ai_resample_to(&self) -> Option<u32> {
        let models = self.ai_upscale_models();
        if models.is_empty() {
            return None;
        }
        let total: u32 = models.iter().map(AiModel::scale).product();
        (total != self.ai_upscale_factor()).then(|| self.ai_upscale_factor())
    }

    /// The AI strength as a blend weight for the network's output, or `None`
    /// at full strength (1.0, the default), where no blend is emitted and the
    /// script is unchanged. Clamped to 0..1; a non-finite value (a hand-edited
    /// preset) is full strength.
    pub fn ai_blend_weight(&self) -> Option<f64> {
        let s = self.ai_strength;
        if !s.is_finite() || s >= 1.0 {
            None
        } else {
            Some(s.max(0.0))
        }
    }

    /// When a frame runs in tiles, and their size: `(largest whole frame in
    /// pixels, tile size)`. Above SD every model tiles at 512 — whole-frame
    /// Real-CUGAN at 1080p ran out of GPU memory on a 16 GB Mac. Real-ESRGAN
    /// x4plus (23 RRDB blocks, then two doublings at full width) is far larger:
    /// whole-frame at 720x576 lost the Vulkan device (`VK_ERROR_DEVICE_LOST`,
    /// then a segfault) and 512-pixel tiles thrashed at 29 s a frame, so it
    /// runs in 384-pixel tiles (6.8 s a frame there; 256 took 10 s). x2plus
    /// works at a quarter of the area until its last layers and runs a DVD
    /// frame whole, so it keeps the common rule.
    pub fn ai_tiling(&self) -> (&'static str, u32) {
        if self.upscale_method == UpscaleMethod::RealEsrganPlus && self.ai_upscale_factor() == 4 {
            ("384 * 384", 384)
        } else {
            ("720 * 576", 512)
        }
    }

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

    /// Whether Pad to Fill applies: it pads out to the resize target, so there
    /// is nothing to pad to without one.
    pub fn pads_to_aspect(&self) -> bool {
        self.enabled && self.resize_enabled && self.pad_to_aspect
    }

    /// The fixed canvas to pad out to, as (width, height) with `-1` for an axis
    /// left at the picture's own size — or `None` when not padding to a canvas.
    ///
    /// Odd sizes are rounded up to even: every subsampled format needs it, and
    /// rounding up means the picture still fits.
    pub fn pad_canvas(&self) -> Option<(i32, i32)> {
        if !(self.enabled && self.pad_enabled) {
            return None;
        }
        let axis = |v: Option<i32>| v.filter(|&v| v > 0).map_or(-1, |v| (v + 1) & !1);
        let (w, h) = (axis(self.pad_width), axis(self.pad_height));
        (w > 0 || h > 0).then_some((w, h))
    }

    /// Whether any bars are added at all.
    pub fn adds_borders(&self) -> bool {
        self.pads_to_aspect() || self.pad_canvas().is_some()
    }

    /// The bar colour as 8-bit RGB. An unparseable custom colour is black.
    pub fn border_rgb(&self) -> [u8; 3] {
        match self.pad_color {
            BorderColor::Black => [0, 0, 0],
            BorderColor::Grey => [128, 128, 128],
            BorderColor::White => [255, 255, 255],
            BorderColor::Custom => self
                .pad_custom_color
                .as_deref()
                .and_then(parse_hex_color)
                .unwrap_or([0, 0, 0]),
        }
    }

    /// The frame size this pass delivers from a `width` x `height` picture
    /// whose samples are `sar` wide, mirroring the script: crop, then the
    /// integer upscale, then the resize fitting (`RESIZE_STANDARD`), then the
    /// bars. The script stays the authority on the exact size; this is what
    /// the worker needs to decide things that must be fixed before the script
    /// runs, such as the colour tags on both sides of the encoder.
    pub fn output_size(&self, width: i32, height: i32, sar: f64) -> (i32, i32) {
        if !self.enabled {
            return (width, height);
        }
        let (mut w, mut h) = (width as f64, height as f64);
        if self.crop_enabled {
            w -= f64::from(self.crop_left.max(0) + self.crop_right.max(0));
            h -= f64::from(self.crop_top.max(0) + self.crop_bottom.max(0));
        }
        let squares = self.squares_pixels();
        if self.resize_enabled || self.use_integer_upscale || squares {
            if self.use_integer_upscale {
                let factor = if self.upscale_method.is_ai() {
                    f64::from(self.ai_upscale_factor())
                } else if self.upscale_method == UpscaleMethod::Spline36 {
                    f64::from(self.upscale_factor.max(1))
                } else {
                    // Edge-directed: max(factor // 2, 1) doublings.
                    f64::from(1 << (self.upscale_factor / 2).max(1))
                };
                w *= factor;
                h *= factor;
            }
            if self.resize_enabled || squares {
                let even = |v: f64| ((v.round() as i32) & !1).max(2) as f64;
                let display = self.display_aspect_ratio().unwrap_or(w * sar / h.max(1.0));
                let fit = if squares { display } else { w / h.max(1.0) };
                let mut tw = if self.resize_enabled { self.target_width.unwrap_or(-1) } else { -1 } as f64;
                let mut th = if self.resize_enabled { self.target_height.unwrap_or(-1) } else { -1 } as f64;
                if squares && tw <= 0.0 && th <= 0.0 {
                    th = h;
                }
                if self.maintain_aspect || (squares && tw <= 0.0 && th <= 0.0) {
                    if tw > 0.0 && th <= 0.0 {
                        th = even(tw / fit);
                    } else if th > 0.0 && tw <= 0.0 {
                        tw = even(th * fit);
                    } else if tw > 0.0 && th > 0.0 {
                        let scale = (tw / (h * fit)).min(th / h);
                        tw = even(h * fit * scale);
                        th = even(h * scale);
                    }
                }
                if tw > 0.0 {
                    w = tw;
                }
                if th > 0.0 {
                    h = th;
                }
                if self.pads_to_aspect() {
                    w = w.max(f64::from(self.target_width.unwrap_or(0)));
                    h = h.max(f64::from(self.target_height.unwrap_or(0)));
                }
            }
        }
        if let Some((cw, ch)) = self.pad_canvas() {
            if cw > 0 {
                w = w.max(f64::from(cw));
            }
            if ch > 0 {
                h = h.max(f64::from(ch));
            }
        }
        (w.round() as i32, h.round() as i32)
    }

    /// Whether the samples are converted from BT.601 to BT.709, for a source
    /// whose colour is BT.601 (`source_is_601`, see
    /// `ColorMetadata::is_bt601_family`) delivered at `output` size.
    pub fn converts_to_bt709(&self, source_is_601: bool, output: (i32, i32)) -> bool {
        if !self.enabled || !source_is_601 {
            return false;
        }
        match self.convert_to_bt709 {
            Bt709Conversion::Off => false,
            Bt709Conversion::On => true,
            Bt709Conversion::Auto => output.1 >= HD_MIN_HEIGHT || output.0 >= HD_MIN_WIDTH,
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
    fn test_preview_token() {
        assert_eq!(
            AspectDeclaration::Sar("16:15".into()).preview_token().as_deref(),
            Some("sar=16/15")
        );
        assert_eq!(
            AspectDeclaration::Dar("16/9".into()).preview_token().as_deref(),
            Some("dar=16/9")
        );
        assert_eq!(AspectDeclaration::None.preview_token(), None);
    }

    #[test]
    fn test_parse_hex_color() {
        assert_eq!(parse_hex_color("#FF8000"), Some([255, 128, 0]));
        assert_eq!(parse_hex_color(" 0a0B0c "), Some([10, 11, 12]));
        for junk in ["", "#FFF", "#GGGGGG", "#FF80001", "red", "#ÿÿÿ"] {
            assert_eq!(parse_hex_color(junk), None, "{junk:?}");
        }
    }

    #[test]
    fn test_border_rgb_falls_back_to_black() {
        let mut params = CropResizeParameters::default();
        assert_eq!(params.border_rgb(), [0, 0, 0]);
        params.pad_color = BorderColor::White;
        assert_eq!(params.border_rgb(), [255, 255, 255]);
        params.pad_color = BorderColor::Custom;
        params.pad_custom_color = Some("#102030".to_string());
        assert_eq!(params.border_rgb(), [16, 32, 48]);
        params.pad_custom_color = Some("blue".to_string());
        assert_eq!(params.border_rgb(), [0, 0, 0]);
    }

    #[test]
    fn test_pad_canvas() {
        let params = CropResizeParameters {
            enabled: true,
            pad_enabled: true,
            pad_width: Some(720),
            pad_height: Some(575),
            ..CropResizeParameters::default()
        };
        // Odd rounds up, so the picture still fits.
        assert_eq!(params.pad_canvas(), Some((720, 576)));
        assert!(params.adds_borders());

        // One axis only: the other stays at the picture's own size.
        let one_axis = CropResizeParameters { pad_width: None, ..params.clone() };
        assert_eq!(one_axis.pad_canvas(), Some((-1, 576)));

        // No size at all, the section off, or the pass off: no canvas.
        let no_size = CropResizeParameters { pad_width: None, pad_height: Some(0), ..params.clone() };
        assert_eq!(no_size.pad_canvas(), None);
        let off = CropResizeParameters { pad_enabled: false, ..params.clone() };
        assert_eq!(off.pad_canvas(), None);
        let pass_off = CropResizeParameters { enabled: false, ..params };
        assert_eq!(pass_off.pad_canvas(), None);
        assert!(!pass_off.adds_borders());
    }

    #[test]
    fn test_pad_to_aspect_needs_a_resize_target() {
        let params = CropResizeParameters {
            enabled: true,
            pad_to_aspect: true,
            ..CropResizeParameters::default()
        };
        assert!(!params.pads_to_aspect());
        assert!(CropResizeParameters { resize_enabled: true, ..params }.pads_to_aspect());
    }

    #[test]
    fn test_serialization() {
        let params = CropResizeParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"maintainAspect\":true"));
    }

    #[test]
    fn test_ai_upscale_models_follow_factor_and_noise() {
        let p = |method, factor, noise: &str| CropResizeParameters {
            enabled: true,
            use_integer_upscale: true,
            upscale_method: method,
            upscale_factor: factor,
            cugan_noise: noise.into(),
            ..Default::default()
        };
        use crate::upscale_addons::*;
        let b = |names: &[&'static str]| {
            names.iter().map(|&file| AiModel::Addon { addon: ANIME_ADDON, file }).collect::<Vec<_>>()
        };
        assert_eq!(p(UpscaleMethod::RealEsrgan, 2, "").ai_upscale_models(), b(&[ANIME_ESRGAN_X2]));
        assert_eq!(p(UpscaleMethod::RealEsrgan, 3, "").ai_upscale_models(), b(&[ANIME_ESRGAN_X2]));
        assert_eq!(p(UpscaleMethod::RealEsrgan, 4, "").ai_upscale_models(), b(&[ANIME_ESRGAN_X4]));
        assert_eq!(p(UpscaleMethod::RealCugan, 2, "denoise3x").ai_upscale_models(), b(&[CUGAN_DENOISE3X]));
        assert_eq!(p(UpscaleMethod::RealCugan, 4, "none").ai_upscale_models(),
            b(&[CUGAN_NO_DENOISE, CUGAN_NO_DENOISE]));
        // An unknown strength from a hand-edited preset is the default.
        assert_eq!(p(UpscaleMethod::RealCugan, 2, "max").ai_upscale_models(), b(&[CUGAN_CONSERVATIVE]));
        // Every model named here is one the add-on installs, and the add-on
        // is what the pass declares it needs.
        for m in [UpscaleMethod::RealEsrgan, UpscaleMethod::RealCugan] {
            for f in [2, 4] {
                for n in ["none", "conservative", "denoise3x"] {
                    let params = p(m, f, n);
                    assert_eq!(params.upscale_addon().map(|a| a.0), Some(ANIME_ADDON));
                    for model in params.ai_upscale_models() {
                        let AiModel::Addon { addon, file } = model else { panic!("{model:?}") };
                        assert!(MODELS.contains(&(addon, file, model.scale())), "{file}");
                    }
                }
            }
        }
        assert!(!p(UpscaleMethod::Nnedi3Rpow2, 2, "").uses_ai_upscale());
        assert!(p(UpscaleMethod::RealCugan, 2, "").uses_ai_upscale());
        assert!(!p(UpscaleMethod::RealCugan, 2, "").uses_animejanai());
    }

    #[test]
    fn test_animejanai_models_pair_sd_with_the_chosen_hd_model() {
        let p = |factor, size: &str, sharp| CropResizeParameters {
            enabled: true,
            use_integer_upscale: true,
            upscale_method: UpscaleMethod::AnimeJanai,
            upscale_factor: factor,
            animejanai_model: size.into(),
            animejanai_sharp: sharp,
            ..Default::default()
        };
        let pair = |hd| AiModel::AnimeJanai { sd: crate::animejanai::SD_MODEL, hd };
        assert_eq!(p(2, "compact", false).ai_upscale_models(),
            [pair("2x_AnimeJaNai_HD_V3_Compact.onnx")]);
        assert_eq!(p(3, "superUltraCompact", true).ai_upscale_models(),
            [pair("2x_AnimeJaNai_HD_V3Sharp1_SuperUltraCompact.onnx")]);
        // 2x only: 4x is two doublings, each choosing SD or HD.
        assert_eq!(p(4, "ultraCompact", false).ai_upscale_models(),
            [pair("2x_AnimeJaNai_HD_V3_UltraCompact.onnx"); 2]);
        assert!(p(2, "compact", false).uses_animejanai());
        assert!(p(2, "compact", false).uses_ai_upscale());
        // Defaults: Compact, not sharp.
        let d = CropResizeParameters::default();
        assert_eq!((d.animejanai_model.as_str(), d.animejanai_sharp), ("compact", false));
    }

    #[test]
    fn test_addon_upscalers_follow_their_factor_rules() {
        use crate::upscale_addons::*;
        let p = |method, factor, denoise| CropResizeParameters {
            enabled: true,
            use_integer_upscale: true,
            upscale_method: method,
            upscale_factor: factor,
            general_denoise: denoise,
            ..Default::default()
        };
        let a = |addon, file| AiModel::Addon { addon, file };
        // General is 4x only: 2x (and 3x) run it at 4x and resample down.
        for f in [2, 3] {
            let g = p(UpscaleMethod::RealEsrganGeneral, f, false);
            assert_eq!(g.ai_upscale_models(), [a(GENERAL_ADDON, GENERAL_X4)]);
            assert_eq!(g.ai_resample_to(), Some(2));
        }
        let g4 = p(UpscaleMethod::RealEsrganGeneral, 4, true);
        assert_eq!(g4.ai_upscale_models(), [a(GENERAL_ADDON, GENERAL_WDN_X4)]);
        assert_eq!(g4.ai_resample_to(), None);
        // SPAN is 2x only: 4x runs it twice.
        assert_eq!(p(UpscaleMethod::LiveAction, 2, false).ai_upscale_models(), [a(GENERAL_ADDON, LIVE_ACTION_X2)]);
        assert_eq!(p(UpscaleMethod::LiveAction, 4, false).ai_upscale_models(), [a(GENERAL_ADDON, LIVE_ACTION_X2); 2]);
        assert_eq!(p(UpscaleMethod::LiveAction, 4, false).ai_resample_to(), None);
        // x2plus / x4plus by factor, the 4x one in its own tiles.
        let plus2 = p(UpscaleMethod::RealEsrganPlus, 2, false);
        let plus4 = p(UpscaleMethod::RealEsrganPlus, 4, false);
        assert_eq!(plus2.ai_upscale_models(), [a(ESRGAN_PLUS_ADDON, PLUS_X2)]);
        assert_eq!(plus4.ai_upscale_models(), [a(ESRGAN_PLUS_ADDON, PLUS_X4)]);
        assert_eq!(plus2.ai_tiling(), ("720 * 576", 512));
        assert_eq!(plus4.ai_tiling(), ("384 * 384", 384));
        // The bundled models never resample, and keep the common tiles.
        for m in [UpscaleMethod::RealEsrgan, UpscaleMethod::RealCugan, UpscaleMethod::AnimeJanai] {
            for f in [2, 4] {
                assert_eq!(p(m, f, false).ai_resample_to(), None, "{m:?} {f}");
                assert_eq!(p(m, f, false).ai_tiling(), ("720 * 576", 512));
            }
        }
        // The add-on each needs, only when it is what the pass runs.
        assert_eq!(plus4.upscale_addon().map(|a| a.0), Some(ESRGAN_PLUS_ADDON));
        assert_eq!(p(UpscaleMethod::LiveAction, 2, false).upscale_addon().map(|a| a.0), Some(GENERAL_ADDON));
        assert_eq!(p(UpscaleMethod::RealEsrgan, 2, false).upscale_addon().map(|a| a.0), Some(ANIME_ADDON));
        assert_eq!(p(UpscaleMethod::RealCugan, 4, false).upscale_addon().map(|a| a.0), Some(ANIME_ADDON));
        assert_eq!(p(UpscaleMethod::AnimeJanai, 2, false).upscale_addon(), None);
        let off = CropResizeParameters { use_integer_upscale: false, ..plus4.clone() };
        assert_eq!(off.upscale_addon(), None);
        for m in [UpscaleMethod::RealEsrganGeneral, UpscaleMethod::LiveAction, UpscaleMethod::RealEsrganPlus] {
            assert!(m.is_ai(), "{m:?}");
        }
    }

    #[test]
    fn test_ai_strength_defaults_to_full_and_clamps() {
        let d = CropResizeParameters::default();
        assert_eq!(d.ai_strength, 1.0);
        assert_eq!(d.ai_blend_weight(), None);
        let with = |s| CropResizeParameters { ai_strength: s, ..Default::default() }.ai_blend_weight();
        assert_eq!(with(0.5), Some(0.5));
        assert_eq!(with(-0.2), Some(0.0));
        assert_eq!(with(1.5), None);
        assert_eq!(with(f64::NAN), None);
        // Absent from old JSON = full strength; the camel-case wire names.
        let p: CropResizeParameters = serde_json::from_str(r#"{"enabled":true}"#).unwrap();
        assert_eq!((p.ai_strength, p.general_denoise), (1.0, false));
        let json = serde_json::to_string(&CropResizeParameters {
            upscale_method: UpscaleMethod::RealEsrganGeneral,
            ..Default::default()
        })
        .unwrap();
        assert!(json.contains("\"aiStrength\":1.0"), "{json}");
        assert!(json.contains("\"generalDenoise\":false"), "{json}");
        assert!(json.contains("\"upscaleMethod\":\"realEsrganGeneral\""), "{json}");
        for (v, s) in [(UpscaleMethod::LiveAction, "liveAction"), (UpscaleMethod::RealEsrganPlus, "realEsrganPlus")] {
            assert_eq!(serde_json::to_string(&v).unwrap(), format!("\"{s}\""));
        }
    }

    #[test]
    fn output_size_follows_the_script() {
        let base = CropResizeParameters { enabled: true, ..Default::default() };
        // Nothing switched on: the source size.
        assert_eq!(base.output_size(720, 576, 1.0), (720, 576));
        // Crop, then a 2x NNEDI3 doubling.
        let p = CropResizeParameters {
            crop_enabled: true,
            crop_left: 8,
            crop_right: 8,
            crop_bottom: 8,
            use_integer_upscale: true,
            ..base.clone()
        };
        assert_eq!(p.output_size(720, 576, 1.0), (1408, 1136));
        // 4x edge-directed is two doublings; Spline36 multiplies by the factor.
        let p4 = CropResizeParameters { use_integer_upscale: true, upscale_factor: 4, ..base.clone() };
        assert_eq!(p4.output_size(720, 480, 1.0), (2880, 1920));
        // A 1920x1080 box with the storage aspect kept: 720x576 fits as 1350x1080.
        let fit = CropResizeParameters {
            resize_enabled: true,
            target_width: Some(1920),
            target_height: Some(1080),
            ..base.clone()
        };
        assert_eq!(fit.output_size(720, 576, 1.0), (1350, 1080));
        // Squared up from a 16:9 PAL DVD (SAR 64:45): fills the box exactly.
        let square = CropResizeParameters { pixel_aspect: PixelAspectMode::Square, ..fit.clone() };
        assert_eq!(square.output_size(720, 576, 64.0 / 45.0), (1920, 1080));
        // Squared with no target size keeps the height.
        let square_only = CropResizeParameters { pixel_aspect: PixelAspectMode::Square, ..base.clone() };
        assert_eq!(square_only.output_size(720, 576, 16.0 / 15.0).1, 576);
        // A canvas only ever adds.
        let canvas = CropResizeParameters {
            pad_enabled: true,
            pad_width: Some(1920),
            pad_height: Some(1080),
            ..base.clone()
        };
        assert_eq!(canvas.output_size(720, 576, 1.0), (1920, 1080));
        // A disabled pass changes nothing.
        let off = CropResizeParameters { enabled: false, ..fit };
        assert_eq!(off.output_size(720, 576, 1.0), (720, 576));
    }

    #[test]
    fn bt709_conversion_auto_converts_only_bt601_to_hd() {
        let p = CropResizeParameters { enabled: true, ..Default::default() };
        assert_eq!(p.convert_to_bt709, Bt709Conversion::Auto, "the default");
        assert!(p.converts_to_bt709(true, (1440, 1080)));
        assert!(p.converts_to_bt709(true, (1280, 536)), "a wide picture cropped short is HD");
        assert!(p.converts_to_bt709(true, (960, 720)));
        assert!(!p.converts_to_bt709(true, (1024, 576)), "SD-sized output stays 601");
        assert!(!p.converts_to_bt709(false, (1920, 1080)), "only a 601 source");
        let on = CropResizeParameters { convert_to_bt709: Bt709Conversion::On, ..p.clone() };
        assert!(on.converts_to_bt709(true, (720, 576)));
        assert!(!on.converts_to_bt709(false, (720, 576)));
        let off = CropResizeParameters { convert_to_bt709: Bt709Conversion::Off, ..p.clone() };
        assert!(!off.converts_to_bt709(true, (1920, 1080)));
        let disabled = CropResizeParameters { enabled: false, convert_to_bt709: Bt709Conversion::On, ..p };
        assert!(!disabled.converts_to_bt709(true, (1920, 1080)), "a disabled pass converts nothing");
    }

    #[test]
    fn bt709_conversion_wire_names_and_missing_field() {
        for (v, s) in [(Bt709Conversion::Auto, "auto"), (Bt709Conversion::On, "on"), (Bt709Conversion::Off, "off")] {
            assert_eq!(serde_json::to_string(&v).unwrap(), format!("\"{s}\""));
        }
        // A preset saved before 1.7.0 has no field: Auto.
        let p: CropResizeParameters = serde_json::from_str(r#"{"enabled": true}"#).unwrap();
        assert_eq!(p.convert_to_bt709, Bt709Conversion::Auto);
    }
}
