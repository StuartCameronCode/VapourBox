//! Processing pipeline containing all video processing passes.

use serde::{Deserialize, Serialize};

use super::{
    ChromaFixParameters, ColorCorrectionParameters, CropResizeParameters,
    DebandParameters, DeblockParameters, DehaloParameters, DeScratchParameters,
    SharpenParameters, NoiseReductionParameters, QTGMCParameters,
};

/// Defines the type of each processing pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(dead_code)]
pub enum PassType {
    Deinterlace,
    DeScratch,
    NoiseReduction,
    Dehalo,
    Deblock,
    Deband,
    Sharpen,
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
            PassType::NoiseReduction => "Noise Reduction",
            PassType::Dehalo => "Dehalo",
            PassType::Deblock => "Deblock",
            PassType::Deband => "Deband",
            PassType::Sharpen => "Sharpen",
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
            PassType::NoiseReduction => "Reduce video noise and grain",
            PassType::Dehalo => "Remove halo artifacts around edges",
            PassType::Deblock => "Remove compression block artifacts",
            PassType::Deband => "Remove color banding from gradients",
            PassType::Sharpen => "Sharpen edges and enhance detail",
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

    /// Noise reduction pass parameters.
    #[serde(default)]
    pub noise_reduction: NoiseReductionParameters,

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
            noise_reduction: NoiseReductionParameters::default(),
            dehalo: DehaloParameters::default(),
            deblock: DeblockParameters::default(),
            deband: DebandParameters::default(),
            sharpen: SharpenParameters::default(),
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
            noise_reduction: NoiseReductionParameters { enabled: false, ..Default::default() },
            dehalo: DehaloParameters { enabled: false, ..Default::default() },
            deblock: DeblockParameters { enabled: false, ..Default::default() },
            deband: DebandParameters { enabled: false, ..Default::default() },
            sharpen: SharpenParameters { enabled: false, ..Default::default() },
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
        if self.descratch.enabled {
            passes.push(PassType::DeScratch);
        }
        if self.noise_reduction.enabled {
            passes.push(PassType::NoiseReduction);
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
        if self.sharpen.enabled {
            passes.push(PassType::Sharpen);
        }
        if self.chroma_fixes.enabled {
            passes.push(PassType::ChromaFixes);
        }
        if self.color_correction.enabled {
            passes.push(PassType::ColorCorrection);
        }
        if self.crop_resize.enabled && self.crop_resize.resize_enabled {
            // Resize (post-processing) - if not already added for crop
            if !passes.contains(&PassType::CropResize) {
                passes.push(PassType::CropResize);
            }
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

    /// Check if a specific pass is enabled.
    pub fn is_pass_enabled(&self, pass: PassType) -> bool {
        match pass {
            PassType::Deinterlace => self.deinterlace_enabled(),
            PassType::DeScratch => self.descratch.enabled,
            PassType::NoiseReduction => self.noise_reduction.enabled,
            PassType::Dehalo => self.dehalo.enabled,
            PassType::Deblock => self.deblock.enabled,
            PassType::Deband => self.deband.enabled,
            PassType::Sharpen => self.sharpen.enabled,
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
}
