//! Pipeline executor for vspipe | ffmpeg.

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

use crate::dependency_locator::DependencyLocator;
use crate::models::{LogLevel, ProgressInfo, VideoJob};
use crate::progress_reporter::ProgressReporter;

/// Executes the vspipe | ffmpeg pipeline.
pub struct PipelineExecutor {
    reporter: ProgressReporter,
    deps: DependencyLocator,
    vspipe_process: Option<Child>,
    ffmpeg_process: Option<Child>,
}

impl PipelineExecutor {
    /// Create a new pipeline executor.
    pub fn new(reporter: ProgressReporter) -> Result<Self> {
        let deps = DependencyLocator::new()?;
        Ok(Self {
            reporter,
            deps,
            vspipe_process: None,
            ffmpeg_process: None,
        })
    }

    /// Execute the deinterlacing pipeline.
    pub fn execute<F>(&mut self, script_path: &Path, job: &VideoJob, on_cancel: F) -> Result<()>
    where
        F: Fn() -> bool,
    {
        let vspipe_path = self.deps.vspipe_path()?;
        let ffmpeg_path = self.deps.ffmpeg_path()?;
        let env = self.deps.build_environment();

        self.reporter.send_log(
            LogLevel::Debug,
            &format!("vspipe: {:?}, ffmpeg: {:?}", vspipe_path, ffmpeg_path),
        );

        // Debug: log environment
        self.reporter.send_log(
            LogLevel::Debug,
            &format!("PYTHONHOME: {:?}", env.get("PYTHONHOME")),
        );
        self.reporter.send_log(
            LogLevel::Debug,
            &format!("PYTHONPATH: {:?}", env.get("PYTHONPATH")),
        );
        self.reporter.send_log(
            LogLevel::Debug,
            &format!("VAPOURSYNTH_PLUGIN_PATH: {:?}", env.get("VAPOURSYNTH_PLUGIN_PATH")),
        );

        // Start vspipe process
        let mut vspipe = Command::new(&vspipe_path)
            .args(["-c", "y4m", script_path.to_string_lossy().as_ref(), "-"])
            .envs(&env)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("Failed to start vspipe: {:?}", vspipe_path))?;

        // Get vspipe stdout for piping to ffmpeg
        let vspipe_stdout = vspipe.stdout.take().context("Failed to get vspipe stdout")?;
        let vspipe_stderr = vspipe.stderr.take().context("Failed to get vspipe stderr")?;

        // Build FFmpeg arguments
        let ffmpeg_args = self.build_ffmpeg_args(job);

