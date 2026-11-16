//! Audio restoration: renders the output's audio track before the encode.
//!
//! VapourBox's picture goes through VapourSynth; its sound never did — the
//! encoder copied or re-encoded the source's audio. This pass changes that for
//! one audio stream, and does it **before** the video encode, into a WAV the
//! encoder then maps in place of the source's stream:
//!
//! ```text
//! source ──ffmpeg (restore chain)──► a.wav ──[deep-filter]──► b.wav ──ffmpeg (loudness, limiter)──► restored.wav
//!                                                                                     │
//!   transcribe restored.wav (Whisper) ◄──────────────────────────────────────────────┤
//!   encode: video from vspipe + restored.wav (+ the source's other audio streams)  ◄─┘
//! ```
//!
//! Rendering first, rather than adding an `-af` to the encode, is what makes
//! the rest possible: DeepFilterNet is a separate program; two-pass loudness
//! normalisation needs the whole track measured before any of it is written;
//! a negative sync offset needs audio from *before* the trim point; and the
//! subtitles transcribe the rendered file, which is the output's soundtrack
//! sample for sample, so their cues line up whatever offset, drift or trim was
//! applied. It also leaves the audio independent of how the video encode is
//! run (a segmented encode can map the same file).
//!
//! **One decision site.** Every filter is chosen by [`AudioPlan::new`], in one
//! fixed order, and each ffmpeg run gets exactly one `-af`, joined from its
//! share of that list — the same rule as the encoder's `-vf` chain, for the
//! same reason (ffmpeg honours only the last `-af`).
//!
//! The order, and why:
//! 1. `aresample=first_pts=0` — pads the start when the audio stream begins
//!    after the video does (common in captures). Mapping the source's stream
//!    straight into the output kept that gap through its timestamps; a WAV has
//!    none, so it must be made of samples.
//!    1a. On a delayed AVI read from near its start (`source_decode` rule 9),
//!    where an input `-ss` fails and loses ~1.3 s of sound, the read starts
//!    at 0 and `atrim=start_sample` + `asetpts` drop the head here: after
//!    the padding (so the count is on the container timeline) and before the
//!    drift resample (the read point is in source time). Not an output
//!    `-ss`: ffmpeg trims an output after the whole `-af` chain, whose own
//!    trims and padding would move the cut.
//! 2. channel fix (`pan`) — before anything measures or filters the channels.
//! 3. `adeclip` — first of the repairs: it reconstructs peaks from the shape
//!    of the clipped waveform, which any filter ahead of it would change.
//! 4. `adeclick` — impulses, before the filters below smear them.
//! 5. rumble `highpass`, 6. hum notches (`bandreject` at f, 2f, 3f).
//! 7. `afftdn`, then `atrim` of its delay: it puts out its input 25 ms late
//!    at every sample rate and strength (measured: 1200 samples at 48 kHz,
//!    1102 at 44.1, 800 at 32). Its noise floor (`nf`) is the source's,
//!    measured: at its −50 dB default it took 0.7 dB off −39 dB hiss, with
//!    the measured floor 13.6 dB; and its noise tracking (`tn`) undid that.
//! 8. timing — drift is corrected by resampling (`aresample` up, `asetrate`
//!    to relabel by the exact ratio, `aresample` back), not `atempo`: atempo
//!    moved every click ~20 ms early, and drift *is* a sample-clock error,
//!    so resampling restores the original pitch as well as the length. Then
//!    a silent lead (`adelay`) where a positive offset reaches before the
//!    start; a negative one just reads later.
//! 9. DeepFilterNet (a separate program, `-D` compensates its 30 ms delay).
//! 10. `loudnorm` (two passes, linear), `aresample` back from its 192 kHz.
//! 11. `alimiter` with `latency=1` (otherwise it delays by its attack time)
//!     and `level=0` (otherwise it normalises back up to 0 dBFS).
//! 12. `apad` + `atrim` to exactly the picture's length.

use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use anyhow::{bail, Context, Result};

use crate::dependency_locator::DependencyLocator;
use crate::models::{
    AudioMode, AudioRestorationParameters, ChannelFix, ContainerFormat,
    EncodingSettings, HumFrequency, LogLevel, ProgressInfo, VideoCodec, VideoJob,
};
use crate::progress_reporter::ProgressReporter;

/// The feature name the DeepFilterNet add-on refusal starts with.
pub const DEEP_FILTER_FEATURE: &str = "Speech enhancement (DeepFilterNet)";

/// DeepFilterNet works at 48 kHz and writes 48 kHz whatever it is given.
pub const DEEP_FILTER_RATE: u32 = 48_000;

/// `afftdn`'s output delay, as a fraction of a second (measured, see above).
pub const AFFTDN_DELAY_SECONDS: f64 = 0.025;

/// Drift smaller than this is left alone: under two frames, and within the
/// accuracy of a container's stated durations.
pub const DRIFT_MIN_SECONDS: f64 = 0.05;

/// A drift factor this close to 1 is not applied: the resample would still
/// run, for nothing.
pub const TEMPO_EPSILON: f64 = 1e-6;

/// Loudness normalisation's true-peak ceiling and loudness range: the
/// widely used streaming values. Only the integrated target is a setting.
pub const LOUDNORM_TRUE_PEAK: f64 = -1.5;
pub const LOUDNORM_RANGE: f64 = 11.0;

/// How much audio the automatic checks (channels, hum, noise floor) look at,
/// and the highest rate they decode it at (the noise floor needs the whole
/// band: white hiss is 8 dB quieter below 4 kHz than across 24).
pub const ANALYSIS_SECONDS: f64 = 60.0;
pub const ANALYSIS_MAX_RATE: u32 = 48_000;

/// `afftdn`'s noise floor is the quietest tenth of 50 ms windows, clamped to
/// what it accepts (-80) and to -30: a "floor" louder than that is the
/// content itself (music with no pauses), which afftdn would eat.
pub const NOISE_FLOOR_PERCENTILE: f64 = 0.10;
pub const NOISE_FLOOR_RANGE: (f64, f64) = (-80.0, -30.0);

/// Extra source audio read past the end, so the filters that trim their own
/// delay off the front still fill the window.
const READ_MARGIN_SECONDS: f64 = 1.0;

/// Notch width (Q) for the hum filters: about 6 Hz wide at 50 Hz.
const HUM_Q: f64 = 8.0;

// ---------------------------------------------------------------------------
// What is known about the source and the output
// ---------------------------------------------------------------------------

/// The source's audio, as probed.
#[derive(Debug, Clone, PartialEq)]
pub struct SourceAudio {
    /// How many audio streams the source has.
    pub streams: u32,
    /// The restored stream's channel count and sample rate.
    pub channels: u32,
    pub sample_rate: u32,
    /// The restored stream's duration in seconds, when stated or measured.
    pub duration: Option<f64>,
}

/// The span of the output on the source's timeline: where the picture starts
/// (the trim's in-point) and how long the encoded picture is.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OutputWindow {
    pub start: f64,
    /// `None` when the length is unknown: the audio then runs to its end.
    pub duration: Option<f64>,
    /// The source's decoder delay in frames (`VideoJob::decoder_delay`):
    /// non-zero only for an AVI that stores decode-order timestamps, which
    /// cannot seek its sound near its start (`source_decode` rule 9).
    pub decoder_delay: u32,
}

impl OutputWindow {
    /// The window a job's picture covers: from its in-point, as long as the
    /// encoded video (its output frame count over its output rate, from the
    /// pipeline's `FrameMap`s — not the source's count, which double-rate
    /// deinterlacing, IVTC and frame-rate conversion all change).
    ///
    /// Both are on the source's container timeline, which is what the render's
    /// `-ss` counts from. When the output keeps a source's sound-first layout
    /// (`VideoJob::output_video_delay`), the window starts at the container's
    /// start and is that much longer; otherwise it starts at the in-point's
    /// picture, the video's start offset included.
    pub fn for_job(job: &VideoJob) -> Self {
        let fps = job.input_frame_rate.unwrap_or(29.97);
        let start = job.source_audio_start();
        let delay = job.output_video_delay();
        let duration = job
            .total_frames
            .filter(|n| *n > 0)
            .and_then(|n| job.effective_pipeline().output_duration_secs(n as u64, fps))
            .map(|d| d + delay);
        Self { start, duration, decoder_delay: job.decoder_delay() }
    }
}

/// The job-log note for "start the sound with the picture".
pub fn start_with_picture_note(video_start: f64) -> String {
    if video_start > 0.0 {
        format!("Start with the picture: the {video_start:.3} s of sound before the first picture is dropped.")
    } else {
        "Start with the picture: the sound already starts with the picture; nothing dropped.".to_string()
    }
}

/// Which channel of a stereo pair is dead.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeadChannel {
    Left,
    Right,
}

/// What the automatic checks found, on a sample of the window.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Analysis {
    pub dead_channel: Option<DeadChannel>,
    /// 50 or 60 when a mains hum stands out of the spectrum.
    pub hum: Option<u32>,
    /// The noise floor in dBFS (for `afftdn`), when measured.
    pub noise_floor_db: Option<f64>,
}



/// A channel is dead when it is this far below the other…
pub const DEAD_CHANNEL_GAP_DB: f64 = 30.0;
/// …and the other carries something.
pub const LIVE_CHANNEL_MIN_DB: f64 = -60.0;

/// Which channel to replace, from each channel's RMS level in dBFS.
pub fn dead_channel(left_db: f64, right_db: f64) -> Option<DeadChannel> {
    let (loud, quiet) = if left_db >= right_db { (left_db, right_db) } else { (right_db, left_db) };
    if loud < LIVE_CHANNEL_MIN_DB || loud - quiet < DEAD_CHANNEL_GAP_DB {
        return None;
    }
    Some(if left_db < right_db { DeadChannel::Left } else { DeadChannel::Right })
}

/// RMS level in dBFS of each channel of interleaved samples.
pub fn channel_levels_db(interleaved: &[f32], channels: usize) -> Vec<f64> {
    let channels = channels.max(1);
    let frames = interleaved.len() / channels;
    (0..channels)
        .map(|c| {
            let sum: f64 = (0..frames).map(|i| (interleaved[i * channels + c] as f64).powi(2)).sum();
            let rms = (sum / frames.max(1) as f64).sqrt();
            20.0 * (rms + 1e-12).log10()
        })
        .collect()
}

/// The noise floor of `mono` in dBFS: the [`NOISE_FLOOR_PERCENTILE`] quietest
/// 50 ms window's RMS level, clamped to [`NOISE_FLOOR_RANGE`] (digital
/// silence reads as the bottom of the range).
pub fn noise_floor_db(mono: &[f32], rate: u32) -> f64 {
    let win = (rate as usize / 20).max(1);
    let mut levels: Vec<f64> = mono
        .chunks_exact(win)
        .map(|w| {
            let rms = (w.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / win as f64).sqrt();
            20.0 * (rms + 1e-12).log10()
        })
        .collect();
    if levels.is_empty() {
        return NOISE_FLOOR_RANGE.0;
    }
    levels.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let idx = ((levels.len() - 1) as f64 * NOISE_FLOOR_PERCENTILE).round() as usize;
    levels[idx].clamp(NOISE_FLOOR_RANGE.0, NOISE_FLOOR_RANGE.1)
}

/// The integer rates that resample by `factor` most exactly: upsample to
/// `r1`, relabel as `s` (`asetrate` takes only an integer), resample back.
/// `r1` is searched between 4× and 8× the rate, so the content is never
/// low-passed and the ratio `s / r1` is within ~1e-11 of `factor` — an
/// integer `asetrate` straight from 48 kHz would be off by up to 1e-5, 37 ms
/// over an hour.
pub fn resample_ratio(rate: u32, factor: f64) -> (u32, u32) {
    let mut best = (rate, (rate as f64 * factor).round() as u32);
    let mut best_err = f64::MAX;
    for r1 in rate * 4..=rate * 8 {
        let s = (r1 as f64 * factor).round();
        let err = (s / r1 as f64 - factor).abs();
        if err < best_err {
            best_err = err;
            best = (r1, s as u32);
            if err < 1e-13 {
                break;
            }
        }
    }
    best
}

/// Power at `freq` by the Goertzel algorithm, averaged over 2-second blocks
/// (0.5 Hz resolution: mains frequency wanders by a tenth of a hertz, which a
/// single minute-long transform would resolve right past).
pub fn band_power(x: &[f32], rate: u32, freq: f64) -> f64 {
    let block = (rate as usize) * 2;
    if x.len() < block {
        return goertzel(x, rate, freq);
    }
    let blocks: Vec<f64> = x.chunks_exact(block).map(|b| goertzel(b, rate, freq)).collect();
    blocks.iter().sum::<f64>() / blocks.len() as f64
}

fn goertzel(x: &[f32], rate: u32, freq: f64) -> f64 {
    let n = x.len().max(1) as f64;
    let w = 2.0 * std::f64::consts::PI * freq / rate as f64;
    let coeff = 2.0 * w.cos();
    let (mut s1, mut s2) = (0.0f64, 0.0f64);
    for (i, &v) in x.iter().enumerate() {
        // Hann window, so a strong neighbour does not leak into the bin.
        let win = 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / (n - 1.0).max(1.0)).cos();
        let s = v as f64 * win + coeff * s1 - s2;
        s2 = s1;
        s1 = s;
    }
    (s1 * s1 + s2 * s2 - coeff * s1 * s2) / (n * n)
}

/// How far a hum line must stand above its neighbours, in dB.
pub const HUM_PROMINENCE_DB: f64 = 12.0;

/// How far (dB) the strongest of `f`, 2f and 3f stands above the spectrum
/// either side of it.
pub fn hum_prominence_db(mono: &[f32], rate: u32, mains: f64) -> f64 {
    (1..=3)
        .map(|k| {
            let f = mains * k as f64;
            let peak = band_power(mono, rate, f);
            // Neighbours 4–7 Hz away: outside the notch, inside the band, and
            // clear of the other mains frequency's harmonics.
            let mut refs: Vec<f64> =
                [-7.0, -5.5, -4.0, 4.0, 5.5, 7.0].iter().map(|d| band_power(mono, rate, f + d)).collect();
            refs.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let floor = (refs[2] + refs[3]) / 2.0;
            10.0 * ((peak + 1e-20) / (floor + 1e-20)).log10()
        })
        .fold(f64::MIN, f64::max)
}

/// 50, 60 or nothing: whichever mains frequency's lines stand out more, if
/// either stands out by [`HUM_PROMINENCE_DB`].
pub fn detect_hum(mono: &[f32], rate: u32) -> Option<u32> {
    let p50 = hum_prominence_db(mono, rate, 50.0);
    let p60 = hum_prominence_db(mono, rate, 60.0);
    let (best, p) = if p50 >= p60 { (50, p50) } else { (60, p60) };
    (p >= HUM_PROMINENCE_DB).then_some(best)
}

/// What drift correction will do.
#[derive(Debug, Clone, PartialEq)]
pub enum DriftDecision {
    /// Resample by this factor, audio length / picture length.
    Apply(f64),
    /// Leave it, with the reason for the job log.
    Skip(String),
}

/// Whether to correct drift between an audio track of `audio_secs` and a
/// picture of `video_secs`, refusing anything above `max_percent`.
pub fn drift_decision(audio_secs: f64, video_secs: f64, max_percent: f64) -> DriftDecision {
    if !(audio_secs > 0.0 && video_secs > 0.0) {
        return DriftDecision::Skip("the audio or picture length could not be measured".into());
    }
    let drift = audio_secs - video_secs;
    let factor = audio_secs / video_secs;
    let percent = (factor - 1.0).abs() * 100.0;
    if drift.abs() <= DRIFT_MIN_SECONDS {
        return DriftDecision::Skip(format!(
            "the audio is {:.3} s against the picture's {:.3} s — within {} s, nothing to correct",
            audio_secs, video_secs, DRIFT_MIN_SECONDS
        ));
    }
    if percent > max_percent {
        return DriftDecision::Skip(format!(
            "the audio ({:.3} s) and picture ({:.3} s) differ by {:.2}%, more than the {:.2}% \
             limit — that is not clock drift (a missing stretch of audio, or the wrong track?), \
             so it is left uncorrected",
            audio_secs, video_secs, percent, max_percent
        ));
    }
    if (factor - 1.0).abs() < TEMPO_EPSILON {
        return DriftDecision::Skip("the change would be below 1e-6".into());
    }
    DriftDecision::Apply(factor)
}

// ---------------------------------------------------------------------------
// The plan: every decision, as pure data
// ---------------------------------------------------------------------------

/// Loudness as measured by `loudnorm`'s first pass.
#[derive(Debug, Clone, PartialEq)]
pub struct LoudnessMeasurement {
    pub input_i: f64,
    pub input_tp: f64,
    pub input_lra: f64,
    pub input_thresh: f64,
    pub target_offset: f64,
}

/// Every decision about one job's audio, made up front.
#[derive(Debug, Clone, PartialEq)]
pub struct AudioPlan {
    /// The source audio stream (among audio streams) restored.
    pub stream: u32,
    pub source_rate: u32,
    /// Where to start reading the source (seconds, `-ss` before `-i`).
    pub read_start: f64,
    /// Whether `read_start` is reached by decoding from 0 and dropping it in
    /// the chain (step 1a, `source_decode` rule 9) rather than by `-ss`.
    pub read_skip: bool,
    /// How much to read (`-t`), when the window's length is known.
    pub read_duration: Option<f64>,
    /// The first ffmpeg run's filters, in order.
    pub restore_filters: Vec<String>,
    /// DeepFilterNet's attenuation limit, when it runs.
    pub deep_filter: Option<u32>,
    /// The loudness target, when normalising.
    pub loudness_target: Option<f64>,
    /// The filters after DeepFilterNet / loudness (limiter, length).
    pub finish_filters: Vec<String>,
    /// The rendered track's sample rate and exact length in samples.
    pub out_rate: u32,
    pub out_samples: Option<u64>,
    /// What was decided and why, for the job log.
    pub notes: Vec<String>,
}

