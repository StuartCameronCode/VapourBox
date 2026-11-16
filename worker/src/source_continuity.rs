//! Timestamp resets in an MPEG-PS/TS, and the continuous copy that removes
//! them (task #21).
//!
//! A DVD title that spans VOB IDs, or a broadcast capture spliced across a
//! programme change, has a clock that goes back (or leaps forward) mid-file.
//! Nothing after the demuxer copes with that:
//!
//! - ffprobe's duration covers only the last segment's span, so the app's
//!   frame count, and the untrimmed encode capped at it, stop at about the
//!   first reset;
//! - `-ss` is a search over timestamps that occur once per segment, so a seek
//!   past a reset lands anywhere;
//! - the seek decoders run with `-copyts` (source_decode, rule 6), which turns
//!   ffmpeg's own discontinuity correction off, so a trim across a reset stops
//!   there.
//!
//! **Frame N is the Nth slot of the continuous timeline, each segment's
//! first picture one frame after the last segment's last.** A source with a
//! reset is stream-copied once, in its own container, and everything decodes
//! the copy. The copy shifts each segment by one offset, for every stream
//! alike (so sync inside a segment is kept), and **the picture decides the
//! offset** ([`JoinPlan`], task #58): `-copyts` turns ffmpeg's own
//! correction off and a `setts` bitstream filter per stream applies the
//! offsets by byte position. ffmpeg's correction took its offset from
//! whichever stream showed the reset first, so a first part whose sound ran
//! 16 ms past its last picture put every later picture 16 ms off the grid
//! (ffprobe then read 125 fps). A sound packet left overhanging the next
//! segment by more than half of it is dropped. When no plan can be made (no
//! durations or positions, streams resetting a different number of times)
//! the copy falls back to ffmpeg's correction, without `-copyts`. A source
//! without a reset is never copied, and its every argument stays as it was.
//!
//! [`resets_from_packets`] is the one statement of what counts as a reset;
//! the app learns it by running `--scan-timestamps`.

use std::collections::HashMap;
use std::path::Path;
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::source_decode::TIMESTAMP_SEARCH_FORMATS;

/// A backward step larger than this (seconds) is a reset: ffmpeg's own test
/// in a discontinuous format (a DTS more than a tenth of a second behind the
/// stream's last).
pub const RESET_BACKWARD_SECS: f64 = 0.1;

/// A forward step larger than this (seconds) is a reset: ffmpeg's
/// `dts_delta_threshold`. Smaller forward jumps (a signal drop-out) are real
/// gaps, which every decoder fills alike.
pub const RESET_FORWARD_SECS: f64 = 10.0;

/// ffprobe's arguments (before the input) for the streams and the format.
pub const STREAMS_PROBE_ARGS: [&str; 6] = [
    "-v", "error",
    "-show_entries", "stream=index,codec_type:format=format_name",
    "-of", "json",
];

/// ffprobe's arguments (before the input) for every packet's stream, DTS,
/// duration and byte position, one `stream_index,dts_time,duration_time,pos`
/// line each (ffprobe's own field order, whatever order they are asked in):
/// the whole file is read, so the output is kept to what the rule and the
/// join plan (task #58) need, plus the position, which is how far through
/// the file the scan is (task #55: on a network share the read takes
/// minutes, and the app shows it).
pub const PACKETS_PROBE_ARGS: [&str; 6] = [
    "-v", "error",
    "-show_entries", "packet=stream_index,dts_time,duration_time,pos",
    "-of", "csv=p=0",
];

/// One timestamp reset: where a stream's clock jumped.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reset {
    /// The stream's index in the file.
    pub stream: u32,
    /// `video` or `audio`.
    pub codec_type: String,
    /// The stream's packet count before the reset (for video, the picture it
    /// happens at, in decode order).
    pub packet: u64,
    /// The last DTS before the jump, seconds.
    pub from: f64,
    /// The first DTS after it.
    pub to: f64,
}

/// What `--scan-timestamps` reports.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContinuityScan {
    /// ffprobe's `format_name`.
    pub format: String,
    /// Whether the format is one whose resets matter (MPEG-PS/TS); `resets`
    /// is empty otherwise, whatever the file holds.
    pub applies: bool,
    pub resets: Vec<Reset>,
    /// Video packets in the file, every video stream (how the copy is checked).
    pub video_packets: u64,
    /// How the copy joins the segments; `None` without a reset, or when the
    /// packets don't give what the plan needs (the copy then falls back to
    /// ffmpeg's own correction). Absent from a scan an older worker wrote.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub join: Option<JoinPlan>,
}

/// From this point on (the stream's packet index, or a byte position; see
/// [`JoinStream::by_position`]), a stream's timestamps move by `offset`
/// seconds (the latest cut a packet is at or after applies).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cut {
    pub at: i64,
    pub offset: f64,
}

/// One copied stream's part of a [`JoinPlan`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JoinStream {
    /// `video`, `audio` or `subtitle`.
    pub codec_type: String,
    /// Its index among the file's streams of that type, which is its output
    /// index of that type too (`-map 0:v -map 0:a? -map 0:s?` keeps order).
    pub type_index: u32,
    /// Whether the cuts are byte positions (`POS`) rather than the stream's
    /// own packet indices (`N`). A stream that resets is cut at its own
    /// reset packet, by index: MPEG audio split from one PES by the parser
    /// carries no position after its first frame. A stream without a reset
    /// of its own (subtitles) is cut where the picture's reset packet sits
    /// in the file.
    pub by_position: bool,
    pub cuts: Vec<Cut>,
    /// Packet indices dropped: the last packet of a segment that overhangs
    /// the next segment's first by more than half of itself.
    pub drop: Vec<i64>,
}

