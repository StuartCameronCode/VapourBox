//! The ffmpeg arguments that decode the source into the raw pipe `pipe_source`
//! reads — the single place both the encode and the preview path get them from.
//!
//! `pipe_source.py` sizes every frame from the job's `input_width` x
//! `input_height` (ffprobe's `width`/`height`), so the decoder must emit frames
//! of exactly that size or the byte stream desyncs into garbage. Two rules keep
//! that true without ever resampling the picture:
//!
//! 1. **Decode the full stored frame** — `-apply_cropping codec`. Since FFmpeg
//!    7.1 the CLI applies *container* cropping by default: a QuickTime `clap`
//!    (clean aperture) atom or a Matroska `PixelCrop*` element is exported as
//!    frame-cropping side data and cut off at decode time. ffprobe's
//!    `width`/`height` do **not** include it (they report the full 720x576 of a
//!    720x576 ProRes with a 702-wide clean aperture; the crop only appears as
//!    `side_data_list: Frame Cropping`), so the default decode came out 702 wide
//!    against a job that said 720. `codec` keeps the *bitstream's* own cropping
//!    (the H.264/HEVC SPS crop that turns 1088 coded lines into 1080), which
//!    ffprobe's `width`/`height` already include — so the decoded size is the
//!    probed size by construction. The user's Crop controls are then the only
//!    crop the pipeline ever applies. (`none` would be wrong: it would decode an
//!    H.264 1080p stream at 1920x1088.)
//! 2. **A size mismatch is an error, never a resample.** This used to pass
//!    `-s WxH`, which "fixed" the clean-aperture desync by silently rescaling the
//!    702-wide crop back to 720 — cropped *and* resampled, with a 2.6%
//!    horizontal stretch. [`size_guard_filter`] instead passes frames of exactly
//!    the expected size through untouched (a full-frame `crop` is a pointer
//!    no-op) and fails the decode on any other size, including a mid-stream
//!    resolution change, which with no guard at all would desync into garbage.
//! 3. **A seek must not shift the frames** (issue #157). Writing `rawvideo`,
//!    ffmpeg times its output at a constant rate (the muxer has
//!    `AVFMT_NOTIMESTAMPS` but not `AVFMT_VARIABLE_FPS`). After an input `-ss`
//!    to `(first - 0.5) / fps`, the first kept frame arrives half a frame
//!    after the seek point, and for many time bases (1/2997 MP4, 1/11988 MOV,
//!    1/90000 TS) constant-rate timing fills that gap by emitting the frame
//!    **twice**: the preview showed frame N-1 and a trim of 100..109 came out
//!    `100, 100, 101 .. 108`. [`RESET_PTS_FILTER`] rebases the first kept frame
//!    to 0, on every decoder that seeks. Not `-fps_mode passthrough`: that
//!    also drops a soft-telecine source's pulldown repeats, which IVTC expects.
//!
//! 4. **An invalid colour tag is cleared before anything converts.** FFmpeg 9's
//!    scaler refuses a frame tagged `reserved` (ProRes writes code 0 for
//!    "unknown", which FFmpeg reads as reserved), and the decoder converts
//!    whenever the pipe format is not the source's own (ProRes 4444 with alpha,
//!    `yuva444p12le`) or a detector asks for another format. Every builder
//!    takes the job's `VideoJob::decode_tag_neutraliser` and puts it first in
//!    its one `-vf` ([`decoder_filter`]); `None` leaves the args exactly as they
//!    were.
//!
//! 5. **Frame N counts from the video's first picture, and every seek says
//!    so.** An input `-ss` is measured from the *container's* start,
//!    which is the earliest stream's: on a broadcast capture that is the
//!    audio, 1.3 s before the first picture. [`seek_time`] adds the job's
//!    `video_start_offset` ([`probe_video_start`]: the first presented
//!    picture's PTS minus the container start) to every seek. A decoder that
//!    does not seek still resets PTS when the offset is non-zero, which drops
//!    the copies of the first picture that ffmpeg's constant-rate output would
//!    otherwise put into the gap (MKV/MP4) and keeps open-GOP leading pictures
//!    that it would drop as negative-time (TS). With no offset nothing changes.
//!
//! 6. **MPEG-TS/PS seek a GOP early and drop to the frame by time** (issue
//!    #169). They have no keyframe index: libavformat seeks them by a
//!    timestamp binary search that treats every packet as a keyframe, so an
//!    input `-ss` lands on a non-key packet inside frame N's GOP and the
//!    decoder starts at the *next* keyframe (DVD, GOP 12: 40 -> 48; H.264 TS,
//!    GOP 25: 40 -> 50; nothing at all past the last keyframe). For those
//!    formats the job carries a [`SeekPlan`] ([`seek_plan_from_probe`]): the
//!    decoder seeks `preroll` (one GOP plus reorder delay, measured) before
//!    the target, keeps the file's own timestamps (`-copyts`) and drops to the
//!    target with an absolute `trim` ahead of the PTS reset. Without
//!    `-copyts` the timestamps after a seek that falls before a late video's
//!    first packet are rebased differently, and a relative trim keeps the
//!    wrong frame. Every other format has no plan and keeps its arguments
//!    byte for byte ([`decoder_seek`]).
//!
//! See docs/ENGINEERING_NOTES.md, "Clean aperture: decode the stored frame",
//! docs/reports/issue-157-seek-alignment, docs/reports/issue-169-mpeg-seek and
//! docs/reports/2026-11-reserved-colour-tags.

/// Input option placed before `-i` on every ffmpeg that decodes the source's
/// pictures for the pipeline (encode decoder, preview decoder). See the module
/// docs for why `codec` and not `none`/`all`.
pub const APPLY_CROPPING: [&str; 2] = ["-apply_cropping", "codec"];

/// First filter of a decoder that seeks: the first kept frame becomes PTS 0, so
/// constant-rate output timing has no gap to fill with a repeated frame. See
/// rule 3 in the module docs.
pub const RESET_PTS_FILTER: &str = "setpts=PTS-STARTPTS";

/// The message ffmpeg's `crop` filter logs when [`size_guard_filter`] rejects a
/// frame. Used to recognise a guard failure in the decoder's stderr and replace
/// ffmpeg's cryptic wording with an explanation.
pub const SIZE_GUARD_SIGNATURE: &str = "Invalid too big or non positive size";

