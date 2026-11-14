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
//! 7. **An AVI lands on frame N too** (issue #173). Three faults, one fix
//!    each, all in [`source_seek`] and [`seek_arg`]:
//!    - AVI stores decode-order timestamps only. With a decoder delay
//!      (MPEG-2, MPEG-4 ASP, H.264 with B-frames) ffmpeg stamps display
//!      picture *k* as *k + D*, so a seek landed D frames early. The worker
//!      measures D ([`decoder_delay_from_probe`], only for a source whose
//!      packets carry no PTS) and every seek adds it. Seeks only: the
//!      untrimmed encode was already right, and the sound is not moved.
//!    - An AVI's tick is one frame, so `(N - 0.5) / fps` sits exactly on half
//!      a tick; printed to the nearest microsecond it often fell below the
//!      half and the trim rounded to N - 1 (one start in three on every
//!      NTSC-rate AVI, B-frames or not). Every seek value is rounded *up*.
//!    - ffmpeg starts a seek 3/23 s early for a delayed stream, and an AVI
//!      cannot seek before its start: frames 1-3 jumped ~1.5 s ("could not
//!      seek"). Below [`COUNT_SEEK_BELOW`] a delayed source decodes from the
//!      start and drops the first N pictures by count (`trim=start_frame`).
//!
//! 8. **Every constant-rate decoder places the frames on the source's grid**
//!    (issue #174). Frame N is slot N of the grid at the job's rate (the
//!    stream's exact fraction) from the video's first picture; each slot shows
//!    the stored frame its timestamp puts there, so a null frame or a pulldown
//!    repeat is a slot showing the frame before it. `rawvideo`'s own
//!    constant-rate output did not: it gave a first frame with a repeat flag
//!    extra slots (`soft_telecine_test.mkv`: 122 for 120, every frame two
//!    late) and rounded a gap's edge differently, and a seek into a null run or
//!    onto a pulldown repeat kept the stored frame *after* it. So the decoder
//!    copies timestamps, seeks [`GRID_LOOKBACK_SLOTS`] early (and a
//!    [`SeekPlan`]'s preroll more), and runs [`SourceGrid::filters`]: `setpts`
//!    to the first picture (the same constant in every decoder, so the `fps`
//!    filter rounds identically in all of them), `fps`, `trim=start_pts=N`, the
//!    reset. [`decode_start`] is the one decision. A source whose packets lack
//!    PTS (rule 7's AVIs) has no grid and keeps rules 3-7.
//!
//! 9. **The sound of a delayed AVI cannot be seeked near its start either.**
//!    ffmpeg's early start applies when any stream has a delay, so an input
//!    `-ss` on the sound below [`COUNT_SEEK_BELOW`] fails the same way and
//!    loses ~1.3 s of sound. [`sound_seek`] is the one decision: decodes of
//!    the sound skip after decoding instead (Audio Restoration's render with
//!    an `atrim`, its analysis and transcription with an output-side `-ss`),
//!    and the stream-copy encode seeks a NUT copy of the sound
//!    (`audio_restoration::needs_sound_sidecar`).
//!
//! See docs/ENGINEERING_NOTES.md, "Clean aperture: decode the stored frame",
//! docs/reports/issue-157-seek-alignment, docs/reports/issue-169-mpeg-seek,
//! docs/reports/issue-173-avi-seek, docs/reports/issue-174-source-grid,
//! docs/reports/2026-11-avi-audio-seek and
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
    seek: &DecoderSeek,
) -> String {
    let mut chain: Vec<String> = Vec::new();
    if let Some(fix) = tag_fix {
        chain.push(fix.to_string());
    }
    let trim = seek.trim();
    if let Some(t) = &trim {
        chain.push(t.clone());
    }
    if seeks || trim.is_some() {
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
    "-show_entries", "packet=pts_time:stream=start_time,r_frame_rate,avg_frame_rate:format=start_time",
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
    probe_json(ffprobe, env, &VIDEO_START_PROBE_ARGS, input).map(|j| video_start_from_probe(&j))
}

/// ffprobe's JSON answer to `args` for a file, `None` on any failure.
pub fn probe_json(
    ffprobe: &std::path::Path,
    env: &std::collections::HashMap<String, String>,
    args: &[&str],
    input: &str,
) -> Option<serde_json::Value> {
    let out = std::process::Command::new(ffprobe)
        .args(args)
        .arg(input)
        .envs(env)
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

/// Whether the source stores its pictures with decode-order timestamps only
/// (rule 7): some of the first packets [`VIDEO_START_PROBE_ARGS`] lists carry
/// no PTS. AVI does this for any codec with a decoder delay (MPEG-2, MPEG-4
/// ASP, H.264 with B-frames); no MP4, MOV, MKV or TS fixture does. Only then
/// is [`DECODER_DELAY_PROBE_ARGS`] worth a decode.
pub fn stores_decode_order(json: &serde_json::Value) -> bool {
    json.get("packets")
        .and_then(|p| p.as_array())
        .is_some_and(|packets| packets.iter().any(|p| p.get("pts_time").is_none()))
}

/// ffprobe's arguments (before the input) for [`decoder_delay_from_probe`]:
/// decodes the first few packets. The app runs the same
/// (`FieldOrderDetector.decoderDelayProbeArgs`).
pub const DECODER_DELAY_PROBE_ARGS: [&str; 10] = [
    "-v", "error",
    "-select_streams", "v:0",
    "-show_entries", "frame=best_effort_timestamp_time:stream=r_frame_rate:format=start_time",
    "-read_intervals", "%+#16",
    "-of", "json",
];

/// The largest decoder delay believed (H.264 in AVI measures 2).
pub const MAX_DECODER_DELAY: u32 = 4;

/// How many frames late the decoder stamps every picture of a source that
/// stores decode-order timestamps (rule 7): the first decoded picture's
/// timestamp, less the container start and the video start offset, in whole
/// frames of the stream's `r_frame_rate` (an AVI's one-frame tick). Whole
/// frames because ffprobe prints six decimals, which would reopen the
/// rounding tie [`seek_arg`] closes. 0 unless it is 1..=[`MAX_DECODER_DELAY`].
///
/// `json` is ffprobe's output for [`DECODER_DELAY_PROBE_ARGS`].
pub fn decoder_delay_from_probe(json: &serde_json::Value, video_start: f64) -> u32 {
    let num = |v: Option<&serde_json::Value>| {
        v.and_then(|s| s.as_str()).and_then(|s| s.parse::<f64>().ok()).filter(|t| t.is_finite())
    };
    let rate = json
        .get("streams")
        .and_then(|s| s.as_array())
        .and_then(|s| s.first())
        .and_then(|s| s.get("r_frame_rate"))
        .and_then(|r| r.as_str())
        .and_then(|r| {
            let (n, d) = r.split_once('/')?;
            let (n, d) = (n.parse::<f64>().ok()?, d.parse::<f64>().ok()?);
            (n > 0.0 && d > 0.0).then(|| n / d)
        });
    let first = json
        .get("frames")
        .and_then(|f| f.as_array())
        .and_then(|f| f.first())
        .and_then(|f| num(f.get("best_effort_timestamp_time")));
    let (Some(rate), Some(first)) = (rate, first) else { return 0 };
    let container = num(json.get("format").and_then(|f| f.get("start_time"))).unwrap_or(0.0);
    let frames = ((first - container - video_start.max(0.0)) * rate).round();
    if frames >= 1.0 && frames <= MAX_DECODER_DELAY as f64 {
        frames as u32
    } else {
        0
    }
}

/// [`video_start_from_probe`] and, for a source that [`stores_decode_order`],
/// [`decoder_delay_from_probe`], for a file. `None` when ffprobe could not
/// read it (offset and delay then count as 0, the old behaviour).
pub fn probe_video_timing(
    ffprobe: &std::path::Path,
    env: &std::collections::HashMap<String, String>,
    input: &str,
) -> Option<(f64, u32)> {
    let json = probe_json(ffprobe, env, &VIDEO_START_PROBE_ARGS, input)?;
    let offset = video_start_from_probe(&json);
    let delay = if stores_decode_order(&json) {
        probe_json(ffprobe, env, &DECODER_DELAY_PROBE_ARGS, input)
            .map_or(0, |j| decoder_delay_from_probe(&j, offset))
    } else {
        0
    };
    Some((offset, delay))
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
    format!("trim=start={}", seek_arg(t))
}

/// The `trim` that drops the first `frame` decoded pictures (rule 7: a
/// delayed AVI's seeks near the start count instead of seeking).
pub fn trim_frames_filter(frame: i64) -> String {
    format!("trim=start_frame={}", frame)
}

/// A seek time as ffmpeg takes it (`-ss`, `trim=start=`): seconds to the
/// microsecond, rounded **up** (rule 7). ffmpeg parses the value to whole
/// microseconds and then rounds it to the stream's nearest tick. In an AVI one
/// tick is one frame, so `(N - 0.5) / fps` falls exactly on half a tick; to
/// the nearest microsecond it often printed just *below* the half and the trim
/// started a frame early (1 start in 3 on every NTSC-rate AVI). Rounded up it
/// is never below the half, and an exact half rounds up in ffmpeg. The 1 ns
/// allowance stops a value that is already whole microseconds (0.38 s, held
/// as 380000.00000000006 us) from gaining one.
pub fn seek_arg(t: f64) -> String {
    format!("{:.6}", (t * 1e6 - 1e-3).ceil() / 1e6)
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

/// What one decoder does to start at a target: its `-ss` (if any), under a
/// [`SeekPlan`] the absolute time `trim` drops to (`-copyts` with it), or, for
/// a delayed AVI near its start (rule 7), the number of decoded pictures to
/// drop with no seek at all.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct DecoderSeek {
    pub ss: Option<f64>,
    pub trim_from: Option<f64>,
    pub trim_frames: Option<i64>,
    /// Rebase PTS even when not seeking (rule 7): a delayed source's first
    /// picture is stamped D frames in, and `rawvideo`'s constant-rate output
    /// filled that gap with copies of it (H.264 in AVI, D = 2: frame 0 three
    /// times, untrimmed encode included).
    pub rebase: bool,
}

impl DecoderSeek {
    /// Whether the decoder starts anywhere but the beginning.
    pub fn seeks(&self) -> bool {
        self.ss.is_some() || self.trim_from.is_some() || self.trim_frames.is_some()
    }

    /// The `trim` filter this seek needs in the decoder's one `-vf`, if any.
    pub fn trim(&self) -> Option<String> {
        self.trim_from
            .map(trim_filter)
            .or_else(|| self.trim_frames.map(trim_frames_filter))
    }

    /// The `-copyts`/`-ss` input options, in order, before `-i`.
    fn input_args(&self) -> Vec<String> {
        let mut args = Vec::new();
        if self.trim_from.is_some() {
            args.push("-copyts".to_string());
        }
        if let Some(t) = self.ss {
            args.push("-ss".to_string());
            args.push(seek_arg(t));
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
        None => DecoderSeek { ss: Some(t), ..DecoderSeek::default() },
        Some(p) => {
            let early = t - p.preroll;
            DecoderSeek {
                ss: (early > 0.0).then_some(early),
                trim_from: Some(p.container_start + t),
                trim_frames: None,
                rebase: false,
            }
        }
    }
}

/// Below this seek time a delayed AVI decodes from the start and drops
/// pictures by count (rule 7). ffmpeg starts such a seek 3/23 s early, and
/// below that the AVI demuxer cannot seek at all; half a second leaves a
/// margin at any rate, for at most a few frames more of decoding.
pub const COUNT_SEEK_BELOW: f64 = 0.5;

/// The one decision for every decoder that starts at source frame `frame`
/// (encode, preview, detectors): [`seek_time`] moved by the decoder delay of
/// an AVI that stores decode-order timestamps ([`decoder_delay_from_probe`],
/// rule 7), through [`decoder_seek`] for an MPEG-TS/PS plan (rule 6). A
/// source with a plan never takes a delay (no TS/PS stores packets without
/// PTS, and the plan trims by its own timestamps), and a delayed source near
/// its start counts pictures instead of seeking. With no delay this is
/// exactly `decoder_seek(seek_time(..), plan)`.
pub fn source_seek(
    frame: i64,
    fps: f64,
    video_start: f64,
    delay_frames: u32,
    plan: Option<&SeekPlan>,
) -> DecoderSeek {
    let plan = plan.filter(|p| p.is_valid());
    let delay = if plan.is_some() { 0 } else { delay_frames.min(MAX_DECODER_DELAY) as i64 };
    let rebase = delay > 0;
    if frame <= 0 {
        return DecoderSeek { rebase, ..DecoderSeek::default() };
    }
    let target = seek_time(frame + delay, fps, video_start);
    if delay > 0 && target.is_some_and(|t| t < COUNT_SEEK_BELOW) {
        return DecoderSeek { trim_frames: Some(frame), rebase, ..DecoderSeek::default() };
    }
    DecoderSeek { rebase, ..decoder_seek(target, plan) }
}

/// Slots a decoder that starts at frame N begins decoding before it (rule 8),
/// so a slot inside a run of null frames, or a pulldown repeat, is reached
/// from the stored frame it repeats. Measured: a 4-slot leading null run and
/// a 5-frame mid-stream one are exact from every start with 8.
pub const GRID_LOOKBACK_SLOTS: i64 = 8;

/// Relative difference below which the stream's own rate is taken as the
/// job's: the app sends a decimal (29.97), the stream knows the fraction
/// (`2997/100` is not `30000/1001`; a grid at the wrong one drops or repeats
/// a frame every few hours).
pub const GRID_RATE_TOLERANCE: f64 = 0.001;

/// The constant-rate grid a source's frames are placed on (rule 8): the job's
/// rate as the stream's exact fraction, from the video's first picture.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceGrid {
    pub rate_num: u32,
    pub rate_den: u32,
    /// The first picture's presentation time in the file's own timestamps
    /// (what `-copyts` keeps), seconds. Slot `n` is at `origin + n / rate`.
    pub origin: f64,
}

impl SourceGrid {
    /// Whether the grid is usable.
    pub fn is_valid(&self) -> bool {
        self.rate_num > 0 && self.rate_den > 0 && self.origin.is_finite()
    }

    /// The rate in frames per second.
    pub fn fps(&self) -> f64 {
        self.rate_num as f64 / self.rate_den as f64
    }

    /// [`Self::filters`] from slot 0 for a decode that does not keep the
    /// file's timestamps (frame 0 of a TS/PS, see [`DecodeStart`]): the first
    /// picture is the origin there too, so `STARTPTS` takes the constant's
    /// place and the ticks after it are the same.
    pub fn filters_from_first_picture(&self) -> Vec<String> {
        let mut f = self.filters(0);
        f[0] = RESET_PTS_FILTER.to_string();
        f
    }

    /// The filters that place the decoded frames on the grid and keep slots
    /// `first..`: timestamps relative to the first picture (the same constant
    /// in every decoder, so the `fps` filter rounds identically in all of
    /// them), the grid, the drop to slot `first` and the PTS reset that
    /// `rawvideo`'s constant-rate output needs (rule 3).
    pub fn filters(&self, first: i64) -> Vec<String> {
        vec![
            format!("setpts=PTS-{:.6}/TB", self.origin),
            format!("fps={}/{}", self.rate_num, self.rate_den),
            format!("trim=start_pts={}", first.max(0)),
            RESET_PTS_FILTER.to_string(),
        ]
    }
}

fn parse_rate(v: Option<&serde_json::Value>) -> Option<(u64, u64)> {
    let (n, d) = v?.as_str()?.trim().split_once('/')?;
    let (n, d) = (n.parse::<u64>().ok()?, d.parse::<u64>().ok()?);
    (n > 0 && d > 0).then_some((n, d))
}

/// The [`SourceGrid`] for a source, from ffprobe's answer to
/// [`VIDEO_START_PROBE_ARGS`], at `job_fps` (the rate the app sends and the
/// script declares). `None`, and the decoders keep their old arguments, when
/// any probed packet has no PTS: MPEG-2 in AVI stores some without one, so
/// its pictures' times are guesses a grid can't be placed on (issue #15's
/// territory), or when the probe says nothing usable.
///
/// The rate is `FieldOrderDetector.selectFrameRate`'s choice (avg when r is
/// about twice it, the field-coded case, else r) as an exact fraction, taken
/// only when it is within [`GRID_RATE_TOLERANCE`] of `job_fps`; otherwise
/// `job_fps` itself. The origin is the first picture: the earlier of the
/// stream's start and its packets' PTS, never before the container's start
/// (an MP4 edit list's discarded pre-roll), as in [`video_start_from_probe`].
pub fn grid_from_probe(json: &serde_json::Value, job_fps: f64) -> Option<SourceGrid> {
    let num = |v: Option<&serde_json::Value>| {
        v.and_then(|s| s.as_str()).and_then(|s| s.parse::<f64>().ok()).filter(|t| t.is_finite())
    };
    let packets = json.get("packets")?.as_array()?;
    if packets.is_empty() {
        return None;
    }
    let mut first = f64::INFINITY;
    for p in packets {
        first = first.min(num(p.get("pts_time"))?);
    }
    let stream = json.get("streams").and_then(|s| s.as_array()).and_then(|s| s.first());
    if let Some(start) = num(stream.and_then(|s| s.get("start_time"))) {
        first = first.min(start);
    }
    let container = num(json.get("format").and_then(|f| f.get("start_time")));
    let origin = match container {
        Some(c) => first.max(c),
        None => first,
    };

    let r = parse_rate(stream.and_then(|s| s.get("r_frame_rate")));
    let avg = parse_rate(stream.and_then(|s| s.get("avg_frame_rate")));
    let stream_rate = match (r, avg) {
        (Some(r), Some(a)) => {
            let ratio = (r.0 * a.1) as f64 / (r.1 * a.0) as f64;
            if ratio > 1.8 && ratio < 2.2 { Some(a) } else { Some(r) }
        }
        (r, a) => r.or(a),
    };
    let rate = match stream_rate {
        Some((n, d))
            if job_fps <= 0.0
                || ((n as f64 / d as f64 - job_fps) / job_fps).abs() <= GRID_RATE_TOLERANCE =>
        {
            (n, d)
        }
        _ if job_fps > 0.0 => {
            let (n, d) = crate::models::fps_to_rational(job_fps);
            (n.max(1) as u64, d.max(1) as u64)
        }
        _ => return None,
    };
    let grid = SourceGrid {
        rate_num: u32::try_from(rate.0).ok()?,
        rate_den: u32::try_from(rate.1).ok()?,
        origin,
    };
    grid.is_valid().then_some(grid)
}

/// [`grid_from_probe`] for a file, or `None` (no grid: today's decode).
pub fn probe_source_grid(
    ffprobe: &std::path::Path,
    env: &std::collections::HashMap<String, String>,
    input: &str,
    job_fps: f64,
) -> Option<SourceGrid> {
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
    grid_from_probe(&json, job_fps)
}

/// How one constant-rate decoder starts at source frame `frame`: its input
/// options and the filters ahead of the size guard. The one decision every
/// such decoder (encode, preview, detectors) takes its start from.
///
/// With a [`SourceGrid`] (rule 8): `-copyts`, a seek [`GRID_LOOKBACK_SLOTS`]
/// before the frame (and a [`SeekPlan`]'s preroll before that, on TS/PS),
/// then [`SourceGrid::filters`] down to slot `frame`. Without one, exactly
/// the arguments of rules 3, 5, 6 and 7 ([`source_seek`]).
///
/// Frame 0 of a source with a [`SeekPlan`] (MPEG-TS/PS) runs without
/// `-copyts` ([`SourceGrid::filters_from_first_picture`]). `-copyts` switches
/// off ffmpeg's timestamp discontinuity correction, and on a program stream
/// whose clock resets (a DVD title's cells written back to back, a spliced
/// broadcast capture) the grid's `fps` drops every picture after a backward
/// reset: an untrimmed encode stopped there and `pipe_source` froze the last
/// frame for the rest (review: 150 of 300 pictures). Measured identical to the
/// `-copyts` grid on every TS/PS fixture. A decode that seeks there already
/// runs `-copyts` (rule 6) and still stops at such a reset.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct DecodeStart {
    pub ss: Option<f64>,
    pub copyts: bool,
    pub filters: Vec<String>,
    /// Without a grid, the seek of rules 3-7 these were built from (for the
    /// preview's log line); `None` on a grid.
    pub seek: Option<DecoderSeek>,
}

impl DecodeStart {
    /// The start of a decoder with no grid: exactly the `-ss`, trim and
    /// reset of rules 3, 5, 6 and 7 for `seek`.
    pub fn from_seek(seek: DecoderSeek, video_start: f64) -> Self {
        let mut filters = Vec::new();
        let trim = seek.trim();
        if let Some(t) = &trim {
            filters.push(t.clone());
        }
        if resets_pts(seek.seeks() || seek.rebase, video_start) || trim.is_some() {
            filters.push(RESET_PTS_FILTER.to_string());
        }
        DecodeStart { ss: seek.ss, copyts: seek.trim_from.is_some(), filters, seek: Some(seek) }
    }

    /// The `-copyts`/`-ss` input options, in order, before `-i`.
    pub fn input_args(&self) -> Vec<String> {
        let mut args = Vec::new();
        if self.copyts {
            args.push("-copyts".to_string());
        }
        if let Some(t) = self.ss {
            args.push("-ss".to_string());
            args.push(seek_arg(t));
        }
        args
    }

    /// The decoder's one `-vf`: the colour-tag neutraliser, these filters,
    /// the size guard.
    pub fn vf(&self, width: i32, height: i32, tag_fix: Option<&str>) -> String {
        let mut chain: Vec<String> = Vec::new();
        if let Some(fix) = tag_fix {
            chain.push(fix.to_string());
        }
        chain.extend(self.filters.iter().cloned());
        chain.push(size_guard_filter(width, height));
        chain.join(",")
    }
}

/// See [`DecodeStart`]. `fps` is the job's rate and `delay_frames` the
/// AVI decoder delay of rule 7, both used only without a grid.
pub fn decode_start(
    frame: i64,
    fps: f64,
    video_start: f64,
    delay_frames: u32,
    plan: Option<&SeekPlan>,
    grid: Option<&SourceGrid>,
) -> DecodeStart {
    let frame = frame.max(0);
    let plan = plan.filter(|p| p.is_valid());
    match grid.filter(|g| g.is_valid()) {
        Some(g) if frame == 0 && plan.is_some() => DecodeStart {
            ss: None,
            copyts: false,
            filters: g.filters_from_first_picture(),
            seek: None,
        },
        Some(g) => {
            let target = seek_time(frame - GRID_LOOKBACK_SLOTS, g.fps(), video_start);
            let ss = match (target, plan) {
                (Some(t), Some(p)) => Some(t - p.preroll).filter(|s| *s > 0.0),
                (t, None) => t,
                (None, Some(_)) => None,
            };
            DecodeStart { ss, copyts: true, filters: g.filters(frame), seek: None }
        }
        None => DecodeStart::from_seek(
            source_seek(frame, fps, video_start, delay_frames, plan),
            video_start,
        ),
    }
}

/// Rule 9: ffmpeg starts an input seek 3/23 s early when **any** stream of
/// the file has a decoder delay (not only the one being decoded), and a
/// delayed AVI cannot seek before its start, so a seek of its **sound** below
/// that fails too ("could not seek to position") and decoding resumes ~1.4 s
/// in: a trim from frame 2 lost 1.28 s of sound. A decode of a delayed
/// source's sound that starts in `(0, COUNT_SEEK_BELOW)` must therefore not
/// use an input `-ss`. The same threshold as the picture's count seek
/// (rule 7), so both switch at the same point. See
/// docs/reports/2026-11-avi-audio-seek.
pub fn sound_seek_fails(start: f64, delay_frames: u32) -> bool {
    delay_frames > 0 && start > 0.0 && start < COUNT_SEEK_BELOW
}

/// How a decode of the source's sound reaches `start` seconds on the
/// container timeline.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SoundSeek {
    /// From the beginning: no seek at all.
    None,
    /// An input `-ss` (before `-i`), as every source but rule 9's has.
    Input(f64),
    /// Decode from the beginning and drop this many seconds after decoding
    /// (an output-side `-ss`, or an `atrim` in a filter chain).
    Skip(f64),
}

