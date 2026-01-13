//! QTGMC deinterlacing parameters.
//!
//! All 70+ QTGMC parameters supported by the VapourSynth implementation.
//! Parameters with `None` values use preset defaults.

use serde::{Deserialize, Serialize};

/// All QTGMC parameters supported by the VapourSynth implementation.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QTGMCParameters {
    /// Whether this pass is enabled.
    #[serde(default = "default_true")]
    pub enabled: bool,

    // === Preset ===
    /// Master quality/speed preset
    #[serde(default)]
    pub preset: QTGMCPreset,

    // === Input/Output ===
    /// Input type: 0=interlaced, 1=progressive, 2=progressive with combing
    #[serde(default)]
    pub input_type: i32,

    /// Top-field-first. None = auto-detect
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tff: Option<bool>,

    /// Output frame rate divisor. 1=double-rate (50i->50p), 2=single-rate (50i->25p)
    #[serde(default = "default_fps_divisor")]
    pub fps_divisor: i32,

    // === Quality (Temporal Radius) ===
    /// Temporal radius for pre-filtering (0-2)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tr0: Option<i32>,

    /// Temporal radius for motion analysis (0-3)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tr1: Option<i32>,

    /// Temporal radius for final smoothing (0-3)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tr2: Option<i32>,

    /// Repair mode after TR0 smoothing (0-4)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rep0: Option<i32>,

    /// Repair mode after TR1 smoothing (0-4)
    #[serde(default)]
    pub rep1: i32,

    /// Repair mode after TR2 smoothing (0-4)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rep2: Option<i32>,

    /// Include chroma in repair
    #[serde(default = "default_true")]
    pub rep_chroma: bool,

    // === Interpolation ===
    /// Edge interpolation mode
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edi_mode: Option<String>,

    /// NNEDI3 predictor neural network size (0-6)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nn_size: Option<i32>,

    /// NNEDI3 number of neurons (0-4)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nn_neurons: Option<i32>,

    /// NNEDI3 interpolation quality (1-2)
    #[serde(default = "default_one")]
    pub edi_qual: i32,

    /// EEDI3 maximum search distance
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edi_max_d: Option<i32>,

    /// Chroma interpolation method
    #[serde(default)]
    pub chroma_edi: String,

    // === Motion Analysis ===
    /// Motion analysis block size
    #[serde(skip_serializing_if = "Option::is_none")]
    pub block_size: Option<i32>,

    /// Block overlap
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overlap: Option<i32>,

    /// Search algorithm (0-5)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub search: Option<i32>,

    /// Search parameter
    #[serde(skip_serializing_if = "Option::is_none")]
    pub search_param: Option<i32>,

    /// Sub-pixel search accuracy (1-4)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pel_search: Option<i32>,

    /// Consider chroma in motion analysis
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chroma_motion: Option<bool>,

    /// Use true motion estimation
    #[serde(default)]
    pub true_motion: bool,

    /// Motion vector cost weighting
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lambda: Option<i32>,

    /// Least squares adaptive distance
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lsad: Option<i32>,

    /// Penalty for new motion vectors
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p_new: Option<i32>,

    /// Penalty level
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p_level: Option<i32>,

    /// Use global motion analysis
    #[serde(default = "default_true")]
    pub global_motion: bool,

    /// DCT mode for motion analysis (0-10)
    #[serde(default)]
    pub dct: i32,

    /// Sub-pixel accuracy (1=full, 2=half, 4=quarter)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sub_pel: Option<i32>,

    /// Sub-pixel interpolation method (1-2)
    #[serde(default = "default_two")]
    pub sub_pel_interp: i32,

    // === Motion Thresholds ===
    /// SAD threshold for TR1 temporal smoothing
    #[serde(default = "default_th_sad1")]
    pub th_sad1: i32,

    /// SAD threshold for TR2 temporal smoothing
    #[serde(default = "default_th_sad2")]
    pub th_sad2: i32,

    /// Scene change detection threshold 1
    #[serde(default = "default_th_scd1")]
    pub th_scd1: i32,

    /// Scene change detection threshold 2
    #[serde(default = "default_th_scd2")]
    pub th_scd2: i32,

    // === Sharpening ===
    /// Output sharpness (0.0-2.0)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sharpness: Option<f64>,

    /// Sharpening mode: 0=off, 1=unmasked, 2=masked
    #[serde(skip_serializing_if = "Option::is_none")]
    pub s_mode: Option<i32>,

    /// Sharpness limiting mode: 0=off, 1=simple, 2=complex
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sl_mode: Option<i32>,

    /// Sharpness limiting radius
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sl_rad: Option<i32>,

    /// Sharpening overshoot
    #[serde(default)]
    pub s_ovs: i32,

    /// Thin line sharpening (0.0-1.0)
    #[serde(default)]
    pub sv_thin: f64,

    /// Sharpening back-blend (0-3)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sbb: Option<i32>,

    /// Search clip preprocessing (0-5)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub srch_clip_pp: Option<i32>,

    // === Noise Processing ===
    /// Noise processing mode: 0=off, 1=denoise, 2=grain restore
    #[serde(skip_serializing_if = "Option::is_none")]
    pub noise_process: Option<i32>,

    /// Easy denoise strength
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ez_denoise: Option<f64>,

    /// Easy grain retention amount
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ez_keep_grain: Option<f64>,

    /// Noise estimation preset
    #[serde(default = "default_noise_preset")]
    pub noise_preset: String,

    /// Denoiser plugin
    #[serde(skip_serializing_if = "Option::is_none")]
    pub denoiser: Option<String>,

    /// FFT denoiser thread count
    #[serde(default = "default_one")]
    pub fft_threads: i32,

    /// Motion-compensated denoising
    #[serde(skip_serializing_if = "Option::is_none")]
    pub denoise_mc: Option<bool>,

    /// Noise temporal radius
    #[serde(skip_serializing_if = "Option::is_none")]
    pub noise_tr: Option<i32>,

    /// Denoising sigma (strength)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sigma: Option<f64>,

    /// Apply denoising to chroma
    #[serde(default)]
    pub chroma_noise: bool,

    /// Show noise (for debugging)
    #[serde(default)]
    pub show_noise: f64,

    /// Grain restoration amount
    #[serde(skip_serializing_if = "Option::is_none")]
    pub grain_restore: Option<f64>,

    /// Noise restoration amount
    #[serde(skip_serializing_if = "Option::is_none")]
    pub noise_restore: Option<f64>,

    /// Noise deinterlacing method
    #[serde(skip_serializing_if = "Option::is_none")]
    pub noise_deint: Option<String>,

    /// Stabilize noise
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stabilize_noise: Option<bool>,

    // === Source Matching ===
    /// Source matching mode: 0=off, 1=simple, 2=refined, 3=double
    #[serde(default)]
    pub source_match: i32,

    /// Interpolation preset for source match pass 1
    #[serde(skip_serializing_if = "Option::is_none")]
    pub match_preset: Option<String>,

    /// Interpolation method for source match pass 1
    #[serde(skip_serializing_if = "Option::is_none")]
    pub match_edi: Option<String>,

    /// Interpolation preset for source match pass 2
    #[serde(skip_serializing_if = "Option::is_none")]
    pub match_preset2: Option<String>,

    /// Interpolation method for source match pass 2
    #[serde(skip_serializing_if = "Option::is_none")]
    pub match_edi2: Option<String>,

    /// Temporal radius for source match output
    #[serde(default = "default_one")]
    pub match_tr2: i32,

    /// Source match enhancement
    #[serde(default = "default_match_enhance")]
    pub match_enhance: f64,

    /// Lossless mode: 0=off, 1=lossless, 2=fake lossless
    #[serde(default)]
    pub lossless: i32,

    // === Advanced ===
    /// Add borders to help edge interpolation
    #[serde(default)]
    pub border: bool,

    /// Use precise mode
    #[serde(skip_serializing_if = "Option::is_none")]
    pub precise: Option<bool>,

    /// Force minimum temporal radius for motion vectors
    #[serde(default)]
    pub force_tr: i32,

    /// Pre-filter brightening strength
    #[serde(default = "default_str")]
    pub str: f64,

    /// Amplitude
    #[serde(default = "default_amp")]
    pub amp: f64,

    /// Fast motion analysis
    #[serde(default)]
    pub fast_ma: bool,

    /// Extended pel search
    #[serde(default)]
    pub e_search_p: bool,

    /// Refine motion estimation
    #[serde(default)]
    pub refine_motion: bool,

    // === GPU Acceleration ===
    /// Use OpenCL acceleration
    #[serde(default)]
    pub opencl: bool,

    /// OpenCL device index
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<i32>,
}