/// A `-vf` that passes `width`x`height` frames through unchanged and fails the
/// decode on anything else.
///
/// `crop` re-evaluates `w`/`h` whenever its input is (re)configured — at the
/// first frame and again on any mid-stream size change — and rejects a zero
/// size. So a matching frame is a full-frame, zero-copy crop, and a mismatch is
/// a hard error instead of either a rescale or a silently desynced raw stream.
pub fn size_guard_filter(width: i32, height: i32) -> String {
    format!(
        "crop=w='if(eq(iw\\,{w})\\,iw\\,0)':h='if(eq(ih\\,{h})\\,ih\\,0)':x=0:y=0:exact=1",
        w = width,
        h = height
    )
}

/// The decoder's single `-vf` (ffmpeg honours only the last one): the
/// colour-tag neutraliser if the source needs one, the drop to the target
/// frame when the decoder seeks early (rule 6), the PTS reset when the decoder
/// seeks, then the size guard.
pub fn decoder_filter(
    width: i32,
    height: i32,
    seeks: bool,
    tag_fix: Option<&str>,
    trim_from: Option<f64>,
) -> String {
    let mut chain: Vec<String> = Vec::new();
    if let Some(fix) = tag_fix {
        chain.push(fix.to_string());
    }
    if let Some(t) = trim_from {
        chain.push(trim_filter(t));
    }
    if seeks || trim_from.is_some() {
        chain.push(RESET_PTS_FILTER.to_string());
    }
    chain.push(size_guard_filter(width, height));
    chain.join(",")
}

/// Packets read to find the first presented picture: enough to cover the
/// reorder window of any open GOP (leading B pictures come after their I
/// picture in the file but are shown before it).
pub const VIDEO_START_PACKETS: u32 = 64;

/// ffprobe's arguments (before the input) for [`video_start_from_probe`]. The
/// app runs the same (`FieldOrderDetector.videoStartProbeArgs`).
pub const VIDEO_START_PROBE_ARGS: [&str; 10] = [
    "-v", "error",
    "-select_streams", "v:0",
    "-show_entries", "packet=pts_time:stream=start_time:format=start_time",
    "-read_intervals", "%+#64",
    "-of", "json",
];

/// Where the video's first picture starts, in seconds after the container's
/// start (which is what an input `-ss` is measured from): the earlier of the
/// video stream's `start_time` and the smallest PTS among its first packets,
/// minus the format's `start_time`. Never negative; 0 when the video starts
/// first, or when anything is missing.
///
/// Not the stream's `start_time` alone: that is the first packet's, and on an
/// open GOP the pictures shown before it come later in the file (the DVB-T
/// fixture's three leading B pictures sit 0.12 s before its I picture). Not
/// the packets alone either: MPEG-2 in AVI stores packets with no PTS
/// (`hard_telecine_test.avi`'s first two), so the smallest one *listed* can
/// be a later picture's.
///
/// `json` is ffprobe's output for [`VIDEO_START_PROBE_ARGS`].
pub fn video_start_from_probe(json: &serde_json::Value) -> f64 {
    let num = |v: Option<&serde_json::Value>| v.and_then(|s| s.as_str()).and_then(|s| s.parse::<f64>().ok());
    let container = num(json.get("format").and_then(|f| f.get("start_time")));
    let stream = num(json
        .get("streams")
        .and_then(|s| s.as_array())
        .and_then(|s| s.first())
        .and_then(|s| s.get("start_time")));
    let first = json
        .get("packets")
        .and_then(|p| p.as_array())
        .map(|packets| {
            packets
                .iter()
                .filter_map(|p| num(p.get("pts_time")))
                .fold(stream.unwrap_or(f64::INFINITY), f64::min)
        })
        .or(stream)
        .filter(|t| t.is_finite());
    match (container, first) {
        (Some(c), Some(f)) if f > c => f - c,
        _ => 0.0,
    }
}

/// [`video_start_from_probe`] for a file. `None` when ffprobe could not read
/// it (the caller then treats the offset as 0, today's behaviour).
pub fn probe_video_start(
    ffprobe: &std::path::Path,
    env: &std::collections::HashMap<String, String>,
    input: &str,
) -> Option<f64> {
    let out = std::process::Command::new(ffprobe)
        .args(VIDEO_START_PROBE_ARGS)
        .arg(input)
        .envs(env)
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    Some(video_start_from_probe(&json))
}

/// Whether the file has an audio stream. Asked only when the video starts
/// late: the gap is kept in the output only to keep sound and picture in
/// step, so with no sound there is nothing to keep (a DVB recording stripped
/// of its audio can still start with a teletext or data stream). `None` when
/// ffprobe could not answer.
pub fn probe_has_audio(
    ffprobe: &std::path::Path,
    env: &std::collections::HashMap<String, String>,
    input: &str,
) -> Option<bool> {
    let out = std::process::Command::new(ffprobe)
        .args(["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", input])
        .envs(env)
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| !String::from_utf8_lossy(&out.stdout).trim().is_empty())
}

/// The input `-ss` that makes source frame `frame` the first one decoded, or
/// `None` for frame 0 (decode from the start: see rule 5 for why frame 0
/// never seeks, even when the video starts after the container).
///
/// The midpoint of the interval *before* `frame`, so the first kept frame
/// (PTS >= the seek time) is exactly `frame` under PTS rounding, plus the
/// video's start offset, since `-ss` counts from the container's start.
/// Every decoder of the source takes its seek from here.
pub fn seek_time(frame: i64, fps: f64, video_start: f64) -> Option<f64> {
    if frame <= 0 {
        return None;
    }
    let fps = if fps > 0.0 { fps } else { 29.97 };
    let t = (frame as f64 - 0.5) / fps + video_start.max(0.0);
    (t > 0.0).then_some(t)
}

/// Whether a decoder resets PTS: when it seeks (rule 3) and, whatever it
/// does, when the video starts after the container (rule 5).
pub fn resets_pts(seeks: bool, video_start: f64) -> bool {
    seeks || video_start > 0.0
}