impl AudioPlan {
    /// Decide everything. `drift` is the factor to apply, already
    /// vetted by [`drift_decision`].
    pub fn new(
        p: &AudioRestorationParameters,
        source: &SourceAudio,
        window: OutputWindow,
        analysis: &Analysis,
        drift: Option<f64>,
    ) -> Self {
        let rate = source.sample_rate.max(1);
        let mut notes = Vec::new();
        let mut f: Vec<String> = Vec::new();

        // 1. A stream that starts late is padded from the window's start.
        f.push("aresample=first_pts=0".to_string());

        // 2. Channels.
        let fix = match p.channel_fix {
            ChannelFix::Auto => match (source.channels, analysis.dead_channel) {
                (2, Some(DeadChannel::Right)) => {
                    notes.push("Channel fix: the right channel is silent; using the left for both.".into());
                    ChannelFix::LeftOnly
                }
                (2, Some(DeadChannel::Left)) => {
                    notes.push("Channel fix: the left channel is silent; using the right for both.".into());
                    ChannelFix::RightOnly
                }
                (2, None) => {
                    notes.push("Channel fix: both channels carry sound; left as they are.".into());
                    ChannelFix::Off
                }
                _ => ChannelFix::Off,
            },
            other => other,
        };
        if fix != ChannelFix::Off && source.channels != 2 {
            notes.push(format!(
                "Channel fix applies to stereo audio; this stream has {} channel(s), so it is skipped.",
                source.channels
            ));
        } else if let Some(pan) = pan_filter(fix) {
            f.push(pan.to_string());
        }

        // 3–7. Repairs.
        if p.declip {
            f.push("adeclip".to_string());
        }
        if p.declick {
            f.push(format!("adeclick=t={}", num(p.declick_threshold.clamp(1.0, 100.0))));
        }
        if p.rumble_filter {
            f.push(format!("highpass=f={}:poles=2", p.rumble_cutoff_hz.clamp(10, 300)));
        }
        if p.hum_removal {
            let mains = match p.hum_frequency {
                HumFrequency::Hz50 => Some(50),
                HumFrequency::Hz60 => Some(60),
                HumFrequency::Auto => {
                    match analysis.hum {
                        Some(hz) => notes.push(format!("Hum removal: found {hz} Hz mains hum.")),
                        None => notes.push(
                            "Hum removal: no 50 or 60 Hz hum stands out, so nothing is notched.".into(),
                        ),
                    }
                    analysis.hum
                }
            };
            if let Some(hz) = mains {
                for k in 1..=3 {
                    f.push(format!("bandreject=f={}:width_type=q:w={}", hz * k, num(HUM_Q)));
                }
            }
        }
        if p.denoise {
            let floor = analysis.noise_floor_db.unwrap_or(-50.0).round();
            f.push(format!("afftdn=nr={}:nf={}", num(p.denoise_strength.clamp(0.01, 97.0)), num(floor)));
            notes.push(format!("Noise reduction: noise floor {} dB.", num(floor)));
            let delay = (rate as f64 * AFFTDN_DELAY_SECONDS).round() as u64;
            f.push(format!("atrim=start_sample={delay}"));
            f.push("asetpts=PTS-STARTPTS".to_string());
        }

        // 8. Timing. Source time for output time t is (start + t - offset) × factor.
        let tempo = drift.filter(|t| (t - 1.0).abs() >= TEMPO_EPSILON);
        let factor = tempo.unwrap_or(1.0);
        let offset = p.offset_ms as f64 / 1000.0;
        let source_start = (window.start - offset) * factor;
        let (read_start, lead) = if source_start >= 0.0 {
            (source_start, 0.0)
        } else {
            // A delay reaching before the source's start: silence first.
            (0.0, -source_start / factor)
        };
        if let Some(t) = tempo {
            let (r1, s) = resample_ratio(rate, t);
            f.push(format!("aresample={r1}"));
            f.push(format!("asetrate={s}"));
            f.push(format!("aresample={rate}"));
            notes.push(format!(
                "Drift correction: the sound is {:.3}% {} than the picture; resampled to fit.",
                (t - 1.0).abs() * 100.0,
                if t > 1.0 { "longer" } else { "shorter" }
            ));
        }
        let lead_samples = (lead * rate as f64).round() as u64;
        if lead_samples > 0 {
            f.push(format!("adelay=delays={lead_samples}S:all=1"));
        }
        if p.offset_ms != 0 {
            notes.push(format!(
                "Sync offset: sound {} by {} ms.",
                if p.offset_ms > 0 { "delayed" } else { "advanced" },
                p.offset_ms.abs()
            ));
        }
        let read_duration = window.duration.map(|d| {
            (d - lead).max(0.0) * factor + READ_MARGIN_SECONDS + if p.denoise { AFFTDN_DELAY_SECONDS } else { 0.0 }
        });
        // 1a. A read an input seek would get wrong is dropped after decoding,
        // right behind the padding.
        let read_skip = crate::source_decode::sound_seek_fails(read_start, window.decoder_delay);
        if read_skip {
            let n = (read_start * rate as f64).round() as u64;
            f.insert(1, format!("atrim=start_sample={n}"));
            f.insert(2, "asetpts=PTS-STARTPTS".to_string());
            notes.push(
                "The source cannot seek its sound this near its start (an AVI with a decoder delay), \
                 so it is read from the beginning and the head dropped."
                    .into(),
            );
        }

        // 9–12.
        let deep_filter = p.deep_filter.then(|| p.deep_filter_attenuation.clamp(1, 100));
        let loudness_target = p.loudness_normalize.then(|| p.loudness_target.clamp(-70.0, -5.0));
        let out_rate = if deep_filter.is_some() { DEEP_FILTER_RATE } else { rate };
        let out_samples = window.duration.map(|d| (d * out_rate as f64).round() as u64);
        let mut finish = Vec::new();
        if p.limiter {
            let limit = 10f64.powf(p.limiter_ceiling_db.clamp(-24.0, 0.0) / 20.0).clamp(0.0625, 1.0);
            finish.push(format!("alimiter=limit={}:level=0:latency=1", num(limit)));
        }
        if let Some(n) = out_samples {
            finish.extend(length_filters(n));
        }
        // With nothing after the first run, it writes the final track itself.
        if deep_filter.is_none() && loudness_target.is_none() {
            f.append(&mut finish);
        } else if let Some(d) = window.duration {
            // The input to DeepFilterNet / loudness already has its length.
            f.extend(length_filters((d * rate as f64).round() as u64));
        }

        Self {
            stream: p.stream_index,
            source_rate: rate,
            read_start,
            read_skip,
            read_duration,
            restore_filters: f,
            deep_filter,
            loudness_target,
            finish_filters: finish,
            out_rate,
            out_samples,
            notes,
        }
    }

    /// Whether the first ffmpeg run writes the finished track.
    pub fn single_pass(&self) -> bool {
        self.deep_filter.is_none() && self.loudness_target.is_none()
    }

    /// The first run: the source's chosen stream through the restore chain.
    pub fn restore_args(&self, source: &str, output: &Path) -> Vec<String> {
        let mut args = quiet_args();
        if self.read_start > 0.0 && !self.read_skip {
            args.extend(["-ss".into(), format!("{:.6}", self.read_start)]);
        }
        // An input -t counts from where the read starts: the file's start
        // when the head is dropped in the chain.
        let head = if self.read_skip { self.read_start } else { 0.0 };
        if let Some(t) = self.read_duration {
            args.extend(["-t".into(), format!("{:.6}", t + head)]);
        }
        args.extend(["-i".into(), source.to_string()]);
        args.extend(["-map".into(), format!("0:a:{}", self.stream)]);
        args.extend(["-af".into(), self.restore_filters.join(",")]);
        args.extend(wav_output_args(output));
        args
    }

    /// DeepFilterNet on the first run's output, into `out_dir` (it keeps the
    /// input's file name).
    pub fn deep_filter_args(&self, input: &Path, out_dir: &Path) -> Option<Vec<String>> {
        let atten = self.deep_filter?;
        Some(vec![
            // Compensate its STFT + lookahead delay (30 ms, measured). The
            // track comes out that much short at the end; `finish` pads it.
            "-D".into(),
            "-a".into(),
            atten.to_string(),
            "-o".into(),
            out_dir.to_string_lossy().to_string(),
            input.to_string_lossy().to_string(),
        ])
    }

    /// `loudnorm`'s measuring pass over `input`; its JSON is on stderr.
    pub fn measure_args(&self, input: &Path) -> Option<Vec<String>> {
        let target = self.loudness_target?;
        let mut args = quiet_args();
        args.extend(["-i".into(), input.to_string_lossy().to_string()]);
        args.extend([
            "-af".into(),
            format!(
                "loudnorm=I={}:TP={}:LRA={}:print_format=json",
                num(target),
                num(LOUDNORM_TRUE_PEAK),
                num(LOUDNORM_RANGE)
            ),
        ]);
        args.extend(["-f".into(), "null".into(), "-".into()]);
        Some(args)
    }

    /// The last run, after DeepFilterNet or for loudness: loudness (with the
    /// first pass's measurement), back to the track's rate, limiter, length.
    pub fn finish_filter_chain(&self, measured: Option<&LoudnessMeasurement>) -> String {
        let mut f = Vec::new();
        if let (Some(target), Some(m)) = (self.loudness_target, measured) {
            f.push(format!(
                "loudnorm=I={}:TP={}:LRA={}:measured_I={}:measured_TP={}:measured_LRA={}:\
                 measured_thresh={}:offset={}:linear=true:print_format=summary",
                num(target),
                num(LOUDNORM_TRUE_PEAK),
                num(LOUDNORM_RANGE),
                num(m.input_i),
                num(m.input_tp),
                num(m.input_lra),
                num(m.input_thresh),
                num(m.target_offset)
            ));
        }
        // loudnorm resamples to 192 kHz; DeepFilterNet's output is already 48.
        f.push(format!("aresample={}", self.out_rate));
        f.extend(self.finish_filters.iter().cloned());
        f.join(",")
    }

    pub fn finish_args(&self, input: &Path, output: &Path, measured: Option<&LoudnessMeasurement>) -> Vec<String> {
        let mut args = quiet_args();
        args.extend(["-i".into(), input.to_string_lossy().to_string()]);
        args.extend(["-af".into(), self.finish_filter_chain(measured)]);
        args.extend(wav_output_args(output));
        args
    }
}

/// The analysis decode: `ANALYSIS_SECONDS` from `start`, as 32-bit float at
/// `rate`. An input seek, except where it fails (`source_decode` rule 9),
/// where the seek goes after `-i` and the head is decoded and discarded.
fn analysis_args(input: &str, stream: u32, start: f64, decoder_delay: u32, rate: u32) -> Vec<String> {
    let seek = ["-ss".to_string(), format!("{start:.3}"), "-t".to_string(), format!("{ANALYSIS_SECONDS}")];
    let input = ["-i".to_string(), input.to_string()];
    let mut args: Vec<String> = ["-v", "error", "-nostdin"].iter().map(|s| s.to_string()).collect();
    if crate::source_decode::sound_seek_fails(start, decoder_delay) {
        args.extend(input);
        args.extend(seek);
    } else {
        args.extend(seek);
        args.extend(input);
    }
    args.extend(["-map".into(), format!("0:a:{stream}"), "-ar".into(), rate.to_string(), "-f".into(), "f32le".into(), "-".into()]);
    args
}

fn quiet_args() -> Vec<String> {
    ["-hide_banner", "-nostdin", "-nostats", "-y"].iter().map(|s| s.to_string()).collect()
}

/// Intermediate and final tracks are 32-bit float: `adeclip` rebuilds peaks
/// above full scale, and loudness gain comes later, so nothing may clip in
/// between. RF64 past 4 GB (about 3.5 hours of float stereo at 48 kHz).
fn wav_output_args(output: &Path) -> Vec<String> {
    [
        "-vn", "-sn", "-dn", "-map_metadata", "-1", "-c:a", "pcm_f32le", "-rf64", "auto", "-f", "wav",
    ]
    .iter()
    .map(|s| s.to_string())
    .chain(std::iter::once(output.to_string_lossy().to_string()))
    .collect()
}

/// Exactly `n` samples: silence added if short, the rest cut if long.
fn length_filters(n: u64) -> [String; 2] {
    [format!("apad=whole_len={n}"), format!("atrim=end_sample={n}")]
}

fn pan_filter(fix: ChannelFix) -> Option<&'static str> {
    match fix {
        ChannelFix::LeftOnly => Some("pan=stereo|c0=c0|c1=c0"),
        ChannelFix::RightOnly => Some("pan=stereo|c0=c1|c1=c1"),
        ChannelFix::Mix => Some("pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1"),
        ChannelFix::Off | ChannelFix::Auto => None,
    }
}

/// A number for a filter argument: no trailing zeros, no exponent.
fn num(v: f64) -> String {
    let s = format!("{:.4}", v);
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s == "-0" { "0".into() } else { s.to_string() }
}

/// A tempo factor: drift of 0.01% needs more than four places.
fn num_precise(v: f64) -> String {
    let s = format!("{:.9}", v);
    s.trim_end_matches('0').trim_end_matches('.').to_string()
}

/// Parse `loudnorm`'s `print_format=json` block from ffmpeg's stderr.
pub fn parse_loudnorm_json(stderr: &str) -> Option<LoudnessMeasurement> {
    let start = stderr.rfind("\"input_i\"").and_then(|i| stderr[..i].rfind('{'))?;
    let end = start + stderr[start..].find('}')?;
    let v: serde_json::Value = serde_json::from_str(&stderr[start..=end]).ok()?;
    let get = |k: &str| -> Option<f64> {
        let s = v.get(k)?.as_str()?.trim();
        s.parse::<f64>().ok().filter(|x| x.is_finite())
    };
    Some(LoudnessMeasurement {
        input_i: get("input_i")?,
        input_tp: get("input_tp")?,
        input_lra: get("input_lra")?,
        input_thresh: get("input_thresh")?,
        target_offset: get("target_offset")?,
    })
}

// ---------------------------------------------------------------------------
// The encoder's side: mapping the rendered track
// ---------------------------------------------------------------------------

/// The rendered track as the encoder needs it.
#[derive(Debug, Clone, PartialEq)]
pub struct RestoredTrack {
    pub path: PathBuf,
    /// Which source audio stream it replaces, and how many there are.
    pub stream: u32,
    pub source_streams: u32,
}

/// The encoder's input for the rendered track (comes after its other inputs),
/// read from its start, or later by the encoder's priming when one applies
/// ([`EncoderPriming`]; a WAV seeks to the sample).
pub fn encode_input_args(track: Option<&RestoredTrack>, priming: Option<&EncoderPriming>) -> Vec<String> {
    let Some(t) = track else { return Vec::new() };
    let mut args = Vec::new();
    if let Some(p) = priming {
        args.extend(["-ss".into(), crate::source_decode::seek_arg(p.secs)]);
    }
    args.extend(["-i".into(), t.path.to_string_lossy().to_string()]);
    args
}

/// Where the encoder reads the output's sound from on the source's container
/// timeline: `VideoJob::source_audio_start`, plus the encoder's priming when
/// one applies ([`EncoderPriming`]). Only the encoder's audio inputs read
/// from here; the render, transcription, `OutputWindow` and every note keep
/// `source_audio_start` itself.
pub fn encode_sound_start(job: &VideoJob, priming: Option<&EncoderPriming>) -> f64 {
    job.source_audio_start() + priming.map_or(0.0, |p| p.secs)
}

/// The encoder's audio `-map`s. Without a rendered track, every source audio
/// stream (`1:a?`) as always. With one, the rendered track first — it is
/// the one a player picks by default — then the source's other audio streams
/// untouched, in their order, with the restored stream's tags (language,
/// title) carried over to the rendered one.
///
/// `sound` is the [`SoundCopy`]'s input and stream count when the source's
/// sound is copied from it rather than from input 1 (`source_decode` rule 9).
/// Its streams' tags are still taken from the source, every one named.
///
/// `cut` is the [`SoundCut`] and its packet input when the copied sound is
/// cut for AVI ([`needs_sound_cut`]): every copied stream is then mapped on
/// its own, a PCM one from the sound's usual input (seeked to the in-point),
/// a compressed one from the packet input, every one's tags named.
pub fn encode_map_args(
    settings: &EncodingSettings,
    track: Option<&RestoredTrack>,
    track_input: usize,
    sound: Option<(usize, u32)>,
    cut: Option<(&SoundCut, usize)>,
) -> Vec<String> {
    if settings.audio_mode == AudioMode::None {
        return Vec::new();
    }
    let from = sound.map_or(1, |(input, _)| input);
    if let Some((c, packet_input)) = cut {
        let mut args = Vec::new();
        if track.is_some() {
            args.extend(["-map".into(), format!("{track_input}:a:0")]);
        }
        let streams = copied_streams(track, c.streams.len() as u32);
        for (_, k) in &streams {
            let input = match c.streams.get(*k as usize) {
                Some(CutStream::Packet) => packet_input,
                _ => from,
            };
            args.extend(["-map".into(), format!("{input}:a:{k}")]);
        }
        if let Some(t) = track {
            args.extend(["-map_metadata:s:a:0".into(), format!("1:s:a:{}", t.stream)]);
        }
        for (j, k) in &streams {
            args.extend([format!("-map_metadata:s:a:{j}"), format!("1:s:a:{k}")]);
        }
        return args;
    }
    let Some(t) = track else {
        let mut args = vec!["-map".into(), format!("{from}:a?")];
        if let Some((_, streams)) = sound {
            for k in 0..streams {
                args.extend([format!("-map_metadata:s:a:{k}"), format!("1:s:a:{k}")]);
            }
        }
        return args;
    };
    let mut args = vec!["-map".into(), format!("{track_input}:a:0")];
    let others: Vec<u32> = (0..t.source_streams).filter(|k| *k != t.stream).collect();
    for k in &others {
        args.extend(["-map".into(), format!("{from}:a:{k}")]);
    }
    // Tags per output stream. Naming one stream's switches off ffmpeg's own
    // copying for the rest, so every audio stream is named.
    args.extend(["-map_metadata:s:a:0".into(), format!("1:s:a:{}", t.stream)]);
    for (j, k) in others.iter().enumerate() {
        args.extend([format!("-map_metadata:s:a:{}", j + 1), format!("1:s:a:{k}")]);
    }
    args
}

