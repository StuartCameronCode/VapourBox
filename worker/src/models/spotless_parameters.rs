use serde::{Deserialize, Serialize};

/// Which spot remover to run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum SpotLessMethod {
    /// SpotLess — motion-compensated temporal median. Higher quality, slow.
    #[default]
    #[serde(rename = "spotless")]
    SpotLess,
    /// RemoveDirt — measured 6.3x faster for about 60% of the removal.
    #[serde(rename = "removeDirt")]
    RemoveDirt,
}

/// Parameters for the SpotLess pass.
/// Removes dust, dirt, and temporal spots using motion-compensated median.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpotLessParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Which spot remover to run.
    #[serde(default)]
    pub method: SpotLessMethod,

    /// RemoveDirt: global motion threshold — how much of the frame may differ
    /// before it is treated as motion rather than damage.
    #[serde(default = "default_rd_gmthreshold")]
    pub rd_gmthreshold: i32,
    /// RemoveDirt: how large a difference counts as a spot.
    #[serde(default = "default_rd_noise")]
    pub rd_noise: i32,
    /// RemoveDirt: how many neighbouring pixels must agree.
    #[serde(default = "default_rd_noisy")]
    pub rd_noisy: i32,
    /// RemoveDirt: dilation distance around a detected spot.
    #[serde(default = "default_rd_dist")]
    pub rd_dist: i32,
    /// RemoveDirt: re-enable the canonical trailing RemoveGrain(17). Off by
    /// default — measured, it alone triples the collateral damage.
    #[serde(default)]
    pub rd_post_denoise: bool,

    /// Process chroma planes (default true).
    #[serde(default = "default_true")]
    pub chroma: bool,

    /// Recalculate motion vectors for more precision (default false).
    #[serde(default)]
    pub rec: bool,

    /// Block size for motion analysis (default 16).
    #[serde(default = "default_blksize")]
    pub blksize: i32,

    /// Block overlap (default 8).
    #[serde(default = "default_overlap")]
    pub overlap: i32,

    /// Sub-pixel accuracy: 1=pixel, 2=half, 4=quarter (default 2).
    #[serde(default = "default_pel")]
    pub pel: i32,
}

fn default_true() -> bool { true }
fn default_blksize() -> i32 { 16 }
fn default_overlap() -> i32 { 8 }
fn default_pel() -> i32 { 2 }

fn default_rd_gmthreshold() -> i32 { 70 }
fn default_rd_noise() -> i32 { 50 }
fn default_rd_noisy() -> i32 { 12 }
fn default_rd_dist() -> i32 { 1 }

impl Default for SpotLessParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            chroma: default_true(),
            rec: false,
            blksize: default_blksize(),
            overlap: default_overlap(),
            pel: default_pel(),
            method: SpotLessMethod::default(),
            rd_gmthreshold: default_rd_gmthreshold(),
            rd_noise: default_rd_noise(),
            rd_noisy: default_rd_noisy(),
            rd_dist: default_rd_dist(),
            rd_post_denoise: false,
        }
    }
}
