//! QTGMC deinterlacing parameters.
//!
//! All 70+ QTGMC parameters supported by the VapourSynth implementation.
//! Parameters with `None` values use preset defaults.

use serde::{Deserialize, Serialize};

/// Deinterlace method selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum DeinterlaceMethod {
    /// QTGMC high-quality motion-compensated deinterlacing.
    #[default]
    Qtgmc,
    /// IVTC inverse telecine (VFM + VDecimate).
    Ivtc,
    /// Soft telecine: relabel frame rate for DVD sources with soft telecine flags.
    SoftTelecine,
    /// Bwdif — bob-weave deinterlacer with a cubic interpolator. Measured
    /// 622 fps against QTGMC Fast's 150 on the same clip, at most of the
    /// quality. The speed tier, for long captures and quick proofs.
    Bwdif,
}

/// All QTGMC parameters supported by the VapourSynth implementation.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QTGMCParameters {
    /// Whether this pass is enabled.
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Deinterlace method: QTGMC or IVTC.
    #[serde(default)]
    pub method: DeinterlaceMethod,

    // === Preset ===
    /// Master quality/speed preset
    #[serde(default)]
    pub preset: QTGMCPreset,

    // === Input/Output ===
    /// Input type: 0=interlaced, 1=progressive, 2=progressive with combing
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_type: Option<i32>,

    /// Top-field-first. None = auto-detect
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tff: Option<bool>,

    /// Output frame rate divisor. 1=double-rate (50i->50p), 2=single-rate (50i->25p)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps_divisor: Option<i32>,

    /// Hand Bwdif an nnedi3 interpolator instead of its own cubic one. Measured
    /// 0.524 against 0.585 plain — better than Yadifmod+nnedi3 at the same
    /// cost, which is why Yadifmod is not a separate method.
    #[serde(default)]
    pub bwdif_edeint: bool,

    // === Working Format (issue #49) ===
    /// Upsample 4:2:0 chroma to 4:2:2 with field-aware resampling before
    /// deinterlacing, and restore the source format afterwards. Interlaced
    /// 4:2:0 stores chroma per field, so interpolating it at 4:2:0 mixes the
    /// two fields' chroma. Costs roughly 30% throughput (measured 35 -> 24 fps),
    /// so `None` = disabled and the quality/speed trade-off is the user's call.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chroma_upsample_fix: Option<bool>,

    /// Run the deinterlace pass at 16-bit and dither back afterwards. QTGMC
    /// performs many merge/expr steps that round at the working depth. Costs
    /// roughly 2x time and memory, so `None` = disabled.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub high_precision: Option<bool>,

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rep1: Option<i32>,

    /// Repair mode after TR2 smoothing (0-4)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rep2: Option<i32>,

    /// Include chroma in repair
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rep_chroma: Option<bool>,

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edi_qual: Option<i32>,

    /// EEDI3 maximum search distance
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edi_max_d: Option<i32>,

    /// Chroma interpolation method
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chroma_edi: Option<String>,

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub true_motion: Option<bool>,

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub global_motion: Option<bool>,

    /// DCT mode for motion analysis (0-10)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dct: Option<i32>,

    /// Sub-pixel accuracy (1=full, 2=half, 4=quarter)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sub_pel: Option<i32>,

    /// Sub-pixel interpolation method (1-2)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sub_pel_interp: Option<i32>,

    // === Motion Thresholds ===
    /// SAD threshold for TR1 temporal smoothing
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub th_sad1: Option<i32>,

    /// SAD threshold for TR2 temporal smoothing
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub th_sad2: Option<i32>,

    /// Scene change detection threshold 1
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub th_scd1: Option<i32>,

    /// Scene change detection threshold 2
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub th_scd2: Option<i32>,

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub s_ovs: Option<i32>,

    /// Thin line sharpening (0.0-1.0)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sv_thin: Option<f64>,

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub noise_preset: Option<String>,

    /// Denoiser plugin
    #[serde(skip_serializing_if = "Option::is_none")]
    pub denoiser: Option<String>,

    /// FFT denoiser thread count
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fft_threads: Option<i32>,

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chroma_noise: Option<bool>,

    /// Show noise (for debugging)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub show_noise: Option<f64>,

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_match: Option<i32>,

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub match_tr2: Option<i32>,

    /// Source match enhancement
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub match_enhance: Option<f64>,

    /// Lossless mode: 0=off, 1=lossless, 2=fake lossless
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lossless: Option<i32>,

    // === Advanced ===
    /// Add borders to help edge interpolation
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub border: Option<bool>,

    /// Use precise mode
    #[serde(skip_serializing_if = "Option::is_none")]
    pub precise: Option<bool>,

    /// Force minimum temporal radius for motion vectors
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub force_tr: Option<i32>,

    /// Pre-filter brightening strength
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub str: Option<f64>,

    /// Amplitude
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub amp: Option<f64>,

    /// Fast motion analysis
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast_ma: Option<bool>,

    /// Extended pel search
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub e_search_p: Option<bool>,

    /// Refine motion estimation
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refine_motion: Option<bool>,

    // === GPU Acceleration ===
    /// Use OpenCL acceleration
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opencl: Option<bool>,

    /// OpenCL device index
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<i32>,

    // === IVTC Parameters (VFM - field matching) ===
    /// Field order for VFM: 0=BFF, 1=TFF
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ivtc_order: Option<i32>,

    /// VFM matching mode (0-5)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ivtc_mode: Option<i32>,

    /// VFM combing threshold
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ivtc_cthresh: Option<i32>,

    /// VFM max combed pixels in a block
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ivtc_mi: Option<i32>,

    /// VFM block width for combing detection
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ivtc_block_x: Option<i32>,

    /// VFM block height for combing detection
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ivtc_block_y: Option<i32>,

    // === IVTC Parameters (VDecimate - duplicate removal) ===
    /// Decimation cycle length (default 5 for 3:2 pulldown)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ivtc_cycle: Option<i32>,

    /// VDecimate duplicate detection threshold
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ivtc_dupthresh: Option<f64>,

    /// VDecimate scene change threshold
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ivtc_scthresh: Option<f64>,
}

