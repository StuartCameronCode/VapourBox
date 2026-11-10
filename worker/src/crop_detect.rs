//! Find what is not picture at the edges of a video: black borders and analog
//! blanking, the dim ramp beside them, wide letterbox / pillarbox bars, and the
//! head-switching band at the bottom of a tape capture (app 1.7.0,
//! `--detect-crop`). The result fills Crop & Resize's crop controls when the
//! user clicks Apply, the way Detect fills the Descale panel; nothing here is
//! ever applied on its own.
//!
//! Frames are sampled across the source (or its trim) and measured line by
//! line in plain Rust; no VapourSynth is involved. VCG Deinterlacer 2.0's
//! `analysis/edges.rs` (MIT) was read as a reference for which signals
//! separate these things; the code and its thresholds are our own, measured on
//! our fixtures (docs/reports/2026-11-crop-detect-709/).
//!
//! What each test is built against:
//!
//! * **Black and blanking** are dark AND flat. Brightness alone would eat into
//!   a night scene, so a line's brightness is a high percentile over every
//!   sampled frame — a line that carries picture in any of them is picture —
//!   and its detail must be low as well. Noisy blanking (grain out of the
//!   blanking interval) is dark but not perfectly flat, so detail has an
//!   absolute floor rather than only a fraction of the picture's.
//! * **The ramp**: past analog blanking the picture fades in over a few lines.
//!   It is followed only while each line is dimmer than the picture just inside
//!   it and the next is brighter, for at most a few lines, so dark content is
//!   never mistaken for one.
//! * **Bars wider than blanking ever is** (`BLANKING_MAX_FRACTION`) are the
//!   picture's framing — a letterboxed film inside 4:3, a 4:3 picture inside
//!   HD. They are reported separately and only cropped if the user asks.
//! * **Head switching** is a band of lines at the very bottom torn out of
//!   sequence with the picture: unlike the line above it in luma or chroma, or
//!   shifted sideways against it. Three things keep a picture from being read
//!   as one: the band must be in at least half the usable frames (a burnt-in
//!   subtitle or a hard edge comes and goes), torn across most of the width (a
//!   subtitle is a short run in the middle), and touch the bottom (a subtitle
//!   sits above the title-safe margin). On an interlaced source each field has
//!   its own band, so lines are compared with the line above *in the same
//!   field*.
//! * **Dark scenes and fades**: frames too dark to judge are left out of every
//!   statistic, and the report says how many frames were usable.

use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::dependency_locator::DependencyLocator;
use crate::models::{FieldOrder, ProcessingPipeline, Rotation, VideoJob};
use crate::source_decode;

/// Frames sampled across the source.
pub const SAMPLE_FRAMES: usize = 24;

/// Fraction of each dimension left out at both ends when measuring along the
/// other, so a bar on one axis cannot contaminate the other's statistics (the
/// head-switching band spans the whole width, for one).
const INSET: f64 = 0.12;

/// A line's brightness: this percentile of its samples over every usable
/// frame. A mean would be dragged down by dark content.
const LEVEL_PERCENTILE: f64 = 0.98;

/// A frame whose picture (the central region's 90th percentile) is darker than
/// this, on the 8-bit scale, tells nothing about where the picture stops.
const DARK_FRAME: f64 = 48.0;

/// A black/blanking line is no brighter than this fraction of the way from
/// black to the picture's typical line brightness...
const BLANK_LEVEL: f64 = 0.30;

/// ...and carries no more than this fraction of the picture's detail, or
/// `BLANK_DETAIL_FLOOR` levels, whichever is more.
const BLANK_DETAIL: f64 = 0.5;
const BLANK_DETAIL_FLOOR: f64 = 6.0;

/// Fewer dark lines than this is not a border (one dim line is a hard edge)...
const MIN_RUN: usize = 2;

/// ...unless it is black in every sampled frame: no sample brighter than
/// this many levels above black. Capture cards leave exactly one such line at
/// the top of a field (measured on our VHS fixture: 0 in every frame, where
/// the line below is picture).
const HARD_BLACK: f64 = 4.0;

/// Analog blanking and overscan borders are narrower than this fraction of the
/// dimension; anything wider is a bar (letterbox / pillarbox), reported but
/// not cropped unless asked. Blanking on a tape capture measures 1-3 %.
pub const BLANKING_MAX_FRACTION: f64 = 0.05;

/// No side is ever more than this fraction of its dimension: a "bar" wider
/// than that is a black picture, not framing.
const BAR_MAX_FRACTION: f64 = 0.35;

/// The ramp: at most this many lines, each below this fraction of the
/// picture's brightness just inside it.
const RAMP_MAX: usize = 6;
const RAMP_KNEE: f64 = 0.85;

/// The head-switching search covers this fraction of the height, from the
/// bottom (35 lines of 576: an interlaced band is two fields' worth).
const BAND_SEARCH_FRACTION: f64 = 0.06;

/// A band line is torn across at least this many of these segments of the
/// width — a subtitle is a short run in the middle.
const BAND_SEGMENTS: usize = 8;
const BAND_SEGMENTS_NEEDED: usize = 6;

/// A segment is torn when it differs from the line above by this many times
/// the picture's typical line-to-line difference, and by at least the floor
/// (8-bit levels; chroma's typical difference is far smaller than luma's).
const BAND_RATIO: f64 = 2.2;
const BAND_LUMA_FLOOR: f64 = 4.0;
const BAND_CHROMA_FLOOR: f64 = 2.5;

/// The sideways tear: the best horizontal match against the line above is at
/// least this far off, and much better than no shift.
const BAND_SHIFT_MAX: i32 = 16;
const BAND_SHIFT_MIN: i32 = 3;
const BAND_SHIFT_GAIN: f64 = 0.6;

/// A line is band when it is torn in at least this fraction of usable frames.
const BAND_FRAME_FRACTION: f64 = 0.5;

/// Lines at the very bottom that may be neither blank nor band before the band
/// starts, and lines inside the band that may miss the test.
const BAND_SKIP: usize = 2;
const BAND_GAP: usize = 1;

/// The widest band offered to Edge Repair instead of the crop: the Edge
/// Repair panel's own maximum. A band wider than that is cropped.
pub const EDGE_REPAIR_MAX: i32 = 16;

/// A frame agrees with an edge when its own measurement is within this.
const AGREEMENT: usize = 2;

/// The four sides of something.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sides {
    pub left: i32,
    pub right: i32,
    pub top: i32,
    pub bottom: i32,
}

impl Sides {
    pub fn is_zero(&self) -> bool {
        self.left == 0 && self.right == 0 && self.top == 0 && self.bottom == 0
    }
}

/// What one edge was found to be.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EdgeKind {
    #[default]
    None,
    /// Black border or analog blanking, narrow: cropped.
    Blanking,
    /// A letterbox / pillarbox bar: the picture's framing, cropped only if the
    /// user asks.
    Bar,
    /// The torn band at the bottom of a tape capture.
    HeadSwitching,
}

