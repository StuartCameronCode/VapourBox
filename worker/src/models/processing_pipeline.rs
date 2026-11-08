//! Processing pipeline containing all video processing passes.

use serde::{Deserialize, Serialize};

use super::frame_rate_parameters::gcd;

use super::{
    AntiAliasParameters, GeometryParameters, GrainParameters, StabilizeParameters,
    ChromaDenoiseParameters, ChromaFixParameters, ColorCorrectionParameters, CropResizeParameters,
    DebandParameters, DeblockParameters, DehaloParameters, DeinterlaceMethod, DeScratchParameters,
    SpotLessParameters, SharpenParameters, NoiseReductionParameters, QTGMCParameters, FrameRateParameters, FrameRateMethod, NoiseReductionMethod, DeflickerParameters, EdgeRepairParameters, GhostRemovalParameters, DescaleParameters, FaceRestoreParameters,};

/// Minimum temporal context (frames on each side of the target) a windowed
/// preview decodes, regardless of which filters are enabled. Motion-compensated
/// filters (QTGMC) need neighbours; this floor preserves the old fixed 11-frame
/// (5-per-side) window so preview quality never regresses when a pipeline's
/// declared radius is small.
pub const MIN_PREVIEW_RADIUS: u32 = 5;

/// A span of *source* (input-side) frames, with whether the mapping that
/// produced it is frame-exact. `exact = false` means the span is the best
/// available estimate (data-dependent decimation, or a synthesized/interpolated
/// output frame with no single source origin) and a consumer should treat the
/// result as approximate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub struct SourceSpan {
    pub start: u64,
    pub end: u64,
    pub exact: bool,
}

/// Which output frame a preview of one source frame renders, and how the
/// preview script has to be set up to render exactly that frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreviewOutput {
    /// The frame to take from the preview script's output clip.
    pub local_index: u64,
    /// Copies of the window's first frame to put in front of the Frame Rate
    /// pass's input, so its retime runs in the same phase as the encode's.
    pub rate_pad: u64,
    /// Which of the source frame's output frames this is (from 0), and how
    /// many it has: 2 under a ×2 frame rate or double-rate deinterlacing.
    pub sub_frame: u64,
    pub sub_frames: u64,
    /// Made by interpolation rather than taken from a source frame.
    pub generated: bool,
}

/// How one pass relates its *input* clip to its *output* clip on the frame
/// timeline. Two operations matter to the rest of the system: a forward count
/// (the progress total) and an inverse window (which source frames produce a
/// given output frame, for preview/seek). See `ProcessingPipeline::output_count`
/// / `invert` for how these compose across a pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum FrameMap {
    /// Count and index unchanged. `radius` = temporal neighbours the filter
    /// reads to compute one frame (denoise, sharpen, single-rate QTGMC…).
    Identity { radius: u32 },

    /// Each input frame fans out to `factor` contiguous output frames.
    /// QTGMC FPSDivisor=1 → factor 2 (one output frame per field). Exact.
    Fanout { factor: u32, radius: u32 },

    /// Drop frames on a fixed cycle: keep `keep` of every `cycle`
    /// (VDecimate / IVTC, cycle 5 keep 4 → 30→24). The count is exact, but
    /// *which* frame is dropped is data-dependent, so the inverse is approximate.
    Decimate { cycle: u32, keep: u32 },

    /// Rational retime of the timeline (frame-rate conversion / interpolation).
    /// `synthesizes` = output frames may have no single source origin (motion
    /// interpolation) → inverse is a blended, inexact range.
    Retime { num: u32, den: u32, synthesizes: bool, radius: u32 },
}

#[allow(dead_code)]
impl FrameMap {
    /// Output frame count given an input frame count. (Progress / total.)
    pub fn output_count(&self, n_in: u64) -> u64 {
        match *self {
            FrameMap::Identity { .. } => n_in,
            FrameMap::Fanout { factor, .. } => n_in * factor as u64,
            FrameMap::Decimate { cycle, keep } => n_in * keep as u64 / cycle as u64,
            FrameMap::Retime { num, den, .. } => n_in * num as u64 / den as u64,
        }
    }

    /// How the map scales the frame rate, as num/den: a pass that emits more
    /// frames over the same duration raises the rate by the same factor.
    pub fn rate_factor(&self) -> (u64, u64) {
        match *self {
            FrameMap::Identity { .. } => (1, 1),
            FrameMap::Fanout { factor, .. } => (factor as u64, 1),
            FrameMap::Decimate { cycle, keep } => (keep as u64, cycle as u64),
            FrameMap::Retime { num, den, .. } => (num as u64, den as u64),
        }
    }

    /// Map an output frame index back to the input-side source frames that
    /// produce it. (Preview / seek.)
    pub fn inverse(&self, m: u64) -> SourceSpan {
        match *self {
            FrameMap::Identity { .. } => SourceSpan { start: m, end: m, exact: true },

            // output frames [k*factor .. k*factor+factor) all come from source k
            FrameMap::Fanout { factor, .. } => {
                let s = m / factor as u64;
                SourceSpan { start: s, end: s, exact: true }
            }

            // best-effort: assume kept frames are evenly spaced within each cycle.
            // Off by ≤1 from the true kept frame, and the dropped one is a
            // near-duplicate, so visually negligible — but mark it inexact.
            FrameMap::Decimate { cycle, keep } => {
                let c = m / keep as u64;
                let i = m % keep as u64;
                let s = c * cycle as u64 + i * cycle as u64 / keep as u64;
                SourceSpan { start: s, end: s, exact: false }
            }

            FrameMap::Retime { num, den, synthesizes, .. } => {
                let lo = m * den as u64 / num as u64;
                let hi = (m * den as u64 + num as u64 - 1) / num as u64; // ceil
                SourceSpan { start: lo, end: hi.max(lo), exact: !synthesizes }
            }
        }
    }

