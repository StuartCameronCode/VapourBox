//! Processing pipeline containing all video processing passes.

use serde::{Deserialize, Serialize};

use super::{
    AntiAliasParameters, GeometryParameters, GrainParameters, StabilizeParameters,
    ChromaDenoiseParameters, ChromaFixParameters, ColorCorrectionParameters, CropResizeParameters,
    DebandParameters, DeblockParameters, DehaloParameters, DeinterlaceMethod, DeScratchParameters,
    SpotLessParameters, SharpenParameters, NoiseReductionParameters, QTGMCParameters, FrameRateParameters, FrameRateMethod, DeflickerParameters, EdgeRepairParameters, GhostRemovalParameters,};

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
            PassType::EdgeRepair => "Edge Repair",
            PassType::FrameRate => "Frame Rate",
            PassType::ColorCorrection => "Color Correction",
            PassType::ChromaFixes => "Chroma Fixes",
            PassType::CropResize => "Crop / Resize",
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
            PassType::EdgeRepair => "Rebuild the dirty rows and columns at the frame border",
            PassType::FrameRate => "Convert between PAL and NTSC frame rates",
            PassType::ColorCorrection => "Adjust brightness, contrast, and colors",
            PassType::ChromaFixes => "Fix chroma bleeding and crawl artifacts",
            PassType::CropResize => "Crop borders and resize output",
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
            edge_repair: EdgeRepairParameters::default(),
            frame_rate: FrameRateParameters::default(),
            color_correction: ColorCorrectionParameters::default(),
            chroma_fixes: ChromaFixParameters::default(),
            crop_resize: CropResizeParameters::default(),
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
            edge_repair: EdgeRepairParameters { enabled: false, ..Default::default() },
            frame_rate: FrameRateParameters { enabled: false, ..Default::default() },
            color_correction: ColorCorrectionParameters { enabled: false, ..Default::default() },
            chroma_fixes: ChromaFixParameters { enabled: false, ..Default::default() },
            crop_resize: CropResizeParameters { enabled: false, ..Default::default() },
        }
    }

    /// Get the ordered list of enabled passes.
    pub fn enabled_passes(&self) -> Vec<PassType> {
        let mut passes = Vec::new();

        // Order: Crop first (pre-processing), then deinterlace, noise, dehalo, deblock, deband, sharpen, chroma, color, resize last
        if self.crop_resize.enabled && self.crop_resize.crop_enabled {
            passes.push(PassType::CropResize); // Pre-crop
        }
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
        if self.sharpen.enabled {
            passes.push(PassType::Sharpen);
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
        if self.crop_resize.enabled && self.crop_resize.resize_enabled {
            // Resize (post-processing) - if not already added for crop
            if !passes.contains(&PassType::CropResize) {
                passes.push(PassType::CropResize);
            }
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
        count
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
            PassType::NoiseReduction => FrameMap::Identity { radius: 3 },
            // CCD is spatial at temporal_radius 0, temporal above it.
            PassType::ChromaDenoise => FrameMap::Identity {
                radius: self.chroma_denoise.radius(),
            },
            PassType::SpotLess => FrameMap::Identity { radius: 2 },
            PassType::DeScratch => FrameMap::Identity { radius: 1 },
            PassType::Deflicker => FrameMap::Identity { radius: self.deflicker.radius() },
            PassType::EdgeRepair => FrameMap::Identity { radius: 0 },
            PassType::GhostRemoval => FrameMap::Identity { radius: 0 },
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
    /// The source rate is not known to the pipeline, so this reports the
    /// identity and the executor substitutes the real ratio once vspipe has
    /// reported the input rate. Reporting a wrong fixed ratio here would make
    /// the progress total and the preview seek disagree with the output.
    fn frame_rate_frame_map(&self) -> FrameMap {
        // Without a source rate we cannot know the ratio, and a wrong fixed
        // ratio is worse than none: it would make the progress total and the
        // preview index disagree with what the encoder actually receives.
        match self.frame_rate.ratio() {
            Some((num, den)) => FrameMap::Retime {
                num,
                den,
                // Interpolated frames have no single source origin, so the
                // preview's inverse mapping is a blended range, not a frame.
                synthesizes: matches!(self.frame_rate.method, FrameRateMethod::FlowFps),
                radius: 1,
            },
            None => FrameMap::Identity { radius: 1 },
        }
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
            PassType::EdgeRepair => self.edge_repair.has_effect(),
            PassType::FrameRate => self.frame_rate.enabled,
            PassType::ColorCorrection => self.color_correction.enabled,
            PassType::ChromaFixes => self.chroma_fixes.enabled,
            PassType::CropResize => self.crop_resize.enabled,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