/// The encoder's audio codec arguments. Passthrough copies — except the
/// rendered track, which is new audio and must be encoded: FLAC in MKV, AAC
/// at the chosen quality in MP4/MOV, 24-bit PCM in AVI — and 24-bit PCM
/// whatever the container beside an editing intermediate (ProRes, v210).
///
/// See `restored_passthrough_codec`.
///
/// With a [`SoundCut`] (Passthrough into AVI, seeked), each copied PCM stream
/// is re-written in its own codec instead (`-c:a:N`, bit-identical, cut to the
/// sample), and `-copypriorss:a 0` drops a compressed stream's packets before
/// its seek.
pub fn encode_codec_args(settings: &EncodingSettings, track: Option<&RestoredTrack>, cut: Option<&SoundCut>) -> Vec<String> {
    let mut args = Vec::new();
    match settings.audio_mode {
        AudioMode::Passthrough => {
            args.extend(["-c:a".into(), "copy".into()]);
            if track.is_some() {
                let codec = restored_passthrough_codec(settings.container, settings.codec);
                args.extend(["-c:a:0".into(), codec.ffmpeg_name().into()]);
                if codec.takes_bitrate() {
                    args.extend(["-b:a:0".into(), format!("{}k", settings.audio_quality.bitrate())]);
                }
            }
            if let Some(c) = cut {
                let mut packets = false;
                for (j, k) in copied_streams(track, c.streams.len() as u32) {
                    match c.streams.get(k as usize) {
                        Some(CutStream::Exact(codec)) => args.extend([format!("-c:a:{j}"), (*codec).to_string()]),
                        Some(CutStream::Packet) => packets = true,
                        None => {}
                    }
                }
                if packets {
                    args.extend(["-copypriorss:a".into(), "0".into()]);
                }
            }
        }
        AudioMode::Convert => {
            args.extend(["-c:a".into(), settings.audio_codec.ffmpeg_name().into()]);
            if !settings.audio_codec.is_lossless() {
                args.extend(["-b:a".into(), format!("{}k", settings.audio_quality.bitrate())]);
            }
        }
        AudioMode::None => args.push("-an".into()),
    }
    args
}

/// What a restored track is encoded as under Passthrough. Deliberately not
/// `AudioCodec`: that is the user's Convert choice and a wire value shared
/// with the app (`AudioCodec::Pcm` is `pcm_s16le` there and stays so).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestoredTrackCodec {
    Aac,
    Flac,
    Pcm24,
}

impl RestoredTrackCodec {
    #[cfg(test)]
    pub const ALL: [RestoredTrackCodec; 3] = [RestoredTrackCodec::Aac, RestoredTrackCodec::Flac, RestoredTrackCodec::Pcm24];

    pub fn ffmpeg_name(self) -> &'static str {
        match self {
            RestoredTrackCodec::Aac => "aac",
            RestoredTrackCodec::Flac => "flac",
            RestoredTrackCodec::Pcm24 => "pcm_s24le",
        }
    }

    /// Whether `-b:a` applies (the chosen audio quality).
    pub fn takes_bitrate(self) -> bool {
        match self {
            RestoredTrackCodec::Aac => true,
            RestoredTrackCodec::Flac | RestoredTrackCodec::Pcm24 => false,
        }
    }
}

/// What a restored track is encoded as when the audio setting is Passthrough.
///
/// Wherever the track is lossless it keeps 24 bits: the render is 32-bit
/// float, and 16-bit rounds the quietest detail of pauses and fades to zero
/// (measurable, not audible) — docs/reports/2026-11-intermediate-pcm-depth.
/// - An editing intermediate (ProRes, v210) gets 24-bit PCM in every
///   container: its soundtrack will be encoded again on delivery, so a lossy
///   restored track would be two lossy generations, and PCM is what editors
///   expect beside it.
/// - MKV gets FLAC, which ffmpeg writes at 24 bits from the float render.
/// - AVI gets 24-bit PCM beside every codec, written as
///   `WAVE_FORMAT_EXTENSIBLE` (ffmpeg's only form above 16 bits). Video for
///   Windows, DirectShow, Media Foundation, VirtualDub 1.10.4 and VirtualDub2
///   read it sample for sample; ACM, the old conversion layer, refuses 24-bit
///   PCM in either header form (report, F6). Convert → PCM still gives 16 bits
///   for a reader that needs them.
/// - MP4/MOV otherwise get AAC.
/// All three lossless forms decode to the same samples.
pub fn restored_passthrough_codec(container: ContainerFormat, video: VideoCodec) -> RestoredTrackCodec {
    if video.is_editing_intermediate() {
        return RestoredTrackCodec::Pcm24;
    }
    match container {
        ContainerFormat::Mkv => RestoredTrackCodec::Flac,
        ContainerFormat::Mp4 | ContainerFormat::Mov => RestoredTrackCodec::Aac,
        ContainerFormat::Avi => RestoredTrackCodec::Pcm24,
    }
}

// ---------------------------------------------------------------------------
// The source's sound for a delayed AVI trimmed near its start
// ---------------------------------------------------------------------------

/// A copy of the source's audio streams in NUT, which the encoder seeks in
/// place of the source (`source_decode` rule 9): an input `-ss` on a delayed
/// AVI below `COUNT_SEEK_BELOW` fails and drops ~1.3 s of sound, and the
/// encode cannot filter audio. NUT keeps each stream's own time base
/// (1/sample rate) and any codec an AVI holds, so its seek is sample-exact;
/// an MKA copy was 9 samples off, an audio-only AVI ~10 ms on MP3 (see
/// docs/reports/2026-11-avi-audio-seek).
#[derive(Debug, Clone, PartialEq)]
pub struct SoundCopy {
    pub path: PathBuf,
    /// How many audio streams it holds: the source's, in order.
    pub streams: u32,
}

/// A [`SoundCopy`] and its scratch directory, removed when this is dropped
/// (held to the end of the job, like [`RenderedAudio`]).
pub struct SoundSidecar {
    pub copy: SoundCopy,
    work: PathBuf,
}

impl Drop for SoundSidecar {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.work);
    }
}

/// Whether the encode must take the source's sound from a [`SoundCopy`]:
/// it carries source audio (all of it, or the streams beside a rendered
/// track), and that sound's seek would fail (`VideoJob::sound_seek`). The
/// seek is the encoder's own, which an [`EncoderPriming`] moves later: an
/// untrimmed delayed AVI converted into AVI seeks its sound by the priming.
pub fn needs_sound_sidecar(job: &VideoJob, track: Option<&RestoredTrack>, priming: Option<&EncoderPriming>) -> bool {
    job.encoding_settings.audio_mode != AudioMode::None
        && job.source_has_audio != Some(false)
        && track.map_or(true, |t| t.source_streams > 1)
        && matches!(
            job.sound_seek(encode_sound_start(job, priming)),
            crate::source_decode::SoundSeek::Skip(_)
        )
}

/// The ffmpeg arguments that copy every audio stream of `source` into the NUT
/// file `out`, up to `end` seconds (the window's end plus a margin) when known.
pub fn sound_copy_args(source: &str, end: Option<f64>, out: &Path) -> Vec<String> {
    let mut args = quiet_args();
    args.extend(["-v".into(), "error".into(), "-i".into(), source.to_string()]);
    args.extend(["-map".into(), "0:a".into(), "-c".into(), "copy".into()]);
    if let Some(t) = end {
        args.extend(["-t".into(), format!("{t:.6}")]);
    }
    args.extend(["-map_metadata".into(), "-1".into(), "-f".into(), "nut".into()]);
    args.push(out.to_string_lossy().to_string());
    args
}

/// The output audio index and source audio stream of each stream the encode
/// copies from the source, in output order: every source stream, or, beside
/// a rendered track (output 0), the others.
pub fn copied_streams(track: Option<&RestoredTrack>, streams: u32) -> Vec<(u32, u32)> {
    let first = u32::from(track.is_some());
    (0..streams)
        .filter(|k| track.map_or(true, |t| t.stream != *k))
        .enumerate()
        .map(|(j, k)| (first + j as u32, k))
        .collect()
}

/// PCM codecs that AVI holds and that decode and encode back bit for bit:
/// the ones a [`SoundCut`] re-writes instead of copying (measured
/// bit-identical, docs/reports/2026-11-avi-copy-trim). A-law/µ-law and the
/// big-endian or DVD/Blu-ray layouts are not among them (AVI refuses the
/// latter, so their copy fails as it always did).
pub const EXACT_PCM_CODECS: [&str; 6] = ["pcm_u8", "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le"];

/// How the encode carries one copied source stream into AVI.
#[derive(Debug, Clone, PartialEq)]
pub enum CutStream {
    /// Re-written in this (its own) PCM codec: seeked to the in-point and
    /// decoded, so ffmpeg's accurate seek cuts it to the sample.
    Exact(&'static str),
    /// Still a copy, from the packet boundary nearest the in-point.
    Packet,
}

/// A Passthrough trim into a container that cannot store a stream's start
/// (AVI, [`needs_sound_cut`]). A copy keeps the packets from where the
/// demuxer's seek lands, before the in-point (a GOP early on a long-GOP
/// source); MKV/MP4/MOV store that as a later video start, AVI plays it under
/// the first picture and the whole track runs late. So PCM is re-written,
/// exact, and a compressed stream is copied from a second input of the same
/// file seeked `half_packet` early, with `-copypriorss:a 0`: its first packet
/// is then the one whose start is nearest the in-point (within half a packet).
///
/// ffmpeg drops a copied packet when its timestamp, in the stream's own time
/// base, is below the seek rounded to that time base. An AVI's compressed
/// audio counts in packets (AC-3 4/125, MP3 3/125), so the rounding alone
/// keeps the nearest packet and a seek to the in-point is right; seeking it
/// half a packet early kept the one before (measured +27 ms). A fine time
/// base (MP4 1/48000, MKV 1/1000) keeps the first packet at or after the
/// seek, so only those streams ask for the early seek.
#[derive(Debug, Clone, PartialEq)]
pub struct SoundCut {
    /// Every source audio stream, in order.
    pub streams: Vec<CutStream>,
    /// Half the longest packet among the [`CutStream::Packet`] streams whose
    /// time base is finer than a quarter of a packet, seconds; 0 when there
    /// are none (a stream counted in packets, as in AVI, is cut at the nearest
    /// by ffmpeg's rounding) or no duration was stated (the cut is then the
    /// first packet at or after the in-point).
    pub half_packet: f64,
    /// Half the longest packet among every [`CutStream::Packet`] stream,
    /// whatever its time base: the early seek when the packets are read from
    /// the NUT sound copy instead ([`SoundCopy`]), whose audio time base is
    /// the sample rate, so even an AVI's MP3/AC-3 needs it there.
    pub half_any_packet: f64,
    /// Per source audio stream, how long before the container's start its
    /// first packet starts, seconds (0 when it does not): a lossy encoder's
    /// start-up (priming), which MKV/MP4 store at a negative timestamp and
    /// AVI cannot (task #43). An empty list (no probe) reads as 0.
    pub head_before_start: Vec<f64>,
}

impl SoundCut {
    /// Whether any stream is copied by packet (and so needs the packet input).
    pub fn has_packet_streams(&self) -> bool {
        self.streams.iter().any(|s| *s == CutStream::Packet)
    }

    /// Whether a copied compressed stream (`copied`, from [`copied_streams`])
    /// starts before the container's start, by more than a microsecond: an
    /// untrimmed copy into AVI would then hand the muxer a negative
    /// timestamp, and ffmpeg shifts every stream by it ([`may_cut_sound_head`]).
    pub fn starts_early(&self, copied: &[(u32, u32)]) -> bool {
        copied.iter().any(|(_, k)| {
            let k = *k as usize;
            self.streams.get(k) == Some(&CutStream::Packet)
                && self.head_before_start.get(k).is_some_and(|h| *h > 1e-6)
        })
    }
}

/// Whether the encode's copied sound must be cut ([`SoundCut`]): Passthrough
/// into a container with no stream start (AVI), carrying source audio (all
/// of it, or the streams beside a rendered track), and the encoder seeks it
/// (a trim, or `startWithPicture` on a late video). Every other job keeps its
/// arguments byte for byte.
pub fn needs_sound_cut(job: &VideoJob, track: Option<&RestoredTrack>) -> bool {
    job.encoding_settings.audio_mode == AudioMode::Passthrough
        && !job.encoding_settings.container.stores_stream_start()
        && job.source_has_audio != Some(false)
        && track.map_or(true, |t| t.source_streams > 1)
        && job.source_audio_start() > 0.0
}

/// Whether an untrimmed copy into AVI may need its head cut (task #43): the
/// clauses of [`needs_sound_cut`] with the sound read from the container's
/// start. A source whose compressed sound was encoded by ffmpeg (AAC, MP3,
/// AC-3, MP2 in MKV or MP4) starts with the encoder's priming at a negative
/// timestamp, which AVI cannot store: ffmpeg shifted every stream by it, a
/// null frame at the head for AAC/MP3 and the priming played as sound
/// (−18.6 ms, docs/reports/2026-11-avi-copy-priming). The probe decides
/// ([`SoundCut::starts_early`]); [`sound_cut_applies`] is the decision.
pub fn may_cut_sound_head(job: &VideoJob, track: Option<&RestoredTrack>) -> bool {
    job.encoding_settings.audio_mode == AudioMode::Passthrough
        && !job.encoding_settings.container.stores_stream_start()
        && job.source_has_audio != Some(false)
        && track.map_or(true, |t| t.source_streams > 1)
        && job.source_audio_start() <= 0.0
}

/// Whether the encode applies `cut`: a seeked copy into AVI
/// ([`needs_sound_cut`]), or an untrimmed one whose copied compressed sound
/// starts before the container's start ([`may_cut_sound_head`]). The one
/// decision; every other job keeps its arguments byte for byte.
pub fn sound_cut_applies(job: &VideoJob, track: Option<&RestoredTrack>, cut: &SoundCut) -> bool {
    needs_sound_cut(job, track)
        || (may_cut_sound_head(job, track)
            && cut.starts_early(&copied_streams(track, cut.streams.len() as u32)))
}

/// ffprobe's arguments (before the input) for [`sound_cut_from_probe`]: each
/// audio stream's codec and the durations of its first packets, read from the
/// file's start (no seek, so a delayed AVI's failed seek cannot affect it).
pub const SOUND_CUT_PROBE_ARGS: [&str; 9] = [
    "-v", "error", "-select_streams", "a", "-read_intervals", "%+#256",
    "-show_entries", "stream=index,codec_name,time_base:packet=stream_index,pts_time,duration_time:format=start_time", "-of",
];

/// The [`SoundCut`] for a source, from ffprobe's JSON for
/// [`SOUND_CUT_PROBE_ARGS`] (`-of json`). `None` when it lists no audio.
pub fn sound_cut_from_probe(json: &str) -> Option<SoundCut> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let streams = v.get("streams")?.as_array()?;
    if streams.is_empty() {
        return None;
    }
    let mut cut = Vec::new();
    let mut indices = Vec::new();
    let mut time_bases = Vec::new();
    for s in streams {
        time_bases.push(s.get("time_base").and_then(|t| t.as_str()).and_then(parse_time_base));
        let codec = s.get("codec_name").and_then(|c| c.as_str()).unwrap_or("");
        cut.push(match EXACT_PCM_CODECS.iter().find(|c| **c == codec) {
            Some(c) => CutStream::Exact(c),
            None => CutStream::Packet,
        });
        indices.push(s.get("index").and_then(|i| i.as_i64()).unwrap_or(-1));
    }
    let mut longest = vec![0.0f64; cut.len()];
    let mut first: Vec<Option<f64>> = vec![None; cut.len()];
    let num = |x: Option<&serde_json::Value>| x.and_then(|d| d.as_str()).and_then(|d| d.parse::<f64>().ok()).filter(|d| d.is_finite());
    let container_start = num(v.get("format").and_then(|f| f.get("start_time"))).unwrap_or(0.0);
    for p in v.get("packets").and_then(|p| p.as_array()).into_iter().flatten() {
        let Some(k) = p.get("stream_index").and_then(|i| i.as_i64()).and_then(|i| indices.iter().position(|x| *x == i)) else {
            continue;
        };
        // The stream's first packet (packets come in file order; an AVI
        // states no pts and counts as starting with the container).
        if first[k].is_none() {
            first[k] = Some(num(p.get("pts_time")).unwrap_or(container_start));
        }
        if cut[k] != CutStream::Packet {
            continue;
        }
        let d = p.get("duration_time").and_then(|d| d.as_str()).and_then(|d| d.parse::<f64>().ok());
        if let Some(d) = d.filter(|d| d.is_finite() && *d > 0.0 && *d < 1.0) {
            longest[k] = longest[k].max(d);
        }
    }
    // Only a stream whose time base is finer than its packets needs the early
    // seek; one counted in packets is cut at the nearest by the rounding (an
    // unknown time base is taken as fine).
    let half = longest
        .iter()
        .zip(&time_bases)
        .filter(|(p, tb)| tb.map_or(true, |tb| tb * 4.0 <= **p))
        .map(|(p, _)| *p / 2.0)
        .fold(0.0, f64::max);
    let half_any = longest.iter().map(|p| *p / 2.0).fold(0.0, f64::max);
    let head = first.iter().map(|f| f.map_or(0.0, |f| (container_start - f).max(0.0))).collect();
    Some(SoundCut { streams: cut, half_packet: half, half_any_packet: half_any, head_before_start: head })
}

/// "4/125" → 0.032.
fn parse_time_base(s: &str) -> Option<f64> {
    let (n, d) = s.split_once('/')?;
    let (n, d): (f64, f64) = (n.trim().parse().ok()?, d.trim().parse().ok()?);
    (n > 0.0 && d > 0.0).then_some(n / d)
}

// ---------------------------------------------------------------------------
// A lossy encoder's start-up (priming) in a container that cannot mark it
// ---------------------------------------------------------------------------