    /// Temporal neighbours (each side) the filter reads to compute one frame.
    pub fn radius(&self) -> u32 {
        match *self {
            FrameMap::Identity { radius }
            | FrameMap::Fanout { radius, .. }
            | FrameMap::Retime { radius, .. } => radius,
            FrameMap::Decimate { .. } => 0,
        }
    }
}

/// Defines the type of each processing pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(dead_code)]
pub enum PassType {
    Deinterlace,
    DeScratch,
    SpotLess,
    /// Undo a studio's upscale and upscale again properly.
    Descale,
    NoiseReduction,
    ChromaDenoise,
    Dehalo,
    Deblock,
    Deband,
    Sharpen,
    AntiAlias,
    Stabilize,
    Geometry,
    Grain,
    /// Remove brightness pulsing between frames.
    Deflicker,
    /// Remove the displaced echo RF and cable distribution leave behind.
    GhostRemoval,
    /// Rebuild the dirty rows and columns at the frame border.
    EdgeRepair,
    /// Frame-rate conversion (standards conversion, not smoothing).
    FrameRate,
    ColorCorrection,
    ChromaFixes,
    CropResize,
    /// Restore faces with a neural network (an add-on).
    FaceRestore,
}

#[allow(dead_code)]
impl PassType {
    /// Get display name for the pass.
    pub fn display_name(&self) -> &'static str {
        match self {
            PassType::Deinterlace => "Deinterlace",
            PassType::DeScratch => "DeScratch",
            PassType::SpotLess => "SpotLess",
            PassType::NoiseReduction => "Noise Reduction",
            PassType::ChromaDenoise => "Chroma Denoise",
            PassType::Dehalo => "Dehalo",
            PassType::Deblock => "Deblock",
            PassType::Deband => "Deband",
            PassType::Sharpen => "Sharpen",
            PassType::AntiAlias => "Anti-Aliasing",
            PassType::Stabilize => "Stabilize",
            PassType::Geometry => "Rotate / Flip",
            PassType::Grain => "Film Grain",
            PassType::Deflicker => "Deflicker",
            PassType::GhostRemoval => "Ghost Removal",
            PassType::Descale => "Descale",
            PassType::EdgeRepair => "Edge Repair",
            PassType::FrameRate => "Frame Rate",
            PassType::ColorCorrection => "Color Correction",
            PassType::ChromaFixes => "Chroma Fixes",
            PassType::CropResize => "Crop / Resize",
            PassType::FaceRestore => "Face Restoration",
        }
    }

    /// Get description for the pass.
    pub fn description(&self) -> &'static str {
        match self {
            PassType::Deinterlace => "Deinterlace (QTGMC) or inverse telecine (IVTC)",
            PassType::DeScratch => "Remove vertical scratches from scanned film",
            PassType::SpotLess => "Remove dust, dirt, and temporal spots from film",
            PassType::NoiseReduction => "Reduce video noise and grain",
            PassType::ChromaDenoise => "Remove blotchy colour noise (CCD)",
            PassType::Dehalo => "Remove halo artifacts around edges",
            PassType::Deblock => "Remove compression block artifacts",
            PassType::Deband => "Remove color banding from gradients",
            PassType::Sharpen => "Sharpen edges and enhance detail",
            PassType::AntiAlias => "Smooth stair-stepping on diagonal edges",
            PassType::Stabilize => "Remove shake and weave from the picture",
            PassType::Geometry => "Rotate or mirror the picture",
            PassType::Grain => "Add film grain back after denoising",
            PassType::Deflicker => "Even out brightness pulsing between frames",
            PassType::GhostRemoval => "Remove the displaced echo RF and cable distribution leave behind",
            PassType::Descale => "Undo a studio's upscale, then upscale again cleanly",
            PassType::EdgeRepair => "Rebuild the dirty rows and columns at the frame border",
            PassType::FrameRate => "Convert between PAL and NTSC, or to any frame rate",
            PassType::ColorCorrection => "Adjust brightness, contrast, and colors",
            PassType::ChromaFixes => "Fix chroma bleeding and crawl artifacts",
            PassType::CropResize => "Crop borders and resize output",
            PassType::FaceRestore => "Restore detail in blurry, low-resolution faces with AI",
        }
    }
}