/// The `trim` that drops every frame before `t`, an absolute timestamp in
/// seconds (the decoder runs with `-copyts`, rule 6).
pub fn trim_filter(t: f64) -> String {
    format!("trim=start={:.6}", t)
}

/// Formats seeked by a timestamp search rather than an index (rule 6), as
/// ffprobe's `format_name` names them: MPEG-TS (also M2TS) and MPEG-PS
/// (`.mpg`, `.vob`, a DVD import). Matched per comma-separated entry, so
/// `mpegvideo` (a raw elementary stream) is not one of them.
pub const TIMESTAMP_SEARCH_FORMATS: [&str; 2] = ["mpegts", "mpeg"];

/// Seconds of the video read to measure its GOP.
pub const SEEK_PROBE_SECONDS: u32 = 20;

/// ffprobe's arguments (before the input) for [`seek_plan_from_probe`]. The
/// app runs the same (`FieldOrderDetector.seekProbeArgs`).
pub const SEEK_PROBE_ARGS: [&str; 10] = [
    "-v", "error",
    "-select_streams", "v:0",
    "-show_entries", "packet=pts_time,dts_time,flags:format=format_name,start_time",
    "-read_intervals", "%+20",
    "-of", "json",
];

/// Added to the measured GOP and reorder delay: the search's own slack and a
/// couple of frames.
pub const SEEK_PREROLL_MARGIN: f64 = 0.5;

/// The smallest preroll, whatever the GOP measures.
pub const SEEK_PREROLL_MIN: f64 = 1.0;

/// How a decoder of a timestamp-searched source seeks (rule 6): `preroll`
/// seconds before the target, then an absolute `trim` at
/// `container_start` + the target.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeekPlan {
    /// Seconds to seek before the target: at least one GOP plus the reorder
    /// delay, so a keyframe is reached before the target is.
    pub preroll: f64,
    /// The container's `start_time` (what `-ss` counts from), in the
    /// timestamps `-copyts` keeps.
    pub container_start: f64,
}

impl SeekPlan {
    /// Whether the plan is usable (finite, non-negative values).
    pub fn is_valid(&self) -> bool {
        self.preroll.is_finite() && self.preroll > 0.0 && self.container_start.is_finite()
    }
}

/// The [`SeekPlan`] for a source, from ffprobe's answer to
/// [`SEEK_PROBE_ARGS`], or `None` when its format seeks by index (seek as
/// before).
///
/// The preroll is the largest gap between keyframes in the window, plus the
/// largest PTS - DTS (B-picture reorder) and [`SEEK_PREROLL_MARGIN`], at
/// least [`SEEK_PREROLL_MIN`]. The search lands at DTS <= the seek point; the
/// next keyframe's DTS is at most one GOP later and it is presented at most
/// the reorder delay after that, so it is shown no later than the target.
/// With fewer than two keyframes in the window, the GOP is at least the
/// window, which becomes the preroll.
pub fn seek_plan_from_probe(json: &serde_json::Value) -> Option<SeekPlan> {
    let format = json.get("format")?;
    let name = format.get("format_name")?.as_str()?;
    if !name.split(',').any(|n| TIMESTAMP_SEARCH_FORMATS.contains(&n.trim())) {
        return None;
    }
    let num = |v: Option<&serde_json::Value>| {
        v.and_then(|s| s.as_str()).and_then(|s| s.parse::<f64>().ok()).filter(|t| t.is_finite())
    };
    let container_start = num(format.get("start_time")).unwrap_or(0.0);
    let packets = json.get("packets").and_then(|p| p.as_array()).cloned().unwrap_or_default();
    let mut keys: Vec<f64> = Vec::new();
    let mut reorder: f64 = 0.0;
    for p in &packets {
        let pts = num(p.get("pts_time"));
        let dts = num(p.get("dts_time"));
        if let (Some(pts), Some(dts)) = (pts, dts) {
            reorder = reorder.max(pts - dts);
        }
        let key = p.get("flags").and_then(|f| f.as_str()).is_some_and(|f| f.starts_with('K'));
        if let (true, Some(t)) = (key, pts.or(dts)) {
            keys.push(t);
        }
    }
    let gop = if keys.len() < 2 {
        SEEK_PROBE_SECONDS as f64
    } else {
        keys.windows(2).map(|w| w[1] - w[0]).fold(0.0, f64::max)
    };
    let preroll = (gop + reorder + SEEK_PREROLL_MARGIN).max(SEEK_PREROLL_MIN);
    Some(SeekPlan { preroll, container_start })
}

/// [`seek_plan_from_probe`] for a file. `None` when the format needs no plan
/// or ffprobe could not read it (the decoders then seek as before).
pub fn probe_seek_plan(
    ffprobe: &std::path::Path,
    env: &std::collections::HashMap<String, String>,
    input: &str,
) -> Option<SeekPlan> {
    let out = std::process::Command::new(ffprobe)
        .args(SEEK_PROBE_ARGS)
        .arg(input)
        .envs(env)
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    seek_plan_from_probe(&json)
}

/// What one decoder does to start at a target: its `-ss` (if any) and, under
/// a [`SeekPlan`], the absolute time `trim` drops to (`-copyts` with it).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct DecoderSeek {
    pub ss: Option<f64>,
    pub trim_from: Option<f64>,
}

impl DecoderSeek {
    /// Whether the decoder starts anywhere but the beginning.
    pub fn seeks(&self) -> bool {
        self.ss.is_some() || self.trim_from.is_some()
    }

    /// The `-copyts`/`-ss` input options, in order, before `-i`.
    fn input_args(&self) -> Vec<String> {
        let mut args = Vec::new();
        if self.trim_from.is_some() {
            args.push("-copyts".to_string());
        }
        if let Some(t) = self.ss {
            args.push("-ss".to_string());
            args.push(format!("{:.6}", t));
        }
        args
    }
}

/// How a decoder reaches `target` (a [`seek_time`]: container-relative, or
/// `None` to start at the beginning). Without a plan it is the plain `-ss`
/// it always was; with one, `-ss` moves `preroll` earlier (omitted when that
/// is before the start) and the target becomes an absolute `trim`.
pub fn decoder_seek(target: Option<f64>, plan: Option<&SeekPlan>) -> DecoderSeek {
    let Some(t) = target.filter(|t| *t > 0.0) else {
        return DecoderSeek::default();
    };
    match plan.filter(|p| p.is_valid()) {
        None => DecoderSeek { ss: Some(t), trim_from: None },
        Some(p) => {
            let early = t - p.preroll;
            DecoderSeek {
                ss: (early > 0.0).then_some(early),
                trim_from: Some(p.container_start + t),
            }
        }
    }
}