/// How long a lossy audio encoder's start-up (its priming, or encoder delay)
/// lasts: its first packet's negative timestamp, in seconds. AAC primes 1024
/// samples, libmp3lame 1105, AC-3 256; FLAC and PCM none.
///
/// MP4, MOV and MKV mark the priming to be skipped (an edit list, skip
/// samples); AVI cannot. There ffmpeg's default `-avoid_negative_ts` shifted
/// every stream later by the priming, which rounds to a null frame at the
/// head when it is over half a frame (AAC, MP3 at 25 and 29.97 fps), and the
/// player then plays the priming as sound, so the content was late by it and
/// early by the null frame: AAC −18.6 ms, MP3 −16.9 ms, AC-3 +5.4 ms at 25 fps
/// (docs/reports/2026-11-avi-convert-priming). So the encode reads every
/// encoded sound input this much later and writes
/// `-avoid_negative_ts disabled` ([`ENCODER_PRIMING_OUTPUT_ARGS`]): the
/// priming then takes the place of the first `secs` of sound, and decoded
/// time t plays source time t.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EncoderPriming {
    pub secs: f64,
}

/// The encoder's output option that keeps every stream where it is when an
/// [`EncoderPriming`] applies: the video starts at 0 in AVI
/// (`VideoJob::output_video_delay` is 0 there), no subtitles are mapped, and
/// every audio stream is encoded and read late by the priming.
pub const ENCODER_PRIMING_OUTPUT_ARGS: [&str; 2] = ["-avoid_negative_ts", "disabled"];

/// Whether the encode must account for its audio encoder's priming
/// ([`EncoderPriming`]): Convert (every audio stream encoded) into a
/// container that cannot store where a stream starts (AVI), with sound. The
/// codec is not part of the decision: the probe measures it, and an encoder
/// with no priming (FLAC, PCM) measures none and changes nothing. Never with
/// a [`SoundCut`], which is Passthrough only.
pub fn needs_priming_shift(job: &VideoJob) -> bool {
    job.encoding_settings.audio_mode == AudioMode::Convert
        && !job.encoding_settings.container.stores_stream_start()
        && job.source_has_audio != Some(false)
}

/// ffmpeg's arguments for [`priming_from_probe`]: a fifth of a second of
/// silence at `rate`, encoded with the job's own audio codec arguments
/// (`codec_args`, from [`encode_codec_args`]), as `framecrc`, which prints
/// each packet's timestamp in the encoder's time base. The encoder chooses
/// its own rate (AC-3 encodes a 96 kHz source at 48 kHz), which the time
/// base shows.
pub fn priming_probe_args(codec_args: &[String], rate: u32) -> Vec<String> {
    let mut args = quiet_args();
    args.extend(["-v".into(), "error".into(), "-f".into(), "lavfi".into()]);
    args.extend(["-i".into(), format!("anullsrc=r={rate}:cl=stereo"), "-t".into(), "0.2".into()]);
    args.extend(codec_args.iter().cloned());
    args.extend(["-f".into(), "framecrc".into(), "-".into()]);
    args
}

/// The [`EncoderPriming`] from ffmpeg's `framecrc` output for
/// [`priming_probe_args`]: the first packet's timestamp in the stream's time
/// base (`#tb 0: 1/48000`). `None` when it is not negative (no priming) or
/// the output cannot be read.
pub fn priming_from_probe(framecrc: &str) -> Option<EncoderPriming> {
    let mut tb = None;
    for line in framecrc.lines().map(str::trim) {
        if let Some(rest) = line.strip_prefix("#tb 0:") {
            tb = parse_time_base(rest.trim());
            continue;
        }
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut fields = line.split(',').map(str::trim);
        if fields.next() != Some("0") {
            continue;
        }
        let pts: i64 = fields.next()?.parse().ok()?;
        let secs = -(pts as f64) * tb?;
        return (secs > 0.0 && secs < 1.0).then_some(EncoderPriming { secs });
    }
    None
}

// ---------------------------------------------------------------------------
// Running it
// ---------------------------------------------------------------------------

/// A finished render: the track, and the scratch directory it lives in,
/// removed when this is dropped (after the encode and the subtitle mux).
pub struct RenderedAudio {
    pub track: RestoredTrack,
    work: PathBuf,
}

impl Drop for RenderedAudio {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.work);
    }
}

/// The DeepFilterNet add-on's program for `platform` (its upstream file
/// name, which differs per platform; see its manifest).
pub fn deep_filter_binary(addons_root: &Path, platform: &str) -> Result<PathBuf> {
    let name = crate::addons::manifest(crate::addons::DEEPFILTERNET)
        .and_then(|m| m.executable_for(platform))
        .with_context(|| format!("DeepFilterNet has no program for {platform}"))?;
    Ok(crate::addons::addon_dir(addons_root, crate::addons::DEEPFILTERNET).join(name))
}

/// Probes the source, plans and renders. Owns nothing but its helpers.
pub struct AudioRestorer {
    reporter: ProgressReporter,
    deps: DependencyLocator,
}

impl AudioRestorer {
    pub fn new(reporter: ProgressReporter, deps: DependencyLocator) -> Self {
        Self { reporter, deps }
    }

    /// Plan the job's audio without rendering it (`--audio-plan`), or `None`
    /// when the pass does nothing for this job (with the reason logged).
    pub fn plan(&self, job: &VideoJob) -> Result<Option<(AudioPlan, SourceAudio)>> {
        let p = job.effective_pipeline().audio;
        if !p.has_effect() {
            return Ok(None);
        }
        if p.only_starts_with_picture() && job.video_start() <= 0.0 {
            // Nothing to drop: the sound already starts with the picture, so
            // leave it to the encoder (copied, not re-encoded).
            self.log(LogLevel::Info, "Start the sound with the picture: this video's sound and picture already start together; nothing to drop.");
            return Ok(None);
        }
        if p.uses_deep_filter() {
            // Refused before anything runs, with the add-on refusal every
            // feature gives (the app offers the download when it is chosen).
            self.deps.require_addons(&[crate::addons::DEEPFILTERNET], DEEP_FILTER_FEATURE)?;
        }
        if job.encoding_settings.audio_mode == AudioMode::None {
            self.log(LogLevel::Warning, "Audio restoration is on, but the output has no audio (Output → Audio is off); skipping it.");
            return Ok(None);
        }
        let Some(mut source) = self.probe_source(&job.input_path, p.stream_index)? else {
            self.log(LogLevel::Warning, "Audio restoration: the source has no audio stream; skipping it.");
            return Ok(None);
        };
        let mut p = p;
        if p.stream_index >= source.streams {
            self.log(
                LogLevel::Warning,
                &format!(
                    "Audio restoration: the source has {} audio stream(s), so stream {} does not exist; restoring the first.",
                    source.streams, p.stream_index + 1
                ),
            );
            p.stream_index = 0;
            source = self.probe_source(&job.input_path, 0)?.context("audio stream vanished")?;
        }
        let window = OutputWindow::for_job(job);

        let needs_analysis = p.channel_fix == ChannelFix::Auto
            || (p.hum_removal && p.hum_frequency == HumFrequency::Auto)
            || p.denoise;
        let analysis = if needs_analysis {
            self.analyse(&job.input_path, &p, &source, window).unwrap_or_else(|e| {
                self.log(LogLevel::Warning, &format!("Audio analysis failed ({e}); automatic choices are off."));
                Analysis::default()
            })
        } else {
            Analysis::default()
        };

        let drift = if p.drift_correction {
            match self.drift_factor(job, &source, p.drift_max_percent) {
                DriftDecision::Apply(f) => Some(f),
                DriftDecision::Skip(why) => {
                    self.log(LogLevel::Info, &format!("Drift correction: {why}."));
                    None
                }
            }
        } else {
            None
        };
        let mut plan = AudioPlan::new(&p, &source, window, &analysis, drift);
        if p.start_with_picture {
            plan.notes.push(start_with_picture_note(job.video_start()));
        }
        Ok(Some((plan, source)))
    }

    /// Render the job's restored audio track, or `None` when the pass does
    /// nothing for this job.
    pub fn render<F: Fn() -> bool>(&self, job: &VideoJob, on_cancel: F) -> Result<Option<RenderedAudio>> {
        let Some((plan, source)) = self.plan(job)? else { return Ok(None) };
        for note in &plan.notes {
            self.log(LogLevel::Info, note);
        }
        let ffmpeg = self.deps.ffmpeg_path()?;
        let work = std::env::temp_dir().join(format!("vb_audio_{}", job.id));
        let _ = std::fs::remove_dir_all(&work);
        std::fs::create_dir_all(&work).context("Failed to create the audio work directory")?;
        // From here the directory is removed on any early return.
        let rendered = RenderedAudio {
            track: RestoredTrack { path: work.join("restored.wav"), stream: plan.stream, source_streams: source.streams },
            work: work.clone(),
        };
        let total = plan.out_samples.map(|n| n as f64 / plan.out_rate as f64).or(source.duration);

        self.log(LogLevel::Info, "Restoring audio...");
        let first = if plan.single_pass() { rendered.track.path.clone() } else { work.join("restore.wav") };
        self.run_ffmpeg(&ffmpeg, &plan.restore_args(&job.input_path, &first), total, &on_cancel)
            .context("Audio restoration failed")?;

        let mut current = first;
        if let Some(args) = plan.deep_filter_args(&current, &work.join("dfn")) {
            self.log(LogLevel::Info, "Running DeepFilterNet speech enhancement...");
            let bin = deep_filter_binary(&self.deps.addons_dir(), self.deps.platform_suffix())?;
            self.run_quiet(&bin, &args, &on_cancel).context("DeepFilterNet failed")?;
            current = work.join("dfn").join(current.file_name().unwrap());
            if !current.exists() {
                bail!("DeepFilterNet wrote no output at {}", current.display());
            }
        }
        if !plan.single_pass() {
            let measured = match plan.measure_args(&current) {
                Some(args) => {
                    self.log(LogLevel::Info, "Measuring loudness...");
                    let stderr = self.run_ffmpeg(&ffmpeg, &args, total, &on_cancel)?;
                    let m = parse_loudnorm_json(&stderr);
                    if m.is_none() {
                        self.log(LogLevel::Warning, "Loudness could not be measured (silent audio?); not normalising it.");
                    }
                    m
                }
                None => None,
            };
            if let Some(m) = &measured {
                self.log(LogLevel::Info, &format!(
                    "Loudness: measured {:.1} LUFS, true peak {:.1} dBTP; normalising to {} LUFS.",
                    m.input_i, m.input_tp, num(plan.loudness_target.unwrap_or_default())
                ));
            }
            let args = plan.finish_args(&current, &rendered.track.path, measured.as_ref());
            self.run_ffmpeg(&ffmpeg, &args, total, &on_cancel).context("Audio finishing failed")?;
        }
        if on_cancel() {
            bail!("Job cancelled");
        }
        Ok(Some(rendered))
    }

    /// The [`SoundCopy`] the encode seeks, when it needs one
    /// ([`needs_sound_sidecar`]). A failure is a warning, not a refusal: the
    /// encode then seeks the source as before and may lose its first second
    /// or so of sound, which the warning says.
    pub fn sound_sidecar(
        &self,
        job: &VideoJob,
        track: Option<&RestoredTrack>,
        priming: Option<&EncoderPriming>,
    ) -> Option<SoundSidecar> {
        if !needs_sound_sidecar(job, track, priming) {
            return None;
        }
        // A silent source has nothing to copy, and nothing to lose.
        let streams = match self.probe_source(&job.input_path, 0) {
            Ok(Some(s)) if s.streams > 0 => s.streams,
            Ok(_) => return None,
            Err(e) => {
                self.log(LogLevel::Warning, &format!(
                    "Could not probe the source's sound for the trim ({e:#}); the first ~1.3 s of sound may be missing."
                ));
                return None;
            }
        };
        match self.write_sound_copy(job, streams) {
            Ok(sidecar) => {
                self.log(LogLevel::Info, &format!(
                    "The source has a decoder delay (AVI) and the output's sound starts within {} s of it, \
                     where it cannot seek its sound: the sound is copied to a temporary file that can.",
                    crate::source_decode::COUNT_SEEK_BELOW
                ));
                Some(sidecar)
            }
            Err(e) => {
                self.log(LogLevel::Warning, &format!(
                    "Could not copy the source's sound for the trim ({e:#}); the first ~1.3 s of sound may be missing."
                ));
                None
            }
        }
    }

    /// The [`SoundCut`] the encode applies, when it needs one
    /// ([`sound_cut_applies`]): a seeked copy into AVI, or an untrimmed one
    /// whose copied sound starts before the container (task #43). A failed
    /// probe is a warning: the encode then copies as before.
    pub fn sound_cut(&self, job: &VideoJob, track: Option<&RestoredTrack>) -> Option<SoundCut> {
        let seeked = needs_sound_cut(job, track);
        if !seeked && !may_cut_sound_head(job, track) {
            return None;
        }
        let late = if seeked {
            "the sound may run late by up to a keyframe interval; MKV, MP4 or MOV keeps it in sync"
        } else {
            "a sound encoded with a start-up (AAC, MP3) may put a null frame at the head and run up to a frame early; \
             MKV, MP4 or MOV keeps it in sync"
        };
        let ffprobe = match self.deps.ffprobe_path() {
            Ok(p) => p,
            Err(e) => {
                self.log(LogLevel::Warning, &format!("Could not probe the source's sound for the AVI output ({e:#}); {late}."));
                return None;
            }
        };
        let out = Command::new(&ffprobe)
            .args(SOUND_CUT_PROBE_ARGS)
            .args(["json", job.input_path.as_str()])
            .envs(self.deps.build_environment())
            .output();
        let cut = match out {
            Ok(o) if o.status.success() => sound_cut_from_probe(&String::from_utf8_lossy(&o.stdout)),
            Ok(o) => {
                let err = String::from_utf8_lossy(&o.stderr);
                self.log(LogLevel::Warning, &format!("Could not probe the source's sound for the AVI output ({}); {late}.", err.trim()));
                return None;
            }
            Err(e) => {
                self.log(LogLevel::Warning, &format!("Could not probe the source's sound for the AVI output ({e}); {late}."));
                return None;
            }
        };
        let Some(cut) = cut else {
            // No audio stream to cut (or an unreadable probe): nothing to copy late.
            return None;
        };
        if !sound_cut_applies(job, track, &cut) {
            // Untrimmed, and every copied stream starts with the container:
            // the copy is right as it is, its arguments unchanged.
            return None;
        }
        let copied = copied_streams(track, cut.streams.len() as u32);
        if !seeked {
            self.log(LogLevel::Info,
                "The source's compressed sound starts with its encoder's start-up (priming) before the first picture, \
                 which AVI cannot mark: it is copied from the packet nearest the first picture (within half a packet), \
                 so the first few tens of milliseconds play as the decoder's start-up.");
            return Some(cut);
        }
        let exact = copied.iter().any(|(_, k)| matches!(cut.streams[*k as usize], CutStream::Exact(_)));
        let packet = copied.iter().any(|(_, k)| cut.streams[*k as usize] == CutStream::Packet);
        let mut parts = Vec::new();
        if exact {
            parts.push("PCM sound is re-written in its own format, cut to the sample".to_string());
        }
        if packet {
            parts.push("compressed sound is copied from the packet nearest the in-point or first picture (within half a packet)".to_string());
        }
        self.log(LogLevel::Info, &format!(
            "AVI cannot store where a stream starts, so a copied sound would keep the seek's pre-roll and run late: the {}.",
            parts.join("; the ")
        ));
        Some(cut)
    }

    /// The [`EncoderPriming`] the encode accounts for, when it needs one
    /// ([`needs_priming_shift`]), measured from the job's own encoder at the
    /// rate of the sound it encodes first (the rendered track's, else the
    /// source's first stream's). `None` when the encoder has no priming. A
    /// failed probe is a warning: the encode then runs as before, with a
    /// null frame at the head and the sound off by the priming.
    pub fn encoder_priming(&self, job: &VideoJob, track: Option<&RestoredTrack>) -> Option<EncoderPriming> {
        if !needs_priming_shift(job) {
            return None;
        }
        let settings = &job.encoding_settings;
        let codec = settings.audio_codec.ffmpeg_name();
        let warn = |why: String| {
            self.log(LogLevel::Warning, &format!(
                "Could not measure the {codec} encoder's start-up for the AVI output ({why}); \
                 the output may hold an extra frame at its head and its sound may be off by up to ~25 ms."
            ));
        };
        let heard = track.map_or_else(|| job.input_path.clone(), |t| t.path.to_string_lossy().to_string());
        let rate = match self.probe_source(&heard, 0) {
            Ok(Some(s)) if s.streams > 0 && s.sample_rate > 0 => s.sample_rate,
            // A silent source has no sound to shift.
            Ok(_) => return None,
            Err(e) => {
                warn(format!("{e:#}"));
                return None;
            }
        };
        let args = priming_probe_args(&encode_codec_args(settings, None, None), rate);
        self.log(LogLevel::Debug, &format!("ffmpeg (encoder start-up): {args:?}"));
        let ffmpeg = match self.deps.ffmpeg_path() {
            Ok(p) => p,
            Err(e) => {
                warn(format!("{e:#}"));
                return None;
            }
        };
        let out = Command::new(ffmpeg).args(&args).envs(self.deps.build_environment()).stdin(Stdio::null()).output();
        let priming = match out {
            Ok(o) if o.status.success() => priming_from_probe(&String::from_utf8_lossy(&o.stdout)),
            Ok(o) => {
                warn(String::from_utf8_lossy(&o.stderr).trim().to_string());
                return None;
            }
            Err(e) => {
                warn(e.to_string());
                return None;
            }
        }?;
        let ms = priming.secs * 1000.0;
        self.log(LogLevel::Info, &format!(
            "AVI cannot mark the {codec} encoder's start-up ({ms:.1} ms), which a player plays as sound: \
             the sound is read {ms:.1} ms later to stay in sync with the picture, and its first {ms:.1} ms \
             is the encoder's start-up. MKV, MP4 and MOV keep every sample."
        ));
        Some(priming)
    }