/// Container for all processing pass parameters.
/// Defines the complete video processing pipeline.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessingPipeline {
    /// Deinterlacing pass parameters (QTGMC).
    #[serde(default)]
    pub deinterlace: QTGMCParameters,

    /// DeScratch pass parameters (scratch removal).
    #[serde(default)]
    pub descratch: DeScratchParameters,

    /// SpotLess pass parameters (spot/dirt removal).
    #[serde(default)]
    pub spotless: SpotLessParameters,

    /// Noise reduction pass parameters.
    #[serde(default)]
    pub noise_reduction: NoiseReductionParameters,

    /// Chroma denoise pass parameters (CCD).
    #[serde(default)]
    pub chroma_denoise: ChromaDenoiseParameters,

    /// Dehalo pass parameters.
    #[serde(default)]
    pub dehalo: DehaloParameters,

    /// Deblock pass parameters.
    #[serde(default)]
    pub deblock: DeblockParameters,

    /// Deband pass parameters (f3kdb).
    #[serde(default)]
    pub deband: DebandParameters,

    /// Sharpening pass parameters.
    #[serde(default)]
    pub sharpen: SharpenParameters,

    /// Anti-aliasing pass parameters.
    #[serde(default)]
    pub anti_alias: AntiAliasParameters,

    /// Stabilisation pass parameters.
    #[serde(default)]
    pub stabilize: StabilizeParameters,

    /// Rotate/flip pass parameters.
    #[serde(default)]
    pub geometry: GeometryParameters,

    /// Film grain pass parameters.
    #[serde(default)]
    pub grain: GrainParameters,

    /// Brightness flicker removal. Off by default.
    #[serde(default)]
    pub deflicker: DeflickerParameters,

    #[serde(default)]
    pub ghost_removal: GhostRemovalParameters,

    #[serde(default)]
    pub descale: DescaleParameters,

    #[serde(default)]
    pub edge_repair: EdgeRepairParameters,

    /// Frame-rate conversion. Off by default.
    #[serde(default)]
    pub frame_rate: FrameRateParameters,

    /// Color correction pass parameters.
    #[serde(default)]
    pub color_correction: ColorCorrectionParameters,

    /// Chroma fix pass parameters.
    #[serde(default)]
    pub chroma_fixes: ChromaFixParameters,

    /// Crop and resize pass parameters.
    #[serde(default)]
    pub crop_resize: CropResizeParameters,

    /// Face restoration (RestoreFormer++ / GFPGAN / CodeFormer). Off by default.
    #[serde(default)]
    pub face_restore: FaceRestoreParameters,
}

impl Default for ProcessingPipeline {
    fn default() -> Self {
        Self {
            deinterlace: QTGMCParameters::default(),
            descratch: DeScratchParameters::default(),
            spotless: SpotLessParameters::default(),
            noise_reduction: NoiseReductionParameters::default(),
            chroma_denoise: ChromaDenoiseParameters::default(),
            dehalo: DehaloParameters::default(),
            deblock: DeblockParameters::default(),
            deband: DebandParameters::default(),
            sharpen: SharpenParameters::default(),
            anti_alias: AntiAliasParameters::default(),
            stabilize: StabilizeParameters::default(),
            geometry: GeometryParameters::default(),
            grain: GrainParameters::default(),
            deflicker: DeflickerParameters::default(),
            ghost_removal: GhostRemovalParameters::default(),
            descale: DescaleParameters::default(),
            edge_repair: EdgeRepairParameters::default(),
            frame_rate: FrameRateParameters::default(),
            color_correction: ColorCorrectionParameters::default(),
            chroma_fixes: ChromaFixParameters::default(),
            crop_resize: CropResizeParameters::default(),
            face_restore: FaceRestoreParameters::default(),
        }
    }
}

#[allow(dead_code)]
impl ProcessingPipeline {
    /// Create a pipeline from legacy QTGMC-only parameters.
    pub fn from_legacy(qtgmc_params: &QTGMCParameters) -> Self {
        Self {
            deinterlace: qtgmc_params.clone(),
            descratch: DeScratchParameters { enabled: false, ..Default::default() },
            spotless: SpotLessParameters { enabled: false, ..Default::default() },
            noise_reduction: NoiseReductionParameters { enabled: false, ..Default::default() },
            chroma_denoise: ChromaDenoiseParameters { enabled: false, ..Default::default() },
            dehalo: DehaloParameters { enabled: false, ..Default::default() },
            deblock: DeblockParameters { enabled: false, ..Default::default() },
            deband: DebandParameters { enabled: false, ..Default::default() },
            sharpen: SharpenParameters { enabled: false, ..Default::default() },
            anti_alias: AntiAliasParameters { enabled: false, ..Default::default() },
            stabilize: StabilizeParameters { enabled: false, ..Default::default() },
            geometry: GeometryParameters { enabled: false, ..Default::default() },
            grain: GrainParameters { enabled: false, ..Default::default() },
            deflicker: DeflickerParameters { enabled: false, ..Default::default() },
            ghost_removal: GhostRemovalParameters { enabled: false, ..Default::default() },
            descale: DescaleParameters::default(),
            edge_repair: EdgeRepairParameters { enabled: false, ..Default::default() },
            frame_rate: FrameRateParameters { enabled: false, ..Default::default() },
            color_correction: ColorCorrectionParameters { enabled: false, ..Default::default() },
            chroma_fixes: ChromaFixParameters { enabled: false, ..Default::default() },
            crop_resize: CropResizeParameters { enabled: false, ..Default::default() },
            face_restore: FaceRestoreParameters::default(),
        }
    }