/// The joined copy's timeline: each segment shifted so that its first
/// picture follows the previous segment's last by one frame, and every
/// stream of the segment shifted alike.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JoinPlan {
    pub streams: Vec<JoinStream>,
    /// What the plan did that a log should say (dropped sound).
    pub notes: Vec<String>,
}

/// One row of [`PACKETS_PROBE_ARGS`]' answer.
#[derive(Debug, Clone, Copy)]
struct Packet {
    dts: Option<f64>,
    duration: Option<f64>,
    pos: Option<i64>,
}

fn field<T: std::str::FromStr>(f: Option<&str>) -> Option<T> {
    f.and_then(|s| s.trim().parse::<T>().ok())
}

/// The packet rows per stream, in file order, for the streams in `types`.
fn packets_by_stream(csv: &str, types: &HashMap<u32, String>) -> std::collections::BTreeMap<u32, Vec<Packet>> {
    let mut out: std::collections::BTreeMap<u32, Vec<Packet>> = Default::default();
    for line in csv.lines() {
        let mut fields = line.split(',');
        let Some(stream) = field::<u32>(fields.next()) else { continue };
        if !types.contains_key(&stream) {
            continue;
        }
        let dts = field::<f64>(fields.next()).filter(|t| t.is_finite());
        let duration = field::<f64>(fields.next()).filter(|d| d.is_finite() && *d > 0.0);
        let pos = field::<i64>(fields.next()).filter(|p| *p >= 0);
        out.entry(stream).or_default().push(Packet { dts, duration, pos });
    }
    out
}

/// Where a stream's clock jumps: (index of the last packet with a DTS
/// before it, index of the first after it), by [`resets_from_packets`]' rule.
fn reset_points(packets: &[Packet]) -> Vec<(usize, usize)> {
    let mut last: Option<(usize, f64)> = None;
    let mut out = Vec::new();
    for (i, p) in packets.iter().enumerate() {
        let Some(dts) = p.dts else { continue };
        if let Some((j, prev)) = last {
            let step = dts - prev;
            if step < -RESET_BACKWARD_SECS || step > RESET_FORWARD_SECS {
                out.push((j, i));
            }
        }
        last = Some((i, dts));
    }
    out
}

fn typical_duration(packets: &[Packet]) -> Option<f64> {
    let mut d: Vec<f64> = packets.iter().filter_map(|p| p.duration).collect();
    if d.is_empty() {
        return None;
    }
    d.sort_by(|a, b| a.partial_cmp(b).unwrap());
    Some(d[d.len() / 2])
}

/// The [`JoinPlan`] for a packet list (as [`resets_from_packets`] reads it,
/// with durations and positions), or `None` when there is no video reset or
/// the plan can't be made exactly: a reset packet without a position, a
/// video stream without a duration, an audio or video stream resetting a
/// different number of times from the picture.
pub fn join_plan(csv: &str, types: &HashMap<u32, String>) -> Option<JoinPlan> {
    let copied: HashMap<u32, String> = types
        .iter()
        .filter(|(_, t)| matches!(t.as_str(), "video" | "audio" | "subtitle"))
        .map(|(i, t)| (*i, t.clone()))
        .collect();
    let streams = packets_by_stream(csv, &copied);
    // The grid: the first video stream with a reset.
    let (_, grid_packets) = streams
        .iter()
        .find(|(i, p)| copied[*i] == "video" && !reset_points(p).is_empty())?;
    let frame = typical_duration(grid_packets)?;
    let mut offsets = Vec::new();
    // The picture's cuts by byte position, for streams without a reset of
    // their own; `None` when a reset packet has no position.
    let mut grid_positions = Some(Vec::new());
    let mut off = 0.0;
    for (from, to) in reset_points(grid_packets) {
        let (a, b) = (grid_packets[from], grid_packets[to]);
        let step = a.duration.unwrap_or(frame);
        off += a.dts? + (to - from) as f64 * step - b.dts?;
        offsets.push(off);
        grid_positions = grid_positions.and_then(|mut v: Vec<Cut>| {
            v.push(Cut { at: b.pos?, offset: off });
            Some(v)
        });
    }
    let mut type_counts: HashMap<String, u32> = HashMap::new();
    let mut plan = JoinPlan { streams: Vec::new(), notes: Vec::new() };
    for (&index, packets) in &streams {
        let kind = copied[&index].clone();
        let type_index = {
            let c = type_counts.entry(kind.clone()).or_insert(0);
            *c += 1;
            *c - 1
        };
        let resets = if kind == "subtitle" { Vec::new() } else { reset_points(packets) };
        let mut stream = JoinStream {
            codec_type: kind.clone(),
            type_index,
            by_position: false,
            cuts: Vec::new(),
            drop: Vec::new(),
        };
        if resets.is_empty() {
            // No reset of its own (subtitles, a stream that ends before
            // it): the picture's cuts, by where they sit in the file.
            stream.by_position = true;
            stream.cuts = grid_positions.clone()?;
        } else if resets.len() == offsets.len() {
            let dur = typical_duration(packets);
            let mut prev_off = 0.0;
            for (k, &(from, to)) in resets.iter().enumerate() {
                let (a, b) = (packets[from], packets[to]);
                stream.cuts.push(Cut { at: to as i64, offset: offsets[k] });
                // How far its last packet before the reset runs into the
                // next segment's first, once both are shifted.
                if let (Some(d), Some(ad), Some(bd), true) = (a.duration.or(dur), a.dts, b.dts, to == from + 1) {
                    let overhang = (ad + prev_off + d) - (bd + offsets[k]);
                    if overhang > d / 2.0 {
                        stream.drop.push(from as i64);
                        plan.notes.push(format!(
                            "{} stream {}: the segment's sound ran {:.0} ms past its last picture; \
                             its last packet ({:.0} ms) is dropped at the join",
                            kind,
                            type_index,
                            (overhang) * 1000.0,
                            d * 1000.0
                        ));
                    }
                }
                prev_off = offsets[k];
            }
        } else {
            return None;
        }
        plan.streams.push(stream);
    }
    Some(plan)
}