// Default value functions
fn default_true() -> bool { true }

/// ChromaEdi values havsfunc's QTGMC actually implements. Any other non-empty
/// string disables chroma EDI (`planes=[0]`) and then returns the luma-only
/// interpolation without ever restoring chroma, producing badly broken chroma
/// (issue #49) — so unsupported values are dropped rather than passed through.
const SUPPORTED_CHROMA_EDI: [&str; 2] = ["nnedi3", "bob"];

impl QTGMCParameters {
    /// Whether to upsample 4:2:0 chroma to 4:2:2 around the deinterlace pass.
    /// Defaults to disabled: it is the more correct way to handle interlaced
    /// 4:2:0 chroma, but it costs roughly 30% throughput, so it is offered as
    /// an option rather than imposed.
    pub fn chroma_upsample_fix_enabled(&self) -> bool {
        self.chroma_upsample_fix.unwrap_or(false)
    }

    /// Whether to run the deinterlace pass at 16-bit. Defaults to disabled
    /// because it roughly doubles processing time.
    pub fn high_precision_enabled(&self) -> bool {
        self.high_precision.unwrap_or(false)
    }

    /// `chroma_edi` restricted to the values havsfunc implements, lowercased
    /// the way QTGMC itself does.
    ///
    /// The empty string is passed through — it is QTGMC's own default and means
    /// "interpolate chroma with the main EDI". Unsupported non-empty values
    /// return `None` so the parameter is omitted entirely rather than sent
    /// through to the broken code path.
    pub fn normalized_chroma_edi(&self) -> Option<String> {
        let value = self.chroma_edi.as_deref()?.trim().to_lowercase();
        if value.is_empty() || SUPPORTED_CHROMA_EDI.contains(&value.as_str()) {
            Some(value)
        } else {
            None
        }
    }
}

impl Default for QTGMCParameters {
    fn default() -> Self {
        Self {
            enabled: true,
            method: DeinterlaceMethod::default(),
            preset: QTGMCPreset::default(),
            input_type: None,
            tff: None,
            fps_divisor: None,
            bwdif_edeint: false,
            chroma_upsample_fix: None,
            high_precision: None,
            tr0: None,
            tr1: None,
            tr2: None,
            rep0: None,
            rep1: None,
            rep2: None,
            rep_chroma: None,
            edi_mode: None,
            nn_size: None,
            nn_neurons: None,
            edi_qual: None,
            edi_max_d: None,
            chroma_edi: None,
            block_size: None,
            overlap: None,
            search: None,
            search_param: None,
            pel_search: None,
            chroma_motion: None,
            true_motion: None,
            lambda: None,
            lsad: None,
            p_new: None,
            p_level: None,
            global_motion: None,
            dct: None,
            sub_pel: None,
            sub_pel_interp: None,
            th_sad1: None,
            th_sad2: None,
            th_scd1: None,
            th_scd2: None,
            sharpness: None,
            s_mode: None,
            sl_mode: None,
            sl_rad: None,
            s_ovs: None,
            sv_thin: None,
            sbb: None,
            srch_clip_pp: None,
            noise_process: None,
            ez_denoise: None,
            ez_keep_grain: None,
            noise_preset: None,
            denoiser: None,
            fft_threads: None,
            denoise_mc: None,
            noise_tr: None,
            sigma: None,
            chroma_noise: None,
            show_noise: None,
            grain_restore: None,
            noise_restore: None,
            noise_deint: None,
            stabilize_noise: None,
            source_match: None,
            match_preset: None,
            match_edi: None,
            match_preset2: None,
            match_edi2: None,
            match_tr2: None,
            match_enhance: None,
            lossless: None,
            border: None,
            precise: None,
            force_tr: None,
            str: None,
            amp: None,
            fast_ma: None,
            e_search_p: None,
            refine_motion: None,
            opencl: None,
            device: None,
            ivtc_order: None,
            ivtc_mode: None,
            ivtc_cthresh: None,
            ivtc_mi: None,
            ivtc_block_x: None,
            ivtc_block_y: None,
            ivtc_cycle: None,
            ivtc_dupthresh: None,
            ivtc_scthresh: None,
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

#[allow(dead_code)]
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
        assert_eq!(params.fps_divisor, None);
        assert!(params.tff.is_none());
    }
}