// Default value functions
fn default_fps_divisor() -> i32 { 1 }
fn default_true() -> bool { true }
fn default_one() -> i32 { 1 }
fn default_two() -> i32 { 2 }
fn default_th_sad1() -> i32 { 640 }
fn default_th_sad2() -> i32 { 256 }
fn default_th_scd1() -> i32 { 180 }
fn default_th_scd2() -> i32 { 98 }
fn default_noise_preset() -> String { "Fast".to_string() }
fn default_match_enhance() -> f64 { 0.5 }
fn default_str() -> f64 { 2.0 }
fn default_amp() -> f64 { 0.0625 }

impl Default for QTGMCParameters {
    fn default() -> Self {
        Self {
            enabled: true,
            preset: QTGMCPreset::default(),
            input_type: 0,
            tff: None,
            fps_divisor: 1,
            tr0: None,
            tr1: None,
            tr2: None,
            rep0: None,
            rep1: 0,
            rep2: None,
            rep_chroma: true,
            edi_mode: None,
            nn_size: None,
            nn_neurons: None,
            edi_qual: 1,
            edi_max_d: None,
            chroma_edi: String::new(),
            block_size: None,
            overlap: None,
            search: None,
            search_param: None,
            pel_search: None,
            chroma_motion: None,
            true_motion: false,
            lambda: None,
            lsad: None,
            p_new: None,
            p_level: None,
            global_motion: true,
            dct: 0,
            sub_pel: None,
            sub_pel_interp: 2,
            th_sad1: 640,
            th_sad2: 256,
            th_scd1: 180,
            th_scd2: 98,
            sharpness: None,
            s_mode: None,
            sl_mode: None,
            sl_rad: None,
            s_ovs: 0,
            sv_thin: 0.0,
            sbb: None,
            srch_clip_pp: None,
            noise_process: None,
            ez_denoise: None,
            ez_keep_grain: None,
            noise_preset: "Fast".to_string(),
            denoiser: None,
            fft_threads: 1,
            denoise_mc: None,
            noise_tr: None,
            sigma: None,
            chroma_noise: false,
            show_noise: 0.0,
            grain_restore: None,
            noise_restore: None,
            noise_deint: None,
            stabilize_noise: None,
            source_match: 0,
            match_preset: None,
            match_edi: None,
            match_preset2: None,
            match_edi2: None,
            match_tr2: 1,
            match_enhance: 0.5,
            lossless: 0,
            border: false,
            precise: None,
            force_tr: 0,
            str: 2.0,
            amp: 0.0625,
            fast_ma: false,
            e_search_p: false,
            refine_motion: false,
            opencl: false,
            device: None,
        }
    }
}