/// One edge, as measured (unrounded source lines).
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EdgeFinding {
    pub kind: EdgeKind,
    /// Dark, flat lines from the frame edge (blanking or bar).
    pub blank: i32,
    /// The dim ramp beside them.
    pub ramp: i32,
    /// Head-switching lines (bottom only), above the `blank` black lines at
    /// the very bottom, counting the up to two untorn lines between them.
    pub band: i32,
    /// A bar beyond the band (bottom only: a letterbox above a torn band).
    pub bar: i32,
    /// What the recommended crop removes here, before rounding.
    pub crop: i32,
    /// The same with any bar included.
    pub crop_with_bars: i32,
    /// Fraction of usable frames whose own measurement lands within 2 lines
    /// of this edge (0-1): the frames whose picture reaches it. The rest do
    /// not contradict it — their picture is dark there too — so a low value
    /// means thin evidence (a dark film), not a wrong edge.
    pub confidence: f64,
}

/// The four edges of the source, measured in its own orientation.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EdgeFindings {
    pub left: EdgeFinding,
    pub right: EdgeFinding,
    pub top: EdgeFinding,
    pub bottom: EdgeFinding,
}

/// One decoded frame, 8-bit 4:4:4 (chroma at luma resolution, so a chroma line
/// can be compared with the one above it).
pub struct Frame {
    pub width: usize,
    pub height: usize,
    pub y: Vec<u8>,
    pub u: Vec<u8>,
    pub v: Vec<u8>,
}

impl Frame {
    /// From planar `yuv444p` bytes, or `None` for a short decode.
    pub fn from_yuv444p(data: &[u8], width: usize, height: usize) -> Option<Frame> {
        let n = width * height;
        if data.len() < 3 * n {
            return None;
        }
        Some(Frame {
            width,
            height,
            y: data[..n].to_vec(),
            u: data[n..2 * n].to_vec(),
            v: data[2 * n..3 * n].to_vec(),
        })
    }
}

/// The inclusive-exclusive middle of one axis.
fn inset(n: usize) -> (usize, usize) {
    let lo = (n as f64 * INSET) as usize;
    let hi = n - lo;
    if hi > lo + 2 {
        (lo, hi)
    } else {
        (0, n)
    }
}

fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut v = values.to_vec();
    v.sort_by(|a, b| a.total_cmp(b));
    v[v.len() / 2]
}

/// The value at `pct` of a 256-bin histogram.
fn percentile(hist: &[u32], pct: f64) -> f64 {
    let total: u64 = hist.iter().map(|&c| c as u64).sum();
    if total == 0 {
        return 0.0;
    }
    let want = ((total as f64) * pct).ceil().max(1.0) as u64;
    let mut seen = 0u64;
    for (v, &c) in hist.iter().enumerate() {
        seen += c as u64;
        if seen >= want {
            return v as f64;
        }
    }
    255.0
}

/// Per-line statistics of one axis: brightness percentile and detail.
#[derive(Clone, Default)]
struct Lines {
    level: Vec<f64>,
    detail: Vec<f64>,
}

/// One frame's measurements.
struct FrameStats {
    cols: Lines,
    rows: Lines,
    /// Per bottom line (offset 0 = last line): torn in this frame.
    torn: Vec<bool>,
}

/// Columns (over the middle rows) and rows (over the middle columns), with
/// their histograms added into `col_hist` / `row_hist`.
fn line_stats(f: &Frame, col_hist: &mut [u32], row_hist: &mut [u32]) -> (Lines, Lines) {
    let (w, h) = (f.width, f.height);
    let (y0, y1) = inset(h);
    let (x0, x1) = inset(w);
    let mut ch = vec![0u32; w * 256];
    let mut col_detail = vec![0f64; w];
    for y in y0..y1 {
        let row = &f.y[y * w..(y + 1) * w];
        for (x, &v) in row.iter().enumerate() {
            ch[x * 256 + v as usize] += 1;
        }
        if y > y0 {
            let above = &f.y[(y - 1) * w..y * w];
            for x in 0..w {
                col_detail[x] += row[x].abs_diff(above[x]) as f64;
            }
        }
    }
    let n = (y1 - y0 - 1).max(1) as f64;
    let mut cols = Lines { level: vec![0.0; w], detail: vec![0.0; w] };
    for x in 0..w {
        let hist = &ch[x * 256..(x + 1) * 256];
        cols.level[x] = percentile(hist, LEVEL_PERCENTILE);
        cols.detail[x] = col_detail[x] / n;
        for (i, &c) in hist.iter().enumerate() {
            col_hist[x * 256 + i] += c;
        }
    }

    let mut rows = Lines { level: vec![0.0; h], detail: vec![0.0; h] };
    let mut rh = [0u32; 256];
    for y in 0..h {
        rh.fill(0);
        let row = &f.y[y * w..(y + 1) * w];
        let mut d = 0f64;
        for x in x0..x1 {
            rh[row[x] as usize] += 1;
            if x > x0 {
                d += row[x].abs_diff(row[x - 1]) as f64;
            }
        }
        rows.level[y] = percentile(&rh, LEVEL_PERCENTILE);
        rows.detail[y] = d / (x1 - x0 - 1).max(1) as f64;
        for (i, &c) in rh.iter().enumerate() {
            row_hist[y * 256 + i] += c;
        }
    }
    (cols, rows)
}

/// How unlike line `y` is from line `r` over the middle columns: per segment
/// in luma and in chroma, and the whole line in luma.
fn line_break(f: &Frame, y: usize, r: usize) -> ([f64; BAND_SEGMENTS], [f64; BAND_SEGMENTS], f64) {
    let w = f.width;
    let (x0, x1) = inset(w);
    let seg = ((x1 - x0) / BAND_SEGMENTS).max(1);
    let mut luma = [0f64; BAND_SEGMENTS];
    let mut chroma = [0f64; BAND_SEGMENTS];
    let mut total = 0f64;
    for s in 0..BAND_SEGMENTS {
        let a = x0 + s * seg;
        let b = (a + seg).min(x1);
        let (mut l, mut c) = (0f64, 0f64);
        for x in a..b {
            let (i, j) = (y * w + x, r * w + x);
            l += f.y[i].abs_diff(f.y[j]) as f64;
            c += (f.u[i].abs_diff(f.u[j]) as f64 + f.v[i].abs_diff(f.v[j]) as f64) / 2.0;
        }
        let n = (b - a).max(1) as f64;
        luma[s] = l / n;
        chroma[s] = c / n;
        total += l;
    }
    (luma, chroma, total / (seg * BAND_SEGMENTS) as f64)
}

/// Whether line `y` is shifted sideways against line `r`: its best match is
/// at least `BAND_SHIFT_MIN` columns off and much better than no shift.
fn shifted(f: &Frame, y: usize, r: usize, floor: f64) -> bool {
    let w = f.width;
    let (x0, x1) = inset(w);
    let lo = x0 as i32 + BAND_SHIFT_MAX;
    let hi = x1 as i32 - BAND_SHIFT_MAX;
    if hi <= lo + 8 {
        return false;
    }
    let sad = |s: i32| -> f64 {
        let mut t = 0f64;
        let mut n = 0f64;
        let mut x = lo;
        while x < hi {
            t += f.y[y * w + (x + s) as usize].abs_diff(f.y[r * w + x as usize]) as f64;
            n += 1.0;
            x += 2;
        }
        t / n
    };
    let zero = sad(0);
    if zero < floor {
        return false;
    }
    let (mut best, mut best_s) = (zero, 0);
    for s in -BAND_SHIFT_MAX..=BAND_SHIFT_MAX {
        let v = sad(s);
        if v < best {
            best = v;
            best_s = s;
        }
    }
    best_s.abs() >= BAND_SHIFT_MIN && best <= zero * BAND_SHIFT_GAIN
}

