//! VapourBox Worker - CLI video processing tool
//!
//! This worker process receives a job configuration file via --config argument,
//! generates a VapourSynth script, and runs the vspipe | ffmpeg pipeline.
//! Progress is reported via JSON messages on stdout.
//!
//! Preview mode: Use --preview --frame N to generate a single processed frame
//! as PNG output to stdout (binary).
//!
//! DVD modes:
//!   --dvd-info <path>: Enumerate DVD titles, output JSON to stdout
//!   --dvd-extract <path> --title N [--chapters S-E] --output <path>: Extract DVD title

use anyhow::{Context, Result};
use clap::Parser;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

mod models;
mod dependency_locator;
mod dvd_reader;
mod pipeline_executor;
mod pixel_format;
mod progress_reporter;
mod script_generator;
mod subtitle_generator;
mod platform;

use models::VideoJob;
use pipeline_executor::PipelineExecutor;
use progress_reporter::ProgressReporter;
use script_generator::ScriptGenerator;
use subtitle_generator::SubtitleGenerator;

/// Command-line arguments
#[derive(Parser, Debug)]
#[command(name = "vapourbox-worker")]
#[command(about = "Video processing worker using VapourSynth")]
#[command(version)]
struct Args {
    /// Path to the job configuration JSON file
    #[arg(long)]
    config: Option<PathBuf>,

    /// Preview mode: generate a single processed frame as PNG to stdout
    #[arg(long)]
    preview: bool,

    /// Frame number to extract in preview mode (required with --preview)
    #[arg(long)]
    frame: Option<i32>,

    /// DVD info mode: enumerate titles from a DVD mount point or VIDEO_TS folder
    #[arg(long)]
    dvd_info: Option<String>,

    /// DVD extract mode: extract a title from a DVD
    #[arg(long)]
    dvd_extract: Option<String>,

    /// Title number to extract (required with --dvd-extract)
    #[arg(long)]
    title: Option<u32>,

    /// Chapter range to extract (e.g., "1-5", optional with --dvd-extract)
    #[arg(long)]
    chapters: Option<String>,

    /// Output file path (required with --dvd-extract)
    #[arg(long)]
    output: Option<PathBuf>,

    /// Probe mode: report whether a usable OpenCL device is available as JSON
    /// (`{"opencl": true|false}`) to stdout and exit. Used by the app to warn
    /// when OpenCL-only options (knlmeanscl denoiser, QTGMC OpenCL) won't work.
    #[arg(long)]
    probe_opencl: bool,

    /// Probe mode: report this machine's CPU architecture and the instruction
    /// set extensions relevant to plugin dispatch, as JSON, and exit.
    ///
    /// Exists because a green test run is otherwise silent about the hardware
    /// it ran on, and several bundled plugins pick a code path from exactly
    /// these bits. GitHub's hosted Windows fleet is mixed for AVX-512, so a
    /// passing Windows job may or may not have exercised the AVX-512 kernels —
    /// which is how the CTMF crash reached main and then looked spontaneous.
    #[arg(long)]
    probe_cpu: bool,
}

