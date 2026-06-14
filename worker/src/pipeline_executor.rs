//! Pipeline executor for vspipe | ffmpeg.

use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

#[cfg(unix)]
use std::os::unix::process::ExitStatusExt;

use anyhow::{bail, Context, Result};

/// Format an exit status for error messages, including signal info on Unix.
fn format_exit_status(status: &std::process::ExitStatus) -> String {
    if let Some(code) = status.code() {
        return format!("exit code {}", code);
    }
    #[cfg(unix)]
    {
        if let Some(sig) = status.signal() {
            let name = match sig {
                1 => "SIGHUP",
                2 => "SIGINT",
                6 => "SIGABRT",
                9 => "SIGKILL",
                11 => "SIGSEGV",
                13 => "SIGPIPE",
                15 => "SIGTERM",
                _ => "unknown",
            };
            return format!("signal {} ({})", sig, name);
        }
    }
    "unknown status".to_string()
}

/// True if the process was terminated by SIGPIPE (Unix only; always false
/// elsewhere). A vspipe SIGPIPE means the downstream consumer (ffmpeg) closed
/// the pipe — usually because ffmpeg itself failed, so the ffmpeg error is the
/// one worth reporting.
fn is_sigpipe(status: &std::process::ExitStatus) -> bool {
    #[cfg(unix)]
    {
        status.signal() == Some(13)
    }
    #[cfg(not(unix))]
    {
        let _ = status;
        false
    }
}

use crate::dependency_locator::DependencyLocator;
use crate::models::{AudioMode, ContainerFormat, DeinterlaceMethod, EncoderFamily, LogLevel, ProgressInfo, SubtitleOutput, VideoCodec, VideoJob};
use crate::progress_reporter::ProgressReporter;
use crate::script_generator::{PreviewParams, ScriptGenerator};

/// Executes the ffmpeg (decode) | vspipe | ffmpeg (encode) pipeline.
pub struct PipelineExecutor {
    reporter: ProgressReporter,
    deps: DependencyLocator,
    decoder_process: Option<Child>,
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
            decoder_process: None,
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

        // Determine input pixel format for the decoder
        let pix_fmt = job.input_pixel_format.as_deref().unwrap_or("yuv420p");
        // Declared frame size — must match the dimensions pipe_source uses in
        // the template (see script_generator), so the raw stream stays aligned.
        let width = job.input_width.unwrap_or(720);
        let height = job.input_height.unwrap_or(480);

        // Build decoder FFmpeg arguments
        // Frame trimming is handled here (faster than VapourSynth trimming since FFmpeg
        // can seek using the container index)
        let mut decoder_args: Vec<String> = Vec::new();

        // Seek to start frame if specified (time-based, before -i for fast seek)
        if let Some(start) = job.start_frame {
            if start > 0 {
                let fps = job.input_frame_rate.unwrap_or(29.97);
                let start_time = start as f64 / fps;
                decoder_args.push("-ss".to_string());
                decoder_args.push(format!("{:.6}", start_time));
            }
        }

        decoder_args.extend([
            "-i".to_string(), job.input_path.clone(),
            "-map".to_string(), "0:v:0".to_string(), // only first video stream
            // Force the declared dimensions. Some sources decode to a different
            // size than ffprobe reports (e.g. a clean aperture: 720x576 coded ->
            // 702x576 decoded), which otherwise desyncs the raw frame stream from
            // what pipe_source expects -> garbage output.
            "-s".to_string(), format!("{}x{}", width, height),
            "-f".to_string(), "rawvideo".to_string(),
            "-pix_fmt".to_string(), pix_fmt.to_string(),
            "-v".to_string(), "error".to_string(),
        ]);