/// Which of the bottom `search` lines are torn in this frame. `d` is the
/// distance to the line above in the same field (2 when interlaced).
fn torn_lines(f: &Frame, search: usize, d: usize) -> Vec<bool> {
    let h = f.height;
    let (y0, y1) = inset(h);
    // The picture's own line-to-line difference, over the middle rows.
    let (mut refs_l, mut refs_c) = (Vec::new(), Vec::new());
    let mut y = y0.max(d);
    while y < y1 {
        let (l, c, _) = line_break(f, y, y - d);
        refs_l.push(l.iter().sum::<f64>() / BAND_SEGMENTS as f64);
        refs_c.push(c.iter().sum::<f64>() / BAND_SEGMENTS as f64);
        y += 2;
    }
    let ref_l = median(&refs_l);
    let ref_c = median(&refs_c);
    let luma_bar = (ref_l * BAND_RATIO).max(BAND_LUMA_FLOOR);
    let chroma_bar = (ref_c * BAND_RATIO).max(BAND_CHROMA_FLOOR);
    (0..search)
        .map(|o| {
            let y = h - 1 - o;
            if y < d {
                return false;
            }
            let (l, c, _) = line_break(f, y, y - d);
            let torn_l = l.iter().filter(|&&v| v > luma_bar).count();
            let torn_c = c.iter().filter(|&&v| v > chroma_bar).count();
            torn_l >= BAND_SEGMENTS_NEEDED
                || torn_c >= BAND_SEGMENTS_NEEDED
                || shifted(f, y, y - d, (ref_l * 1.5).max(3.0))
        })
        .collect()
}

/// The central region's 90th percentile luma: how bright the picture is.
fn picture_level(f: &Frame) -> f64 {
    let (x0, x1) = inset(f.width);
    let (y0, y1) = inset(f.height);
    let mut hist = [0u32; 256];
    for y in (y0..y1).step_by(2) {
        for x in (x0..x1).step_by(2) {
            hist[f.y[y * f.width + x] as usize] += 1;
        }
    }
    percentile(&hist, 0.9)
}

/// Dark, flat lines from the start of `level`, up to `limit`.
fn blank_run(level: &[f64], detail: &[f64], level_bar: f64, detail_bar: f64, limit: usize) -> usize {
    let mut k = 0;
    while k < limit.min(level.len()) && level[k] <= level_bar && detail[k] <= detail_bar {
        k += 1;
    }
    k
}

/// `blank_run`, less a run too short to be a border.
fn border_run(level: &[f64], detail: &[f64], level_bar: f64, detail_bar: f64, limit: usize, black: f64) -> usize {
    let k = blank_run(level, detail, level_bar, detail_bar, limit);
    if k >= MIN_RUN || (k == 1 && level[0] <= black + HARD_BLACK) {
        k
    } else {
        0
    }
}

/// The dim ramp after `k` dark lines.
fn ramp_after(level: &[f64], k: usize, limit: usize) -> usize {
    if k == 0 {
        return 0;
    }
    let inner: Vec<f64> = level.iter().skip(k + 6).take(8).copied().collect();
    let reference = median(&inner);
    let mut r = 0;
    while r < RAMP_MAX
        && k + r + 1 < limit.min(level.len())
        && level[k + r] < reference * RAMP_KNEE
        && level[k + r + 1] > level[k + r]
    {
        r += 1;
    }
    r
}

/// The measurement, before any rounding or orientation.
#[derive(Debug, Clone, PartialEq)]
pub struct Analysis {
    pub edges: EdgeFindings,
    pub usable_frames: usize,
    /// Why nothing could be measured, when that is the case.
    pub inconclusive: Option<String>,
}