    /// Get the ordered list of enabled passes.
    pub fn enabled_passes(&self) -> Vec<PassType> {
        let mut passes = Vec::new();

        // Order: deinterlace, damage, noise, dehalo, deblock, deband, anti-alias,
        // chroma, color, stabilize, rotate, crop + resize, face restoration, then
        // sharpen, grain,
        // frame rate.
        if self.deinterlace_enabled() {
            passes.push(PassType::Deinterlace);
        }
        // Edge repair must precede every spatial filter, or denoising and
        // sharpening smear the bad rows inward — and it must precede the resize,
        // or resampling spreads them. After deinterlacing rather than first, so
        // it works on progressive output when deinterlacing is on.
        if self.edge_repair.has_effect() {
            passes.push(PassType::EdgeRepair);
        }
        // Ghosting is a per-line echo in luma; removing it before the denoise
        // stops the denoiser averaging the echo into the picture.
        if self.ghost_removal.has_effect() {
            passes.push(PassType::GhostRemoval);
        }
        // Deflicker must follow deinterlacing — field-doubled frames break
        // every temporal comparison it makes — and precede the dirt and
        // denoise passes, which all assume a stable exposure.
        if self.deflicker.enabled {
            passes.push(PassType::Deflicker);
        }
        if self.descratch.enabled {
            passes.push(PassType::DeScratch);
        }
        if self.spotless.enabled {
            passes.push(PassType::SpotLess);
        }
        // Descale needs the studio's upscale exactly as it was: before any
        // denoise, deblock or sharpen changes the picture it inverts.
        if self.descale.enabled {
            passes.push(PassType::Descale);
        }
        if self.noise_reduction.enabled {
            passes.push(PassType::NoiseReduction);
        }
        // Chroma noise is removed with the rest of the denoising, before the
        // deband/sharpen steps that would otherwise amplify it.
        if self.chroma_denoise.enabled {
            passes.push(PassType::ChromaDenoise);
        }
        if self.dehalo.enabled {
            passes.push(PassType::Dehalo);
        }
        if self.deblock.enabled {
            passes.push(PassType::Deblock);
        }
        if self.deband.enabled {
            passes.push(PassType::Deband);
        }
        // Anti-aliasing before sharpening: sharpening stair-stepped edges
        // makes the stepping more visible, not less.
        if self.anti_alias.enabled {
            passes.push(PassType::AntiAlias);
        }
        if self.chroma_fixes.enabled {
            passes.push(PassType::ChromaFixes);
        }
        if self.color_correction.enabled {
            passes.push(PassType::ColorCorrection);
        }
        // Stabilisation shifts the picture within the frame, so it runs last
        // before framing — that way a crop can remove the edges it exposes.
        if self.stabilize.enabled {
            passes.push(PassType::Stabilize);
        }
        // Rotation swaps width and height, so it has to settle before any
        // framing decision is made. It also must follow deinterlacing: fields
        // run horizontally, so turning a still-interlaced clip shears them.
        if self.geometry.has_effect() {
            passes.push(PassType::Geometry);
        }
        // Crop and resize are one pass and run together, crop first. The crop
        // used to run ahead of everything else, which meant it could not
        // remove the edges Stabilize exposes (issue #109).
        if self.crop_resize.enabled
            && (self.crop_resize.crop_enabled || self.crop_resize.resize_enabled)
        {
            passes.push(PassType::CropResize);
        }

        // Faces are restored at the delivered resolution, after the resize:
        // an upscale gives the restorer more pixels per face, and a downscale
        // after it would soften the detail it recovered. Before sharpening,
        // which would otherwise sharpen the VHS face only to have it replaced,
        // and before grain, which puts texture back over the smooth result.
        if self.face_restore.enabled {
            passes.push(PassType::FaceRestore);
        }

        // Sharpening follows the resize (issue #109), so it works on the
        // delivered pixels: sharpened earlier, a downscale softens the edges
        // again and an upscale enlarges the halos. It still follows
        // anti-aliasing, and precedes the grain it would otherwise exaggerate.
        if self.sharpen.enabled {
            passes.push(PassType::Sharpen);
        }

        // Grain goes last of the video passes. Added before the resize it is
        // resampled away; before the deband it is smoothed away. Measured, and
        // the reason this pass sits after framing rather than with the other
        // enhancement steps.
        if self.grain.has_effect() {
            passes.push(PassType::Grain);
        }

        // Frame rate conversion is genuinely last. It resamples the timeline, so
        // running it before anything temporal would have every later pass work
        // on invented frames rather than photographed ones.
        if self.frame_rate.enabled {
            passes.push(PassType::FrameRate);
        }

        passes
    }

    /// Check if deinterlacing is enabled.
    fn deinterlace_enabled(&self) -> bool {
        self.deinterlace.enabled
    }

    /// Get count of enabled passes.
    pub fn enabled_pass_count(&self) -> usize {
        let mut count = 0;
        if self.deinterlace.enabled { count += 1; }
        if self.descratch.enabled { count += 1; }
        if self.spotless.enabled { count += 1; }
        if self.noise_reduction.enabled { count += 1; }
        if self.dehalo.enabled { count += 1; }
        if self.deblock.enabled { count += 1; }
        if self.deband.enabled { count += 1; }
        if self.sharpen.enabled { count += 1; }
        if self.color_correction.enabled { count += 1; }
        if self.chroma_fixes.enabled { count += 1; }
        if self.crop_resize.enabled { count += 1; }
        if self.face_restore.enabled { count += 1; }
        count
    }

    /// Whether this pipeline interpolates with RIFE, which needs a GPU probe
    /// before its script can be generated.
    pub fn uses_rife(&self) -> bool {
        self.frame_rate.enabled && self.frame_rate.method == FrameRateMethod::Rife
    }

    /// Whether this pipeline upscales with a neural model (Real-ESRGAN /
    /// Real-CUGAN), which needs a GPU probe before its script can be generated.
    pub fn uses_ai_upscale(&self) -> bool {
        self.crop_resize.uses_ai_upscale()
    }

    /// Whether that model is AnimeJaNai, whose models are an add-on that must
    /// also be installed.
    pub fn uses_animejanai(&self) -> bool {
        self.crop_resize.uses_animejanai()
    }

