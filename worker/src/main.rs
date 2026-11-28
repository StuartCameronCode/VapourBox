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
//!   --dvd-extract <path> --title N [--chapters S-E] [--angle A] --output <path>:
//!     extract one title (its cells only, one angle, the chapter range)
//!
//! Timestamp resets (MPEG-PS/TS, see source_continuity):
//!   --scan-timestamps <path>: print the resets as JSON
//!   --make-continuous <path> --output <path> [--source <model>]: write the
//!     continuous copy (with the model's scan, when it describes <path>)
//!
//! Source model (source_model, task #50):
//!   --probe-source <path> [--defer-scan]: print the model (the reset scan
//!     left for later with --defer-scan, task #55)
//!   --complete-source <model>: run a deferred model's scan, with progress

use anyhow::{Context, Result};
use clap::Parser;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

mod models;
mod comment_metadata;
mod crop_detect;
mod cpu;
mod dependency_locator;
mod dvd_reader;
mod pipeline_executor;
mod vspipe_exit;
mod vspipe_failure;
mod pixel_format;
mod ffprobe_run;
mod source_continuity;
mod source_decode;
mod source_timing;
mod source_model;
mod progress_reporter;
mod addons;
mod audio_restoration;
mod avi_header;
mod ai_runtime;
mod animejanai;
mod upscale_addons;
mod gpu_plugin;
mod hdr_metadata;
mod native_res;
mod noise_halo;
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

    /// Which of the source frame's output frames to preview, from 0: under a
    /// x2 frame rate, 1 is the frame made between this one and the next.
    /// Clamped to the frames there are.
    #[arg(long, default_value_t = 0)]
    sub_frame: u32,

    /// DVD info mode: enumerate titles from a DVD mount point or VIDEO_TS folder
    #[arg(long)]
    dvd_info: Option<String>,

    /// DVD extract mode: extract a title from a DVD
    #[arg(long)]
    dvd_extract: Option<String>,

    /// Title number to extract (required with --dvd-extract)
    #[arg(long)]
    title: Option<u32>,

    /// Chapter range to extract (e.g., "1-5" or "3", optional with --dvd-extract)
    #[arg(long)]
    chapters: Option<String>,

    /// Angle to extract from a multi-angle title (1-based, default 1)
    #[arg(long, default_value_t = 1)]
    angle: u8,

    /// Output file path (required with --dvd-extract and --make-continuous)
    #[arg(long)]
    output: Option<PathBuf>,

    /// Scan an MPEG-PS/TS for timestamp resets and print JSON
    /// (`{"format", "applies", "resets": [...], "videoPackets"}`) to stdout.
    #[arg(long)]
    scan_timestamps: Option<String>,

    /// Copy an MPEG-PS/TS with a timestamp reset to `--output` with
    /// continuous timestamps (same container), reporting progress as JSON
    /// lines (phase "joining"); the copy is checked before it is kept.
    #[arg(long)]
    make_continuous: Option<String>,

    /// Probe a source and print its `SourceModel` (`source_model`, task #50)
    /// as one JSON line: everything every decoder of it needs to know.
    #[arg(long)]
    probe_source: Option<String>,

    /// With `--probe-source`: leave an MPEG-PS/TS's timestamp-reset scan
    /// (a read of the whole file) for `--complete-source`; the model says
    /// `continuityDeferred` (task #55).
    #[arg(long)]
    defer_scan: bool,

    /// Finish a deferred `SourceModel` file: run its timestamp-reset scan,
    /// reporting progress as JSON lines (phase "scanning"), then print the
    /// completed model as the last line (task #55).
    #[arg(long)]
    complete_source: Option<PathBuf>,

    /// A `SourceModel` file (from `--probe-source`) for the job in
    /// `--config`, when the job does not carry one inline: the worker then
    /// probes nothing it already describes.
    #[arg(long)]
    source: Option<PathBuf>,

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

    /// Probe mode: report whether RIFE frame interpolation runs here, as JSON
    /// (`{"available": bool, "reason": …, "detail": …, "message": …}`), and
    /// exit. The app shows `message` when RIFE is selected; it names what is
    /// missing (a Vulkan driver, the VC++ runtime, an older deps bundle) and
    /// what to do about it.
    #[arg(long)]
    probe_rife: bool,

    /// Probe whether AI upscaling (Real-ESRGAN / Real-CUGAN through VSNCNN)
    /// can run here; prints the same JSON shape as `--probe-rife`.
    #[arg(long)]
    probe_upscale: bool,

    /// Detect the resolution and kernel the video in `--config` was upscaled
    /// from (for the Descale pass); prints a JSON report.
    #[arg(long)]
    detect_native: bool,

    /// Measure the black borders, analog blanking and head-switching band at
    /// the edges of the video in `--config` (for Crop & Resize's Detect);
    /// prints a JSON report.
    #[arg(long)]
    detect_crop: bool,

    /// Measure how noisy the video in `--config` is and how strongly its
    /// edges ring (for the pass list's suggestions); prints a JSON report.
    #[arg(long)]
    detect_noise_halo: bool,

    /// Probe whether the AI runtime add-on (ONNX Runtime) runs here: imports
    /// it the way a job does, runs a tiny test model, and prints JSON
    /// (`{"available", "reason", "detail", "message", "version", "providers",
    /// "provider", "fallback"}`). `VAPOURBOX_AI_FORCE_CPU=1` tests the CPU path.
    #[arg(long)]
    probe_ai_runtime: bool,

    /// Print the audio restoration plan for the job in `--config` (the probes
    /// it makes, then every ffmpeg / DeepFilterNet argument list it would run)
    /// as JSON, and exit without rendering anything.
    #[arg(long)]
    audio_plan: bool,

    /// Print the add-on manifests compiled into this worker, as JSON
    /// (`{"<id>": "<version>", …}`), and exit.
    #[arg(long)]
    list_addons: bool,
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

    if let Some(ref input) = args.scan_timestamps {
        return run_scan_timestamps(input);
    }
    if let Some(ref input) = args.make_continuous {
        return run_make_continuous(&args, input);
    }
    if let Some(ref input) = args.probe_source {
        return run_probe_source(input, args.defer_scan);
    }
    if let Some(ref model) = args.complete_source {
        return run_complete_source(model);
    }

    // OpenCL probe mode: emit availability as JSON and exit (no progress stream).
    if args.probe_cpu {
        return run_probe_cpu();
    }

    if args.probe_opencl {
        return run_probe_opencl();
    }

    if args.probe_rife {
        return run_probe_gpu_plugin(gpu_plugin::GpuPlugin::Rife);
    }

    if args.probe_upscale {
        return run_probe_gpu_plugin(gpu_plugin::GpuPlugin::Upscale);
    }

    if args.detect_native {
        return run_detect_native(&args);
    }

    if args.detect_crop {
        return run_detect_crop(&args);
    }

    if args.detect_noise_halo {
        return run_detect_noise_halo(&args);
    }

    if args.probe_ai_runtime {
        return run_probe_ai_runtime();
    }

    if args.audio_plan {
        return run_audio_plan(&args);
    }

    if args.list_addons {
        let list: serde_json::Map<String, serde_json::Value> = addons::manifests()
            .iter()
            .map(|m| (m.id.clone(), serde_json::Value::String(m.version.clone())))
            .collect();
        println!("{}", serde_json::Value::Object(list));
        return ExitCode::SUCCESS;
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

    match run_worker(args.config.as_ref().unwrap(), args.source.as_deref(), &reporter, cancelled) {
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
    // `knlmDevice` is the device the KNLMeans noise-reduction method runs on
    // (null when none works, with `knlmMessage` saying why) — not the same
    // question as `knlm`, which is about havsfunc's default-device call.
    let (opencl, knlm, knlm_runtime) = match dependency_locator::DependencyLocator::new() {
        Ok(deps) => (deps.opencl_available(), deps.knlm_available(), deps.knlm_runtime()),
        Err(_) => (
            false,
            false,
            Err(dependency_locator::KNLM_NO_DEVICE_MESSAGE.to_string()),
        ),
    };
    let (knlm_device, knlm_message) = match knlm_runtime {
        Ok(device) => (Some(device), None),
        Err(message) => (None, Some(message)),
    };
    println!(
        "{}",
        serde_json::json!({
            "opencl": opencl,
            "knlm": knlm,
            "knlmDevice": knlm_device,
            "knlmMessage": knlm_message,
        })
    );
    ExitCode::SUCCESS
}


/// Print the audio restoration plan for the job in `--config` as JSON
/// (`{"active": false}` when the pass does nothing for it). Log messages go to
/// stderr, so stdout is the one JSON line.
fn run_audio_plan(args: &Args) -> ExitCode {
    let result = (|| -> anyhow::Result<serde_json::Value> {
        let config = args
            .config
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("--config is required with --audio-plan"))?;
        let mut job: models::VideoJob = serde_json::from_str(&std::fs::read_to_string(config)?)?;
        let deps = dependency_locator::DependencyLocator::new()?;
        resolve_source(&mut job, Some(&deps), args.source.as_deref(), true, |m| eprintln!("{m}"));
        let reporter = ProgressReporter::new_to_stderr();
        let Some((plan, source)) = audio_restoration::AudioRestorer::new(reporter, deps).plan(&job)? else {
            return Ok(serde_json::json!({ "active": false }));
        };
        let p = |s: &str| std::path::PathBuf::from(s);
        let first = if plan.single_pass() { "restored.wav" } else { "restore.wav" };
        Ok(serde_json::json!({
            "active": true,
            "sourceStreams": source.streams,
            "stream": plan.stream,
            "outRate": plan.out_rate,
            "outSamples": plan.out_samples,
            "restore": plan.restore_args(&job.input_path, &p(first)),
            "deepFilter": plan.deep_filter_args(&p(first), &p("dfn")),
            "measure": plan.measure_args(&p(first)),
            "finish": (!plan.single_pass()).then(|| plan.finish_args(&p(first), &p("restored.wav"), None)),
            "notes": plan.notes,
            "readStart": plan.read_start,
            "readSkip": plan.read_skip,
            "decoderDelay": job.decoder_delay(),
            "videoStartOffset": job.video_start(),
            "videoDelay": job.output_video_delay(),
        }))
    })();
    match result {
        Ok(v) => {
            println!("{v}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            println!("{}", serde_json::json!({ "error": format!("{e:#}") }));
            ExitCode::FAILURE
        }
    }
}

/// Detect a source's native resolution and kernel and print the report as one
/// JSON line (`{"error": ...}` when it could not be analysed).
fn run_detect_native(args: &Args) -> ExitCode {
    let result = (|| -> anyhow::Result<native_res::NativeResReport> {
        let config = args
            .config
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("--config is required with --detect-native"))?;
        let mut job: models::VideoJob = serde_json::from_str(&std::fs::read_to_string(config)?)?;
        let deps = dependency_locator::DependencyLocator::new()?;
        resolve_source(&mut job, Some(&deps), args.source.as_deref(), false, |m| eprintln!("{m}"));
        native_res::detect(&deps, &job)
    })();
    match result {
        Ok(report) => {
            println!("{}", serde_json::to_string(&report).unwrap_or_default());
            ExitCode::SUCCESS
        }
        Err(e) => {
            println!("{}", serde_json::json!({ "error": e.to_string() }));
            ExitCode::FAILURE
        }
    }
}

/// Measure a source's edges for the crop and print the report as one JSON
/// line (`{"error": ...}` when it could not be analysed).
fn run_detect_crop(args: &Args) -> ExitCode {
    let result = (|| -> anyhow::Result<crop_detect::CropReport> {
        let config = args
            .config
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("--config is required with --detect-crop"))?;
        let mut job: models::VideoJob = serde_json::from_str(&std::fs::read_to_string(config)?)?;
        let deps = dependency_locator::DependencyLocator::new()?;
        resolve_source(&mut job, Some(&deps), args.source.as_deref(), false, |m| eprintln!("{m}"));
        crop_detect::detect(&deps, &job)
    })();
    match result {
        Ok(report) => {
            println!("{}", serde_json::to_string(&report).unwrap_or_default());
            ExitCode::SUCCESS
        }
        Err(e) => {
            println!("{}", serde_json::json!({ "error": e.to_string() }));
            ExitCode::FAILURE
        }
    }
}

