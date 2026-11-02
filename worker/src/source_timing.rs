//! Variable-frame-rate sources (issue #137): where each stored frame falls on
//! the constant-rate grid the pipeline works on.
//!
//! Everything after the decoder assumes constant frame rate: pipe_source builds
//! a fixed-rate clip, FlowFPS/RIFE retime by a fixed ratio, the encoder stamps
//! one rate. A phone or screen recording is not like that — it drops its rate
//! when the scene gets dark or busy, so its stored frames sit at irregular times.
//!
//! Left to itself, the decoder ffmpeg (writing `rawvideo`) fills each gap by
//! repeating a frame, and the job's frame count — ffprobe's `nb_frames`, the
//! number of *stored* frames — then cut the repeated-into-existence tail off.
//! The result was a video shorter than its audio, with frozen frames wherever
//! the camera had slowed down, which interpolation turned into visible stutter:
//! FlowFPS and RIFE animate between two identical frames, then catch up.
//!
//! So for a VFR source the worker reads the stored frames' timestamps, decodes
//! them as they are (`-fps_mode passthrough`) and places them on the grid in the
//! script itself. That makes the gaps known: a grid slot with no frame of its
//! own repeats the one before it — exactly as before, no invented pixels — unless
//! the Frame Rate pass is synthesizing frames anyway, in which case the slot is
//! interpolated at its true position between its neighbours.
//!
//! The grid is `job.input_frame_rate`, the same rate the app shows and trims in.
//! A source whose frames all land on it gets no timeline at all, so a CFR job's
//! decode and script are exactly what they were.

use std::path::Path;
use std::process::{Command, Stdio};

/// Relative difference between `r_frame_rate` and `avg_frame_rate` below which
/// a source is taken to be constant-rate without reading its timestamps.
/// Reading them means demuxing the whole file, so this keeps that cost to the
/// sources that can need it. A container's average often differs from its
/// nominal rate by duration rounding; anything that passes this gate is then
/// confirmed against the real timestamps, so a false positive only costs time.
/// The app's `FieldOrderDetector.isVariableRate` uses the same threshold.
pub const VFR_RATE_TOLERANCE: f64 = 0.0002;

/// Whether ffprobe's two rates say the timestamps are worth reading.
///
/// Field-coded interlaced H.264 reports `r_frame_rate` at the field rate, twice
/// `avg_frame_rate` (issue #13); that is a constant rate, not a variable one.
pub fn rates_suggest_vfr(r_frame_rate: f64, avg_frame_rate: f64) -> bool {
    if r_frame_rate <= 0.0 || avg_frame_rate <= 0.0 {
        return false;
    }
    let ratio = r_frame_rate / avg_frame_rate;
    if ratio > 1.8 && ratio < 2.2 {
        return false;
    }
    ((r_frame_rate - avg_frame_rate) / r_frame_rate).abs() > VFR_RATE_TOLERANCE
}

/// One grid slot: which stored frame shows at that time, and, if the slot is a
/// gap, how far it sits between that frame and the next.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Slot {
    /// Index of the stored frame showing at this slot's time.
    pub src: u32,
    /// For a gap slot (one whose frame was already shown by the slot before),
    /// its position between `src` and `src + 1`, in (0, 1). `None` for a slot
    /// that has a frame of its own, or a gap after the last frame.
    pub gap_position: Option<f64>,
}

/// A source's stored frames placed on a constant-rate grid.
#[derive(Debug, Clone)]
pub struct SourceTimeline {
    /// Stored frame times in seconds, ascending, as the container reports them.
    times: Vec<f64>,
    /// The input's start time: `-ss` positions are relative to it.
    start_time: f64,
    slots: Vec<Slot>,
}