    /// The manifest add-ons (`app/assets/addons/`, see `addons.rs`) each
    /// enabled feature of this pipeline needs. `ScriptGenerator` refuses the
    /// job, naming them and Settings → Add-ons, unless all are installed, and
    /// emits the `{{#AI_RUNTIME}}` block when any of them needs the AI runtime.
    ///
    /// A pass that runs a model from an add-on adds an entry here when
    /// enabled (a model add-on whose manifest `requires` `ai-runtime`).
    pub fn required_addons(&self) -> Vec<crate::addons::AddonNeed> {
        let mut needs = Vec::new();
        if self.face_restore.enabled {
            needs.push(crate::addons::AddonNeed {
                feature: "Face restoration",
                ids: self.face_restore.required_addons(),
            });
        }
        needs
    }

    /// Whether this pipeline denoises with KNLMeans, which needs a working
    /// OpenCL device before its script can be generated.
    pub fn uses_knlm(&self) -> bool {
        self.noise_reduction.enabled
            && self.noise_reduction.method == NoiseReductionMethod::KnlMeans
    }

    /// The frame-timeline map each enabled pass imposes, in application order.
    /// Only the deinterlace pass changes the count today; the rest are identity
    /// (with a small temporal radius for context-sensitive filters).
    pub fn frame_maps(&self) -> Vec<FrameMap> {
        self.enabled_passes()
            .into_iter()
            .map(|p| self.frame_map_for(p))
            .collect()
    }

    /// The `FrameMap` for a single pass, derived from its parameters.
    fn frame_map_for(&self, pass: PassType) -> FrameMap {
        match pass {
            PassType::Deinterlace => self.deinterlace_frame_map(),
            // Temporal filters need neighbours for a correct windowed preview,
            // but don't change the frame count.
            PassType::NoiseReduction => FrameMap::Identity {
                radius: self.noise_reduction.temporal_radius(),
            },
            // CCD is spatial at temporal_radius 0, temporal above it.
            PassType::ChromaDenoise => FrameMap::Identity {
                radius: self.chroma_denoise.radius(),
            },
            PassType::SpotLess => FrameMap::Identity { radius: 2 },
            PassType::DeScratch => FrameMap::Identity { radius: 1 },
            PassType::Deflicker => FrameMap::Identity { radius: self.deflicker.radius() },
            PassType::EdgeRepair => FrameMap::Identity { radius: 0 },
            PassType::GhostRemoval => FrameMap::Identity { radius: 0 },
            PassType::Descale => FrameMap::Identity { radius: 0 },
            // Restored faces are blended with their neighbours', whose landmarks
            // are smoothed over theirs: twice the smoothing radius.
            PassType::FaceRestore => FrameMap::Identity { radius: self.face_restore.frames_read_either_side() },
            // The one pass that emits a Retime. The ratio is known up front, so
            // the count is exact; `synthesizes` is true only for the
            // interpolating method, where an output frame has no single source.
            PassType::FrameRate => self.frame_rate_frame_map(),
            // Purely spatial passes.
            _ => FrameMap::Identity { radius: 0 },
        }
    }

    /// Frame mapping for the frame rate pass.
    ///
    /// Needs the source rate, which `VideoJob::effective_pipeline` fills in;
    /// a pipeline built without one reports the identity. Reporting a wrong
    /// fixed ratio here would make the progress total and the preview seek
    /// disagree with the output.
    fn frame_rate_frame_map(&self) -> FrameMap {
        // Without a source rate we cannot know the ratio, and a wrong fixed
        // ratio is worse than none: it would make the progress total and the
        // preview index disagree with what the encoder actually receives.
        match self.frame_rate_input_fps().and_then(|(n, d)| self.frame_rate.ratio_against(n, d)) {
            Some((num, den)) => FrameMap::Retime {
                num,
                den,
                // Interpolated frames have no single source origin, so the
                // preview's inverse mapping is a blended range, not a frame.
                synthesizes: self.frame_rate.method.synthesizes(),
                radius: 1,
            },
            None => FrameMap::Identity { radius: 1 },
        }
    }

    /// The rate the frame rate pass converts *from*: the source rate as
    /// changed by every pass ahead of it. Double-rate deinterlacing hands it
    /// 50p from a 25i source, and its target is absolute, so the ratio has to
    /// be taken against that, not against the source.
    fn frame_rate_input_fps(&self) -> Option<(u32, u32)> {
        let (mut num, mut den) = (
            self.frame_rate.source_fps_num? as u64,
            self.frame_rate.source_fps_den? as u64,
        );
        for pass in self.enabled_passes() {
            if pass == PassType::FrameRate {
                break;
            }
            let (f_num, f_den) = self.frame_map_for(pass).rate_factor();
            num *= f_num;
            den *= f_den;
            let g = gcd(num, den);
            num /= g;
            den /= g;
        }
        Some((u32::try_from(num).ok()?, u32::try_from(den).ok()?))
    }

    /// Frame mapping for the deinterlace pass. QTGMC double-rate (FPSDivisor=1,
    /// the default when unset) doubles the frame count; IVTC/soft-telecine
    /// decimate on a cycle. Mirrors the count logic the progress reporter and
    /// VapourSynth pipeline actually produce.
    fn deinterlace_frame_map(&self) -> FrameMap {
        let d = &self.deinterlace;
        match d.method {
            DeinterlaceMethod::Qtgmc => {
                if d.fps_divisor.unwrap_or(1) == 1 {
                    FrameMap::Fanout { factor: 2, radius: 3 }
                } else {
                    FrameMap::Identity { radius: 3 }
                }
            }
            // Bwdif's field argument decides this exactly as QTGMC's
            // fps_divisor does: double rate emits one frame per field.
            // Radius 1 rather than 3 — it reads one neighbour each side, not
            // QTGMC's temporal window.
            DeinterlaceMethod::Bwdif => {
                if d.fps_divisor.unwrap_or(1) == 1 {
                    FrameMap::Fanout { factor: 2, radius: 1 }
                } else {
                    FrameMap::Identity { radius: 1 }
                }
            }
            DeinterlaceMethod::Ivtc | DeinterlaceMethod::SoftTelecine => {
                let cycle = d.ivtc_cycle.unwrap_or(5).max(2) as u32;
                FrameMap::Decimate { cycle, keep: cycle - 1 }
            }
        }
    }