/// Measure a source's noise and halos and print the report as one JSON line
/// (`{"error": ...}` when it could not be analysed).
fn run_detect_noise_halo(args: &Args) -> ExitCode {
    let result = (|| -> anyhow::Result<noise_halo::NoiseHaloReport> {
        let config = args
            .config
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("--config is required with --detect-noise-halo"))?;
        let mut job: models::VideoJob = serde_json::from_str(&std::fs::read_to_string(config)?)?;
        let deps = dependency_locator::DependencyLocator::new()?;
        resolve_source(&mut job, Some(&deps), args.source.as_deref(), false, |m| eprintln!("{m}"));
        noise_halo::detect(&deps, &job)
    })();
    match result {
        Ok(report) => {
            println!("{}", serde_json::to_string(&report).unwrap_or_default());
            ExitCode::SUCCESS
        }
        Err(e) => {
            println!("{}", serde_json::json!({ "error": e.to_string() }));
            ExitCode::FAILURE
        }
    }
}

/// Probe whether a GPU plugin (RIFE, AI upscaling) runs here and print the
/// result as JSON to stdout. Deps that cannot be located are reported as "not
/// installed" rather than as a failure of the probe: the remedy is the same,
/// let the app download them.
fn run_probe_ai_runtime() -> ExitCode {
    let json = match dependency_locator::DependencyLocator::new() {
        Ok(deps) => deps.ai_runtime_status().to_json(deps.platform_suffix()),
        Err(e) => ai_runtime::AiRuntimeStatus::unavailable(
            ai_runtime::AiRuntimeReason::ProbeFailed,
            e.to_string(),
        )
        .to_json(""),
    };
    println!("{json}");
    ExitCode::SUCCESS
}

