//! How noisy a source is, and how strongly its edges ring (app 1.7.0,
//! `--detect-noise-halo`). The app runs this in the background when a video
//! is loaded and badges Noise Reduction or Dehalo as recommended when a score
//! is clearly high; nothing here changes a setting.
//!
//! Frames are sampled across the source (or its trim) in pairs of consecutive
//! frames, decoded at their stored size and depth, and measured on luma in
//! plain Rust; no VapourSynth. VCG Deinterlacer v1's `analyze_noise_level` /
//! `analyze_halo_level` (MIT) were read for the idea; neither of their
//! measures separated our fixtures (ffmpeg signalstats TOUT does not respond
//! to added noise at all), so both measures here are our own, chosen and
//! calibrated in docs/reports/2026-11-noise-halo-scores/.
//!
//! **Noise** is the frame-to-frame difference after motion compensation. Each
//! 16x16 block is matched in the next frame (searched at half resolution
//! within +-10 px, refined to the pixel), the match chosen on box-smoothed
//! pictures so the choice barely depends on the noise being measured, and its
//! sigma is `std(block - match) / sqrt 2`. A low percentile over blocks keeps
//! the flattest, best-matched ones. Unlike a spatial high-pass this sees noise
//! at every spatial frequency, so tape noise (band-limited along the line) and
//! film grain (clumped) count in full, while texture that moved cancels. An
//! interlaced source is measured field by field, against the same field of the
//! next frame, so combing is never read as noise. Blocks near black or white
//! are left out (clipping hides noise there), which also leaves out letterbox
//! bars. A source whose frames repeat exactly (static digital video, cartoons
//! on twos, a codec's skipped blocks) reads low: the measure under-reports,
//! never over-reports.
//!
//! **Halo** is ringing beside isolated step edges. Edges are found along each
//! line (so interlacing cannot fake one) and followed three lines up and down
//! in the same field; the seven lines' profiles are averaged, and an edge is
//! kept when both sides settle to flat plateaus 6-10 px out. In units of the
//! step: overshoot past the bright plateau within 5 px, and undershoot below
//! the dark one. A halo rings on both sides; an outline (a dark line beside a
//! cartoon fill) is one-sided, so each edge scores the smaller of the two, and
//! the score is the mean over every edge in the sample.
//!
//! Both are in 8-bit units whatever the source's depth.

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::crop_detect;
use crate::dependency_locator::DependencyLocator;
use crate::models::VideoJob;
use crate::pixel_format;

/// Noise sigma (8-bit levels) at and above which Noise Reduction is
/// recommended. Clean fixtures, including dense texture panned by a fraction
/// of a pixel each frame, measure at most 2.1; added white noise of sigma 4
/// measures 3.7-3.8, tape-like noise of sigma 6 5.0-5.4.
pub const NOISE_HIGH: f64 = 3.5;

/// Halo score (% of the step) at and above which Dehalo is recommended. Clean
/// fixtures measure at most 3.3 (a 1080p camera file); unsharp masks of
/// amount 1 on sharp-edged pictures measure 7-71.
pub const HALO_HIGH: f64 = 6.0;

/// Fewer edges than this in the whole sample is too little to judge halos.
pub const HALO_MIN_EDGES: usize = 200;

/// Pairs of frames sampled across the source; fewer above HD, where each
/// decode costs more.
pub const SAMPLE_PAIRS: usize = 24;
pub const SAMPLE_PAIRS_LARGE: usize = 12;
const LARGE_PIXELS: i64 = 1920 * 1088;

/// The source's noise is this percentile of the pairs' estimates: noise is in
/// every shot, texture that defeats motion compensation (water, foliage in
/// wind) only in some.
const PAIR_PERCENTILE: f64 = 0.25;

/// Motion compensation: block size, coarse search radius (at half
/// resolution, so twice this in pixels), the border kept clear for the
/// search, and the most blocks measured per field (a grid is thinned above
/// it, which bounds the cost on HD and 4K).
const BLOCK: usize = 16;
const COARSE: i32 = 5;
const MARGIN: usize = 2 * COARSE as usize + 1;
const MAX_BLOCKS: usize = 4096;

