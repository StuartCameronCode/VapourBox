//! Everything VapourBox needs to know about a source before it decodes a
//! frame of it, probed once, in one place (task #50).
//!
//! `vapourbox-worker --probe-source <path>` prints a [`SourceModel`]. The app
//! stores it on the queue item at analysis and sends it in every job (inline
//! as `source`, or by file with `--source`); the worker uses it as given and
//! probes only when a job carries none (a hand-written job, the CLI).
//!
//! Before this, three code paths probed the same file: the app's
//! `FieldOrderDetector`, the app's `PreviewGenerator`, and the worker's
//! `fill_*` steps, which ran again on every preview request. The app's copies
//! of the probe rules (video start, decoder delay, seek plan, grid, frame
//! count) were twins of `source_decode`'s, pinned by vector files. The model
//! is now the only answer; the rules it is built from are unchanged.

use std::collections::HashMap;
use std::path::Path;
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};

use crate::source_continuity::{self, ContinuityScan};
use crate::source_decode::{self, SeekPlan, SourceGrid};
use crate::source_timing;

/// Bumped whenever a field's meaning changes. A job whose model has another
/// schema is re-probed, never trusted.
pub const SOURCE_MODEL_SCHEMA: u32 = 1;

/// Which file a model describes, so a model made before the file changed is
/// noticed and re-probed rather than trusted.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceIdentity {
    pub path: String,
    pub size_bytes: u64,
    /// Modification time, milliseconds since the Unix epoch (0 if unknown).
    pub modified_ms: u64,
}

impl SourceIdentity {
    pub fn of(path: &str) -> Option<Self> {
        let meta = std::fs::metadata(path).ok()?;
        let modified_ms = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_millis() as u64);
        Some(Self { path: path.to_string(), size_bytes: meta.len(), modified_ms })
    }
}

/// One audio stream, as the app lists and the encode maps them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioStreamFacts {
    pub index: u32,
    pub codec: Option<String>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u32>,
    pub channel_layout: Option<String>,
    pub bit_rate: Option<u64>,
    pub start_time: Option<f64>,
}

/// The Dolby Vision configuration record of the video stream.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DolbyVisionFacts {
    pub profile: Option<u32>,
    pub compatibility_id: Option<u32>,
}

/// The first video stream.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoFacts {
    pub codec: Option<String>,
    pub codec_tag_string: Option<String>,
    pub pixel_format: Option<String>,
    pub width: i32,
    pub height: i32,
    /// `sample_aspect_ratio` as jobs carry it ([`normalize_sar`]): `None`
    /// for square pixels or unknown.
    pub sar: Option<String>,
    /// ffprobe's `field_order` (the container's or bitstream's claim).
    pub field_order: Option<String>,
    pub r_frame_rate: Option<String>,
    pub avg_frame_rate: Option<String>,
    /// The picture rate jobs run at ([`select_frame_rate`]).
    pub frame_rate: f64,
    /// The length in frames every decoder, trim and timeline counts in
    /// ([`frame_count`]).
    pub frame_count: i64,
    /// `nb_frames`, when the container stores it.
    pub stored_frames: Option<i64>,
    /// The video stream's own duration, seconds.
    pub stream_duration: Option<f64>,
    pub stream_start: Option<f64>,
    /// Seconds the first picture starts after the container's start
    /// (`source_decode::video_start_from_probe`).
    pub video_start_offset: f64,
    /// Seconds of pictures shown before the stream's `start_time` (an open
    /// GOP's leading B pictures), counted into the length.
    pub leading_pictures: f64,
    /// `source_decode::decoder_delay_from_probe`.
    pub decoder_delay_frames: u32,
    /// `source_decode::seek_plan_from_probe`: MPEG-TS/PS only.
    pub seek_plan: Option<SeekPlan>,
    /// `source_decode::grid_from_probe`, at [`Self::frame_rate`].
    pub source_grid: Option<SourceGrid>,
    /// Whether the two rates suggest a variable frame rate
    /// (`source_timing::rates_suggest_vfr`).
    pub variable_frame_rate: bool,
    /// The stored frames' times, only when they really are irregular (the
    /// timeline the decoders place them on is built from them).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame_times: Option<Vec<f64>>,
    /// Where `-ss` counts from for [`Self::frame_times`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame_times_start: Option<f64>,
    /// `soft_telecine_decimates_at(frame_rate)`: a soft-telecine decode at
    /// this rate holds 3:2 repeats.
    pub pulldown_rate: bool,
    /// ffprobe's raw colour tags (`reserved` kept: the decoders clear it).
    pub color_matrix: Option<String>,
    pub color_primaries: Option<String>,
    pub color_transfer: Option<String>,
    pub color_range: Option<String>,
    pub dolby_vision: Option<DolbyVisionFacts>,
}

/// See the module docs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceModel {
    pub schema: u32,
    pub identity: SourceIdentity,
    pub format_name: String,
    pub container_start: Option<f64>,
    /// The container's duration, seconds.
    pub duration: Option<f64>,
    pub video: VideoFacts,
    pub audio_streams: Vec<AudioStreamFacts>,
    /// The timestamp-reset scan (`source_continuity`), `None` if it failed
    /// or was deferred.
    pub continuity: Option<ContinuityScan>,
    /// The scan has not run yet (`--probe-source --defer-scan`, task #55): an
    /// MPEG-PS/TS whose whole-file read is left to `--complete-source`, so
    /// analysis need not wait for it. Absent (false) in every other model.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub continuity_deferred: bool,
}

/// Whether [`probe_source_with`] reads the whole file for the reset scan now
/// or leaves it to [`complete_source`] (task #55).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanMode {
    Now,
    Deferred,
}

impl SourceModel {
    /// Whether this model still describes `path`: same schema, same file,
    /// unchanged since it was probed.
    pub fn describes(&self, path: &str) -> bool {
        self.schema == SOURCE_MODEL_SCHEMA
            && self.identity.path == path
            && SourceIdentity::of(path).is_some_and(|now| now == self.identity)
    }