/// Measure `frames` (all the same size). `interlaced` compares each line with
/// the one above it in the same field; `full_range` puts black at 0, not 16.
pub fn analyse(frames: &[Frame], interlaced: bool, full_range: bool) -> Analysis {
    let mut result = Analysis { edges: EdgeFindings::default(), usable_frames: 0, inconclusive: None };
    let Some(first) = frames.first() else {
        result.inconclusive = Some("No frames could be decoded.".into());
        return result;
    };
    let (w, h) = (first.width, first.height);
    if w < 32 || h < 32 {
        result.inconclusive = Some(format!("The video is too small to analyse ({w}x{h})."));
        return result;
    }
    let d = if interlaced { 2 } else { 1 };
    let search = ((h as f64 * BAND_SEARCH_FRACTION) as usize).max(4);

    let mut col_hist = vec![0u32; w * 256];
    let mut row_hist = vec![0u32; h * 256];
    let mut per_frame = Vec::new();
    for f in frames.iter().filter(|f| f.width == w && f.height == h) {
        if picture_level(f) < DARK_FRAME {
            continue;
        }
        let (cols, rows) = line_stats(f, &mut col_hist, &mut row_hist);
        per_frame.push(FrameStats { cols, rows, torn: torn_lines(f, search, d) });
    }
    result.usable_frames = per_frame.len();
    if per_frame.is_empty() {
        result.inconclusive = Some(
            "Every sampled frame is too dark to show where the picture stops.".into(),
        );
        return result;
    }

    // The whole sample, line by line.
    let n = per_frame.len() as f64;
    let mean = |pick: &dyn Fn(&FrameStats) -> &Vec<f64>, len: usize| -> Vec<f64> {
        let mut acc = vec![0f64; len];
        for fs in &per_frame {
            for (a, v) in acc.iter_mut().zip(pick(fs)) {
                *a += v / n;
            }
        }
        acc
    };
    let cols = Lines {
        level: (0..w).map(|x| percentile(&col_hist[x * 256..(x + 1) * 256], LEVEL_PERCENTILE)).collect(),
        detail: mean(&|fs| &fs.cols.detail, w),
    };
    let rows = Lines {
        level: (0..h).map(|y| percentile(&row_hist[y * 256..(y + 1) * 256], LEVEL_PERCENTILE)).collect(),
        detail: mean(&|fs| &fs.rows.detail, h),
    };

    let black = if full_range { 0.0 } else { 16.0 };
    let (x0, x1) = inset(w);
    let (y0, y1) = inset(h);
    let col_plateau = median(&cols.level[x0..x1]);
    let row_plateau = median(&rows.level[y0..y1]);
    let col_bar = black + BLANK_LEVEL * (col_plateau - black);
    let row_bar = black + BLANK_LEVEL * (row_plateau - black);
    let col_flat = (median(&cols.detail[x0..x1]) * BLANK_DETAIL).max(BLANK_DETAIL_FLOOR);
    let row_flat = (median(&rows.detail[y0..y1]) * BLANK_DETAIL).max(BLANK_DETAIL_FLOOR);
    let rev = |v: &[f64]| -> Vec<f64> { v.iter().rev().copied().collect() };

    // One side: the dark run and the ramp, and how many frames agree.
    let side = |level: &[f64], detail: &[f64], bar: f64, flat: f64, len: usize, per: &dyn Fn(&FrameStats) -> (Vec<f64>, Vec<f64>)| -> EdgeFinding {
        let limit = (len as f64 * BAR_MAX_FRACTION) as usize;
        let blank = border_run(level, detail, bar, flat, limit, black);
        let ramp = ramp_after(level, blank, limit);
        let agree = per_frame
            .iter()
            .filter(|fs| {
                let (l, dd) = per(fs);
                border_run(&l, &dd, bar, flat, limit, black).abs_diff(blank) <= AGREEMENT
            })
            .count();
        let is_bar = blank as f64 > len as f64 * BLANKING_MAX_FRACTION;
        let total = (blank + ramp) as i32;
        EdgeFinding {
            kind: if blank == 0 {
                EdgeKind::None
            } else if is_bar {
                EdgeKind::Bar
            } else {
                EdgeKind::Blanking
            },
            blank: blank as i32,
            ramp: ramp as i32,
            band: 0,
            bar: if is_bar { total } else { 0 },
            crop: if is_bar { 0 } else { total },
            crop_with_bars: total,
            confidence: agree as f64 / n,
        }
    };

    result.edges.left = side(&cols.level, &cols.detail, col_bar, col_flat, w,
        &|fs| (fs.cols.level.clone(), fs.cols.detail.clone()));
    result.edges.right = side(&rev(&cols.level), &rev(&cols.detail), col_bar, col_flat, w,
        &|fs| (rev(&fs.cols.level), rev(&fs.cols.detail)));
    result.edges.top = side(&rows.level, &rows.detail, row_bar, row_flat, h,
        &|fs| (fs.rows.level.clone(), fs.rows.detail.clone()));
    let mut bottom = side(&rev(&rows.level), &rev(&rows.detail), row_bar, row_flat, h,
        &|fs| (rev(&fs.rows.level), rev(&fs.rows.detail)));

    // Head switching, upward from any dark lines at the very bottom.
    let torn_fraction: Vec<f64> = (0..search)
        .map(|o| per_frame.iter().filter(|fs| fs.torn[o]).count() as f64 / n)
        .collect();
    let is_band = |o: usize| o < search && torn_fraction[o] >= BAND_FRAME_FRACTION;
    let start = if bottom.kind == EdgeKind::Bar { 0 } else { bottom.blank as usize };
    let mut o = start;
    while o < start + BAND_SKIP && o < search && !is_band(o) {
        o += 1;
    }
    if is_band(o) {
        let first = o;
        let mut last = o;
        let mut gap = 0;
        while o < search {
            if is_band(o) {
                last = o;
                gap = 0;
            } else {
                gap += 1;
                if gap > BAND_GAP {
                    break;
                }
            }
            o += 1;
        }
        let rows_torn = (first..=last).filter(|&o| is_band(o)).count();
        if rows_torn >= MIN_RUN {
            let band_end = last + 1;
            let rrows = rev(&rows.level);
            let rdetail = rev(&rows.detail);
            // Anything dark above the band: blanking, or a letterbox bar.
            let limit = (h as f64 * BAR_MAX_FRACTION) as usize;
            let above = border_run(&rrows[band_end..], &rdetail[band_end..], row_bar, row_flat, limit, black);
            let ramp = ramp_after(&rrows[band_end..], above, limit);
            let above_is_bar = above as f64 > h as f64 * BLANKING_MAX_FRACTION;
            let band_conf = (first..=last).map(|o| torn_fraction[o]).sum::<f64>()
                / (last - first + 1) as f64;
            let dark_below = if bottom.kind == EdgeKind::Bar { 0 } else { bottom.blank };
            bottom = EdgeFinding {
                kind: EdgeKind::HeadSwitching,
                // Black lines below the band, the band, then whatever dark
                // lines sit above it: blanking (cropped with it, counted as
                // ramp here) or a bar (kept apart).
                blank: dark_below,
                ramp: if above_is_bar { 0 } else { (above + ramp) as i32 },
                band: (band_end - start) as i32,
                bar: if above_is_bar { (above + ramp) as i32 } else { 0 },
                crop: if above_is_bar {
                    band_end as i32
                } else {
                    (band_end + above + ramp) as i32
                },
                crop_with_bars: (band_end + above + ramp) as i32,
                confidence: band_conf,
            };
        }
    }
    result.edges.bottom = bottom;
    result
}

/// What `--detect-crop` prints.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CropReport {
    /// Whether anything worth cropping was found.
    pub found: bool,
    /// The source's size.
    pub width: i32,
    pub height: i32,
    /// Whether lines were compared within each field.
    pub interlaced: bool,
    /// Frames sampled, and how many were bright enough to use.
    pub frames: Vec<i32>,
    pub usable_frames: i32,
    /// The recommended crop for the Crop controls: blanking, ramps and the
    /// head-switching band, not bars. In the orientation the Crop pass sees
    /// (after Rotate / Flip), rounded outward to the steps below.
    pub crop: Sides,
    /// The same with letterbox / pillarbox bars included; `None` with no bars.
    pub crop_with_bars: Option<Sides>,
    /// Edge Repair's widths for repairing the head-switching band instead of
    /// cropping it (in the source's own orientation, which is the one Edge
    /// Repair works in), with `crop_with_repair` for the rest; `None` with no
    /// band.
    pub edge_repair: Option<Sides>,
    pub crop_with_repair: Option<Sides>,
    /// Each edge as measured, in the Crop pass's orientation.
    pub edges: EdgeFindings,
    /// The lowest confidence among the edges that found something.
    pub confidence: f64,
    /// Horizontal and vertical rounding steps the crop obeys.
    pub step_x: i32,
    pub step_y: i32,
    /// Why nothing was found, in words, when that is the case.
    pub message: Option<String>,
}

/// Round `v` up to a multiple of `step`.
fn round_up(v: i32, step: i32) -> i32 {
    (v.max(0) + step - 1) / step * step
}

/// Map the source's four sides to the orientation after Rotate / Flip, which
/// is the one the Crop pass works in.
pub fn orient<T: Copy>(pipeline: &ProcessingPipeline, left: T, right: T, top: T, bottom: T) -> (T, T, T, T) {
    let g = &pipeline.geometry;
    if !g.has_effect() {
        return (left, right, top, bottom);
    }
    // A clockwise quarter turn puts the source's left edge at the top.
    let (l, r, t, b) = match g.rotation {
        Rotation::None => (left, right, top, bottom),
        Rotation::Cw90 => (bottom, top, left, right),
        Rotation::Rotate180 => (right, left, bottom, top),
        Rotation::Ccw90 => (top, bottom, right, left),
    };
    let (l, r) = if g.flip_horizontal { (r, l) } else { (l, r) };
    let (t, b) = if g.flip_vertical { (b, t) } else { (t, b) };
    (l, r, t, b)
}