/// A field's noise is this percentile of its blocks' estimates.
const BLOCK_PERCENTILE: f64 = 0.10;

/// Blocks whose mean is within this many levels of black or white are left
/// out.
const CLIP_MARGIN: f64 = 4.0;

/// Halo: plateaus `NEAR..=FAR` px from the edge, the near zone `1..NEAR`, and
/// lines followed this far up and down.
const NEAR: usize = 6;
const FAR: usize = 10;
const REACH: usize = 3;

/// A plateau is flat when its standard deviation is within twice the noise
/// left after averaging the lines, 2 levels, or this fraction of the step,
/// whichever is most: a sharpened picture's plateaus carry sharpened texture.
const FLAT_REL: f64 = 0.03;

/// One plane of luma in 8-bit units.
#[derive(Clone)]
pub struct Plane {
    pub width: usize,
    pub height: usize,
    pub data: Vec<f32>,
}

impl Plane {
    /// The luma plane at the start of `bytes`: 8-bit, or little-endian 16-bit
    /// samples holding `depth` bits, scaled to 8-bit units.
    pub fn from_luma(bytes: &[u8], width: usize, height: usize, depth: u32) -> Option<Plane> {
        let n = width * height;
        let data: Vec<f32> = if depth > 8 {
            if bytes.len() < 2 * n {
                return None;
            }
            let scale = (1u32 << (depth - 8)) as f32;
            bytes[..2 * n]
                .chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]) as f32 / scale)
                .collect()
        } else {
            if bytes.len() < n {
                return None;
            }
            bytes[..n].iter().map(|&v| v as f32).collect()
        };
        Some(Plane { width, height, data })
    }

    #[inline]
    fn at(&self, x: usize, y: usize) -> f32 {
        self.data[y * self.width + x]
    }

    /// Every other line, from `parity`.
    fn field(&self, parity: usize) -> Plane {
        let lines: Vec<usize> = (parity..self.height).step_by(2).collect();
        let mut data = Vec::with_capacity(lines.len() * self.width);
        for &y in &lines {
            data.extend_from_slice(&self.data[y * self.width..(y + 1) * self.width]);
        }
        Plane { width: self.width, height: lines.len(), data }
    }

    /// The fields of an interlaced frame, or the frame itself.
    fn fields(&self, interlaced: bool) -> Vec<Plane> {
        if interlaced {
            vec![self.field(0), self.field(1)]
        } else {
            vec![self.clone()]
        }
    }

    /// 3x3 box average, edges clamped.
    fn box3(&self) -> Plane {
        let (w, h) = (self.width, self.height);
        let mut out = vec![0f32; w * h];
        for y in 0..h {
            for x in 0..w {
                let mut s = 0f32;
                for dy in [-1i64, 0, 1] {
                    let yy = (y as i64 + dy).clamp(0, h as i64 - 1) as usize;
                    for dx in [-1i64, 0, 1] {
                        let xx = (x as i64 + dx).clamp(0, w as i64 - 1) as usize;
                        s += self.data[yy * w + xx];
                    }
                }
                out[y * w + x] = s / 9.0;
            }
        }
        Plane { width: w, height: h, data: out }
    }

    /// Half size, each pixel the mean of a 2x2 block.
    fn half(&self) -> Plane {
        let (w, h) = (self.width / 2, self.height / 2);
        let mut out = vec![0f32; w * h];
        for y in 0..h {
            for x in 0..w {
                let s = self.at(2 * x, 2 * y)
                    + self.at(2 * x + 1, 2 * y)
                    + self.at(2 * x, 2 * y + 1)
                    + self.at(2 * x + 1, 2 * y + 1);
                out[y * w + x] = s / 4.0;
            }
        }
        Plane { width: w, height: h, data: out }
    }
}

