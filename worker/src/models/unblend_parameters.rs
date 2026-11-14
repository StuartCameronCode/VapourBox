//! Unblend (SRestore): recover the original frames of footage that was
//! frame-rate converted by blending (a film shown on PAL through a standards
//! converter, a PAL programme converted to NTSC).
//!
//! Runs right after Deinterlace, on the double-rate picture, because the
//! detector has to see the blends exactly as the deinterlacer leaves them:
//! denoising averages them into the clean frames, and sharpening, grain and
//! resizing change the frame-to-frame differences it measures.
//!
//! The work is `worker/templates/srestore.py`, VapourBox's port of havsfunc's
//! srestore 2.7e. havsfunc's own `srestore` cannot be used: on VapourSynth R55+ its
//! detector never sees two consecutive frames and the result is plain
//! decimation (docs/reports/2026-11-srestore). Each decision is a pure
//! function of the `WINDOW` frames before it, so the preview, the encode,
//! and any thread count agree.

use serde::{Deserialize, Serialize};

use super::frame_rate_parameters::{custom_fps_fraction, gcd};
use super::FrameRateTarget;

/// Frames each decision replays (the port's `window`). The probe's choice:
/// the smallest window whose recovery matched the linear (whole-clip)
/// detector on both fixtures, at +0.45 s per SD preview frame.
pub const UNBLEND_WINDOW: u32 = 48;

/// Frames beyond the window the pass reads: its measurements look 4 frames
/// ahead and it outputs a frame up to a few positions from the nominal one.
pub const UNBLEND_REACH: u32 = 8;

/// Parameters for the Unblend pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UnblendParameters {
    #[serde(default)]
    pub enabled: bool,

    /// The rate the original frames ran at. Only rates below the pass's
    /// input rate can be recovered.
    #[serde(default = "default_target")]
    pub target: FrameRateTarget,

    /// The rate for `FrameRateTarget::Custom`; made exact by
    /// `custom_fps_fraction`, as for the Frame Rate pass.
    #[serde(default = "default_custom_fps")]
    pub custom_fps: f64,

    /// The source rate. Filled by `VideoJob::effective_pipeline`, like the
    /// Frame Rate pass's; the app never sends it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_fps_num: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_fps_den: Option<u32>,
}

fn default_target() -> FrameRateTarget { FrameRateTarget::Film23976 }
fn default_custom_fps() -> f64 { 24.0 }

impl Default for UnblendParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            target: default_target(),
            custom_fps: default_custom_fps(),
            source_fps_num: None,
            source_fps_den: None,
        }
    }
}

impl UnblendParameters {
    /// The target rate as an exact fraction.
    pub fn target_fraction(&self) -> (u32, u32) {
        self.target.as_fraction().unwrap_or_else(|| custom_fps_fraction(self.custom_fps))
    }

    /// The reduced output/input ratio for an input of `in_num/in_den` fps,
    /// or the user-facing reason the pass cannot convert it.
    ///
    /// srestore computes its own ratio (`numr/denm`) from floating-point
    /// rates; the pass only runs where that is exactly the target ratio, so
    /// the frame count (`FrameMap::Retime`), the script and the encoder's rate
    /// all agree. The script checks the same thing and raises.
    pub fn ratio_at(&self, in_num: u32, in_den: u32) -> Result<(u32, u32), String> {
        if in_num == 0 || in_den == 0 {
            return Err("Unblend needs the source frame rate.".into());
        }
        let (t_num, t_den) = self.target_fraction();
        unblend_ratio(in_num, in_den, t_num, t_den).ok_or_else(|| refusal(in_num, in_den, t_num, t_den))
    }
}

/// The reduced output/input ratio Unblend runs at for this conversion, or
/// `None` where srestore would not decimate or would not hit it exactly.
pub fn unblend_ratio(in_num: u32, in_den: u32, t_num: u32, t_den: u32) -> Option<(u32, u32)> {
    let (frfac, numr, denm) = srestore_ratio(in_num, in_den, t_num, t_den);
    let num = t_num as u64 * in_den as u64;
    let den = t_den as u64 * in_num as u64;
    let g = gcd(num, den);
    let (num, den) = (num / g, den / g);
    if frfac == 1.0 || denm <= 0 || numr <= 0 || numr as u64 * den != denm as u64 * num {
        return None;
    }
    Some((u32::try_from(num).ok()?, u32::try_from(den).ok()?))
}

/// What the panel and a refused job say when a target can't be recovered.
pub fn refusal(in_num: u32, in_den: u32, t_num: u32, t_den: u32) -> String {
    let fps = |n: u32, d: u32| {
        let v = n as f64 / d as f64;
        let s = format!("{v:.3}");
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    };
    format!(
        "Unblend can't recover {} fps from {} fps. It can only lower the frame rate (to at least a fifth \
         of it), and only to rates it can reach exactly. Pick the rate the footage was made at: 23.976, \
         24 or 25 fps for film or PAL programmes, 29.97 for NTSC.",
        fps(t_num, t_den),
        fps(in_num, in_den),
    )
}

