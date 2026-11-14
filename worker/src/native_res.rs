//! Detect the resolution and kernel a source was upscaled from — what the
//! Descale pass needs to know, and what a user cannot see by looking.
//!
//! The method is the one getnative made standard: descale the luma to each
//! candidate height and resample it back with the same kernel. At the height
//! the picture was drawn at, with the kernel the studio used, the round trip
//! reproduces the source almost exactly; everywhere else it loses detail. So
//! the error, plotted against height, shows a sharp dip at the native height —
//! and among kernels at that height, the right one is lowest.
//!
//! Measured on a synthetic 720p -> 1080p Catmull-Rom master: 2.8e-8 at 720
//! against ~2e-4 elsewhere, and Catmull-Rom 2.8e-8 against 1.9e-5 for the next
//! kernel. A real Blu-ray's dip is shallower (grain, compression, credits), so
//! a height is reported as found only when its error is well below its
//! neighbours'; a source that was never upscaled has no dip at all, and is
//! reported as such rather than given a guess that would damage it.
//!
//! The luma analysed is the source's own Y plane: the frames are decoded in
//! the pipe format (`pixel_format::decode_pixel_format`) and the plane is
//! scaled here ([`luma_gray16`]). Never a decode to gray: swscale makes that
//! luma with the frame's matrix tag, and a BT.709-tagged copy of a master came
//! out up to 28 levels away from the untagged one — far enough that the 720p
//! dip vanished (docs/reports/2026-11-reserved-colour-tags, addendum).

use std::fs;
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::dependency_locator::DependencyLocator;
use crate::models::VideoJob;
use crate::pixel_format;
use crate::source_decode;

/// Marker for the analysis script's one result line on stderr.
const RESULT_MARKER: &str = "NATIVE_RES_RESULT:";

/// What the detection found.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeResReport {
    /// Whether a native resolution stands out clearly enough to use.
    pub found: bool,
    pub height: i32,
    pub width: i32,
    /// The Descale pass's kernel name (`bilinear`, `bicubic`, `lanczos`,
    /// `spline16`, `spline36`, `spline64`) and its parameters.
    pub kernel: String,
    pub bicubic_b: f64,
    pub bicubic_c: f64,
    pub lanczos_taps: i32,
    /// The best height's error over the median of its neighbours': near 0 is
    /// a sharp dip, near 1 none at all.
    pub dip: f64,
    /// Every kernel tried at that height, best first: (label, mean error).
    pub kernels: Vec<(String, f64)>,
    /// The height scan, for display: (height, error).
    pub curve: Vec<(i32, f64)>,
    /// The source frames analysed.
    pub frames: Vec<i32>,
}

/// A dip at or below this fraction of its neighbours' error counts as found.
pub const DIP_THRESHOLD: f64 = 0.5;

/// Which source frames to analyse: a few spread through the clip (not the very
/// start or end, where titles, fades and black frames are likeliest).
pub fn sample_frames(total: Option<u64>, start: Option<u64>, end: Option<u64>) -> Vec<i32> {
    let first = start.unwrap_or(0);
    let last = match (end, total) {
        (Some(e), _) => e,
        (None, Some(t)) if t > 0 => t - 1,
        _ => return vec![first as i32],
    };
    if last <= first {
        return vec![first as i32];
    }
    let span = last - first;
    [0.2, 0.4, 0.6, 0.8]
        .iter()
        .map(|f| (first + (span as f64 * f).round() as u64) as i32)
        .collect()
}

/// The pipe format the sample frames are decoded in, its bit depth, and
/// whether its samples are full range: the same choice `noise_halo` makes, so
/// the luma plane comes through untouched.
fn luma_source(job: &VideoJob) -> (String, u32, bool) {
    let pipe = pixel_format::decode_pixel_format(job.input_pixel_format.as_deref());
    let (_, depth) = pixel_format::chroma_and_depth(&pipe.name);
    let full_range = job.color_metadata().is_full_range() || pipe.name.starts_with("yuvj");
    (pipe.name, depth, full_range)
}