    fn write_sound_copy(&self, job: &VideoJob, streams: u32) -> Result<SoundSidecar> {
        let work = std::env::temp_dir().join(format!("vb_sound_{}", job.id));
        let _ = std::fs::remove_dir_all(&work);
        std::fs::create_dir_all(&work).context("Failed to create the sound copy's directory")?;
        let sidecar = SoundSidecar { copy: SoundCopy { path: work.join("sound.nut"), streams }, work };
        let end = job
            .source_audio_window()
            .and_then(|(start, duration)| duration.map(|d| start + d + READ_MARGIN_SECONDS));
        let args = sound_copy_args(&job.input_path, end, &sidecar.copy.path);
        self.log(LogLevel::Debug, &format!("ffmpeg (sound copy): {args:?}"));
        let out = Command::new(self.deps.ffmpeg_path()?)
            .args(&args)
            .envs(self.deps.build_environment())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .context("Failed to start ffmpeg")?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            bail!("ffmpeg exited with {}: {}", out.status, err.trim());
        }
        Ok(sidecar)
    }

    fn log(&self, level: LogLevel, msg: &str) {
        self.reporter.send_log(level, msg);
    }

    /// The number of audio streams, and the chosen one's details.
    fn probe_source(&self, input: &str, stream: u32) -> Result<Option<SourceAudio>> {
        let ffprobe = self.deps.ffprobe_path()?;
        let out = Command::new(&ffprobe)
            .args(["-v", "error", "-select_streams", "a", "-show_entries",
                   "stream=channels,sample_rate,duration:stream_tags=DURATION", "-of", "json", input])
            .envs(self.deps.build_environment())
            .output()
            .context("Failed to run ffprobe on the audio")?;
        Ok(parse_source_probe(&String::from_utf8_lossy(&out.stdout), stream))
    }

    /// Decode a minute from the middle of the window at 8 kHz and measure it.
    fn analyse(&self, input: &str, p: &AudioRestorationParameters, source: &SourceAudio, window: OutputWindow) -> Result<Analysis> {
        let ffmpeg = self.deps.ffmpeg_path()?;
        let start = window.start + window.duration.map_or(0.0, |d| (d / 2.0 - ANALYSIS_SECONDS / 2.0).max(0.0));
        let rate = source.sample_rate.clamp(8000, ANALYSIS_MAX_RATE);
        let out = Command::new(&ffmpeg)
            .args(analysis_args(input, p.stream_index, start, window.decoder_delay, rate))
            .envs(self.deps.build_environment())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .context("Failed to decode audio for analysis")?;
        let samples: Vec<f32> = out.stdout.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
        let ch = source.channels.max(1) as usize;
        let mut a = Analysis::default();
        if ch == 2 {
            let levels = channel_levels_db(&samples, 2);
            a.dead_channel = dead_channel(levels[0], levels[1]);
            self.log(LogLevel::Debug, &format!("Audio analysis: channel levels L {:.1} dB, R {:.1} dB", levels[0], levels[1]));
        }
        let mono: Vec<f32> = samples.chunks_exact(ch).map(|f| f.iter().sum::<f32>() / ch as f32).collect();
        if p.hum_removal && p.hum_frequency == HumFrequency::Auto {
            a.hum = detect_hum(&mono, rate);
            self.log(LogLevel::Debug, &format!(
                "Audio analysis: hum prominence 50 Hz {:.1} dB, 60 Hz {:.1} dB",
                hum_prominence_db(&mono, rate, 50.0), hum_prominence_db(&mono, rate, 60.0)
            ));
        }
        if p.denoise {
            a.noise_floor_db = Some(noise_floor_db(&mono, rate));
        }
        Ok(a)
    }

    /// The whole source's audio length over the whole encoded picture's.
    fn drift_factor(&self, job: &VideoJob, source: &SourceAudio, max_percent: f64) -> DriftDecision {
        let fps = job.input_frame_rate.unwrap_or(29.97);
        let trimmed = job.start_frame.is_some() || job.end_frame.is_some();
        // Drift is a property of the recording, so it is measured over all of
        // it: a trimmed window's audio is cut to the window by construction.
        let frames = if trimmed { self.deps.probe_frame_count(&job.input_path) } else { job.total_frames };
        let video = frames
            .filter(|n| *n > 0)
            .and_then(|n| job.effective_pipeline().output_duration_secs(n as u64, fps));
        // The sound before the first picture is not drift: compare only the
        // part that runs under the picture.
        let audio = source
            .duration
            .or_else(|| self.measure_audio_duration(&job.input_path, job.effective_pipeline().audio.stream_index))
            .map(|a| a - job.video_start());
        match (audio, video) {
            (Some(a), Some(v)) => drift_decision(a, v, max_percent),
            _ => DriftDecision::Skip("the audio or picture length could not be measured".into()),
        }
    }

    /// Decode the stream to nothing and read how long it was.
    fn measure_audio_duration(&self, input: &str, stream: u32) -> Option<f64> {
        let ffmpeg = self.deps.ffmpeg_path().ok()?;
        let out = Command::new(&ffmpeg)
            .args(["-nostdin", "-v", "error", "-i", input, "-map", &format!("0:a:{stream}"),
                   "-progress", "pipe:1", "-f", "null", "-"])
            .envs(self.deps.build_environment())
            .output()
            .ok()?;
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| l.strip_prefix("out_time_us="))
            .filter_map(|v| v.trim().parse::<i64>().ok())
            .last()
            .map(|us| us as f64 / 1e6)
            .filter(|s| *s > 0.0)
    }

    /// Run ffmpeg, reporting progress against `total` seconds and honouring
    /// cancel. Returns its stderr tail (the loudness measurement is there).
    fn run_ffmpeg<F: Fn() -> bool>(&self, ffmpeg: &Path, args: &[String], total: Option<f64>, on_cancel: &F) -> Result<String> {
        self.log(LogLevel::Debug, &format!("audio ffmpeg: {:?}", args));
        let mut full = vec!["-progress".to_string(), "pipe:1".to_string()];
        full.extend(args.iter().cloned());
        let mut child = Command::new(ffmpeg)
            .args(&full)
            .envs(self.deps.build_environment())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("Failed to start ffmpeg for audio")?;
        let out_us = Arc::new(AtomicI64::new(0));
        let stdout = child.stdout.take().context("ffmpeg stdout")?;
        let out_us2 = out_us.clone();
        let progress = thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Some(v) = line.strip_prefix("out_time_us=") {
                    if let Ok(us) = v.trim().parse::<i64>() {
                        out_us2.store(us, Ordering::Relaxed);
                    }
                }
            }
        });
        let tail = Arc::new(Mutex::new(String::new()));
        let mut stderr = child.stderr.take().context("ffmpeg stderr")?;
        let tail2 = tail.clone();
        let errs = thread::spawn(move || {
            let mut s = String::new();
            let _ = stderr.read_to_string(&mut s);
            let mut keep = s.len().saturating_sub(16_000);
            while !s.is_char_boundary(keep) {
                keep += 1;
            }
            *tail2.lock().unwrap() = s[keep..].to_string();
        });
        let status = loop {
            if on_cancel() {
                let _ = child.kill();
                let _ = child.wait();
                bail!("Job cancelled");
            }
            if let Some(status) = child.try_wait()? {
                break status;
            }
            let pct = total
                .filter(|t| *t > 0.0)
                .map_or(0, |t| ((out_us.load(Ordering::Relaxed) as f64 / 1e6 / t) * 100.0).clamp(0.0, 100.0) as i32);
            self.reporter.send_progress_phase(&ProgressInfo::new(pct, if total.is_some() { 100 } else { 0 }, 0.0, 0.0), "audio");
            thread::sleep(Duration::from_millis(250));
        };
        let _ = progress.join();
        let _ = errs.join();
        let stderr = tail.lock().unwrap().clone();
        if !status.success() {
            let last: Vec<&str> = stderr.lines().filter(|l| !l.trim().is_empty()).collect();
            let last = last[last.len().saturating_sub(8)..].join("\n");
            bail!("ffmpeg exited with {status}:\n{last}");
        }
        Ok(stderr)
    }

    /// Run a helper program (DeepFilterNet) with indeterminate progress.
    fn run_quiet<F: Fn() -> bool>(&self, bin: &Path, args: &[String], on_cancel: &F) -> Result<()> {
        self.log(LogLevel::Debug, &format!("{}: {:?}", bin.display(), args));
        let mut child = Command::new(bin)
            .args(args)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("Failed to start {}", bin.display()))?;
        let mut stderr = child.stderr.take().context("stderr")?;
        let errs = thread::spawn(move || {
            let mut s = String::new();
            let _ = stderr.read_to_string(&mut s);
            s
        });
        let status = loop {
            if on_cancel() {
                let _ = child.kill();
                let _ = child.wait();
                bail!("Job cancelled");
            }
            if let Some(status) = child.try_wait()? {
                break status;
            }
            self.reporter.send_progress_phase(&ProgressInfo::new(0, 0, 0.0, 0.0), "audio");
            thread::sleep(Duration::from_millis(250));
        };
        let stderr = errs.join().unwrap_or_default();
        if !status.success() {
            let last: Vec<&str> = stderr.lines().filter(|l| !l.trim().is_empty()).collect();
            bail!("exited with {status}:\n{}", last[last.len().saturating_sub(8)..].join("\n"));
        }
        Ok(())
    }
}

/// Parse ffprobe's `-select_streams a` JSON: the stream count and the chosen
/// stream's details (`None` without any audio stream, or without `stream`).
pub fn parse_source_probe(json: &str, stream: u32) -> Option<SourceAudio> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let streams = v.get("streams")?.as_array()?;
    let s = streams.get(stream as usize)?;
    let int = |k: &str| -> Option<u32> {
        let x = s.get(k)?;
        x.as_u64().map(|n| n as u32).or_else(|| x.as_str()?.parse().ok())
    };
    let duration = s
        .get("duration")
        .and_then(|d| d.as_str())
        .and_then(|d| d.parse::<f64>().ok())
        .or_else(|| s.get("tags")?.get("DURATION")?.as_str().and_then(parse_hms))
        .filter(|d| *d > 0.0);
    Some(SourceAudio {
        streams: streams.len() as u32,
        channels: int("channels").unwrap_or(2),
        sample_rate: int("sample_rate").unwrap_or(48_000),
        duration,
    })
}

