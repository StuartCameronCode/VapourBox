//! iDeinterlace Worker - CLI video deinterlacing tool
//!
//! This worker process receives a job configuration file via --config argument,
//! generates a VapourSynth script, and runs the vspipe | ffmpeg pipeline.
//! Progress is reported via JSON messages on stdout.
//!
//! Preview mode: Use --preview --frame N to generate a single processed frame
//! as PNG output to stdout (binary).

use anyhow::{Context, Result};
use clap::Parser;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

mod models;
mod dependency_locator;
mod pipeline_executor;
mod progress_reporter;
mod script_generator;
mod platform;

use models::VideoJob;
use pipeline_executor::PipelineExecutor;
use progress_reporter::ProgressReporter;
use script_generator::ScriptGenerator;

/// Command-line arguments
#[derive(Parser, Debug)]
#[command(name = "ideinterlace-worker")]
#[command(about = "Video deinterlacing worker using QTGMC via VapourSynth")]
#[command(version)]
struct Args {
    /// Path to the job configuration JSON file
    #[arg(long)]
    config: PathBuf,

    /// Preview mode: generate a single processed frame as PNG to stdout
    #[arg(long)]
    preview: bool,

    /// Frame number to extract in preview mode (required with --preview)
    #[arg(long)]
    frame: Option<i32>,
}

fn main() -> ExitCode {
    let args = Args::parse();

    // Preview mode outputs raw PNG to stdout - no JSON messages
    if args.preview {
        return run_preview_mode(&args);
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

    match run_worker(&args, &reporter, cancelled) {
        Ok(output_path) => {
            reporter.send_complete(true, Some(&output_path));
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

/// Run in preview mode - generate single frame PNG to stdout
fn run_preview_mode(args: &Args) -> ExitCode {
    let frame = match args.frame {
        Some(f) => f,
        None => {
            eprintln!("Error: --frame is required with --preview");
            return ExitCode::from(1);
        }
    };

    // Load job configuration
    let config_content = match std::fs::read_to_string(&args.config) {
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

    // Calculate time from frame number
    let frame_rate = job.input_frame_rate.unwrap_or(29.97);
    let time_seconds = frame as f64 / frame_rate;

    eprintln!("Preview: frame {} at {:.3}s (fps: {:.2})", frame, time_seconds, frame_rate);

    // Execute preview (extracts frames with ffmpeg, processes with VapourSynth)
    let executor = match PipelineExecutor::new(ProgressReporter::new()) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("Error creating executor: {}", e);
            return ExitCode::from(1);
        }
    };

    match executor.generate_preview(&job, time_seconds) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("Error generating preview: {}", e);
            ExitCode::from(1)
        }
    }
}

fn run_worker(
    args: &Args,
    reporter: &ProgressReporter,
    cancelled: Arc<AtomicBool>,
) -> Result<String> {
    // Load job configuration
    reporter.send_log(models::LogLevel::Info, "Loading job configuration...");
    let config_content = std::fs::read_to_string(&args.config)
        .with_context(|| format!("Failed to read config file: {:?}", args.config))?;
    let job: VideoJob = serde_json::from_str(&config_content)
        .with_context(|| "Failed to parse job configuration")?;

    reporter.send_log(
        models::LogLevel::Info,
        &format!("Processing: {}", job.input_path),
    );
    reporter.send_log(
        models::LogLevel::Debug,
        &format!("QTGMC params: opencl={}, tff={:?}, preset={}",
            job.qtgmc_parameters.opencl,
            job.qtgmc_parameters.tff,
            job.qtgmc_parameters.preset.as_str()),
    );

    // Generate VapourSynth script
    reporter.send_log(models::LogLevel::Info, "Generating VapourSynth script...");
    let script_generator = ScriptGenerator::new()?;
    let script_path = script_generator
        .generate(&job)
        .with_context(|| "Failed to generate VapourSynth script")?;

    reporter.send_log(
        models::LogLevel::Debug,
        &format!("Script written to: {:?}", script_path),
    );

    // Execute pipeline
    reporter.send_log(models::LogLevel::Info, "Starting encoding pipeline...");
    let mut executor = PipelineExecutor::new(reporter.clone())?;

    let result = executor.execute(&script_path, &job, || cancelled.load(Ordering::SeqCst));

    // Keep temp script for debugging
    // if let Err(e) = std::fs::remove_file(&script_path) {
    //     reporter.send_log(
    //         models::LogLevel::Warning,
    //         &format!("Failed to remove temp script: {}", e),
    //     );
    // }

    // Handle cancellation or errors
    result?;

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
    Ok(job.output_path.clone())
}