/// srestore 2.7e's `frfac`, `numr` and `denm`, computed exactly as
/// `srestore.ratio` (worker/templates/srestore.py) and havsfunc do, in
/// floating point. `frfac == 1.0` means srestore would not decimate.
pub fn srestore_ratio(in_num: u32, in_den: u32, out_num: u32, out_den: u32) -> (f64, i64, i64) {
    let irate = in_num as f64 / in_den as f64;
    let frate = out_num as f64 / out_den as f64;
    let floor_half = |x: f64| (x + 0.5).floor();
    // omode 6: the decimating mode the port always runs.
    let frfac = if frate * 5.0 < irate || frate > irate { 1.0 } else { frate.abs() / irate };

    let mut numr = if (frfac * 1001.0 - floor_half(frfac * 1001.0)).abs() < 0.01 {
        floor_half(frfac * 1001.0)
    } else if (1001.0 / frfac - floor_half(1001.0 / frfac)).abs() < 0.01 {
        1001.0
    } else {
        floor_half(frfac * 9000.0)
    };
    if (irate * numr / floor_half(numr / frfac) - frate).abs()
        > (irate * floor_half(frate * 100.0) / floor_half(irate * 100.0) - frate).abs()
    {
        numr = floor_half(frate * 100.0);
    }
    let denm = floor_half(numr / frfac);
    (frfac, numr as i64, denm as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(target: FrameRateTarget) -> UnblendParameters {
        UnblendParameters { enabled: true, target, ..Default::default() }
    }

    #[test]
    fn the_conversions_unblend_is_for_are_accepted() {
        // Film or PAL blended into PAL, double rate (50p after QTGMC).
        assert_eq!(params(FrameRateTarget::Film23976).ratio_at(50, 1), Ok((480, 1001)));
        assert_eq!(params(FrameRateTarget::Film24).ratio_at(50, 1), Ok((12, 25)));
        assert_eq!(params(FrameRateTarget::Pal25).ratio_at(50, 1), Ok((1, 2)));
        // Film or PAL blended into NTSC (59.94p after QTGMC).
        assert_eq!(params(FrameRateTarget::Film23976).ratio_at(60000, 1001), Ok((2, 5)));
        assert_eq!(params(FrameRateTarget::Pal25).ratio_at(60000, 1001), Ok((1001, 2400)));
        assert_eq!(params(FrameRateTarget::Ntsc2997).ratio_at(60000, 1001), Ok((1, 2)));
    }

    #[test]
    fn raising_the_rate_or_an_inexact_ratio_is_refused() {
        let up = params(FrameRateTarget::Pal50).ratio_at(25, 1).unwrap_err();
        assert!(up.contains("can only lower the frame rate"), "{up}");
        assert!(up.contains("from 25 fps"), "{up}");
        // srestore would make 59.94 -> 50 into 835/1001, not 1001/1200.
        assert!(params(FrameRateTarget::Pal50).ratio_at(60000, 1001).is_err());
        // Same rate: nothing to remove.
        assert!(params(FrameRateTarget::Pal25).ratio_at(25, 1).is_err());
        // Below a fifth.
        let low = UnblendParameters { target: FrameRateTarget::Custom, custom_fps: 10.0, ..params(FrameRateTarget::Custom) };
        assert!(low.ratio_at(60000, 1001).is_err());
    }

    /// Every rate pair of the probe's sweep (docs/reports/2026-11-srestore,
    /// `lengths.py`), produced by the Python port the script runs: the Rust
    /// arithmetic must give the same numr/denm and the same verdict, or the
    /// worker would accept a job the script then refuses (or the reverse).
    #[test]
    fn the_rust_ratio_matches_the_scripts_for_every_probed_pair() {
        let table: serde_json::Value = serde_json::from_str(include_str!(
            "../../../docs/reports/2026-11-srestore/data/ratio_table.json"
        ))
        .unwrap();
        let rows = table["rows"].as_array().unwrap();
        assert!(rows.len() >= 100);
        for row in rows {
            let pair = |k: &str| (row[k][0].as_u64().unwrap() as u32, row[k][1].as_u64().unwrap() as u32);
            let (s, t) = (pair("source"), pair("target"));
            let (frfac, numr, denm) = srestore_ratio(s.0, s.1, t.0, t.1);
            assert_eq!((numr, denm), (row["numr"].as_i64().unwrap(), row["denm"].as_i64().unwrap()), "{s:?} -> {t:?}");
            assert_eq!(frfac == 1.0, row["frfac"].as_f64().unwrap() == 1.0, "{s:?} -> {t:?}");
            let accepted = unblend_ratio(s.0, s.1, t.0, t.1).is_some();
            assert_eq!(accepted, row["accepted"].as_bool().unwrap(), "{s:?} -> {t:?}");
        }
    }

    #[test]
    fn an_old_pipeline_without_the_pass_deserialises_it_off() {
        let p: UnblendParameters = serde_json::from_str("{}").unwrap();
        assert!(!p.enabled);
        assert_eq!(p.target, FrameRateTarget::Film23976);
    }
}
