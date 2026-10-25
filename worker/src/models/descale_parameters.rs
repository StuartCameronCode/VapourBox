//! Descale: undo a studio's upscale, then upscale again properly.
//!
//! Most modern anime is drawn below 1080p and upscaled for broadcast or Blu-ray
//! with a plain resampling kernel. When the native resolution and kernel are
//! known, `descale` inverts that resample exactly, recovering the picture as it
//! was drawn; NNEDI3 then upscales it back to the source size with far cleaner
//! lines than the studio's kernel gave. Luma only — chroma was stored at a
//! lower resolution to begin with — and the output stays at the source size.

use serde::{Deserialize, Serialize};

/// The resampling kernel the studio upscaled with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum DescaleKernel {
    Bilinear,
    /// Bicubic with `b`/`c` (Catmull-Rom b=0 c=0.5 is the usual one).
    #[default]
    Bicubic,
    Lanczos,
    Spline16,
    Spline36,
    Spline64,
}

/// How the studio's resampler treated pixels past the frame edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum DescaleBorder {
    #[default]
    Mirror,
    Zero,
    Extend,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DescaleParameters {
    #[serde(default)]
    pub enabled: bool,

    /// The height the picture was drawn at.
    #[serde(default = "default_native_height")]
    pub native_height: i32,

    /// The width it was drawn at; 0 derives it from the source's shape.
    #[serde(default)]
    pub native_width: i32,

    #[serde(default)]
    pub kernel: DescaleKernel,

    #[serde(default)]
    pub bicubic_b: f64,

    #[serde(default = "default_bicubic_c")]
    pub bicubic_c: f64,

    #[serde(default = "default_lanczos_taps")]
    pub lanczos_taps: i32,

    #[serde(default)]
    pub border: DescaleBorder,

    /// Keep the source wherever re-applying the kernel to the descaled picture
    /// does not reproduce it: detail drawn at full resolution (credits, text,
    /// overlays), which descaling would otherwise smear.
    #[serde(default = "default_true")]
    pub protect_detail: bool,

    /// How far (8-bit levels) the re-applied kernel may miss before a pixel
    /// counts as full-resolution detail.
    #[serde(default = "default_detail_threshold")]
    pub detail_threshold: f64,
}

fn default_native_height() -> i32 { 720 }
fn default_bicubic_c() -> f64 { 0.5 }
fn default_lanczos_taps() -> i32 { 3 }
fn default_true() -> bool { true }
fn default_detail_threshold() -> f64 { 4.0 }

impl Default for DescaleParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            native_height: default_native_height(),
            native_width: 0,
            kernel: DescaleKernel::default(),
            bicubic_b: 0.0,
            bicubic_c: default_bicubic_c(),
            lanczos_taps: default_lanczos_taps(),
            border: DescaleBorder::default(),
            protect_detail: true,
            detail_threshold: default_detail_threshold(),
        }
    }
}

impl DescaleParameters {
    /// The descale call for a GRAY float clip `{clip}` at `{w}`x`{h}`, as
    /// Python — and the matching forward resize that re-applies the kernel.
    pub fn kernel_calls(&self) -> (String, String) {
        let border = match self.border {
            DescaleBorder::Mirror => 0,
            DescaleBorder::Zero => 1,
            DescaleBorder::Extend => 2,
        };
        let taps = self.lanczos_taps.clamp(1, 8);
        let (b, c) = (self.bicubic_b.clamp(-1.0, 2.0), self.bicubic_c.clamp(-1.0, 2.0));
        let (de, fwd) = match self.kernel {
            DescaleKernel::Bilinear => (
                "core.descale.Debilinear(c, w, h".to_string(),
                "core.resize.Bilinear(c, w, h".to_string(),
            ),
            DescaleKernel::Bicubic => (
                format!("core.descale.Debicubic(c, w, h, b={b}, c={c}"),
                format!("core.resize.Bicubic(c, w, h, filter_param_a={b}, filter_param_b={c}"),
            ),
            DescaleKernel::Lanczos => (
                format!("core.descale.Delanczos(c, w, h, taps={taps}"),
                format!("core.resize.Lanczos(c, w, h, filter_param_a={taps}"),
            ),
            DescaleKernel::Spline16 => (
                "core.descale.Despline16(c, w, h".to_string(),
                "core.resize.Spline16(c, w, h".to_string(),
            ),
            DescaleKernel::Spline36 => (
                "core.descale.Despline36(c, w, h".to_string(),
                "core.resize.Spline36(c, w, h".to_string(),
            ),
            DescaleKernel::Spline64 => (
                "core.descale.Despline64(c, w, h".to_string(),
                "core.resize.Spline64(c, w, h".to_string(),
            ),
        };
        (format!("{de}, border_handling={border})"), format!("{fwd})"))
    }

    /// The native height, kept to something descale can work with.
    pub fn effective_native_height(&self) -> i32 {
        self.native_height.clamp(16, 4320)
    }

    /// The detail threshold, clamped to a sensible 0.5-64 levels.
    pub fn effective_detail_threshold(&self) -> f64 {
        self.detail_threshold.clamp(0.5, 64.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kernel_calls_pair_the_inverse_with_its_forward_resize() {
        let p = DescaleParameters { kernel: DescaleKernel::Bicubic, bicubic_b: 0.0, bicubic_c: 0.5, ..Default::default() };
        let (de, fwd) = p.kernel_calls();
        assert_eq!(de, "core.descale.Debicubic(c, w, h, b=0, c=0.5, border_handling=0)");
        assert_eq!(fwd, "core.resize.Bicubic(c, w, h, filter_param_a=0, filter_param_b=0.5)");
        let p = DescaleParameters { kernel: DescaleKernel::Lanczos, lanczos_taps: 40, border: DescaleBorder::Extend, ..Default::default() };
        let (de, fwd) = p.kernel_calls();
        assert_eq!(de, "core.descale.Delanczos(c, w, h, taps=8, border_handling=2)");
        assert_eq!(fwd, "core.resize.Lanczos(c, w, h, filter_param_a=8)");
        for k in [DescaleKernel::Bilinear, DescaleKernel::Spline16, DescaleKernel::Spline36, DescaleKernel::Spline64] {
            let (de, fwd) = DescaleParameters { kernel: k, ..Default::default() }.kernel_calls();
            assert!(de.starts_with("core.descale.De") && fwd.starts_with("core.resize."), "{k:?}");
        }
    }

    #[test]
    fn wire_names() {
        let json = serde_json::to_string(&DescaleParameters::default()).unwrap();
        assert!(json.contains("\"kernel\":\"bicubic\""));
        assert!(json.contains("\"nativeHeight\":720"));
        assert!(json.contains("\"border\":\"mirror\""));
        assert!(json.contains("\"protectDetail\":true"));
    }
}