fn main() -> ExitCode {
    let args = Args::parse();

    // Become our own process-group leader, so the app can tear down this worker
    // *and everything it spawns* with a single signal to -pid.
    //
    // Without this, killing the worker leaves vspipe and ffmpeg running. They
    // usually die shortly afterwards, but only incidentally: their pipes close
    // with the worker and they take EPIPE the next time they write. A child
    // blocked on slow input — reading a source over a network share is the
    // reported case — writes nothing for minutes and so never notices, and is
    // left encoding a job nobody is waiting for.
    //
    // Nothing kills them deliberately today. The encode path's
    // PipelineExecutor::terminate() only covers the children it tracks on
    // `self`, and preview mode never even installs a signal handler (it returns
    // below before ctrlc is set up), so a SIGTERM there kills the worker outright
    // without unwinding — Drop never runs and its children are simply abandoned.
    // Rather than add bookkeeping to each path, put everything in one group.
    //
    // Best-effort: if this fails the app falls back to signalling the pid alone,
    // which is exactly today's behaviour.
    #[cfg(unix)]
    {
        use nix::unistd::{setpgid, Pid};
        let _ = setpgid(Pid::from_raw(0), Pid::from_raw(0));
    }

    // DVD info mode: enumerate titles, output JSON to stdout
    if let Some(ref dvd_path) = args.dvd_info {
        return run_dvd_info(dvd_path);
    }

    // DVD extract mode: extract title to file
    if let Some(ref dvd_path) = args.dvd_extract {
        return run_dvd_extract(&args, dvd_path);
    }

    // OpenCL probe mode: emit availability as JSON and exit (no progress stream).
    if args.probe_cpu {
        return run_probe_cpu();
    }

    if args.probe_opencl {
        return run_probe_opencl();
    }

    // Preview mode outputs raw PNG to stdout - no JSON messages
    if args.preview {
        return run_preview_mode(&args);
    }

    // Normal processing mode requires --config
    if args.config.is_none() {
        eprintln!("Error: --config is required for processing mode");
        return ExitCode::from(1);
    }

    let reporter = ProgressReporter::new();

    // Set up cancellation flag
    let cancelled = Arc::new(AtomicBool::new(false));
    let cancelled_clone = cancelled.clone();

    // Handle SIGTERM/SIGINT for graceful cancellation
    if let Err(e) = ctrlc::set_handler(move || {
        cancelled_clone.store(true, Ordering::SeqCst);
    }) {
        reporter.send_error(&format!("Failed to set signal handler: {}", e));
        return ExitCode::from(1);
    }

    match run_worker(args.config.as_ref().unwrap(), &reporter, cancelled) {
        Ok(output_path) => {
            reporter.send_complete(true, Some(&output_path));
            // Small delay to ensure stdout is flushed and received by parent process
            std::thread::sleep(std::time::Duration::from_millis(100));
            ExitCode::SUCCESS
        }
        Err(e) => {
            // Check if this was a cancellation
            if e.to_string().contains("cancelled") {
                reporter.send_log(models::LogLevel::Info, "Job cancelled by user");
                reporter.send_complete(false, None);
                ExitCode::from(130) // Standard exit code for SIGINT
            } else {
                reporter.send_error(&format!("{:#}", e));
                reporter.send_complete(false, None);
                ExitCode::from(1)
            }
        }
    }
}

/// Probe whether a usable OpenCL device is available and print the result as
/// JSON to stdout. The app calls this once and uses it to warn when an
/// OpenCL-only option (knlmeanscl denoiser, QTGMC OpenCL) is selected on a
/// machine with no usable device. Falls back to `false` if deps can't be
/// located (no probe possible ⇒ assume unavailable, so the app warns rather
/// than letting the job fail with a cryptic VapourSynth error).
fn run_probe_opencl() -> ExitCode {
    // Report both capabilities: `opencl` gates the QTGMC OpenCL/NNEDI3CL path,
    // `knlm` gates the knlmeanscl denoiser (a distinct probe — KNLMeansCL can
    // fail where NNEDI3CL succeeds). Both fall back to false if deps can't be
    // located, so the app warns rather than letting a job fail cryptically.
    let (opencl, knlm) = dependency_locator::DependencyLocator::new()
        .map(|deps| (deps.opencl_available(), deps.knlm_available()))
        .unwrap_or((false, false));
    println!("{}", serde_json::json!({ "opencl": opencl, "knlm": knlm }));
    ExitCode::SUCCESS
}


/// Report the CPU architecture and the dispatch-relevant instruction set
/// extensions as JSON.
///
/// This is diagnostic, not a decision: nothing in the pipeline reads it. It
/// exists so a test run can *state* which hardware it tested, because several
/// bundled plugins select a code path from these bits and a green run is
/// otherwise silent about which path it took.
///
/// The motivating case: `ctmf.CTMF`'s AVX-512 kernel for 8-bit input crashes
/// the process, and GitHub's hosted Windows runners are a mixed fleet — so the
/// nightly passed for days on non-AVX-512 machines, went red the night it drew
/// an AVX-512 one, and looked like a spontaneous failure against an unchanged
/// tree. Printing this next to the result turns "it passed" into "it passed on
/// this hardware".
fn run_probe_cpu() -> ExitCode {
    let features = detected_cpu_features();
    println!(
        "{}",
        serde_json::json!({
            "arch": std::env::consts::ARCH,
            "features": features,
        })
    );
    ExitCode::SUCCESS
}

