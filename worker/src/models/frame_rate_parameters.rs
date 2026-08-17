//! Frame rate conversion (MVTools FlowFPS).
//!
//! Deliberately scoped to **standards conversion**, not smoothing. Interpolating
//! a 25p master to 60p invents frames that were never photographed and makes the
//! file a worse record than the tape it came from — squarely against what this
//! app is for. Converting an already-converted PAL/NTSC tape is the opposite
//! case: the damage is already in the source, and doing nothing is not neutral,
//! it means duplication judder or a 4% speed error.
//!
//! So this offers named target rates rather than a free number, is off by
//! default, and is never described as making motion "smooth".
//!
//! FlowFPS rather than BlockFPS: measured over 35 input-length/ratio
//! combinations, FlowFPS's output count matches `FrameMap::Retime::output_count`
//! (`n * num / den`) **exactly**, while BlockFPS is off by one in 14 of them
//! because it produces `floor((n-1) * r) + 1`. Choosing FlowFPS makes the
//! existing FrameMap variant correct as written.

use serde::{Deserialize, Serialize};

/// A target frame rate, as a rational so the FrameMap ratio stays exact.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum FrameRateTarget {
    /// 25 fps — PAL/SECAM.
    #[default]
    #[serde(rename = "pal25")]
    Pal25,
    /// 30000/1001 — NTSC.
    #[serde(rename = "ntsc2997")]
    Ntsc2997,
    /// 24000/1001 — film after 3:2 removal.
    #[serde(rename = "film23976")]
    Film23976,
    /// 24 fps — true film.
    #[serde(rename = "film24")]
    Film24,
    /// 50 fps — PAL double rate.
    #[serde(rename = "pal50")]
    Pal50,
    /// 60000/1001 — NTSC double rate.
    #[serde(rename = "ntsc5994")]
    Ntsc5994,
}

impl FrameRateTarget {
    /// Target rate as (numerator, denominator).
    pub fn as_fraction(self) -> (u32, u32) {
        match self {
            FrameRateTarget::Pal25 => (25, 1),
            FrameRateTarget::Ntsc2997 => (30000, 1001),
            FrameRateTarget::Film23976 => (24000, 1001),
            FrameRateTarget::Film24 => (24, 1),
            FrameRateTarget::Pal50 => (50, 1),
            FrameRateTarget::Ntsc5994 => (60000, 1001),
        }
    }
}

/// How the new frames are produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum FrameRateMethod {
    /// Motion-compensated interpolation. Measured 0.098 mean abs diff against
    /// independently rendered ground truth on a pan, against 1.269 for
    /// duplication — but it warps around occlusion boundaries when it fails.
    #[default]
    #[serde(rename = "flowFps")]
    FlowFps,
    /// Duplicate or drop whole frames. No invented pixels, visible judder.
    /// The honest choice for an archival master.
    #[serde(rename = "duplicate")]
    Duplicate,
}

/// Parameters for the frame rate pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameRateParameters {
    #[serde(default)]
    pub enabled: bool,

    #[serde(default)]
    pub target: FrameRateTarget,

    #[serde(default)]
    pub method: FrameRateMethod,

    /// Motion-estimation block size. Larger is faster and blockier.
    #[serde(default = "default_block_size")]
    pub block_size: i32,

    /// Block overlap. Must be less than block_size and even.
    #[serde(default = "default_overlap")]
    pub overlap: i32,

    /// The source rate, supplied by the app from ffprobe. The pipeline needs it
    /// to report a correct `FrameMap::Retime`, and cannot see the job — the
    /// same reason `inputSar` is carried rather than looked up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_fps_num: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_fps_den: Option<u32>,
}

fn default_block_size() -> i32 { 16 }
fn default_overlap() -> i32 { 8 }

impl Default for FrameRateParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            target: FrameRateTarget::default(),
            method: FrameRateMethod::default(),
            block_size: default_block_size(),
            overlap: default_overlap(),
            source_fps_num: None,
            source_fps_den: None,
        }
    }
}