    /// Total output frame count for a given source frame count, composing every
    /// enabled pass's forward map. Replaces ad-hoc double-rate / IVTC scaling.
    pub fn output_count(&self, source_frames: u64) -> u64 {
        self.frame_maps()
            .iter()
            .fold(source_frames, |n, m| m.output_count(n))
    }

    /// Map a final output frame index back to the source frame span that
    /// produces it, composing every enabled pass's inverse in reverse order.
    pub fn invert(&self, output_frame: u64) -> SourceSpan {
        self.frame_maps().iter().rev().fold(
            SourceSpan { start: output_frame, end: output_frame, exact: true },
            |span, m| {
                let a = m.inverse(span.start);
                let b = m.inverse(span.end);
                SourceSpan {
                    start: a.start,
                    end: b.end.max(a.start),
                    exact: span.exact && a.exact && b.exact,
                }
            },
        )
    }

    /// The output frame a preview of source frame `target` renders, given the
    /// window starts at source frame `first` and the encode at `origin` (its
    /// in-point). `sub_frame` picks among the output frames that fall in
    /// `target`'s time span, `[target, target + 1)`, and is clamped to them.
    ///
    /// A retime's phase depends on where its clip starts: 24 → 60 puts output
    /// frames at 0, 0.4, 0.8, … source frames from the start. The preview's
    /// clip starts at `first`, so left alone it generates frames at different
    /// moments than the encode does whenever `first` is not a whole number of
    /// the ratio's periods from `origin` (issue #129). `rate_pad` frames in
    /// front of the pass move its start back to such a point. They are copies
    /// of a frame that has already been through every other pass, and the one
    /// requested frame only reads its own two neighbours, so they cost nothing.
    ///
    /// Without a frame rate pass, the frame's outputs are its share of the
    /// local window's count, as before (double-rate deinterlacing gives two).
    /// A source frame a decimation or down-conversion leaves no output of
    /// its own shows the output just before it.
    pub fn preview_output(&self, origin: u64, first: u64, target: u64, sub_frame: u64) -> PreviewOutput {
        let local = target.saturating_sub(first);
        let passes = self.enabled_passes();
        let retime = passes.iter().position(|p| *p == PassType::FrameRate).and_then(|i| {
            match self.frame_map_for(passes[i]) {
                FrameMap::Retime { num, den, synthesizes, .. } => Some((i, num as u64, den as u64, synthesizes)),
                _ => None,
            }
        });

        let Some((at, num, den, synthesizes)) = retime else {
            let lo = self.output_count(local);
            let n = self.output_count(local + 1).saturating_sub(lo).max(1);
            let k = sub_frame.min(n - 1);
            return PreviewOutput { local_index: lo + k, rate_pad: 0, sub_frame: k, sub_frames: n, generated: false };
        };

        // Frame counts at the retime's input, from the encode's first frame.
        // A window before the in-point is not in the encode at all; its phase
        // is taken from the start of the source instead.
        let before = |n: u64| passes[..at].iter().fold(n, |n, p| self.frame_map_for(*p).output_count(n));
        let start = before(first.checked_sub(origin).unwrap_or(first));
        let pad = start % den;
        let (p, p_next) = (start + before(local), start + before(local + 1));
        let ceil = |x: u64| (x * num).div_ceil(den);
        let (lo, hi) = (ceil(p), ceil(p_next));
        let (m, n, k) = if hi > lo {
            let k = sub_frame.min(hi - lo - 1);
            (lo + k, hi - lo, k)
        } else {
            (p * num / den, 1, 0)
        };
        PreviewOutput {
            local_index: m - (start - pad) * num / den,
            rate_pad: pad,
            sub_frame: k,
            sub_frames: n,
            generated: synthesizes && (m * den) % num != 0,
        }
    }

    /// Conservative temporal padding (frames each side) a windowed preview
    /// should decode so every enabled filter has the context it needs. Floored
    /// at `MIN_PREVIEW_RADIUS` so motion-compensated filters never starve.
    pub fn total_radius(&self) -> u32 {
        let declared: u32 = self.frame_maps().iter().map(|m| m.radius()).sum();
        declared.max(MIN_PREVIEW_RADIUS)
    }

    /// Check if a specific pass is enabled.
    pub fn is_pass_enabled(&self, pass: PassType) -> bool {
        match pass {
            PassType::Deinterlace => self.deinterlace_enabled(),
            PassType::DeScratch => self.descratch.enabled,
            PassType::SpotLess => self.spotless.enabled,
            PassType::NoiseReduction => self.noise_reduction.enabled,
            PassType::ChromaDenoise => self.chroma_denoise.enabled,
            PassType::Dehalo => self.dehalo.enabled,
            PassType::Deblock => self.deblock.enabled,
            PassType::Deband => self.deband.enabled,
            PassType::Sharpen => self.sharpen.enabled,
            PassType::AntiAlias => self.anti_alias.enabled,
            PassType::Stabilize => self.stabilize.enabled,
            PassType::Geometry => self.geometry.has_effect(),
            PassType::Grain => self.grain.has_effect(),
            PassType::Deflicker => self.deflicker.enabled,
            PassType::GhostRemoval => self.ghost_removal.has_effect(),
            PassType::Descale => self.descale.enabled,
            PassType::EdgeRepair => self.edge_repair.has_effect(),
            PassType::FrameRate => self.frame_rate.enabled,
            PassType::ColorCorrection => self.color_correction.enabled,
            PassType::ChromaFixes => self.chroma_fixes.enabled,
            PassType::CropResize => self.crop_resize.enabled,
            PassType::FaceRestore => self.face_restore.enabled,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn retimed(target: (u32, u32), src: (u32, u32), method: FrameRateMethod, deinterlace: bool) -> ProcessingPipeline {
        ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: deinterlace, ..Default::default() },
            frame_rate: FrameRateParameters {
                enabled: true,
                target: crate::models::FrameRateTarget::Custom,
                custom_fps: target.0 as f64 / target.1 as f64,
                method,
                source_fps_num: Some(src.0),
                source_fps_den: Some(src.1),
                ..Default::default()
            },
            ..Default::default()
        }
    }