/// The value at `pct` of `values` (the lower of two neighbours, as NumPy's
/// `method='lower'`), or `None` for none.
fn percentile_lower(values: &mut [f64], pct: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.total_cmp(b));
    let i = ((values.len() - 1) as f64 * pct).floor() as usize;
    Some(values[i])
}

/// Sum of absolute differences between the `size`x`size` block of `a` at
/// (`ax`, `ay`) and that of `b` at (`bx`, `by`).
fn sad(a: &Plane, ax: usize, ay: usize, b: &Plane, bx: usize, by: usize, size: usize) -> f32 {
    let mut s = 0f32;
    for r in 0..size {
        let ra = &a.data[(ay + r) * a.width + ax..(ay + r) * a.width + ax + size];
        let rb = &b.data[(by + r) * b.width + bx..(by + r) * b.width + bx + size];
        for (p, q) in ra.iter().zip(rb) {
            s += (p - q).abs();
        }
    }
    s
}

/// Motion-compensated noise sigma of field (or frame) `f` against the same
/// field of the next frame `g`, or `None` when too few blocks can be judged.
pub fn mc_sigma(f: &Plane, g: &Plane, black: f64, white: f64) -> Option<f64> {
    let (w, h) = (f.width, f.height);
    if g.width != w || g.height != h || w < 2 * MARGIN + 2 * BLOCK || h < 2 * MARGIN + 2 * BLOCK {
        return None;
    }
    let by = (h - 2 * MARGIN) / BLOCK;
    let bx = (w - 2 * MARGIN) / BLOCK;
    if by < 2 || bx < 2 {
        return None;
    }
    let mut stride = 1;
    while (by / stride) * (bx / stride) > MAX_BLOCKS {
        stride += 1;
    }
    let (sf, sg) = (f.box3(), g.box3());
    let (cf, cg) = (f.half().box3(), g.half().box3());
    let half = BLOCK / 2;
    let mut sigmas = Vec::new();
    let mut total = 0usize;
    for i in (0..by).step_by(stride) {
        for j in (0..bx).step_by(stride) {
            total += 1;
            let (y, x) = (MARGIN + i * BLOCK, MARGIN + j * BLOCK);
            // Coarse: the half-resolution block, +-COARSE.
            let (cy, cx) = (y / 2, x / 2);
            let mut best = f32::INFINITY;
            let mut v = (0i32, 0i32);
            for dy in -COARSE..=COARSE {
                for dx in -COARSE..=COARSE {
                    let (ty, tx) = (cy as i32 + dy, cx as i32 + dx);
                    if ty < 0 || tx < 0 || ty as usize + half > cg.height || tx as usize + half > cg.width {
                        continue;
                    }
                    let s = sad(&cf, cx, cy, &cg, tx as usize, ty as usize, half);
                    if s < best {
                        best = s;
                        v = (dy, dx);
                    }
                }
            }
            // Refine +-1 px at full resolution.
            let mut best = f32::INFINITY;
            let mut m = (0i32, 0i32);
            for ry in -1..=1 {
                for rx in -1..=1 {
                    let (dy, dx) = (2 * v.0 + ry, 2 * v.1 + rx);
                    let (ty, tx) = (y as i32 + dy, x as i32 + dx);
                    if ty < 0 || tx < 0 || ty as usize + BLOCK > h || tx as usize + BLOCK > w {
                        continue;
                    }
                    let s = sad(&sf, x, y, &sg, tx as usize, ty as usize, BLOCK);
                    if s < best {
                        best = s;
                        m = (dy, dx);
                    }
                }
            }
            let mut mean = 0f64;
            for r in 0..BLOCK {
                for c in 0..BLOCK {
                    mean += f.at(x + c, y + r) as f64;
                }
            }
            mean /= (BLOCK * BLOCK) as f64;
            if !(mean > black + CLIP_MARGIN && mean < white - CLIP_MARGIN) {
                continue;
            }
            let (ty, tx) = ((y as i32 + m.0) as usize, (x as i32 + m.1) as usize);
            let (mut s1, mut s2) = (0f64, 0f64);
            for r in 0..BLOCK {
                for c in 0..BLOCK {
                    let d = (f.at(x + c, y + r) - g.at(tx + c, ty + r)) as f64;
                    s1 += d;
                    s2 += d * d;
                }
            }
            let n = (BLOCK * BLOCK) as f64;
            let var = (s2 / n - (s1 / n).powi(2)).max(0.0);
            sigmas.push(var.sqrt() / std::f64::consts::SQRT_2);
        }
    }
    if sigmas.len() < (total / 20).max(8) {
        return None;
    }
    percentile_lower(&mut sigmas, BLOCK_PERCENTILE)
}