/// The one decision for a decode of the source's sound (rule 9).
pub fn sound_seek(start: f64, delay_frames: u32) -> SoundSeek {
    if !(start.is_finite() && start > 0.0) {
        SoundSeek::None
    } else if sound_seek_fails(start, delay_frames) {
        SoundSeek::Skip(start)
    } else {
        SoundSeek::Input(start)
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
    start: &DecodeStart,
    start_frame: Option<i32>,
    end_frame: Option<i32>,
    total_frames: Option<i32>,
    tag_fix: Option<&str>,
) -> Vec<String> {
    let mut args: Vec<String> = Vec::new();

    // Start at the in-point: `start` is [`decode_start`] for `start_frame`.
    // On the source's grid when it has one (rule 8); otherwise an accurate
    // `-ss` before `-i` with the PTS reset (rule 3), on a TS/PS a preroll and
    // a trim (rule 6), near a delayed AVI's start a trim by count (rule 7). An
    // untrimmed decode of a source with no grid whose streams start together
    // is left exactly as it was.
    args.extend(start.input_args());

    args.extend(APPLY_CROPPING.iter().map(|s| s.to_string()));
    args.extend([
        "-i".to_string(), input_path.to_string(),
        "-map".to_string(), "0:v:0".to_string(), // only first video stream
        "-vf".to_string(), start.vf(width, height, tag_fix),
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
/// from `start` ([`decode_start`] for the window's first frame) into
/// `output_path`. Same cropping, size and seek rules as
/// [`encode_decoder_args`]: a window starting at frame 0 does not seek,
/// exactly like an untrimmed encode, so the two agree on frame 0.
#[allow(clippy::too_many_arguments)]
pub fn preview_decoder_args(
    input_path: &str,
    start: &DecodeStart,
    num_frames: i32,
    width: i32,
    height: i32,
    pix_fmt: &str,
    output_path: &str,
    tag_fix: Option<&str>,
) -> Vec<String> {
    let mut args: Vec<String> = start.input_args();
    args.extend(APPLY_CROPPING.iter().map(|s| s.to_string()));
    args.extend([
        "-i".to_string(), input_path.to_string(),
        "-map".to_string(), "0:v:0".to_string(),
        "-frames:v".to_string(), num_frames.to_string(),
        "-vf".to_string(), start.vf(width, height, tag_fix),
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
        "-vf".to_string(), decoder_filter(width, height, false, tag_fix, &seek),
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
        encode_decoder_args("in.mov", 720, 576, "yuv422p10le", &DecodeStart::from_seek(DecoderSeek::default(), 0.0), None, None, Some(100), None)
    }

    fn preview_args() -> Vec<String> {
        preview_decoder_args("in.mov", &DecodeStart::from_seek(decoder_seek(Some(0.38), None), 0.0), 11, 720, 576, "yuv422p10le", "frames.raw", None)
    }

    /// The seek the worker builds for an encode trimmed at `start`.
    fn test_seek(start: Option<i32>, fps: f64, video_start: f64, plan: Option<&SeekPlan>) -> DecoderSeek {
        source_seek(start.unwrap_or(0) as i64, fps, video_start, 0, plan)
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
            encode_decoder_args("in.mov", 720, 576, "yuv420p", &DecodeStart::from_seek(test_seek(Some(10), 25.0, 0.0, None), 0.0), Some(10), Some(19), None, None);
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
            encode_decoder_args("in.mov", 720, 576, "yuv422p10le", &DecodeStart::from_seek(test_seek(Some(0), 25.0, 0.0, None), 0.0), Some(0), Some(19), None, None);
        let preview_at_zero =
            preview_decoder_args("in.mov", &DecodeStart::from_seek(DecoderSeek::default(), 0.0), 4, 720, 576, "yuv422p10le", "frames.raw", None);
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
        let args = encode_decoder_args("in.mov", 720, 576, "yuv420p", &DecodeStart::from_seek(test_seek(Some(10), 25.0, 0.0, None), 0.0), Some(10), Some(19), None, None);
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
            ("encode", encode_decoder_args("in.mov", 720, 576, "yuv444p12le", &DecodeStart::from_seek(test_seek(Some(10), 25.0, 0.0, None), 0.0), Some(10), Some(19), None, fix)),
            ("preview", preview_decoder_args("in.mov", &DecodeStart::from_seek(decoder_seek(Some(0.38), None), 0.0), 11, 720, 576, "yuv444p12le", "frames.raw", fix)),
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
        assert_eq!(decoder_filter(720, 576, false, None, &DecoderSeek::default()), size_guard_filter(720, 576));
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
            encode_decoder_args("in.ts", 720, 576, "yuv420p", &DecodeStart::from_seek(test_seek(None, 25.0, 1.2, None), 1.2), None, None, Some(100), None);
        let preview_at_zero =
            preview_decoder_args("in.ts", &DecodeStart::from_seek(decoder_seek(None, None), 1.2), 4, 720, 576, "yuv420p", "frames.raw", None);
        for (path, args) in [("untrimmed", untrimmed), ("preview at 0", preview_at_zero)] {
            assert!(pos(&args, "-ss").is_none(), "{path}: {args:?}");
            assert_eq!(vf(&args), format!("{},{}", RESET_PTS_FILTER, size_guard_filter(720, 576)), "{path}");
            assert_eq!(args.iter().filter(|a| *a == "-vf").count(), 1, "{path}");
        }
        // Trimmed: the seek carries the offset.
        let trimmed =
            encode_decoder_args("in.ts", 720, 576, "yuv420p", &DecodeStart::from_seek(test_seek(Some(40), 25.0, 1.2, None), 1.2), Some(40), Some(49), None, None);
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
            encode_decoder_args("in.mov", 720, 576, "yuv420p", &DecodeStart::from_seek(test_seek(Some(10), 25.0, 0.0, None), 0.0), Some(10), Some(19), None, None)[..2],
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
        assert_eq!(decoder_seek(Some(1.58), None), DecoderSeek { ss: Some(1.58), ..DecoderSeek::default() });
        assert_eq!(decoder_seek(None, None), DecoderSeek::default());
        assert_eq!(decoder_seek(None, Some(&plan())), DecoderSeek::default(), "frame 0 never seeks");
        // An invalid plan is no plan.
        let bad = SeekPlan { preroll: f64::NAN, container_start: 0.0 };
        assert_eq!(decoder_seek(Some(1.58), Some(&bad)), DecoderSeek { ss: Some(1.58), ..DecoderSeek::default() });
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
            ("encode", encode_decoder_args("in.ts", 720, 576, "yuv420p", &DecodeStart::from_seek(test_seek(Some(40), 25.0, 1.2, Some(&p)), 1.2), Some(40), Some(49), None, None)),
            ("preview", preview_decoder_args("in.ts", &DecodeStart::from_seek(decoder_seek(Some(target), Some(&p)), 1.2), 11, 720, 576, "yuv420p", "frames.raw", None)),
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
        let args = preview_decoder_args("in.ts", &DecodeStart::from_seek(decoder_seek(Some(target), Some(&p)), 1.2), 1, 720, 576, "yuv420p", "f.raw", Some("setparams=colorspace=unknown"));
        assert!(vf(&args).starts_with("setparams=colorspace=unknown,trim=start="), "{args:?}");
    }

    #[test]
    fn a_plan_leaves_frame_zero_and_untrimmed_decodes_alone() {
        let p = plan();
        let untrimmed = encode_decoder_args("in.ts", 720, 576, "yuv420p", &DecodeStart::from_seek(test_seek(None, 25.0, 1.2, Some(&p)), 1.2), None, None, Some(100), None);
        let at_zero = preview_decoder_args("in.ts", &DecodeStart::from_seek(decoder_seek(None, Some(&p)), 1.2), 4, 720, 576, "yuv420p", "frames.raw", None);
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

    // ---- Issue #173: AVI seeks (rule 7) ----

    fn json(text: &str) -> serde_json::Value {
        serde_json::from_str(text).unwrap()
    }

    #[test]
    fn decode_order_storage_is_recognised_from_the_packet_probe() {
        // hard_telecine_test.avi: 22 of its first 64 packets carry no PTS.
        let avi = json(include_str!("../../Tests/TestResources/video_start_probe_avi.json"));
        assert!(stores_decode_order(&avi));
        assert_eq!(video_start_from_probe(&avi), 0.0, "the AVI's video starts with the file");
        // Every packet of the DVB-T capture has one: no decoding probe for it.
        let ts = json(include_str!("../../Tests/TestResources/video_start_probe_dvbt.json"));
        assert!(!stores_decode_order(&ts));
        assert!(!stores_decode_order(&serde_json::json!({})));
    }

    #[test]
    fn the_mpeg2_avi_decoder_delay_is_one_frame() {
        let probe = json(include_str!("../../Tests/TestResources/decoder_delay_probe_avi.json"));
        assert_eq!(decoder_delay_from_probe(&probe, 0.0), 1);
        // Measured from the video's first picture, not the file's.
        assert_eq!(decoder_delay_from_probe(&probe, 0.033367), 0);
    }

    #[test]
    fn implausible_decoder_delays_are_ignored() {
        let probe = |first: &str, rate: &str| {
            serde_json::json!({
                "frames": [{ "best_effort_timestamp_time": first }],
                "streams": [{ "r_frame_rate": rate }],
                "format": { "start_time": "0.000000" }
            })
        };
        assert_eq!(decoder_delay_from_probe(&probe("0.066733", "30000/1001"), 0.0), 2, "H.264 in AVI");
        assert_eq!(decoder_delay_from_probe(&probe("0.000000", "30000/1001"), 0.0), 0);
        assert_eq!(decoder_delay_from_probe(&probe("0.200000", "25/1"), 0.0), 0, "5 frames: not a delay");
        assert_eq!(decoder_delay_from_probe(&probe("0.040000", "0/0"), 0.0), 0);
        assert_eq!(decoder_delay_from_probe(&serde_json::json!({ "frames": [] }), 0.0), 0);
    }

    /// The shared table (`Tests/TestResources/seek_arg_cases.json`, computed in
    /// exact arithmetic; the Dart twin checks the same rows).
    #[test]
    fn source_seek_matches_the_shared_table() {
        let table = json(include_str!("../../Tests/TestResources/seek_arg_cases.json"));
        let cases = table["cases"].as_array().unwrap();
        assert!(cases.len() > 20);
        for c in cases {
            let frame = c["frame"].as_i64().unwrap();
            let fps = c["fpsNum"].as_f64().unwrap() / c["fpsDen"].as_f64().unwrap();
            let vs = c["videoStart"].as_f64().unwrap();
            let delay = c["delay"].as_u64().unwrap() as u32;
            let seek = source_seek(frame, fps, vs, delay, None);
            assert_eq!(seek.ss.map(seek_arg), c["ss"].as_str().map(String::from), "{c}");
            assert_eq!(seek.trim_frames, c["trimFrames"].as_i64(), "{c}");
            assert_eq!(seek.trim_from, None, "{c}");
        }
    }

    #[test]
    fn seek_values_round_up_to_the_microsecond() {
        // Frame 43 of an NTSC AVI: 42.5 ticks of 1001/30000 is 1.4180833.. s.
        // To the nearest microsecond it printed 1.418083, below the half tick,
        // and the trim began at frame 42.
        let t = seek_time(43, 30000.0 / 1001.0, 0.0).unwrap();
        assert_eq!(format!("{t:.6}"), "1.418083", "the old formatting");
        assert_eq!(seek_arg(t), "1.418084");
        // Whole microseconds are left alone (0.38 is 380000.00000000006 us).
        assert_eq!(seek_arg(0.38), "0.380000");
        assert_eq!(seek_arg(1.58 + 1.202022), "2.782022");
        assert_eq!(trim_filter(0.38), "trim=start=0.380000");
    }

    #[test]
    fn a_delayed_avi_counts_pictures_near_its_start() {
        let seek = source_seek(2, 30000.0 / 1001.0, 0.0, 1, None);
        assert_eq!(seek, DecoderSeek { trim_frames: Some(2), rebase: true, ..DecoderSeek::default() });
        for (path, args) in [
            ("encode", encode_decoder_args("in.avi", 720, 480, "yuv420p", &DecodeStart::from_seek(seek, 0.0), Some(2), Some(13), None, Some("setparams=colorspace=unknown"))),
            ("preview", preview_decoder_args("in.avi", &DecodeStart::from_seek(seek, 0.0), 11, 720, 480, "yuv420p", "f.raw", Some("setparams=colorspace=unknown"))),
        ] {
            assert!(pos(&args, "-ss").is_none(), "{path}: no input seek: {args:?}");
            assert!(pos(&args, "-copyts").is_none(), "{path}");
            assert_eq!(args.iter().filter(|a| *a == "-vf").count(), 1, "{path}");
            // Tag fix first, the count trim, then the reset that rebases after it.
            assert_eq!(
                vf(&args),
                format!(
                    "setparams=colorspace=unknown,trim=start_frame=2,{RESET_PTS_FILTER},{}",
                    size_guard_filter(720, 480)
                ),
                "{path}"
            );
        }
        // -frames:v still counts output frames.
        let enc = encode_decoder_args("in.avi", 720, 480, "yuv420p", &DecodeStart::from_seek(seek, 0.0), Some(2), Some(13), None, None);
        assert_eq!(enc[pos(&enc, "-frames:v").unwrap() + 1], "12");
    }

    #[test]
    fn a_delayed_avi_seeks_the_delay_later_past_the_window() {
        let fps = 30000.0 / 1001.0;
        let seek = source_seek(41, fps, 0.0, 1, None);
        assert_eq!(seek.ss, seek_time(42, fps, 0.0));
        assert_eq!(seek.trim_frames, None);
        let args = preview_decoder_args("in.avi", &DecodeStart::from_seek(seek, 0.0), 11, 720, 480, "yuv420p", "f.raw", None);
        assert_eq!(args[..2], ["-ss".to_string(), "1.384717".to_string()]);
        assert_eq!(vf(&args), format!("{RESET_PTS_FILTER},{}", size_guard_filter(720, 480)));
        // Frame 0 never seeks, delay or not, but a delayed source rebases its
        // PTS so constant-rate output does not repeat its first picture.
        let zero = source_seek(0, fps, 0.0, 2, None);
        assert_eq!(zero, DecoderSeek { rebase: true, ..DecoderSeek::default() });
        let untrimmed = encode_decoder_args("in.avi", 720, 480, "yuv420p", &DecodeStart::from_seek(zero, 0.0), None, None, Some(90), None);
        assert!(pos(&untrimmed, "-ss").is_none());
        assert_eq!(vf(&untrimmed), format!("{RESET_PTS_FILTER},{}", size_guard_filter(720, 480)));
        assert_eq!(source_seek(0, fps, 0.0, 0, None), DecoderSeek::default(), "no delay: unchanged");
        // Out-of-range delays are clamped, never trusted.
        assert_eq!(source_seek(100, 25.0, 0.0, 99, None).ss, seek_time(104, 25.0, 0.0));
    }

    #[test]
    fn without_a_delay_source_seek_is_the_plain_decoder_seek() {
        for frame in [1, 10, 41, 43, 1000] {
            for fps in [25.0, 30000.0 / 1001.0, 24000.0 / 1001.0] {
                for plan in [None, Some(plan())] {
                    assert_eq!(
                        source_seek(frame, fps, 1.2, 0, plan.as_ref()),
                        decoder_seek(seek_time(frame, fps, 1.2), plan.as_ref()),
                    );
                }
            }
        }
    }

    #[test]
    fn a_seek_plan_takes_no_decoder_delay() {
        // No TS/PS stores packets without PTS; if one ever reports a delay the
        // plan's absolute trim stays on its own timestamps.
        let p = plan();
        assert_eq!(
            source_seek(40, 25.0, 1.2, 1, Some(&p)),
            decoder_seek(seek_time(40, 25.0, 1.2), Some(&p))
        );
        assert_eq!(source_seek(1, 25.0, 0.0, 1, Some(&p)).trim_frames, None);
    }

    #[test]
    fn the_decoder_delay_probe_reads_frames_not_packets() {
        assert_eq!(DECODER_DELAY_PROBE_ARGS[4], "-show_entries");
        assert!(DECODER_DELAY_PROBE_ARGS[5].starts_with("frame=best_effort_timestamp_time"));
        assert_eq!(&DECODER_DELAY_PROBE_ARGS[6..8], ["-read_intervals", "%+#16"]);
    }
    // ---- rule 8: the source grid (issue #174) ----

    fn grid_probe(r: &str, avg: &str, start: &str, container: &str, pts: &[&str]) -> serde_json::Value {
        serde_json::json!({
            "packets": pts.iter().map(|p| serde_json::json!({ "pts_time": p })).collect::<Vec<_>>(),
            "streams": [{ "start_time": start, "r_frame_rate": r, "avg_frame_rate": avg }],
            "format": { "start_time": container },
        })
    }

    #[test]
    fn the_probe_args_ask_for_the_rates_too() {
        assert!(VIDEO_START_PROBE_ARGS.contains(
            &"packet=pts_time:stream=start_time,r_frame_rate,avg_frame_rate:format=start_time"
        ));
    }

    #[test]
    fn the_grid_takes_the_streams_exact_rate_when_it_is_the_jobs() {
        // small_clip.mp4: 2997/100, which the app sends as 29.97.
        let g = grid_from_probe(&grid_probe("2997/100", "2997/100", "0.000000", "0.000000", &["0.000000", "0.033367"]), 29.97).unwrap();
        assert_eq!((g.rate_num, g.rate_den), (2997, 100));
        assert_eq!(g.origin, 0.0);
        // A VOB: r is the field rate, avg the frame rate (selectFrameRate's rule).
        let g = grid_from_probe(&grid_probe("60000/1001", "30000/1001", "0.550056", "0.550056", &["0.550056", "0.600100"]), 29.97).unwrap();
        assert_eq!((g.rate_num, g.rate_den), (30000, 1001));
        assert!((g.origin - 0.550056).abs() < 1e-9);
        // A job at another rate than the stream: the job's.
        let g = grid_from_probe(&grid_probe("25/1", "25/1", "0", "0", &["0"]), 23.976).unwrap();
        assert_eq!((g.rate_num, g.rate_den), (24000, 1001));
    }

    #[test]
    fn the_grid_starts_at_the_first_picture_never_before_the_container() {
        // DVB-T: the open GOP's leading B pictures precede the stream start.
        let g = grid_from_probe(&grid_probe("50/1", "25/1", "2.722022", "1.400000", &["2.722022", "2.602022", "2.642022"]), 25.0).unwrap();
        assert!((g.origin - 2.602022).abs() < 1e-9);
        assert_eq!((g.rate_num, g.rate_den), (25, 1));
        // An MP4 edit list's discarded pre-roll sits before the container start.
        let g = grid_from_probe(&grid_probe("2997/100", "2997/100", "0", "0", &["-0.100100", "0.000000"]), 29.97).unwrap();
        assert_eq!(g.origin, 0.0);
    }

    #[test]
    fn packets_without_timestamps_get_no_grid() {
        // hard_telecine_test.avi: MPEG-2 in AVI, B pictures stored with no PTS.
        let mut j = grid_probe("30000/1001", "30000/1001", "0", "0", &["0.066733"]);
        j["packets"].as_array_mut().unwrap().insert(0, serde_json::json!({ "pts_time": "N/A" }));
        assert_eq!(grid_from_probe(&j, 29.97), None);
        let mut j = grid_probe("25/1", "25/1", "0", "0", &[]);
        assert_eq!(grid_from_probe(&j, 25.0), None, "no packets, no grid");
        j["packets"] = serde_json::json!([{}]);
        assert_eq!(grid_from_probe(&j, 25.0), None);
    }

    fn grid() -> SourceGrid {
        SourceGrid { rate_num: 25, rate_den: 1, origin: 1.2 }
    }

    #[test]
    fn grid_decoders_copy_timestamps_and_keep_slots_from_the_frame() {
        let start = decode_start(0, 25.0, 1.2, 0, None, Some(&grid()));
        let args = encode_decoder_args("in.mkv", 720, 576, "yuv420p", &start, None, None, Some(100), None);
        assert_eq!(args[0], "-copyts");
        assert!(pos(&args, "-ss").is_none(), "untrimmed never seeks");
        assert_eq!(
            vf(&args),
            format!("setpts=PTS-1.200000/TB,fps=25/1,trim=start_pts=0,setpts=PTS-STARTPTS,{}", size_guard_filter(720, 576))
        );
        // An in-point seeks the lookback early and drops to its slot.
        let start = decode_start(40, 25.0, 1.2, 0, None, Some(&grid()));
        let args = encode_decoder_args("in.mkv", 720, 576, "yuv420p", &start, Some(40), Some(49), None, None);
        let ss: f64 = args[pos(&args, "-ss").unwrap() + 1].parse().unwrap();
        assert!((ss - ((40 - GRID_LOOKBACK_SLOTS) as f64 - 0.5) / 25.0 - 1.2).abs() < 1e-6);
        assert!(pos(&args, "-copyts").unwrap() < pos(&args, "-ss").unwrap());
        assert!(vf(&args).contains("fps=25/1,trim=start_pts=40,setpts=PTS-STARTPTS,crop="));
        assert_eq!(args[pos(&args, "-frames:v").unwrap() + 1], "10");
        // The preview window and the encode start the same way.
        let p = preview_decoder_args("in.mkv", &start, 10, 720, 576, "yuv420p", "f.raw", None);
        assert_eq!(p[..pos(&p, "-i").unwrap()], args[..pos(&args, "-i").unwrap()]);
        assert_eq!(vf(&p), vf(&args));
    }

    #[test]
    fn a_frame_within_the_lookback_decodes_from_the_start() {
        // interlaced_test.avi's in-points 1-4 are inside its leading null run:
        // only a decode from frame 0 reaches the stored frame they repeat.
        for n in 1..=GRID_LOOKBACK_SLOTS {
            let s = decode_start(n, 25.0, 0.0, 0, None, Some(&grid()));
            assert_eq!(s.ss, None, "frame {n}");
            assert!(s.copyts);
            assert_eq!(s.filters[2], format!("trim=start_pts={n}"));
        }
        assert!(decode_start(GRID_LOOKBACK_SLOTS + 1, 25.0, 0.0, 0, None, Some(&grid())).ss.is_some());
    }

    #[test]
    fn a_grid_on_a_ts_adds_the_plans_preroll() {
        let s = decode_start(40, 25.0, 1.2, 0, Some(&plan()), Some(&grid()));
        let expect = ((40 - GRID_LOOKBACK_SLOTS) as f64 - 0.5) / 25.0 + 1.2 - plan().preroll;
        assert!((s.ss.unwrap() - expect).abs() < 1e-9);
        assert!(!s.filters.iter().any(|f| f.starts_with("trim=start=")), "the slot trim replaces the time trim");
        // Preroll past the start: no -ss, still the slot.
        let s = decode_start(10, 25.0, 1.2, 0, Some(&plan()), Some(&grid()));
        assert_eq!(s.ss, None);
        assert_eq!(s.filters[2], "trim=start_pts=10");
    }

    #[test]
    fn a_ts_decoded_from_its_start_keeps_discontinuity_correction() {
        // -copyts would stop an untrimmed program stream at a clock reset.
        let s = decode_start(0, 25.0, 1.2, 0, Some(&plan()), Some(&grid()));
        assert!(!s.copyts);
        assert_eq!(s.ss, None);
        assert_eq!(s.filters, ["setpts=PTS-STARTPTS", "fps=25/1", "trim=start_pts=0", "setpts=PTS-STARTPTS"]);
        // Any other format still starts frame 0 on its grid.
        assert!(decode_start(0, 25.0, 1.2, 0, None, Some(&grid())).copyts);
    }

    #[test]
    fn without_a_grid_decode_start_is_the_old_seek() {
        let cases = [(0, 0.0, 0, None), (10, 0.0, 0, None), (0, 1.2, 0, None), (40, 1.2, 0, None),
                     (40, 1.2, 0, Some(plan())), (0, 1.2, 0, Some(plan())), (3, 0.0, 1, None), (41, 0.0, 2, None)];
        for (frame, vs, delay, plan) in cases {
            let s = decode_start(frame, 25.0, vs, delay, plan.as_ref(), None);
            let old = source_seek(frame, 25.0, vs, delay, plan.as_ref());
            assert_eq!(s.ss, old.ss);
            assert_eq!(s.copyts, old.trim_from.is_some());
            assert_eq!(
                s.vf(720, 576, None),
                decoder_filter(720, 576, resets_pts(old.seeks() || old.rebase, vs), None, &old)
            );
            assert_eq!(s.input_args(), old.input_args());
        }
        let bad = SourceGrid { rate_num: 0, rate_den: 1, origin: 0.0 };
        assert_eq!(decode_start(10, 25.0, 0.0, 0, None, Some(&bad)), decode_start(10, 25.0, 0.0, 0, None, None));
    }

    #[test]
    fn a_grid_replaces_the_avi_delay_count() {
        // A source with a grid has PTS on every packet, so it never has a
        // decoder delay; if one were set, the grid still decides.
        let s = decode_start(3, 25.0, 0.0, 1, None, Some(&grid()));
        assert!(s.seek.is_none());
        assert_eq!(s.filters[2], "trim=start_pts=3");
    }

    #[test]
    fn the_grid_round_trips_in_camel_case() {
        let v = serde_json::to_value(grid()).unwrap();
        assert_eq!(v, serde_json::json!({ "rateNum": 25, "rateDen": 1, "origin": 1.2 }));
        assert_eq!(serde_json::from_value::<SourceGrid>(v).unwrap(), grid());
    }

    /// The vectors the app's `source_grid_test.dart` checks too: the
    /// Original and the thumbnails must start exactly as these decoders do.
    #[test]
    fn shared_grid_vectors() {
        let v: serde_json::Value = serde_json::from_str(include_str!(
            "../../Tests/TestResources/source_grid_vectors.json"
        ))
        .unwrap();
        for case in v["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let grid = grid_from_probe(&case["probe"], case["jobFps"].as_f64().unwrap());
            let want: Option<SourceGrid> = serde_json::from_value(case["grid"].clone()).unwrap();
            assert_eq!(grid, want, "{name}");
            for start in case["starts"].as_array().unwrap() {
                let plan: Option<SeekPlan> = start.get("plan").map(|p| serde_json::from_value(p.clone()).unwrap());
                let s = decode_start(
                    start["frame"].as_i64().unwrap(),
                    case["jobFps"].as_f64().unwrap(),
                    start["videoStart"].as_f64().unwrap(),
                    0,
                    plan.as_ref(),
                    grid.as_ref(),
                );
                let ss = s.ss.map(seek_arg);
                assert_eq!(ss.as_deref(), start["ss"].as_str(), "{name} frame {}", start["frame"]);
                let filters: Vec<String> = serde_json::from_value(start["filters"].clone()).unwrap();
                assert_eq!(s.filters, filters, "{name}");
                assert_eq!(s.copyts, start["copyts"].as_bool().unwrap_or(true), "{name} frame {}", start["frame"]);
            }
        }
    }

    #[test]
    fn the_sound_skips_only_on_a_delayed_source_near_its_start() {
        // No delay: every start seeks as it always did.
        assert_eq!(sound_seek(0.0667, 0), SoundSeek::Input(0.0667));
        assert!(!sound_seek_fails(0.0667, 0));
        // Delayed: inside (0, COUNT_SEEK_BELOW) the seek would fail.
        for t in [0.0334, 0.0667, 0.1, 0.12, 0.49] {
            assert!(sound_seek_fails(t, 2), "{t}");
            assert_eq!(sound_seek(t, 1), SoundSeek::Skip(t));
        }
        // At or past the threshold an input seek works.
        assert_eq!(sound_seek(COUNT_SEEK_BELOW, 2), SoundSeek::Input(COUNT_SEEK_BELOW));
        assert_eq!(sound_seek(2.0, 2), SoundSeek::Input(2.0));
        // Nothing to seek to.
        for t in [0.0, -0.1, f64::NAN] {
            assert!(!sound_seek_fails(t, 2) || t.is_nan());
            assert_eq!(sound_seek(t, 2), SoundSeek::None);
        }
    }
}
