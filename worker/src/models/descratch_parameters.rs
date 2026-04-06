use serde::{Deserialize, Serialize};

/// Parameters for the DeScratch pass.
/// Removes vertical scratches from scanned film.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeScratchParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Minimum luma difference to detect a scratch (1-255).
    #[serde(default = "default_mindif")]
    pub mindif: i32,

    /// Maximum asymmetry of neighbor pixels (0-255).
    #[serde(default = "default_asym")]
    pub asym: i32,

    /// Maximum vertical gap to close (0-255).
    #[serde(default = "default_maxgap")]
    pub maxgap: i32,

    /// Maximum scratch width in pixels (1-15, odd).
    #[serde(default = "default_maxwidth")]
    pub maxwidth: i32,

    /// Minimum scratch width in pixels (1-15, odd).
    #[serde(default = "default_minwidth")]
    pub minwidth: i32,

    /// Minimum scratch length in pixels.
    #[serde(default = "default_minlen")]
    pub minlen: i32,

    /// Maximum scratch length in pixels.
    #[serde(default = "default_maxlen")]
    pub maxlen: i32,

    /// Maximum angle from vertical in degrees (0-90).
    #[serde(default = "default_maxangle")]
    pub maxangle: i32,

    /// Vertical blur radius for analysis (1-200).
    #[serde(default = "default_blurlen")]
    pub blurlen: i32,

    /// Percent of scratch detail to keep (0-100).
    #[serde(default = "default_keep")]
    pub keep: i32,

    /// Border thickness for smooth transition (0-15).
    #[serde(default = "default_border")]
    pub border: i32,

    /// Luma mode: 0=off, 1=dark, 2=bright, 3=both.
    #[serde(default = "default_mode_y")]
    pub mode_y: i32,

    /// Chroma U mode: 0=off, 1=dark, 2=bright, 3=both.
    #[serde(default)]
    pub mode_u: i32,

    /// Chroma V mode: 0=off, 1=dark, 2=bright, 3=both.
    #[serde(default)]
    pub mode_v: i32,

    /// Minimum chroma difference (0 = use mindif value).
    #[serde(default)]
    pub mindif_uv: i32,
}

fn default_mindif() -> i32 { 5 }
fn default_asym() -> i32 { 10 }
fn default_maxgap() -> i32 { 3 }
fn default_maxwidth() -> i32 { 3 }
fn default_minwidth() -> i32 { 1 }
fn default_minlen() -> i32 { 100 }
fn default_maxlen() -> i32 { 2048 }
fn default_maxangle() -> i32 { 5 }
fn default_blurlen() -> i32 { 15 }
fn default_keep() -> i32 { 100 }
fn default_border() -> i32 { 2 }
fn default_mode_y() -> i32 { 1 }

impl Default for DeScratchParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            mindif: default_mindif(),
            asym: default_asym(),
            maxgap: default_maxgap(),
            maxwidth: default_maxwidth(),
            minwidth: default_minwidth(),
            minlen: default_minlen(),
            maxlen: default_maxlen(),
            maxangle: default_maxangle(),
            blurlen: default_blurlen(),
            keep: default_keep(),
            border: default_border(),
            mode_y: default_mode_y(),
            mode_u: 0,
            mode_v: 0,
            mindif_uv: 0,
        }
    }
}