    /// The variable-frame-rate timeline at `fps` (the job's rate), from the
    /// stored times: no probe.
    pub fn timeline(&self, fps: f64, log: impl Fn(&str)) -> Option<source_timing::SourceTimeline> {
        let times = self.video.frame_times.as_ref()?;
        let start = self.video.frame_times_start.unwrap_or_else(|| {
            times.iter().cloned().fold(f64::INFINITY, f64::min)
        });
        source_timing::timeline_from_times(times, start, fps, log)
    }
}

// ---------------------------------------------------------------------------
// Pure rules
// ---------------------------------------------------------------------------

/// ffprobe's `sample_aspect_ratio` as jobs carry it: `None` for square
/// pixels or when there is none to read (`N/A`, `1:1`, `0:1`).
pub fn normalize_sar(raw: Option<&str>) -> Option<String> {
    let sar = raw?.trim();
    if sar.is_empty() || sar == "N/A" || sar == "1:1" {
        return None;
    }
    if let Some((n, _)) = sar.split_once(':') {
        if n.parse::<f64>().unwrap_or(0.0) <= 0.0 {
            return None;
        }
    }
    Some(sar.to_string())
}

/// The true picture rate from `r_frame_rate` and `avg_frame_rate`: `avg`
/// when it is about half of `r` (field-coded interlaced H.264 reports the
/// field rate as `r`, issue #13), else `r`.
pub fn select_frame_rate(r: Option<f64>, avg: Option<f64>) -> Option<f64> {
    match (r.filter(|r| *r > 0.0), avg.filter(|a| *a > 0.0)) {
        (None, a) => a.or(avg),
        (Some(r), None) => Some(r),
        (Some(r), Some(a)) => {
            let ratio = r / a;
            Some(if ratio > 1.8 && ratio < 2.2 { a } else { r })
        }
    }
}

/// A colour tag as jobs carry it: `None` for empty, `unknown` or `N/A`.
/// Every other value, `reserved` included, is kept.
pub fn color_tag(stream: &serde_json::Value, key: &str) -> Option<String> {
    let v = stream.get(key)?.as_str()?.trim();
    (!v.is_empty() && v != "unknown" && v != "N/A").then(|| v.to_string())
}

/// Where the first picture sits: its offset after the container's start
/// and how long before the stream's `start_time` it is shown.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct VideoStart {
    pub offset: f64,
    pub leading: f64,
}

/// [`VideoStart`] from ffprobe's answer to
/// `source_decode::VIDEO_START_PROBE_ARGS`. The offset is
/// `video_start_from_probe`'s. The leading pictures count only when the
/// stream starts after the container (as they always have in the app's frame
/// count): otherwise the first picture cannot be later than the stream.
pub fn video_start(json: &serde_json::Value) -> VideoStart {
    let num = |v: Option<&serde_json::Value>| {
        v.and_then(|s| s.as_str()).and_then(|s| s.parse::<f64>().ok()).filter(|t| t.is_finite())
    };
    let offset = source_decode::video_start_from_probe(json);
    let container = num(json.pointer("/format/start_time"));
    let stream = num(json.pointer("/streams/0/start_time"));
    let leading = match (stream, container) {
        (Some(s), Some(c)) if s > c => {
            let first = json
                .get("packets")
                .and_then(|p| p.as_array())
                .into_iter()
                .flatten()
                .filter_map(|p| num(p.get("pts_time")))
                .fold(s, f64::min);
            (s - first).max(0.0)
        }
        _ => 0.0,
    };
    VideoStart { offset, leading }
}

/// The length of a source with no stored count, by duration: the stream's
/// own duration plus its leading pictures, else the container's less the
/// video start offset. The container's alone runs from the earliest stream
/// (a DVB-T capture's sound starts 1.2 s first: 158 frames for 128).
pub fn frame_count_from_duration(
    stream_duration: Option<f64>,
    container_duration: Option<f64>,
    start: VideoStart,
    fps: f64,
) -> i64 {
    if fps <= 0.0 {
        return 0;
    }
    if let Some(d) = stream_duration.filter(|d| *d > 0.0) {
        return ((d + start.leading) * fps).round() as i64;
    }
    match container_duration {
        Some(c) if c - start.offset > 0.0 => ((c - start.offset) * fps).round() as i64,
        _ => 0,
    }
}

/// Seconds before the stream's end that [`TAIL_FRAMES_PROBE_SECONDS`]'s
/// decode starts.
pub const TAIL_FRAMES_PROBE_SECONDS: f64 = 3.0;

/// ffprobe's arguments (before the input) for [`untimed_last_picture`].
pub fn tail_frames_probe_args(from: f64) -> Vec<String> {
    vec![
        "-v".into(), "error".into(),
        "-select_streams".into(), "v:0".into(),
        "-show_entries".into(), "frame=best_effort_timestamp_time,duration_time".into(),
        "-read_intervals".into(), format!("{:.6}%", from.max(0.0)),
        "-of".into(), "json".into(),
    ]
}

/// The time ffmpeg's decoder gives the last picture that has no timestamp
/// of its own (an MPEG-PS flushes its last reference picture with neither
/// PTS nor DTS, task #26): the previous frame's time plus its duration, as
/// `ffmpeg_dec.c` stamps it. `None` when every frame has a time.
pub fn untimed_last_picture(json: &serde_json::Value, fps: f64) -> Option<f64> {
    let num = |v: Option<&serde_json::Value>| {
        v.and_then(|s| s.as_str()).and_then(|s| s.parse::<f64>().ok()).filter(|t| t.is_finite())
    };
    let mut prev: Option<(f64, f64)> = None;
    let mut last: Option<f64> = None;
    for f in json.get("frames").and_then(|f| f.as_array()).into_iter().flatten() {
        let d = num(f.get("duration_time"));
        let dur = match d {
            Some(d) if d > 0.0 => d,
            _ if fps > 0.0 => 1.0 / fps,
            _ => 0.0,
        };
        let t = match num(f.get("best_effort_timestamp_time")) {
            Some(t) => t,
            None => {
                let Some((pt, pd)) = prev else { continue };
                let t = pt + pd;
                if last.is_none_or(|l| t > l) {
                    last = Some(t);
                }
                t
            }
        };
        prev = Some((t, dur));
    }
    last
}