/// The luma plane at the start of `bytes` (8-bit, or little-endian 16-bit
/// samples holding `depth` bits) as little-endian GRAY16 at full range: a
/// limited-range plane is expanded (black 0, white 65535, clamped), a
/// full-range one scaled. This is what FFmpeg's decode to gray16le gives for
/// an UNTAGGED source (within one code), which is what the analysis's error
/// cap and `DIP_THRESHOLD` were calibrated on. `None` for a short buffer.
pub fn luma_gray16(bytes: &[u8], width: usize, height: usize, depth: u32, full_range: bool) -> Option<Vec<u8>> {
    let n = width * height;
    let unit = f64::from(1u32 << depth.saturating_sub(8));
    let (black, range) = if full_range {
        (0.0, f64::from((1u32 << depth) - 1))
    } else {
        (16.0 * unit, 219.0 * unit)
    };
    let scale = |v: f64| ((v - black) * 65535.0 / range).round().clamp(0.0, 65535.0) as u16;
    let samples: Vec<u16> = if depth > 8 {
        if bytes.len() < 2 * n {
            return None;
        }
        bytes[..2 * n]
            .chunks_exact(2)
            .map(|c| scale(f64::from(u16::from_le_bytes([c[0], c[1]]))))
            .collect()
    } else {
        if bytes.len() < n {
            return None;
        }
        bytes[..n].iter().map(|&v| scale(f64::from(v))).collect()
    };
    Some(samples.into_iter().flat_map(u16::to_le_bytes).collect())
}

