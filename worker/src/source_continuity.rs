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
//! **Frame N is the Nth slot of the continuous timeline, with each segment
//! following the last exactly as ffmpeg's correction joins them.** A source
//! with a reset is stream-copied once, in its own container and without
//! `-copyts`, so that correction rewrites the timestamps continuously (one
//! offset per segment, for every stream alike, so sync inside a segment is
//! kept), and everything decodes the copy. A source without one is never
//! copied, and its every argument stays as it was.
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

/// ffprobe's arguments (before the input) for every packet's stream and DTS,
/// one `stream_index,dts_time` line each: the whole file is read, so the
/// output is kept to what the rule needs (~0.7 s for 90k packets).
pub const PACKETS_PROBE_ARGS: [&str; 6] = [
    "-v", "error",
    "-show_entries", "packet=stream_index,dts_time",
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
        if video.is_empty() {
            format!("{} timestamp reset(s) in the sound", self.resets.len())
        } else {
            format!("timestamps reset at {}", video.join(", "))
        }
    }
}

/// Whether ffprobe's `format_name` is one ffmpeg treats as discontinuous and
/// seeks by timestamp (MPEG-TS/PS).
pub fn applies_to(format_name: &str) -> bool {
    format_name
        .split(',')
        .any(|n| TIMESTAMP_SEARCH_FORMATS.contains(&n.trim()))
}

/// The resets in a packet list (`stream_index,dts_time` lines, in file
/// order), for the audio and video streams in `types` (index -> codec type).
/// Per stream, in decode order: a DTS more than [`RESET_BACKWARD_SECS`]
/// behind the stream's last, or more than [`RESET_FORWARD_SECS`] ahead.
/// Packets without a DTS are skipped (a program stream leaves some out). A
/// 33-bit wrap never shows: the demuxer unwraps it before ffprobe prints.
pub fn resets_from_packets(csv: &str, types: &HashMap<u32, String>) -> (Vec<Reset>, u64) {
    let mut last: HashMap<u32, f64> = HashMap::new();
    let mut counts: HashMap<u32, u64> = HashMap::new();
    let mut resets = Vec::new();
    let mut video_packets = 0u64;
    for line in csv.lines() {
        let mut fields = line.split(',');
        let Some(stream) = fields.next().and_then(|s| s.trim().parse::<u32>().ok()) else {
            continue;
        };
        let Some(kind) = types.get(&stream) else { continue };
        if kind != "video" && kind != "audio" {
            continue;
        }
        let count = counts.entry(stream).or_insert(0);
        let packet = *count;
        *count += 1;
        if kind == "video" {
            video_packets += 1;
        }
        let Some(dts) = fields
            .next()
            .and_then(|s| s.trim().parse::<f64>().ok())
            .filter(|t| t.is_finite())
        else {
            continue;
        };
        if let Some(&prev) = last.get(&stream) {
            let step = dts - prev;
            if step < -RESET_BACKWARD_SECS || step > RESET_FORWARD_SECS {
                resets.push(Reset {
                    stream,
                    codec_type: kind.clone(),
                    packet,
                    from: prev,
                    to: dts,
                });
            }
        }
        last.insert(stream, dts);
    }
    (resets, video_packets)
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
    if !applies_to(&format) {
        return Ok(ContinuityScan { format, applies: false, resets: vec![], video_packets: 0 });
    }
    let out = Command::new(ffprobe)
        .args(PACKETS_PROBE_ARGS)
        .arg(input)
        .envs(env)
        .stderr(Stdio::null())
        .output()
        .context("failed to run ffprobe")?;
    if !out.status.success() {
        bail!("ffprobe could not list the packets of {}", input);
    }
    let (resets, video_packets) = resets_from_packets(&String::from_utf8_lossy(&out.stdout), &types);
    Ok(ContinuityScan { format, applies: true, resets, video_packets })
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
) -> Vec<String> {
    let mut args: Vec<String> = ["-hide_banner", "-nostdin", "-y", "-v", "error", "-i", input]
        .iter()
        .map(|s| s.to_string())
        .collect();
    args.extend(["-map", "0:v", "-map", "0:a?"].iter().map(|s| s.to_string()));
    if with_subtitles {
        args.extend(["-map", "0:s?"].iter().map(|s| s.to_string()));
    }
    args.extend(
        ["-c", "copy", "-map_metadata", "0", "-progress", "pipe:1", "-nostats", "-f", muxer, output]
            .iter()
            .map(|s| s.to_string()),
    );
    args
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
                .args(continuous_copy_args(input, muxer, &out_str, with_subtitles))
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
        let a = continuous_copy_args("in.vob", "vob", "out.mpg", true);
        let s = a.join(" ");
        assert!(!s.contains("copyts"), "{s}");
        assert!(s.contains("-map 0:v -map 0:a? -map 0:s? -c copy -map_metadata 0"), "{s}");
        assert!(s.ends_with("-f vob out.mpg"), "{s}");
        let t = continuous_copy_args("in.ts", "mpegts", "out.ts", false).join(" ");
        assert!(!t.contains("0:s?"), "{t}");
        assert!(t.ends_with("-f mpegts out.ts"), "{t}");
        // No -muxdelay: the copy keeps the source's start time.
        assert!(!t.contains("muxdelay"), "{t}");
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