impl ContinuityScan {
    /// Whether the source has to be decoded from a continuous copy.
    pub fn needs_copy(&self) -> bool {
        self.applies && !self.resets.is_empty()
    }

    /// One line for a log: how many resets, and at which pictures.
    pub fn summary(&self) -> String {
        let video: Vec<String> = self
            .resets
            .iter()
            .filter(|r| r.codec_type == "video")
            .map(|r| format!("picture {} ({:.2} s -> {:.2} s)", r.packet, r.from, r.to))
            .collect();
        let mut line = if video.is_empty() {
            format!("{} timestamp reset(s) in the sound", self.resets.len())
        } else {
            format!("timestamps reset at {}", video.join(", "))
        };
        for note in self.join.iter().flat_map(|j| &j.notes) {
            line.push_str("; ");
            line.push_str(note);
        }
        line
    }
}

/// Whether ffprobe's `format_name` is one ffmpeg treats as discontinuous and
/// seeks by timestamp (MPEG-TS/PS).
pub fn applies_to(format_name: &str) -> bool {
    format_name
        .split(',')
        .any(|n| TIMESTAMP_SEARCH_FORMATS.contains(&n.trim()))
}

/// The resets in a packet list (`stream_index,dts_time[,duration_time,pos]` lines, in
/// file order), for the audio and video streams in `types` (index -> codec
/// type): [`ResetScanner`] over the whole list.
pub fn resets_from_packets(csv: &str, types: &HashMap<u32, String>) -> (Vec<Reset>, u64) {
    let mut scanner = ResetScanner::new(types);
    for line in csv.lines() {
        scanner.push(line);
    }
    scanner.finish()
}

/// The reset rule, one packet line at a time, so a scan can follow ffprobe's
/// output as it arrives (task #55) instead of holding all of it.
///
/// Per stream, in decode order: a DTS more than [`RESET_BACKWARD_SECS`]
/// behind the stream's last, or more than [`RESET_FORWARD_SECS`] ahead.
/// Packets without a DTS are skipped (a program stream leaves some out). A
/// 33-bit wrap never shows: the demuxer unwraps it before ffprobe prints.
pub struct ResetScanner<'a> {
    types: &'a HashMap<u32, String>,
    last: HashMap<u32, f64>,
    counts: HashMap<u32, u64>,
    resets: Vec<Reset>,
    video_packets: u64,
    position: Option<u64>,
}

impl<'a> ResetScanner<'a> {
    pub fn new(types: &'a HashMap<u32, String>) -> Self {
        Self {
            types,
            last: HashMap::new(),
            counts: HashMap::new(),
            resets: Vec::new(),
            video_packets: 0,
            position: None,
        }
    }

    /// The furthest byte position a packet line has given so far (any
    /// stream: a program stream leaves many packets without one).
    pub fn position(&self) -> Option<u64> {
        self.position
    }

    /// One `stream_index,dts_time[,duration_time,pos]` line.
    pub fn push(&mut self, line: &str) {
        let mut fields = line.split(',');
        let Some(stream) = fields.next().and_then(|s| s.trim().parse::<u32>().ok()) else {
            return;
        };
        let dts = fields.next();
        let _duration = fields.next();
        if let Some(pos) = fields.next().and_then(|s| s.trim().parse::<u64>().ok()) {
            self.position = Some(self.position.map_or(pos, |p| p.max(pos)));
        }
        let Some(kind) = self.types.get(&stream) else { return };
        if kind != "video" && kind != "audio" {
            return;
        }
        let count = self.counts.entry(stream).or_insert(0);
        let packet = *count;
        *count += 1;
        if kind == "video" {
            self.video_packets += 1;
        }
        let Some(dts) = dts
            .and_then(|s| s.trim().parse::<f64>().ok())
            .filter(|t| t.is_finite())
        else {
            return;
        };
        if let Some(&prev) = self.last.get(&stream) {
            let step = dts - prev;
            if step < -RESET_BACKWARD_SECS || step > RESET_FORWARD_SECS {
                self.resets.push(Reset {
                    stream,
                    codec_type: kind.clone(),
                    packet,
                    from: prev,
                    to: dts,
                });
            }
        }
        self.last.insert(stream, dts);
    }

    /// The resets found and the video packets counted.
    pub fn finish(self) -> (Vec<Reset>, u64) {
        (self.resets, self.video_packets)
    }
}

