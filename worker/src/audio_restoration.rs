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
    AudioCodec, AudioMode, AudioRestorationParameters, ChannelFix, ContainerFormat,
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
        Self { start, duration }
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
        if self.read_start > 0.0 {
            args.extend(["-ss".into(), format!("{:.6}", self.read_start)]);
        }
        if let Some(t) = self.read_duration {
            args.extend(["-t".into(), format!("{:.6}", t)]);
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

/// The encoder's input for the rendered track (comes after its other inputs).
pub fn encode_input_args(track: Option<&RestoredTrack>) -> Vec<String> {
    match track {
        Some(t) => vec!["-i".into(), t.path.to_string_lossy().to_string()],
        None => Vec::new(),
    }
}

/// The encoder's audio `-map`s. Without a rendered track, every source audio
/// stream (`1:a?`) as always. With one, the rendered track first — it is
/// the one a player picks by default — then the source's other audio streams
/// untouched, in their order, with the restored stream's tags (language,
/// title) carried over to the rendered one.
pub fn encode_map_args(settings: &EncodingSettings, track: Option<&RestoredTrack>, track_input: usize) -> Vec<String> {
    if settings.audio_mode == AudioMode::None {
        return Vec::new();
    }
    let Some(t) = track else {
        return vec!["-map".into(), "1:a?".into()];
    };
    let mut args = vec!["-map".into(), format!("{track_input}:a:0")];
    let others: Vec<u32> = (0..t.source_streams).filter(|k| *k != t.stream).collect();
    for k in &others {
        args.extend(["-map".into(), format!("1:a:{k}")]);
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
/// at the chosen quality in MP4/MOV, PCM in AVI — and PCM whatever the
/// container beside an editing intermediate (ProRes, v210).
pub fn encode_codec_args(settings: &EncodingSettings, track: Option<&RestoredTrack>) -> Vec<String> {
    let mut args = Vec::new();
    match settings.audio_mode {
        AudioMode::Passthrough => {
            args.extend(["-c:a".into(), "copy".into()]);
            if track.is_some() {
                let codec = restored_passthrough_codec(settings.container, settings.codec);
                args.extend(["-c:a:0".into(), codec.ffmpeg_name().into()]);
                if !codec.is_lossless() {
                    args.extend(["-b:a:0".into(), format!("{}k", settings.audio_quality.bitrate())]);
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

/// What a restored track is encoded as when the audio setting is Passthrough.
///
/// An editing intermediate (ProRes, v210) gets PCM in every container: its
/// soundtrack will be encoded again on delivery, so a lossy restored track
/// would be two lossy generations, and PCM is what editors expect beside it.
pub fn restored_passthrough_codec(container: ContainerFormat, video: VideoCodec) -> AudioCodec {
    if video.is_editing_intermediate() {
        return AudioCodec::Pcm;
    }
    match container {
        ContainerFormat::Mkv => AudioCodec::Flac,
        ContainerFormat::Mp4 | ContainerFormat::Mov => AudioCodec::Aac,
        ContainerFormat::Avi => AudioCodec::Pcm,
    }
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
            .args(["-v", "error", "-nostdin", "-ss", &format!("{start:.3}"), "-t", &format!("{ANALYSIS_SECONDS}"),
                   "-i", input, "-map", &format!("0:a:{}", p.stream_index),
                   "-ar", &rate.to_string(), "-f", "f32le", "-"])
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
    use crate::models::{AudioQuality, ProcessingPipeline, QTGMCParameters, DeinterlaceMethod, FrameRateParameters, FrameRateTarget};

    fn stereo48() -> SourceAudio {
        SourceAudio { streams: 1, channels: 2, sample_rate: 48_000, duration: Some(60.0) }
    }

    fn window(start: f64, d: f64) -> OutputWindow {
        OutputWindow { start, duration: Some(d) }
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
            for offset in [0, 250, -250] {
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
                let plan = AudioPlan::new(&p, &stereo48(), window(1.0, 30.0), &Analysis::default(), drift);
                let ranks: Vec<usize> = names(&plan.restore_filters)
                    .iter()
                    .enumerate()
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
        assert_eq!(encode_map_args(&s, None, 3), vec!["-map", "1:a?"]);
        let t = RestoredTrack { path: "r.wav".into(), stream: 1, source_streams: 3 };
        assert_eq!(
            encode_map_args(&s, Some(&t), 3),
            vec![
                "-map", "3:a:0", "-map", "1:a:0", "-map", "1:a:2",
                "-map_metadata:s:a:0", "1:s:a:1", "-map_metadata:s:a:1", "1:s:a:0",
                "-map_metadata:s:a:2", "1:s:a:2",
            ]
        );
        assert!(encode_map_args(&settings(AudioMode::None, ContainerFormat::Mkv), Some(&t), 3).is_empty());
        assert_eq!(encode_input_args(Some(&t)), vec!["-i", "r.wav"]);
        assert!(encode_input_args(None).is_empty());
    }

    #[test]
    fn passthrough_copies_the_others_and_encodes_the_restored_track() {
        let t = RestoredTrack { path: "r.wav".into(), stream: 0, source_streams: 2 };
        assert_eq!(
            encode_codec_args(&settings(AudioMode::Passthrough, ContainerFormat::Mkv), Some(&t)),
            vec!["-c:a", "copy", "-c:a:0", "flac"]
        );
        assert_eq!(
            encode_codec_args(&settings(AudioMode::Passthrough, ContainerFormat::Mp4), Some(&t)),
            vec!["-c:a", "copy", "-c:a:0", "aac", "-b:a:0", "192k"]
        );
        assert_eq!(
            encode_codec_args(&settings(AudioMode::Passthrough, ContainerFormat::Avi), Some(&t)),
            vec!["-c:a", "copy", "-c:a:0", "pcm_s16le"]
        );
        // Beside ProRes in MOV: PCM, with no bitrate.
        let mut prores = settings(AudioMode::Passthrough, ContainerFormat::Mov);
        prores.codec = VideoCodec::ProResHQ;
        assert_eq!(encode_codec_args(&prores, Some(&t)), vec!["-c:a", "copy", "-c:a:0", "pcm_s16le"]);
        // Without a track, exactly what the encoder always did.
        assert_eq!(encode_codec_args(&settings(AudioMode::Passthrough, ContainerFormat::Mp4), None), vec!["-c:a", "copy"]);
        let mut convert = settings(AudioMode::Convert, ContainerFormat::Mp4);
        convert.audio_codec = AudioCodec::Opus;
        assert_eq!(encode_codec_args(&convert, Some(&t)), vec!["-c:a", "libopus", "-b:a", "192k"]);
        assert_eq!(encode_codec_args(&settings(AudioMode::None, ContainerFormat::Mp4), None), vec!["-an"]);
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

    /// An editing intermediate's (ProRes, v210) restored track is PCM in
    /// every container; every other codec keeps the container's choice.
    #[test]
    fn restored_passthrough_is_pcm_beside_intermediates() {
        let all = [ContainerFormat::Mp4, ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi];
        for video in VideoCodec::ALL.iter().copied().filter(|c| c.is_editing_intermediate()) {
            for container in all {
                assert_eq!(restored_passthrough_codec(container, video), AudioCodec::Pcm, "{video:?}/{container:?}");
            }
        }
        assert!(VideoCodec::ProResHQ.is_editing_intermediate() && VideoCodec::V210.is_editing_intermediate());
        assert_eq!(restored_passthrough_codec(ContainerFormat::Mov, VideoCodec::H264), AudioCodec::Aac);
        assert_eq!(restored_passthrough_codec(ContainerFormat::Mp4, VideoCodec::H265), AudioCodec::Aac);
        assert_eq!(restored_passthrough_codec(ContainerFormat::Mkv, VideoCodec::FFV1), AudioCodec::Flac);
        assert_eq!(restored_passthrough_codec(ContainerFormat::Avi, VideoCodec::H264), AudioCodec::Pcm);
    }
}
