//! Noise reduction parameters for video processing.

use serde::{Deserialize, Serialize};

/// Noise reduction method options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum NoiseReductionMethod {
    #[default]
    SmDegrain,
    McTemporalDenoise,
    /// Didée's MCDegrainSharp: motion-compensated degrain that sharpens where
    /// the motion match is good and blurs where it is poor.
    McDegrainSharp,
    QtgmcBuiltin,
    /// Frequency-domain (DFT) denoiser. Very clean on fine, even grain.
    DfTtest,
    /// Classic 3D FFT spatio-temporal denoiser. Fast and aggressive.
    Fft3dFilter,
    /// Motion-adaptive temporal smoother. Very gentle — a finishing pass.
    TTempSmooth,
}

/// Noise reduction preset levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum NoiseReductionPreset {
    #[default]
    Off,
    Light,
    Moderate,
    Heavy,
    Custom,
}

/// Parameters for the noise reduction pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoiseReductionParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Preset level for simple mode.
    #[serde(default)]
    pub preset: NoiseReductionPreset,

    /// Which noise reduction method to use.
    #[serde(default)]
    pub method: NoiseReductionMethod,

    // --- SMDegrain Parameters ---

    /// Temporal radius (1-6). Higher = more temporal smoothing.
    #[serde(default = "default_sm_degrain_tr", rename = "smDegrainTr")]
    pub sm_degrain_tr: i32,

    /// SAD threshold for luma. Higher = more denoising.
    #[serde(default = "default_sm_degrain_th_sad", rename = "smDegrainThSAD")]
    pub sm_degrain_th_sad: i32,

    /// SAD threshold for chroma. Higher = more chroma denoising.
    #[serde(default = "default_sm_degrain_th_sadc", rename = "smDegrainThSADC")]
    pub sm_degrain_th_sadc: i32,

    /// Refine motion vectors for better accuracy.
    #[serde(default = "default_true", rename = "smDegrainRefine")]
    pub sm_degrain_refine: bool,

    /// Prefilter mode (0-4). Higher = stronger prefiltering.
    #[serde(default = "default_sm_degrain_prefilter", rename = "smDegrainPrefilter")]
    pub sm_degrain_prefilter: i32,

    // --- MCTemporalDenoise Parameters ---

    /// Denoise strength/sigma.
    #[serde(default = "default_mc_temporal_sigma")]
    pub mc_temporal_sigma: f64,

    /// Temporal radius for MCTemporalDenoise.
    #[serde(default = "default_mc_temporal_radius")]
    pub mc_temporal_radius: i32,

    /// Profile setting for MCTemporalDenoise.
    #[serde(default = "default_mc_temporal_profile")]
    pub mc_temporal_profile: String,

    // --- MCDegrainSharp Parameters ---

    /// Number of neighbouring frames on each side to degrain against (1-3).
    #[serde(default = "default_mcds_frames")]
    pub mcds_frames: i32,

    /// Blur strength for the poorly-matched areas (0.0-1.58).
    #[serde(default = "default_mcds_blur")]
    pub mcds_blur: f64,

    /// Sharpening strength for the well-matched areas (0.0-1.0).
    #[serde(default = "default_mcds_sharp")]
    pub mcds_sharp: f64,

    /// Run the motion search on the blurred clip, which finds steadier vectors
    /// on noisy sources.
    #[serde(default = "default_true")]
    pub mcds_blur_search: bool,

    /// Block SAD threshold. Low staggers the denoising, high brings ghosting.
    #[serde(default = "default_mcds_th_sad")]
    pub mcds_th_sad: i32,

    /// Planes to process (0 luma, 1 U, 2 V, 3 both chroma, 4 all).
    #[serde(default = "default_mcds_plane")]
    pub mcds_plane: i32,

    // --- QTGMC Built-in Parameters ---

    /// EZDenoise strength (0.0 to 5.0+).
    #[serde(default)]
    pub qtgmc_ez_denoise: f64,

    /// EZKeepGrain amount (0.0 to 1.0).
    #[serde(default)]
    pub qtgmc_ez_keep_grain: f64,

    // --- DFTTest Parameters ---

    /// Denoising strength. DFTTest's own default is 8.0.
    #[serde(default = "default_dfttest_sigma")]
    pub dfttest_sigma: f64,

    /// Temporal window in frames; must be odd. 1 makes it purely spatial.
    #[serde(default = "default_dfttest_tbsize")]
    pub dfttest_tbsize: i32,

    /// Spatial block size. Larger separates frequencies better but is slower.
    #[serde(default = "default_dfttest_sbsize")]
    pub dfttest_sbsize: i32,

    // --- FFT3DFilter Parameters ---

    /// Denoising strength.
    #[serde(default = "default_fft3d_sigma")]
    pub fft3d_sigma: f64,

    /// Temporal window in frames (1-5). 1 makes it purely spatial.
    #[serde(default = "default_fft3d_bt")]
    pub fft3d_bt: i32,

    /// Post-denoise sharpening (0.0-1.0), applied inside the same transform.
    #[serde(default)]
    pub fft3d_sharpen: f64,

    // --- TTempSmooth Parameters ---

    /// Temporal radius (1-7).
    #[serde(default = "default_ttemp_maxr")]
    pub ttemp_maxr: i32,

    /// Per-pixel difference threshold, above which a pixel is left alone.
    #[serde(default = "default_ttemp_thresh")]
    pub ttemp_thresh: i32,

    /// Motion-difference threshold. Must stay below [`Self::ttemp_thresh`].
    #[serde(default = "default_ttemp_mdiff")]
    pub ttemp_mdiff: i32,

    /// Weighting strength (1-8). Higher weights the current frame more.
    #[serde(default = "default_ttemp_strength")]
    pub ttemp_strength: i32,
}

