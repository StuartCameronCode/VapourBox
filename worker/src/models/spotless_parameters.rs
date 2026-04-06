use serde::{Deserialize, Serialize};

/// Parameters for the SpotLess pass.
/// Removes dust, dirt, and temporal spots using motion-compensated median.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpotLessParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

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

impl Default for SpotLessParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            chroma: default_true(),
            rec: false,
            blksize: default_blksize(),
            overlap: default_overlap(),
            pel: default_pel(),
        }
    }
}