/// The count by duration with an untimed last picture counted in: its slot
/// on the grid from the first picture, plus one; never fewer.
pub fn frame_count_with_untimed_tail(
    by_duration: i64,
    untimed_last: Option<f64>,
    stream_start: f64,
    start: VideoStart,
    fps: f64,
) -> i64 {
    let Some(last) = untimed_last.filter(|_| fps > 0.0) else { return by_duration };
    let first = stream_start - start.leading;
    let n = ((last - first) * fps).round() as i64 + 1;
    n.max(by_duration)
}

/// What the tail probe ([`probe_tail`]) found among the last
/// [`TAIL_FRAMES_PROBE_SECONDS`] of a file's video packets.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct TailPictures {
    /// The largest PTS of a packet the demuxer does not mark discard: the
    /// last picture a decode outputs.
    pub last_kept: Option<f64>,
    /// Whether any packet was marked discard (`D`): an MP4/MOV edit list can
    /// keep pictures past its end for B-frame reorder.
    pub discards: bool,
}

/// [`TailPictures`] from `ffprobe -show_entries packet=pts_time,flags -of
/// csv=p=0` output. Packets marked discard never reach the decoder's output,
/// so they never set the last picture; a packet without a time is skipped.
pub fn tail_pictures_from_csv(csv: &str) -> TailPictures {
    let mut tail = TailPictures::default();
    for line in csv.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let (pts, flags) = line.split_once(',').unwrap_or((line, ""));
        if flags.contains('D') {
            tail.discards = true;
            continue;
        }
        if let Some(t) = pts.trim().parse::<f64>().ok().filter(|t| t.is_finite()) {
            tail.last_kept = Some(tail.last_kept.map_or(t, |m: f64| m.max(t)));
        }
    }
    tail
}

/// Whether ffprobe's `format_name` is the QuickTime/MP4 family, whose
/// stored count (`nb_frames`) is the sample table's, edit list or not.
pub fn is_mov_family(format_name: &str) -> bool {
    format_name.split(',').any(|f| f == "mov" || f == "mp4")
}

/// The length on `grid` from the last picture's time: its slot, plus one.
/// Matroska's container duration can count the last frame's repeat flags.
pub fn frame_count_from_last_picture(last_pts: f64, grid: &SourceGrid) -> i64 {
    (((last_pts - grid.origin) * grid.fps()).round() as i64 + 1).max(0)
}

/// What [`frame_count`] decides from. The probes it may need are passed in
/// as closures, so the rule is testable without a file.
pub struct CountInputs<'a> {
    pub stored_frames: Option<i64>,
    pub r: Option<f64>,
    pub avg: Option<f64>,
    pub fps: f64,
    pub stream_duration: Option<f64>,
    pub container_duration: Option<f64>,
    pub stream_start: Option<f64>,
    pub format_name: &'a str,
    pub start: VideoStart,
    pub grid: Option<&'a SourceGrid>,
    /// Slots of the VFR timeline, when the times are irregular.
    pub timeline_slots: Option<usize>,
    /// Whether the demuxer marks some video packets discard (an MP4/MOV
    /// edit list's pre-roll, [`source_decode::discards_from_probe`], or
    /// pictures kept past its end, [`TailPictures::discards`]).
    pub discards: bool,
}

/// The length in frames every decoder, trim and timeline counts in:
///
/// 1. a variable-frame-rate source: its timeline's slots (what the decoders
///    produce), else, if only the rates suggest VFR, duration × rate;
/// 2. `nb_frames` when stored (an AVI's null frames are slots: the grid
///    decode of `interlaced_test.avi` gives the 79 it stores, not the 75
///    `-count_frames` decodes), except
///    2a. when the demuxer discards packets (an MP4/MOV edit list's
///    pre-roll, which `nb_frames` counts): the last kept picture's slot on
///    the grid, plus one ([`frame_count_from_last_picture`], task #54).
///    `small_clip.mp4` stores 3154 and decodes 3151; a stream-copy cut
///    with holes in its timestamps (`edit_list_bframes.mp4`) stores 146,
///    keeps 125 and decodes 128 slots. Without a grid or a last picture,
///    `nb_frames` as before;
/// 3. otherwise [`frame_count_from_duration`]; an MPEG-TS/PS adds an untimed
///    last picture, and a source with no stream duration (Matroska) is
///    counted from its last picture on its grid.
pub fn frame_count(
    i: &CountInputs,
    untimed_last: impl FnOnce(f64, f64) -> Option<f64>,
    last_picture: impl FnOnce(f64) -> Option<f64>,
) -> i64 {
    if let Some(slots) = i.timeline_slots {
        return slots as i64;
    }
    let variable = match (i.r, i.avg) {
        (Some(r), Some(a)) => source_timing::rates_suggest_vfr(r, a),
        _ => false,
    };
    let duration = i.stream_duration.or(i.container_duration);
    if variable && i.fps > 0.0 {
        if let Some(d) = duration.filter(|d| *d > 0.0) {
            return (d * i.fps).round() as i64;
        }
    }
    if let Some(n) = i.stored_frames {
        if i.discards && i.fps > 0.0 {
            if let (Some(grid), Some(container)) = (i.grid, i.container_duration) {
                if let Some(slots) = last_picture(container)
                    .map(|t| frame_count_from_last_picture(t, grid))
                    .filter(|s| *s > 0)
                {
                    return slots;
                }
            }
        }
        return n;
    }
    let by_duration =
        frame_count_from_duration(i.stream_duration, i.container_duration, i.start, i.fps);
    let has_stream_duration = i.stream_duration.is_some_and(|d| d > 0.0);
    if has_stream_duration && i.fps > 0.0 && source_continuity::applies_to(i.format_name) {
        if let Some(stream_start) = i.stream_start {
            let untimed = untimed_last(stream_start, i.stream_duration.unwrap_or(0.0));
            return frame_count_with_untimed_tail(by_duration, untimed, stream_start, i.start, i.fps);
        }
    }
    if has_stream_duration || i.fps <= 0.0 {
        return by_duration;
    }
    let (Some(container), Some(grid)) = (i.container_duration, i.grid) else {
        return by_duration;
    };
    match last_picture(container).map(|t| frame_count_from_last_picture(t, grid)) {
        Some(n) if n > 0 => n,
        _ => by_duration,
    }
}