        // Limit decoder frame count to match what pipe_source expects.
        // Without this, the decoder can send more frames than TOTAL_FRAMES
        // (e.g. MPEG-2 telecine produces duplicate frames), causing a broken
        // pipe when vspipe closes stdin before the decoder finishes.
        // For trimmed exports, limit to the trimmed range instead.
        if let (Some(start), Some(end)) = (job.start_frame, job.end_frame) {
            let count = end - start + 1;
            if count > 0 {
                decoder_args.push("-frames:v".to_string());
                decoder_args.push(count.to_string());
            }
        } else if let Some(end) = job.end_frame {
            let count = end + 1;
            decoder_args.push("-frames:v".to_string());
            decoder_args.push(count.to_string());
        } else if let Some(total) = job.total_frames {
            decoder_args.push("-frames:v".to_string());
            decoder_args.push(total.to_string());
        }

        decoder_args.push("pipe:1".to_string()); // stdout via FFmpeg pipe protocol

        self.reporter.send_log(
            LogLevel::Debug,
            &format!("Decoder args: {:?}", decoder_args),
        );

        // Start decoder FFmpeg process
        let mut decoder = Command::new(&ffmpeg_path)
            .args(&decoder_args)
            .envs(&env)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("Failed to start decoder ffmpeg: {:?}", ffmpeg_path))?;

        let decoder_stdout = decoder.stdout.take().context("Failed to get decoder stdout")?;
        let decoder_stderr = decoder.stderr.take().context("Failed to get decoder stderr")?;

        // Start vspipe with stdin from decoder
        let mut vspipe = Command::new(&vspipe_path)
            .args(["-c", "y4m", script_path.to_string_lossy().as_ref(), "-"])
            .envs(&env)
            .stdin(decoder_stdout) // pipe decoder output → vspipe stdin
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

        self.decoder_process = Some(decoder);
        self.vspipe_process = Some(vspipe);
        self.ffmpeg_process = Some(ffmpeg);

        // Monitor decoder stderr for errors (in background thread)
        let decoder_reporter = self.reporter.clone();
        let decoder_stderr_thread = thread::spawn(move || {
            let reader = BufReader::new(decoder_stderr);
            let mut last_line = String::new();
            for line in reader.lines().map_while(Result::ok) {
                decoder_reporter.send_log(LogLevel::Debug, &format!("decoder stderr: {}", line));
                last_line = line;
            }
            last_line
        });

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
            && pipeline.deinterlace.fps_divisor.unwrap_or(1) == 1;
        let is_ivtc = pipeline.deinterlace.enabled
            && matches!(pipeline.deinterlace.method,
                DeinterlaceMethod::Ivtc | DeinterlaceMethod::SoftTelecine);
        let ivtc_cycle = pipeline.deinterlace.ivtc_cycle.unwrap_or(5);

        // Capture ffmpeg stderr in a background thread (for error messages).
        // Progress comes from the temp file, not stderr.
        let ffmpeg_reporter = self.reporter.clone();
        let ffmpeg_stderr_thread = thread::spawn(move || {
            let reader = BufReader::new(ffmpeg_stderr);
            // Keep the last few non-empty lines so a failed ffmpeg can report a
            // useful error (e.g. "Unknown encoder 'h264_qsv'"), not just its
            // final — often blank — stderr line.
            let mut tail: std::collections::VecDeque<String> = std::collections::VecDeque::new();
            for line in reader.lines().map_while(Result::ok) {
                ffmpeg_reporter.send_log(LogLevel::Debug, &format!("ffmpeg stderr: {}", line));
                if !line.trim().is_empty() {
                    tail.push_back(line);
                    if tail.len() > 12 {
                        tail.pop_front();
                    }
                }
            }
            tail.into_iter().collect::<Vec<_>>().join("\n")
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
        let mut max_effective_total: i32 = 0;

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

                    // Prevent the total from ever decreasing (avoids progress bar jumping backward)
                    if effective_total > max_effective_total {
                        max_effective_total = effective_total;
                    }
                    effective_total = max_effective_total;

                    // Safety clamp: if current_frame exceeds total, metadata was wrong
                    if current_frame > effective_total {
                        effective_total = current_frame;
                        max_effective_total = current_frame;
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
        let decoder_status = self
            .decoder_process
            .as_mut()
            .map(|p| p.wait())
            .transpose()
            .context("Failed to wait for decoder ffmpeg")?;

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
        let _ = decoder_stderr_thread.join();
        let _ = vspipe_thread.join();
        let ffmpeg_stderr_tail = ffmpeg_stderr_thread.join().unwrap_or_default();

        // Clean up progress file
        let _ = fs::remove_file(&progress_file);

        // Check exit codes.
        //
        // ffmpeg is checked FIRST on purpose: when the encoder ffmpeg fails
        // (e.g. an unavailable hardware encoder), vspipe dies with SIGPIPE as a
        // *symptom* of the closed pipe. Reporting ffmpeg's error — with its
        // stderr tail — surfaces the real cause instead of the misleading
        // "vspipe exited with signal 13 (SIGPIPE)".
        let ffmpeg_ok = if let Some(status) = ffmpeg_status {
            let code = status.code().unwrap_or(-1);
            if code != 0 && code != 130 && code != 141 {
                let tail = ffmpeg_stderr_tail.trim();
                if tail.is_empty() {
                    bail!("ffmpeg exited with {}", format_exit_status(&status));
                }
                bail!("ffmpeg exited with {}:\n{}", format_exit_status(&status), tail);
            }
            true
        } else {
            false
        };

        // vspipe: a SIGPIPE here means ffmpeg closed the pipe early. If ffmpeg
        // failed we've already reported the real cause above; if ffmpeg was fine
        // (e.g. IVTC VDecimate finishing early) it's harmless. Only surface a
        // genuine vspipe failure — a real exit code, or a non-SIGPIPE signal.
        if let Some(status) = vspipe_status {
            let ok = matches!(status.code(), Some(0) | Some(130) | Some(141));
            if !ok && !is_sigpipe(&status) {
                bail!("vspipe exited with {}", format_exit_status(&status));
            }
        }

        // Decoder may exit with broken pipe (141=SIGPIPE on Linux, 224=EPIPE on
        // macOS) when vspipe finishes reading before the decoder sends all frames
        // (e.g. IVTC VDecimate reads fewer frames than available). Harmless.
        if let Some(status) = decoder_status {
            let code = status.code().unwrap_or(-1);
            if code != 0 && code != 130 && code != 141 && code != 224 {
                bail!("Decoder ffmpeg exited with {}", format_exit_status(&status));
            }
        }

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

    /// Probe the input file's subtitle stream codec names in subtitle-relative
    /// order (so index N corresponds to the `s:N` stream specifier).
    /// Returns None if ffprobe is unavailable or fails; Some(empty) if there are
    /// no subtitle streams.
    fn probe_subtitle_codecs(&self, input_path: &str) -> Option<Vec<String>> {
        let ffprobe_path = self.deps.ffprobe_path().ok()?;
        let env = self.deps.build_environment();

        let output = Command::new(&ffprobe_path)
            .args([
                "-v", "quiet",
                "-select_streams", "s",
                "-show_entries", "stream=codec_name",
                "-of", "csv=p=0",
                input_path,
            ])
            .envs(&env)
            .output()
            .ok()?;

        if !output.status.success() {
            return None;
        }

        Some(
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect(),
        )
    }

    /// Whether a subtitle codec is text-based and can therefore be transcoded to
    /// mov_text for MP4/MOV output. Image-based subtitles (hdmv_pgs_subtitle,
    /// dvd_subtitle, dvb_subtitle, xsub) cannot and are excluded. Uses an
    /// allowlist so unknown codecs are excluded (skipped) rather than risking a
    /// hard encode failure.
    fn is_text_subtitle(codec_name: &str) -> bool {
        matches!(
            codec_name,
            "subrip"
                | "srt"
                | "ass"
                | "ssa"
                | "mov_text"
                | "text"
                | "webvtt"
                | "subviewer"
                | "subviewer1"
                | "microdvd"
                | "stl"
        )
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
        // When trimming, seek the audio input to the same start point so ffmpeg
        // doesn't read the entire audio track (which hangs for small segments of
        // large files).
        if let Some(start) = job.start_frame {
            if start > 0 {
                let fps = job.input_frame_rate.unwrap_or(29.97);
                let start_time = start as f64 / fps;
                args.extend(["-ss".to_string(), format!("{:.6}", start_time)]);
            }
        }
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
                // mov_text only holds text subtitles. Image-based subs (PGS/VobSub
                // from DVD/Blu-ray rips) cannot be transcoded to mov_text — ffmpeg
                // does NOT skip them, it aborts the whole encode with
                // "Subtitle encoding currently only possible from text to text..."
                // (exit -22). So probe the source and map only text-based streams.
                if let Some(codecs) = self.probe_subtitle_codecs(&job.input_path) {
                    let mut mapped_any = false;
                    for (rel_idx, codec) in codecs.iter().enumerate() {
                        if Self::is_text_subtitle(codec) {
                            args.extend(["-map".to_string(), format!("1:s:{}", rel_idx)]);
                            mapped_any = true;
                        }
                    }
                    if mapped_any {
                        args.extend(["-c:s".to_string(), "mov_text".to_string()]);
                    }
                }
                // If probing fails, map no subtitles — a missing subtitle track must
                // never fail the encode.
            }
            _ => {} // AVI and others: skip subtitle mapping
        }

        // Video codec
        args.extend(["-c:v".to_string(), settings.codec.ffmpeg_codec().to_string()]);

        // Encoder-family-specific quality and preset args
        Self::build_encoder_quality_args(&mut args, job);

        // Force a compatible output pixel format for codecs that can't accept the
        // pipeline's native format (e.g. classic HuffYUV requires yuv422p).
        if let Some(pix_fmt) = settings.codec.forced_pix_fmt() {
            args.extend(["-pix_fmt".to_string(), pix_fmt.to_string()]);
        }

        // MP4/MOV container fixups. QuickTime and other Apple players reject HEVC
        // with the default `hev1` sample-entry; force `hvc1` so the output is
        // playable. Also move the moov atom to the front (+faststart) for better
        // playback/seeking. Both are no-ops for MKV/AVI.
        if matches!(settings.container, ContainerFormat::Mp4 | ContainerFormat::Mov) {
            if settings.codec.is_h265() {
                args.extend(["-tag:v".to_string(), "hvc1".to_string()]);
            }
            args.extend(["-movflags".to_string(), "+faststart".to_string()]);
        }

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

        // When trimming, stop when the shortest stream (the trimmed video) ends.
        // Without this, ffmpeg reads the full audio track even if only a small
        // video segment was exported.
        let is_trimmed = job.start_frame.is_some() || job.end_frame.is_some();
        if is_trimmed {
            args.push("-shortest".to_string());
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

    /// Best-effort average bitrate (kbps) for Intel-Mac VideoToolbox, which has
    /// no constant-quality (-q:v) mode. Maps the CRF-like quality (0-51, lower =
    /// better) to bits-per-pixel, then bitrate = width*height*fps*bpp. HEVC
    /// targets ~60% of H.264's bitrate for comparable quality. Floored at 500 kbps.
    #[cfg(not(target_arch = "aarch64"))]
    fn videotoolbox_bitrate_kbps(job: &VideoJob) -> u32 {
        let settings = &job.encoding_settings;
        let w = job.input_width.unwrap_or(720).max(1) as f64;
        let h = job.input_height.unwrap_or(480).max(1) as f64;
        let fps = job.input_frame_rate.unwrap_or(29.97).max(1.0);
        let q = settings.quality.clamp(0, 51) as f64;
        let mut bpp = 0.20 - (0.18 * q / 51.0); // q=0 -> 0.20, q=51 -> 0.02
        if matches!(settings.codec, VideoCodec::H265Videotoolbox) {
            bpp *= 0.6;
        }
        let bps = w * h * fps * bpp;
        ((bps / 1000.0).round() as u32).max(500)
    }

    /// Build encoder-family-specific quality and preset arguments.
    fn build_encoder_quality_args(args: &mut Vec<String>, job: &VideoJob) {
        let settings = &job.encoding_settings;
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
                    // VideoToolbox's constant-quality mode (-q:v) is only
                    // supported on Apple Silicon. On Intel Macs the encoder has
                    // no qscale and fails to open with -q:v ("qscale not
                    // available for encoder. Use -b:v bitrate instead"), so use
                    // an average bitrate there. target_arch is per-slice in the
                    // universal binary (x86_64 == Intel, aarch64 == Apple Silicon).
                    #[cfg(target_arch = "aarch64")]
                    {
                        // CRF 0-51 -> q:v 100-1 (inverted scale)
                        let vt_quality =
                            ((51 - settings.quality) as f64 * 100.0 / 51.0).round().max(1.0) as i32;
                        args.extend(["-q:v".to_string(), vt_quality.to_string()]);
                    }
                    #[cfg(not(target_arch = "aarch64"))]
                    {
                        // Native Intel-VideoToolbox control: an explicit target
                        // bitrate set in the UI. Fall back to the resolution-derived
                        // estimate only when the UI didn't provide one.
                        let kbps = settings
                            .video_bitrate_kbps
                            .filter(|&k| k > 0)
                            .unwrap_or_else(|| Self::videotoolbox_bitrate_kbps(job));
                        args.extend(["-b:v".to_string(), format!("{}k", kbps)]);
                    }
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
    /// Decodes frames around the target time with FFmpeg, pipes raw data through
    /// VapourSynth for filtering, then encodes the middle frame as PNG.
    pub fn generate_preview(&self, job: &VideoJob, time_seconds: f64) -> Result<()> {
        use std::io::Write;

        let ffmpeg_path = self.deps.ffmpeg_path()?;
        let vspipe_path = self.deps.vspipe_path()?;
        let env = self.deps.build_environment();

        // Number of frames to extract (need enough for QTGMC temporal processing)
        let num_frames = 11; // Decode 11 frames, VapourSynth uses middle one
        let frame_rate = job.input_frame_rate.unwrap_or(29.97);
        let frame_duration = 1.0 / frame_rate;
        let pix_fmt = job.input_pixel_format.as_deref().unwrap_or("yuv420p");
        let width = job.input_width.unwrap_or(720);
        let height = job.input_height.unwrap_or(480);

        // Guard against zero dimensions. A failed/missing analysis stores 0x0,
        // which otherwise reaches VapourSynth as a cryptic "BlankClip: invalid
        // width". Surface an actionable error instead. (0 only occurs for an
        // explicit Some(0); None already falls back to the defaults above.)
        if width == 0 || height == 0 {
            bail!(
                "Invalid video dimensions ({}x{}). The file may not have been analyzed correctly \u{2014} try removing it from the queue and re-adding it.",
                width, height
            );
        }

        // Calculate start time (go back half the frames for temporal context)
        let start_time = (time_seconds - (num_frames as f64 / 2.0) * frame_duration).max(0.0);

        eprintln!("Decoding {} frames starting at {:.3}s ({}x{} {})", num_frames, start_time, width, height, pix_fmt);

        // Determine field order for interlaced content
        let field_based = if job.qtgmc_parameters.tff == Some(true) {
            2 // TFF
        } else {
            1 // BFF
        };

        // FPS as rational
        let script_generator = ScriptGenerator::new()?;
        let (fps_num, fps_den) = script_generator.frame_rate_to_rational(frame_rate);

        let preview_params = PreviewParams {
            width,
            height,
            pix_fmt: pix_fmt.to_string(),
            num_frames,
            fps_num,
            fps_den,
            field_based,
        };

        let script_path = script_generator.generate_preview(job, &preview_params)?;

        eprintln!("Generated preview script: {:?}", script_path);

        // Decode frames to a temp raw file (avoids rawvideo muxer pipe issues on Windows)
        // For 11 frames this is tiny (~9MB) and near-instant with keyframe seeking
        let temp_dir = std::env::temp_dir().join(format!("vapourbox_preview_{}", job.id));
        fs::create_dir_all(&temp_dir)
            .with_context(|| format!("Failed to create temp dir: {:?}", temp_dir))?;
        let raw_path = temp_dir.join("frames.raw");

        let extract_result = Command::new(&ffmpeg_path)
            .args([
                "-ss", &format!("{:.6}", start_time),
                "-i", &job.input_path,
                "-map", "0:v:0",
                "-frames:v", &num_frames.to_string(),
                // Force the declared dimensions. Some sources decode to a
                // different size than ffprobe reports (e.g. a clean aperture:
                // 720x576 coded -> 702x576 decoded), which otherwise desyncs the
                // raw frame stream from what pipe_source expects -> garbage.
                "-s", &format!("{}x{}", width, height),
                "-f", "rawvideo",
                "-pix_fmt", pix_fmt,
                "-v", "error",
                "-y",
                raw_path.to_string_lossy().as_ref(),
            ])
            .envs(&env)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .with_context(|| "Failed to run ffmpeg for frame extraction")?;

        if !extract_result.status.success() {
            let stderr = String::from_utf8_lossy(&extract_result.stderr);
            let _ = fs::remove_dir_all(&temp_dir);
            bail!("Failed to decode frames: {}", stderr);
        }

        if !raw_path.exists() {
            let _ = fs::remove_dir_all(&temp_dir);
            bail!("Failed to create raw frame file");
        }

        // Pipe raw frames from file to vspipe stdin
        let raw_file = fs::File::open(&raw_path)
            .with_context(|| format!("Failed to open raw file: {:?}", raw_path))?;

        // Start vspipe — reads raw frames from file via stdin, outputs Y4M
        let mut vspipe = Command::new(&vspipe_path)
            .args([
                "-c", "y4m",
                script_path.to_string_lossy().as_ref(),
                "-",
            ])
            .envs(&env)
            .stdin(raw_file)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("Failed to start vspipe: {:?}", vspipe_path))?;

        let vspipe_stdout = vspipe.stdout.take().context("Failed to get vspipe stdout")?;
        let vspipe_stderr = vspipe.stderr.take();

        // Start encoder FFmpeg — converts Y4M to PNG
        let ffmpeg_enc = Command::new(&ffmpeg_path)
            .args([
                "-f", "yuv4mpegpipe",
                "-i", "pipe:0",
                "-vframes", "1",
                "-vf", "scale=in_range=tv:out_range=pc",
                "-f", "image2pipe",
                "-vcodec", "png",
                "pipe:1",
            ])
            .envs(&env)
            .stdin(vspipe_stdout)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("Failed to start ffmpeg encoder: {:?}", ffmpeg_path))?;

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

        // Wait for processes
        let vspipe_status = vspipe.wait().context("Failed to wait for vspipe")?;
        let output = ffmpeg_enc.wait_with_output().context("Failed to wait for ffmpeg")?;

        // Clean up temp files
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::remove_file(&script_path);

        // Check for errors
        if !vspipe_status.success() {
            let errors = stderr_thread.map(|t| t.join().ok()).flatten().unwrap_or_default();
            if !errors.is_empty() {
                bail!("vspipe failed: {}", errors.join("\n"));
            }
            bail!("vspipe exited with {}", format_exit_status(&vspipe_status));
        }

        if !output.status.success() {
            bail!("ffmpeg encoder exited with {}", format_exit_status(&output.status));
        }

        // Write PNG to stdout
        std::io::stdout().write_all(&output.stdout)?;
        std::io::stdout().flush()?;

        Ok(())
    }

    /// Terminate all processes.
    fn terminate(&mut self) {
        if let Some(ref mut decoder) = self.decoder_process {
            let _ = decoder.kill();
        }
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
        PipelineExecutor::build_encoder_quality_args(&mut args, job);

        // Force a compatible output pixel format (e.g. HuffYUV requires yuv422p)
        if let Some(pix_fmt) = settings.codec.forced_pix_fmt() {
            args.extend(["-pix_fmt".to_string(), pix_fmt.to_string()]);
        }

        // MP4/MOV container fixups (mirrors build_ffmpeg_args): hvc1 tag for HEVC
        // so Apple players accept it, plus +faststart.
        if matches!(settings.container, ContainerFormat::Mp4 | ContainerFormat::Mov) {
            if settings.codec.is_h265() {
                args.extend(["-tag:v".to_string(), "hvc1".to_string()]);
            }
            args.extend(["-movflags".to_string(), "+faststart".to_string()]);
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
            processing_pipeline: None,
            encoding_settings: EncodingSettings::default(),
            detected_field_order: None,
            total_frames: None,
            input_frame_rate: None,
            start_frame: None,
            end_frame: None,
            subtitle_settings: None,
            subtitle_only: false,
            input_sar: None,
            input_width: None,
            input_height: None,
            input_pixel_format: None,
        }
    }

    #[test]
    fn test_is_text_subtitle_excludes_image_based() {
        // Image-based subtitles (DVD/Blu-ray rips) must be excluded — these are
        // what made ffmpeg abort with exit -22 on MOV/MP4 output (issue #6).
        for codec in ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"] {
            assert!(
                !PipelineExecutor::is_text_subtitle(codec),
                "{codec} is image-based and must not be mapped to mov_text"
            );
        }

        // Text-based subtitles can be transcoded to mov_text.
        for codec in ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt"] {
            assert!(
                PipelineExecutor::is_text_subtitle(codec),
                "{codec} is text-based and should be mapped to mov_text"
            );
        }

        // Unknown codecs are excluded (allowlist) to avoid a hard encode failure.
        assert!(!PipelineExecutor::is_text_subtitle("some_future_codec"));
    }

    /// True if `args` contains the consecutive pair [flag, value].
    fn has_arg_pair(args: &[String], flag: &str, value: &str) -> bool {
        args.windows(2).any(|w| w[0] == flag && w[1] == value)
    }

    #[test]
    fn test_hevc_mp4_tagged_hvc1_for_quicktime() {
        // Issue #19: HEVC in MP4/MOV must use the hvc1 sample-entry tag or Apple
        // players (QuickTime) reject the file.
        let mut job = create_test_job("out.mp4");
        job.encoding_settings.codec = VideoCodec::H265;
        job.encoding_settings.container = ContainerFormat::Mp4;
        let args = build_ffmpeg_args_for_test(&job);
        assert!(has_arg_pair(&args, "-tag:v", "hvc1"), "HEVC/MP4 must set -tag:v hvc1: {args:?}");
        assert!(has_arg_pair(&args, "-movflags", "+faststart"), "MP4 should set +faststart");
    }

    #[test]
    fn test_hevc_mov_tagged_hvc1() {
        let mut job = create_test_job("out.mov");
        job.encoding_settings.codec = VideoCodec::H265Videotoolbox;
        job.encoding_settings.container = ContainerFormat::Mov;
        let args = build_ffmpeg_args_for_test(&job);
        assert!(has_arg_pair(&args, "-tag:v", "hvc1"), "HEVC/MOV must set -tag:v hvc1");
    }

    #[test]
    fn test_h264_mp4_not_tagged_hvc1() {
        let mut job = create_test_job("out.mp4");
        job.encoding_settings.codec = VideoCodec::H264;
        job.encoding_settings.container = ContainerFormat::Mp4;
        let args = build_ffmpeg_args_for_test(&job);
        assert!(!has_arg_pair(&args, "-tag:v", "hvc1"), "H.264 must not be tagged hvc1");
        assert!(has_arg_pair(&args, "-movflags", "+faststart"));
    }

    #[test]
    fn test_hevc_mkv_no_hvc1_or_faststart() {
        let mut job = create_test_job("out.mkv");
        job.encoding_settings.codec = VideoCodec::H265;
        job.encoding_settings.container = ContainerFormat::Mkv;
        let args = build_ffmpeg_args_for_test(&job);
        assert!(!has_arg_pair(&args, "-tag:v", "hvc1"), "MKV doesn't use hvc1");
        assert!(!has_arg_pair(&args, "-movflags", "+faststart"), "faststart is MP4/MOV-only");
    }

    // Intel-only: VideoToolbox uses an explicit target bitrate (no constant-quality
    // mode). On Apple Silicon the encoder uses -q:v, so this assertion is x86_64-only.
    #[cfg(not(target_arch = "aarch64"))]
    #[test]
    fn test_videotoolbox_intel_uses_explicit_bitrate() {
        let mut job = create_test_job("out.mp4");
        job.encoding_settings.codec = VideoCodec::H265Videotoolbox;
        job.encoding_settings.container = ContainerFormat::Mp4;
        job.encoding_settings.video_bitrate_kbps = Some(20000);
        let args = build_ffmpeg_args_for_test(&job);
        assert!(has_arg_pair(&args, "-b:v", "20000k"), "Intel VT must use the chosen bitrate: {args:?}");
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
    fn test_ffmpeg_args_video_codec_huffyuv_forces_yuv422p() {
        let mut job = create_test_job("output.avi");
        job.encoding_settings.codec = VideoCodec::Huffyuv;

        let args = build_ffmpeg_args_for_test(&job);

        let video_codec_idx = args.iter().position(|a| a == "-c:v").unwrap();
        assert_eq!(args[video_codec_idx + 1], "huffyuv");

        // Classic HuffYUV only supports yuv422p, so the pixel format must be forced
        let pix_fmt_idx = args.iter().position(|a| a == "-pix_fmt");
        assert!(pix_fmt_idx.is_some(), "HuffYUV should force -pix_fmt");
        assert_eq!(args[pix_fmt_idx.unwrap() + 1], "yuv422p");

        // Lossless: no CRF or preset
        assert!(!args.contains(&"-crf".to_string()), "HuffYUV should not have -crf");
        assert!(!args.contains(&"-preset".to_string()), "HuffYUV should not have -preset");
    }

    #[test]
    fn test_ffmpeg_args_video_codec_ffvhuff_no_forced_pix_fmt() {
        let mut job = create_test_job("output.mkv");
        job.encoding_settings.codec = VideoCodec::Ffvhuff;

        let args = build_ffmpeg_args_for_test(&job);

        let video_codec_idx = args.iter().position(|a| a == "-c:v").unwrap();
        assert_eq!(args[video_codec_idx + 1], "ffvhuff");

        // ffvhuff accepts yuv420p natively — no forced pixel format
        assert!(!args.contains(&"-pix_fmt".to_string()), "ffvhuff should not force -pix_fmt");
        assert!(!args.contains(&"-crf".to_string()), "ffvhuff should not have -crf");
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

        // VideoToolbox quality control is arch-specific: constant-quality (-q:v)
        // on Apple Silicon, average bitrate (-b:v) on Intel (which has no qscale).
        #[cfg(target_arch = "aarch64")]
        {
            let qv_idx = args.iter().position(|a| a == "-q:v");
            assert!(qv_idx.is_some(), "Apple Silicon VideoToolbox should use -q:v");
            // CRF 18 -> (51-18)*100/51 = 64.7 -> 65
            let qv_value: i32 = args[qv_idx.unwrap() + 1].parse().unwrap();
            assert!(qv_value > 0 && qv_value <= 100, "VideoToolbox q:v should be 1-100, got {}", qv_value);
        }
        #[cfg(not(target_arch = "aarch64"))]
        {
            assert!(!args.contains(&"-q:v".to_string()),
                "Intel VideoToolbox must not use -q:v (qscale unsupported)");
            let bv_idx = args.iter().position(|a| a == "-b:v");
            assert!(bv_idx.is_some(), "Intel VideoToolbox should use -b:v");
            assert!(args[bv_idx.unwrap() + 1].ends_with('k'),
                "Intel VideoToolbox -b:v should be a kbps value, got {}", args[bv_idx.unwrap() + 1]);
        }

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