/// For every isolated, vertically coherent step edge in `a`: the smaller of
/// its overshoot and undershoot, as a fraction of the step. `noise` (8-bit
/// levels) raises how strong and flat an edge must be to count.
pub fn edge_halos(a: &Plane, noise: f64, interlaced: bool) -> Vec<f64> {
    let t_edge = (5.0 * noise).max(16.0) as f32;
    let min_step = (8.0 * noise).max(24.0);
    let flat = (2.0 * noise / ((2 * REACH + 1) as f64).sqrt()).max(2.0);
    let mut out = Vec::new();
    for f in a.fields(interlaced) {
        let (w, h) = (f.width, f.height);
        if w < 2 * (FAR + REACH + 3) || h < 2 * REACH + 3 {
            continue;
        }
        // The horizontal gradient a[x+1] - a[x-1].
        let mut g = vec![0f32; w * h];
        for y in 0..h {
            for x in 1..w - 1 {
                g[y * w + x] = f.at(x + 1, y) - f.at(x - 1, y);
            }
        }
        let gi = |x: usize, y: usize| g[y * w + x];
        let sign = |v: f32| -> i8 {
            if v > 0.0 {
                1
            } else if v < 0.0 {
                -1
            } else {
                0
            }
        };
        let lo_x = FAR + REACH + 2;
        let hi_x = w - FAR - REACH - 2;
        let mut prof = [0f64; 2 * FAR + 1];
        for y in REACH.max(1)..(h - REACH).min(h - 1) {
            for x in lo_x..hi_x {
                let v = gi(x, y).abs();
                if v < t_edge || v < gi(x - 1, y).abs() || v <= gi(x + 1, y).abs() {
                    continue;
                }
                let s = sign(gi(x, y));
                // Follow it up and down, a pixel of drift per line at most.
                let mut ok = true;
                let mut rows = [(y, x); 2 * REACH + 1];
                let mut n = 1;
                for dir in [-1i64, 1] {
                    let mut px = x;
                    for k in 1..=REACH {
                        let yy = (y as i64 + dir * k as i64) as usize;
                        let mut best_v = f32::MIN;
                        let mut best_dx = 0i64;
                        for dx in [-1i64, 0, 1] {
                            let xx = (px as i64 + dx) as usize;
                            let gv = gi(xx, yy);
                            let cand = if sign(gv) == s { gv.abs() } else { 0.0 };
                            if cand > best_v {
                                best_v = cand;
                                best_dx = dx;
                            }
                        }
                        if best_v < t_edge * 0.5 {
                            ok = false;
                        }
                        px = (px as i64 + best_dx) as usize;
                        rows[n] = (yy, px);
                        n += 1;
                    }
                }
                if !ok {
                    continue;
                }
                for (k, p) in prof.iter_mut().enumerate() {
                    let mut acc = 0f64;
                    for &(yy, xx) in &rows {
                        acc += f.at(xx + k - FAR, yy) as f64;
                    }
                    *p = acc / rows.len() as f64;
                }
                if s < 0 {
                    prof.reverse();
                }
                let stats = |z: &[f64]| -> (f64, f64) {
                    let m = z.iter().sum::<f64>() / z.len() as f64;
                    let v = z.iter().map(|q| (q - m) * (q - m)).sum::<f64>() / z.len() as f64;
                    (m, v.sqrt())
                };
                let far_d = &prof[..=FAR - NEAR];
                let far_b = &prof[FAR + NEAR..];
                let (fd, sd) = stats(far_d);
                let (fb, sb) = stats(far_b);
                let step = fb - fd;
                let tol = flat.max(FLAT_REL * step);
                if sd > tol || sb > tol || step < min_step {
                    continue;
                }
                let max = |z: &[f64]| z.iter().cloned().fold(f64::MIN, f64::max);
                let min = |z: &[f64]| z.iter().cloned().fold(f64::MAX, f64::min);
                let near_b = &prof[FAR + 1..FAR + NEAR];
                let near_d = &prof[FAR + 1 - NEAR..FAR];
                let over = (max(near_b) - max(far_b)) / step;
                let under = (min(far_d) - min(near_d)) / step;
                out.push(over.min(under));
            }
        }
    }
    out
}