fn run_probe_gpu_plugin(plugin: gpu_plugin::GpuPlugin) -> ExitCode {
    let json = match dependency_locator::DependencyLocator::new() {
        Ok(deps) => deps.gpu_plugin_status(plugin).to_json(plugin, deps.platform_suffix()),
        Err(e) => gpu_plugin::GpuPluginStatus::unavailable(
            gpu_plugin::GpuPluginReason::NotInstalled,
            e.to_string(),
        )
        .to_json(plugin, ""),
    };
    println!("{json}");
    ExitCode::SUCCESS
}

/// Report the CPU architecture, the dispatch-relevant instruction set
/// extensions and, on x86, the deps bundle tier, as JSON.
///
/// `tier` is a decision: the app reads it to choose which x86 deps bundle to
/// download (see `cpu::cpu_tier`). It is absent off x86, where bundles are not
/// tiered, and the app treats a missing or unreadable answer on x86 as `v2`.
///
/// `features` is diagnostic. It lets a test run *state* which hardware it
/// tested, because several bundled plugins select a code path from these bits
/// and a green run is otherwise silent about which path it took — the CTMF
/// AVX-512 crash passed for days on non-AVX-512 runners before drawing one.
///
/// `ctmfOpt` is `script_generator::ctmf_opt()`, the SIMD level every template
/// gives CTMF. A test that calls CTMF itself passes it (task #112), so it
/// runs the kernel the app runs and never the 8-bit AVX-512 one that
/// auto-detect picks.
fn run_probe_cpu() -> ExitCode {
    println!("{}", probe_cpu_json());
    ExitCode::SUCCESS
}

/// The JSON `--probe-cpu` prints.
fn probe_cpu_json() -> serde_json::Value {
    let mut out = serde_json::json!({
        "arch": std::env::consts::ARCH,
        "features": detected_cpu_features(),
        "ctmfOpt": script_generator::ctmf_opt(),
    });
    if let Some(tier) = cpu::cpu_tier() {
        out["tier"] = serde_json::json!(tier.as_str());
    }
    out
}