/// The stream types and format name from ffprobe's answer to
/// [`STREAMS_PROBE_ARGS`].
pub fn streams_from_probe(json: &serde_json::Value) -> (String, HashMap<u32, String>) {
    let format = json
        .pointer("/format/format_name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let mut types = HashMap::new();
    for s in json.get("streams").and_then(|s| s.as_array()).into_iter().flatten() {
        if let (Some(i), Some(t)) = (
            s.get("index").and_then(|v| v.as_u64()),
            s.get("codec_type").and_then(|v| v.as_str()),
        ) {
            types.insert(i as u32, t.to_string());
        }
    }
    (format, types)
}

/// Scan a file for timestamp resets. A format other than MPEG-PS/TS is
/// answered from the stream probe alone (`applies: false`), without reading
/// its packets.
pub fn scan(
    ffprobe: &Path,
    env: &HashMap<String, String>,
    input: &str,
) -> Result<ContinuityScan> {
    scan_with_progress(ffprobe, env, input, |_| {})
}

/// [`scan`], reporting the fraction of the file read (0..1) as it goes.
pub fn scan_with_progress(
    ffprobe: &Path,
    env: &HashMap<String, String>,
    input: &str,
    progress: impl FnMut(f64),
) -> Result<ContinuityScan> {
    let out = Command::new(ffprobe)
        .args(STREAMS_PROBE_ARGS)
        .arg(input)
        .envs(env)
        .stderr(Stdio::piped())
        .output()
        .context("failed to run ffprobe")?;
    if !out.status.success() {
        bail!(
            "ffprobe could not read {}: {}",
            input,
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    let json: serde_json::Value =
        serde_json::from_slice(&out.stdout).context("ffprobe's stream list is not JSON")?;
    let (format, types) = streams_from_probe(&json);
    scan_packets_with_progress(ffprobe, env, input, format, &types, progress)
}

/// [`scan`] once the stream probe is done (`format` and `types` from
/// [`streams_from_probe`], which reads any `-show_streams -show_format`
/// answer): the source model's probe already has them.
pub fn scan_packets(
    ffprobe: &Path,
    env: &HashMap<String, String>,
    input: &str,
    format: String,
    types: &HashMap<u32, String>,
) -> Result<ContinuityScan> {
    scan_packets_with_progress(ffprobe, env, input, format, types, |_| {})
}

/// How much further (a fraction of the file) a scan must get before it
/// reports progress again.
const PROGRESS_STEP: f64 = 0.005;

/// [`scan_packets`], following ffprobe's output line by line and reporting
/// the fraction of the file's bytes read (from the packets' positions) as it
/// goes, then 1.0 at the end. If the caller is killed, ffprobe dies on its
/// next write to the closed pipe.
pub fn scan_packets_with_progress(
    ffprobe: &Path,
    env: &HashMap<String, String>,
    input: &str,
    format: String,
    types: &HashMap<u32, String>,
    mut progress: impl FnMut(f64),
) -> Result<ContinuityScan> {
    if !applies_to(&format) {
        return Ok(ContinuityScan { format, applies: false, resets: vec![], video_packets: 0, join: None });
    }
    let size = std::fs::metadata(input).map(|m| m.len()).unwrap_or(0);
    let mut child = Command::new(ffprobe)
        .args(PACKETS_PROBE_ARGS)
        .arg(input)
        .envs(env)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to run ffprobe")?;
    let mut scanner = ResetScanner::new(types);
    let mut csv = String::new();
    if let Some(stdout) = child.stdout.take() {
        use std::io::BufRead;
        let mut reported = 0.0f64;
        let mut reader = std::io::BufReader::with_capacity(1 << 16, stdout);
        let mut line = Vec::new();
        loop {
            line.clear();
            match reader.read_until(b'\n', &mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            let text = String::from_utf8_lossy(&line);
            scanner.push(&text);
            csv.push_str(&text);
            if let (Some(pos), true) = (scanner.position(), size > 0) {
                let f = (pos as f64 / size as f64).min(1.0);
                if f - reported >= PROGRESS_STEP {
                    reported = f;
                    progress(f);
                }
            }
        }
    }
    let status = child.wait().context("ffprobe did not finish")?;
    if !status.success() {
        bail!("ffprobe could not list the packets of {}", input);
    }
    let (resets, video_packets) = scanner.finish();
    // The join plan needs every packet's row, but only when there is a reset.
    let join = if resets.is_empty() { None } else { join_plan(&csv, types) };
    progress(1.0);
    Ok(ContinuityScan { format, applies: true, resets, video_packets, join })
}

/// The muxer a continuous copy is written with: the source's own container,
/// so every format-specific rule (the seek plan, field-coded TS, soft
/// telecine) applies to the copy exactly as to the source.
pub fn copy_muxer(format_name: &str) -> Option<&'static str> {
    let names: Vec<&str> = format_name.split(',').map(str::trim).collect();
    if names.contains(&"mpegts") {
        Some("mpegts")
    } else if names.contains(&"mpeg") {
        Some("vob")
    } else {
        None
    }
}

/// ffmpeg's arguments for the continuous copy. No `-copyts`: that is what
/// leaves ffmpeg's discontinuity correction on. Video, audio and subtitles
/// are copied; data streams (teletext pages as data, SCTE-35) are not, since
/// nothing downstream reads them. With `with_subtitles` false the subtitles
/// are left out too (the retry when the muxer refuses one).
pub fn continuous_copy_args(
    input: &str,
    muxer: &str,
    output: &str,
    with_subtitles: bool,
    join: Option<&JoinPlan>,
) -> Vec<String> {
    let mut args: Vec<String> = ["-hide_banner", "-nostdin", "-y", "-v", "error"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    if join.is_some() {
        args.push("-copyts".to_string());
    }
    args.extend(["-i", input].iter().map(|s| s.to_string()));
    args.extend(["-map", "0:v", "-map", "0:a?"].iter().map(|s| s.to_string()));
    if with_subtitles {
        args.extend(["-map", "0:s?"].iter().map(|s| s.to_string()));
    }
    for s in join.map(|j| j.streams.as_slice()).unwrap_or_default() {
        if s.codec_type == "subtitle" && !with_subtitles {
            continue;
        }
        let spec = match s.codec_type.as_str() {
            "video" => "v",
            "audio" => "a",
            _ => "s",
        };
        args.push(format!("-bsf:{spec}:{}", s.type_index));
        args.push(join_bsf(s));
    }
    args.extend(
        ["-c", "copy", "-map_metadata", "0", "-progress", "pipe:1", "-nostats", "-f", muxer, output]
            .iter()
            .map(|s| s.to_string()),
    );
    args
}

/// The bitstream filters that move one stream onto the joined timeline:
/// `setts` adds the offset of the latest cut a packet is at or after (its
/// packet index `N`, or its byte position `POS`), leaving a missing
/// timestamp missing; `noise`, after it, drops the overhanging packets by
/// index (`n`: `setts` drops nothing, so both count the same packets).
/// Commas inside an option are escaped for the filter list.
pub fn join_bsf(s: &JoinStream) -> String {
    let key = if s.by_position { "POS" } else { "N" };
    let mut off = "0".to_string();
    for c in &s.cuts {
        off = format!("if(gte({key}\\,{})\\,{:.9}\\,{})", c.at, c.offset, off);
    }
    let shift = |ts: &str| format!("if(eq({ts}\\,NOPTS)\\,NOPTS\\,{ts}+round(({off})/TB))");
    let mut f = format!("setts=pts={}:dts={}", shift("PTS"), shift("DTS"));
    if !s.drop.is_empty() {
        let drop: Vec<String> = s.drop.iter().map(|n| format!("eq(n\\,{n})")).collect();
        f.push_str(&format!(",noise=drop={}", drop.join("+")));
    }
    f
}

/// Why a finished copy can't be used, or `None` when it can: it must have no
/// reset left and every video packet of the source.
pub fn copy_problem(source: &ContinuityScan, copy: &ContinuityScan) -> Option<String> {
    if !copy.resets.is_empty() {
        return Some(format!(
            "the joined copy still has {} timestamp reset(s) ({})",
            copy.resets.len(),
            copy.summary()
        ));
    }
    if copy.video_packets != source.video_packets {
        return Some(format!(
            "the joined copy has {} video packets, the source {}",
            copy.video_packets, source.video_packets
        ));
    }
    None
}

/// Copy `input` to `output` with continuous timestamps and check the result
/// (see [`copy_problem`]). `progress` gets the fraction of the source's bytes
/// copied. On failure `output` is removed and the error says why; the caller
/// keeps the original.
pub fn make_continuous(
    ffmpeg: &Path,
    ffprobe: &Path,
    env: &HashMap<String, String>,
    input: &str,
    source: &ContinuityScan,
    output: &Path,
    mut progress: impl FnMut(f64),
) -> Result<ContinuityScan> {
    let muxer = copy_muxer(&source.format)
        .with_context(|| format!("no continuous copy for format {}", source.format))?;
    let size = std::fs::metadata(input).map(|m| m.len()).unwrap_or(0);
    let out_str = output.to_string_lossy().to_string();
    let result = (|| -> Result<ContinuityScan> {
        let mut last_err = String::new();
        let mut done = false;
        for with_subtitles in [true, false] {
            let mut child = Command::new(ffmpeg)
                .args(continuous_copy_args(input, muxer, &out_str, with_subtitles, source.join.as_ref()))
                .envs(env)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .context("failed to run ffmpeg")?;
            let stderr = child.stderr.take();
            let err_thread = std::thread::spawn(move || {
                let mut s = String::new();
                if let Some(mut e) = stderr {
                    use std::io::Read;
                    let _ = e.read_to_string(&mut s);
                }
                s
            });
            if let Some(stdout) = child.stdout.take() {
                use std::io::BufRead;
                for line in std::io::BufReader::new(stdout).lines().map_while(|l| l.ok()) {
                    if let Some(bytes) = line.strip_prefix("total_size=") {
                        if let (Ok(b), true) = (bytes.trim().parse::<u64>(), size > 0) {
                            progress((b as f64 / size as f64).min(1.0));
                        }
                    }
                }
            }
            let status = child.wait()?;
            let err = err_thread.join().unwrap_or_default();
            if status.success() {
                done = true;
                break;
            }
            last_err = err.trim().to_string();
        }
        if !done {
            bail!("ffmpeg could not copy the source: {}", last_err);
        }
        let copy = scan(ffprobe, env, &out_str)?;
        if let Some(problem) = copy_problem(source, &copy) {
            bail!("{}", problem);
        }
        progress(1.0);
        Ok(copy)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(output);
    }
    result
}

/// What a DVD import did with the file it extracted (see [`finish_import`]).
pub enum ImportOutcome {
    /// No reset: the extraction is the output, byte for byte.
    Unchanged,
    /// Joined into a continuous copy; carries the extraction's scan (its
    /// resets, for the log).
    Joined(ContinuityScan),
    /// Kept as extracted, for the reason given.
    Kept(String),
}

/// Finish a DVD import from the file it extracted (`part`): rename it to
/// `output` when it has no reset, else join it into `output` and delete the
/// part. A failed scan or join keeps the extraction as it is (with the reason
/// in [`ImportOutcome::Kept`]), since an import that stops at a reset still
/// beats no import. `scan_fn` and `join_fn` are the scan and the copy
/// (injected so the decision is testable without ffmpeg).
pub fn finish_import(
    part: &Path,
    output: &Path,
    scan_fn: impl FnOnce(&str) -> Result<ContinuityScan>,
    join_fn: impl FnOnce(&ContinuityScan) -> Result<ContinuityScan>,
) -> Result<ImportOutcome> {
    let part_str = part.to_string_lossy().to_string();
    let outcome = match scan_fn(&part_str) {
        Ok(s) if s.needs_copy() => match join_fn(&s) {
            Ok(_) => {
                let _ = std::fs::remove_file(part);
                return Ok(ImportOutcome::Joined(s));
            }
            Err(e) => ImportOutcome::Kept(format!("{} ({:#})", s.summary(), e)),
        },
        Ok(_) => ImportOutcome::Unchanged,
        Err(e) => ImportOutcome::Kept(format!("the timestamp scan failed: {:#}", e)),
    };
    std::fs::rename(part, output)
        .with_context(|| format!("failed to move {:?} to {:?}", part, output))?;
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn types() -> HashMap<u32, String> {
        HashMap::from([
            (0, "video".to_string()),
            (1, "audio".to_string()),
            (2, "subtitle".to_string()),
            (3, "data".to_string()),
        ])
    }

    #[test]
    fn a_backward_step_over_a_tenth_of_a_second_is_a_reset() {
        let csv = "0,0.50\n0,0.54\n0,6.46\n0,0.50\n0,0.54\n";
        let (r, n) = resets_from_packets(csv, &types());
        assert_eq!(n, 5);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].packet, 3);
        assert_eq!((r[0].from, r[0].to), (6.46, 0.50));
        assert_eq!(r[0].codec_type, "video");
    }

    #[test]
    fn b_frame_reordering_and_small_steps_back_are_not_resets() {
        // DTS is monotonic in a sane stream; a step back of 0.08 s (two
        // frames) is ffmpeg's own tolerance, not a reset.
        let (r, _) = resets_from_packets("0,1.00\n0,0.92\n0,1.04\n", &types());
        assert!(r.is_empty(), "{r:?}");
    }

    #[test]
    fn a_forward_gap_counts_only_beyond_ten_seconds() {
        let (r, _) = resets_from_packets("0,1.0\n0,6.0\n0,6.04\n", &types());
        assert!(r.is_empty(), "a 5 s drop-out is a gap: {r:?}");
        let (r, _) = resets_from_packets("0,1.0\n0,16.0\n0,16.04\n", &types());
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].packet, 1);
    }

    #[test]
    fn packets_without_a_dts_are_skipped_but_counted() {
        let (r, n) = resets_from_packets("0,0.5\n0,N/A\n0,0.58\n0,\n0,0.62\n", &types());
        assert!(r.is_empty());
        assert_eq!(n, 5);
        let (r, _) = resets_from_packets("0,6.0\n0,N/A\n0,0.5\n", &types());
        assert_eq!(r[0].packet, 2);
    }

    #[test]
    fn audio_resets_count_and_other_streams_are_ignored() {
        let csv = "1,6.5\n1,0.53\n2,9.0\n2,0.0\n3,9.0\n3,0.0\n0,0.5\n";
        let (r, n) = resets_from_packets(csv, &types());
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].stream, 1);
        assert_eq!(r[0].codec_type, "audio");
        assert_eq!(n, 1);
    }

    #[test]
    fn each_stream_is_followed_on_its_own() {
        // Interleaved: the audio runs ahead of the video without either
        // stepping back.
        let csv = "1,0.0\n0,0.5\n1,0.6\n0,0.54\n1,1.2\n0,0.58\n";
        let (r, _) = resets_from_packets(csv, &types());
        assert!(r.is_empty(), "{r:?}");
    }

    #[test]
    fn the_position_column_is_read_and_never_goes_back() {
        // ffprobe's own order: stream_index, dts_time, duration_time, pos
        // (a TS line can end in an empty field; a PS sound packet often has
        // no position).
        let csv = "1,0.529978,0.024,2062\n1,0.553978,0.024,N/A\n0,1.40,0.04,564,\n0,1.44,0.04,5076,\n2,9.0,N/A,99999\n0,1.48,0.04,4000\n";
        let t = types();
        let mut s = ResetScanner::new(&t);
        let mut seen = Vec::new();
        for line in csv.lines() {
            s.push(line);
            seen.push(s.position());
        }
        assert_eq!(
            seen,
            vec![Some(2062), Some(2062), Some(2062), Some(5076), Some(99999), Some(99999)],
            "positions from every stream, the furthest kept"
        );
        let (r, n) = s.finish();
        assert!(r.is_empty(), "{r:?}");
        assert_eq!(n, 3);
    }

    #[test]
    fn the_scanner_line_by_line_is_the_rule_over_the_whole_list() {
        let cases = [
            "0,0.50\n0,0.54\n0,6.46\n0,0.50\n0,0.54\n",
            "0,1.0\n0,16.0\n0,16.04\n",
            "0,6.0\n0,N/A\n0,0.5\n",
            "1,6.5,0.024,10\n1,0.53,0.024,20\n2,9.0,0.04,30\n2,0.0,0.04,40\n3,9.0\n3,0.0\n0,0.5,0.04,50\n",
        ];
        let t = types();
        for csv in cases {
            let mut s = ResetScanner::new(&t);
            csv.lines().for_each(|l| s.push(l));
            assert_eq!(s.finish(), resets_from_packets(csv, &t), "{csv}");
            // The old two-column lines and the new four-column lines agree.
            let two: String = csv
                .lines()
                .map(|l| l.split(',').take(2).collect::<Vec<_>>().join(",") + "\n")
                .collect();
            assert_eq!(resets_from_packets(&two, &t), resets_from_packets(csv, &t), "{csv}");
        }
    }

    #[test]
    fn the_packet_probe_asks_for_the_position() {
        assert!(PACKETS_PROBE_ARGS.join(" ").contains("packet=stream_index,dts_time,duration_time,pos"));
    }

    #[test]
    fn only_mpeg_ps_and_ts_apply() {
        assert!(applies_to("mpeg"));
        assert!(applies_to("mpegts"));
        assert!(!applies_to("mpegvideo"));
        assert!(!applies_to("mov,mp4,m4a,3gp,3g2,mj2"));
        assert!(!applies_to("matroska,webm"));
        assert_eq!(copy_muxer("mpeg"), Some("vob"));
        assert_eq!(copy_muxer("mpegts"), Some("mpegts"));
        assert_eq!(copy_muxer("mpegvideo"), None);
    }

    #[test]
    fn the_copy_keeps_the_container_and_drops_copyts() {
        let a = continuous_copy_args("in.vob", "vob", "out.mpg", true, None);
        let s = a.join(" ");
        assert!(!s.contains("copyts"), "{s}");
        assert!(s.contains("-map 0:v -map 0:a? -map 0:s? -c copy -map_metadata 0"), "{s}");
        assert!(s.ends_with("-f vob out.mpg"), "{s}");
        let t = continuous_copy_args("in.ts", "mpegts", "out.ts", false, None).join(" ");
        assert!(!t.contains("0:s?"), "{t}");
        assert!(t.ends_with("-f mpegts out.ts"), "{t}");
        // No -muxdelay: the copy keeps the source's start time.
        assert!(!t.contains("muxdelay"), "{t}");
    }

    /// The off-grid reset (`conf_reset_offgrid.mpg`'s shape): the picture
    /// resets after 50 frames at 2.00 s, the sound after 84 packets, running
    /// 16 ms past the last picture. Task #58.
    fn offgrid_csv() -> String {
        let mut rows = Vec::new();
        let mut pos = 0i64;
        let mut push = |s: u32, dts: f64, d: f64| {
            rows.push(format!("{s},{dts:.6},{d:.6},{pos}"));
            pos += 100;
        };
        for part in 0..2 {
            for i in 0..50 {
                push(0, 0.5 + i as f64 * 0.04, 0.04);
            }
            let sound = if part == 0 { 84 } else { 83 };
            for i in 0..sound {
                push(1, 0.529978 + i as f64 * 0.024, 0.024);
            }
        }
        rows.join("\n")
    }

    #[test]
    fn the_picture_decides_the_join_and_overhanging_sound_is_dropped() {
        let plan = join_plan(&offgrid_csv(), &types()).expect("a plan");
        assert_eq!(plan.streams.len(), 2);
        let (v, a) = (&plan.streams[0], &plan.streams[1]);
        assert_eq!((v.codec_type.as_str(), v.type_index), ("video", 0));
        // Last picture 0.5 + 49 x 0.04 = 2.46, next at 2.50; the second part's
        // first picture is at 0.50: everything after moves by exactly 2.00 s.
        assert_eq!(v.cuts.len(), 1);
        assert!((v.cuts[0].offset - 2.0).abs() < 1e-9, "{:?}", v.cuts);
        assert_eq!(v.cuts[0].at, 50, "the second part's first picture");
        assert!(!v.by_position && !a.by_position, "streams that reset are cut by packet index");
        // The sound moves by the picture's offset, at its own reset.
        assert!((a.cuts[0].offset - 2.0).abs() < 1e-9);
        assert_eq!(a.cuts[0].at, 84);
        // Its last packet ends 2.545978; the next part's first starts at
        // 2.529978: 16 ms of a 24 ms packet overhang, so it goes.
        assert_eq!(a.drop, vec![83]);
        assert_eq!(plan.notes.len(), 1, "{:?}", plan.notes);
        assert!(v.drop.is_empty());
    }

    #[test]
    fn a_join_on_the_grid_drops_nothing_and_two_resets_add_up() {
        // Sound and picture end together: 51 pictures = 85 MP2 packets.
        let mut rows = Vec::new();
        let mut pos = 0;
        for _ in 0..3 {
            for i in 0..51 {
                rows.push(format!("0,{:.6},0.04,{pos}", 0.5 + i as f64 * 0.04));
                pos += 10;
            }
            for i in 0..85 {
                rows.push(format!("1,{:.6},0.024,{pos}", 0.5 + i as f64 * 0.024));
                pos += 10;
            }
        }
        let plan = join_plan(&rows.join("\n"), &types()).unwrap();
        let offs: Vec<f64> = plan.streams[0].cuts.iter().map(|c| c.offset).collect();
        assert_eq!(offs.len(), 2);
        assert!((offs[0] - 2.04).abs() < 1e-9 && (offs[1] - 4.08).abs() < 1e-9, "{offs:?}");
        assert!(plan.streams.iter().all(|s| s.drop.is_empty()));
        assert!(plan.notes.is_empty());
    }

    #[test]
    fn the_summary_says_what_the_join_dropped() {
        let mut scan = scan_of(1, 100);
        assert!(!scan.summary().contains("dropped"));
        scan.join = join_plan(&offgrid_csv(), &types());
        let s = scan.summary();
        assert!(s.starts_with("timestamps reset at picture 150") && s.contains("16 ms past its last picture"), "{s}");
    }

    #[test]
    fn no_plan_without_what_it_needs() {
        // No durations (an older scan's two columns).
        assert!(join_plan("0,6.46\n0,0.50\n", &types()).is_none());
        // No video reset.
        assert!(join_plan("0,0.5,0.04,0\n0,0.54,0.04,10\n1,3.0,0.024,20\n1,0.5,0.024,30\n", &types()).is_none());
        // The sound resets twice, the picture once.
        let csv = "0,2.46,0.04,0\n0,0.5,0.04,10\n1,2.0,0.024,20\n1,0.5,0.024,30\n1,3.0,0.024,40\n1,0.6,0.024,50\n";
        assert!(join_plan(csv, &types()).is_none());
    }

    #[test]
    fn the_join_filters_shift_by_position_and_keep_missing_timestamps() {
        let plan = join_plan(&offgrid_csv(), &types()).unwrap();
        let v = join_bsf(&plan.streams[0]);
        assert_eq!(
            v,
            "setts=pts=if(eq(PTS\\,NOPTS)\\,NOPTS\\,PTS+round((if(gte(N\\,50)\\,2.000000000\\,0))/TB))\
             :dts=if(eq(DTS\\,NOPTS)\\,NOPTS\\,DTS+round((if(gte(N\\,50)\\,2.000000000\\,0))/TB))"
        );
        assert!(join_bsf(&plan.streams[1]).ends_with(",noise=drop=eq(n\\,83)"));
        let a = continuous_copy_args("in.vob", "vob", "out.mpg", true, Some(&plan)).join(" ");
        assert!(a.contains("-v error -copyts -i in.vob"), "{a}");
        assert!(a.contains("-bsf:v:0 setts=") && a.contains("-bsf:a:0 setts="), "{a}");
    }

    /// A subtitle stream has no reset of its own: it follows the picture's
    /// cuts, and is left out with the subtitles.
    #[test]
    fn subtitles_follow_the_picture() {
        let csv = format!("{}\n2,1.0,,50\n2,0.7,,20000\n", offgrid_csv());
        let plan = join_plan(&csv, &types()).unwrap();
        let sub = plan.streams.iter().find(|s| s.codec_type == "subtitle").unwrap();
        assert!(sub.by_position);
        assert_eq!(sub.cuts, vec![Cut { at: 13_400, offset: plan.streams[0].cuts[0].offset }]);
        assert!(join_bsf(sub).contains("gte(POS\\,13400)"));
        let without = continuous_copy_args("in.vob", "vob", "o.mpg", false, Some(&plan)).join(" ");
        assert!(!without.contains("-bsf:s"), "{without}");
        assert!(continuous_copy_args("in.vob", "vob", "o.mpg", true, Some(&plan)).join(" ").contains("-bsf:s:0 "));
    }

    fn scan_of(resets: usize, video: u64) -> ContinuityScan {
        ContinuityScan {
            format: "mpeg".into(),
            applies: true,
            resets: (0..resets)
                .map(|i| Reset {
                    stream: 0,
                    codec_type: "video".into(),
                    packet: 150 * (i as u64 + 1),
                    from: 6.46,
                    to: 0.5,
                })
                .collect(),
            video_packets: video,
            join: None,
        }
    }

    #[test]
    fn a_copy_is_refused_with_a_reset_left_or_a_packet_missing() {
        let src = scan_of(1, 300);
        assert_eq!(copy_problem(&src, &scan_of(0, 300)), None);
        assert!(copy_problem(&src, &scan_of(1, 300)).unwrap().contains("reset"));
        assert!(copy_problem(&src, &scan_of(0, 299)).unwrap().contains("299"));
    }

    #[test]
    fn needs_copy_only_with_a_reset_in_an_applicable_format() {
        assert!(scan_of(1, 300).needs_copy());
        assert!(!scan_of(0, 300).needs_copy());
        let mut s = scan_of(1, 300);
        s.applies = false;
        assert!(!s.needs_copy());
        assert!(scan_of(2, 450).summary().contains("picture 150"));
    }

    #[test]
    fn streams_are_read_from_the_probe() {
        let j = serde_json::json!({
            "streams": [{"index": 0, "codec_type": "video"}, {"index": 1, "codec_type": "audio"}],
            "format": {"format_name": "mpeg"}
        });
        let (f, t) = streams_from_probe(&j);
        assert_eq!(f, "mpeg");
        assert_eq!(t.get(&1).map(String::as_str), Some("audio"));
    }

    fn tmp(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "vb_continuity_{}_{}",
            name,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn an_import_without_a_reset_is_renamed_untouched() {
        let d = tmp("plain");
        let (part, out) = (d.join("t.mpg.part"), d.join("t.mpg"));
        std::fs::write(&part, b"abc").unwrap();
        let o = finish_import(&part, &out, |_| Ok(scan_of(0, 3)), |_| panic!("no join")).unwrap();
        assert!(matches!(o, ImportOutcome::Unchanged));
        assert_eq!(std::fs::read(&out).unwrap(), b"abc");
        assert!(!part.exists());
    }

    #[test]
    fn an_import_with_a_reset_is_joined_and_the_part_removed() {
        let d = tmp("joined");
        let (part, out) = (d.join("t.mpg.part"), d.join("t.mpg"));
        std::fs::write(&part, b"abc").unwrap();
        let o = finish_import(&part, &out, |_| Ok(scan_of(1, 3)), |_| {
            std::fs::write(&out, b"joined").unwrap();
            Ok(scan_of(0, 3))
        })
        .unwrap();
        match o {
            ImportOutcome::Joined(s) => assert_eq!(s.resets.len(), 1, "reports the source's resets"),
            _ => panic!("not joined"),
        }
        assert_eq!(std::fs::read(&out).unwrap(), b"joined");
        assert!(!part.exists());
    }

    #[test]
    fn a_failed_join_or_scan_keeps_the_extraction() {
        let d = tmp("kept");
        let (part, out) = (d.join("t.mpg.part"), d.join("t.mpg"));
        std::fs::write(&part, b"abc").unwrap();
        let o = finish_import(&part, &out, |_| Ok(scan_of(1, 3)), |_| bail!("muxer said no")).unwrap();
        match o {
            ImportOutcome::Kept(why) => assert!(why.contains("muxer said no"), "{why}"),
            _ => panic!("not kept"),
        }
        assert_eq!(std::fs::read(&out).unwrap(), b"abc");

        std::fs::write(&part, b"def").unwrap();
        let o = finish_import(&part, &out, |_| bail!("no ffprobe"), |_| panic!("no join")).unwrap();
        assert!(matches!(o, ImportOutcome::Kept(_)));
        assert_eq!(std::fs::read(&out).unwrap(), b"def");
    }
}