/// What one pair of frames gave.
#[derive(Debug, Clone, Default)]
pub struct PairResult {
    pub noise: Option<f64>,
    pub halos: Vec<f64>,
}

/// Measure one pair of consecutive frames: noise from the two together, halos
/// in each.
pub fn measure_pair(a: &Plane, b: &Plane, interlaced: bool, full_range: bool) -> PairResult {
    let (black, white) = if full_range { (0.0, 255.0) } else { (16.0, 235.0) };
    let fa = a.fields(interlaced);
    let fb = b.fields(interlaced);
    let sigmas: Vec<Option<f64>> = fa.iter().zip(&fb).map(|(f, g)| mc_sigma(f, g, black, white)).collect();
    let noise = if sigmas.iter().all(|s| s.is_some()) {
        Some(sigmas.iter().flatten().sum::<f64>() / sigmas.len() as f64)
    } else {
        None
    };
    let mut halos = edge_halos(a, noise.unwrap_or(0.0), interlaced);
    halos.extend(edge_halos(b, noise.unwrap_or(0.0), interlaced));
    PairResult { noise, halos }
}

/// The source's scores from its pairs.
#[derive(Debug, Clone, PartialEq)]
pub struct Analysis {
    pub noise: Option<f64>,
    pub halo: Option<f64>,
    pub halo_edges: usize,
    pub usable_pairs: usize,
}

pub fn combine(results: &[PairResult]) -> Analysis {
    let mut sigmas: Vec<f64> = results.iter().filter_map(|r| r.noise).collect();
    let usable_pairs = sigmas.len();
    let noise = percentile_lower(&mut sigmas, PAIR_PERCENTILE);
    let halo_edges: usize = results.iter().map(|r| r.halos.len()).sum();
    let halo = (halo_edges >= HALO_MIN_EDGES).then(|| {
        results.iter().flat_map(|r| r.halos.iter()).sum::<f64>() / halo_edges as f64 * 100.0
    });
    Analysis { noise, halo, halo_edges, usable_pairs }
}

/// What `--detect-noise-halo` prints.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoiseHaloReport {
    pub width: i32,
    pub height: i32,
    /// Whether each field was measured on its own.
    pub interlaced: bool,
    /// The first frame of each sampled pair, and how many pairs gave a noise
    /// estimate.
    pub frames: Vec<i32>,
    pub usable_pairs: i32,
    /// Noise sigma in 8-bit levels; `None` when it could not be measured.
    pub noise: Option<f64>,
    /// Halo score in % of the edge's step; `None` with too few edges.
    pub halo: Option<f64>,
    pub halo_edges: i32,
    /// Whether each is high enough to recommend its pass. The thresholds are
    /// decided here, once; the app only reads these.
    pub noise_high: bool,
    pub halo_high: bool,
    pub noise_threshold: f64,
    pub halo_threshold: f64,
}