impl SourceTimeline {
    /// Place `times` (stored frame presentation times, seconds, any order) on a
    /// grid of `fps_num/fps_den` starting at the first frame.
    ///
    /// Slot `i` shows the last frame due by the middle of the slot — the same
    /// rounding a CFR conversion uses, so on a constant-rate source every slot
    /// gets its own frame and this returns `None`: there is nothing to correct.
    pub fn build(times: &[f64], start_time: f64, fps_num: u32, fps_den: u32) -> Option<Self> {
        if times.len() < 2 || fps_num == 0 || fps_den == 0 {
            return None;
        }
        let mut times = times.to_vec();
        times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        if times.iter().any(|t| !t.is_finite()) {
            return None;
        }

        let period = fps_den as f64 / fps_num as f64;
        let t0 = times[0];
        // The last frame is shown for one typical interval: the median, so a
        // single long gap before it doesn't stretch the end.
        let mut deltas: Vec<f64> = times.windows(2).map(|w| w[1] - w[0]).filter(|d| *d > 0.0).collect();
        if deltas.is_empty() {
            return None;
        }
        deltas.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let typical = deltas[deltas.len() / 2];
        let end = times[times.len() - 1] + typical;
        let count = (((end - t0) / period).round() as usize).max(1);

        let mut slots = Vec::with_capacity(count);
        let mut k = 0usize;
        let mut previous: Option<usize> = None;
        for i in 0..count {
            let t = t0 + i as f64 * period;
            while k + 1 < times.len() && times[k + 1] <= t + period / 2.0 {
                k += 1;
            }
            let gap_position = if previous == Some(k) && k + 1 < times.len() {
                let span = times[k + 1] - times[k];
                (span > 0.0).then(|| ((t - times[k]) / span).clamp(0.01, 0.99))
            } else {
                None
            };
            slots.push(Slot { src: k as u32, gap_position });
            previous = Some(k);
        }

        let regular = slots.len() == times.len()
            && slots.iter().enumerate().all(|(i, s)| s.src as usize == i);
        if regular {
            return None;
        }
        Some(Self { times, start_time, slots })
    }

    /// Number of grid slots: the source's length in frames at the grid rate.
    pub fn slot_count(&self) -> usize {
        self.slots.len()
    }

    /// Number of stored frames.
    pub fn stored_count(&self) -> usize {
        self.times.len()
    }

    /// Slots that have no stored frame of their own.
    pub fn gap_count(&self) -> usize {
        let mut gaps = 0;
        for i in 1..self.slots.len() {
            if self.slots[i].src == self.slots[i - 1].src {
                gaps += 1;
            }
        }
        gaps
    }

    /// The window an encode decodes: the job's trim, in grid slots, clamped to
    /// the source. `start`/`end` are inclusive, as on `VideoJob`.
    pub fn window_for_trim(&self, start: Option<i32>, end: Option<i32>) -> TimelineWindow {
        let last = self.slots.len() - 1;
        let first = start.unwrap_or(0).max(0) as usize;
        let first = first.min(last);
        let end = end.map(|e| (e.max(0) as usize).min(last)).unwrap_or(last).max(first);
        self.window(first, end)
    }

    /// Slots `first..=last` (clamped), with the stored frames they need.
    pub fn window(&self, first: usize, last: usize) -> TimelineWindow {
        let max = self.slots.len() - 1;
        let first = first.min(max);
        let last = last.clamp(first, max);
        let slots = &self.slots[first..=last];

        let src_first = slots[0].src;
        // One frame past the last slot's, when there is one: a gap slot is
        // interpolated towards it.
        let src_last = (slots[slots.len() - 1].src + 1).min(self.times.len() as u32 - 1);
        let seek_time = (src_first > 0).then(|| {
            let i = src_first as usize;
            // Midway between the frame before and the first one wanted, so the
            // decoder's accurate seek keeps exactly `src_first` regardless of
            // timestamp rounding.
            ((self.times[i - 1] + self.times[i]) / 2.0 - self.start_time).max(0.0)
        });

        TimelineWindow {
            src_count: src_last - src_first + 1,
            seek_time,
            slots: slots
                .iter()
                .map(|s| Slot { src: s.src - src_first, gap_position: s.gap_position })
                .collect(),
        }
    }
}

/// The part of a timeline one decode covers, with stored-frame indices
/// relative to the first frame decoded.
#[derive(Debug, Clone, PartialEq)]
pub struct TimelineWindow {
    /// Stored frames to decode.
    pub src_count: u32,
    /// `-ss` for the decoder (relative to the input's start), or `None` to
    /// decode from the beginning.
    pub seek_time: Option<f64>,
    pub slots: Vec<Slot>,
}

impl TimelineWindow {
    /// The slot-to-frame map as a Python dict of the slots where it does NOT
    /// simply advance by one frame: the template rebuilds the rest. Gaps and
    /// skipped frames are rare next to the frames that land in their own slot,
    /// so this stays small even for a feature-length source.
    pub fn python_jumps(&self) -> String {
        let mut entries = Vec::new();
        let mut previous: i64 = -1;
        for (i, slot) in self.slots.iter().enumerate() {
            if slot.src as i64 != previous + 1 {
                entries.push(format!("{}: {}", i, slot.src));
            }
            previous = slot.src as i64;
        }
        format!("{{{}}}", entries.join(", "))
    }