/// The instruction set extensions that bundled plugins actually dispatch on.
///
/// Deliberately a short list rather than everything detectable: these are the
/// ones that change which kernel a plugin runs here. Detection is a runtime
/// CPUID query, so it reports what the process can really execute — including
/// under emulation, where an x86_64 worker on Apple Silicon correctly reports
/// whatever Rosetta exposes rather than what the binary was compiled for.
#[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
fn detected_cpu_features() -> Vec<&'static str> {
    let mut features = Vec::new();
    for (name, present) in [
        ("sse2", std::is_x86_feature_detected!("sse2")),
        ("sse4.1", std::is_x86_feature_detected!("sse4.1")),
        ("avx", std::is_x86_feature_detected!("avx")),
        ("avx2", std::is_x86_feature_detected!("avx2")),
        ("fma", std::is_x86_feature_detected!("fma")),
        ("avx512f", std::is_x86_feature_detected!("avx512f")),
    ] {
        if present {
            features.push(name);
        }
    }
    features
}

#[cfg(target_arch = "aarch64")]
fn detected_cpu_features() -> Vec<&'static str> {
    // NEON is architectural on aarch64, so it is reported unconditionally
    // rather than probed. It is worth naming: it is why the ARM bundles prefer
    // dubhater's nnedi3 over znedi3, whose SIMD kernels are x86-only.
    vec!["neon"]
}

#[cfg(not(any(target_arch = "x86", target_arch = "x86_64", target_arch = "aarch64")))]
fn detected_cpu_features() -> Vec<&'static str> {
    Vec::new()
}

/// Run DVD info mode: enumerate titles and output JSON to stdout.
fn run_dvd_info(dvd_path: &str) -> ExitCode {
    match dvd_reader::enumerate_titles(dvd_path) {
        Ok(info) => {
            match serde_json::to_string_pretty(&info) {
                Ok(json) => {
                    println!("{}", json);
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("Error serializing DVD info: {}", e);
                    ExitCode::from(1)
                }
            }
        }
        Err(e) => {
            // Output error as JSON for the Flutter app to parse
            let error_msg = format!("{:#}", e);
            let error_json = serde_json::json!({
                "type": "error",
                "message": error_msg,
            });
            println!("{}", error_json);
            ExitCode::from(1)
        }
    }
}

/// Run DVD extract mode: extract a title to an MPEG-PS file.
fn run_dvd_extract(args: &Args, dvd_path: &str) -> ExitCode {
    let title = match args.title {
        Some(t) => t,
        None => {
            eprintln!("Error: --title is required with --dvd-extract");
            return ExitCode::from(1);
        }
    };

    let output = match args.output {
        Some(ref p) => p.clone(),
        None => {
            eprintln!("Error: --output is required with --dvd-extract");
            return ExitCode::from(1);
        }
    };

    // Parse chapter range (e.g., "1-5")
    let (start_chapter, end_chapter) = if let Some(ref ch) = args.chapters {
        let parts: Vec<&str> = ch.split('-').collect();
        match parts.len() {
            1 => {
                let ch: u32 = parts[0].parse().unwrap_or(1);
                (Some(ch), Some(ch))
            }
            2 => {
                let start: u32 = parts[0].parse().unwrap_or(1);
                let end: u32 = parts[1].parse().unwrap_or(start);
                (Some(start), Some(end))
            }
            _ => (None, None),
        }
    } else {
        (None, None)
    };

    let reporter = ProgressReporter::new();

    match dvd_reader::extract_title(dvd_path, title, start_chapter, end_chapter, &output, &reporter) {
        Ok(()) => {
            reporter.send_complete(true, Some(&output.to_string_lossy()));
            ExitCode::SUCCESS
        }
        Err(e) => {
            reporter.send_error(&format!("{:#}", e));
            reporter.send_complete(false, None);
            ExitCode::from(1)
        }
    }
}

/// Run in preview mode - generate single frame PNG to stdout
fn run_preview_mode(args: &Args) -> ExitCode {
    let frame = match args.frame {
        Some(f) => f,
        None => {
            eprintln!("Error: --frame is required with --preview");
            return ExitCode::from(1);
        }
    };

    let config_path = match args.config {
        Some(ref p) => p,
        None => {
            eprintln!("Error: --config is required with --preview");
            return ExitCode::from(1);
        }
    };

    // Load job configuration
    let config_content = match std::fs::read_to_string(config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error reading config: {}", e);
            return ExitCode::from(1);
        }
    };

    let job: VideoJob = match serde_json::from_str(&config_content) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("Error parsing config: {}", e);
            return ExitCode::from(1);
        }
    };

    // The frame index is passed straight through to the worker — no
    // time-conversion round-trip — so the rendered frame is exactly the one the
    // caller asked for (see generate_preview's frame-accurate windowing).
    eprintln!("Preview: source frame {} (fps: {:.2})", frame, job.input_frame_rate.unwrap_or(29.97));

    // Execute preview (extracts frames with ffmpeg, processes with VapourSynth)
    let executor = match PipelineExecutor::new(ProgressReporter::new()) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("Error creating executor: {}", e);
            return ExitCode::from(1);
        }
    };

    match executor.generate_preview(&job, frame) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("Error generating preview: {}", e);
            ExitCode::from(1)
        }
    }
}