/// The rounding steps for a job's crop: even everywhere (the Crop controls
/// move in twos, which keeps 4:2:0 and 4:2:2 chroma aligned), and a multiple
/// of four vertically when a 4:2:0 picture is still interlaced at the crop —
/// each field's chroma lines alternate too, so cropping two lines would swap
/// them.
pub fn steps(job: &VideoJob) -> (i32, i32) {
    let pipeline = job.effective_pipeline();
    let pipe = crate::pixel_format::decode_pixel_format(job.input_pixel_format.as_deref());
    let (class, _) = crate::pixel_format::chroma_and_depth(&pipe.name);
    let still_interlaced =
        crate::script_generator::ScriptGenerator::still_interlaced_tff(job, &pipeline).is_some();
    let y = if still_interlaced && class == crate::pixel_format::ChromaClass::C420 { 4 } else { 2 };
    (2, y)
}

/// Turn the measurement into the report: orientation, rounding, the
/// alternatives.
pub fn report_from(analysis: &Analysis, job: &VideoJob, frames: Vec<i32>, interlaced: bool) -> CropReport {
    let pipeline = job.effective_pipeline();
    let (sx, sy) = steps(job);
    let e = &analysis.edges;
    let (w, h) = (job.input_width.unwrap_or(0), job.input_height.unwrap_or(0));

    // Rounded in the Crop pass's orientation: a side that ends up horizontal
    // rounds to the horizontal step.
    let place = |pick: &dyn Fn(&EdgeFinding) -> i32| -> Sides {
        let (l, r, t, b) = orient(&pipeline, pick(&e.left), pick(&e.right), pick(&e.top), pick(&e.bottom));
        Sides {
            left: round_up(l, sx),
            right: round_up(r, sx),
            top: round_up(t, sy),
            bottom: round_up(b, sy),
        }
    };
    let crop = place(&|f| f.crop);
    let with_bars = place(&|f| f.crop_with_bars);
    let has_bars = [e.left, e.right, e.top, e.bottom].iter().any(|f| f.bar > 0);

    // The band can be repaired instead: Edge Repair rebuilds the bottom lines
    // in the source's orientation (it runs before Rotate / Flip), and the crop
    // keeps everything else it found.
    // Edge Repair works from the frame's edge, so it covers any black lines
    // below the band as well as the band.
    let (edge_repair, crop_with_repair) = if e.bottom.kind == EdgeKind::HeadSwitching && e.bottom.band > 0 {
        let reach = e.bottom.blank + e.bottom.band;
        let repair = crate::models::EdgeRepairParameters::even(round_up(reach, 2));
        if repair >= reach && repair <= EDGE_REPAIR_MAX {
            let mut rest = *e;
            rest.bottom.crop -= reach;
            let (l, r, t, b) = orient(&pipeline, rest.left.crop, rest.right.crop, rest.top.crop, rest.bottom.crop);
            (
                Some(Sides { bottom: repair, ..Sides::default() }),
                Some(Sides {
                    left: round_up(l, sx),
                    right: round_up(r, sx),
                    top: round_up(t, sy),
                    bottom: round_up(b, sy),
                }),
            )
        } else {
            (None, None)
        }
    } else {
        (None, None)
    };

    let (l, r, t, b) = orient(&pipeline, e.left, e.right, e.top, e.bottom);
    let edges = EdgeFindings { left: l, right: r, top: t, bottom: b };
    let confidence = [l, r, t, b]
        .iter()
        .filter(|f| f.kind != EdgeKind::None)
        .map(|f| f.confidence)
        .fold(1.0, f64::min);
    let found = analysis.inconclusive.is_none() && (!crop.is_zero() || has_bars);
    let message = match &analysis.inconclusive {
        Some(m) => Some(m.clone()),
        None if !found => Some("No black borders, blanking or head-switching noise at the edges.".into()),
        None => None,
    };
    CropReport {
        found,
        width: w,
        height: h,
        interlaced,
        frames,
        usable_frames: analysis.usable_frames as i32,
        crop,
        crop_with_bars: has_bars.then_some(with_bars),
        edge_repair,
        crop_with_repair,
        edges,
        confidence,
        step_x: sx,
        step_y: sy,
        message,
    }
}

/// Which frames to sample: `SAMPLE_FRAMES` spread through the clip or its
/// trim, leaving the first and last 5 % (titles, fades).
pub fn sample_frames(total: Option<u64>, start: Option<u64>, end: Option<u64>) -> Vec<i32> {
    sample_frames_n(SAMPLE_FRAMES, total, start, end)
}

/// [`sample_frames`] with `count` samples instead of `SAMPLE_FRAMES`.
pub fn sample_frames_n(count: usize, total: Option<u64>, start: Option<u64>, end: Option<u64>) -> Vec<i32> {
    let first = start.unwrap_or(0);
    let last = match (end, total) {
        (Some(e), _) => e,
        (None, Some(t)) if t > 0 => t - 1,
        _ => return vec![first as i32],
    };
    if last <= first {
        return vec![first as i32];
    }
    let span = (last - first) as f64;
    let mut frames: Vec<i32> = (0..count)
        .map(|i| (first as f64 + span * (0.05 + 0.9 * (i as f64 + 0.5) / count as f64)).round() as i32)
        .collect();
    frames.dedup();
    frames
}

/// Whether the source's lines alternate between two fields.
pub fn is_interlaced(job: &VideoJob) -> bool {
    matches!(
        job.detected_field_order,
        Some(FieldOrder::TopFieldFirst) | Some(FieldOrder::BottomFieldFirst)
    )
}

/// The job's probed frame size, or the error every detector reports.
pub fn frame_size(job: &VideoJob) -> Result<(i32, i32)> {
    match (job.input_width, job.input_height) {
        (Some(w), Some(h)) if w > 0 && h > 0 => Ok((w, h)),
        _ => bail!("The video's size is unknown; re-add it to the queue."),
    }
}

