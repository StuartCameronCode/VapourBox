//! Colourisation: colour black-and-white footage with a neural network
//! (DDColor or DeOldify Video), keeping the source's luma bit-exact and
//! replacing only its chroma. Runs on ONNX Runtime from the ai-runtime add-on;
//! each model is an add-on of its own (`colorize-ddcolor`,
//! `colorize-deoldify`). See `worker/templates/colorize.py`.

use serde::{Deserialize, Serialize};

pub const COLORIZE_DDCOLOR_ADDON: &str = "colorize-ddcolor";
pub const COLORIZE_DEOLDIFY_ADDON: &str = "colorize-deoldify";

/// Which network predicts the colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum ColorizeModel {
    /// DDColor-T (Apache-2.0): vivid, predicted per frame, so it leans on
    /// temporal smoothing.
    #[default]
    #[serde(rename = "ddcolor")]
    DdColor,
    /// DeOldify's Video generator (MIT): muted, trained for steady colour on
    /// video.
    #[serde(rename = "deoldify")]
    DeOldify,
}

impl ColorizeModel {
    /// The add-on holding this model's file.
    pub fn addon(&self) -> &'static str {
        match self {
            ColorizeModel::DdColor => COLORIZE_DDCOLOR_ADDON,
            ColorizeModel::DeOldify => COLORIZE_DEOLDIFY_ADDON,
        }
    }

    /// The model's file in that add-on.
    pub fn file(&self) -> &'static str {
        match self {
            ColorizeModel::DdColor => "colorize-ddcolor-tiny.onnx",
            ColorizeModel::DeOldify => "colorize-deoldify-video.onnx",
        }
    }

    /// The name `colorize.colorize(model=...)` takes.
    pub fn script_name(&self) -> &'static str {
        match self {
            ColorizeModel::DdColor => "ddcolor",
            ColorizeModel::DeOldify => "deoldify",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColorizeParameters {
    #[serde(default)]
    pub enabled: bool,

    #[serde(default)]
    pub model: ColorizeModel,

    /// DDColor's input size (pixels, square; a multiple of 32). Upstream's
    /// default is 512.
    #[serde(default = "default_ddcolor_size")]
    pub ddcolor_render_size: i32,

    /// DeOldify's `render_factor`: the model sees a square of 16 x this many
    /// pixels. Upstream's default for video is 21 (336 pixels).
    #[serde(default = "default_render_factor")]
    pub deoldify_render_factor: i32,

    /// How much of the predicted colour is applied: 0 leaves the picture
    /// grey, 1 is the model's colour, above 1 is more saturated.
    #[serde(default = "default_strength")]
    pub strength: f64,

    /// Frames either side each frame's colour is averaged with (weighted
    /// down to nothing where the picture moved), so it does not flicker.
    #[serde(default = "default_radius")]
    pub temporal_radius: i32,
}

fn default_ddcolor_size() -> i32 { 512 }
fn default_render_factor() -> i32 { 21 }
fn default_strength() -> f64 { 1.0 }
fn default_radius() -> i32 { 2 }

impl Default for ColorizeParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            model: ColorizeModel::default(),
            ddcolor_render_size: default_ddcolor_size(),
            deoldify_render_factor: default_render_factor(),
            strength: default_strength(),
            temporal_radius: default_radius(),
        }
    }
}

impl ColorizeParameters {
    /// The add-on a job with this pass needs: the chosen model's.
    pub fn required_addons(&self) -> Vec<&'static str> {
        vec![self.model.addon()]
    }

    /// The square size (pixels) the model runs at: DDColor's size rounded
    /// down to a multiple of 32 (its decoder needs one), DeOldify's render
    /// factor x 16, each clamped to the range the panel offers.
    pub fn render_size(&self) -> u32 {
        match self.model {
            ColorizeModel::DdColor => (self.ddcolor_render_size.clamp(256, 768) / 32 * 32) as u32,
            ColorizeModel::DeOldify => (self.deoldify_render_factor.clamp(10, 40) * 16) as u32,
        }
    }

    pub fn clamped_strength(&self) -> f64 { self.strength.clamp(0.0, 1.5) }

    /// Frames read either side of the one being coloured (the preview's
    /// temporal context).
    pub fn temporal_radius(&self) -> u32 { self.temporal_radius.clamp(0, 4) as u32 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_and_wire_names() {
        let p: ColorizeParameters = serde_json::from_str("{}").unwrap();
        assert_eq!(p, ColorizeParameters::default());
        assert!(!p.enabled);
        assert_eq!(p.model, ColorizeModel::DdColor);
        let json = serde_json::to_value(ColorizeParameters { model: ColorizeModel::DeOldify, ..Default::default() }).unwrap();
        assert_eq!(json["model"], "deoldify");
        assert_eq!(json["ddcolorRenderSize"], 512);
        assert_eq!(json["deoldifyRenderFactor"], 21);
        assert_eq!(json["temporalRadius"], 2);
        assert_eq!(serde_json::to_string(&ColorizeModel::DdColor).unwrap(), "\"ddcolor\"");
    }

    #[test]
    fn render_sizes_are_what_each_model_can_take() {
        let dd = |s| ColorizeParameters { ddcolor_render_size: s, ..Default::default() }.render_size();
        assert_eq!(dd(512), 512);
        assert_eq!(dd(500), 480, "rounded down to a multiple of 32");
        assert_eq!(dd(64), 256);
        assert_eq!(dd(4096), 768);
        let de = |f| ColorizeParameters { model: ColorizeModel::DeOldify, deoldify_render_factor: f, ..Default::default() }
            .render_size();
        assert_eq!(de(21), 336);
        assert_eq!(de(0), 160);
        assert_eq!(de(99), 640);
    }

    #[test]
    fn required_addon_per_model() {
        let with = |model| ColorizeParameters { model, ..Default::default() }.required_addons();
        assert_eq!(with(ColorizeModel::DdColor), vec!["colorize-ddcolor"]);
        assert_eq!(with(ColorizeModel::DeOldify), vec!["colorize-deoldify"]);
    }

    /// The files named here are the ones the manifests install.
    #[test]
    fn model_files_are_in_their_manifests() {
        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        for m in [ColorizeModel::DdColor, ColorizeModel::DeOldify] {
            let manifest = std::fs::read_to_string(repo.join("app/assets/addons").join(format!("{}.json", m.addon()))).unwrap();
            assert!(manifest.contains(&format!("\"name\": \"{}\"", m.file())), "{m:?}");
            assert!(manifest.contains("\"ai-runtime\""), "{m:?} must require the AI runtime");
        }
    }
}