fn default_sm_degrain_tr() -> i32 { 2 }
fn default_sm_degrain_th_sad() -> i32 { 300 }
fn default_sm_degrain_th_sadc() -> i32 { 150 }
fn default_true() -> bool { true }
fn default_sm_degrain_prefilter() -> i32 { 2 }
fn default_mc_temporal_sigma() -> f64 { 4.0 }
fn default_mc_temporal_radius() -> i32 { 2 }
fn default_mc_temporal_profile() -> String { "medium".to_string() }
fn default_mcds_frames() -> i32 { 2 }
fn default_mcds_blur() -> f64 { 0.3 }
fn default_mcds_sharp() -> f64 { 0.3 }
fn default_mcds_th_sad() -> i32 { 400 }
fn default_mcds_plane() -> i32 { 4 }
fn default_dfttest_sigma() -> f64 { 8.0 }
fn default_dfttest_tbsize() -> i32 { 3 }
fn default_dfttest_sbsize() -> i32 { 16 }
fn default_fft3d_sigma() -> f64 { 2.0 }
fn default_fft3d_bt() -> i32 { 3 }
fn default_ttemp_maxr() -> i32 { 3 }
fn default_ttemp_thresh() -> i32 { 4 }
fn default_ttemp_mdiff() -> i32 { 2 }
fn default_ttemp_strength() -> i32 { 2 }

impl Default for NoiseReductionParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            preset: NoiseReductionPreset::default(),
            method: NoiseReductionMethod::default(),
            sm_degrain_tr: default_sm_degrain_tr(),
            sm_degrain_th_sad: default_sm_degrain_th_sad(),
            sm_degrain_th_sadc: default_sm_degrain_th_sadc(),
            sm_degrain_refine: true,
            sm_degrain_prefilter: default_sm_degrain_prefilter(),
            mc_temporal_sigma: default_mc_temporal_sigma(),
            mc_temporal_radius: default_mc_temporal_radius(),
            mc_temporal_profile: default_mc_temporal_profile(),
            mcds_frames: default_mcds_frames(),
            mcds_blur: default_mcds_blur(),
            mcds_sharp: default_mcds_sharp(),
            mcds_blur_search: true,
            mcds_th_sad: default_mcds_th_sad(),
            mcds_plane: default_mcds_plane(),
            qtgmc_ez_denoise: 0.0,
            qtgmc_ez_keep_grain: 0.0,
            dfttest_sigma: default_dfttest_sigma(),
            dfttest_tbsize: default_dfttest_tbsize(),
            dfttest_sbsize: default_dfttest_sbsize(),
            fft3d_sigma: default_fft3d_sigma(),
            fft3d_bt: default_fft3d_bt(),
            fft3d_sharpen: 0.0,
            ttemp_maxr: default_ttemp_maxr(),
            ttemp_thresh: default_ttemp_thresh(),
            ttemp_mdiff: default_ttemp_mdiff(),
            ttemp_strength: default_ttemp_strength(),
        }
    }
}

impl NoiseReductionParameters {
    /// TCanny sigma for the blur step.
    ///
    /// The user-facing 0.0-1.58 range maps onto TCanny's sigma scale, matching
    /// the published MCDegrainSharp so a setting means the same thing here as in
    /// the scripts people copy their numbers from.
    pub fn mcds_blur_sigma(&self) -> f64 {
        self.mcds_blur * MCDS_SIGMA_MAX / MCDS_BLUR_MAX
    }