pub fn report_from(analysis: &Analysis, job: &VideoJob, frames: Vec<i32>, interlaced: bool) -> NoiseHaloReport {
    NoiseHaloReport {
        width: job.input_width.unwrap_or(0),
        height: job.input_height.unwrap_or(0),
        interlaced,
        frames,
        usable_pairs: analysis.usable_pairs as i32,
        noise: analysis.noise,
        halo: analysis.halo,
        halo_edges: analysis.halo_edges as i32,
        noise_high: analysis.noise.is_some_and(|n| n >= NOISE_HIGH),
        halo_high: analysis.halo.is_some_and(|h| h >= HALO_HIGH),
        noise_threshold: NOISE_HIGH,
        halo_threshold: HALO_HIGH,
    }
}

/// Decode the sampled pairs and measure them.
pub fn detect(deps: &DependencyLocator, job: &VideoJob) -> Result<NoiseHaloReport> {
    let (width, height) = crop_detect::frame_size(job)?;
    let count = if width as i64 * height as i64 > LARGE_PIXELS { SAMPLE_PAIRS_LARGE } else { SAMPLE_PAIRS };
    let frames = crop_detect::sample_frames_n(
        count,
        job.total_frames.map(|f| f.max(0) as u64),
        job.start_frame.map(|f| f.max(0) as u64),
        job.end_frame.map(|f| f.max(0) as u64),
    );
    // The source's own format, so the luma plane comes through untouched (a
    // conversion to gray would expand its range).
    let pipe = pixel_format::decode_pixel_format(job.input_pixel_format.as_deref());
    let (_, depth) = pixel_format::chroma_and_depth(&pipe.name);
    let (w, h) = (width as usize, height as usize);
    let pairs = crop_detect::decode_samples(deps, job, &frames, 2, &pipe.name, |bytes| {
        // Two frames of the same size back to back; one means the clip ended.
        if bytes.len() % 2 != 0 {
            return None;
        }
        let half = bytes.len() / 2;
        let a = Plane::from_luma(&bytes[..half], w, h, depth)?;
        let b = Plane::from_luma(&bytes[half..], w, h, depth)?;
        Some((a, b))
    })?;
    let interlaced = crop_detect::is_interlaced(job);
    let full_range = job.color_metadata().is_full_range() || pipe.name.starts_with("yuvj");
    let results: Vec<PairResult> = std::thread::scope(|scope| {
        let handles: Vec<_> = pairs
            .iter()
            .map(|(a, b)| scope.spawn(move || measure_pair(a, b, interlaced, full_range)))
            .collect();
        handles.into_iter().map(|h| h.join().unwrap_or_default()).collect()
    });
    Ok(report_from(&combine(&results), job, frames, interlaced))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A deterministic Gaussian source (Box-Muller over an LCG).
    struct Rng(u64);
    impl Rng {
        fn uniform(&mut self) -> f64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((self.0 >> 11) as f64 + 0.5) / (1u64 << 53) as f64
        }
        fn gauss(&mut self) -> f64 {
            let (u, v) = (self.uniform(), self.uniform());
            (-2.0 * u.ln()).sqrt() * (std::f64::consts::TAU * v).cos()
        }
    }

    /// A textured picture at horizontal offset `shift`: smooth shading,
    /// fine texture and a few hard-edged rectangles.
    fn picture(w: usize, h: usize, shift: f64) -> Vec<f64> {
        let mut p = vec![0f64; w * h];
        for y in 0..h {
            for x in 0..w {
                let xs = x as f64 + shift;
                let mut v = 90.0 + 50.0 * (xs / 53.0).sin() * (y as f64 / 37.0).cos()
                    + 12.0 * (xs / 3.1).sin() * (y as f64 / 2.7).sin();
                // Rectangles with hard vertical edges.
                let rx = (xs / 90.0).floor() as i64;
                if (xs % 90.0) > 30.0 && (xs % 90.0) < 60.0 && (y / 40) % 2 == 0 {
                    v = 60.0 + 100.0 * ((rx % 2) as f64);
                }
                p[y * w + x] = v;
            }
        }
        p
    }

    fn plane(v: &[f64], w: usize, h: usize) -> Plane {
        Plane { width: w, height: h, data: v.iter().map(|&x| x.round().clamp(0.0, 255.0) as f32).collect() }
    }

    fn noisy(v: &[f64], sigma: f64, rng: &mut Rng) -> Vec<f64> {
        v.iter().map(|&x| x + sigma * rng.gauss()).collect()
    }

    /// Unsharp mask along the line: a + amount * (a - box5(a)).
    fn sharpen(v: &[f64], w: usize, h: usize, amount: f64) -> Vec<f64> {
        let mut out = v.to_vec();
        for y in 0..h {
            for x in 2..w - 2 {
                let b: f64 = (0..5).map(|k| v[y * w + x + k - 2]).sum::<f64>() / 5.0;
                out[y * w + x] = v[y * w + x] + amount * (v[y * w + x] - b);
            }
        }
        out
    }

    fn pairs(n: usize, w: usize, h: usize, sigma: f64, amount: f64) -> Vec<PairResult> {
        let mut rng = Rng(7);
        (0..n)
            .map(|t| {
                let a = sharpen(&picture(w, h, 3.0 * t as f64), w, h, amount);
                let b = sharpen(&picture(w, h, 3.0 * t as f64 + 3.0), w, h, amount);
                measure_pair(
                    &plane(&noisy(&a, sigma, &mut rng), w, h),
                    &plane(&noisy(&b, sigma, &mut rng), w, h),
                    false,
                    false,
                )
            })
            .collect()
    }

    #[test]
    fn noise_is_measured_close_to_what_was_added() {
        for sigma in [0.0, 2.0, 5.0, 8.0] {
            let a = combine(&pairs(4, 320, 240, sigma, 0.0));
            let n = a.noise.unwrap();
            assert!((n - sigma).abs() <= 0.15 * sigma + 0.6, "sigma {sigma}: measured {n}");
        }
    }

    #[test]
    fn texture_that_moves_is_not_noise_and_heavy_noise_is_high() {
        let job = job_for(320, 240);
        let clean = report_from(&combine(&pairs(4, 320, 240, 0.0, 0.0)), &job, vec![0], false);
        assert!(!clean.noise_high);
        let heavy = report_from(&combine(&pairs(4, 320, 240, 6.0, 0.0)), &job, vec![0], false);
        assert!(heavy.noise_high, "{heavy:?}");
    }

    #[test]
    fn interlaced_frames_are_measured_per_field() {
        // Each frame's fields 4 px apart: combing on every edge.
        let (w, h) = (320, 240);
        let mut rng = Rng(3);
        let weave = |t: f64, rng: &mut Rng, sigma: f64| {
            let top = picture(w, h, t);
            let bottom = picture(w, h, t + 4.0);
            let mut v: Vec<f64> = (0..w * h).map(|i| if (i / w) % 2 == 0 { top[i] } else { bottom[i] }).collect();
            v = noisy(&v, sigma, rng);
            plane(&v, w, h)
        };
        for sigma in [0.0, 3.0] {
            let r: Vec<PairResult> = (0..4)
                .map(|t| {
                    let a = weave(8.0 * t as f64, &mut rng, sigma);
                    let b = weave(8.0 * t as f64 + 8.0, &mut rng, sigma);
                    measure_pair(&a, &b, true, false)
                })
                .collect();
            let n = combine(&r).noise.unwrap();
            assert!((n - sigma).abs() <= 0.15 * sigma + 0.6, "interlaced sigma {sigma}: measured {n}");
        }
    }

    #[test]
    fn black_frames_cannot_be_measured() {
        let (w, h) = (160, 120);
        let black = Plane { width: w, height: h, data: vec![16.0; w * h] };
        let r = measure_pair(&black, &black, false, false);
        assert!(r.noise.is_none());
        assert!(r.halos.is_empty());
        let a = combine(&[r]);
        assert_eq!((a.noise, a.halo), (None, None));
    }

    #[test]
    fn sharpening_reads_as_halo_and_a_clean_picture_does_not() {
        let clean = combine(&pairs(4, 320, 240, 0.0, 0.0));
        let sharp = combine(&pairs(4, 320, 240, 0.0, 1.5));
        assert!(clean.halo_edges >= HALO_MIN_EDGES, "{clean:?}");
        assert!(clean.halo.unwrap() < 2.0, "{clean:?}");
        assert!(sharp.halo.unwrap() >= HALO_HIGH, "{sharp:?}");
        // Noise alone is not a halo.
        let noisy = combine(&pairs(4, 320, 240, 5.0, 0.0));
        assert!(noisy.halo.map_or(true, |h| h < 2.0), "{noisy:?}");
    }

    #[test]
    fn an_outline_is_not_a_halo() {
        // Flat fills with a 3 px dark outline between them: the profile dips
        // on one side only.
        let (w, h) = (320, 120);
        let mut v = vec![0f64; w * h];
        for y in 0..h {
            for x in 0..w {
                let cell = (x / 40) % 2;
                let edge = x % 40;
                v[y * w + x] = if edge < 3 { 30.0 } else if cell == 0 { 170.0 } else { 110.0 };
            }
        }
        let p = plane(&v, w, h);
        let halos = edge_halos(&p, 0.0, false);
        assert!(!halos.is_empty());
        let mean = halos.iter().sum::<f64>() / halos.len() as f64 * 100.0;
        assert!(mean.abs() < 1.0, "outline read as halo: {mean}");
    }

    #[test]
    fn ten_bit_luma_is_read_in_eight_bit_units() {
        let raw: Vec<u8> = [64u16, 940, 512].iter().flat_map(|v| v.to_le_bytes()).collect();
        let p = Plane::from_luma(&raw, 3, 1, 10).unwrap();
        assert_eq!(p.data, vec![16.0, 235.0, 128.0]);
        assert!(Plane::from_luma(&raw[..4], 3, 1, 10).is_none());
        let p8 = Plane::from_luma(&[16, 235, 128], 3, 1, 8).unwrap();
        assert_eq!(p8.data, vec![16.0, 235.0, 128.0]);
    }

    #[test]
    fn percentile_is_the_lower_neighbour() {
        assert_eq!(percentile_lower(&mut [4.0, 1.0, 3.0, 2.0], 0.25), Some(1.0));
        assert_eq!(percentile_lower(&mut [5.0], 0.1), Some(5.0));
        assert_eq!(percentile_lower(&mut [], 0.5), None);
    }

    fn job_for(w: i32, h: i32) -> VideoJob {
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
        j
    }

    #[test]
    fn report_says_high_only_at_the_thresholds() {
        let job = job_for(720, 576);
        let at = |noise, halo| {
            report_from(
                &Analysis { noise, halo, halo_edges: 500, usable_pairs: 10 },
                &job,
                vec![1],
                false,
            )
        };
        let r = at(Some(NOISE_HIGH), Some(HALO_HIGH));
        assert!(r.noise_high && r.halo_high);
        let r = at(Some(NOISE_HIGH - 0.01), Some(HALO_HIGH - 0.01));
        assert!(!r.noise_high && !r.halo_high);
        let r = at(None, None);
        assert!(!r.noise_high && !r.halo_high);
        let v = serde_json::to_value(&r).unwrap();
        for key in ["noise", "halo", "noiseHigh", "haloHigh", "haloEdges", "usablePairs", "noiseThreshold"] {
            assert!(v.get(key).is_some(), "{key}");
        }
    }

    #[test]
    fn too_few_edges_is_no_halo_score() {
        let r = PairResult { noise: Some(1.0), halos: vec![0.5; HALO_MIN_EDGES - 1] };
        assert_eq!(combine(&[r]).halo, None);
        let r = PairResult { noise: Some(1.0), halos: vec![0.5; HALO_MIN_EDGES] };
        assert_eq!(combine(&[r]).halo, Some(50.0));
    }
}