    /// The gap slots as a Python dict of slot -> `mv.FlowInter` `time` (a
    /// percentage, whole numbers so the template builds one FlowInter per
    /// distinct position rather than one per gap).
    pub fn python_gap_times(&self) -> String {
        let entries: Vec<String> = self
            .slots
            .iter()
            .enumerate()
            .filter_map(|(i, s)| {
                s.gap_position
                    .map(|p| format!("{}: {}", i, ((p * 100.0).round() as i32).clamp(1, 99)))
            })
            .collect();
        format!("{{{}}}", entries.join(", "))
    }
}

/// Parse an ffprobe rational ("30000/1001", "25/1", "0/0").
fn parse_rational(s: &str) -> Option<f64> {
    let (n, d) = s.trim().split_once('/')?;
    let (n, d) = (n.parse::<f64>().ok()?, d.parse::<f64>().ok()?);
    (d != 0.0 && n > 0.0).then(|| n / d)
}

/// Parse `ffprobe -show_entries packet=pts_time,flags -of csv=p=0` output into
/// presentation times, skipping packets the demuxer marks to be discarded (an
/// MP4 edit list's pre-roll), which the decoder never outputs. `None` if any
/// kept packet has no timestamp — the times can't be trusted then, and the
/// source keeps the old constant-rate decode.
pub fn parse_packet_times(csv: &str) -> Option<Vec<f64>> {
    let mut times = Vec::new();
    for line in csv.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let (pts, flags) = line.split_once(',').unwrap_or((line, ""));
        if flags.contains('D') {
            continue;
        }
        times.push(pts.trim().parse::<f64>().ok()?);
    }
    Some(times)
}

