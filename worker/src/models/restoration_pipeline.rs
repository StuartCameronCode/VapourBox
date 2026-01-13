//! Restoration pipeline containing all video restoration passes.

use serde::{Deserialize, Serialize};

use super::{
    ChromaFixParameters, ColorCorrectionParameters, CropResizeParameters,
    NoiseReductionParameters, QTGMCParameters,
};

/// Defines the type of each restoration pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PassType {
    Deinterlace,
    NoiseReduction,
    ColorCorrection,
    ChromaFixes,
    CropResize,
}

impl PassType {
    /// Get display name for the pass.
    pub fn display_name(&self) -> &'static str {
        match self {
            PassType::Deinterlace => "Deinterlace",
            PassType::NoiseReduction => "Noise Reduction",
            PassType::ColorCorrection => "Color Correction",
            PassType::ChromaFixes => "Chroma Fixes",
            PassType::CropResize => "Crop / Resize",
        }
    }

    /// Get description for the pass.
    pub fn description(&self) -> &'static str {
        match self {
            PassType::Deinterlace => "Remove interlacing artifacts using QTGMC",
            PassType::NoiseReduction => "Reduce video noise and grain",
            PassType::ColorCorrection => "Adjust brightness, contrast, and colors",
            PassType::ChromaFixes => "Fix chroma bleeding and crawl artifacts",
            PassType::CropResize => "Crop borders and resize output",
        }
    }
}

/// Container for all restoration pass parameters.
/// Defines the complete video restoration pipeline.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RestorationPipeline {
    /// Deinterlacing pass parameters (QTGMC).
    #[serde(default)]
    pub deinterlace: QTGMCParameters,

    /// Noise reduction pass parameters.
    #[serde(default)]
    pub noise_reduction: NoiseReductionParameters,

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

impl Default for RestorationPipeline {
    fn default() -> Self {
        Self {
            deinterlace: QTGMCParameters::default(),
            noise_reduction: NoiseReductionParameters::default(),
            color_correction: ColorCorrectionParameters::default(),
            chroma_fixes: ChromaFixParameters::default(),
            crop_resize: CropResizeParameters::default(),
        }
    }
}

impl RestorationPipeline {
    /// Create a pipeline from legacy QTGMC-only parameters.
    pub fn from_legacy(qtgmc_params: &QTGMCParameters) -> Self {
        Self {
            deinterlace: qtgmc_params.clone(),
            noise_reduction: NoiseReductionParameters { enabled: false, ..Default::default() },
            color_correction: ColorCorrectionParameters { enabled: false, ..Default::default() },
            chroma_fixes: ChromaFixParameters { enabled: false, ..Default::default() },
            crop_resize: CropResizeParameters { enabled: false, ..Default::default() },
        }
    }

    /// Get the ordered list of enabled passes.
    pub fn enabled_passes(&self) -> Vec<PassType> {
        let mut passes = Vec::new();

        // Order: Crop first (pre-processing), then deinterlace, noise, chroma, color, resize last
        if self.crop_resize.enabled && self.crop_resize.crop_enabled {
            passes.push(PassType::CropResize); // Pre-crop
        }
        if self.deinterlace_enabled() {
            passes.push(PassType::Deinterlace);
        }
        if self.noise_reduction.enabled {
            passes.push(PassType::NoiseReduction);
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
        if self.noise_reduction.enabled { count += 1; }
        if self.color_correction.enabled { count += 1; }
        if self.chroma_fixes.enabled { count += 1; }
        if self.crop_resize.enabled { count += 1; }
        count
    }

    /// Check if a specific pass is enabled.
    pub fn is_pass_enabled(&self, pass: PassType) -> bool {
        match pass {
            PassType::Deinterlace => self.deinterlace_enabled(),
            PassType::NoiseReduction => self.noise_reduction.enabled,
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
        let pipeline = RestorationPipeline::default();
        assert!(!pipeline.noise_reduction.enabled);
        assert!(!pipeline.color_correction.enabled);
        assert!(!pipeline.chroma_fixes.enabled);
        assert!(!pipeline.crop_resize.enabled);
    }

    #[test]
    fn test_enabled_passes() {
        let mut pipeline = RestorationPipeline::default();
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
        let pipeline = RestorationPipeline::default();
        let json = serde_json::to_string(&pipeline).unwrap();
        assert!(json.contains("\"noiseReduction\""));
        assert!(json.contains("\"colorCorrection\""));
    }
}