// ---------------------------------------------------------------------------
// The probe
// ---------------------------------------------------------------------------

fn run_json(ffprobe: &Path, env: &HashMap<String, String>, args: &[String], input: &str) -> Option<serde_json::Value> {
    let out = Command::new(ffprobe)
        .args(args)
        .arg(input)
        .envs(env)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

/// The video packets of the last [`TAIL_FRAMES_PROBE_SECONDS`] of the file
/// ([`TailPictures`]). `None` when ffprobe fails.
fn probe_tail(ffprobe: &Path, env: &HashMap<String, String>, input: &str, container: f64) -> Option<TailPictures> {
    let from = container - TAIL_FRAMES_PROBE_SECONDS;
    let mut args: Vec<String> = ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    if from > 0.0 {
        args.push("-read_intervals".into());
        args.push(format!("{from:.3}%"));
    }
    args.push("-of".into());
    args.push("csv=p=0".into());
    let out = Command::new(ffprobe).args(&args).arg(input).envs(env).stderr(Stdio::null()).output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(tail_pictures_from_csv(&String::from_utf8_lossy(&out.stdout)))
}

fn num_str(v: Option<&serde_json::Value>) -> Option<f64> {
    v.and_then(|s| s.as_str()).and_then(|s| s.parse::<f64>().ok()).filter(|t| t.is_finite())
}

fn uint(v: Option<&serde_json::Value>) -> Option<u64> {
    v.and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
}

/// Probe `input` into a [`SourceModel`]. `Err` only when ffprobe cannot
/// read the file or it has no video stream; every later step that fails
/// leaves its field at the value that means "decode as before".
pub fn probe_source(
    ffprobe: &Path,
    env: &HashMap<String, String>,
    input: &str,
    log: impl Fn(&str) + Sync,
) -> anyhow::Result<SourceModel> {
    probe_source_with(ffprobe, env, input, ScanMode::Now, log)
}

/// [`probe_source`], with the reset scan of an MPEG-PS/TS (the one probe
/// that reads every byte) run now or deferred. A deferred model has
/// `continuity: None` and `continuity_deferred: true`, and is otherwise the
/// same model; any other format has nothing to defer and is unchanged.
pub fn probe_source_with(
    ffprobe: &Path,
    env: &HashMap<String, String>,
    input: &str,
    scan_mode: ScanMode,
    log: impl Fn(&str) + Sync,
) -> anyhow::Result<SourceModel> {
    let identity = SourceIdentity::of(input)
        .ok_or_else(|| anyhow::anyhow!("{input} could not be read"))?;
    let main_args: Vec<String> = ["-v", "error", "-show_streams", "-show_format", "-of", "json"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    let json = run_json(ffprobe, env, &main_args, input)
        .ok_or_else(|| anyhow::anyhow!("ffprobe could not read {input}"))?;
    let streams: Vec<&serde_json::Value> =
        json.get("streams").and_then(|s| s.as_array()).into_iter().flatten().collect();
    let video = *streams
        .iter()
        .find(|s| s.get("codec_type").and_then(|t| t.as_str()) == Some("video"))
        .ok_or_else(|| anyhow::anyhow!("{input} has no video stream"))?;
    let format = json.get("format");
    let format_name = format
        .and_then(|f| f.get("format_name"))
        .and_then(|f| f.as_str())
        .unwrap_or("")
        .to_string();
    let container_start = num_str(format.and_then(|f| f.get("start_time")));
    let duration = num_str(format.and_then(|f| f.get("duration")));
    let str_of = |k: &str| video.get(k).and_then(|v| v.as_str()).map(str::to_string);
    let r_str = str_of("r_frame_rate");
    let avg_str = str_of("avg_frame_rate");
    let r = r_str.as_deref().and_then(source_timing::parse_rational);
    let avg = avg_str.as_deref().and_then(source_timing::parse_rational);
    let fps = select_frame_rate(r, avg).unwrap_or(0.0);
    let stream_duration = num_str(video.get("duration"));
    let stream_start = num_str(video.get("start_time"));
    let (_, types) = source_continuity::streams_from_probe(&json);
    let stored_frames = uint(video.get("nb_frames")).map(|n| n as i64);
    // An MP4/MOV's stored count is its sample table's, discarded pre-roll
    // included: its tail is read up front, for any discards there and the
    // last kept picture (task #54). Every other source reads it only if its
    // count needs the last picture.
    let reads_tail = stored_frames.is_some() && is_mov_family(&format_name);
    let continuity_deferred =
        scan_mode == ScanMode::Deferred && source_continuity::applies_to(&format_name);

    // The independent probes run at once: analysis waits for the slowest,
    // not their sum.
    let (start_json, seek_plan, continuity, times, mov_tail) = std::thread::scope(|s| {
        let a = s.spawn(|| source_decode::probe_json(ffprobe, env, &source_decode::VIDEO_START_PROBE_ARGS, input));
        let b = s.spawn(|| source_decode::probe_seek_plan(ffprobe, env, input));
        let c = s.spawn(|| {
            if continuity_deferred {
                return None;
            }
            source_continuity::scan_packets(ffprobe, env, input, format_name.clone(), &types).ok()
        });
        let d = s.spawn(|| match (r, avg) {
            (Some(r), Some(a)) => source_timing::probe_times(
                ffprobe,
                env,
                input,
                r,
                a,
                container_start,
                &log,
            ),
            _ => None,
        });
        let e = s.spawn(|| match duration {
            Some(c) if reads_tail => probe_tail(ffprobe, env, input, c),
            _ => None,
        });
        (
            a.join().ok().flatten(),
            b.join().ok().flatten(),
            c.join().ok().flatten(),
            d.join().ok().flatten(),
            e.join().ok().flatten(),
        )
    });

    let start = start_json.as_ref().map(video_start).unwrap_or_default();
    let decoder_delay_frames = match &start_json {
        Some(j) if source_decode::stores_decode_order(j) => {
            source_decode::probe_json(ffprobe, env, &source_decode::DECODER_DELAY_PROBE_ARGS, input)
                .map_or(0, |d| source_decode::decoder_delay_from_probe(&d, start.offset))
        }
        _ => 0,
    };
    let source_grid = start_json.as_ref().and_then(|j| source_decode::grid_from_probe(j, fps));
    let timeline = times
        .as_ref()
        .and_then(|(t, st)| source_timing::timeline_from_times(t, *st, fps, &log));
    let (frame_times, frame_times_start) = match (&timeline, times) {
        (Some(_), Some((t, st))) => (Some(t), Some(st)),
        _ => (None, None),
    };
    let discards = start_json.as_ref().is_some_and(source_decode::discards_from_probe)
        || mov_tail.is_some_and(|t| t.discards);
    let frame_count = frame_count(
        &CountInputs {
            stored_frames,
            r,
            avg,
            fps,
            stream_duration,
            container_duration: duration,
            stream_start,
            format_name: &format_name,
            start,
            grid: source_grid.as_ref(),
            timeline_slots: timeline.as_ref().map(|t| t.slot_count()),
            discards,
        },
        |stream_start, stream_duration| {
            let from = stream_start + stream_duration - TAIL_FRAMES_PROBE_SECONDS;
            run_json(ffprobe, env, &tail_frames_probe_args(from), input)
                .and_then(|j| untimed_last_picture(&j, fps))
        },
        |container| match mov_tail {
            Some(t) => t.last_kept,
            None => probe_tail(ffprobe, env, input, container).and_then(|t| t.last_kept),
        },
    );

    let dolby_vision = crate::hdr_metadata::HdrMetadata::from_ffprobe_json(
        &serde_json::json!({ "streams": [video] }),
    )
    .dolby_vision
    .filter(|d| d.profile.is_some() || d.compatibility_id.is_some())
    .map(|d| DolbyVisionFacts { profile: d.profile, compatibility_id: d.compatibility_id });

    let audio_streams = streams
        .iter()
        .filter(|s| s.get("codec_type").and_then(|t| t.as_str()) == Some("audio"))
        .map(|s| AudioStreamFacts {
            index: uint(s.get("index")).unwrap_or(0) as u32,
            codec: s.get("codec_name").and_then(|v| v.as_str()).map(str::to_string),
            sample_rate: uint(s.get("sample_rate")).map(|v| v as u32),
            channels: uint(s.get("channels")).map(|v| v as u32),
            channel_layout: s.get("channel_layout").and_then(|v| v.as_str()).map(str::to_string),
            bit_rate: uint(s.get("bit_rate")),
            start_time: num_str(s.get("start_time")),
        })
        .collect();

    Ok(SourceModel {
        schema: SOURCE_MODEL_SCHEMA,
        identity,
        format_name,
        container_start,
        duration,
        video: VideoFacts {
            codec: str_of("codec_name"),
            codec_tag_string: str_of("codec_tag_string"),
            pixel_format: str_of("pix_fmt"),
            width: uint(video.get("width")).unwrap_or(0) as i32,
            height: uint(video.get("height")).unwrap_or(0) as i32,
            sar: normalize_sar(video.get("sample_aspect_ratio").and_then(|v| v.as_str())),
            field_order: str_of("field_order"),
            r_frame_rate: r_str,
            avg_frame_rate: avg_str,
            frame_rate: fps,
            frame_count,
            stored_frames,
            stream_duration,
            stream_start,
            video_start_offset: start.offset,
            leading_pictures: start.leading,
            decoder_delay_frames,
            seek_plan,
            source_grid,
            variable_frame_rate: matches!((r, avg), (Some(r), Some(a)) if source_timing::rates_suggest_vfr(r, a)),
            frame_times,
            frame_times_start,
            pulldown_rate: crate::models::soft_telecine_decimates_at(fps),
            color_matrix: color_tag(video, "color_space"),
            color_primaries: color_tag(video, "color_primaries"),
            color_transfer: color_tag(video, "color_transfer"),
            color_range: color_tag(video, "color_range"),
            dolby_vision,
        },
        audio_streams,
        continuity,
        continuity_deferred,
    })
}

/// Finish a deferred model (`--complete-source`, task #55): run its reset
/// scan, reporting the fraction of the file read, and return the model with
/// `continuity` filled. A model that no longer describes its file (or has
/// another schema) is probed again in full; a model with nothing deferred is
/// returned as it is. A failed scan leaves `continuity: None`, as
/// [`probe_source`] does.
pub fn complete_source(
    ffprobe: &Path,
    env: &HashMap<String, String>,
    mut model: SourceModel,
    progress: impl FnMut(f64),
    log: impl Fn(&str) + Sync,
) -> anyhow::Result<SourceModel> {
    let path = model.identity.path.clone();
    if !model.describes(&path) {
        log("The source model no longer describes the file; probing it again");
        model = probe_source_with(ffprobe, env, &path, ScanMode::Deferred, &log)?;
    }
    if !model.continuity_deferred {
        return Ok(model);
    }
    model.continuity = source_continuity::scan_with_progress(ffprobe, env, &path, progress).ok();
    model.continuity_deferred = false;
    Ok(model)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn resource(name: &str) -> serde_json::Value {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/TestResources")
            .join(name);
        serde_json::from_str(&std::fs::read_to_string(p).unwrap()).unwrap()
    }

    fn inputs<'a>() -> CountInputs<'a> {
        CountInputs {
            stored_frames: None,
            r: Some(25.0),
            avg: Some(25.0),
            fps: 25.0,
            stream_duration: None,
            container_duration: None,
            stream_start: None,
            format_name: "matroska,webm",
            start: VideoStart::default(),
            grid: None,
            timeline_slots: None,
            discards: false,
        }
    }

    #[test]
    fn sar_is_normalised_as_the_app_did() {
        assert_eq!(normalize_sar(Some("16:15")), Some("16:15".into()));
        for raw in [None, Some(""), Some("N/A"), Some("1:1"), Some("0:1")] {
            assert_eq!(normalize_sar(raw), None, "{raw:?}");
        }
    }

    #[test]
    fn field_coded_rate_takes_the_average() {
        assert_eq!(select_frame_rate(Some(50.0), Some(25.0)), Some(25.0));
        assert_eq!(select_frame_rate(Some(25.0), Some(24.9)), Some(25.0));
        assert_eq!(select_frame_rate(None, Some(24.0)), Some(24.0));
        assert_eq!(select_frame_rate(Some(30.0), None), Some(30.0));
        assert_eq!(select_frame_rate(Some(0.0), None), None);
    }

    #[test]
    fn colour_tags_drop_unknown_and_keep_reserved() {
        let s = json!({"color_space": "reserved", "color_range": "unknown", "color_trc": ""});
        assert_eq!(color_tag(&s, "color_space").as_deref(), Some("reserved"));
        assert_eq!(color_tag(&s, "color_range"), None);
        assert_eq!(color_tag(&s, "color_trc"), None);
        assert_eq!(color_tag(&s, "color_primaries"), None);
    }

    /// The DVB-T vector the app's `videoStartFromProbe` was checked against:
    /// the stream starts after the container, three leading B pictures.
    #[test]
    fn video_start_counts_leading_pictures_on_dvbt() {
        let j = resource("video_start_probe_dvbt.json");
        let s = video_start(&j);
        assert!((s.offset - source_decode::video_start_from_probe(&j)).abs() < 1e-12);
        assert!(s.offset > 1.0, "{s:?}");
        assert!(s.leading > 0.1 && s.leading < 0.13, "{s:?}");
    }

    #[test]
    fn leading_pictures_count_only_when_the_stream_starts_late() {
        let j = json!({
            "format": {"start_time": "1.0"},
            "streams": [{"start_time": "1.0"}],
            "packets": [{"pts_time": "0.9"}, {"pts_time": "1.0"}],
        });
        assert_eq!(video_start(&j), VideoStart { offset: 0.0, leading: 0.0 });
    }

    #[test]
    fn stored_count_wins_for_constant_rate() {
        let i = CountInputs { stored_frames: Some(79), ..inputs() };
        assert_eq!(frame_count(&i, |_, _| panic!(), |_| panic!()), 79);
    }

    #[test]
    fn variable_rate_counts_timeline_slots_else_duration() {
        let i = CountInputs {
            stored_frames: Some(100),
            r: Some(30.0),
            avg: Some(28.0),
            fps: 30.0,
            stream_duration: Some(4.0),
            timeline_slots: Some(121),
            ..inputs()
        };
        assert_eq!(frame_count(&i, |_, _| None, |_| None), 121);
        let i = CountInputs { timeline_slots: None, ..i };
        assert_eq!(frame_count(&i, |_, _| None, |_| None), 120);
    }

    #[test]
    fn by_duration_uses_stream_duration_plus_leading_else_container_less_offset() {
        let start = VideoStart { offset: 1.2, leading: 0.12 };
        assert_eq!(frame_count_from_duration(Some(5.0), Some(6.4), start, 25.0), 128);
        assert_eq!(frame_count_from_duration(None, Some(6.32), start, 25.0), 128);
        assert_eq!(frame_count_from_duration(None, None, start, 25.0), 0);
        assert_eq!(frame_count_from_duration(Some(5.0), None, start, 0.0), 0);
    }

    /// Task #26's DVD (`seek_dvd_pal.mpg`): ffprobe's stream starts at 0.54
    /// and lasts 5.96 s (149 frames); the flushed P picture is 6.46 + 0.04,
    /// so 150 are decoded and counted.
    #[test]
    fn dvd_untimed_tail_is_counted() {
        let j = resource("tail_frames_probe_dvd_pal.json");
        let last = untimed_last_picture(&j, 25.0).expect("an untimed last picture");
        assert!((last - 6.50).abs() < 1e-9, "{last}");
        let i = CountInputs {
            fps: 25.0,
            stream_duration: Some(5.96),
            container_duration: Some(5.970022),
            stream_start: Some(0.54),
            format_name: "mpeg",
            ..inputs()
        };
        assert_eq!(frame_count(&i, |start, dur| {
            assert!((start + dur - TAIL_FRAMES_PROBE_SECONDS - 3.5).abs() < 1e-9);
            Some(last)
        }, |_| panic!()), 150);
    }

    #[test]
    fn untimed_tail_never_lowers_the_count() {
        assert_eq!(frame_count_with_untimed_tail(150, Some(1.0), 0.5, VideoStart::default(), 25.0), 150);
        assert_eq!(frame_count_with_untimed_tail(150, None, 0.5, VideoStart::default(), 25.0), 150);
    }

    #[test]
    fn matroska_counts_from_its_last_picture_on_the_grid() {
        let grid = SourceGrid { rate_num: 30000, rate_den: 1001, origin: 0.0 };
        let i = CountInputs {
            fps: 30000.0 / 1001.0,
            container_duration: Some(4.04),
            grid: Some(&grid),
            ..inputs()
        };
        let n = frame_count(&i, |_, _| panic!(), |_| Some(119.0 * 1001.0 / 30000.0));
        assert_eq!(n, 120);
        // No last picture: the container's duration.
        let n = frame_count(&i, |_, _| panic!(), |_| None);
        assert_eq!(n, (4.04 * 30000.0 / 1001.0_f64).round() as i64);
    }

    /// Task #54: an edit list's discarded packets are counted by
    /// `nb_frames` but never decoded; the count is the last kept picture's
    /// slot on the grid, plus one.
    #[test]
    fn an_edit_list_counts_from_its_last_kept_picture() {
        let grid = SourceGrid { rate_num: 2997, rate_den: 100, origin: 0.0 };
        // small_clip.mp4: 3154 stored, 3 discarded, the last picture at
        // 105.105105 s.
        let i = CountInputs {
            stored_frames: Some(3154),
            r: Some(29.97),
            avg: Some(29.97),
            fps: 29.97,
            stream_duration: Some(105.119119),
            container_duration: Some(105.119119),
            stream_start: Some(0.0),
            format_name: "mov,mp4,m4a,3gp,3g2,mj2",
            grid: Some(&grid),
            discards: true,
            ..inputs()
        };
        assert_eq!(frame_count(&i, |_, _| panic!(), |_| Some(105.105105)), 3151);
        // edit_list_bframes.mp4: 146 stored, 125 kept, holes before the end;
        // the grid decode is 128 slots.
        let grid = SourceGrid { rate_num: 30000, rate_den: 1001, origin: 0.0 };
        let i = CountInputs {
            stored_frames: Some(146),
            fps: 30000.0 / 1001.0,
            container_duration: Some(4.273233),
            grid: Some(&grid),
            ..i
        };
        assert_eq!(frame_count(&i, |_, _| panic!(), |_| Some(4.237567)), 128);
        // No last picture, or no grid: the stored count, as before.
        assert_eq!(frame_count(&i, |_, _| panic!(), |_| None), 146);
        let no_grid = CountInputs { grid: None, ..i };
        assert_eq!(frame_count(&no_grid, |_, _| panic!(), |_| panic!()), 146);
        // Without discards the tail is never asked.
        let plain = CountInputs { discards: false, ..i };
        assert_eq!(frame_count(&plain, |_, _| panic!(), |_| panic!()), 146);
        // A variable rate still counts its timeline first.
        let vfr = CountInputs { timeline_slots: Some(90), ..i };
        assert_eq!(frame_count(&vfr, |_, _| panic!(), |_| panic!()), 90);
    }

    #[test]
    fn the_tail_skips_discarded_packets() {
        let t = tail_pictures_from_csv("4.104100,K__\n4.237567,___\n4.270933,_D_\nN/A,___\n\n4.170767,___,\n");
        assert_eq!(t, TailPictures { last_kept: Some(4.237567), discards: true });
        // CRLF, and no discards.
        let t = tail_pictures_from_csv("1.0,K__\r\n2.0,___\r\n");
        assert_eq!(t, TailPictures { last_kept: Some(2.0), discards: false });
        assert_eq!(tail_pictures_from_csv(""), TailPictures::default());
    }

    #[test]
    fn only_the_mov_family_reads_its_tail_up_front() {
        assert!(is_mov_family("mov,mp4,m4a,3gp,3g2,mj2"));
        for f in ["matroska,webm", "avi", "mpegts", "mpeg", "mp3"] {
            assert!(!is_mov_family(f), "{f}");
        }
    }

    #[test]
    fn untimed_last_picture_follows_ffmpeg_dec() {
        let j = json!({"frames": [
            {"duration_time": "0.04"},
            {"best_effort_timestamp_time": "1.00", "duration_time": "0.04"},
            {"best_effort_timestamp_time": "1.04", "duration_time": "0.04"},
            {"duration_time": "0.04"},
        ]});
        assert!((untimed_last_picture(&j, 25.0).unwrap() - 1.08).abs() < 1e-9);
        let j = json!({"frames": [{"best_effort_timestamp_time": "1.00"}]});
        assert_eq!(untimed_last_picture(&j, 25.0), None);
    }

    #[test]
    fn a_deferred_scan_is_said_and_otherwise_absent() {
        let mut m = sample_model();
        let s = serde_json::to_string(&m).unwrap();
        assert!(!s.contains("continuityDeferred"), "absent unless deferred: {s}");
        m.continuity_deferred = true;
        let s = serde_json::to_string(&m).unwrap();
        assert!(s.contains("\"continuityDeferred\":true"), "{s}");
        assert_eq!(serde_json::from_str::<SourceModel>(&s).unwrap(), m);
    }

    #[test]
    fn model_round_trips_and_omits_absent_times() {
        let m = sample_model();
        let s = serde_json::to_string(&m).unwrap();
        assert!(!s.contains("frameTimes"), "{s}");
        assert!(s.contains("\"sourceGrid\":{\"rateNum\":25"), "{s}");
        assert_eq!(serde_json::from_str::<SourceModel>(&s).unwrap(), m);
        assert!(!m.describes("/x.mp4"), "a file that does not exist is never described");
    }

    fn job_with(extra: serde_json::Value) -> crate::models::VideoJob {
        let mut j = json!({
            "id": "00000000-0000-0000-0000-000000000050",
            "inputPath": "/x.mp4", "outputPath": "out.mkv",
            "qtgmcParameters": {}, "encodingSettings": {},
        });
        j.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        let mut job: crate::models::VideoJob = serde_json::from_value(j).unwrap();
        job.source = Some(sample_model());
        job
    }

    #[test]
    fn applying_the_model_fills_only_what_the_job_left_unset() {
        let mut job = job_with(json!({}));
        job.apply_source_model();
        assert_eq!((job.input_width, job.input_height), (Some(720), Some(576)));
        assert_eq!(job.input_frame_rate, Some(25.0));
        assert_eq!(job.input_sar.as_deref(), Some("16:15"));
        assert_eq!(job.video_start_offset, Some(0.0));
        assert_eq!(job.decoder_delay_frames, Some(0));
        assert_eq!(job.source_grid, Some(SourceGrid { rate_num: 25, rate_den: 1, origin: 0.0 }));
        assert_eq!(job.total_frames, Some(25), "a missing count is the model's");

        // A trim's count is the model's over the trim (task #54).
        for (start, end, want) in [
            (json!(5), json!(14), 10),
            (json!(null), json!(9), 10),
            (json!(20), json!(null), 5),
            (json!(30), json!(null), 0),
        ] {
            let mut job = job_with(json!({ "startFrame": start, "endFrame": end }));
            job.apply_source_model();
            assert_eq!(job.total_frames, Some(want), "{start} .. {end}");
        }
        // A job's own count is never replaced.
        let mut job = job_with(json!({ "totalFrames": 7 }));
        job.apply_source_model();
        assert_eq!(job.total_frames, Some(7));

        let mut job = job_with(json!({
            "inputWidth": 704, "inputHeight": 480, "inputSar": "10:11", "videoStartOffset": 0.5,
        }));
        job.apply_source_model();
        assert_eq!((job.input_width, job.input_height), (Some(704), Some(480)));
        assert_eq!(job.input_sar.as_deref(), Some("10:11"));
        assert_eq!(job.video_start_offset, Some(0.5));
    }

    /// Task #54: the model counts every job, except where it can't stand for
    /// the decode (no model, or a raw MPEG-PS/TS whose timestamps reset).
    #[test]
    fn only_an_unchecked_reset_source_is_counted_by_decoding() {
        let job = job_with(json!({}));
        assert!(!job.counts_by_decoding());
        assert_eq!(job.model_frame_count(), Some(25));

        let mut job = job_with(json!({}));
        job.source = None;
        assert!(job.counts_by_decoding());
        assert_eq!(job.model_frame_count(), None);

        let reset = ContinuityScan {
            format: "mpegts".into(),
            applies: true,
            resets: vec![source_continuity::Reset {
                stream: 0,
                codec_type: "video".into(),
                packet: 150,
                from: 6.0,
                to: 0.0,
            }],
            video_packets: 300,
            join: None,
        };
        let mut job = job_with(json!({}));
        job.source.as_mut().unwrap().continuity = Some(reset.clone());
        assert!(job.counts_by_decoding(), "a raw reset file: the model counts its last segment");
        assert_eq!(job.model_frame_count(), None);
        job.continuity_checked = true;
        assert!(!job.counts_by_decoding(), "the app's joined copy is counted by its model");

        let mut job = job_with(json!({}));
        job.source.as_mut().unwrap().continuity = Some(ContinuityScan { resets: vec![], ..reset });
        assert!(!job.counts_by_decoding());
    }

    /// `grid_from_probe` takes the job's rate when the stream's is not
    /// within `GRID_RATE_TOLERANCE` of it; the model's grid follows.
    #[test]
    fn the_grid_is_at_the_jobs_rate() {
        let mut job = job_with(json!({ "inputFrameRate": 25.0 }));
        job.apply_source_model();
        assert_eq!(job.source_grid, Some(SourceGrid { rate_num: 25, rate_den: 1, origin: 0.0 }));

        let mut job = job_with(json!({ "inputFrameRate": 50.0 }));
        if let Some(m) = job.source.as_mut() {
            m.video.source_grid = Some(SourceGrid { rate_num: 25, rate_den: 1, origin: 0.4 });
        }
        job.apply_source_model();
        let g = job.source_grid.unwrap();
        assert_eq!(g.fps(), 50.0);
        assert_eq!(g.origin, 0.4);
    }

    fn sample_model() -> SourceModel {
        SourceModel {
            schema: SOURCE_MODEL_SCHEMA,
            identity: SourceIdentity { path: "/x.mp4".into(), size_bytes: 1, modified_ms: 2 },
            format_name: "mov,mp4".into(),
            container_start: Some(0.0),
            duration: Some(1.0),
            video: VideoFacts {
                codec: Some("h264".into()),
                codec_tag_string: None,
                pixel_format: Some("yuv420p".into()),
                width: 720,
                height: 576,
                sar: Some("16:15".into()),
                field_order: None,
                r_frame_rate: Some("25/1".into()),
                avg_frame_rate: Some("25/1".into()),
                frame_rate: 25.0,
                frame_count: 25,
                stored_frames: Some(25),
                stream_duration: Some(1.0),
                stream_start: Some(0.0),
                video_start_offset: 0.0,
                leading_pictures: 0.0,
                decoder_delay_frames: 0,
                seek_plan: None,
                source_grid: Some(SourceGrid { rate_num: 25, rate_den: 1, origin: 0.0 }),
                variable_frame_rate: false,
                frame_times: None,
                frame_times_start: None,
                pulldown_rate: false,
                color_matrix: None,
                color_primaries: None,
                color_transfer: None,
                color_range: None,
                dolby_vision: None,
            },
            audio_streams: vec![],
            continuity: None,
            continuity_deferred: false,
        }
    }

    #[test]
    fn timeline_is_built_from_stored_times() {
        // 30 fps with every fourth frame missing.
        let times: Vec<f64> = (0..40).filter(|i| i % 4 != 3).map(|i| i as f64 / 30.0).collect();
        let mut m: SourceModel = serde_json::from_value(json!({
            "schema": 1,
            "identity": {"path": "/v.mp4", "sizeBytes": 1, "modifiedMs": 1},
            "formatName": "mov,mp4",
            "video": {"width": 16, "height": 16, "frameRate": 30.0, "frameCount": 40,
                      "videoStartOffset": 0.0, "leadingPictures": 0.0, "decoderDelayFrames": 0,
                      "variableFrameRate": true, "pulldownRate": true},
            "audioStreams": []
        }))
        .unwrap();
        assert!(m.timeline(30.0, |_| {}).is_none());
        m.video.frame_times = Some(times);
        let t = m.timeline(30.0, |_| {}).expect("irregular times make a timeline");
        // The last stored frame is 38 (39 is a gap): it is shown for one frame.
        assert_eq!(t.slot_count(), 39);
    }
}