    /// TCanny sigma for the unsharp-mask step, from the 0.0-1.0 range.
    pub fn mcds_sharp_sigma(&self) -> f64 {
        self.mcds_sharp * MCDS_SIGMA_MAX
    }

    /// The `planes` list literal matching `mcds_plane`.
    ///
    /// mvtools takes a single `plane` selector but TCanny takes a list, so the
    /// two have to agree or the blur/sharpen references would cover different
    /// planes than the degrain does.
    pub fn mcds_planes_literal(&self) -> String {
        match self.mcds_plane {
            0 => "[0]".to_string(),
            1 => "[1]".to_string(),
            2 => "[2]".to_string(),
            3 => "[1, 2]".to_string(),
            _ => "[0, 1, 2]".to_string(),
        }
    }

    /// Degrain frames, clamped to the 1-3 mvtools provides.
    pub fn mcds_effective_frames(&self) -> i32 {
        self.mcds_frames.clamp(1, 3)
    }

    /// DFTTest's temporal window, forced odd.
    ///
    /// `tbsize` must be odd — the window is centred on the current frame. An
    /// even value is not rejected, it just makes DFTTest process a window that
    /// isn't centred, so the fix has to happen here rather than being left to
    /// the plugin.
    pub fn dfttest_effective_tbsize(&self) -> i32 {
        let clamped = self.dfttest_tbsize.clamp(1, 15);
        if clamped % 2 == 0 {
            clamped - 1
        } else {
            clamped
        }
    }

    /// FFT3DFilter's temporal window, clamped to the 1-5 it implements.
    pub fn fft3d_effective_bt(&self) -> i32 {
        self.fft3d_bt.clamp(1, 5)
    }

    /// TTempSmooth's `mdiff`, kept below `thresh`.
    ///
    /// The plugin requires `mdiff < thresh`; equal or greater is accepted but
    /// disables the motion protection the parameter exists for, so a wrong
    /// pairing smooths through motion instead of erroring.
    pub fn ttemp_effective_mdiff(&self) -> i32 {
        let thresh = self.ttemp_effective_thresh();
        self.ttemp_mdiff.clamp(0, (thresh - 1).max(0))
    }

    /// TTempSmooth's `thresh`, clamped to the 1-256 it accepts.
    pub fn ttemp_effective_thresh(&self) -> i32 {
        self.ttemp_thresh.clamp(1, 256)
    }

    /// TTempSmooth's temporal radius, clamped to the 1-7 it implements.
    pub fn ttemp_effective_maxr(&self) -> i32 {
        self.ttemp_maxr.clamp(1, 7)
    }
}

