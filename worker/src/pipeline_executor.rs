//! Pipeline executor for vspipe | ffmpeg.

use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use anyhow::{bail, Context, Result};

use crate::dependency_locator::DependencyLocator;
use crate::models::{AudioMode, ContainerFormat, DeinterlaceMethod, EncoderFamily, EncodingSettings, LogLevel, ProgressInfo, SubtitleOutput, VideoCodec, VideoJob};
use crate::progress_reporter::ProgressReporter;
use crate::script_generator::{PreviewParams, ScriptGenerator};

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

        // Use SAR from job (detected during import) or probe as fallback
        let input_sar = job.input_sar.clone().or_else(|| self.probe_sar(&job.input_path));
        if let Some(ref sar) = input_sar {
            self.reporter.send_log(LogLevel::Debug, &format!("Input SAR: {}", sar));
        }

        // Build FFmpeg arguments, using a temp file for progress to avoid
        // Windows pipe buffering which delays progress by ~10K frames.
        let progress_file = std::env::temp_dir().join(format!("vb_progress_{}", job.id));
        let existing_comment = self.probe_comment(&job.input_path);
        let ffmpeg_args = self.build_ffmpeg_args(job, &progress_file, input_sar.as_deref(), existing_comment.as_deref());

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

        // Determine how deinterlacing affects output frame count
        let pipeline = job.effective_pipeline();
        let is_double_rate = pipeline.deinterlace.enabled
            && pipeline.deinterlace.method == DeinterlaceMethod::Qtgmc
            && pipeline.deinterlace.fps_divisor == 1;
        let is_ivtc = pipeline.deinterlace.enabled
            && pipeline.deinterlace.method == DeinterlaceMethod::Ivtc;
        let ivtc_cycle = pipeline.deinterlace.ivtc_cycle;

        // Capture ffmpeg stderr in a background thread (for error messages).
        // Progress comes from the temp file, not stderr.
        let ffmpeg_reporter = self.reporter.clone();
        let ffmpeg_stderr_thread = thread::spawn(move || {
            let reader = BufReader::new(ffmpeg_stderr);
            let mut last_line = String::new();
            for line in reader.lines().map_while(Result::ok) {
                ffmpeg_reporter.send_log(LogLevel::Debug, &format!("ffmpeg stderr: {}", line));
                last_line = line;
            }
            last_line
        });

        // Poll the progress file for updates instead of reading piped stderr.
        // Windows buffers pipe writes (~64KB), delaying progress by thousands
        // of frames. File reads always return the latest data immediately.
        let reporter = self.reporter.clone();
        let progress_interval = Duration::from_millis(500);
        let mut current_frame = 0i32;
        let mut current_fps = 0.0f64;
        let mut smoothed_fps = 0.0f64;
        let mut vspipe_total: i32 = 0;

        loop {
            // Check for cancellation
            if on_cancel() {
                self.terminate();
                let _ = fs::remove_file(&progress_file);
                bail!("Job cancelled");
            }

            // Parse the progress file for the latest values.
            // Also check for "progress=end" which ffmpeg writes when done.
            let mut ffmpeg_done = false;
            if let Ok(content) = fs::read_to_string(&progress_file) {
                for line in content.lines() {
                    if let Some(val) = line.strip_prefix("frame=") {
                        if let Ok(f) = val.trim().parse::<i32>() {
                            current_frame = f;
                        }
                    } else if let Some(val) = line.strip_prefix("fps=") {
                        if let Ok(f) = val.trim().parse::<f64>() {
                            if f > 0.0 {
                                current_fps = f;
                                if smoothed_fps <= 0.0 {
                                    smoothed_fps = f;
                                } else {
                                    smoothed_fps = 0.15 * f + 0.85 * smoothed_fps;
                                }
                            }
                        }
                    } else if line.starts_with("progress=end") {
                        ffmpeg_done = true;
                    }
                }
            }

            // Also check process exit as a fallback
            if !ffmpeg_done {
                ffmpeg_done = self
                    .ffmpeg_process
                    .as_mut()
                    .and_then(|p| p.try_wait().ok().flatten())
                    .is_some();
            }

            // Send progress if we have meaningful data
            if current_frame > 0 {
                let reported = total_frames.load(Ordering::SeqCst);
                if reported > 0 {
                    vspipe_total = reported;
                }

                if vspipe_total > 0 {
                    let mut effective_total = if is_double_rate {
                        vspipe_total * 2
                    } else if is_ivtc && ivtc_cycle > 1 {
                        // IVTC VDecimate removes 1 frame per cycle
                        vspipe_total * (ivtc_cycle - 1) / ivtc_cycle
                    } else {
                        vspipe_total
                    };

                    // Safety clamp: if current_frame exceeds total, metadata was wrong
                    if current_frame > effective_total {
                        effective_total = current_frame;
                    }

                    let eta = if smoothed_fps > 0.0 && effective_total > current_frame {
                        ((effective_total - current_frame) as f64) / smoothed_fps
                    } else {
                        0.0
                    };

                    let progress = ProgressInfo::new(current_frame, effective_total, current_fps, eta);
                    reporter.send_progress(&progress);
                }
            }

            if ffmpeg_done {
                break;
            }

            thread::sleep(progress_interval);
        }

        // Wait for processes to exit FIRST (closes their pipes, unblocking reader threads)
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

        // Now safe to join threads (pipes are closed, readers will hit EOF)
        let _ = vspipe_thread.join();
        let _ = ffmpeg_stderr_thread.join();

        // Clean up progress file
        let _ = fs::remove_file(&progress_file);

        // Check exit codes
        if let Some(status) = vspipe_status {
            let code = status.code().unwrap_or(-1);
            if code != 0 && code != 130 && code != 141 {
                bail!("vspipe exited with code {}", code);
            }
        }

        let ffmpeg_ok = if let Some(status) = ffmpeg_status {
            let code = status.code().unwrap_or(-1);
            if code != 0 && code != 130 && code != 141 {
                bail!("ffmpeg exited with code {}", code);
            }
            true
        } else {
            false
        };

        // Send final 100% progress when job succeeds.
        // The source metadata total can be wrong (e.g. AVI containers),
        // so use the actual frame count ffmpeg processed as the definitive total.
        if ffmpeg_ok && current_frame > 0 {
            let final_progress = ProgressInfo::new(current_frame, current_frame, current_fps, 0.0);
            reporter.send_progress(&final_progress);
        }

        Ok(())
    }

    /// Probe the input file's comment metadata using ffprobe.
    fn probe_comment(&self, input_path: &str) -> Option<String> {
        let ffprobe_path = self.deps.ffprobe_path().ok()?;
        let env = self.deps.build_environment();

        let output = Command::new(&ffprobe_path)
            .args([
                "-v", "quiet",
                "-show_entries", "format_tags=comment",
                "-of", "csv=p=0",
                input_path,
            ])
            .envs(&env)
            .output()
            .ok()?;

        let comment = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if comment.is_empty() { None } else { Some(comment) }
    }

    /// Probe the input file's sample aspect ratio (SAR) using ffprobe.
    /// Returns "N:M" string (e.g. "10:11") or None if SAR is 1:1 or unavailable.
    fn probe_sar(&self, input_path: &str) -> Option<String> {
        let ffprobe_path = self.deps.ffprobe_path().ok()?;
        let env = self.deps.build_environment();

        let output = Command::new(&ffprobe_path)
            .args([
                "-v", "quiet",
                "-select_streams", "v:0",
                "-show_entries", "stream=sample_aspect_ratio",
                "-of", "csv=p=0",
                input_path,
            ])
            .envs(&env)
            .output()
            .ok()?;

        let sar = String::from_utf8_lossy(&output.stdout).trim().to_string();

        // Ignore missing, unknown, or square pixel SAR
        if sar.is_empty() || sar == "N/A" || sar == "1:1" {
            return None;
        }

        // Validate format is "N:M"
        let parts: Vec<&str> = sar.split(':').collect();
        if parts.len() == 2 && parts[0].parse::<u32>().is_ok() && parts[1].parse::<u32>().is_ok() {
            Some(sar)
        } else {
            None
        }
    }

    /// Build FFmpeg command-line arguments.
    fn build_ffmpeg_args(&self, job: &VideoJob, progress_file: &Path, input_sar: Option<&str>, existing_comment: Option<&str>) -> Vec<String> {
        let mut args = Vec::new();
        let settings = &job.encoding_settings;

        // Input 0: Processed video from vspipe (Y4M pipe)
        args.extend(["-f".to_string(), "yuv4mpegpipe".to_string()]);
        args.extend(["-i".to_string(), "-".to_string()]);

        // Input 1: Original file for audio stream
        // (Y4M from vspipe contains only video, so we need the original file for audio)
        args.extend(["-i".to_string(), job.input_path.clone()]);

        // Progress output to a temp file (avoids Windows pipe buffering delay)
        args.extend(["-progress".to_string(), progress_file.to_string_lossy().to_string()]);

        // Map streams: video from input 0 (processed), audio and subtitles from input 1 (original)
        args.extend(["-map".to_string(), "0:v".to_string()]);  // Video from Y4M pipe
        if settings.audio_mode != AudioMode::None {
            args.extend(["-map".to_string(), "1:a?".to_string()]); // Audio from original (? = optional)
        }

        // Preserve existing subtitle streams from source (? = optional, no error if none)
        let subtitle_embed_pending = job.subtitle_settings.as_ref()
            .is_some_and(|s| s.enabled && !matches!(s.output, SubtitleOutput::SrtFile));
        match settings.container {
            ContainerFormat::Mkv => {
                args.extend(["-map".to_string(), "1:s?".to_string()]);
                args.extend(["-c:s".to_string(), "copy".to_string()]);
            }
            ContainerFormat::Mp4 | ContainerFormat::Mov if !subtitle_embed_pending => {
                // Transcode text subs to mov_text; image-based subs (PGS) will be
                // skipped by ffmpeg if they can't be converted.
                args.extend(["-map".to_string(), "1:s?".to_string()]);
                args.extend(["-c:s".to_string(), "mov_text".to_string()]);
            }
            _ => {} // AVI and others: skip subtitle mapping
        }

        // Video codec
        args.extend(["-c:v".to_string(), settings.codec.ffmpeg_codec().to_string()]);

        // Encoder-family-specific quality and preset args
        Self::build_encoder_quality_args(&mut args, settings);

        // Preserve input sample aspect ratio (SAR) when no resize is applied.
        // The Y4M pipe from vspipe strips SAR metadata, so we must re-apply it.
        let pipeline = job.effective_pipeline();
        let resize_active = pipeline.crop_resize.enabled && pipeline.crop_resize.resize_enabled;
        if !resize_active {
            if let Some(sar) = input_sar {
                // Use '/' as ratio separator — ':' is the ffmpeg filter option separator
                let sar_filter = sar.replace(':', "/");
                args.extend(["-vf".to_string(), format!("setsar={}", sar_filter)]);
            }
        }

        // Audio handling
        match settings.audio_mode {
            AudioMode::Passthrough => {
                args.extend(["-c:a".to_string(), "copy".to_string()]);
            }
            AudioMode::Convert => {
                args.extend(["-c:a".to_string(), settings.audio_codec.ffmpeg_name().to_string()]);
                // Only add bitrate for lossy codecs
                if !settings.audio_codec.is_lossless() {
                    args.extend(["-b:a".to_string(), format!("{}k", settings.audio_quality.bitrate())]);
                }
            }
            AudioMode::None => {
                args.push("-an".to_string());
            }
        }

        // Timestamp normalization for modes that change frame rate.
        // Fixes audio sync offset caused by mismatched initial PTS between the
        // Y4M pipe (starts at 0) and audio from the original container.
        // Safe/no-op when timestamps are already aligned.
        let is_framerate_change = pipeline.deinterlace.enabled
            && matches!(
                pipeline.deinterlace.method,
                DeinterlaceMethod::Ivtc | DeinterlaceMethod::SoftTelecine
            );
        if is_framerate_change {
            args.extend(["-avoid_negative_ts".to_string(), "make_zero".to_string()]);
            args.push("-start_at_zero".to_string());
        }

        // Embed VapourBox version in output metadata, preserving any existing comment
        let version = env!("CARGO_PKG_VERSION");
        let comment = match existing_comment {
            Some(existing) => format!("VapourBox {} | {}", version, existing),
            None => format!("VapourBox {}", version),
        };
        args.extend(["-metadata".to_string(), format!("comment={}", comment)]);

        // Custom arguments
        if !settings.custom_ffmpeg_args.is_empty() {
            args.extend(settings.custom_ffmpeg_args.split_whitespace().map(String::from));
        }

        // Output file (force overwrite)
        args.push("-y".to_string());
        args.push(job.output_path.clone());

        args
    }

    /// Build encoder-family-specific quality and preset arguments.
    fn build_encoder_quality_args(args: &mut Vec<String>, settings: &EncodingSettings) {
        if let Some(profile) = settings.codec.prores_profile() {
            args.push("-profile:v".to_string());
            args.push(profile.to_string());
        } else {
            match settings.codec.encoder_family() {
                EncoderFamily::Software => {
                    args.extend(["-crf".to_string(), settings.quality.to_string()]);
                    args.extend(["-preset".to_string(), settings.encoder_preset.clone()]);
                }
                EncoderFamily::Nvenc => {
                    // VBR with constant quality (-cq) provides much better quality
                    // than constqp mode. -b:v 0 removes bitrate ceiling so the
                    // encoder allocates whatever bitrate the content needs.
                    args.extend(["-rc".to_string(), "vbr".to_string()]);
                    args.extend(["-cq".to_string(), settings.quality.to_string()]);
                    args.extend(["-b:v".to_string(), "0".to_string()]);
                    args.extend(["-preset".to_string(), settings.encoder_preset.clone()]);
                    args.extend(["-tune".to_string(), "hq".to_string()]);
                    args.extend(["-multipass".to_string(), "fullres".to_string()]);
                    args.extend(["-rc-lookahead".to_string(), "32".to_string()]);
                    args.extend(["-spatial-aq".to_string(), "1".to_string()]);
                    args.extend(["-aq-strength".to_string(), "8".to_string()]);
                    args.extend(["-b_ref_mode".to_string(), "middle".to_string()]);
                    args.extend(["-bf".to_string(), "3".to_string()]);
                    if matches!(settings.codec, VideoCodec::H264Nvenc) {
                        args.extend(["-profile:v".to_string(), "high".to_string()]);
                    }
                }
                EncoderFamily::Qsv => {
                    args.extend(["-global_quality".to_string(), settings.quality.to_string()]);
                    args.extend(["-preset".to_string(), settings.encoder_preset.clone()]);
                }
                EncoderFamily::Videotoolbox => {
                    // VideoToolbox uses q:v with inverted scale (CRF 0-51 -> q:v 100-1)
                    let vt_quality = ((51 - settings.quality) as f64 * 100.0 / 51.0).round().max(1.0) as i32;
                    args.extend(["-q:v".to_string(), vt_quality.to_string()]);
                }
                EncoderFamily::Amf => {
                    args.extend(["-rc".to_string(), "cqp".to_string()]);
                    args.extend(["-qp_i".to_string(), settings.quality.to_string()]);
                    args.extend(["-qp_p".to_string(), settings.quality.to_string()]);
                    args.extend(["-quality".to_string(), settings.encoder_preset.clone()]);
                }
                EncoderFamily::Lossless | EncoderFamily::ProRes => {
                    // No quality/preset args needed
                }
            }
        }
    }

    /// Generate a preview frame as PNG to stdout.
    ///
    /// This extracts frames around the target time using ffmpeg (fast keyframe seek),
    /// then processes them through VapourSynth with the filter pipeline.
    pub fn generate_preview(&self, job: &VideoJob, time_seconds: f64) -> Result<()> {
        use std::io::Write;

        let ffmpeg_path = self.deps.ffmpeg_path()?;
        let vspipe_path = self.deps.vspipe_path()?;
        let env = self.deps.build_environment();

        // Create temp directory for extracted frames
        let temp_dir = std::env::temp_dir().join(format!("vapourbox_preview_{}", job.id));
        fs::create_dir_all(&temp_dir)
            .with_context(|| format!("Failed to create temp dir: {:?}", temp_dir))?;

        // Number of frames to extract (need enough for QTGMC temporal processing)
        let num_frames = 11; // Extract 11 frames, use middle one
        let frame_rate = job.input_frame_rate.unwrap_or(29.97);
        let frame_duration = 1.0 / frame_rate;

        // Calculate start time (go back half the frames)
        let start_time = (time_seconds - (num_frames as f64 / 2.0) * frame_duration).max(0.0);

        eprintln!("Extracting {} frames starting at {:.3}s", num_frames, start_time);

        // Extract frames to a temporary lossless video file (FFV1)
        // Using a video file instead of images because ffms2 is available but imwri is not
        let temp_video_path = temp_dir.join("preview_clip.mkv");
        let extract_result = Command::new(&ffmpeg_path)
            .args([
                "-ss", &format!("{:.3}", start_time),
                "-i", &job.input_path,
                "-vframes", &num_frames.to_string(),
                "-c:v", "ffv1",
                "-level", "1",
                "-an",
                temp_video_path.to_string_lossy().as_ref(),
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .with_context(|| "Failed to run ffmpeg for frame extraction")?;

        if !extract_result.status.success() {
            let stderr = String::from_utf8_lossy(&extract_result.stderr);
            // Clean up
            let _ = fs::remove_dir_all(&temp_dir);
            bail!("Failed to extract frames: {}", stderr);
        }

        // Verify the file was created
        if !temp_video_path.exists() {
            let _ = fs::remove_dir_all(&temp_dir);
            bail!("Failed to create preview clip");
        }

        eprintln!("Extracted frames to {:?}", temp_video_path);

        // Determine field order for interlaced content
        let field_based = if job.qtgmc_parameters.tff == Some(true) {
            2 // TFF
        } else {
            1 // BFF
        };

        // Generate preview script using the script generator
        let script_generator = ScriptGenerator::new()?;
        let preview_params = PreviewParams {
            video_path: temp_video_path.to_string_lossy().to_string(),
            fps_num: (frame_rate * 1000.0) as i32,
            fps_den: 1000,
            field_based,
        };

        let script_path = script_generator.generate_preview(job, &preview_params)?;

        eprintln!("Generated preview script: {:?}", script_path);

        // Run vspipe on the preview script (outputs single frame)
        let mut vspipe = Command::new(&vspipe_path)
            .args([
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
                    if !line.starts_with("INPUT_INFO:") &&
                       !line.starts_with("Loaded template") &&
                       !line.trim().is_empty() {
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

        // Clean up temp files
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::remove_file(&script_path);

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
    use crate::models::{AudioCodec, AudioQuality, EncodingSettings, QTGMCParameters, VideoCodec};
    use uuid::Uuid;

    /// Helper to build FFmpeg args without requiring a full PipelineExecutor.
    /// This mirrors the logic in PipelineExecutor::build_ffmpeg_args for testing.
    fn build_ffmpeg_args_for_test(job: &VideoJob) -> Vec<String> {
        let mut args = Vec::new();
        let settings = &job.encoding_settings;

        // Input 0: Processed video from vspipe (Y4M pipe)
        args.extend(["-f".to_string(), "yuv4mpegpipe".to_string()]);
        args.extend(["-i".to_string(), "-".to_string()]);

        // Input 1: Original file for audio stream
        args.extend(["-i".to_string(), job.input_path.clone()]);

        // Progress output to temp file
        args.extend(["-progress".to_string(), "/tmp/test_progress.txt".to_string()]);

        // Map streams: video from input 0 (processed), audio from input 1 (original) if not disabled
        args.extend(["-map".to_string(), "0:v".to_string()]);
        if settings.audio_mode != AudioMode::None {
            args.extend(["-map".to_string(), "1:a?".to_string()]);
        }

        // Video codec
        args.extend(["-c:v".to_string(), settings.codec.ffmpeg_codec().to_string()]);

        // Encoder-family-specific quality and preset args
        PipelineExecutor::build_encoder_quality_args(&mut args, settings);

        // Audio handling
        match settings.audio_mode {
            AudioMode::Passthrough => {
                args.extend(["-c:a".to_string(), "copy".to_string()]);
            }
            AudioMode::Convert => {
                args.extend(["-c:a".to_string(), settings.audio_codec.ffmpeg_name().to_string()]);
                // Only add bitrate for lossy codecs
                if !settings.audio_codec.is_lossless() {
                    args.extend(["-b:a".to_string(), format!("{}k", settings.audio_quality.bitrate())]);
                }
            }
            AudioMode::None => {
                args.push("-an".to_string());
            }
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

    fn create_test_job(output_path: &str) -> VideoJob {
        VideoJob {
            id: Uuid::new_v4(),
            input_path: "input.mp4".to_string(),
            output_path: output_path.to_string(),
            qtgmc_parameters: QTGMCParameters::default(),
            restoration_pipeline: None,
            encoding_settings: EncodingSettings::default(),
            detected_field_order: None,
            total_frames: None,
            input_frame_rate: None,
            start_frame: None,
            end_frame: None,
            subtitle_settings: None,
            subtitle_only: false,
            input_sar: None,
        }
    }

    #[test]
    fn test_default_encoding_settings_has_audio_passthrough() {
        let settings = EncodingSettings::default();
        assert_eq!(
            settings.audio_mode,
            AudioMode::Passthrough,
            "Default encoding settings should have audio_mode=Passthrough to preserve original audio"
        );
    }

    #[test]
    fn test_ffmpeg_args_audio_passthrough_produces_stream_copy() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.audio_mode = AudioMode::Passthrough;

        let args = build_ffmpeg_args_for_test(&job);

        // Find the audio codec argument
        let audio_codec_idx = args.iter().position(|a| a == "-c:a");
        assert!(audio_codec_idx.is_some(), "FFmpeg args should contain -c:a");

        let codec_value = &args[audio_codec_idx.unwrap() + 1];
        assert_eq!(
            codec_value, "copy",
            "When audio_mode=Passthrough, FFmpeg should use '-c:a copy' to passthrough audio unchanged"
        );

        // Ensure no bitrate argument is present (copy doesn't need bitrate)
        let has_audio_bitrate = args.iter().any(|a| a == "-b:a");
        assert!(
            !has_audio_bitrate,
            "When audio_mode=Passthrough, FFmpeg should not have -b:a (bitrate) argument"
        );
    }

    #[test]
    fn test_ffmpeg_args_audio_convert_uses_codec_and_bitrate() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.audio_mode = AudioMode::Convert;
        job.encoding_settings.audio_codec = AudioCodec::Aac;
        job.encoding_settings.audio_quality = AudioQuality::VeryHigh;

        let args = build_ffmpeg_args_for_test(&job);

        // Find the audio codec argument
        let audio_codec_idx = args.iter().position(|a| a == "-c:a");
        assert!(audio_codec_idx.is_some(), "FFmpeg args should contain -c:a");

        let codec_value = &args[audio_codec_idx.unwrap() + 1];
        assert_eq!(
            codec_value, "aac",
            "When audio_mode=Convert, FFmpeg should use the specified audio codec"
        );

        // Find the audio bitrate argument
        let audio_bitrate_idx = args.iter().position(|a| a == "-b:a");
        assert!(
            audio_bitrate_idx.is_some(),
            "When audio_mode=Convert, FFmpeg should have -b:a (bitrate) argument"
        );

        let bitrate_value = &args[audio_bitrate_idx.unwrap() + 1];
        assert_eq!(
            bitrate_value, "256k",
            "Audio bitrate should be formatted as '256k'"
        );
    }

    #[test]
    fn test_ffmpeg_args_audio_convert_flac_no_bitrate() {
        let mut job = create_test_job("output.mkv");
        job.encoding_settings.audio_mode = AudioMode::Convert;
        job.encoding_settings.audio_codec = AudioCodec::Flac;

        let args = build_ffmpeg_args_for_test(&job);

        // Find the audio codec argument
        let audio_codec_idx = args.iter().position(|a| a == "-c:a");
        assert!(audio_codec_idx.is_some(), "FFmpeg args should contain -c:a");

        let codec_value = &args[audio_codec_idx.unwrap() + 1];
        assert_eq!(
            codec_value, "flac",
            "When audio_codec=Flac, FFmpeg should use flac codec"
        );

        // Ensure no bitrate argument for lossless codec
        let has_audio_bitrate = args.iter().any(|a| a == "-b:a");
        assert!(
            !has_audio_bitrate,
            "Lossless codecs (FLAC) should not have -b:a (bitrate) argument"
        );
    }

    #[test]
    fn test_ffmpeg_args_audio_none_produces_no_audio() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.audio_mode = AudioMode::None;

        let args = build_ffmpeg_args_for_test(&job);

        // Should have -an flag
        assert!(
            args.contains(&"-an".to_string()),
            "When audio_mode=None, FFmpeg should have -an flag"
        );

        // Should not map audio stream
        assert!(
            !args.contains(&"1:a?".to_string()),
            "When audio_mode=None, FFmpeg should not map audio stream"
        );

        // Should not have audio codec argument
        let audio_codec_idx = args.iter().position(|a| a == "-c:a");
        assert!(
            audio_codec_idx.is_none(),
            "When audio_mode=None, FFmpeg should not have -c:a argument"
        );
    }

    #[test]
    fn test_ffmpeg_args_contains_input_and_output() {
        let job = create_test_job("output_test.mp4");
        let args = build_ffmpeg_args_for_test(&job);

        // Check for yuv4mpegpipe input (from vspipe)
        assert!(
            args.contains(&"-f".to_string()) && args.contains(&"yuv4mpegpipe".to_string()),
            "FFmpeg args should specify yuv4mpegpipe format for input from vspipe"
        );

        // Check for stdin input
        let stdin_idx = args.iter().position(|a| a == "-i");
        assert!(stdin_idx.is_some(), "FFmpeg args should have -i for input");
        assert_eq!(
            args[stdin_idx.unwrap() + 1], "-",
            "FFmpeg should read from stdin (pipe from vspipe)"
        );

        // Check for output file
        assert!(
            args.last() == Some(&"output_test.mp4".to_string()),
            "FFmpeg args should end with output file path"
        );

        // Check for overwrite flag
        assert!(
            args.contains(&"-y".to_string()),
            "FFmpeg args should contain -y to force overwrite"
        );
    }

    #[test]
    fn test_ffmpeg_args_video_codec_h264() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H264;
        job.encoding_settings.quality = 18;
        job.encoding_settings.encoder_preset = "medium".to_string();

        let args = build_ffmpeg_args_for_test(&job);

        // Check video codec
        let video_codec_idx = args.iter().position(|a| a == "-c:v");
        assert!(video_codec_idx.is_some(), "FFmpeg args should contain -c:v");
        assert_eq!(args[video_codec_idx.unwrap() + 1], "libx264");

        // Check CRF
        let crf_idx = args.iter().position(|a| a == "-crf");
        assert!(crf_idx.is_some(), "H.264 should use CRF");
        assert_eq!(args[crf_idx.unwrap() + 1], "18");

        // Check preset
        let preset_idx = args.iter().position(|a| a == "-preset");
        assert!(preset_idx.is_some(), "H.264 should have encoder preset");
        assert_eq!(args[preset_idx.unwrap() + 1], "medium");
    }

    #[test]
    fn test_ffmpeg_args_video_codec_ffv1_lossless() {
        let mut job = create_test_job("output.avi");
        job.encoding_settings.codec = VideoCodec::FFV1;

        let args = build_ffmpeg_args_for_test(&job);

        // Check video codec
        let video_codec_idx = args.iter().position(|a| a == "-c:v");
        assert!(video_codec_idx.is_some(), "FFmpeg args should contain -c:v");
        assert_eq!(
            args[video_codec_idx.unwrap() + 1], "ffv1",
            "FFV1 codec should be used for lossless encoding"
        );

        // FFV1 should not have CRF or preset
        assert!(!args.contains(&"-crf".to_string()), "FFV1 should not have -crf");
        assert!(!args.contains(&"-preset".to_string()), "FFV1 should not have -preset");
    }

    #[test]
    fn test_ffmpeg_args_nvenc_h264_quality() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H264Nvenc;
        job.encoding_settings.quality = 20;
        job.encoding_settings.encoder_preset = "p4".to_string();

        let args = build_ffmpeg_args_for_test(&job);

        let video_codec_idx = args.iter().position(|a| a == "-c:v");
        assert_eq!(args[video_codec_idx.unwrap() + 1], "h264_nvenc");

        // VBR constant quality mode (not constqp)
        let rc_idx = args.iter().position(|a| a == "-rc");
        assert!(rc_idx.is_some(), "NVENC should use -rc");
        assert_eq!(args[rc_idx.unwrap() + 1], "vbr");

        let cq_idx = args.iter().position(|a| a == "-cq");
        assert!(cq_idx.is_some(), "NVENC should use -cq");
        assert_eq!(args[cq_idx.unwrap() + 1], "20");

        // No bitrate ceiling
        let bv_idx = args.iter().position(|a| a == "-b:v");
        assert!(bv_idx.is_some(), "NVENC should use -b:v 0");
        assert_eq!(args[bv_idx.unwrap() + 1], "0");

        let preset_idx = args.iter().position(|a| a == "-preset");
        assert!(preset_idx.is_some(), "NVENC should have -preset");
        assert_eq!(args[preset_idx.unwrap() + 1], "p4");

        // HQ tuning and quality options
        assert!(args.contains(&"-tune".to_string()), "NVENC should have -tune");
        assert!(args.contains(&"hq".to_string()), "NVENC should use -tune hq");
        assert!(args.contains(&"-multipass".to_string()), "NVENC should have -multipass");
        assert!(args.contains(&"-spatial-aq".to_string()), "NVENC should have -spatial-aq");
        assert!(args.contains(&"-b_ref_mode".to_string()), "NVENC should have -b_ref_mode");

        // H.264 should have high profile
        assert!(args.contains(&"-profile:v".to_string()), "NVENC H.264 should have -profile:v");
        assert!(args.contains(&"high".to_string()), "NVENC H.264 should use high profile");

        // Should NOT have -crf
        assert!(!args.contains(&"-crf".to_string()), "NVENC should not use -crf");
    }

    #[test]
    fn test_ffmpeg_args_nvenc_hevc_no_profile() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H265Nvenc;
        job.encoding_settings.quality = 24;
        job.encoding_settings.encoder_preset = "p7".to_string();

        let args = build_ffmpeg_args_for_test(&job);

        let video_codec_idx = args.iter().position(|a| a == "-c:v");
        assert_eq!(args[video_codec_idx.unwrap() + 1], "hevc_nvenc");

        // HEVC NVENC should NOT have -profile:v high (that's H.264-specific)
        assert!(!args.contains(&"-profile:v".to_string()), "NVENC HEVC should not have -profile:v");

        // Should still have VBR quality mode
        let rc_idx = args.iter().position(|a| a == "-rc");
        assert_eq!(args[rc_idx.unwrap() + 1], "vbr");
    }

    #[test]
    fn test_ffmpeg_args_qsv_quality() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H264Qsv;
        job.encoding_settings.quality = 22;
        job.encoding_settings.encoder_preset = "medium".to_string();

        let args = build_ffmpeg_args_for_test(&job);

        let video_codec_idx = args.iter().position(|a| a == "-c:v");
        assert_eq!(args[video_codec_idx.unwrap() + 1], "h264_qsv");

        let gq_idx = args.iter().position(|a| a == "-global_quality");
        assert!(gq_idx.is_some(), "QSV should use -global_quality");
        assert_eq!(args[gq_idx.unwrap() + 1], "22");

        assert!(!args.contains(&"-crf".to_string()), "QSV should not use -crf");
    }

    #[test]
    fn test_ffmpeg_args_videotoolbox_quality() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H264Videotoolbox;
        job.encoding_settings.quality = 18;

        let args = build_ffmpeg_args_for_test(&job);

        let video_codec_idx = args.iter().position(|a| a == "-c:v");
        assert_eq!(args[video_codec_idx.unwrap() + 1], "h264_videotoolbox");

        let qv_idx = args.iter().position(|a| a == "-q:v");
        assert!(qv_idx.is_some(), "VideoToolbox should use -q:v");

        // CRF 18 -> (51-18)*100/51 = 64.7 -> 65
        let qv_value: i32 = args[qv_idx.unwrap() + 1].parse().unwrap();
        assert!(qv_value > 0 && qv_value <= 100, "VideoToolbox q:v should be 1-100, got {}", qv_value);

        assert!(!args.contains(&"-crf".to_string()), "VideoToolbox should not use -crf");
        assert!(!args.contains(&"-preset".to_string()), "VideoToolbox should not use -preset");
    }

    #[test]
    fn test_ffmpeg_args_amf_quality() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H264Amf;
        job.encoding_settings.quality = 20;
        job.encoding_settings.encoder_preset = "balanced".to_string();

        let args = build_ffmpeg_args_for_test(&job);

        let video_codec_idx = args.iter().position(|a| a == "-c:v");
        assert_eq!(args[video_codec_idx.unwrap() + 1], "h264_amf");

        let rc_idx = args.iter().position(|a| a == "-rc");
        assert!(rc_idx.is_some(), "AMF should use -rc");
        assert_eq!(args[rc_idx.unwrap() + 1], "cqp");

        let qp_i_idx = args.iter().position(|a| a == "-qp_i");
        assert!(qp_i_idx.is_some(), "AMF should use -qp_i");
        assert_eq!(args[qp_i_idx.unwrap() + 1], "20");

        let qp_p_idx = args.iter().position(|a| a == "-qp_p");
        assert!(qp_p_idx.is_some(), "AMF should use -qp_p");
        assert_eq!(args[qp_p_idx.unwrap() + 1], "20");

        let quality_idx = args.iter().position(|a| a == "-quality");
        assert!(quality_idx.is_some(), "AMF should use -quality");
        assert_eq!(args[quality_idx.unwrap() + 1], "balanced");

        assert!(!args.contains(&"-crf".to_string()), "AMF should not use -crf");
    }
}