/// Decode `count` consecutive frames from each of `frames` (source frame
/// numbers) as raw `pix_fmt`, a few decoders at a time (each seeks on its
/// own), and turn each decoder's output into a `T` with `parse` (`None` for a
/// short decode). A sample that fails is skipped as long as enough others
/// decode; the samples that did come back are returned in order. Shared by
/// the detectors (`--detect-crop`, `--detect-noise-halo`), so they sample and
/// decode the same way: the stored frame at its probed size, never resampled.
pub fn decode_samples<T: Send>(
    deps: &DependencyLocator,
    job: &VideoJob,
    frames: &[i32],
    count: i32,
    pix_fmt: &str,
    parse: impl Fn(&[u8]) -> Option<T> + Sync,
) -> Result<Vec<T>> {
    let ffmpeg = deps.ffmpeg_path()?;
    let env = deps.build_environment();
    let (width, height) = frame_size(job)?;
    let fps = job.input_frame_rate.filter(|f| *f > 0.0).unwrap_or(29.97);

    let decode = |frame: i32| -> Result<T> {
        let seek = ((frame as f64 - 0.5) / fps).max(0.0);
        let out = Command::new(&ffmpeg)
            .args(source_decode::preview_decoder_args(
                &job.input_path, seek, count, width, height, pix_fmt, "pipe:1",
            ))
            .envs(&env)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .context("running ffmpeg")?;
        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            if let Some(msg) = source_decode::explain_decoder_failure(&stderr, width, height) {
                bail!("{msg}");
            }
            bail!("Could not decode frame {frame}: {stderr}");
        }
        parse(&out.stdout).with_context(|| format!("short decode at frame {frame}"))
    };
    let decode = &decode;
    let mut decoded = Vec::new();
    for chunk in frames.chunks(4) {
        let results: Vec<Result<T>> = std::thread::scope(|scope| {
            let handles: Vec<_> = chunk.iter().map(|&f| scope.spawn(move || decode(f))).collect();
            handles.into_iter().map(|h| h.join().unwrap_or_else(|_| bail!("decoder thread panicked"))).collect()
        });
        for r in results {
            match r {
                Ok(f) => decoded.push(f),
                // A frame past a damaged stretch is not worth failing for, as
                // long as enough others decode.
                Err(e) if decoded.len() + frames.len() > 6 => eprintln!("detect: {e:#}"),
                Err(e) => return Err(e),
            }
        }
    }
    if decoded.is_empty() {
        bail!("No frames could be decoded.");
    }
    Ok(decoded)
}