/// If a failed decoder's stderr shows the size guard tripped, the error to
/// report instead of ffmpeg's exit code.
pub fn explain_decoder_failure(stderr: &str, width: i32, height: i32) -> Option<String> {
    if !stderr.contains(SIZE_GUARD_SIGNATURE) {
        return None;
    }
    Some(format!(
        "The source decoded at a different frame size than the {}x{} it was probed at \
         (for example, its resolution changes part-way through). VapourBox does not \
         resample the source to hide this, since that would silently distort it. \
         Trim the job to a section with a single frame size, or convert the source \
         to one size first.",
        width, height
    ))
}

/// Everything the encode path's decoder ffmpeg needs, in order. Writes the raw
/// frames to stdout (`pipe:1`) for vspipe.
///
/// `pix_fmt` must be `pixel_format::decode_pixel_format`'s answer — the same one
/// the generated script declares (see "Source Pixel Formats" in CLAUDE.md).
#[allow(clippy::too_many_arguments)]
pub fn encode_decoder_args(
    input_path: &str,
    width: i32,
    height: i32,
    pix_fmt: &str,
    input_frame_rate: Option<f64>,
    start_frame: Option<i32>,
    end_frame: Option<i32>,
    total_frames: Option<i32>,
    video_start: f64,
    tag_fix: Option<&str>,
    plan: Option<&SeekPlan>,
) -> Vec<String> {
    let mut args: Vec<String> = Vec::new();

    // Seek to the start frame if specified (before -i for an accurate,
    // fast decode-seek), at [`seek_time`]. The seek then needs the PTS reset
    // (module docs, rule 3), and on a TS/PS a preroll and a trim (rule 6); an
    // untrimmed decode of a source whose streams start together is left
    // exactly as it was.
    let seek = decoder_seek(
        start_frame.and_then(|start| {
            seek_time(start as i64, input_frame_rate.unwrap_or(29.97), video_start)
        }),
        plan,
    );
    args.extend(seek.input_args());
    let reset = resets_pts(seek.seeks(), video_start);

    args.extend(APPLY_CROPPING.iter().map(|s| s.to_string()));
    args.extend([
        "-i".to_string(), input_path.to_string(),
        "-map".to_string(), "0:v:0".to_string(), // only first video stream
        "-vf".to_string(), decoder_filter(width, height, reset, tag_fix, seek.trim_from),
        "-f".to_string(), "rawvideo".to_string(),
        "-pix_fmt".to_string(), pix_fmt.to_string(),
        "-v".to_string(), "error".to_string(),
    ]);

    // Limit decoder frame count to match what pipe_source expects.
    // Without this, the decoder can send more frames than TOTAL_FRAMES
    // (e.g. MPEG-2 telecine produces duplicate frames), causing a broken
    // pipe when vspipe closes stdin before the decoder finishes.
    // For trimmed exports, limit to the trimmed range instead.
    if let (Some(start), Some(end)) = (start_frame, end_frame) {
        let count = end - start + 1;
        if count > 0 {
            args.push("-frames:v".to_string());
            args.push(count.to_string());
        }
    } else if let Some(end) = end_frame {
        let count = end + 1;
        args.push("-frames:v".to_string());
        args.push(count.to_string());
    } else if let Some(total) = total_frames {
        args.push("-frames:v".to_string());
        args.push(total.to_string());
    }

    args.push("pipe:1".to_string()); // stdout via FFmpeg pipe protocol
    args
}

/// The preview path's decoder (also the detectors'): `num_frames` raw frames
/// from `seek_time` into `output_path`. Same cropping, size and seek rules as
/// [`encode_decoder_args`]: a window starting at frame 0 (`seek` `None`, from
/// [`seek_time`]) does not seek, exactly like an untrimmed encode, so the two
/// agree on frame 0.
#[allow(clippy::too_many_arguments)]
pub fn preview_decoder_args(
    input_path: &str,
    seek: Option<f64>,
    num_frames: i32,
    width: i32,
    height: i32,
    pix_fmt: &str,
    output_path: &str,
    video_start: f64,
    tag_fix: Option<&str>,
    plan: Option<&SeekPlan>,
) -> Vec<String> {
    let seek = decoder_seek(seek, plan);
    let mut args: Vec<String> = seek.input_args();
    let reset = resets_pts(seek.seeks(), video_start);
    args.extend(APPLY_CROPPING.iter().map(|s| s.to_string()));
    args.extend([
        "-i".to_string(), input_path.to_string(),
        "-map".to_string(), "0:v:0".to_string(),
        "-frames:v".to_string(), num_frames.to_string(),
        "-vf".to_string(), decoder_filter(width, height, reset, tag_fix, seek.trim_from),
        "-f".to_string(), "rawvideo".to_string(),
        "-pix_fmt".to_string(), pix_fmt.to_string(),
        "-v".to_string(), "error".to_string(),
        "-y".to_string(),
        output_path.to_string(),
    ]);
    args
}