/// Read a source's timeline, or `None` if it is constant-rate (or can't be
/// read, in which case it is decoded as before).
pub fn probe(
    ffprobe: &Path,
    env: &std::collections::HashMap<String, String>,
    input: &str,
    fps: f64,
    log: impl Fn(&str),
) -> Option<SourceTimeline> {
    let out = Command::new(ffprobe)
        .args([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=r_frame_rate,avg_frame_rate:format=start_time",
            "-of", "json",
            input,
        ])
        .envs(env)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    let stream = json.get("streams")?.get(0)?;
    let r = parse_rational(stream.get("r_frame_rate")?.as_str()?)?;
    let avg = parse_rational(stream.get("avg_frame_rate")?.as_str()?)?;
    if !rates_suggest_vfr(r, avg) {
        return None;
    }
    let start_time = json
        .get("format")
        .and_then(|f| f.get("start_time"))
        .and_then(|s| s.as_str())
        .and_then(|s| s.parse::<f64>().ok());

    log(&format!(
        "Source may have a variable frame rate (r_frame_rate {:.3}, average {:.3}); reading its frame timestamps",
        r, avg
    ));
    let out = Command::new(ffprobe)
        .args([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,flags",
            "-of", "csv=p=0",
            input,
        ])
        .envs(env)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let times = parse_packet_times(&String::from_utf8_lossy(&out.stdout))?;
    let first = times.iter().cloned().fold(f64::INFINITY, f64::min);
    let (num, den) = crate::models::fps_to_rational(fps);
    let timeline = SourceTimeline::build(
        &times,
        start_time.unwrap_or(first),
        num.max(0) as u32,
        den.max(0) as u32,
    );
    match &timeline {
        Some(t) => log(&format!(
            "Variable frame rate: {} stored frames over {} frames at {:.3} fps ({} gaps)",
            t.stored_count(),
            t.slot_count(),
            fps,
            t.gap_count()
        )),
        None => log("Frame timestamps are regular; decoding as constant frame rate"),
    }
    timeline
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfr(n: usize, fps: f64) -> Vec<f64> {
        (0..n).map(|i| i as f64 / fps).collect()
    }

    /// 30 fps for `a` frames, then every third frame missing (20 fps) for `b`
    /// more slots — the shape of a phone slowing down in the dark.
    fn slowing(a: usize, b: usize) -> Vec<f64> {
        let mut t = cfr(a, 30.0);
        for i in a..a + b {
            if i % 3 != 2 {
                t.push(i as f64 / 30.0);
            }
        }
        t
    }

    #[test]
    fn constant_rate_needs_no_timeline() {
        assert!(SourceTimeline::build(&cfr(300, 30.0), 0.0, 30, 1).is_none());
        // NTSC rates, with the millisecond rounding containers store.
        let ntsc: Vec<f64> = (0..300).map(|i| (i as f64 * 1001.0 / 30000.0 * 1000.0).round() / 1000.0).collect();
        assert!(SourceTimeline::build(&ntsc, 0.0, 30000, 1001).is_none());
        // Packets arrive in decode order; that is not a gap.
        let mut shuffled = cfr(30, 25.0);
        shuffled.swap(3, 5);
        assert!(SourceTimeline::build(&shuffled, 0.0, 25, 1).is_none());
    }

    #[test]
    fn gaps_become_slots_that_repeat_the_frame_before() {
        let t = SourceTimeline::build(&slowing(150, 149), 0.0, 30, 1).unwrap();
        assert_eq!(t.stored_count(), 250);
        // The whole duration, not the stored count: 299 slots of 1/30 s.
        assert_eq!(t.slot_count(), 299);
        assert_eq!(t.gap_count(), 49);
        let w = t.window_for_trim(None, None);
        assert_eq!(w.slots.len(), 299);
        assert_eq!(w.src_count, 250);
        // Slots 0..150 map one-to-one; slot 152 (a dropped frame) repeats 151.
        assert!(w.slots[..150].iter().enumerate().all(|(i, s)| s.src as usize == i && s.gap_position.is_none()));
        assert_eq!(w.slots[152].src, 151);
        let p = w.slots[152].gap_position.unwrap();
        // 151 is at 151/30, 152 (stored index) at 153/30: slot 152 is halfway.
        assert!((p - 0.5).abs() < 1e-9, "{p}");
        assert_eq!(w.slots[153].src, 152);
        assert!(w.slots[153].gap_position.is_none());
    }

    #[test]
    fn python_maps_round_trip() {
        let t = SourceTimeline::build(&slowing(6, 7), 0.0, 30, 1).unwrap();
        let w = t.window_for_trim(None, None);
        // Rebuild the map the way the template does and compare.
        let jumps = w.python_jumps();
        let parsed: std::collections::HashMap<usize, u32> = jumps
            .trim_matches(|c| c == '{' || c == '}')
            .split(", ")
            .filter(|e| !e.is_empty())
            .map(|e| {
                let (a, b) = e.split_once(": ").unwrap();
                (a.parse().unwrap(), b.parse().unwrap())
            })
            .collect();
        let mut k: i64 = -1;
        for (i, slot) in w.slots.iter().enumerate() {
            k = parsed.get(&i).map(|v| *v as i64).unwrap_or(k + 1);
            assert_eq!(k, slot.src as i64, "slot {i}");
        }
        assert_eq!(w.python_gap_times(), "{8: 50, 11: 50}");
    }

    #[test]
    fn a_trim_window_decodes_only_what_it_needs() {
        let t = SourceTimeline::build(&slowing(150, 149), 0.0, 30, 1).unwrap();
        let w = t.window_for_trim(Some(200), Some(209));
        assert_eq!(w.slots.len(), 10);
        // Slot 200 shows stored frame 183 (150 + 2/3 of 50 after the drops).
        assert_eq!(w.slots[0].src, 0);
        assert_eq!(t.slots[200].src, 183);
        let seek = w.seek_time.unwrap();
        assert!(seek > t.times[182] && seek < t.times[183], "{seek}");
        // Up to the frame after the last slot's, for interpolation.
        assert_eq!(w.src_count, t.slots[209].src - 183 + 2);
        // Trims beyond the end clamp rather than panic.
        let w = t.window_for_trim(Some(290), Some(10_000));
        assert_eq!(w.slots.len(), t.slot_count() - 290);
        assert!(t.window_for_trim(None, None).seek_time.is_none());
    }

    #[test]
    fn seek_is_relative_to_the_input_start() {
        let times: Vec<f64> = slowing(30, 30).iter().map(|t| t + 10.0).collect();
        let t = SourceTimeline::build(&times, 10.0, 30, 1).unwrap();
        let w = t.window(31, 40);
        let seek = w.seek_time.unwrap();
        assert!(seek > 0.9 && seek < 1.1, "{seek}");
    }

    #[test]
    fn rate_gate() {
        assert!(!rates_suggest_vfr(30.0, 30.0));
        assert!(!rates_suggest_vfr(30000.0 / 1001.0, 29.97));
        assert!(rates_suggest_vfr(30.0, 25.2));
        // Field-coded interlaced: field rate vs picture rate, constant.
        assert!(!rates_suggest_vfr(50.0, 25.0));
        assert!(!rates_suggest_vfr(30.0, 0.0));
    }

    #[test]
    fn packet_csv() {
        let csv = "0.000000,K__\n0.033333,___\n-0.033333,_D_\n0.066667,___\n";
        assert_eq!(parse_packet_times(csv).unwrap(), vec![0.0, 0.033333, 0.066667]);
        assert!(parse_packet_times("0.0,K__\nN/A,___\n").is_none());
    }
}