/// Decode the sample frames and measure them.
pub fn detect(deps: &DependencyLocator, job: &VideoJob) -> Result<CropReport> {
    let (width, height) = frame_size(job)?;
    let frames = sample_frames(
        job.total_frames.map(|f| f.max(0) as u64),
        job.start_frame.map(|f| f.max(0) as u64),
        job.end_frame.map(|f| f.max(0) as u64),
    );
    let decoded = decode_samples(deps, job, &frames, 1, "yuv444p", |bytes| {
        Frame::from_yuv444p(bytes, width as usize, height as usize)
    })?;
    let interlaced = is_interlaced(job);
    let analysis = analyse(&decoded, interlaced, job.color_metadata().is_full_range());
    Ok(report_from(&analysis, job, frames, interlaced))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{GeometryParameters, QTGMCParameters};

    /// A deterministic noise source, so fixtures are repeatable.
    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self) -> f64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((self.0 >> 33) as f64) / (1u64 << 31) as f64
        }
        fn noise(&mut self, amp: f64) -> f64 {
            (self.next() - 0.5) * 2.0 * amp
        }
    }

    /// What to draw into a fixture.
    #[derive(Clone, Copy, Default)]
    struct Spec {
        w: usize,
        h: usize,
        /// Black borders / blanking per side.
        left: usize,
        right: usize,
        top: usize,
        bottom: usize,
        /// A dim ramp of this many columns inside the left and right borders.
        ramp: usize,
        /// Noise in the blanking (levels).
        blank_noise: f64,
        /// Head-switching lines at the bottom (per frame, i.e. both fields).
        band: usize,
        /// A burnt-in subtitle in this fraction of frames, its bottom this
        /// many lines above the frame's bottom.
        subtitle_every: usize,
        subtitle_gap: usize,
        /// Every n-th frame is a fade to (near) black.
        dark_every: usize,
        /// The picture is interlaced: fields differ (motion).
        interlaced: bool,
        /// The picture's own edge columns are dark in most frames (a night scene).
        dark_edges: bool,
    }

    /// A frame of picture: gradients, texture and noise, moving with `t`.
    fn frame(spec: &Spec, t: usize, rng: &mut Lcg) -> Frame {
        let (w, h) = (spec.w, spec.h);
        let mut y = vec![16u8; w * h];
        let mut u = vec![128u8; w * h];
        let mut v = vec![128u8; w * h];
        let dark = spec.dark_every > 0 && t % spec.dark_every == 0;
        for yy in spec.top..h - spec.bottom {
            for xx in spec.left..w - spec.right {
                let field_shift = if spec.interlaced && yy % 2 == 1 { 3.0 } else { 0.0 };
                let xs = xx as f64 + t as f64 * 5.0 + field_shift;
                let base = 60.0 + 100.0 * (0.5 + 0.5 * (xs / 37.0).sin() * (yy as f64 / 23.0).cos());
                let mut lum = base + rng.noise(6.0);
                if spec.dark_edges && t % 4 != 0 {
                    let edge = (xx.min(w - 1 - xx) as f64 / (w as f64 * 0.15)).min(1.0);
                    lum = 16.0 + (lum - 16.0) * edge;
                }
                if dark {
                    lum = 18.0 + rng.noise(2.0);
                }
                let i = yy * w + xx;
                y[i] = lum.clamp(16.0, 235.0) as u8;
                u[i] = (128.0 + 20.0 * (xs / 61.0).sin() + rng.noise(2.0)) as u8;
                v[i] = (128.0 + 20.0 * (yy as f64 / 41.0).cos() + rng.noise(2.0)) as u8;
            }
        }
        // The ramp: columns inside each side border fade in.
        for r in 0..spec.ramp {
            let k = (r + 1) as f64 / (spec.ramp + 1) as f64;
            for yy in 0..h {
                for xx in [spec.left + r, w - 1 - spec.right - r] {
                    let i = yy * w + xx;
                    y[i] = (16.0 + (y[i] as f64 - 16.0) * k * 0.6) as u8;
                }
            }
        }
        // Noisy blanking.
        if spec.blank_noise > 0.0 {
            for yy in 0..h {
                for xx in (0..spec.left).chain(w - spec.right..w) {
                    y[yy * w + xx] = (16.0 + rng.noise(spec.blank_noise).abs()) as u8;
                }
            }
        }
        // A subtitle: a short run of bright text-like blocks in the middle.
        if spec.subtitle_every > 0 && t % spec.subtitle_every == 0 {
            let bottom = h - spec.bottom - spec.subtitle_gap;
            for yy in bottom - 18..bottom {
                for xx in w * 3 / 8..w * 5 / 8 {
                    if (xx / 7 + yy / 5 + t) % 3 != 0 {
                        y[yy * w + xx] = 230;
                    }
                }
            }
        }
        // Head switching: the bottom lines torn sideways with smeared, noisy
        // luma and wrecked chroma.
        for o in 0..spec.band {
            let yy = h - 1 - o;
            let shift = 6 + (o * 3 + t) % 9;
            let row: Vec<u8> = y[(yy - 8) * w..(yy - 7) * w].to_vec();
            for xx in 0..w {
                let i = yy * w + xx;
                let src = row[(xx + w - shift) % w] as f64;
                y[i] = (src * 0.7 + 40.0 + rng.noise(25.0)).clamp(16.0, 235.0) as u8;
                u[i] = (128.0 + rng.noise(40.0)) as u8;
                v[i] = (128.0 + rng.noise(40.0)) as u8;
            }
        }
        Frame { width: w, height: h, y, u, v }
    }

    fn frames(spec: &Spec, n: usize) -> Vec<Frame> {
        let mut rng = Lcg(42);
        (0..n).map(|t| frame(spec, t, &mut rng)).collect()
    }

    fn sd(spec: Spec) -> Spec {
        Spec { w: 720, h: 576, ..spec }
    }

    fn near(actual: i32, expected: usize, what: &str) {
        assert!(
            (actual - expected as i32).abs() <= 2,
            "{what}: measured {actual}, expected {expected} (within 2)"
        );
    }

    #[test]
    fn blanking_ramps_and_band_are_found_within_two_lines() {
        let spec = sd(Spec { left: 12, right: 8, top: 4, bottom: 0, ramp: 0, band: 8, ..Spec::default() });
        let a = analyse(&frames(&spec, 16), false, false);
        assert!(a.inconclusive.is_none());
        near(a.edges.left.crop, 12, "left");
        near(a.edges.right.crop, 8, "right");
        near(a.edges.top.crop, 4, "top");
        assert_eq!(a.edges.bottom.kind, EdgeKind::HeadSwitching);
        near(a.edges.bottom.crop, 8, "bottom band");
        assert_eq!(a.edges.left.kind, EdgeKind::Blanking);
        assert!(a.edges.left.confidence > 0.9);
    }

    #[test]
    fn a_ramp_is_followed_but_not_into_the_picture() {
        let spec = sd(Spec { left: 10, right: 10, ramp: 3, ..Spec::default() });
        let a = analyse(&frames(&spec, 16), false, false);
        near(a.edges.left.crop, 13, "left with ramp");
        near(a.edges.right.crop, 13, "right with ramp");
        assert!(a.edges.left.ramp >= 1, "the ramp is reported");
    }

    #[test]
    fn noisy_blanking_is_still_blanking() {
        let spec = sd(Spec { left: 14, right: 14, blank_noise: 14.0, ..Spec::default() });
        let a = analyse(&frames(&spec, 16), false, false);
        near(a.edges.left.crop, 14, "noisy left");
        near(a.edges.right.crop, 14, "noisy right");
    }

    #[test]
    fn one_line_of_true_black_counts_but_one_dim_line_does_not() {
        let a = analyse(&frames(&sd(Spec { top: 1, ..Spec::default() }), 12), false, false);
        assert_eq!(a.edges.top.crop, 1, "a capture card's black first line");
        // A single dark-but-not-black line is a hard edge in the picture.
        let mut fs = frames(&sd(Spec::default()), 12);
        for f in &mut fs {
            for x in 0..f.width {
                f.y[x] = 40;
            }
        }
        let a = analyse(&fs, false, false);
        assert_eq!(a.edges.top.crop, 0);
    }

    #[test]
    fn a_clean_frame_has_nothing_to_crop() {
        let a = analyse(&frames(&sd(Spec::default()), 16), false, false);
        assert_eq!(a.edges.left.crop + a.edges.right.crop + a.edges.top.crop + a.edges.bottom.crop, 0);
        assert_eq!(a.edges.bottom.kind, EdgeKind::None);
    }

    #[test]
    fn letterbox_bars_are_reported_but_not_cropped_by_default() {
        let spec = sd(Spec { top: 72, bottom: 72, left: 8, right: 8, ..Spec::default() });
        let a = analyse(&frames(&spec, 16), false, false);
        assert_eq!(a.edges.top.kind, EdgeKind::Bar);
        assert_eq!(a.edges.bottom.kind, EdgeKind::Bar);
        assert_eq!(a.edges.top.crop, 0);
        near(a.edges.top.crop_with_bars, 72, "letterbox top");
        near(a.edges.bottom.crop_with_bars, 72, "letterbox bottom");
        near(a.edges.left.crop, 8, "blanking beside a letterbox");
    }

    #[test]
    fn a_band_under_a_letterbox_is_cropped_and_the_bar_kept() {
        // Head switching appears at the bottom of the frame whatever the
        // picture's framing, so it tears the bottom of the bar.
        let spec = sd(Spec { top: 72, bottom: 72, band: 8, ..Spec::default() });
        let a = analyse(&frames(&spec, 16), false, false);
        assert_eq!(a.edges.bottom.kind, EdgeKind::HeadSwitching);
        near(a.edges.bottom.crop, 8, "band only");
        near(a.edges.bottom.crop_with_bars, 72, "band and bar");
    }

    #[test]
    fn a_subtitle_near_the_bottom_is_not_head_switching() {
        // In most frames, ending only 6 lines above the bottom.
        let spec = sd(Spec { subtitle_every: 1, subtitle_gap: 6, ..Spec::default() });
        let a = analyse(&frames(&spec, 16), false, false);
        assert_ne!(a.edges.bottom.kind, EdgeKind::HeadSwitching);
        assert_eq!(a.edges.bottom.crop, 0);
        // And with a real band beneath it, only the band is taken.
        let spec = sd(Spec { subtitle_every: 1, subtitle_gap: 10, band: 6, ..Spec::default() });
        let a = analyse(&frames(&spec, 16), false, false);
        near(a.edges.bottom.crop, 6, "band under a subtitle");
    }

    #[test]
    fn fades_and_dark_edges_do_not_widen_the_crop() {
        let spec = sd(Spec { left: 10, right: 10, dark_every: 3, dark_edges: true, ..Spec::default() });
        let a = analyse(&frames(&spec, 24), false, false);
        assert!(a.usable_frames < 24, "the fades are left out");
        near(a.edges.left.crop, 10, "left in a dark film");
        near(a.edges.right.crop, 10, "right in a dark film");
    }

    #[test]
    fn an_all_black_sample_is_inconclusive() {
        let spec = sd(Spec { dark_every: 1, ..Spec::default() });
        let a = analyse(&frames(&spec, 8), false, false);
        assert!(a.inconclusive.is_some());
    }

    #[test]
    fn interlaced_band_is_measured_per_field() {
        let spec = sd(Spec { left: 8, right: 8, band: 12, interlaced: true, ..Spec::default() });
        let a = analyse(&frames(&spec, 16), true, false);
        assert_eq!(a.edges.bottom.kind, EdgeKind::HeadSwitching);
        near(a.edges.bottom.crop, 12, "interlaced band");
        near(a.edges.left.crop, 8, "interlaced left");
    }

    #[test]
    fn hd_pillarbox_is_a_bar() {
        let spec = Spec { w: 960, h: 540, left: 120, right: 120, ..Spec::default() };
        let a = analyse(&frames(&spec, 12), false, false);
        assert_eq!(a.edges.left.kind, EdgeKind::Bar);
        near(a.edges.left.crop_with_bars, 120, "pillarbox");
        assert_eq!(a.edges.left.crop, 0);
    }

    fn job(w: i32, h: i32, pix: &str, field: Option<FieldOrder>, pipeline: ProcessingPipeline) -> VideoJob {
        let mut j: VideoJob = serde_json::from_value(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000000",
            "inputPath": "in.avi",
            "outputPath": "out.mkv",
            "qtgmcParameters": {},
            "encodingSettings": {},
        }))
        .unwrap();
        j.input_width = Some(w);
        j.input_height = Some(h);
        j.input_pixel_format = Some(pix.into());
        j.detected_field_order = field;
        j.processing_pipeline = Some(pipeline);
        j
    }

    fn analysis(left: i32, right: i32, top: i32, band: i32) -> Analysis {
        let f = |crop: i32, kind| EdgeFinding { kind, blank: crop, crop, crop_with_bars: crop, confidence: 1.0, ..Default::default() };
        Analysis {
            edges: EdgeFindings {
                left: f(left, EdgeKind::Blanking),
                right: f(right, EdgeKind::Blanking),
                top: f(top, EdgeKind::Blanking),
                bottom: EdgeFinding {
                    kind: EdgeKind::HeadSwitching,
                    band,
                    crop: band,
                    crop_with_bars: band,
                    confidence: 0.8,
                    ..Default::default()
                },
            },
            usable_frames: 10,
            inconclusive: None,
        }
    }

    #[test]
    fn the_report_rounds_outward_to_steps_the_crop_pass_accepts() {
        let progressive = ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            ..ProcessingPipeline::default()
        };
        let r = report_from(&analysis(11, 9, 3, 7), &job(720, 576, "yuv420p", None, progressive.clone()), vec![1], false);
        assert!(r.found);
        assert_eq!(r.crop, Sides { left: 12, right: 10, top: 4, bottom: 8 });
        assert_eq!((r.step_x, r.step_y), (2, 2));
        assert_eq!(r.confidence, 0.8);
        // The band can be repaired instead: Edge Repair at the bottom, crop the rest.
        assert_eq!(r.edge_repair, Some(Sides { bottom: 8, ..Sides::default() }));
        assert_eq!(r.crop_with_repair, Some(Sides { left: 12, right: 10, top: 4, bottom: 0 }));
        // Still interlaced 4:2:0 at the crop: vertical in fours.
        let r = report_from(
            &analysis(11, 9, 3, 7),
            &job(720, 576, "yuv420p", Some(FieldOrder::TopFieldFirst), progressive.clone()),
            vec![1],
            true,
        );
        assert_eq!((r.crop.top, r.crop.bottom, r.step_y), (4, 8, 4));
        let r = report_from(
            &analysis(0, 0, 5, 9),
            &job(720, 576, "yuv420p", Some(FieldOrder::TopFieldFirst), progressive.clone()),
            vec![1],
            true,
        );
        assert_eq!((r.crop.top, r.crop.bottom), (8, 12));
        // Deinterlaced before the crop: twos again.
        let r = report_from(
            &analysis(0, 0, 5, 9),
            &job(720, 576, "yuv420p", Some(FieldOrder::TopFieldFirst), ProcessingPipeline::default()),
            vec![1],
            true,
        );
        assert_eq!((r.crop.top, r.crop.bottom, r.step_y), (6, 10, 2));
        // 4:2:2 interlaced: twos.
        let r = report_from(
            &analysis(0, 0, 5, 9),
            &job(720, 576, "yuv422p", Some(FieldOrder::TopFieldFirst), progressive),
            vec![1],
            true,
        );
        assert_eq!(r.step_y, 2);
    }

    #[test]
    fn the_report_follows_rotate_and_flip() {
        let turned = |rotation, flip_horizontal| ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            geometry: GeometryParameters { enabled: true, rotation, flip_horizontal, flip_vertical: false },
            ..ProcessingPipeline::default()
        };
        let a = analysis(2, 4, 6, 8);
        let crop = |p| report_from(&a, &job(720, 576, "yuv420p", None, p), vec![1], false).crop;
        // Clockwise: left -> top, top -> right, right -> bottom, bottom -> left.
        assert_eq!(crop(turned(Rotation::Cw90, false)), Sides { left: 8, right: 6, top: 2, bottom: 4 });
        assert_eq!(crop(turned(Rotation::Ccw90, false)), Sides { left: 6, right: 8, top: 4, bottom: 2 });
        assert_eq!(crop(turned(Rotation::Rotate180, false)), Sides { left: 4, right: 2, top: 8, bottom: 6 });
        assert_eq!(crop(turned(Rotation::None, true)), Sides { left: 4, right: 2, top: 6, bottom: 8 });
        // Edge Repair works before the turn, so it stays at the source's bottom.
        let r = report_from(&a, &job(720, 576, "yuv420p", None, turned(Rotation::Cw90, false)), vec![1], false);
        assert_eq!(r.edge_repair, Some(Sides { bottom: 8, ..Sides::default() }));
        assert_eq!(r.crop_with_repair.unwrap().left, 0);
    }

    #[test]
    fn repairing_the_band_covers_the_black_lines_below_it() {
        // Two black lines at the very bottom, then a 7-line band.
        let mut a = analysis(4, 4, 0, 0);
        a.edges.bottom = EdgeFinding {
            kind: EdgeKind::HeadSwitching,
            blank: 2,
            band: 7,
            crop: 9,
            crop_with_bars: 9,
            confidence: 1.0,
            ..Default::default()
        };
        let r = report_from(&a, &job(720, 576, "yuv422p", None, ProcessingPipeline::default()), vec![1], false);
        assert_eq!(r.crop.bottom, 10);
        assert_eq!(r.edge_repair, Some(Sides { bottom: 10, ..Sides::default() }));
        assert_eq!(r.crop_with_repair.unwrap().bottom, 0);
        // A band too tall for the Edge Repair panel is only ever cropped.
        a.edges.bottom.band = 16;
        a.edges.bottom.crop = 18;
        let r = report_from(&a, &job(720, 576, "yuv422p", None, ProcessingPipeline::default()), vec![1], false);
        assert!(r.edge_repair.is_none());
    }

    #[test]
    fn nothing_found_says_so() {
        let mut a = analysis(0, 0, 0, 0);
        a.edges.bottom = EdgeFinding::default();
        let r = report_from(&a, &job(720, 576, "yuv420p", None, ProcessingPipeline::default()), vec![1], false);
        assert!(!r.found);
        assert!(r.message.is_some());
        assert!(r.edge_repair.is_none());
    }

    #[test]
    fn samples_spread_through_the_clip_or_its_trim() {
        let all = sample_frames(Some(1000), None, None);
        assert_eq!(all.len(), SAMPLE_FRAMES);
        assert!(all[0] >= 50 && *all.last().unwrap() <= 950);
        let trim = sample_frames(Some(1000), Some(100), Some(199));
        assert!(trim.iter().all(|&f| (100..=199).contains(&f)));
        assert_eq!(sample_frames(None, None, None), vec![0]);
        assert!(sample_frames(Some(5), None, None).len() <= 5);
    }

    #[test]
    fn report_json_is_camel_case() {
        let r = report_from(&analysis(2, 2, 2, 6), &job(720, 576, "yuv420p", None, ProcessingPipeline::default()), vec![3], false);
        let v = serde_json::to_value(&r).unwrap();
        for key in ["found", "crop", "cropWithBars", "edgeRepair", "cropWithRepair", "edges", "usableFrames", "stepY"] {
            assert!(v.get(key).is_some(), "{key}");
        }
        assert_eq!(v["edges"]["bottom"]["kind"], "headSwitching");
    }
}