    /// The frame the preview renders, as an encode output index: what the
    /// preview script's clip index stands for once its padding is counted.
    fn encode_index(p: &ProcessingPipeline, origin: u64, first: u64, out: PreviewOutput) -> u64 {
        // Every case here retimes straight from the source.
        let (num, den) = match p.frame_maps().last() {
            Some(FrameMap::Retime { num, den, .. }) => (*num as u64, *den as u64),
            _ => unreachable!(),
        };
        let start = first - origin;
        out.local_index + (start - out.rate_pad) * num / den
    }

    #[test]
    fn a_preview_steps_through_every_output_frame_in_the_encodes_phase() {
        // 24 -> 60 is 5/2: every pair of source frames has five outputs, at
        // 0, 0.4, 0.8, 1.2, 1.6. Whatever the window, the frames a source
        // frame previews are exactly the encode's frames in its time span.
        let p = retimed((60, 1), (24, 1), FrameRateMethod::Rife, false);
        for origin in [0u64, 3] {
            for target in origin..origin + 12 {
                for first in target.saturating_sub(4).max(origin)..=target {
                    let mut seen = vec![];
                    for k in 0..4 {
                        let out = p.preview_output(origin, first, target, k);
                        seen.push(encode_index(&p, origin, first, out));
                    }
                    seen.dedup();
                    let t = (target - origin) as f64;
                    let want: Vec<u64> = (0..200u64)
                        .filter(|m| { let pos = *m as f64 * 0.4; pos >= t - 1e-9 && pos < t + 1.0 - 1e-9 })
                        .collect();
                    assert_eq!(seen, want, "origin {origin}, first {first}, target {target}");
                }
            }
        }
    }

    #[test]
    fn a_preview_reports_which_frames_are_generated() {
        let p = retimed((60, 1), (24, 1), FrameRateMethod::Rife, false);
        // Source frame 2 spans outputs 5, 6 and 7, at 2.0 (real), 2.4 and 2.8.
        let real = p.preview_output(0, 1, 2, 0);
        assert_eq!((real.sub_frame, real.sub_frames, real.generated), (0, 3, false));
        let made = p.preview_output(0, 1, 2, 1);
        assert_eq!((made.sub_frame, made.generated), (1, true));
        let last = p.preview_output(0, 1, 2, 2);
        assert_eq!((last.sub_frame, last.generated), (2, true));
        // Asking past the end clamps to the last.
        assert_eq!(p.preview_output(0, 1, 2, 9), last);
        // Source frame 3 (3.2, 3.6) has no real frame of its own.
        let odd = p.preview_output(0, 1, 3, 0);
        assert_eq!((odd.sub_frames, odd.generated), (2, true));
        // Repeating frames generates nothing.
        let dup = retimed((60, 1), (24, 1), FrameRateMethod::Duplicate, false);
        assert!(!dup.preview_output(0, 1, 2, 1).generated);
    }

    #[test]
    fn a_doubling_needs_no_padding_and_keeps_the_old_index() {
        // ×2: what the preview has always shown (output 2·local) is sub-frame
        // 0; sub-frame 1 is the frame RIFE makes between.
        let p = retimed((50, 1), (25, 1), FrameRateMethod::Rife, false);
        let out = p.preview_output(0, 7, 10, 0);
        assert_eq!((out.local_index, out.rate_pad, out.generated), (6, 0, false));
        let out = p.preview_output(0, 7, 10, 1);
        assert_eq!((out.local_index, out.generated), (7, true));
    }

    #[test]
    fn padding_aligns_the_window_to_the_ratio() {
        // 24 -> 60: period 2 source frames. A window starting at 7 is half a
        // period out, so one frame of padding.
        let p = retimed((60, 1), (24, 1), FrameRateMethod::FlowFps, false);
        assert_eq!(p.preview_output(0, 7, 10, 0).rate_pad, 1);
        assert_eq!(p.preview_output(0, 8, 10, 0).rate_pad, 0);
        // From an in-point at 3, 7 is 4 frames in: aligned.
        assert_eq!(p.preview_output(3, 7, 10, 0).rate_pad, 0);
    }

    #[test]
    fn a_frame_rate_after_double_rate_deinterlacing_counts_fields() {
        // 25i doubled to 50p, then to 60: one source frame spans two field
        // frames, so 60/25 = 2.4 outputs, two or three per source frame.
        let p = retimed((60, 1), (25, 1), FrameRateMethod::Rife, true);
        let n: Vec<u64> = (0..5).map(|t| p.preview_output(0, t.max(1) - 1, t, 0).sub_frames).collect();
        assert_eq!(n.iter().sum::<u64>(), 12, "{n:?}");
    }