/// QTGMC quality/speed presets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum QTGMCPreset {
    Placebo,
    #[serde(rename = "Very Slow")]
    VerySlow,
    #[default]
    Slower,
    Slow,
    Medium,
    Fast,
    Faster,
    #[serde(rename = "Very Fast")]
    VeryFast,
    #[serde(rename = "Super Fast")]
    SuperFast,
    #[serde(rename = "Ultra Fast")]
    UltraFast,
    Draft,
}

impl QTGMCPreset {
    /// Get the preset string for VapourSynth.
    pub fn as_str(&self) -> &'static str {
        match self {
            QTGMCPreset::Placebo => "Placebo",
            QTGMCPreset::VerySlow => "Very Slow",
            QTGMCPreset::Slower => "Slower",
            QTGMCPreset::Slow => "Slow",
            QTGMCPreset::Medium => "Medium",
            QTGMCPreset::Fast => "Fast",
            QTGMCPreset::Faster => "Faster",
            QTGMCPreset::VeryFast => "Very Fast",
            QTGMCPreset::SuperFast => "Super Fast",
            QTGMCPreset::UltraFast => "Ultra Fast",
            QTGMCPreset::Draft => "Draft",
        }
    }

    /// Human-readable description.
    pub fn description(&self) -> &'static str {
        match self {
            QTGMCPreset::Placebo => "Highest quality, very slow",
            QTGMCPreset::VerySlow => "Excellent quality, slow",
            QTGMCPreset::Slower => "Very high quality (recommended)",
            QTGMCPreset::Slow => "High quality, moderate speed",
            QTGMCPreset::Medium => "Good quality, faster",
            QTGMCPreset::Fast => "Fair quality, fast",
            QTGMCPreset::Faster => "Lower quality, very fast",
            QTGMCPreset::VeryFast => "Basic quality, very fast",
            QTGMCPreset::SuperFast => "Minimal quality, fastest",
            QTGMCPreset::UltraFast => "Lowest quality (uses yadif)",
            QTGMCPreset::Draft => "Testing only",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_preset_serialization() {
        assert_eq!(
            serde_json::to_string(&QTGMCPreset::Slower).unwrap(),
            "\"Slower\""
        );
        assert_eq!(
            serde_json::to_string(&QTGMCPreset::VerySlow).unwrap(),
            "\"Very Slow\""
        );
    }

    #[test]
    fn test_default_parameters() {
        let params = QTGMCParameters::default();
        assert_eq!(params.preset, QTGMCPreset::Slower);
        assert_eq!(params.fps_divisor, 1);
        assert!(params.tff.is_none());
    }
}