fn run_worker(
    config_path: &PathBuf,
    reporter: &ProgressReporter,
    cancelled: Arc<AtomicBool>,
) -> Result<String> {
    // Load job configuration
    reporter.send_log(models::LogLevel::Info, "Loading job configuration...");
    let config_content = std::fs::read_to_string(config_path)
        .with_context(|| format!("Failed to read config file: {:?}", config_path))?;
    let mut job: VideoJob = serde_json::from_str(&config_content)
        .with_context(|| "Failed to parse job configuration")?;

    reporter.send_log(
        models::LogLevel::Info,
        &format!("Processing: {}", job.input_path),
    );

    // Subtitle-only mode: skip video processing, generate subtitles from input
    if job.subtitle_only {
        return run_subtitle_only(&job, reporter, cancelled);
    }

    reporter.send_log(
        models::LogLevel::Debug,
        &format!("QTGMC params: opencl={:?}, tff={:?}, preset={}",
            job.qtgmc_parameters.opencl,
            job.qtgmc_parameters.tff,
            job.qtgmc_parameters.preset.as_str()),
    );

    // Resolve deps once for the pre-generation probes below.
    let deps = dependency_locator::DependencyLocator::new().ok();

    // ------------------------------------------------------------------
    // Pre-encode transcription
    // ------------------------------------------------------------------
    // Whisper used to run only after the encode, which made burn-in
    // impossible: the encoder needs the subtitle file while it is running, and
    // a transcript that does not exist yet cannot be drawn into the picture.
    //
    // Transcribing the SOURCE instead means honouring the trim. The encoder
    // seeks the audio input to the trim point, so the output's audio starts
    // there — a transcript of the whole source would put every cue early by
    // exactly the trimmed-off head. Nothing else retimes audio: IVTC and
    // frame-rate conversion change the video timeline only.
    let mut whisper_srt: Option<std::path::PathBuf> = None;
    if let Some(ref sub_settings) = job.subtitle_settings {
        if sub_settings.enabled && job.burn_in_subtitle_path.is_none() {
            let fps = job.input_frame_rate.unwrap_or(29.97);
            let window = match (job.start_frame, job.end_frame) {
                (Some(start), Some(end)) if end >= start => Some((
                    start as f64 / fps,
                    Some((end - start + 1) as f64 / fps),
                )),
                (Some(start), None) => Some((start as f64 / fps, None)),
                (None, Some(end)) => Some((0.0, Some((end + 1) as f64 / fps))),
                _ => None,
            };
            let srt_target = std::path::Path::new(&job.output_path).with_extension("srt");
            match dependency_locator::DependencyLocator::new().and_then(|d| {
                SubtitleGenerator::new(reporter.clone(), d).transcribe(
                    &job.input_path,
                    sub_settings,
                    window,
                    &srt_target,
                    || cancelled.load(Ordering::SeqCst),
                )
            }) {
                Ok(Some(path)) => {
                    // Burn-in reads this during the encode; the mux pass below
                    // reads it afterwards.
                    if sub_settings.output.burns_in() {
                        job.burn_in_subtitle_path = Some(path.to_string_lossy().to_string());
                    }
                    whisper_srt = Some(path);
                }
                Ok(None) => {}
                Err(e) => reporter.send_log(
                    models::LogLevel::Warning,
                    &format!("Subtitle generation failed: {e}"),
                ),
            }
        }
    }

    // Resolve the frame count if the caller didn't supply one. The Flutter app
    // probes and sets total_frames; direct callers (tests, CLI) may omit it, and
    // the script's pipe_source needs an exact length (it builds a fixed-size
    // clip). Without this the worker defaults to 1 frame and the whole output is
    // a single frame. total_frames must be the *post-trim* count the decoder
    // will actually pipe (trimming is decoder-side: -ss + -frames:v), matching
    // the decoder's own range logic in pipeline_executor.
    if job.total_frames.is_none() {
        if let Some(full) = deps.as_ref().and_then(|d| d.probe_frame_count(&job.input_path)) {
            let effective = match (job.start_frame, job.end_frame) {
                (Some(s), Some(e)) => (e - s + 1).max(0),
                (None, Some(e)) => e + 1,
                (Some(s), None) => (full - s).max(0),
                (None, None) => full,
            };
            reporter.send_log(
                models::LogLevel::Debug,
                &format!("Probed input frame count: {} (effective after trim: {})", full, effective),
            );
            job.total_frames = Some(effective);
        }
    }

    // Generate VapourSynth script
    reporter.send_log(models::LogLevel::Info, "Generating VapourSynth script...");
    // Detect OpenCL availability so QTGMC falls back to CPU NNEDI3 on machines
    // without a usable OpenCL device (headless CI, VMs, remote desktop).
    let opencl_available = deps.as_ref().map(|d| d.opencl_available()).unwrap_or(true);
    // Detect knlmeanscl availability separately (plugin + usable OpenCL device);
    // when unavailable the knlmeanscl denoiser is downgraded to dfttest.
    let knlm_available = deps.as_ref().map(|d| d.knlm_available()).unwrap_or(true);
    let script_generator = ScriptGenerator::new()?
        .with_opencl_available(opencl_available)
        .with_knlm_available(knlm_available)
        .with_zsmooth_plugin(deps.as_ref().and_then(|d| d.zsmooth_plugin()));
    let script_path = script_generator
        .generate(&job)
        .with_context(|| "Failed to generate VapourSynth script")?;

    reporter.send_log(
        models::LogLevel::Debug,
        &format!("Script written to: {:?}", script_path),
    );

    // Execute pipeline.
    //
    // Retry on the rare VapourSynth plugin-autoload skip (a needed plugin
    // namespace fails to register, surfacing as e.g. "no attribute or namespace
    // named fmtc"). It's intermittent under heavy parallel load; a fresh vspipe
    // re-runs autoload and almost always succeeds, so retry with a new process
    // rather than failing the job. Only this specific marker triggers a retry —
    // genuine errors propagate immediately.
    reporter.send_log(models::LogLevel::Info, "Starting encoding pipeline...");
    const MAX_PIPELINE_ATTEMPTS: u32 = 3;
    let mut attempt = 1;
    loop {
        let mut executor = PipelineExecutor::new(reporter.clone())?;
        match executor.execute(&script_path, &job, || cancelled.load(Ordering::SeqCst)) {
            Ok(()) => break,
            Err(e)
                if attempt < MAX_PIPELINE_ATTEMPTS
                    && !cancelled.load(Ordering::SeqCst)
                    && e.to_string().contains(pipeline_executor::PLUGIN_AUTOLOAD_MARKER) =>
            {
                reporter.send_log(
                    models::LogLevel::Warning,
                    &format!(
                        "VapourSynth plugin autoload failed (attempt {}/{}); retrying encode",
                        attempt, MAX_PIPELINE_ATTEMPTS
                    ),
                );
                attempt += 1;
            }
            Err(e) => return Err(e),
        }
    }

    // If cancelled, remove partial output
    if cancelled.load(Ordering::SeqCst) {
        if let Err(e) = std::fs::remove_file(&job.output_path) {
            reporter.send_log(
                models::LogLevel::Warning,
                &format!("Failed to remove partial output: {}", e),
            );
        }
        anyhow::bail!("Job cancelled");
    }

    reporter.send_log(models::LogLevel::Info, "Encoding complete!");

    // ------------------------------------------------------------------
    // Post-encode subtitle handling (warnings only — the video is already made)
    // ------------------------------------------------------------------
    if let Some(ref sub_settings) = job.subtitle_settings {
        if sub_settings.enabled {
            match whisper_srt {
                // Transcribed before the encode. Apply whatever the output mode
                // asks for on top of what already happened during it.
                Some(srt) => {
                    let mode = sub_settings.output;
                    if mode.muxes() {
                        reporter.send_log(
                            models::LogLevel::Info,
                            "Adding subtitle track to the output...",
                        );
                        if let Err(e) = dependency_locator::DependencyLocator::new()
                            .and_then(|d| {
                                SubtitleGenerator::new(reporter.clone(), d).mux(
                                    std::path::Path::new(&job.output_path),
                                    &srt,
                                    || cancelled.load(Ordering::SeqCst),
                                )
                            })
                        {
                            reporter.send_log(
                                models::LogLevel::Warning,
                                &format!("Could not add the subtitle track: {e}"),
                            );
                        }
                    }
                    if mode.keeps_srt_file() {
                        reporter.send_log(
                            models::LogLevel::Info,
                            &format!("Subtitles saved to: {}", srt.display()),
                        );
                    } else {
                        let _ = std::fs::remove_file(&srt);
                    }
                }
                // Nothing was transcribed — a user-supplied burn-in file, or the
                // source had no audio. Fall back to the original path.
                None if job.burn_in_subtitle_path.is_none() => {
                    let _ = run_subtitle_generation(
                        &job.output_path, sub_settings, reporter, &cancelled, false, None,
                    );
                }
                None => {}
            }
        }
    }

    Ok(job.output_path.clone())
}