    #[test]
    fn without_a_retime_double_rate_deinterlacing_has_two_frames() {
        let p = ProcessingPipeline::default();
        let out = p.preview_output(0, 7, 10, 0);
        assert_eq!((out.local_index, out.sub_frames, out.generated), (6, 2, false));
        assert_eq!(p.preview_output(0, 7, 10, 1).local_index, 7);
        let progressive = ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            ..Default::default()
        };
        assert_eq!(progressive.preview_output(0, 7, 10, 5).sub_frames, 1);
    }

    #[test]
    fn a_down_conversion_shows_the_frame_before() {
        // 50 -> 25 leaves odd source frames with no output of their own.
        let p = retimed((25, 1), (50, 1), FrameRateMethod::Duplicate, false);
        let out = p.preview_output(0, 4, 5, 0);
        assert_eq!(out.sub_frames, 1);
        assert_eq!(encode_index(&p, 0, 4, out), 2);
    }

    #[test]
    fn test_default_pipeline() {
        let pipeline = ProcessingPipeline::default();
        assert!(!pipeline.noise_reduction.enabled);
        assert!(!pipeline.color_correction.enabled);
        assert!(!pipeline.chroma_fixes.enabled);
        assert!(!pipeline.crop_resize.enabled);
    }

    #[test]
    fn test_enabled_passes() {
        let mut pipeline = ProcessingPipeline::default();
        pipeline.noise_reduction.enabled = true;
        pipeline.color_correction.enabled = true;

        let passes = pipeline.enabled_passes();
        assert!(passes.contains(&PassType::Deinterlace));
        assert!(passes.contains(&PassType::NoiseReduction));
        assert!(passes.contains(&PassType::ColorCorrection));
        assert!(!passes.contains(&PassType::ChromaFixes));
    }

    #[test]
    fn test_serialization() {
        let pipeline = ProcessingPipeline::default();
        let json = serde_json::to_string(&pipeline).unwrap();
        assert!(json.contains("\"noiseReduction\""));
        assert!(json.contains("\"colorCorrection\""));
    }

    // ---- FrameMap descriptor ----

    #[test]
    fn test_framemap_output_count() {
        assert_eq!(FrameMap::Identity { radius: 0 }.output_count(100), 100);
        assert_eq!(FrameMap::Fanout { factor: 2, radius: 0 }.output_count(100), 200);
        // cycle 5, keep 4 → 30fps→24fps
        assert_eq!(FrameMap::Decimate { cycle: 5, keep: 4 }.output_count(100), 80);
        // 24→25 retime
        assert_eq!(FrameMap::Retime { num: 25, den: 24, synthesizes: false, radius: 0 }.output_count(240), 250);
    }

    #[test]
    fn test_framemap_inverse() {
        assert_eq!(FrameMap::Identity { radius: 0 }.inverse(42),
            SourceSpan { start: 42, end: 42, exact: true });
        // double-rate: output 10 and 11 both come from source 5
        assert_eq!(FrameMap::Fanout { factor: 2, radius: 0 }.inverse(10),
            SourceSpan { start: 5, end: 5, exact: true });
        assert_eq!(FrameMap::Fanout { factor: 2, radius: 0 }.inverse(11),
            SourceSpan { start: 5, end: 5, exact: true });
        // decimation inverse is approximate (data-dependent drop)
        assert!(!FrameMap::Decimate { cycle: 5, keep: 4 }.inverse(8).exact);
        // interpolation: synthesized frames are inexact, blended span
        let s = FrameMap::Retime { num: 2, den: 1, synthesizes: true, radius: 0 }.inverse(7);
        assert!(!s.exact);
    }

    #[test]
    fn test_pipeline_output_count_matches_old_ladder() {
        // Single-rate QTGMC (FPSDivisor=2): unchanged count.
        let mut p = ProcessingPipeline::default();
        p.deinterlace.enabled = true;
        p.deinterlace.method = DeinterlaceMethod::Qtgmc;
        p.deinterlace.fps_divisor = Some(2);
        assert_eq!(p.output_count(1000), 1000);

        // Double-rate QTGMC (FPSDivisor=1, and the unset default): ×2.
        p.deinterlace.fps_divisor = Some(1);
        assert_eq!(p.output_count(1000), 2000);
        p.deinterlace.fps_divisor = None;
        assert_eq!(p.output_count(1000), 2000);

        // IVTC cycle 5: ×(cycle-1)/cycle, matching vspipe_total*(cycle-1)/cycle.
        p.deinterlace.method = DeinterlaceMethod::Ivtc;
        p.deinterlace.fps_divisor = None;
        p.deinterlace.ivtc_cycle = Some(5);
        assert_eq!(p.output_count(1000), 800);

        // Disabled deinterlace: identity.
        p.deinterlace.enabled = false;
        assert_eq!(p.output_count(1000), 1000);
    }

    #[test]
    fn test_pipeline_invert_double_rate() {
        let mut p = ProcessingPipeline::default();
        p.deinterlace.enabled = true;
        p.deinterlace.method = DeinterlaceMethod::Qtgmc;
        p.deinterlace.fps_divisor = Some(1); // double-rate
        // output frame 20 ← source frame 10
        let span = p.invert(20);
        assert_eq!(span.start, 10);
        assert!(span.exact);
    }

    #[test]
    fn test_total_radius_floored() {
        // Even an all-identity pipeline gets the minimum preview window.
        let p = ProcessingPipeline::default();
        assert!(p.total_radius() >= MIN_PREVIEW_RADIUS);
    }
}