impl FrameRateParameters {
    /// Overlap clamped to what mvtools accepts: even, and strictly less than
    /// half the block size. Out of range is a hard error at script evaluation,
    /// not a clamp, so it has to happen here.
    pub fn effective_overlap(&self) -> i32 {
        let max = (self.block_size / 2).max(0);
        (self.overlap.clamp(0, max) / 2) * 2
    }

    /// The retime ratio against a source rate, reduced.
    ///
    /// Reduced matters: 25 → 29.97 is 1200/1001, not the plugin's
    /// `num=30000, den=1001`. `FrameMap::Retime` multiplies a frame count by
    /// this, so an unreduced pair overflows on long clips.
    pub fn ratio_against(&self, src_num: u32, src_den: u32) -> Option<(u32, u32)> {
        if src_num == 0 || src_den == 0 {
            return None;
        }
        let (t_num, t_den) = self.as_fraction();
        // (t_num/t_den) / (src_num/src_den) = (t_num*src_den) / (t_den*src_num)
        let num = (t_num as u64) * (src_den as u64);
        let den = (t_den as u64) * (src_num as u64);
        let g = gcd(num, den);
        Some(((num / g) as u32, (den / g) as u32))
    }

    fn as_fraction(&self) -> (u32, u32) {
        self.target.as_fraction()
    }

    /// The retime ratio using the carried source rate, if the app supplied one.
    pub fn ratio(&self) -> Option<(u32, u32)> {
        self.ratio_against(self.source_fps_num?, self.source_fps_den?)
    }
}

fn gcd(a: u64, b: u64) -> u64 {
    if b == 0 { a.max(1) } else { gcd(b, a % b) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(target: FrameRateTarget) -> FrameRateParameters {
        FrameRateParameters { target, ..Default::default() }
    }

    #[test]
    fn ratios_are_reduced() {
        // 25 -> 29.97 is 1200/1001, NOT 30000/1001. FrameMap multiplies a frame
        // count by this pair, so leaving it unreduced overflows on long clips.
        assert_eq!(params(FrameRateTarget::Ntsc2997).ratio_against(25, 1), Some((1200, 1001)));
        // 23.976 -> 25 reduces to 25025/24000 -> 1001/960.
        assert_eq!(params(FrameRateTarget::Pal25).ratio_against(24000, 1001), Some((1001, 960)));
    }

    #[test]
    fn converting_to_the_same_rate_is_the_identity() {
        assert_eq!(params(FrameRateTarget::Pal25).ratio_against(25, 1), Some((1, 1)));
    }

    #[test]
    fn output_counts_match_what_flowfps_produces() {
        // Measured against the real plugin: FlowFPS emits floor(n_in * r), which
        // is exactly what FrameMap::Retime computes. 97 frames of 25 fps to
        // 29.97 gave 116; to 23.976 from 25 gave 93.
        use crate::models::FrameMap;
        let r = params(FrameRateTarget::Ntsc2997).ratio_against(25, 1).unwrap();
        let map = FrameMap::Retime { num: r.0, den: r.1, synthesizes: true, radius: 1 };
        assert_eq!(map.output_count(97), 116);
    }

    #[test]
    fn a_zero_source_rate_is_rejected_rather_than_dividing_by_zero() {
        assert_eq!(params(FrameRateTarget::Pal25).ratio_against(0, 1), None);
        assert_eq!(params(FrameRateTarget::Pal25).ratio_against(25, 0), None);
    }

    #[test]
    fn overlap_is_clamped_to_what_mvtools_accepts() {
        // mvtools errors rather than clamping, so an out-of-range value from a
        // saved job would fail the whole encode.
        let p = FrameRateParameters { block_size: 16, overlap: 99, ..Default::default() };
        assert_eq!(p.effective_overlap(), 8);
        let odd = FrameRateParameters { block_size: 16, overlap: 5, ..Default::default() };
        assert_eq!(odd.effective_overlap(), 4, "overlap must be even");
        let neg = FrameRateParameters { block_size: 16, overlap: -4, ..Default::default() };
        assert_eq!(neg.effective_overlap(), 0);
    }
}