/// "01:02:03.500000000" → 3723.5 (Matroska's DURATION tag).
fn parse_hms(s: &str) -> Option<f64> {
    let parts: Vec<&str> = s.trim().split(':').collect();
    if parts.len() != 3 {
        return None;
    }
    let h: f64 = parts[0].parse().ok()?;
    let m: f64 = parts[1].parse().ok()?;
    let sec: f64 = parts[2].parse().ok()?;
    Some(h * 3600.0 + m * 60.0 + sec)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AudioCodec, AudioQuality, ProcessingPipeline, QTGMCParameters, DeinterlaceMethod, FrameRateParameters, FrameRateTarget};

    /// A restored track under Passthrough is always a codec its container can
    /// hold (task #39): Convert's pairs are refused, so this function must
    /// never pick one of them. Pcm24 muxes wherever pcm_s16le does.
    #[test]
    fn restored_passthrough_codec_always_fits_its_container() {
        for &video in VideoCodec::ALL {
            for &container in ContainerFormat::ALL {
                let codec = match restored_passthrough_codec(container, video) {
                    RestoredTrackCodec::Aac => AudioCodec::Aac,
                    RestoredTrackCodec::Flac => AudioCodec::Flac,
                    RestoredTrackCodec::Pcm24 => AudioCodec::Pcm,
                };
                assert!(
                    codec.supports_container(container),
                    "{video:?} in {container:?} restores as {codec:?}"
                );
            }
        }
    }

    fn stereo48() -> SourceAudio {
        SourceAudio { streams: 1, channels: 2, sample_rate: 48_000, duration: Some(60.0) }
    }

    fn window(start: f64, d: f64) -> OutputWindow {
        OutputWindow { start, duration: Some(d), decoder_delay: 0 }
    }

    fn on() -> AudioRestorationParameters {
        AudioRestorationParameters { enabled: true, ..Default::default() }
    }

    fn everything() -> AudioRestorationParameters {
        AudioRestorationParameters {
            enabled: true,
            channel_fix: ChannelFix::Mix,
            offset_ms: 120,
            drift_correction: true,
            declip: true,
            declick: true,
            hum_removal: true,
            hum_frequency: HumFrequency::Hz50,
            rumble_filter: true,
            denoise: true,
            deep_filter: true,
            loudness_normalize: true,
            limiter: true,
            ..Default::default()
        }
    }

    fn names(filters: &[String]) -> Vec<String> {
        filters.iter().map(|f| f.split('=').next().unwrap().to_string()).collect()
    }

    fn af_count(args: &[String]) -> usize {
        args.iter().filter(|a| *a == "-af").count()
    }

    /// The order is the module's documented order whatever is switched on, and
    /// every run carries exactly one -af (ffmpeg honours only the last).
    #[test]
    fn every_combination_keeps_the_order_and_one_af_per_run() {
        let order = [
            "aresample", "pan", "adeclip", "adeclick", "highpass", "bandreject", "afftdn", "atrim",
            "asetpts", "asetrate", "adelay", "alimiter", "apad",
        ];
        let rank = |n: &str| order.iter().position(|o| *o == n).unwrap_or_else(|| panic!("unexpected filter {n}"));
        // 9 toggles → 512 combinations, each with and without a negative offset.
        for mask in 0u32..512 {
            for (offset, delayed) in [(0, false), (250, false), (-250, false), (0, true), (-250, true)] {
                let p = AudioRestorationParameters {
                    enabled: true,
                    channel_fix: if mask & 1 != 0 { ChannelFix::LeftOnly } else { ChannelFix::Off },
                    declip: mask & 2 != 0,
                    declick: mask & 4 != 0,
                    rumble_filter: mask & 8 != 0,
                    hum_removal: mask & 16 != 0,
                    hum_frequency: HumFrequency::Hz60,
                    denoise: mask & 32 != 0,
                    deep_filter: mask & 64 != 0,
                    loudness_normalize: mask & 128 != 0,
                    limiter: mask & 256 != 0,
                    offset_ms: offset,
                    ..Default::default()
                };
                let drift = if mask % 3 == 0 { Some(1.002) } else { None };
                // A delayed AVI read from 0.2 s drops its head in the chain
                // (step 1a), right after the padding and nowhere else.
                let w = if delayed {
                    OutputWindow { decoder_delay: 2, ..window(0.2, 30.0) }
                } else {
                    window(1.0, 30.0)
                };
                let plan = AudioPlan::new(&p, &stereo48(), w, &Analysis::default(), drift);
                assert_eq!(plan.read_skip, delayed, "mask {mask} offset {offset}");
                if delayed {
                    assert!(plan.restore_filters[1].starts_with("atrim=start_sample="), "{:?}", plan.restore_filters);
                    assert_eq!(plan.restore_filters[2], "asetpts=PTS-STARTPTS");
                }
                let skip = if delayed { 2 } else { 0 };
                let ranks: Vec<usize> = names(&plan.restore_filters)
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| !(1..=skip).contains(i))
                    // The trailing atrim of the length fix is the last filter;
                    // the first aresample is step 1, the drift resample's two
                    // aresamples belong with its asetrate.
                    .filter(|(i, n)| !(n.as_str() == "atrim" && *i == plan.restore_filters.len() - 1))
                    .filter(|(i, n)| !(n.as_str() == "aresample" && *i > 0))
                    .map(|(_, n)| rank(n))
                    .collect();
                assert!(ranks.windows(2).all(|w| w[0] <= w[1]), "mask {mask}: {:?}", plan.restore_filters);
                let restore = plan.restore_args("in.mkv", Path::new("a.wav"));
                assert_eq!(af_count(&restore), 1, "{restore:?}");
                if !plan.single_pass() {
                    let finish = plan.finish_args(Path::new("a.wav"), Path::new("b.wav"), None);
                    assert_eq!(af_count(&finish), 1, "{finish:?}");
                    // The limiter only ever runs once, last before the length fix.
                    assert!(!plan.restore_filters.iter().any(|f| f.starts_with("alimiter")));
                }
                // The length is always fixed at the end of the run that writes the track.
                let last_chain = if plan.single_pass() {
                    plan.restore_filters.join(",")
                } else {
                    plan.finish_filter_chain(None)
                };
                assert!(last_chain.ends_with(&format!("apad=whole_len={n},atrim=end_sample={n}", n = 30 * plan.out_rate)), "{last_chain}");
            }
        }
    }

    #[test]
    fn full_chain_reads_in_the_documented_order() {
        let plan = AudioPlan::new(&everything(), &stereo48(), window(0.0, 10.0), &Analysis::default(), Some(1.001));
        assert_eq!(
            plan.restore_filters,
            vec![
                "aresample=first_pts=0",
                "pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1",
                "adeclip",
                "adeclick=t=2",
                "highpass=f=40:poles=2",
                "bandreject=f=50:width_type=q:w=8",
                "bandreject=f=100:width_type=q:w=8",
                "bandreject=f=150:width_type=q:w=8",
                "afftdn=nr=12:nf=-50",
                "atrim=start_sample=1200",
                "asetpts=PTS-STARTPTS",
                "aresample=192000",
                "asetrate=192192",
                "aresample=48000",
                // 120 ms delay from a start of 0 reaches before the source: lead silence.
                "adelay=delays=5760S:all=1",
                "apad=whole_len=480000",
                "atrim=end_sample=480000",
            ]
        );
        assert_eq!(plan.deep_filter, Some(100));
        assert_eq!(plan.out_rate, 48_000);
        let m = LoudnessMeasurement { input_i: -27.3, input_tp: -6.0, input_lra: 5.5, input_thresh: -37.5, target_offset: 0.2 };
        assert_eq!(
            plan.finish_filter_chain(Some(&m)),
            "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=-27.3:measured_TP=-6:measured_LRA=5.5:\
             measured_thresh=-37.5:offset=0.2:linear=true:print_format=summary,aresample=48000,\
             alimiter=limit=0.8913:level=0:latency=1,apad=whole_len=480000,atrim=end_sample=480000"
        );
    }

    /// afftdn's delay is trimmed in samples at the source's own rate.
    #[test]
    fn afftdn_delay_is_trimmed_at_the_source_rate() {
        for (rate, samples) in [(48_000, 1200), (44_100, 1103), (32_000, 800)] {
            let src = SourceAudio { sample_rate: rate, ..stereo48() };
            let p = AudioRestorationParameters { denoise: true, ..on() };
            let plan = AudioPlan::new(&p, &src, window(0.0, 5.0), &Analysis::default(), None);
            assert!(plan.restore_filters.contains(&format!("atrim=start_sample={samples}")), "{:?}", plan.restore_filters);
        }
    }

    /// A positive offset delays the sound: from a later in-point it reads
    /// earlier source audio; from the start it needs silence in front.
    /// A negative one reads later audio, never silence (adelay alone could
    /// only ever delay).
    #[test]
    fn offsets_move_the_read_point_or_add_lead_silence() {
        let at = |offset_ms: i32, start: f64| {
            let p = AudioRestorationParameters { offset_ms, ..on() };
            AudioPlan::new(&p, &stereo48(), window(start, 10.0), &Analysis::default(), None)
        };
        let late = at(300, 5.0);
        assert!((late.read_start - 4.7).abs() < 1e-9);
        assert!(!late.restore_filters.iter().any(|f| f.starts_with("adelay")));

        let from_zero = at(300, 0.0);
        assert_eq!(from_zero.read_start, 0.0);
        assert!(from_zero.restore_filters.contains(&"adelay=delays=14400S:all=1".to_string()));
        // Read only what fills the window after the lead (plus the margin).
        assert!((from_zero.read_duration.unwrap() - (9.7 + READ_MARGIN_SECONDS)).abs() < 1e-9);

        let early = at(-300, 0.0);
        assert!((early.read_start - 0.3).abs() < 1e-9);
        assert!(!early.restore_filters.iter().any(|f| f.starts_with("adelay")));
        let args = early.restore_args("in.mkv", Path::new("o.wav"));
        let ss = args.iter().position(|a| a == "-ss").unwrap();
        let i = args.iter().position(|a| a == "-i").unwrap();
        assert!(ss < i, "the seek is an input option");
        assert_eq!(args[ss + 1], "0.300000");
    }

    /// Drift and offset compose: source time = (start + t − offset) × tempo.
    #[test]
    fn drift_scales_the_read_point_and_length() {
        let p = AudioRestorationParameters { offset_ms: -100, ..on() };
        let plan = AudioPlan::new(&p, &stereo48(), window(10.0, 20.0), &Analysis::default(), Some(1.004));
        assert!((plan.read_start - 10.1 * 1.004).abs() < 1e-9);
        assert!((plan.read_duration.unwrap() - (20.0 * 1.004 + READ_MARGIN_SECONDS)).abs() < 1e-9);
        let (r1, s) = resample_ratio(48_000, 1.004);
        assert!(plan.restore_filters.contains(&format!("asetrate={s}")));
        assert!(plan.restore_filters.contains(&format!("aresample={r1}")));
    }

    #[test]
    fn drift_resample_is_skipped_within_1e6_of_one() {
        for t in [1.0, 1.0 + 5e-7, 1.0 - 9e-7] {
            let plan = AudioPlan::new(&on(), &stereo48(), window(0.0, 1.0), &Analysis::default(), Some(t));
            assert!(!plan.restore_filters.iter().any(|f| f.starts_with("asetrate")), "{t}");
            assert_eq!(plan.restore_filters.iter().filter(|f| f.starts_with("aresample")).count(), 1);
        }
        let plan = AudioPlan::new(&on(), &stereo48(), window(0.0, 1.0), &Analysis::default(), Some(1.0 + 2e-6));
        assert!(plan.restore_filters.iter().any(|f| f.starts_with("asetrate")), "{:?}", plan.restore_filters);
    }

    /// The relabelled rate is an integer, so the ratio is found where it can
    /// be exact: within 1e-10 of the factor for any drift, never below 4×.
    #[test]
    fn resample_ratio_is_exact_enough_for_an_hour() {
        for rate in [44_100u32, 48_000] {
            for f in [1.004, 0.996, 1.000123456, 0.99987654321, 1.005] {
                let (r1, s) = resample_ratio(rate, f);
                assert!(r1 >= rate * 4 && r1 <= rate * 8, "{r1}");
                let err = (s as f64 / r1 as f64 - f).abs();
                // Under 0.4 ms over an hour.
                assert!(err * 3600.0 < 0.0004, "{rate} {f}: {r1}->{s} err {err:e}");
            }
        }
        assert_eq!(resample_ratio(48_000, 1.001), (192_000, 192_192));
    }

    #[test]
    fn noise_floor_is_the_quiet_tenth() {
        let mut seed = 99u64;
        // 9 s of -40 dB noise with 1 s bursts of a loud tone every 2 s.
        let x = synth(48_000, 9.0, |t| {
            let n = 0.01 * 3f64.sqrt() * noise(&mut seed);
            if (t as u64) % 2 == 0 && t.fract() < 0.5 { n + 0.5 * (1000.0 * t).sin() } else { n }
        });
        let floor = noise_floor_db(&x, 48_000);
        assert!((floor - (-40.0)).abs() < 1.0, "{floor}");
        assert_eq!(noise_floor_db(&vec![0.0; 48_000], 48_000), NOISE_FLOOR_RANGE.0);
        let p = AudioRestorationParameters { denoise: true, ..on() };
        let a = Analysis { noise_floor_db: Some(-41.4), ..Default::default() };
        let plan = AudioPlan::new(&p, &stereo48(), window(0.0, 1.0), &a, None);
        assert!(plan.restore_filters.contains(&"afftdn=nr=12:nf=-41".to_string()), "{:?}", plan.restore_filters);
    }

    #[test]
    fn drift_needs_more_than_50ms_and_at_most_the_cap() {
        // 1 h picture.
        let v = 3600.0;
        assert!(matches!(drift_decision(v + 0.04, v, 0.5), DriftDecision::Skip(_)));
        assert_eq!(drift_decision(v + 3.6, v, 0.5), DriftDecision::Apply((v + 3.6) / v));
        assert_eq!(drift_decision(v - 3.6, v, 0.5), DriftDecision::Apply((v - 3.6) / v));
        // 0.6% is over a 0.5% cap but under a 1% one.
        assert!(matches!(drift_decision(v * 1.006, v, 0.5), DriftDecision::Skip(why) if why.contains("0.60%")));
        assert!(matches!(drift_decision(v * 1.006, v, 1.0), DriftDecision::Apply(_)));
        assert!(matches!(drift_decision(0.0, v, 0.5), DriftDecision::Skip(_)));
    }

    #[test]
    fn channel_fix_auto_uses_the_analysis() {
        let p = AudioRestorationParameters { channel_fix: ChannelFix::Auto, ..on() };
        let with = |dead| AudioPlan::new(&p, &stereo48(), window(0.0, 1.0), &Analysis { dead_channel: dead, ..Default::default() }, None);
        assert!(with(Some(DeadChannel::Right)).restore_filters.contains(&"pan=stereo|c0=c0|c1=c0".to_string()));
        assert!(with(Some(DeadChannel::Left)).restore_filters.contains(&"pan=stereo|c0=c1|c1=c1".to_string()));
        assert!(!with(None).restore_filters.iter().any(|f| f.starts_with("pan")));
        // Never on anything but stereo.
        let mono = SourceAudio { channels: 1, ..stereo48() };
        let p = AudioRestorationParameters { channel_fix: ChannelFix::LeftOnly, ..on() };
        let plan = AudioPlan::new(&p, &mono, window(0.0, 1.0), &Analysis::default(), None);
        assert!(!plan.restore_filters.iter().any(|f| f.starts_with("pan")));
        assert!(plan.notes.iter().any(|n| n.contains("1 channel")));
    }

    #[test]
    fn dead_channel_needs_a_30db_gap_and_a_live_side() {
        assert_eq!(dead_channel(-20.0, -90.0), Some(DeadChannel::Right));
        assert_eq!(dead_channel(-95.0, -25.0), Some(DeadChannel::Left));
        assert_eq!(dead_channel(-20.0, -45.0), None); // quiet, not dead
        assert_eq!(dead_channel(-80.0, -120.0), None); // all silence
    }

    #[test]
    fn hum_auto_notches_only_what_was_found() {
        let p = AudioRestorationParameters { hum_removal: true, ..on() };
        let plan = |hum| AudioPlan::new(&p, &stereo48(), window(0.0, 1.0), &Analysis { hum, ..Default::default() }, None);
        let f60 = plan(Some(60)).restore_filters;
        assert!(f60.iter().any(|f| f == "bandreject=f=180:width_type=q:w=8"));
        assert!(!f60.iter().any(|f| f.contains("f=50:")));
        let none = plan(None);
        assert!(!none.restore_filters.iter().any(|f| f.starts_with("bandreject")));
        assert!(none.notes.iter().any(|n| n.contains("nothing is notched")));
    }

    fn synth(rate: u32, secs: f64, mut f: impl FnMut(f64) -> f64) -> Vec<f32> {
        (0..(rate as f64 * secs) as usize).map(|i| f(i as f64 / rate as f64) as f32).collect()
    }

    /// A deterministic noise source for the synthetic tests.
    fn noise(seed: &mut u64) -> f64 {
        *seed ^= *seed << 13;
        *seed ^= *seed >> 7;
        *seed ^= *seed << 17;
        (*seed as f64 / u64::MAX as f64) * 2.0 - 1.0
    }

    #[test]
    fn hum_detection_tells_50_from_60_and_ignores_plain_noise() {
        use std::f64::consts::PI;
        let mut s = 0x1234_5678_9abc_def0u64;
        let mut s2 = s;
        let mut s3 = s;
        // Hum at 50.1 Hz (mains wanders), harmonics, under noise and a 440 Hz tone.
        let hum50 = synth(8000, 20.0, |t| {
            0.02 * (2.0 * PI * 50.1 * t).sin() + 0.01 * (2.0 * PI * 100.2 * t).sin()
                + 0.2 * (2.0 * PI * 440.0 * t).sin() + 0.05 * noise(&mut s)
        });
        assert_eq!(detect_hum(&hum50, 8000), Some(50));
        // 60 Hz mains where the third harmonic dominates (rectifier buzz).
        let hum60 = synth(8000, 20.0, |t| {
            0.003 * (2.0 * PI * 60.0 * t).sin() + 0.02 * (2.0 * PI * 180.0 * t).sin() + 0.05 * noise(&mut s2)
        });
        assert_eq!(detect_hum(&hum60, 8000), Some(60));
        let clean = synth(8000, 20.0, |t| 0.2 * (2.0 * PI * 440.0 * t).sin() + 0.05 * noise(&mut s3));
        assert_eq!(detect_hum(&clean, 8000), None);
    }

    #[test]
    fn channel_levels_measure_each_channel() {
        let interleaved: Vec<f32> = (0..16000).flat_map(|i| [if i % 2 == 0 { 0.5 } else { -0.5 }, 0.0]).collect();
        let l = channel_levels_db(&interleaved, 2);
        assert!((l[0] - 20.0 * 0.5f64.log10()).abs() < 0.01);
        assert!(l[1] < -200.0);
    }

    #[test]
    fn loudnorm_json_is_read_from_stderr() {
        let stderr = "[Parsed_loudnorm_0 @ 0x1]\n{\n\t\"input_i\" : \"-27.61\",\n\t\"input_tp\" : \"-4.47\",\n\
            \t\"input_lra\" : \"18.06\",\n\t\"input_thresh\" : \"-39.20\",\n\t\"output_i\" : \"-16.58\",\n\
            \t\"output_tp\" : \"-1.50\",\n\t\"output_lra\" : \"14.78\",\n\t\"output_thresh\" : \"-27.71\",\n\
            \t\"normalization_type\" : \"dynamic\",\n\t\"target_offset\" : \"0.58\"\n}\n";
        let m = parse_loudnorm_json(stderr).unwrap();
        assert_eq!(m.input_i, -27.61);
        assert_eq!(m.target_offset, 0.58);
        // Silence measures -inf: nothing to normalise.
        assert!(parse_loudnorm_json(&stderr.replace("-27.61", "-inf")).is_none());
        assert!(parse_loudnorm_json("no json").is_none());
    }

    #[test]
    fn source_probe_reads_streams_and_durations() {
        let json = r#"{"streams":[{"channels":2,"sample_rate":"48000","duration":"12.5"},
            {"channels":6,"sample_rate":"44100","tags":{"DURATION":"01:00:01.250000000"}}]}"#;
        let a = parse_source_probe(json, 0).unwrap();
        assert_eq!((a.streams, a.channels, a.sample_rate, a.duration), (2, 2, 48_000, Some(12.5)));
        let b = parse_source_probe(json, 1).unwrap();
        assert_eq!((b.channels, b.sample_rate, b.duration), (6, 44_100, Some(3601.25)));
        assert!(parse_source_probe(json, 2).is_none());
        assert!(parse_source_probe(r#"{"streams":[]}"#, 0).is_none());
    }

    /// A source whose video starts after its sound: the rendered track keeps
    /// the sound before the first picture (the encoder delays the picture by
    /// as much), unless "start with the picture" drops it, and a trim reads
    /// from the in-point's picture, offset included.
    #[test]
    fn the_window_follows_the_video_start_offset() {
        let mut job: VideoJob = serde_json::from_value(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000002",
            "inputPath": "in.ts", "outputPath": "out.mkv",
            "qtgmcParameters": {}, "encodingSettings": {},
            "totalFrames": 125, "inputFrameRate": 25.0,
            "videoStartOffset": 1.2,
            "processingPipeline": { "deinterlace": { "enabled": false } }
        }))
        .unwrap();
        let w = OutputWindow::for_job(&job);
        assert_eq!(w.start, 0.0);
        assert!((w.duration.unwrap() - 6.2).abs() < 1e-9, "{w:?}");

        let mut p = job.effective_pipeline();
        p.audio.enabled = true;
        p.audio.start_with_picture = true;
        job.processing_pipeline = Some(p);
        let w = OutputWindow::for_job(&job);
        assert!((w.start - 1.2).abs() < 1e-9 && (w.duration.unwrap() - 5.0).abs() < 1e-9, "{w:?}");

        job.start_frame = Some(25);
        job.total_frames = Some(50);
        let w = OutputWindow::for_job(&job);
        assert!((w.start - 2.2).abs() < 1e-9 && (w.duration.unwrap() - 2.0).abs() < 1e-9, "{w:?}");

        // The plan reads from the window's start, with nothing else changed.
        let plan = AudioPlan::new(
            &job.effective_pipeline().audio,
            &SourceAudio { streams: 1, channels: 2, sample_rate: 48_000, duration: Some(6.1) },
            w,
            &Analysis::default(),
            None,
        );
        assert!((plan.read_start - 2.2).abs() < 1e-9);
    }

    #[test]
    fn start_with_picture_alone_does_nothing_without_a_gap() {
        let p = AudioRestorationParameters { enabled: true, start_with_picture: true, ..Default::default() };
        assert!(p.has_effect());
        assert!(p.only_starts_with_picture());
        let both = AudioRestorationParameters { limiter: true, ..p.clone() };
        assert!(!both.only_starts_with_picture());
        assert!(start_with_picture_note(1.322).contains("1.322 s"));
        assert!(start_with_picture_note(0.0).contains("nothing dropped"));
    }

    /// The picture's length is its output frames over its output rate, so
    /// double-rate deinterlacing and frame-rate conversion leave it as long
    /// as the source window, and a trim shortens it.
    #[test]
    fn the_window_is_the_encoded_pictures_length() {
        let mut job: VideoJob = serde_json::from_value(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000001",
            "inputPath": "in.mkv", "outputPath": "out.mkv",
            "qtgmcParameters": {}, "encodingSettings": {},
            "totalFrames": 250, "inputFrameRate": 25.0
        }))
        .unwrap();
        let mut pipeline = ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: true, fps_divisor: Some(1), ..Default::default() },
            ..Default::default()
        };
        job.processing_pipeline = Some(pipeline.clone());
        let w = OutputWindow::for_job(&job);
        assert_eq!(w.start, 0.0);
        assert!((w.duration.unwrap() - 10.0).abs() < 1e-9, "{w:?}");

        // IVTC from 29.97: 300 frames → 240 at 23.976.
        pipeline.deinterlace = QTGMCParameters { enabled: true, method: DeinterlaceMethod::Ivtc, ..Default::default() };
        job.processing_pipeline = Some(pipeline.clone());
        job.input_frame_rate = Some(30000.0 / 1001.0);
        job.total_frames = Some(300);
        assert!((OutputWindow::for_job(&job).duration.unwrap() - 300.0 * 1001.0 / 30000.0).abs() < 1e-9);

        // 25 → 50 fps, trimmed to 100 frames from frame 50: 200 frames at 50 = 4 s.
        pipeline.deinterlace.enabled = false;
        pipeline.frame_rate = FrameRateParameters { enabled: true, target: FrameRateTarget::Pal50, ..Default::default() };
        job.processing_pipeline = Some(pipeline.clone());
        job.input_frame_rate = Some(25.0);
        job.start_frame = Some(50);
        job.end_frame = Some(149);
        job.total_frames = Some(100);
        let w = OutputWindow::for_job(&job);
        assert!((w.start - 2.0).abs() < 1e-9);
        assert!((w.duration.unwrap() - 4.0).abs() < 1e-9, "{w:?}");

        // 25 → 59.94 is not a whole ratio: floor(100 × 2400/1001) = 239 frames
        // at 60000/1001 — the encoded length, a frame short of the source's.
        pipeline.frame_rate.target = FrameRateTarget::Ntsc5994;
        job.processing_pipeline = Some(pipeline);
        let d = OutputWindow::for_job(&job).duration.unwrap();
        assert!((d - 239.0 * 1001.0 / 60000.0).abs() < 1e-9, "{d}");
    }

    fn settings(mode: AudioMode, container: ContainerFormat) -> EncodingSettings {
        EncodingSettings { audio_mode: mode, container, audio_quality: AudioQuality::High, ..Default::default() }
    }

    #[test]
    fn encoder_maps_the_restored_track_first_and_keeps_the_others() {
        let s = settings(AudioMode::Passthrough, ContainerFormat::Mkv);
        assert_eq!(encode_map_args(&s, None, 3, None, None), vec!["-map", "1:a?"]);
        let t = RestoredTrack { path: "r.wav".into(), stream: 1, source_streams: 3 };
        assert_eq!(
            encode_map_args(&s, Some(&t), 3, None, None),
            vec![
                "-map", "3:a:0", "-map", "1:a:0", "-map", "1:a:2",
                "-map_metadata:s:a:0", "1:s:a:1", "-map_metadata:s:a:1", "1:s:a:0",
                "-map_metadata:s:a:2", "1:s:a:2",
            ]
        );
        assert!(encode_map_args(&settings(AudioMode::None, ContainerFormat::Mkv), Some(&t), 3, None, None).is_empty());
        assert_eq!(encode_input_args(Some(&t), None), vec!["-i", "r.wav"]);
        assert!(encode_input_args(None, None).is_empty());
    }

    /// Rule 9: the source's sound from the copy (input 4 here), its tags
    /// still from the source, every stream named.
    #[test]
    fn encoder_maps_the_sound_copy_with_the_sources_tags() {
        let s = settings(AudioMode::Passthrough, ContainerFormat::Mkv);
        assert_eq!(
            encode_map_args(&s, None, 3, Some((3, 2)), None),
            vec!["-map", "3:a?", "-map_metadata:s:a:0", "1:s:a:0", "-map_metadata:s:a:1", "1:s:a:1"]
        );
        let t = RestoredTrack { path: "r.wav".into(), stream: 0, source_streams: 2 };
        assert_eq!(
            encode_map_args(&s, Some(&t), 3, Some((4, 2)), None),
            vec!["-map", "3:a:0", "-map", "4:a:1", "-map_metadata:s:a:0", "1:s:a:0", "-map_metadata:s:a:1", "1:s:a:1"]
        );
        assert!(encode_map_args(&settings(AudioMode::None, ContainerFormat::Mkv), None, 3, Some((3, 1)), None).is_empty());
    }

    fn delayed_avi(start_frame: Option<i32>) -> VideoJob {
        let mut job: VideoJob = serde_json::from_value(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000022",
            "inputPath": "in.avi",
            "outputPath": "out.mkv",
            "qtgmcParameters": {},
            "encodingSettings": {},
        }))
        .unwrap();
        job.input_frame_rate = Some(30000.0 / 1001.0);
        job.start_frame = start_frame;
        job.end_frame = Some(61);
        job.decoder_delay_frames = Some(2);
        job
    }

    #[test]
    fn the_sound_copy_is_used_only_where_the_seek_fails() {
        let job = delayed_avi(Some(2));
        assert!(needs_sound_sidecar(&job, None, None));
        // A rendered track covers the only stream; with a second, that one
        // still comes from the source.
        let one = RestoredTrack { path: "r.wav".into(), stream: 0, source_streams: 1 };
        let two = RestoredTrack { source_streams: 2, ..one.clone() };
        assert!(!needs_sound_sidecar(&job, Some(&one), None));
        assert!(needs_sound_sidecar(&job, Some(&two), None));
        // No sound, no source sound, untrimmed, far enough in, no delay.
        let mut j = job.clone();
        j.encoding_settings.audio_mode = AudioMode::None;
        assert!(!needs_sound_sidecar(&j, None, None));
        let mut j = job.clone();
        j.source_has_audio = Some(false);
        assert!(!needs_sound_sidecar(&j, None, None));
        assert!(!needs_sound_sidecar(&delayed_avi(None), None, None));
        assert!(!needs_sound_sidecar(&delayed_avi(Some(20)), None, None));
        let mut j = job.clone();
        j.decoder_delay_frames = None;
        assert!(!needs_sound_sidecar(&j, None, None));
    }

    /// Task 38: an untrimmed delayed AVI converted into AVI seeks its sound
    /// by the encoder's priming, which it cannot do near its start: the
    /// sound copy then applies, as it would to a trim there.
    #[test]
    fn a_priming_moves_the_sound_copy_decision() {
        let p = EncoderPriming { secs: 1024.0 / 48000.0 };
        let mut job = delayed_avi(None);
        job.encoding_settings.container = ContainerFormat::Avi;
        job.encoding_settings.audio_mode = AudioMode::Convert;
        assert!(!needs_sound_sidecar(&job, None, None));
        assert!(needs_sound_sidecar(&job, None, Some(&p)));
        assert!((encode_sound_start(&job, Some(&p)) - p.secs).abs() < 1e-12);
        assert_eq!(encode_sound_start(&job, None), 0.0);
        // Far enough in, the seek works either way.
        let far = delayed_avi(Some(20));
        assert!(!needs_sound_sidecar(&far, None, Some(&p)));
    }

    /// Only Convert into a container that cannot store a stream's start, with
    /// sound, accounts for the encoder's priming; never together with a
    /// sound cut (Passthrough only).
    #[test]
    fn the_priming_shift_applies_only_to_convert_into_avi() {
        for container in [ContainerFormat::Mp4, ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi] {
            for mode in [AudioMode::Passthrough, AudioMode::Convert, AudioMode::None] {
                for start in [None, Some(20)] {
                    let mut j = avi_trim(start);
                    j.encoding_settings.container = container;
                    j.encoding_settings.audio_mode = mode;
                    let applies = container == ContainerFormat::Avi && mode == AudioMode::Convert;
                    assert_eq!(needs_priming_shift(&j), applies, "{container:?} {mode:?} {start:?}");
                    assert!(!(needs_priming_shift(&j) && needs_sound_cut(&j, None)), "{container:?} {mode:?}");
                    j.source_has_audio = Some(false);
                    assert!(!needs_priming_shift(&j));
                }
            }
        }
    }

    /// framecrc as FFmpeg 9.0 prints it for each encoder (anullsrc, stereo).
    const FRAMECRC_AAC_48K: &str = "#extradata 0:        5, 0x056101dc\n#software: Lavf63.1.102\n#tb 0: 1/48000\n#media_type 0: audio\n#codec_id 0: aac\n#sample_rate 0: 48000\n#channel_layout_name 0: stereo\n0,      -1024,      -1024,     1024,       21, 0x43390566\n0,          0,          0,     1024,        6, 0x037a013d\n";
    const FRAMECRC_AAC_44K: &str = "#tb 0: 1/44100\n#media_type 0: audio\n0,      -1024,      -1024,     1024,       21, 0x43390566\n";
    const FRAMECRC_MP3_48K: &str = "#software: Lavf63.1.102\n#tb 0: 1/48000\n#media_type 0: audio\n#codec_id 0: mp3\n0,      -1105,      -1105,     1152,      576, 0x963cb835, S=1, Skip Samples,       10, 0x034e0055\n0,         47,         47,     1152,      576, 0x963cb835\n";
    /// AC-3 of a 96 kHz input: the encoder runs at 48 kHz, as its time base says.
    const FRAMECRC_AC3_96K: &str = "#software: Lavf63.1.102\n#tb 0: 1/48000\n#media_type 0: audio\n#codec_id 0: ac3\n#sample_rate 0: 48000\n0,       -256,       -256,     1536,      768, 0x146b5487\n";
    const FRAMECRC_FLAC: &str = "#extradata 0:       34, 0x36ec0265\n#tb 0: 1/48000\n#media_type 0: audio\n#codec_id 0: flac\n0,          0,          0,     1024,       14, 0x2b7e047d\n";
    const FRAMECRC_PCM: &str = "#tb 0: 1/48000\n#codec_id 0: pcm_s16le\n0,          0,          0,     1024,     4096, 0x00000000\n0,       1024,       1024,     1024,     4096, 0x00000000\n";

    #[test]
    fn the_priming_is_read_from_the_first_packet() {
        let secs = |t: &str| priming_from_probe(t).map(|p| p.secs);
        assert!((secs(FRAMECRC_AAC_48K).unwrap() - 1024.0 / 48000.0).abs() < 1e-12);
        assert!((secs(FRAMECRC_AAC_44K).unwrap() - 1024.0 / 44100.0).abs() < 1e-12);
        assert!((secs(FRAMECRC_MP3_48K).unwrap() - 1105.0 / 48000.0).abs() < 1e-12);
        assert!((secs(FRAMECRC_AC3_96K).unwrap() - 256.0 / 48000.0).abs() < 1e-12);
        assert_eq!(secs(FRAMECRC_FLAC), None);
        assert_eq!(secs(FRAMECRC_PCM), None);
        assert_eq!(secs(""), None);
        assert_eq!(secs("garbage\n"), None);
        assert_eq!(secs("0,      -1024,      -1024,     1024\n"), None, "no time base");
    }

    /// The probe encodes silence with the job's own codec arguments; the
    /// rendered track's input is read late by the priming, to the sample.
    #[test]
    fn the_priming_probe_uses_the_jobs_encoder() {
        let mut s = settings(AudioMode::Convert, ContainerFormat::Avi);
        s.audio_codec = AudioCodec::Aac;
        let args = priming_probe_args(&encode_codec_args(&s, None, None), 44100).join(" ");
        assert!(args.contains("-f lavfi -i anullsrc=r=44100:cl=stereo -t 0.2 -c:a aac -b:a "), "{args}");
        assert!(args.ends_with("-f framecrc -"), "{args}");
        let t = RestoredTrack { path: "r.wav".into(), stream: 0, source_streams: 1 };
        let p = EncoderPriming { secs: 1024.0 / 48000.0 };
        assert_eq!(encode_input_args(Some(&t), Some(&p)), vec!["-ss", "0.021334", "-i", "r.wav"]);
        assert!(encode_input_args(None, Some(&p)).is_empty());
    }

    fn avi_trim(start_frame: Option<i32>) -> VideoJob {
        let mut job = delayed_avi(start_frame);
        job.decoder_delay_frames = None;
        job.encoding_settings.container = ContainerFormat::Avi;
        job.encoding_settings.audio_mode = AudioMode::Passthrough;
        job
    }

    /// Task 24: only a Passthrough copy into AVI that the encoder seeks is
    /// cut; every container that stores a stream's start, every other audio
    /// mode and an unseeked job keep their arguments.
    #[test]
    fn the_sound_is_cut_only_for_a_seeked_copy_into_avi() {
        let job = avi_trim(Some(20));
        assert!(needs_sound_cut(&job, None));
        for container in [ContainerFormat::Mp4, ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi] {
            let mut j = job.clone();
            j.encoding_settings.container = container;
            assert_eq!(needs_sound_cut(&j, None), !container.stores_stream_start(), "{container:?}");
        }
        for mode in [AudioMode::Convert, AudioMode::None] {
            let mut j = job.clone();
            j.encoding_settings.audio_mode = mode;
            assert!(!needs_sound_cut(&j, None), "{mode:?}");
        }
        let mut j = job.clone();
        j.source_has_audio = Some(false);
        assert!(!needs_sound_cut(&j, None));
        assert!(!needs_sound_cut(&avi_trim(None), None), "untrimmed: the copy starts at 0");
        assert!(!needs_sound_cut(&avi_trim(Some(0)), None));
        // Beside a rendered track: only when other streams are copied.
        let one = RestoredTrack { path: "r.wav".into(), stream: 0, source_streams: 1 };
        let two = RestoredTrack { source_streams: 2, ..one.clone() };
        assert!(!needs_sound_cut(&job, Some(&one)));
        assert!(needs_sound_cut(&job, Some(&two)));
        // A late video's sound seeked to its first picture counts too.
        let mut j = avi_trim(None);
        j.video_start_offset = Some(0.5);
        j.processing_pipeline = Some(serde_json::from_value(serde_json::json!({
            "audio": {"enabled": true, "startWithPicture": true}
        })).unwrap());
        assert!(j.source_audio_start() > 0.0);
        assert!(needs_sound_cut(&j, Some(&two)));
    }

    /// Task 30: an untrimmed late video into AVI starts its sound at the
    /// first picture, so the copy is cut as a trim's is and the rendered
    /// window starts at the offset, the picture's length long.
    #[test]
    fn an_untrimmed_late_video_into_avi_is_cut_at_the_first_picture() {
        let mut j = avi_trim(None);
        j.video_start_offset = Some(1.0);
        assert!(needs_sound_cut(&j, None));
        j.encoding_settings.container = ContainerFormat::Mkv;
        assert!(!needs_sound_cut(&j, None), "MKV delays the picture instead");

        let mut job: VideoJob = serde_json::from_value(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000030",
            "inputPath": "in.ts", "outputPath": "out.avi",
            "qtgmcParameters": {}, "encodingSettings": {"container": "avi"},
            "totalFrames": 125, "inputFrameRate": 25.0,
            "videoStartOffset": 1.2,
            "processingPipeline": { "deinterlace": { "enabled": false } }
        }))
        .unwrap();
        let w = OutputWindow::for_job(&job);
        assert!((w.start - 1.2).abs() < 1e-9 && (w.duration.unwrap() - 5.0).abs() < 1e-9, "{w:?}");
        job.encoding_settings.container = ContainerFormat::Mkv;
        let w = OutputWindow::for_job(&job);
        assert!(w.start == 0.0 && (w.duration.unwrap() - 6.2).abs() < 1e-9, "{w:?}");
    }

    #[test]
    fn the_cut_probe_reads_codecs_and_packet_lengths() {
        // An MKV's: fine time bases, so the copied streams want the early seek.
        let json = r#"{"packets": [
            {"stream_index": 1, "duration_time": "0.021333"},
            {"stream_index": 2, "duration_time": "0.032000"},
            {"stream_index": 2, "duration_time": "0.032000"},
            {"stream_index": 3, "duration_time": "0.024000"},
            {"stream_index": 3, "duration_time": "N/A"},
            {"stream_index": 3}
        ], "streams": [
            {"index": 1, "codec_name": "pcm_s16le", "time_base": "1/1000"},
            {"index": 2, "codec_name": "ac3", "time_base": "1/1000"},
            {"index": 3, "codec_name": "mp3", "time_base": "1/1000"}
        ]}"#;
        let cut = sound_cut_from_probe(json).unwrap();
        assert_eq!(cut.streams, vec![CutStream::Exact("pcm_s16le"), CutStream::Packet, CutStream::Packet]);
        // PCM's chunk length does not count: only the copied streams'.
        assert!((cut.half_packet - 0.016).abs() < 1e-9, "{}", cut.half_packet);
        assert!(cut.has_packet_streams());
        // An AVI's compressed audio counts in packets: no early seek (the
        // seek's rounding picks the nearest packet). AAC in MP4 does want it.
        let avi = r#"{"packets": [{"stream_index": 1, "duration_time": "0.032000"}],
            "streams": [{"index": 1, "codec_name": "ac3", "time_base": "4/125"}]}"#;
        assert_eq!(sound_cut_from_probe(avi).unwrap().half_packet, 0.0);
        // ...but read from the NUT copy (time base 1/sample rate) it does.
        assert!((sound_cut_from_probe(avi).unwrap().half_any_packet - 0.016).abs() < 1e-9);
        let mp4 = r#"{"packets": [{"stream_index": 1, "duration_time": "0.021333"}],
            "streams": [{"index": 1, "codec_name": "aac", "time_base": "1/48000"}]}"#;
        assert!((sound_cut_from_probe(mp4).unwrap().half_packet - 0.0106665).abs() < 1e-9);
        assert_eq!(parse_time_base("3/125"), Some(0.024));
        assert_eq!(parse_time_base("0/0"), None);
        for codec in EXACT_PCM_CODECS {
            let one = format!(r#"{{"streams": [{{"index": 1, "codec_name": "{codec}"}}]}}"#);
            assert_eq!(sound_cut_from_probe(&one).unwrap().streams, vec![CutStream::Exact(codec)]);
        }
        // AVI refuses these; AAC etc. are copied; no packets → half 0.
        for codec in ["pcm_s16be", "pcm_dvd", "pcm_alaw", "aac", "mp2"] {
            let one = format!(r#"{{"streams": [{{"index": 1, "codec_name": "{codec}"}}]}}"#);
            let c = sound_cut_from_probe(&one).unwrap();
            assert_eq!(c.streams, vec![CutStream::Packet], "{codec}");
            assert_eq!(c.half_packet, 0.0);
        }
        assert!(sound_cut_from_probe(r#"{"streams": []}"#).is_none());
        assert!(sound_cut_from_probe("").is_none());
    }

    /// Task #43: the probe reads where each stream's first packet starts
    /// against the container's start. Captured from ffprobe (FFmpeg 9.0.2)
    /// on sources whose sound ffmpeg encoded (docs/reports/2026-11-avi-copy-priming).
    #[test]
    fn the_cut_probe_reads_a_primed_head() {
        let aac_mkv = r#"{"packets":[{"stream_index":1,"pts_time":"-0.021000","duration_time":"0.021000","side_data_list":[{}]},{"stream_index":1,"pts_time":"0.000000","duration_time":"0.021000"},{"stream_index":1,"pts_time":"0.021000","duration_time":"0.021000"}],"programs":[],"stream_groups":[],"streams":[{"index":1,"codec_name":"aac","time_base":"1/1000"}],"format":{"start_time":"0.000000"}}"#;
        let mp3_mp4 = r#"{"packets":[{"stream_index":1,"pts_time":"-0.023021","duration_time":"0.024000","side_data_list":[{}]},{"stream_index":1,"pts_time":"0.000979","duration_time":"0.024000"},{"stream_index":1,"pts_time":"0.024979","duration_time":"0.024000"}],"programs":[],"stream_groups":[],"streams":[{"index":1,"codec_name":"mp3","time_base":"1/48000"}],"format":{"start_time":"0.000000"}}"#;
        let ac3_mkv = r#"{"packets":[{"stream_index":1,"pts_time":"-0.005000","duration_time":"0.032000","side_data_list":[{}]},{"stream_index":1,"pts_time":"0.027000","duration_time":"0.032000"},{"stream_index":1,"pts_time":"0.059000","duration_time":"0.032000"}],"programs":[],"stream_groups":[],"streams":[{"index":1,"codec_name":"ac3","time_base":"1/1000"}],"format":{"start_time":"0.000000"}}"#;
        let pcm_avi = r#"{"packets":[{"stream_index":1,"pts_time":"0.000000","duration_time":"0.021333"},{"stream_index":1,"pts_time":"0.021333","duration_time":"0.021333"}],"programs":[],"stream_groups":[],"streams":[{"index":1,"codec_name":"pcm_s16le","time_base":"1/48000"}],"format":{"start_time":"0.000000"}}"#;
        let all = [(0u32, 0u32)];
        for (json, head, half) in [(aac_mkv, 0.021, 0.0105), (mp3_mp4, 0.023021, 0.012), (ac3_mkv, 0.005, 0.016)] {
            let c = sound_cut_from_probe(json).unwrap();
            assert!((c.head_before_start[0] - head).abs() < 1e-9, "{c:?}");
            assert!((c.half_packet - half).abs() < 1e-9, "{c:?}");
            assert!(c.starts_early(&all));
        }
        let pcm = sound_cut_from_probe(pcm_avi).unwrap();
        assert_eq!(pcm.head_before_start, vec![0.0]);
        assert!(!pcm.starts_early(&all));
        // An AVI's packets state no pts: they start with the container.
        let no_pts = r#"{"packets":[{"stream_index":1,"duration_time":"0.032000"}],"streams":[{"index":1,"codec_name":"ac3","time_base":"4/125"}],"format":{"start_time":"0.000000"}}"#;
        assert_eq!(sound_cut_from_probe(no_pts).unwrap().head_before_start, vec![0.0]);
        // Measured against the container's start, not 0 (a TS starts late).
        let ts = r#"{"packets":[{"stream_index":1,"pts_time":"1.400000","duration_time":"0.024000"}],"streams":[{"index":1,"codec_name":"mp2","time_base":"1/90000"}],"format":{"start_time":"1.400000"}}"#;
        assert_eq!(sound_cut_from_probe(ts).unwrap().head_before_start, vec![0.0]);
        let neg = r#"{"packets":[{"stream_index":1,"pts_time":"1.379000","duration_time":"0.021000"}],"streams":[{"index":1,"codec_name":"aac","time_base":"1/1000"}],"format":{"start_time":"1.400000"}}"#;
        assert!((sound_cut_from_probe(neg).unwrap().head_before_start[0] - 0.021).abs() < 1e-9);
        // Only a copied stream counts: beside a rendered track of stream 0,
        // stream 1 (FLAC, at 0) is the only one copied.
        let two = r#"{"packets":[{"stream_index":1,"pts_time":"-0.021000","duration_time":"0.021000"},{"stream_index":2,"pts_time":"0.000000","duration_time":"0.021000"}],"streams":[{"index":1,"codec_name":"aac","time_base":"1/1000"},{"index":2,"codec_name":"flac","time_base":"1/1000"}],"format":{"start_time":"0.000000"}}"#;
        let c = sound_cut_from_probe(two).unwrap();
        let t = RestoredTrack { path: "r.wav".into(), stream: 0, source_streams: 2 };
        assert!(!c.starts_early(&copied_streams(Some(&t), 2)));
        assert!(c.starts_early(&copied_streams(None, 2)));
    }

    /// Task #43: an untrimmed Passthrough into AVI may need its head cut;
    /// every other container and mode, and a seeked job (the trim's cut),
    /// do not.
    #[test]
    fn only_an_untrimmed_copy_into_avi_may_cut_its_head() {
        for container in [ContainerFormat::Mp4, ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi] {
            for mode in [AudioMode::Passthrough, AudioMode::Convert, AudioMode::None] {
                for start in [None, Some(0), Some(20)] {
                    let mut j = avi_trim(start);
                    j.encoding_settings.container = container;
                    j.encoding_settings.audio_mode = mode;
                    let may = container == ContainerFormat::Avi && mode == AudioMode::Passthrough && start != Some(20);
                    assert_eq!(may_cut_sound_head(&j, None), may, "{container:?} {mode:?} {start:?}");
                    assert!(!(may_cut_sound_head(&j, None) && needs_sound_cut(&j, None)));
                    assert!(!(may_cut_sound_head(&j, None) && needs_priming_shift(&j)));
                }
            }
        }
        let mut j = avi_trim(None);
        j.source_has_audio = Some(false);
        assert!(!may_cut_sound_head(&j, None));
        let j = avi_trim(None);
        let one = RestoredTrack { path: "r.wav".into(), stream: 0, source_streams: 1 };
        let two = RestoredTrack { path: "r.wav".into(), stream: 0, source_streams: 2 };
        assert!(!may_cut_sound_head(&j, Some(&one)), "the rendered track is all there is");
        assert!(may_cut_sound_head(&j, Some(&two)));
    }

    #[test]
    fn a_cut_maps_each_stream_from_its_own_input() {
        let s = settings(AudioMode::Passthrough, ContainerFormat::Avi);
        let pcm = SoundCut { streams: vec![CutStream::Exact("pcm_s16le")], half_packet: 0.0, half_any_packet: 0.0, head_before_start: vec![] };
        assert_eq!(
            encode_map_args(&s, None, 3, None, Some((&pcm, 3))),
            vec!["-map", "1:a:0", "-map_metadata:s:a:0", "1:s:a:0"]
        );
        assert_eq!(encode_codec_args(&s, None, Some(&pcm)), vec!["-c:a", "copy", "-c:a:0", "pcm_s16le"]);

        let ac3 = SoundCut { streams: vec![CutStream::Packet], half_packet: 0.016, half_any_packet: 0.016, head_before_start: vec![] };
        assert_eq!(
            encode_map_args(&s, None, 3, None, Some((&ac3, 3))),
            vec!["-map", "3:a:0", "-map_metadata:s:a:0", "1:s:a:0"]
        );
        assert_eq!(encode_codec_args(&s, None, Some(&ac3)), vec!["-c:a", "copy", "-copypriorss:a", "0"]);

        // Mixed, from the sound copy (input 3) with the packet input at 4.
        let mixed = SoundCut { streams: vec![CutStream::Exact("pcm_s24le"), CutStream::Packet], half_packet: 0.012, half_any_packet: 0.012, head_before_start: vec![] };
        assert_eq!(
            encode_map_args(&s, None, 3, Some((3, 2)), Some((&mixed, 4))),
            vec!["-map", "3:a:0", "-map", "4:a:1", "-map_metadata:s:a:0", "1:s:a:0", "-map_metadata:s:a:1", "1:s:a:1"]
        );
        assert_eq!(
            encode_codec_args(&s, None, Some(&mixed)),
            vec!["-c:a", "copy", "-c:a:0", "pcm_s24le", "-copypriorss:a", "0"]
        );

        // Beside a rendered track of stream 1: the track first, then 0 and 2.
        let three = SoundCut {
            streams: vec![CutStream::Packet, CutStream::Exact("pcm_s16le"), CutStream::Exact("pcm_u8")],
            half_packet: 0.016,
            half_any_packet: 0.016,
            head_before_start: vec![],
        };
        let t = RestoredTrack { path: "r.wav".into(), stream: 1, source_streams: 3 };
        assert_eq!(
            encode_map_args(&s, Some(&t), 3, None, Some((&three, 4))),
            vec![
                "-map", "3:a:0", "-map", "4:a:0", "-map", "1:a:2",
                "-map_metadata:s:a:0", "1:s:a:1", "-map_metadata:s:a:1", "1:s:a:0",
                "-map_metadata:s:a:2", "1:s:a:2",
            ]
        );
        assert_eq!(
            encode_codec_args(&s, Some(&t), Some(&three)),
            vec!["-c:a", "copy", "-c:a:0", "pcm_s24le", "-c:a:2", "pcm_u8", "-copypriorss:a", "0"]
        );
        assert_eq!(copied_streams(Some(&t), 3), vec![(1, 0), (2, 2)]);
        assert_eq!(copied_streams(None, 2), vec![(0, 0), (1, 1)]);
        // Convert / None ignore a cut.
        assert_eq!(encode_codec_args(&settings(AudioMode::None, ContainerFormat::Avi), None, Some(&mixed)), vec!["-an"]);
        assert!(encode_map_args(&settings(AudioMode::None, ContainerFormat::Avi), None, 3, None, Some((&mixed, 3))).is_empty());
    }

    #[test]
    fn the_sound_copy_is_nut_and_stops_after_the_window() {
        let args = sound_copy_args("in.avi", Some(3.07), Path::new("/t/sound.nut"));
        let joined = args.join(" ");
        assert!(joined.contains("-i in.avi -map 0:a -c copy -t 3.070000"), "{joined}");
        assert!(joined.ends_with("-f nut /t/sound.nut"), "{joined}");
        assert!(!sound_copy_args("in.avi", None, Path::new("s.nut")).contains(&"-t".to_string()));
    }

    /// Rule 9 in the render: no -ss, the head dropped right after the padding,
    /// the input -t counted from the file's start. The same job without the
    /// delay, or further in, reads with -ss exactly as before.
    #[test]
    fn a_delayed_avi_near_its_start_drops_the_head_in_the_chain() {
        let src = SourceAudio { streams: 1, channels: 1, sample_rate: 32_000, duration: Some(3.0) };
        let start = 2.0 * 1001.0 / 30000.0;
        let delayed = OutputWindow { start, duration: Some(2.0), decoder_delay: 2 };
        let plan = AudioPlan::new(&on(), &src, delayed, &Analysis::default(), None);
        assert!(plan.read_skip);
        assert_eq!(
            plan.restore_filters[..3],
            ["aresample=first_pts=0", "atrim=start_sample=2135", "asetpts=PTS-STARTPTS"]
        );
        let args = plan.restore_args("in.avi", Path::new("a.wav"));
        assert!(!args.contains(&"-ss".to_string()), "{args:?}");
        let t = args[args.iter().position(|a| a == "-t").unwrap() + 1].parse::<f64>().unwrap();
        assert!((t - (start + plan.read_duration.unwrap())).abs() < 1e-6, "{t}");

        let plain = AudioPlan::new(&on(), &src, OutputWindow { decoder_delay: 0, ..delayed }, &Analysis::default(), None);
        assert!(!plain.read_skip);
        assert!(plain.restore_args("in.avi", Path::new("a.wav")).join(" ").contains("-ss 0.066733 -t "));
        assert!(!plain.restore_filters.iter().any(|f| f.starts_with("atrim=start_sample")));
        let far = AudioPlan::new(&on(), &src, OutputWindow { start: 1.0, ..delayed }, &Analysis::default(), None);
        assert!(!far.read_skip);
    }

    #[test]
    fn the_analysis_seeks_after_the_input_only_where_the_seek_fails() {
        let a = analysis_args("in.avi", 0, 0.0667, 2, 32_000).join(" ");
        assert!(a.contains("-i in.avi -ss 0.067 -t 60"), "{a}");
        let b = analysis_args("in.avi", 0, 0.0667, 0, 32_000).join(" ");
        assert!(b.contains("-ss 0.067 -t 60 -i in.avi"), "{b}");
        let c = analysis_args("in.avi", 0, 0.0, 2, 32_000).join(" ");
        assert!(c.contains("-ss 0.000 -t 60 -i in.avi"), "{c}");
    }

    #[test]
    fn passthrough_copies_the_others_and_encodes_the_restored_track() {
        let t = RestoredTrack { path: "r.wav".into(), stream: 0, source_streams: 2 };
        assert_eq!(
            encode_codec_args(&settings(AudioMode::Passthrough, ContainerFormat::Mkv), Some(&t), None),
            vec!["-c:a", "copy", "-c:a:0", "flac"]
        );
        assert_eq!(
            encode_codec_args(&settings(AudioMode::Passthrough, ContainerFormat::Mp4), Some(&t), None),
            vec!["-c:a", "copy", "-c:a:0", "aac", "-b:a:0", "192k"]
        );
        // AVI, beside a codec that is not an intermediate: 24-bit PCM too.
        assert_eq!(
            encode_codec_args(&settings(AudioMode::Passthrough, ContainerFormat::Avi), Some(&t), None),
            vec!["-c:a", "copy", "-c:a:0", "pcm_s24le"]
        );
        for codec in [VideoCodec::FFV1, VideoCodec::Huffyuv, VideoCodec::Ffvhuff, VideoCodec::H264] {
            let mut avi = settings(AudioMode::Passthrough, ContainerFormat::Avi);
            avi.codec = codec;
            assert_eq!(encode_codec_args(&avi, Some(&t), None), vec!["-c:a", "copy", "-c:a:0", "pcm_s24le"], "{codec:?}");
        }
        // Beside ProRes in MOV: 24-bit PCM, with no bitrate.
        let mut prores = settings(AudioMode::Passthrough, ContainerFormat::Mov);
        prores.codec = VideoCodec::ProResHQ;
        assert_eq!(encode_codec_args(&prores, Some(&t), None), vec!["-c:a", "copy", "-c:a:0", "pcm_s24le"]);
        // Beside v210, in each of its containers.
        for container in [ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi] {
            let mut v210 = settings(AudioMode::Passthrough, container);
            v210.codec = VideoCodec::V210;
            assert_eq!(encode_codec_args(&v210, Some(&t), None), vec!["-c:a", "copy", "-c:a:0", "pcm_s24le"], "{container:?}");
        }
        // Convert → PCM is the user's choice and stays 16-bit, in AVI too.
        let mut convert_pcm = settings(AudioMode::Convert, ContainerFormat::Mov);
        convert_pcm.codec = VideoCodec::ProResHQ;
        convert_pcm.audio_codec = AudioCodec::Pcm;
        assert_eq!(encode_codec_args(&convert_pcm, Some(&t), None), vec!["-c:a", "pcm_s16le"]);
        let mut convert_avi = settings(AudioMode::Convert, ContainerFormat::Avi);
        convert_avi.codec = VideoCodec::FFV1;
        convert_avi.audio_codec = AudioCodec::Pcm;
        assert_eq!(encode_codec_args(&convert_avi, Some(&t), None), vec!["-c:a", "pcm_s16le"]);
        // Without a track, exactly what the encoder always did.
        assert_eq!(encode_codec_args(&settings(AudioMode::Passthrough, ContainerFormat::Mp4), None, None), vec!["-c:a", "copy"]);
        let mut convert = settings(AudioMode::Convert, ContainerFormat::Mp4);
        convert.audio_codec = AudioCodec::Opus;
        assert_eq!(encode_codec_args(&convert, Some(&t), None), vec!["-c:a", "libopus", "-b:a", "192k"]);
        assert_eq!(encode_codec_args(&settings(AudioMode::None, ContainerFormat::Mp4), None, None), vec!["-an"]);
    }

    #[test]
    fn deep_filter_and_loudness_args() {
        let p = AudioRestorationParameters { deep_filter: true, deep_filter_attenuation: 24, loudness_normalize: true, loudness_target: -23.0, ..on() };
        let plan = AudioPlan::new(&p, &SourceAudio { sample_rate: 44_100, ..stereo48() }, window(0.0, 2.0), &Analysis::default(), None);
        assert_eq!(
            plan.deep_filter_args(Path::new("w/a.wav"), Path::new("w/dfn")).unwrap(),
            vec!["-D", "-a", "24", "-o", "w/dfn", "w/a.wav"]
        );
        // The DeepFilterNet input keeps the source rate; the output is 48 kHz.
        assert!(plan.restore_filters.ends_with(&["apad=whole_len=88200".to_string(), "atrim=end_sample=88200".to_string()]));
        assert_eq!(plan.out_rate, 48_000);
        let m = plan.measure_args(Path::new("b.wav")).unwrap();
        assert!(m.contains(&"loudnorm=I=-23:TP=-1.5:LRA=11:print_format=json".to_string()));
        assert_eq!(&m[m.len() - 3..], ["-f", "null", "-"]);
        // Without a measurement (silence), no loudnorm at all — never one-pass.
        assert!(!plan.finish_filter_chain(None).contains("loudnorm"));
    }

    #[test]
    fn numbers_are_plain() {
        assert_eq!(num(12.0), "12");
        assert_eq!(num(-1.5), "-1.5");
        assert_eq!(num(0.891251), "0.8913");
        assert_eq!(num(-0.0), "0");
        assert_eq!(num_precise(1.000999), "1.000999");
    }

    /// The restored track is 24-bit PCM beside an editing intermediate (ProRes,
    /// v210) in every container, and in AVI beside every codec; otherwise FLAC
    /// in MKV (also 24-bit) and AAC in MP4/MOV. Nothing is 16-bit any more.
    #[test]
    fn restored_passthrough_keeps_24_bits_where_it_can() {
        let all = [ContainerFormat::Mp4, ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi];
        for video in VideoCodec::ALL.iter().copied() {
            for container in all {
                let codec = restored_passthrough_codec(container, video);
                let pcm24 = video.is_editing_intermediate() || container == ContainerFormat::Avi;
                assert_eq!(codec == RestoredTrackCodec::Pcm24, pcm24, "{video:?}/{container:?}");
                if !pcm24 {
                    let expected = if container == ContainerFormat::Mkv { RestoredTrackCodec::Flac } else { RestoredTrackCodec::Aac };
                    assert_eq!(codec, expected, "{video:?}/{container:?}");
                }
            }
        }
        assert!(VideoCodec::ProResHQ.is_editing_intermediate() && VideoCodec::V210.is_editing_intermediate());
        assert_eq!(restored_passthrough_codec(ContainerFormat::Mov, VideoCodec::H264), RestoredTrackCodec::Aac);
        assert_eq!(restored_passthrough_codec(ContainerFormat::Mp4, VideoCodec::H265), RestoredTrackCodec::Aac);
        assert_eq!(restored_passthrough_codec(ContainerFormat::Mkv, VideoCodec::FFV1), RestoredTrackCodec::Flac);
        for video in [VideoCodec::FFV1, VideoCodec::Huffyuv, VideoCodec::Ffvhuff, VideoCodec::H264] {
            assert_eq!(restored_passthrough_codec(ContainerFormat::Avi, video), RestoredTrackCodec::Pcm24, "{video:?}");
        }
    }

    /// The restored track's encoder names, and the user-facing PCM wire value
    /// that this must not change.
    #[test]
    fn restored_track_codec_names_and_the_pcm_wire_value() {
        let names: Vec<_> = RestoredTrackCodec::ALL.iter().map(|c| (c.ffmpeg_name(), c.takes_bitrate())).collect();
        assert_eq!(names, vec![("aac", true), ("flac", false), ("pcm_s24le", false)]);
        assert_eq!(AudioCodec::Pcm.ffmpeg_name(), "pcm_s16le");
        assert_eq!(serde_json::to_string(&AudioCodec::Pcm).unwrap(), "\"pcm_s16le\"");
    }
}
