use serde::{Deserialize, Serialize};

/// Deblocking method options.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub enum DeblockMethod {
    #[default]
    #[serde(rename = "Deblock_QED")]
    DeblockQed,
    #[serde(rename = "Deblock")]
    Deblock,
}

#[allow(dead_code)]
impl DeblockMethod {
    pub fn as_str(&self) -> &'static str {
        match self {
            DeblockMethod::DeblockQed => "Deblock_QED",
            DeblockMethod::Deblock => "Deblock",
        }
    }
}

/// Parameters for the deblocking pass.
/// Removes block artifacts from compressed video.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeblockParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Deblocking method to use.
    #[serde(default)]
    pub method: DeblockMethod,

    // --- Deblock_QED parameters ---

    /// Quant1: Strength for edges (0-60, default 24).
    #[serde(default = "default_quant1")]
    pub quant1: i32,

    /// Quant2: Strength for non-edges (0-60, default 26).
    #[serde(default = "default_quant2")]
    pub quant2: i32,

    /// Analyze planes offset 1.
    #[serde(default = "default_a_offset")]
    pub a_offset1: i32,

    /// Analyze planes offset 2.
    #[serde(default = "default_a_offset")]
    pub a_offset2: i32,
}

fn default_quant1() -> i32 { 24 }
fn default_quant2() -> i32 { 26 }
fn default_a_offset() -> i32 { 1 }

impl Default for DeblockParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            method: DeblockMethod::default(),
            quant1: default_quant1(),
            quant2: default_quant2(),
            a_offset1: default_a_offset(),
            a_offset2: default_a_offset(),
        }
    }
}