/// The decoder for a variable-frame-rate source (see `source_timing`), encode
/// and preview alike: the window's stored frames, exactly as stored.
///
/// `-fps_mode passthrough` is the point. Writing `rawvideo`, ffmpeg otherwise
/// converts to constant rate itself, repeating a frame into every gap — the
/// script could then no longer tell a gap from a frame, and the stored-frame
/// count the window asks for would be the wrong length. The script places the
/// frames on the grid instead.
pub fn timeline_decoder_args(
    input_path: &str,
    width: i32,
    height: i32,
    pix_fmt: &str,
    window: &crate::source_timing::TimelineWindow,
    output: &str,
    tag_fix: Option<&str>,
    plan: Option<&SeekPlan>,
) -> Vec<String> {
    // Passthrough timing needs no PTS reset after a plain seek; a TS/PS one
    // (rule 6) gets the trim, and the reset with it.
    let seek = decoder_seek(window.seek_time, plan);
    let mut args: Vec<String> = seek.input_args();
    args.extend(APPLY_CROPPING.iter().map(|s| s.to_string()));
    args.extend([
        "-i".to_string(), input_path.to_string(),
        "-map".to_string(), "0:v:0".to_string(),
        "-vf".to_string(), decoder_filter(width, height, false, tag_fix, seek.trim_from),
        "-fps_mode".to_string(), "passthrough".to_string(),
        "-frames:v".to_string(), window.src_count.to_string(),
        "-f".to_string(), "rawvideo".to_string(),
        "-pix_fmt".to_string(), pix_fmt.to_string(),
        "-v".to_string(), "error".to_string(),
        "-y".to_string(),
        output.to_string(),
    ]);
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_args() -> Vec<String> {
        encode_decoder_args("in.mov", 720, 576, "yuv422p10le", Some(25.0), None, None, Some(100), 0.0, None, None)
    }

    fn preview_args() -> Vec<String> {
        preview_decoder_args("in.mov", Some(0.38), 11, 720, 576, "yuv422p10le", "frames.raw", 0.0, None, None)
    }

    fn pos(args: &[String], flag: &str) -> Option<usize> {
        args.iter().position(|a| a == flag)
    }

    fn timeline_window() -> crate::source_timing::TimelineWindow {
        crate::source_timing::TimelineWindow {
            src_count: 9,
            seek_time: Some(1.25),
            slots: Vec::new(),
        }
    }

    fn timeline_args() -> Vec<String> {
        timeline_decoder_args("in.mov", 720, 576, "yuv422p10le", &timeline_window(), "pipe:1", None, None)
    }

    /// Every decoder, so every assertion below covers every path.
    fn both() -> [(&'static str, Vec<String>); 3] {
        [("encode", encode_args()), ("preview", preview_args()), ("timeline", timeline_args())]
    }

    #[test]
    fn decoders_never_rescale_the_source() {
        // `-s WxH` on the decoder output silently resamples a source that
        // decodes at another size (a clean aperture: 702 -> 720). Neither it nor
        // a scale filter may come back.
        for (path, args) in both() {
            assert!(pos(&args, "-s").is_none(), "{path} decoder passes -s: {args:?}");
            assert!(
                !args.iter().any(|a| a.contains("scale")),
                "{path} decoder scales: {args:?}"
            );
        }
    }

    #[test]
    fn decoders_keep_the_container_crop_off() {
        // `-apply_cropping codec` is an INPUT option: it must precede `-i`, or
        // ffmpeg applies it to the output and the clap crop still happens.
        for (path, args) in both() {
            let ac = pos(&args, "-apply_cropping")
                .unwrap_or_else(|| panic!("{path} decoder has no -apply_cropping: {args:?}"));
            assert_eq!(args[ac + 1], "codec", "{path}: must be `codec`, not none/all");
            assert!(ac < pos(&args, "-i").unwrap(), "{path}: -apply_cropping after -i");
        }
    }

    #[test]
    fn decoders_guard_the_probed_size() {
        for (path, args) in both() {
            let vf = pos(&args, "-vf").unwrap_or_else(|| panic!("{path}: no -vf"));
            // The guard is the chain's last filter (a seeking decoder resets
            // PTS ahead of it).
            assert!(args[vf + 1].ends_with(&size_guard_filter(720, 576)), "{path}: {args:?}");
            // Exactly one -vf: ffmpeg honours only the last.
            assert_eq!(args.iter().filter(|a| *a == "-vf").count(), 1, "{path}");
            assert!(vf > pos(&args, "-i").unwrap(), "{path}: -vf must be an output option");
        }
    }

    fn vf(args: &[String]) -> &str {
        &args[pos(args, "-vf").expect("a -vf") + 1]
    }

    #[test]
    fn seeking_decoders_reset_pts_before_the_guard() {
        // Issue #157: after a seek, rawvideo's constant-rate timing repeated
        // the first frame. The reset must come first in the ONE -vf chain.
        let trimmed =
            encode_decoder_args("in.mov", 720, 576, "yuv420p", Some(25.0), Some(10), Some(19), None, 0.0, None, None);
        for (path, args) in [("trimmed encode", trimmed), ("preview", preview_args())] {
            assert!(pos(&args, "-ss").is_some(), "{path} seeks");
            assert_eq!(
                vf(&args),
                format!("{},{}", RESET_PTS_FILTER, size_guard_filter(720, 576)),
                "{path}"
            );
            assert_eq!(args.iter().filter(|a| *a == "-vf").count(), 1, "{path}");
            assert_eq!(RESET_PTS_FILTER, "setpts=PTS-STARTPTS");
            // Never passthrough timing: it drops soft-telecine pulldown repeats.
            assert!(pos(&args, "-fps_mode").is_none(), "{path}");
        }
    }

    #[test]
    fn decoders_that_do_not_seek_are_unchanged() {
        // An untrimmed encode (and a trim from frame 0) keeps exactly its old
        // arguments: no seek, so nothing to reset.
        let untrimmed = encode_args();
        let from_zero =
            encode_decoder_args("in.mov", 720, 576, "yuv422p10le", Some(25.0), Some(0), Some(19), None, 0.0, None, None);
        let preview_at_zero =
            preview_decoder_args("in.mov", None, 4, 720, 576, "yuv422p10le", "frames.raw", 0.0, None, None);
        for (path, args) in
            [("untrimmed", untrimmed), ("from zero", from_zero), ("preview at 0", preview_at_zero)]
        {
            assert!(pos(&args, "-ss").is_none(), "{path}: {args:?}");
            assert_eq!(vf(&args), size_guard_filter(720, 576), "{path}");
        }
        // The VFR decoder places stored frames itself and is left alone.
        assert_eq!(vf(&timeline_args()), size_guard_filter(720, 576));
    }

    #[test]
    fn size_guard_is_a_full_frame_crop_that_rejects_other_sizes() {
        let g = size_guard_filter(720, 576);
        assert_eq!(
            g,
            "crop=w='if(eq(iw\\,720)\\,iw\\,0)':h='if(eq(ih\\,576)\\,ih\\,0)':x=0:y=0:exact=1"
        );
        // Anchored at the origin — never a centred crop of a larger frame.
        assert!(g.contains(":x=0:y=0"));
    }

    #[test]
    fn decoders_use_the_pipe_format() {
        for (path, args) in both() {
            let pf = pos(&args, "-pix_fmt").unwrap();
            assert_eq!(args[pf + 1], "yuv422p10le", "{path}");
        }
    }

    #[test]
    fn encode_decoder_trims_and_limits_frames() {
        let args = encode_decoder_args("in.mov", 720, 576, "yuv420p", Some(25.0), Some(10), Some(19), None, 0.0, None, None);
        // Seek before -i, to the midpoint before the start frame.
        let ss = pos(&args, "-ss").unwrap();
        assert!(ss < pos(&args, "-i").unwrap());
        assert_eq!(args[ss + 1], "0.380000");
        let fv = pos(&args, "-frames:v").unwrap();
        assert_eq!(args[fv + 1], "10");
        assert_eq!(args.last().unwrap(), "pipe:1");

        let untrimmed = encode_args();
        assert!(pos(&untrimmed, "-ss").is_none());
        assert_eq!(untrimmed[pos(&untrimmed, "-frames:v").unwrap() + 1], "100");
    }

    #[test]
    fn preview_decoder_writes_the_raw_file() {
        let args = preview_args();
        assert_eq!(args[0], "-ss");
        assert_eq!(args[pos(&args, "-frames:v").unwrap() + 1], "11");
        assert_eq!(args.last().unwrap(), "frames.raw");
    }

    #[test]
    fn timeline_decoder_passes_stored_frames_through() {
        // Without passthrough ffmpeg repeats a frame into every gap, and the
        // script's slot map no longer describes the stream (issue #137).
        let args = timeline_args();
        let fm = pos(&args, "-fps_mode").unwrap();
        assert_eq!(args[fm + 1], "passthrough");
        assert!(fm > pos(&args, "-i").unwrap(), "-fps_mode is an output option");
        assert_eq!(args[pos(&args, "-frames:v").unwrap() + 1], "9");
        let ss = pos(&args, "-ss").unwrap();
        assert!(ss < pos(&args, "-i").unwrap());
        assert_eq!(args[ss + 1], "1.250000");
        let mut from_start = timeline_window();
        from_start.seek_time = None;
        let args = timeline_decoder_args("in.mov", 720, 576, "yuv420p", &from_start, "pipe:1", None, None);
        assert!(pos(&args, "-ss").is_none());
    }

    /// Every builder with a tag fix: still one `-vf`, the fix ahead of the size
    /// guard (the conversion happens after the chain, so the tags must already
    /// be cleared), and an output option.
    #[test]
    fn decoders_clear_invalid_colour_tags_first() {
        let fix = Some("setparams=color_primaries=unknown:color_trc=unknown");
        let all = [
            ("encode", encode_decoder_args("in.mov", 720, 576, "yuv444p12le", Some(25.0), Some(10), Some(19), None, 0.0, fix, None)),
            ("preview", preview_decoder_args("in.mov", Some(0.38), 11, 720, 576, "yuv444p12le", "frames.raw", 0.0, fix, None)),
            ("timeline", timeline_decoder_args("in.mov", 720, 576, "yuv444p12le", &timeline_window(), "pipe:1", fix, None)),
        ];
        for (path, args) in all {
            assert_eq!(args.iter().filter(|a| *a == "-vf").count(), 1, "{path}");
            let vf = pos(&args, "-vf").unwrap();
            assert!(vf > pos(&args, "-i").unwrap(), "{path}");
            // The encode and preview seek, so the PTS reset (issue #157) sits
            // between the fix and the guard; the timeline decoder keeps
            // passthrough timing and has none.
            let reset = if path == "timeline" { String::new() } else { format!("{RESET_PTS_FILTER},") };
            assert_eq!(
                args[vf + 1],
                format!(
                    "setparams=color_primaries=unknown:color_trc=unknown,{reset}{}",
                    size_guard_filter(720, 576)
                ),
                "{path}"
            );
        }
    }

    /// A source with usable tags decodes with exactly the args it always had.
    #[test]
    fn decoders_without_a_tag_fix_are_unchanged() {
        assert_eq!(decoder_filter(720, 576, false, None, None), size_guard_filter(720, 576));
        for (path, args) in both() {
            assert!(!args.iter().any(|a| a.contains("setparams")), "{path}: {args:?}");
        }
    }

    #[test]
    fn guard_failures_are_explained() {
        let stderr = "[Parsed_crop_0 @ 0x6000] Invalid too big or non positive size for width '0' or height '576'\n\
                      [Parsed_crop_0 @ 0x6000] Failed to configure input pad on Parsed_crop_0";
        let msg = explain_decoder_failure(stderr, 720, 576).expect("guard failure recognised");
        assert!(msg.contains("720x576"));
        assert!(explain_decoder_failure("Broken pipe", 720, 576).is_none());
    }

    // --- Rule 5: a video that starts after the container's start -----------

    fn dvbt_probe() -> serde_json::Value {
        // ffprobe's answer for Tests/TestResources/pal-dvbt-fieldcoded-25i.ts;
        // the app's twin (FieldOrderDetector.videoStartFromProbe) reads the
        // same file and must agree.
        let text = include_str!("../../Tests/TestResources/video_start_probe_dvbt.json");
        serde_json::from_str(text).unwrap()
    }

    #[test]
    fn video_start_is_the_first_picture_not_the_first_packet() {
        // The first packet (the I picture) is at 2.722 s, but three leading B
        // pictures are shown from 2.602 s; the container (the audio) starts
        // at 1.400 s.
        let offset = video_start_from_probe(&dvbt_probe());
        assert!((offset - 1.202022).abs() < 1e-6, "{offset}");
    }

    #[test]
    fn video_start_is_zero_unless_the_video_starts_later() {
        let probe = |start: &str, pts: &[&str]| {
            serde_json::json!({
                "packets": pts.iter().map(|p| serde_json::json!({ "pts_time": p })).collect::<Vec<_>>(),
                "format": { "start_time": start },
            })
        };
        // Streams start together, or the video starts first.
        assert_eq!(video_start_from_probe(&probe("0.000000", &["0.000000", "0.040000"])), 0.0);
        assert_eq!(video_start_from_probe(&probe("1.400000", &["1.400000"])), 0.0);
        // Anything missing means no gap: today's behaviour.
        assert_eq!(video_start_from_probe(&serde_json::json!({})), 0.0);
        assert_eq!(video_start_from_probe(&probe("N/A", &["1.0"])), 0.0);
        assert_eq!(video_start_from_probe(&probe("0.0", &[])), 0.0);
        // Video 1 s in: the smallest PTS, wherever it sits in the file.
        let o = video_start_from_probe(&probe("0.000000", &["1.080000", "1.000000", "1.040000"]));
        assert!((o - 1.0).abs() < 1e-9);
    }

    #[test]
    fn packets_without_a_pts_fall_back_to_the_stream_start() {
        // MPEG-2 in AVI: the first two packets have no PTS, so the smallest
        // listed one (0.067) is the third picture's; the stream starts at 0.
        let json = serde_json::json!({
            "packets": [{ "pts_time": "N/A" }, {}, { "pts_time": "0.066733" }, { "pts_time": "0.100100" }],
            "streams": [{ "start_time": "0.000000" }],
            "format": { "start_time": "0.000000" },
        });
        assert_eq!(video_start_from_probe(&json), 0.0);
        // The stream's start alone, when no packet has a PTS.
        let json = serde_json::json!({
            "packets": [{}],
            "streams": [{ "start_time": "1.5" }],
            "format": { "start_time": "0.5" },
        });
        assert!((video_start_from_probe(&json) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn the_probe_reads_as_many_packets_as_it_says() {
        assert!(VIDEO_START_PROBE_ARGS.contains(&format!("%+#{VIDEO_START_PACKETS}").as_str()));
    }

    #[test]
    fn seek_time_adds_the_video_start_and_frame_zero_never_seeks() {
        // With no offset it is exactly the old (N - 0.5) / fps.
        for n in [1i64, 10, 41, 1000] {
            assert_eq!(seek_time(n, 25.0, 0.0), Some((n as f64 - 0.5) / 25.0));
        }
        assert_eq!(seek_time(0, 25.0, 0.0), None);
        assert_eq!(seek_time(0, 25.0, 1.322), None, "frame 0 resets PTS instead");
        assert_eq!(seek_time(-3, 25.0, 1.0), None);
        let t = seek_time(40, 25.0, 1.202022).unwrap();
        assert!((t - (39.5 / 25.0 + 1.202022)).abs() < 1e-9);
    }

    #[test]
    fn a_late_video_resets_pts_even_without_a_seek() {
        // Untrimmed: no -ss (a TS seek can land a GOP late), one -vf, reset first.
        let untrimmed =
            encode_decoder_args("in.ts", 720, 576, "yuv420p", Some(25.0), None, None, Some(100), 1.2, None, None);
        let preview_at_zero =
            preview_decoder_args("in.ts", None, 4, 720, 576, "yuv420p", "frames.raw", 1.2, None, None);
        for (path, args) in [("untrimmed", untrimmed), ("preview at 0", preview_at_zero)] {
            assert!(pos(&args, "-ss").is_none(), "{path}: {args:?}");
            assert_eq!(vf(&args), format!("{},{}", RESET_PTS_FILTER, size_guard_filter(720, 576)), "{path}");
            assert_eq!(args.iter().filter(|a| *a == "-vf").count(), 1, "{path}");
        }
        // Trimmed: the seek carries the offset.
        let trimmed =
            encode_decoder_args("in.ts", 720, 576, "yuv420p", Some(25.0), Some(40), Some(49), None, 1.2, None, None);
        let ss = pos(&trimmed, "-ss").unwrap();
        assert_eq!(trimmed[ss + 1], format!("{:.6}", 39.5 / 25.0 + 1.2));
    }

    #[test]
    fn no_offset_leaves_every_decoder_exactly_as_before() {
        // Pinned in full: a source whose streams start together decodes with
        // the arguments it always had.
        assert_eq!(
            encode_args(),
            [
                "-apply_cropping", "codec", "-i", "in.mov", "-map", "0:v:0", "-vf",
                &size_guard_filter(720, 576), "-f", "rawvideo", "-pix_fmt", "yuv422p10le",
                "-v", "error", "-frames:v", "100", "pipe:1",
            ]
        );
        assert_eq!(
            encode_decoder_args("in.mov", 720, 576, "yuv420p", Some(25.0), Some(10), Some(19), None, 0.0, None, None)[..2],
            ["-ss".to_string(), format!("{:.6}", 9.5 / 25.0)]
        );
    }

    // --- Rule 6: MPEG-TS/PS seek a GOP early (issue #169) -------------------

    fn dvbt_seek_probe() -> serde_json::Value {
        // ffprobe's answer to SEEK_PROBE_ARGS for
        // Tests/TestResources/pal-dvbt-fieldcoded-25i.ts (empty side_data_list
        // entries dropped). The app's twin (FieldOrderDetector.seekPlanFromProbe)
        // reads the same file and must agree.
        let text = include_str!("../../Tests/TestResources/seek_probe_dvbt.json");
        serde_json::from_str(text).unwrap()
    }

    fn plan() -> SeekPlan {
        SeekPlan { preroll: 1.82, container_start: 1.4 }
    }

    #[test]
    fn the_dvbt_plan_is_one_gop_plus_reorder_plus_margin() {
        // Keyframes every 1.12 s (28 frames, field-coded), PTS up to 0.2 s
        // after DTS, container (the audio) from 1.4 s.
        let p = seek_plan_from_probe(&dvbt_seek_probe()).expect("an mpegts plan");
        assert!((p.preroll - (1.12 + 0.2 + SEEK_PREROLL_MARGIN)).abs() < 1e-6, "{p:?}");
        assert!((p.container_start - 1.4).abs() < 1e-9, "{p:?}");
    }

    fn probe_of(format: &str, start: &str, packets: &[(&str, &str, &str)]) -> serde_json::Value {
        serde_json::json!({
            "packets": packets.iter().map(|(pts, dts, flags)| serde_json::json!({
                "pts_time": pts, "dts_time": dts, "flags": flags,
            })).collect::<Vec<_>>(),
            "format": { "format_name": format, "start_time": start },
        })
    }

    #[test]
    fn only_timestamp_searched_formats_get_a_plan() {
        let pk = [("0.0", "0.0", "K__"), ("0.48", "0.48", "K__")];
        for f in ["mpegts", "mpeg"] {
            assert!(seek_plan_from_probe(&probe_of(f, "0.5", &pk)).is_some(), "{f}");
        }
        // Indexed containers, and raw elementary streams (not a fix for them).
        for f in ["mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm", "avi", "mpegvideo", "h264", "mpegtsraw"] {
            assert!(seek_plan_from_probe(&probe_of(f, "0.0", &pk)).is_none(), "{f}");
        }
        assert!(seek_plan_from_probe(&serde_json::json!({})).is_none());
    }

    #[test]
    fn the_preroll_has_a_floor_and_a_fallback() {
        // A DVD's 12-frame GOP (0.48 s), no reorder in the window: the floor.
        let p = seek_plan_from_probe(&probe_of("mpeg", "0.53", &[
            ("0.54", "0.54", "K_"), ("0.58", "0.58", "__"), ("1.02", "1.02", "K_"),
        ])).unwrap();
        assert_eq!(p.preroll, SEEK_PREROLL_MIN);
        // One keyframe in the whole window: the GOP is at least the window.
        let p = seek_plan_from_probe(&probe_of("mpegts", "1.4", &[("1.5", "1.4", "K_"), ("1.54", "1.44", "__")])).unwrap();
        assert!((p.preroll - (SEEK_PROBE_SECONDS as f64 + 0.1 + SEEK_PREROLL_MARGIN)).abs() < 1e-9, "{p:?}");
        // No start time: timestamps count from 0.
        let p = seek_plan_from_probe(&probe_of("mpegts", "N/A", &[])).unwrap();
        assert_eq!(p.container_start, 0.0);
    }

    #[test]
    fn the_seek_probe_reads_the_window_it_says() {
        assert!(SEEK_PROBE_ARGS.contains(&format!("%+{SEEK_PROBE_SECONDS}").as_str()));
    }

    #[test]
    fn decoder_seek_without_a_plan_is_the_plain_seek() {
        assert_eq!(decoder_seek(Some(1.58), None), DecoderSeek { ss: Some(1.58), trim_from: None });
        assert_eq!(decoder_seek(None, None), DecoderSeek::default());
        assert_eq!(decoder_seek(None, Some(&plan())), DecoderSeek::default(), "frame 0 never seeks");
        // An invalid plan is no plan.
        let bad = SeekPlan { preroll: f64::NAN, container_start: 0.0 };
        assert_eq!(decoder_seek(Some(1.58), Some(&bad)), DecoderSeek { ss: Some(1.58), trim_from: None });
    }

    #[test]
    fn decoder_seek_with_a_plan_seeks_early_and_trims_absolutely() {
        let d = decoder_seek(Some(4.0), Some(&plan()));
        assert!((d.ss.unwrap() - 2.18).abs() < 1e-9);
        assert!((d.trim_from.unwrap() - 5.4).abs() < 1e-9);
        // Within the preroll of the start: no -ss, still the trim.
        let d = decoder_seek(Some(1.25), Some(&plan()));
        assert_eq!(d.ss, None);
        assert!((d.trim_from.unwrap() - 2.65).abs() < 1e-9);
        assert!(d.seeks());
    }

    #[test]
    fn planned_decoders_copy_timestamps_seek_early_and_trim_before_the_reset() {
        let p = plan();
        let target = 39.5 / 25.0 + 1.2;
        let all = [
            ("encode", encode_decoder_args("in.ts", 720, 576, "yuv420p", Some(25.0), Some(40), Some(49), None, 1.2, None, Some(&p))),
            ("preview", preview_decoder_args("in.ts", Some(target), 11, 720, 576, "yuv420p", "frames.raw", 1.2, None, Some(&p))),
            ("timeline", timeline_decoder_args("in.ts", 720, 576, "yuv420p",
                &crate::source_timing::TimelineWindow { src_count: 9, seek_time: Some(target), slots: Vec::new() },
                "pipe:1", None, Some(&p))),
        ];
        for (path, args) in all {
            let i = pos(&args, "-i").unwrap();
            let c = pos(&args, "-copyts").unwrap_or_else(|| panic!("{path}: no -copyts {args:?}"));
            let ss = pos(&args, "-ss").unwrap();
            assert!(c < i && ss < i, "{path}: input options after -i");
            assert_eq!(args[ss + 1], format!("{:.6}", target - 1.82), "{path}");
            assert_eq!(
                vf(&args),
                format!("trim=start={:.6},{},{}", 1.4 + target, RESET_PTS_FILTER, size_guard_filter(720, 576)),
                "{path}"
            );
            assert_eq!(args.iter().filter(|a| *a == "-vf").count(), 1, "{path}");
        }
        // The tag fix still goes first.
        let args = preview_decoder_args("in.ts", Some(target), 1, 720, 576, "yuv420p", "f.raw", 1.2, Some("setparams=colorspace=unknown"), Some(&p));
        assert!(vf(&args).starts_with("setparams=colorspace=unknown,trim=start="), "{args:?}");
    }

    #[test]
    fn a_plan_leaves_frame_zero_and_untrimmed_decodes_alone() {
        let p = plan();
        let untrimmed = encode_decoder_args("in.ts", 720, 576, "yuv420p", Some(25.0), None, None, Some(100), 1.2, None, Some(&p));
        let at_zero = preview_decoder_args("in.ts", None, 4, 720, 576, "yuv420p", "frames.raw", 1.2, None, Some(&p));
        for (path, args) in [("untrimmed", untrimmed), ("preview at 0", at_zero)] {
            assert!(pos(&args, "-ss").is_none() && pos(&args, "-copyts").is_none(), "{path}: {args:?}");
            assert_eq!(vf(&args), format!("{},{}", RESET_PTS_FILTER, size_guard_filter(720, 576)), "{path}");
        }
    }

    #[test]
    fn a_plan_round_trips_as_camel_case() {
        let v = serde_json::to_value(plan()).unwrap();
        assert_eq!(v, serde_json::json!({ "preroll": 1.82, "containerStart": 1.4 }));
        assert_eq!(serde_json::from_value::<SeekPlan>(v).unwrap(), plan());
    }
}