/// Top of TCanny's useful sigma range for these two steps.
const MCDS_SIGMA_MAX: f64 = 2.83;
/// Top of the user-facing blur range.
const MCDS_BLUR_MAX: f64 = 1.58;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_parameters() {
        let params = NoiseReductionParameters::default();
        assert!(!params.enabled);
        assert_eq!(params.preset, NoiseReductionPreset::Off);
        assert_eq!(params.method, NoiseReductionMethod::SmDegrain);
    }

    #[test]
    fn test_mcdegrainsharp_defaults() {
        let params = NoiseReductionParameters::default();
        assert_eq!(params.mcds_frames, 2);
        assert_eq!(params.mcds_th_sad, 400);
        assert_eq!(params.mcds_plane, 4);
        assert!(params.mcds_blur_search);
        // 0.3 of the way up each range.
        assert!((params.mcds_blur_sigma() - 0.537_341_772).abs() < 1e-6);
        assert!((params.mcds_sharp_sigma() - 0.849).abs() < 1e-9);
    }

    #[test]
    fn test_mcdegrainsharp_planes_literal_matches_plane_selector() {
        let with_plane = |plane: i32| NoiseReductionParameters {
            mcds_plane: plane,
            ..Default::default()
        };
        assert_eq!(with_plane(0).mcds_planes_literal(), "[0]");
        assert_eq!(with_plane(1).mcds_planes_literal(), "[1]");
        assert_eq!(with_plane(2).mcds_planes_literal(), "[2]");
        assert_eq!(with_plane(3).mcds_planes_literal(), "[1, 2]");
        assert_eq!(with_plane(4).mcds_planes_literal(), "[0, 1, 2]");
        // Anything unexpected falls back to all planes rather than none.
        assert_eq!(with_plane(9).mcds_planes_literal(), "[0, 1, 2]");
    }

    #[test]
    fn test_mcdegrainsharp_frames_are_clamped_to_mvtools_range() {
        let with_frames = |frames: i32| NoiseReductionParameters {
            mcds_frames: frames,
            ..Default::default()
        };
        assert_eq!(with_frames(0).mcds_effective_frames(), 1);
        assert_eq!(with_frames(2).mcds_effective_frames(), 2);
        assert_eq!(with_frames(7).mcds_effective_frames(), 3);
    }

    #[test]
    fn test_serialization() {
        let params = NoiseReductionParameters::default();
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"smDegrainTr\":2"));
        // The added methods' parameters have to reach the worker under the same
        // camelCase names the Dart side writes.
        assert!(json.contains("\"dfttestSigma\":8.0"));
        assert!(json.contains("\"fft3dSigma\":2.0"));
        assert!(json.contains("\"ttempMaxr\":3"));
    }

    #[test]
    fn test_method_wire_names_match_the_dart_enum() {
        // These strings are the wire format between the app and the worker. A
        // mismatch does not error — serde falls back to the default method — so
        // the job silently runs SMDegrain instead of what the user picked.
        let name = |m: NoiseReductionMethod| {
            serde_json::to_string(&NoiseReductionParameters {
                method: m,
                ..Default::default()
            })
            .unwrap()
        };
        for (method, expected) in [
            (NoiseReductionMethod::SmDegrain, "smDegrain"),
            (NoiseReductionMethod::McTemporalDenoise, "mcTemporalDenoise"),
            (NoiseReductionMethod::McDegrainSharp, "mcDegrainSharp"),
            (NoiseReductionMethod::QtgmcBuiltin, "qtgmcBuiltin"),
            (NoiseReductionMethod::DfTtest, "dfTtest"),
            (NoiseReductionMethod::Fft3dFilter, "fft3dFilter"),
            (NoiseReductionMethod::TTempSmooth, "tTempSmooth"),
        ] {
            let json = name(method);
            assert!(
                json.contains(&format!("\"method\":\"{expected}\"")),
                "expected method {expected:?} in {json}"
            );
        }
    }

    #[test]
    fn test_dfttest_tbsize_is_forced_odd() {
        // An even window isn't rejected by DFTTest, it just isn't centred on the
        // current frame — so it has to be fixed here.
        let with_tbsize = |tbsize: i32| NoiseReductionParameters {
            dfttest_tbsize: tbsize,
            ..Default::default()
        };
        assert_eq!(with_tbsize(1).dfttest_effective_tbsize(), 1);
        assert_eq!(with_tbsize(3).dfttest_effective_tbsize(), 3);
        assert_eq!(with_tbsize(4).dfttest_effective_tbsize(), 3);
        assert_eq!(with_tbsize(6).dfttest_effective_tbsize(), 5);
        assert_eq!(with_tbsize(0).dfttest_effective_tbsize(), 1);
        assert_eq!(with_tbsize(99).dfttest_effective_tbsize(), 15);
    }

    #[test]
    fn test_fft3d_bt_is_clamped() {
        let with_bt = |bt: i32| NoiseReductionParameters {
            fft3d_bt: bt,
            ..Default::default()
        };
        assert_eq!(with_bt(0).fft3d_effective_bt(), 1);
        assert_eq!(with_bt(3).fft3d_effective_bt(), 3);
        assert_eq!(with_bt(9).fft3d_effective_bt(), 5);
    }

    #[test]
    fn test_ttempsmooth_mdiff_stays_below_thresh() {
        // mdiff >= thresh is accepted by the plugin but disables the motion
        // protection the parameter exists for.
        let with = |thresh: i32, mdiff: i32| NoiseReductionParameters {
            ttemp_thresh: thresh,
            ttemp_mdiff: mdiff,
            ..Default::default()
        };
        assert_eq!(with(4, 2).ttemp_effective_mdiff(), 2);
        assert_eq!(with(4, 4).ttemp_effective_mdiff(), 3);
        assert_eq!(with(4, 9).ttemp_effective_mdiff(), 3);
        assert_eq!(with(1, 5).ttemp_effective_mdiff(), 0);
    }

    #[test]
    fn test_ttempsmooth_maxr_is_clamped() {
        let with_maxr = |maxr: i32| NoiseReductionParameters {
            ttemp_maxr: maxr,
            ..Default::default()
        };
        assert_eq!(with_maxr(0).ttemp_effective_maxr(), 1);
        assert_eq!(with_maxr(3).ttemp_effective_maxr(), 3);
        assert_eq!(with_maxr(12).ttemp_effective_maxr(), 7);
    }
}