/// The instruction set extensions that bundled plugins dispatch on, plus the
/// whole x86-64-v3 set that decides the bundle tier.
#[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
fn detected_cpu_features() -> Vec<&'static str> {
    let names = ["sse2", "sse4.1", "sse4.2"]
        .into_iter()
        .chain(cpu::V3_FEATURES)
        .chain(["avx512f"]);
    names.filter(|n| cpu::has_feature(n)).collect()
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

    let chapters = match args.chapters.as_deref().map(parse_chapter_range).transpose() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {}", e);
            return ExitCode::from(1);
        }
    };

    let reporter = ProgressReporter::new();

    // Extract beside the output, then join any timestamp resets into the
    // output (source_continuity): a title that spans VOB IDs restarts its
    // clock at each one.
    let mut part_name = output.as_os_str().to_owned();
    part_name.push(".part");
    let part = PathBuf::from(part_name);
    let result = dvd_reader::extract_title(dvd_path, title, chapters, args.angle, &part, &reporter)
        .and_then(|()| join_dvd_resets(&part, &output, &reporter));
    if result.is_err() {
        let _ = std::fs::remove_file(&part);
    }

    match result {
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

/// `--chapters`: "S-E" or "N", 1-based and inclusive. Anything else is an
/// error rather than a guess (the title's own chapter count is checked later).
fn parse_chapter_range(s: &str) -> Result<(u16, u16)> {
    let parse = |p: &str| -> Result<u16> {
        match p.trim().parse::<u16>() {
            Ok(n) if n > 0 => Ok(n),
            _ => anyhow::bail!("--chapters expects S-E or N with chapters from 1, got {:?}", s),
        }
    };
    let range = match s.split_once('-') {
        Some((a, b)) => (parse(a)?, parse(b)?),
        None => {
            let n = parse(s)?;
            (n, n)
        }
    };
    if range.0 > range.1 {
        anyhow::bail!("--chapters {:?} ends before it starts", s);
    }
    Ok(range)
}

/// The DVD import's last step: scan the extraction and, when its timestamps
/// reset, join it into `output` (else rename it there).
fn join_dvd_resets(part: &Path, output: &Path, reporter: &ProgressReporter) -> Result<()> {
    let deps = dependency_locator::DependencyLocator::new().ok();
    let tools = deps.as_ref().and_then(|d| {
        Some((d.ffmpeg_path().ok()?, d.ffprobe_path().ok()?, d.build_environment()))
    });
    let outcome = source_continuity::finish_import(
        part,
        output,
        |p| match &tools {
            Some((_, ffprobe, env)) => source_continuity::scan(ffprobe, env, p),
            None => anyhow::bail!("ffprobe was not found"),
        },
        |scan| {
            let (ffmpeg, ffprobe, env) = tools.as_ref().expect("scanned with the same tools");
            reporter.send_log(
                models::LogLevel::Info,
                &format!(
                    "The title's {}; joining them into one continuous timeline \
                     (needs as much free space again as the title, until done)",
                    scan.summary()
                ),
            );
            let start = std::time::Instant::now();
            source_continuity::make_continuous(
                ffmpeg,
                ffprobe,
                env,
                &part.to_string_lossy(),
                scan,
                output,
                |f| {
                    let done = (f * 1000.0) as i32;
                    let elapsed = start.elapsed().as_secs_f64();
                    let eta = if f > 0.0 { elapsed / f - elapsed } else { 0.0 };
                    reporter.send_progress_phase(
                        &models::ProgressInfo::new(done, 1000, 0.0, eta),
                        "joining",
                    );
                },
            )
        },
    )?;
    match outcome {
        source_continuity::ImportOutcome::Unchanged => {}
        source_continuity::ImportOutcome::Joined(scan) => reporter.send_log(
            models::LogLevel::Info,
            &format!("Joined {} timestamp reset(s): frames now count straight through", scan.resets.len()),
        ),
        source_continuity::ImportOutcome::Kept(why) => reporter.send_log(
            models::LogLevel::Warning,
            &format!(
                "Kept the title as extracted: {}. The app will try to join it again when it analyses it",
                why
            ),
        ),
    }
    Ok(())
}

/// `--scan-timestamps`: print the source's timestamp resets as JSON.
fn run_scan_timestamps(input: &str) -> ExitCode {
    let result = dependency_locator::DependencyLocator::new().and_then(|d| {
        let ffprobe = d.ffprobe_path()?;
        source_continuity::scan(&ffprobe, &d.build_environment(), input)
    });
    match result {
        Ok(scan) => {
            println!("{}", serde_json::to_string(&scan).unwrap_or_default());
            ExitCode::SUCCESS
        }
        Err(e) => {
            println!("{}", serde_json::json!({"type": "error", "message": format!("{:#}", e)}));
            ExitCode::from(1)
        }
    }
}

/// `--make-continuous`: write the continuous copy of a source with a reset,
/// as progress JSON lines like `--dvd-extract`. A source without one is an
/// error (there is nothing to join), so the caller never gets a needless
/// copy.
fn run_make_continuous(args: &Args, input: &str) -> ExitCode {
    let Some(output) = args.output.clone() else {
        eprintln!("Error: --output is required with --make-continuous");
        return ExitCode::from(1);
    };
    let reporter = ProgressReporter::new();
    let result = (|| -> Result<source_continuity::ContinuityScan> {
        let d = dependency_locator::DependencyLocator::new()?;
        let (ffmpeg, ffprobe, env) = (d.ffmpeg_path()?, d.ffprobe_path()?, d.build_environment());
        // The scan the app already has, from the source model it passes
        // (`--source`), saves a second read of the whole file (task #55).
        let known = args.source.as_deref().and_then(|p| {
            let m: source_model::SourceModel =
                serde_json::from_str(&std::fs::read_to_string(p).ok()?).ok()?;
            if m.describes(input) { m.continuity } else { None }
        });
        let scan = match known {
            Some(scan) => {
                reporter.send_log(models::LogLevel::Info, "Using the source model's timestamp scan");
                scan
            }
            None => source_continuity::scan(&ffprobe, &env, input)?,
        };
        if !scan.needs_copy() {
            anyhow::bail!("{} has no timestamp reset to join", input);
        }
        reporter.send_log(models::LogLevel::Info, &format!("Source {}; joining", scan.summary()));
        let start = std::time::Instant::now();
        source_continuity::make_continuous(&ffmpeg, &ffprobe, &env, input, &scan, &output, |f| {
            let elapsed = start.elapsed().as_secs_f64();
            let eta = if f > 0.0 { elapsed / f - elapsed } else { 0.0 };
            reporter.send_progress_phase(
                &models::ProgressInfo::new((f * 1000.0) as i32, 1000, 0.0, eta),
                "joining",
            );
        })?;
        Ok(scan)
    })();
    match result {
        Ok(_) => {
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

/// Warn when a job the app did not prepare (`continuity_checked` false)
/// reads an MPEG-PS/TS whose timestamps reset. Never changes the job: its
/// frame numbers were chosen against an unknown timeline.
fn warn_on_resets(
    job: &VideoJob,
    deps: Option<&dependency_locator::DependencyLocator>,
    log: impl Fn(&str),
) {
    if job.continuity_checked {
        return;
    }
    let scan = match job.source.as_ref().and_then(|m| m.continuity.clone()) {
        Some(scan) => Some(scan),
        None => {
            let Some(d) = deps else { return };
            let Ok(ffprobe) = d.ffprobe_path() else { return };
            source_continuity::scan(&ffprobe, &d.build_environment(), &job.input_path).ok()
        }
    };
    if let Some(scan) = scan {
        if scan.needs_copy() {
            log(&format!(
                "The source's {}. Frames after the first reset are not reliable in this job: \
                 open the file in VapourBox, which decodes such a source from a joined copy, \
                 or remux it first (ffmpeg -i in -map 0 -c copy out, without -copyts)",
                scan.summary()
            ));
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

    let mut job: VideoJob = match serde_json::from_str(&config_content) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("Error parsing config: {}", e);
            return ExitCode::from(1);
        }
    };
    let deps = dependency_locator::DependencyLocator::new().ok();
    resolve_source(&mut job, deps.as_ref(), args.source.as_deref(), false, |msg| eprintln!("{}", msg));

    // The frame index is passed straight through to the worker — no
    // time-conversion round-trip — so the rendered frame is exactly the one the
    // caller asked for (see generate_preview's frame-accurate windowing).
    eprintln!("Preview: source frame {} (fps: {:.2})", frame, job.input_frame_rate.unwrap_or(29.97));

    // Execute preview (extracts frames with ffmpeg, processes with VapourSynth)
    let timeline = source_timeline(&job, deps.as_ref(), |msg| eprintln!("{}", msg));
    let executor = match PipelineExecutor::new(ProgressReporter::new()) {
        Ok(e) => e.with_timeline(timeline),
        Err(e) => {
            eprintln!("Error creating executor: {}", e);
            return ExitCode::from(1);
        }
    };

    match executor.generate_preview(&job, frame, args.sub_frame) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("Error generating preview: {}", e);
            ExitCode::from(1)
        }
    }
}

/// Give `job` its source model and fill every source fact it left unset
/// from it (`VideoJob::apply_source_model`). The model comes from the job
/// itself, else from `source_file` (`--source`); one that is missing, or no
/// longer describes `job.input_path` (the file changed after the app probed
/// it), is probed here. A failed probe leaves the job as it was, and every
/// decoder then works as it did before any of this was known.
fn resolve_source(
    job: &mut VideoJob,
    deps: Option<&dependency_locator::DependencyLocator>,
    source_file: Option<&Path>,
    count_frames: bool,
    log: impl Fn(&str) + Sync,
) {
    if job.source.is_none() {
        if let Some(path) = source_file {
            match std::fs::read_to_string(path)
                .map_err(anyhow::Error::from)
                .and_then(|t| Ok(serde_json::from_str::<source_model::SourceModel>(&t)?))
            {
                Ok(m) => job.source = Some(m),
                Err(e) => log(&format!("The source model {} could not be read ({e}); probing the source", path.display())),
            }
        }
    }
    let usable = job.source.as_ref().is_some_and(|m| m.describes(&job.input_path));
    if !usable {
        if job.source.take().is_some() {
            log("The source model no longer describes the file (it changed after it was probed); probing it again");
        }
        if let Some(d) = deps {
            if let Ok(ffprobe) = d.ffprobe_path() {
                match source_model::probe_source(&ffprobe, &d.build_environment(), &job.input_path, |_| {}) {
                    Ok(m) => {
                        log(&format!(
                            "Probed the source: {}x{}, {} frames at {:.3} fps",
                            m.video.width, m.video.height, m.video.frame_count, m.video.frame_rate
                        ));
                        job.source = Some(m);
                    }
                    Err(e) => log(&format!("The source could not be probed: {e:#}")),
                }
            }
        }
    }
    let decode_count = count_frames && job.total_frames.is_none() && job.counts_by_decoding();
    job.apply_source_model();
    // A job without a count (the app always sends one) takes the model's
    // (`apply_source_model`, task #54). Only a source whose model can't
    // stand for its decode (`counts_by_decoding`: none at all, or a raw
    // MPEG-PS/TS whose timestamps reset) is still counted by decoding, and
    // only for the encode and the audio plan (`count_frames`).
    if decode_count {
        if let Some(full) = deps.and_then(|d| d.probe_frame_count(&job.input_path)) {
            let effective = match (job.start_frame, job.end_frame) {
                (Some(s), Some(e)) => (e - s + 1).max(0),
                (None, Some(e)) => e + 1,
                (Some(s), None) => (full - s).max(0),
                (None, None) => full,
            };
            log(&format!("Counted the input's frames by decoding: {} (effective after trim: {})", full, effective));
            job.total_frames = Some(effective);
        }
    }
    if job.source.is_some() {
        if job.video_start() > 0.0 {
            log(&format!(
                "The video's first picture starts {:.3} s after the file's start (its sound starts first); \
                 frame numbers count from the picture",
                job.video_start()
            ));
        }
        if job.decoder_delay() > 0 {
            log(&format!(
                "The source stores decode-order timestamps (AVI): the decoder stamps each picture \
                 {} frame(s) late, and seeks allow for it",
                job.decoder_delay()
            ));
        }
        if let Some(plan) = job.seek_plan() {
            log(&format!(
                "MPEG-TS/PS source (no keyframe index): seeks start {:.2} s early and drop to the frame",
                plan.preroll
            ));
        }
        match job.source_grid() {
            Some(g) => log(&format!(
                "Frames are placed on a {}/{} fps grid from the first picture ({:.6} s)",
                g.rate_num, g.rate_den, g.origin
            )),
            None => log("No frame grid for this source (timestamps missing); decoding as before"),
        }
    }
}

/// `--probe-source`: print the source's model as one JSON line, or
/// `{"error": ...}` when it could not be read.
fn run_probe_source(input: &str, defer_scan: bool) -> ExitCode {
    let mode = if defer_scan { source_model::ScanMode::Deferred } else { source_model::ScanMode::Now };
    let result = (|| -> anyhow::Result<source_model::SourceModel> {
        let deps = dependency_locator::DependencyLocator::new()?;
        let ffprobe = deps.ffprobe_path()?;
        source_model::probe_source_with(&ffprobe, &deps.build_environment(), input, mode, |m| eprintln!("{m}"))
    })();
    match result {
        Ok(m) => {
            println!("{}", serde_json::to_string(&m).unwrap_or_default());
            ExitCode::SUCCESS
        }
        Err(e) => {
            println!("{}", serde_json::json!({ "error": format!("{e:#}") }));
            ExitCode::FAILURE
        }
    }
}

/// `--complete-source`: finish a deferred model (its reset scan), with
/// progress lines while the file is read, then the model as the last line
/// (`{"error": ...}` when it could not be read or probed).
fn run_complete_source(model_path: &Path) -> ExitCode {
    let reporter = ProgressReporter::new();
    let result = (|| -> anyhow::Result<source_model::SourceModel> {
        let text = std::fs::read_to_string(model_path)
            .with_context(|| format!("could not read {}", model_path.display()))?;
        let model: source_model::SourceModel =
            serde_json::from_str(&text).context("the source model is not valid")?;
        let deps = dependency_locator::DependencyLocator::new()?;
        let ffprobe = deps.ffprobe_path()?;
        let start = std::time::Instant::now();
        source_model::complete_source(
            &ffprobe,
            &deps.build_environment(),
            model,
            |f| {
                let elapsed = start.elapsed().as_secs_f64();
                let eta = if f > 0.0 { elapsed / f - elapsed } else { 0.0 };
                reporter.send_progress_phase(
                    &models::ProgressInfo::new((f * 1000.0) as i32, 1000, 0.0, eta),
                    "scanning",
                );
            },
            |m| eprintln!("{m}"),
        )
    })();
    match result {
        Ok(m) => {
            println!("{}", serde_json::to_string(&m).unwrap_or_default());
            ExitCode::SUCCESS
        }
        Err(e) => {
            println!("{}", serde_json::json!({ "error": format!("{e:#}") }));
            ExitCode::FAILURE
        }
    }
}

/// A variable-frame-rate source's timeline (issue #137, see `source_timing`),
/// or `None` to decode at constant rate as before.
///
/// IVTC and Soft Telecine are left alone: a soft-telecined MPEG-2 stream's
/// timestamps are "variable" by design, and VDecimate expects exactly the
/// constant-rate decode, pulldown repeats included, that it always had.
fn source_timeline(
    job: &VideoJob,
    deps: Option<&dependency_locator::DependencyLocator>,
    log: impl Fn(&str),
) -> Option<source_timing::SourceTimeline> {
    let pipeline = job.effective_pipeline();
    if pipeline.deinterlace.enabled
        && matches!(
            pipeline.deinterlace.method,
            models::DeinterlaceMethod::Ivtc | models::DeinterlaceMethod::SoftTelecine
        )
    {
        return None;
    }
    let fps = job.input_frame_rate.unwrap_or(29.97);
    // The model holds the stored frames' times when they are irregular, so
    // nothing is read again (a preview used to read every packet).
    if let Some(m) = &job.source {
        return m.timeline(fps, log);
    }
    let deps = deps?;
    let ffprobe = deps.ffprobe_path().ok()?;
    source_timing::probe(
        &ffprobe,
        &deps.build_environment(),
        &job.input_path,
        job.input_frame_rate.unwrap_or(29.97),
        log,
    )
}

/// Why the source's sound can't be copied into the job's container, or
/// `None`. Only under Passthrough; a stream Audio Restoration re-encodes is
/// not copied. Read from the source model's audio streams; with no model (a
/// failed probe) it says nothing, and ffmpeg's own error still comes.
fn audio_copy_problem(job: &VideoJob) -> Option<String> {
    if job.encoding_settings.audio_mode != models::AudioMode::Passthrough || job.source_has_audio == Some(false) {
        return None;
    }
    let streams = &job.source.as_ref()?.audio_streams;
    let audio = job.effective_pipeline().audio;
    let restored = (audio.enabled && audio.has_effect()).then_some(audio.stream_index as usize);
    streams
        .iter()
        .enumerate()
        .filter(|(i, _)| Some(*i) != restored)
        .filter_map(|(_, s)| s.codec.as_deref())
        .find_map(|codec| {
            models::audio_copy_problem(
                codec,
                job.encoding_settings.container,
                Some(job.encoding_settings.codec),
            )
        })
}

fn run_worker(
    config_path: &PathBuf,
    source_file: Option<&Path>,
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

    // A Convert codec the container can't hold (a preset saved before the app
    // filtered the list, an imported job) fails ffmpeg's header write only
    // after the script and the audio render. Refuse it before any work, in
    // our words (task #39).
    if let Some(problem) = job.encoding_settings.audio_container_problem() {
        anyhow::bail!(problem);
    }
    // Likewise a video codec FFmpeg can't write to the container (task #49);
    // a pair the app doesn't offer runs, with a note.
    if let Some(problem) = pipeline_executor::container_problem(&job) {
        anyhow::bail!(problem);
    }
    if let Some(note) = job.encoding_settings.codec.container_note(job.encoding_settings.container) {
        reporter.send_log(models::LogLevel::Warning, note);
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

    // Every source fact the decoders need, from the model the app sent (or
    // a file given with --source), probed only when the job carries none:
    // a direct caller's job, the CLI (source_model, task #50).
    resolve_source(&mut job, deps.as_ref(), source_file, true, |msg| {
        reporter.send_log(models::LogLevel::Info, msg)
    });
    // A Passthrough copy the container can't hold (Opus into AVI) fails the
    // header write after all the work; refuse it now (task #49).
    if let Some(problem) = audio_copy_problem(&job) {
        anyhow::bail!(problem);
    }
    // An MPEG-TS/PS's clock may reset mid-file (source_continuity), which the
    // app handles before it sends a job; a hand-written job only gets a warning.
    if job.seek_plan.is_some() {
        warn_on_resets(&job, deps.as_ref(), |msg| {
            reporter.send_log(models::LogLevel::Warning, msg)
        });
    }

    // A variable-frame-rate source is decoded as stored and placed on the
    // grid by the script. Its length in grid slots replaces the stored-frame
    // count the app sends (ffprobe's nb_frames), which is short by every gap.
    let timeline = source_timeline(&job, deps.as_ref(), |msg| {
        reporter.send_log(models::LogLevel::Info, msg)
    });
    let timeline_window = timeline
        .as_ref()
        .map(|t| t.window_for_trim(job.start_frame, job.end_frame));
    if let Some(w) = &timeline_window {
        job.total_frames = Some(w.slots.len() as i32);
    }

    // Generate VapourSynth script
    reporter.send_log(models::LogLevel::Info, "Generating VapourSynth script...");
    // Detect OpenCL availability so QTGMC falls back to CPU NNEDI3 on machines
    // without a usable OpenCL device (headless CI, VMs, remote desktop).
    let opencl_available = deps.as_ref().map(|d| d.opencl_available()).unwrap_or(true);
    // Detect knlmeanscl availability separately (plugin + usable OpenCL device);
    // when unavailable the knlmeanscl denoiser is downgraded to dfttest.
    let knlm_available = deps.as_ref().map(|d| d.knlm_available()).unwrap_or(true);
    // The GPU plugins are probed only for a job that uses them: the probe
    // initialises the GPU.
    let gpu_runtime = |plugin: gpu_plugin::GpuPlugin, used: bool| {
        if !used {
            return Err(format!("{} is not used by this job.", plugin.label()));
        }
        match deps.as_ref() {
            Some(d) => d.gpu_plugin_runtime(plugin),
            None => Err(format!(
                "{} needs VapourBox's dependencies, which could not be found.",
                plugin.label()
            )),
        }
    };
    let pipeline = job.effective_pipeline();
    let rife = gpu_runtime(gpu_plugin::GpuPlugin::Rife, pipeline.uses_rife());
    let upscale = gpu_runtime(gpu_plugin::GpuPlugin::Upscale, pipeline.uses_ai_upscale());
    // Likewise KNLMeans, whose device probe runs KNLMeansCL once per boot.
    let knlm = if job.effective_pipeline().uses_knlm() {
        match deps.as_ref() {
            Some(d) => d.knlm_runtime(),
            None => Err("KNLMeans needs VapourBox's dependencies, which could not be found.".into()),
        }
    } else {
        Err("KNLMeans is not used by this job.".into())
    };
    let script_generator = ScriptGenerator::new()?
        .with_opencl_available(opencl_available)
        .with_knlm_available(knlm_available)
        .with_rife(rife)
        .with_upscale(upscale)
        .with_knlm(knlm)
        .with_animejanai(match deps.as_ref() {
            Some(d) if pipeline.uses_animejanai() => d.animejanai_runtime(),
            _ => Err(animejanai::MISSING_MESSAGE.to_string()),
        })
        .with_timeline(timeline_window);
    let script_generator = match deps.as_ref() {
        Some(d) => script_generator.with_addons(d.addons_dir(), d.platform_suffix()),
        None => script_generator,
    };
    let script_path = script_generator
        .generate(&job)
        .with_context(|| "Failed to generate VapourSynth script")?;

    reporter.send_log(
        models::LogLevel::Debug,
        &format!("Script written to: {:?}", script_path),
    );

    // ------------------------------------------------------------------
    // Audio restoration
    // ------------------------------------------------------------------
    // Rendered before the transcription and the encode, both of which then
    // use the rendered track (see audio_restoration.rs). After the script, so
    // a job the script generator refuses fails before any audio work. Held
    // to the end of the job: its scratch directory goes when it is dropped.
    let restored_audio = if job.effective_pipeline().audio.has_effect() {
        let d = dependency_locator::DependencyLocator::new()?;
        audio_restoration::AudioRestorer::new(reporter.clone(), d)
            .render(&job, || cancelled.load(Ordering::SeqCst))?
    } else {
        None
    };

    // AVI cannot mark a lossy audio encoder's start-up (priming), so Convert
    // into AVI reads its sound later by it (audio_restoration::EncoderPriming).
    // Before the sound copy: it moves the encoder's seek.
    let encoder_priming = {
        let d = dependency_locator::DependencyLocator::new()?;
        audio_restoration::AudioRestorer::new(reporter.clone(), d)
            .encoder_priming(&job, restored_audio.as_ref().map(|r| &r.track))
    };

    // A delayed AVI trimmed near its start cannot seek its sound
    // (source_decode rule 9): the encode then seeks a copy of it. Held to the
    // end of the job, like the rendered track.
    let sound_sidecar = {
        let d = dependency_locator::DependencyLocator::new()?;
        audio_restoration::AudioRestorer::new(reporter.clone(), d)
            .sound_sidecar(&job, restored_audio.as_ref().map(|r| &r.track), encoder_priming.as_ref())
    };

    // AVI cannot store a picture that starts after its sound either, so an
    // untrimmed late video starts both with the picture there (task #30).
    if let Some(note) = job.lead_sound_note() {
        reporter.send_log(models::LogLevel::Info, &note);
    }

    // AVI cannot store where a stream starts, so a copied sound that the
    // encoder seeks is cut there instead (audio_restoration::SoundCut).
    let sound_cut = {
        let d = dependency_locator::DependencyLocator::new()?;
        audio_restoration::AudioRestorer::new(reporter.clone(), d)
            .sound_cut(&job, restored_audio.as_ref().map(|r| &r.track))
    };

    // ------------------------------------------------------------------
    // Pre-encode transcription
    // ------------------------------------------------------------------
    // Whisper used to run only after the encode, which made burn-in
    // impossible: the encoder needs the subtitle file while it is running, and
    // a transcript that does not exist yet cannot be drawn into the picture.
    //
    // Transcribing before the encode means transcribing exactly the audio the
    // output will carry. With audio restoration that is the rendered track:
    // it is the output's soundtrack sample for sample — trimmed, offset,
    // drift-corrected and cleaned — so cues line up whatever was done to it,
    // and Whisper hears the cleaned sound. Without it, it is the source's
    // audio over the trim window: the encoder seeks the audio input to the
    // trim point, so a transcript of the whole source would put every cue
    // early by exactly the trimmed-off head. Nothing else retimes audio: IVTC
    // and frame-rate conversion change the video timeline only.
    let mut whisper_srt: Option<std::path::PathBuf> = None;
    if let Some(ref sub_settings) = job.subtitle_settings {
        if sub_settings.enabled && job.burn_in_subtitle_path.is_none() {
            // A delayed AVI near its start cannot seek its sound (rule 9):
            // the window then skips after decoding.
            let source_window = job.source_audio_window().map(|(start, duration)| {
                subtitle_generator::AudioWindow { seek: job.sound_seek(start), duration }
            });
            let (transcribe_from, window) = match &restored_audio {
                Some(r) => (r.track.path.to_string_lossy().to_string(), None),
                None => (job.input_path.clone(), source_window),
            };
            let srt_target = std::path::Path::new(&job.output_path).with_extension("srt");
            match dependency_locator::DependencyLocator::new().and_then(|d| {
                SubtitleGenerator::new(reporter.clone(), d).transcribe(
                    &transcribe_from,
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
        let mut executor = PipelineExecutor::new(reporter.clone())?
            .with_timeline(timeline.clone())
            .with_restored_audio(restored_audio.as_ref().map(|r| r.track.clone()))
            .with_sound_copy(sound_sidecar.as_ref().map(|s| s.copy.clone()))
            .with_sound_cut(sound_cut.clone())
            .with_encoder_priming(encoder_priming);
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

    // AAC in AVI: a packet over avienc's declared block size is timed as two
    // by every reader that times VBR chunks (task #41). Must follow anything
    // that writes the AVI; the subtitle mux below never rewrites one.
    if avi_header::checks_block_align(&job) {
        match avi_header::fix_aac_block_align(std::path::Path::new(&job.output_path)) {
            Ok(fixes) => {
                for fix in fixes {
                    reporter.send_log(models::LogLevel::Info, &fix.note());
                }
            }
            Err(e) => reporter.send_log(
                models::LogLevel::Warning,
                &format!("Could not check the AVI's AAC block size (players may time its sound late): {e:#}"),
            ),
        }
    }

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
    fn probe_cpu_reports_the_templates_ctmf_opt() {
        // Task #112: tests read this to call CTMF as the templates do. It is
        // the one decision, never 0 (auto-detect, which reaches CTMF's broken
        // 8-bit AVX-512 kernel) and never 4 (that kernel by name).
        let json = probe_cpu_json();
        let opt = json["ctmfOpt"].as_u64().expect("ctmfOpt is a number");
        assert_eq!(opt, u64::from(script_generator::ctmf_opt()));
        assert!(opt == 2 || opt == 3, "ctmfOpt {opt}");
    }

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