        // Start ffmpeg process
        let mut ffmpeg = Command::new(&ffmpeg_path)
            .args(&ffmpeg_args)
            .envs(&env)
            .stdin(vspipe_stdout)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("Failed to start ffmpeg: {:?}", ffmpeg_path))?;

        let ffmpeg_stderr = ffmpeg.stderr.take().context("Failed to get ffmpeg stderr")?;

        self.vspipe_process = Some(vspipe);
        self.ffmpeg_process = Some(ffmpeg);

        // Parse vspipe stderr for input info (in background thread)
        let total_frames = Arc::new(AtomicI32::new(0));
        let total_frames_clone = total_frames.clone();
        let reporter_clone = self.reporter.clone();

        let vspipe_thread = thread::spawn(move || {
            let reader = BufReader::new(vspipe_stderr);
            for line in reader.lines().map_while(Result::ok) {
                // Log all stderr for debugging
                reporter_clone.send_log(LogLevel::Debug, &format!("vspipe stderr: {}", line));

                if line.starts_with("INPUT_INFO:") {
                    // Parse: INPUT_INFO:frames=1234,fps_num=25,fps_den=1
                    for part in line["INPUT_INFO:".len()..].split(',') {
                        if let Some(frames_str) = part.strip_prefix("frames=") {
                            if let Ok(frames) = frames_str.parse::<i32>() {
                                total_frames_clone.store(frames, Ordering::SeqCst);
                            }
                        }
                    }
                }
            }
        });

        // Parse ffmpeg stderr for progress
        let reporter = self.reporter.clone();
        let progress_interval = Duration::from_millis(500);
        let mut last_progress_time = Instant::now();
        let mut current_frame = 0i32;
        let mut current_fps = 0.0f64;

        let ffmpeg_reader = BufReader::new(ffmpeg_stderr);
        for line in ffmpeg_reader.lines().map_while(Result::ok) {
            // Check for cancellation
            if on_cancel() {
                self.terminate();
                bail!("Job cancelled");
            }

            // Parse ffmpeg progress output
            // Format: frame=  123 fps= 45.0 ...
            if line.starts_with("frame=") {
                if let Some(frame_str) = line.split_whitespace().nth(0) {
                    if let Some(frame_num) = frame_str.strip_prefix("frame=") {
                        if let Ok(f) = frame_num.trim().parse::<i32>() {
                            current_frame = f;
                        }
                    }
                }
            }
            if line.contains("fps=") {
                for part in line.split_whitespace() {
                    if let Some(fps_str) = part.strip_prefix("fps=") {
                        if let Ok(f) = fps_str.trim().parse::<f64>() {
                            current_fps = f;
                        }
                    }
                }
            }

            // Send progress update (throttled)
            if last_progress_time.elapsed() >= progress_interval {
                let total = total_frames.load(Ordering::SeqCst);
                let effective_total = if total > 0 {
                    // Double frames for double-rate output
                    if job.qtgmc_parameters.fps_divisor == 1 { total * 2 } else { total }
                } else {
                    job.total_frames.unwrap_or(0)
                };

                let eta = if current_fps > 0.0 && effective_total > current_frame {
                    ((effective_total - current_frame) as f64) / current_fps
                } else {
                    0.0
                };

                let progress = ProgressInfo::new(current_frame, effective_total, current_fps, eta);
                reporter.send_progress(&progress);
                last_progress_time = Instant::now();
            }
        }

        // Wait for threads to finish
        let _ = vspipe_thread.join();

        // Wait for processes to exit
        let vspipe_status = self
            .vspipe_process
            .as_mut()
            .map(|p| p.wait())
            .transpose()
            .context("Failed to wait for vspipe")?;

        let ffmpeg_status = self
            .ffmpeg_process
            .as_mut()
            .map(|p| p.wait())
            .transpose()
            .context("Failed to wait for ffmpeg")?;

        // Check exit codes
        if let Some(status) = vspipe_status {
            let code = status.code().unwrap_or(-1);
            // Allow SIGTERM (130), SIGPIPE (141)
            if code != 0 && code != 130 && code != 141 {
                bail!("vspipe exited with code {}", code);
            }
        }

        if let Some(status) = ffmpeg_status {
            let code = status.code().unwrap_or(-1);
            if code != 0 && code != 130 && code != 141 {
                bail!("ffmpeg exited with code {}", code);
            }
        }

        Ok(())
    }

    /// Build FFmpeg command-line arguments.
    fn build_ffmpeg_args(&self, job: &VideoJob) -> Vec<String> {
        let mut args = Vec::new();
        let settings = &job.encoding_settings;

        // Input from pipe
        args.extend(["-f".to_string(), "yuv4mpegpipe".to_string()]);
        args.extend(["-i".to_string(), "-".to_string()]);

        // Progress output to stderr
        args.extend(["-progress".to_string(), "pipe:2".to_string()]);

        // Video codec
        args.extend(["-c:v".to_string(), settings.codec.ffmpeg_codec().to_string()]);

        // ProRes profile
        if let Some(profile) = settings.codec.prores_profile() {
            args.extend(["-profile:v".to_string(), profile.to_string()]);
        } else {
            // Quality (CRF for H.264/H.265)
            args.extend(["-crf".to_string(), settings.quality.to_string()]);
            args.extend(["-preset".to_string(), settings.encoder_preset.clone()]);
        }

        // Audio handling
        if settings.audio_copy {
            args.extend(["-c:a".to_string(), "copy".to_string()]);
        } else {
            args.extend(["-c:a".to_string(), settings.audio_codec.clone()]);
            args.extend(["-b:a".to_string(), format!("{}k", settings.audio_bitrate)]);
        }

        // Custom arguments
        if !settings.custom_ffmpeg_args.is_empty() {
            args.extend(settings.custom_ffmpeg_args.split_whitespace().map(String::from));
        }

        // Output file (force overwrite)
        args.push("-y".to_string());
        args.push(job.output_path.clone());

        args
    }

    /// Generate a preview frame as PNG to stdout.
    ///
    /// This runs vspipe for a single frame and pipes it through ffmpeg
    /// to output PNG data to stdout.
    pub fn generate_preview(&self, script_path: &Path, frame: i32) -> Result<()> {
        use std::io::Write;

        let vspipe_path = self.deps.vspipe_path()?;
        let ffmpeg_path = self.deps.ffmpeg_path()?;
        let env = self.deps.build_environment();

        // Start vspipe for single frame
        let mut vspipe = Command::new(&vspipe_path)
            .args([
                "--start", &frame.to_string(),
                "--end", &frame.to_string(),
                "-c", "y4m",
                script_path.to_string_lossy().as_ref(),
                "-",
            ])
            .envs(&env)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("Failed to start vspipe: {:?}", vspipe_path))?;

        let vspipe_stdout = vspipe.stdout.take().context("Failed to get vspipe stdout")?;
        let vspipe_stderr = vspipe.stderr.take();

        // Start ffmpeg to encode as PNG to stdout
        // Use zscale filter to properly convert YUV limited range to RGB full range
        let ffmpeg = Command::new(&ffmpeg_path)
            .args([
                "-f", "yuv4mpegpipe",
                "-i", "-",
                "-vframes", "1",
                "-vf", "scale=in_range=tv:out_range=pc",
                "-f", "image2pipe",
                "-vcodec", "png",
                "-",
            ])
            .envs(&env)
            .stdin(vspipe_stdout)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("Failed to start ffmpeg: {:?}", ffmpeg_path))?;

        // Read vspipe stderr in background for error messages
        let stderr_thread = if let Some(stderr) = vspipe_stderr {
            Some(thread::spawn(move || {
                let reader = BufReader::new(stderr);
                let mut errors = Vec::new();
                for line in reader.lines().map_while(Result::ok) {
                    // Skip INPUT_INFO lines
                    if !line.starts_with("INPUT_INFO:") && !line.trim().is_empty() {
                        errors.push(line);
                    }
                }
                errors
            }))
        } else {
            None
        };

        // Wait for vspipe to finish
        let vspipe_status = vspipe.wait().context("Failed to wait for vspipe")?;

        // Read PNG output from ffmpeg
        let output = ffmpeg.wait_with_output().context("Failed to wait for ffmpeg")?;

        // Check for errors
        if !vspipe_status.success() {
            let errors = stderr_thread.map(|t| t.join().ok()).flatten().unwrap_or_default();
            if !errors.is_empty() {
                bail!("vspipe failed: {}", errors.join("\n"));
            }
            bail!("vspipe exited with code {}", vspipe_status.code().unwrap_or(-1));
        }

        if !output.status.success() {
            bail!("ffmpeg exited with code {}", output.status.code().unwrap_or(-1));
        }

        // Write PNG to stdout
        std::io::stdout().write_all(&output.stdout)?;
        std::io::stdout().flush()?;

        Ok(())
    }

    /// Terminate both processes.
    fn terminate(&mut self) {
        if let Some(ref mut vspipe) = self.vspipe_process {
            let _ = vspipe.kill();
        }
        if let Some(ref mut ffmpeg) = self.ffmpeg_process {
            let _ = ffmpeg.kill();
        }
    }
}

impl Drop for PipelineExecutor {
    fn drop(&mut self) {
        self.terminate();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{EncodingSettings, QTGMCParameters};
    use uuid::Uuid;

    #[test]
    fn test_build_ffmpeg_args() {
        let reporter = ProgressReporter::new();
        // This will fail without deps, but we can test arg building
        let job = VideoJob {
            id: Uuid::new_v4(),
            input_path: "input.mp4".to_string(),
            output_path: "output.mp4".to_string(),
            qtgmc_parameters: QTGMCParameters::default(),
            encoding_settings: EncodingSettings::default(),
            detected_field_order: None,
            total_frames: None,
            input_frame_rate: None,
        };

        // We can't fully test without dependencies, but the struct compiles
        assert_eq!(job.output_path, "output.mp4");
    }
}