/// The analysis script. `{paths}` are raw GRAY16 frames of `{w}`x`{h}`, full
/// range ([`luma_gray16`]), so its 2-level cap is in full-range 8-bit levels.
fn analysis_script(paths: &[String], width: i32, height: i32) -> String {
    let paths = paths.iter().map(|p| crate::gpu_plugin::py_str(std::path::Path::new(p))).collect::<Vec<_>>().join(", ");
    format!(
        r#"import json, sys, ctypes
import vapoursynth as vs
core = vs.core
W, H = {width}, {height}
PATHS = [{paths}]

def load(path):
    data = open(path, 'rb').read()
    blank = core.std.BlankClip(width=W, height=H, format=vs.GRAY16, length=1)
    def fill(n, f):
        fo = f.copy()
        ptr, stride = fo.get_write_ptr(0).value, fo.get_stride(0)
        for y in range(H):
            ctypes.memmove(ptr + y * stride, data[y * W * 2:(y + 1) * W * 2], W * 2)
        return fo
    return core.resize.Point(core.std.ModifyFrame(blank, blank, fill), format=vs.GRAYS)

frames = [load(p) for p in PATHS]

# (label, descale kernel, kernel name and parameters for the Descale pass)
KERNELS = [
    ('Bilinear', lambda c, w, h: core.descale.Debilinear(c, w, h), lambda c, w, h: core.resize.Bilinear(c, w, h), ('bilinear', 0, 0, 3)),
    ('Bicubic (Catmull-Rom)', lambda c, w, h: core.descale.Debicubic(c, w, h, b=0, c=0.5), lambda c, w, h: core.resize.Bicubic(c, w, h, filter_param_a=0, filter_param_b=0.5), ('bicubic', 0, 0.5, 3)),
    ('Bicubic (Mitchell)', lambda c, w, h: core.descale.Debicubic(c, w, h, b=1/3, c=1/3), lambda c, w, h: core.resize.Bicubic(c, w, h, filter_param_a=1/3, filter_param_b=1/3), ('bicubic', 1/3, 1/3, 3)),
    ('Bicubic (Hermite)', lambda c, w, h: core.descale.Debicubic(c, w, h, b=0, c=0), lambda c, w, h: core.resize.Bicubic(c, w, h, filter_param_a=0, filter_param_b=0), ('bicubic', 0, 0, 3)),
    ('Bicubic (sharp, b=0 c=1)', lambda c, w, h: core.descale.Debicubic(c, w, h, b=0, c=1), lambda c, w, h: core.resize.Bicubic(c, w, h, filter_param_a=0, filter_param_b=1), ('bicubic', 0, 1, 3)),
    ('Bicubic (b=-0.5 c=0.25)', lambda c, w, h: core.descale.Debicubic(c, w, h, b=-0.5, c=0.25), lambda c, w, h: core.resize.Bicubic(c, w, h, filter_param_a=-0.5, filter_param_b=0.25), ('bicubic', -0.5, 0.25, 3)),
    ('Lanczos (2 taps)', lambda c, w, h: core.descale.Delanczos(c, w, h, taps=2), lambda c, w, h: core.resize.Lanczos(c, w, h, filter_param_a=2), ('lanczos', 0, 0.5, 2)),
    ('Lanczos (3 taps)', lambda c, w, h: core.descale.Delanczos(c, w, h, taps=3), lambda c, w, h: core.resize.Lanczos(c, w, h, filter_param_a=3), ('lanczos', 0, 0.5, 3)),
    ('Lanczos (4 taps)', lambda c, w, h: core.descale.Delanczos(c, w, h, taps=4), lambda c, w, h: core.resize.Lanczos(c, w, h, filter_param_a=4), ('lanczos', 0, 0.5, 4)),
    ('Spline16', lambda c, w, h: core.descale.Despline16(c, w, h), lambda c, w, h: core.resize.Spline16(c, w, h), ('spline16', 0, 0.5, 3)),
    ('Spline36', lambda c, w, h: core.descale.Despline36(c, w, h), lambda c, w, h: core.resize.Spline36(c, w, h), ('spline36', 0, 0.5, 3)),
    ('Spline64', lambda c, w, h: core.descale.Despline64(c, w, h), lambda c, w, h: core.resize.Spline64(c, w, h), ('spline64', 0, 0.5, 3)),
]

def width_for(h):
    return int(round(h * W / H))

def error_clip(src, kernel, h):
    # Each pixel's error is capped (2 levels in 8-bit terms) before averaging,
    # so detail that fits at no height — credits, text, overlays drawn at full
    # resolution — adds the same small amount everywhere instead of swamping
    # the dip, while the misfit of a wrong height still counts in full across
    # the rest of the picture.
    _, de, fwd, _ = kernel
    diff = core.std.Expr([fwd(de(src, width_for(h), h), W, H), src], 'x y - abs 0.0078 min')
    return core.std.PlaneStats(diff)

def errors(clips):
    # One spliced clip, read with frames(): VapourSynth evaluates the
    # candidates in parallel rather than one get_frame at a time.
    joined = core.std.Splice(clips) if len(clips) > 1 else clips[0]
    return [f.props['PlaneStatsAverage'] for f in joined.frames()]

# 1. Scan every height from half the source's up, on the first frame, with one
#    kernel from each family studios use (a master only dips under a kernel
#    close to its own); keep the best error per height.
heights = list(range(max(H // 2, 16), H))
probe = frames[0]
scan = {{}}
for kernel in (KERNELS[0], KERNELS[1], KERNELS[7], KERNELS[10]):
    for h, e in zip(heights, errors([error_clip(probe, kernel, h) for h in heights])):
        scan[h] = min(e, scan.get(h, e))

# 2. The height that dips furthest below its neighbours (+-15, skipping +-2).
#    Only heights with neighbours on BOTH sides are candidates: the error falls
#    steadily toward the source height (H-1 is nearly an identity resample), so
#    a one-sided window would read that slope as a dip.
def dip(h):
    near = sorted(scan[x] for x in range(h - 15, h + 16) if x in scan and abs(x - h) > 2)
    if not near:
        return 1.0
    med = near[len(near) // 2]
    return scan[h] / med if med > 0 else 1.0
candidates = [h for h in heights if (h - 15) in scan and (h + 15) in scan]
best_h = min(candidates, key=dip)

# 3. Every kernel at that height, averaged over all the sampled frames.
ranked = []
for kernel in KERNELS:
    errs = errors([error_clip(f, kernel, best_h) for f in frames])
    ranked.append((kernel, sum(errs) / len(errs)))
ranked.sort(key=lambda kv: kv[1])
(label, _, _, (name, b, c, taps)), _ = ranked[0]

result = dict(
    height=best_h, width=width_for(best_h), kernel=name, bicubicB=b, bicubicC=c, lanczosTaps=taps,
    dip=dip(best_h), kernels=[[k[0], e] for k, e in ranked],
    curve=[[h, scan[h]] for h in heights],
)
print('{marker}' + json.dumps(result), file=sys.stderr, flush=True)
core.std.BlankClip(width=16, height=16, length=1).set_output()
"#,
        marker = RESULT_MARKER,
    )
}

/// Decode the sample frames' luma and run the analysis.
pub fn detect(deps: &DependencyLocator, job: &VideoJob) -> Result<NativeResReport> {
    let ffmpeg = deps.ffmpeg_path()?;
    let vspipe = deps.vspipe_path()?;
    let env = deps.build_environment();
    let (width, height) = match (job.input_width, job.input_height) {
        (Some(w), Some(h)) if w > 0 && h > 0 => (w, h),
        _ => bail!("The video's size is unknown; re-add it to the queue."),
    };
    if height < 64 {
        bail!("The video is too small to analyse ({width}x{height}).");
    }
    let fps = job.input_frame_rate.unwrap_or(29.97);
    let frames = sample_frames(
        job.total_frames.map(|f| f.max(0) as u64),
        job.start_frame.map(|f| f.max(0) as u64),
        job.end_frame.map(|f| f.max(0) as u64),
    );

    let (pix_fmt, depth, full_range) = luma_source(job);
    // A `reserved` colour tag fails a conversion to the pipe format outright
    // (a source format pipe_source can't read is converted).
    let tag_fix = job.decode_tag_neutraliser();

    let dir = std::env::temp_dir().join(format!("vapourbox_native_{}", job.id));
    fs::create_dir_all(&dir).with_context(|| format!("creating {dir:?}"))?;
    let result = (|| -> Result<NativeResReport> {
        let mut paths = Vec::new();
        for &frame in &frames {
            let path = dir.join(format!("frame_{frame}.gray16"));
            let seek = job.source_seek(frame as i64, fps);
            let out = Command::new(&ffmpeg)
                .args(source_decode::preview_decoder_args(
                    &job.input_path,
                    seek,
                    1,
                    width,
                    height,
                    &pix_fmt,
                    "pipe:1",
                    job.video_start(),
                    tag_fix.as_deref(),
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
            let luma = luma_gray16(&out.stdout, width as usize, height as usize, depth, full_range)
                .with_context(|| format!("short decode at frame {frame}"))?;
            fs::write(&path, luma).with_context(|| format!("writing {path:?}"))?;
            paths.push(path.to_string_lossy().to_string());
        }

        let script = dir.join("detect.vpy");
        fs::write(&script, analysis_script(&paths, width, height))?;
        let out = Command::new(&vspipe)
            .args(["--info", script.to_string_lossy().as_ref(), "-"])
            .envs(&env)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .context("running vspipe")?;
        let stderr = String::from_utf8_lossy(&out.stderr);
        let line = stderr
            .lines()
            .find_map(|l| l.trim().strip_prefix(RESULT_MARKER))
            .with_context(|| format!("the analysis did not finish: {}", tail(&stderr)))?;
        let raw: serde_json::Value = serde_json::from_str(line)?;
        Ok(report_from(&raw, frames.clone()))
    })();
    let _ = fs::remove_dir_all(&dir);
    result
}

fn tail(s: &str) -> String {
    s.lines().rev().take(4).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join(" | ")
}

/// The script's JSON as a report, with the found/not-found decision made here.
pub fn report_from(raw: &serde_json::Value, frames: Vec<i32>) -> NativeResReport {
    let f = |k: &str| raw.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0);
    let pairs = |k: &str| -> Vec<(serde_json::Value, f64)> {
        raw.get(k)
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|p| Some((p.get(0)?.clone(), p.get(1)?.as_f64()?)))
                    .collect()
            })
            .unwrap_or_default()
    };
    let dip = raw.get("dip").and_then(|v| v.as_f64()).unwrap_or(1.0);
    NativeResReport {
        found: dip <= DIP_THRESHOLD,
        height: f("height") as i32,
        width: f("width") as i32,
        kernel: raw.get("kernel").and_then(|v| v.as_str()).unwrap_or("bicubic").to_string(),
        bicubic_b: f("bicubicB"),
        bicubic_c: f("bicubicC"),
        lanczos_taps: f("lanczosTaps") as i32,
        dip,
        kernels: pairs("kernels")
            .into_iter()
            .map(|(k, e)| (k.as_str().unwrap_or_default().to_string(), e))
            .collect(),
        curve: pairs("curve")
            .into_iter()
            .map(|(h, e)| (h.as_i64().unwrap_or_default() as i32, e))
            .collect(),
        frames,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samples_spread_through_the_clip_or_its_trim() {
        assert_eq!(sample_frames(Some(1001), None, None), vec![200, 400, 600, 800]);
        assert_eq!(sample_frames(Some(1000), Some(100), Some(199)), vec![120, 140, 159, 179]);
        assert_eq!(sample_frames(None, None, None), vec![0]);
        assert_eq!(sample_frames(Some(1), None, None), vec![0]);
    }

    #[test]
    fn found_only_for_a_clear_dip() {
        let raw = |dip: f64| serde_json::json!({
            "height": 720, "width": 1280, "kernel": "bicubic", "bicubicB": 0.0, "bicubicC": 0.5,
            "lanczosTaps": 3, "dip": dip,
            "kernels": [["Bicubic (Catmull-Rom)", 1e-8], ["Bilinear", 6e-5]],
            "curve": [[719, 2e-4], [720, 1e-8]],
        });
        let r = report_from(&raw(0.0001), vec![5]);
        assert!(r.found);
        assert_eq!((r.height, r.width, r.kernel.as_str()), (720, 1280, "bicubic"));
        assert_eq!(r.kernels[0].0, "Bicubic (Catmull-Rom)");
        assert_eq!(r.curve[1], (720, 1e-8));
        assert!(!report_from(&raw(0.93), vec![5]).found);
    }

    fn job(pix: Option<&str>, range: Option<&str>) -> VideoJob {
        let mut j: VideoJob = serde_json::from_value(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000001", "inputPath": "/in.mov", "outputPath": "/out.mkv",
            "qtgmcParameters": {}, "encodingSettings": {},
        }))
        .unwrap();
        j.input_pixel_format = pix.map(str::to_string);
        j.input_color_range = range.map(str::to_string);
        j
    }

    fn samples(bytes: &[u8]) -> Vec<u16> {
        bytes.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect()
    }

    #[test]
    fn luma_is_decoded_in_the_pipe_format_never_as_gray() {
        assert_eq!(luma_source(&job(Some("yuv420p10le"), None)), ("yuv420p10le".into(), 10, false));
        assert_eq!(luma_source(&job(Some("yuv422p"), Some("tv"))), ("yuv422p".into(), 8, false));
        assert_eq!(luma_source(&job(Some("rgb24"), None)), ("yuv444p".into(), 8, false));
        assert_eq!(luma_source(&job(Some("yuvj420p"), None)), ("yuvj420p".into(), 8, true));
        assert_eq!(luma_source(&job(Some("yuv420p"), Some("pc"))), ("yuv420p".into(), 8, true));
        assert_eq!(luma_source(&job(None, None)).0, "yuv420p");
        for pix in ["gray", "gray16le", "gray10le"] {
            assert!(!luma_source(&job(Some(pix), None)).0.starts_with("gray"), "{pix}");
        }
    }

    #[test]
    fn limited_luma_is_expanded_to_full_range_gray16() {
        // 8-bit: 16 is black, 235 white, outside clamps; the trailing chroma
        // bytes are not read.
        let out = luma_gray16(&[16, 235, 126, 0, 255, 99, 99], 5, 1, 8, false).unwrap();
        let mid = (110.0 * 65535.0_f64 / 219.0).round() as u16;
        assert_eq!(samples(&out), vec![0, 65535, mid, 0, 65535]);
        // 10-bit: 64 black, 940 white, the same mid grey.
        let raw: Vec<u8> = [64u16, 940, 504, 1023].iter().flat_map(|v| v.to_le_bytes()).collect();
        assert_eq!(samples(&luma_gray16(&raw, 4, 1, 10, false).unwrap()), vec![0, 65535, mid, 65535]);
    }

    #[test]
    fn full_range_luma_is_scaled_not_expanded() {
        assert_eq!(samples(&luma_gray16(&[0, 255, 128], 3, 1, 8, true).unwrap()), vec![0, 65535, 32896]);
        let raw: Vec<u8> = [0u16, 1023].iter().flat_map(|v| v.to_le_bytes()).collect();
        assert_eq!(samples(&luma_gray16(&raw, 2, 1, 10, true).unwrap()), vec![0, 65535]);
    }

    #[test]
    fn a_short_decode_is_none() {
        assert!(luma_gray16(&[16; 5], 3, 2, 8, false).is_none());
        assert!(luma_gray16(&[0; 11], 3, 2, 10, false).is_none());
    }

    #[test]
    fn the_script_scans_from_half_height_and_names_every_pass_kernel() {
        let s = analysis_script(&["/a/f.gray16".into()], 1920, 1080);
        assert!(s.contains("W, H = 1920, 1080"));
        assert!(s.contains("PATHS = ['/a/f.gray16']"));
        assert!(s.contains("range(max(H // 2, 16), H)"));
        for k in ["'bilinear'", "'bicubic'", "'lanczos'", "'spline16'", "'spline36'", "'spline64'"] {
            assert!(s.contains(k), "{k}");
        }
        assert!(s.contains(RESULT_MARKER));
    }
}