/// Subtitle-only mode: skip video processing, generate subtitles directly from input.
fn run_subtitle_only(
    job: &VideoJob,
    reporter: &ProgressReporter,
    cancelled: Arc<AtomicBool>,
) -> Result<String> {
    let sub_settings = job
        .subtitle_settings
        .as_ref()
        .filter(|s| s.enabled)
        .context("Subtitle-only mode requires subtitle settings")?;

    reporter.send_log(models::LogLevel::Info, "Subtitle-only mode — skipping video processing");

    run_subtitle_generation(
        &job.input_path, sub_settings, reporter, &cancelled, true,
        Some(&job.output_path),
    )?;

    if cancelled.load(Ordering::SeqCst) {
        anyhow::bail!("Job cancelled");
    }

    // Return the output path (embed creates a new file there;
    // SRT-only still returns input since no video was produced)
    let output = Path::new(&job.output_path);
    if output.exists() {
        Ok(job.output_path.clone())
    } else {
        Ok(job.input_path.clone())
    }
}

/// Run subtitle generation on a video file.
///
/// When `fail_on_error` is true (subtitle-only mode), errors propagate and
/// fail the job. When false (post-encode), errors are logged as warnings
/// and the job still succeeds.
fn run_subtitle_generation(
    video_path: &str,
    settings: &models::SubtitleSettings,
    reporter: &ProgressReporter,
    cancelled: &Arc<AtomicBool>,
    fail_on_error: bool,
    output_path: Option<&str>,
) -> Result<()> {
    reporter.send_log(models::LogLevel::Info, "Generating subtitles...");

    let result = dependency_locator::DependencyLocator::new().and_then(|deps| {
        let sub_gen = SubtitleGenerator::new(reporter.clone(), deps);
        sub_gen.generate(video_path, settings, || cancelled.load(Ordering::SeqCst), output_path)
    });

    match result {
        Ok(Some(srt_path)) => {
            reporter.send_log(
                models::LogLevel::Info,
                &format!("Subtitles saved to: {}", srt_path.display()),
            );
            Ok(())
        }
        Ok(None) => {
            // Subtitle generation skipped (no audio) or embedded only
            Ok(())
        }
        Err(e) => {
            let msg = format!("Subtitle generation failed: {}", e);
            if fail_on_error {
                anyhow::bail!(msg);
            } else {
                reporter.send_log(models::LogLevel::Warning, &msg);
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_features_are_reported_and_plausible() {
        let features = detected_cpu_features();

        // Nothing here is a decision, so the assertion is only that the probe
        // reports *something* real — a probe that silently returns nothing
        // would leave every CI run claiming it tested unknown hardware, which
        // is the whole failure this exists to prevent.
        #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
        assert!(
            features.contains(&"sse2"),
            "SSE2 is part of the x86-64 baseline, so its absence means the \
             probe is broken rather than the CPU being modest: {features:?}"
        );

        #[cfg(target_arch = "aarch64")]
        assert!(features.contains(&"neon"), "{features:?}");

        // AVX-512 implies AVX2 implies AVX: a set that breaks that ordering
        // means the flags have been mis-wired to the wrong detections.
        let has = |f: &str| features.contains(&f);
        if has("avx512f") {
            assert!(has("avx2"), "avx512f without avx2: {features:?}");
        }
        if has("avx2") {
            assert!(has("avx"), "avx2 without avx: {features:?}");
        }
    }
}
