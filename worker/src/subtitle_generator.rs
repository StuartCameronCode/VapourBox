//! Subtitle generation using whisper.cpp CLI.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use anyhow::{bail, Context, Result};

use crate::dependency_locator::DependencyLocator;
use crate::models::{LogLevel, ProgressInfo, SubtitleOutput, SubtitleSettings};
use crate::progress_reporter::ProgressReporter;

/// Generates subtitles from video audio using whisper.cpp.
pub struct SubtitleGenerator {
    reporter: ProgressReporter,
    deps: DependencyLocator,
}

impl SubtitleGenerator {
    pub fn new(reporter: ProgressReporter, deps: DependencyLocator) -> Self {
        Self { reporter, deps }
    }

    /// Generate subtitles for the given video file.
    ///
    /// When `output_path` is provided (subtitle-only mode), embedding creates
    /// a new file at that path instead of modifying the source video.
    /// The SRT file is also placed next to the output path.
    ///
    /// Returns the path to the generated .srt file, if any.
    pub fn generate<F>(
        &self,
        video_path: &str,
        settings: &SubtitleSettings,
        on_cancel: F,
        output_path: Option<&str>,
    ) -> Result<Option<PathBuf>>
    where
        F: Fn() -> bool,
    {
        let video = Path::new(video_path);
        if !video.exists() {
            bail!("Video file not found: {}", video_path);
        }

        // Check if video has an audio track
        if !self.has_audio_track(video_path)? {
            self.reporter.send_log(
                LogLevel::Warning,
                "No audio track found — skipping subtitle generation",
            );
            return Ok(None);
        }

        let whisper_path = self.deps.whisper_path()?;
        let model_path = self.deps.whisper_model_path(&settings.model)?;

        // 1. Extract audio to 16kHz mono WAV
        self.reporter
            .send_log(LogLevel::Info, "Extracting audio for subtitle generation...");
        let temp_wav = self.extract_audio(video_path, &on_cancel)?;
        if on_cancel() {
            let _ = std::fs::remove_file(&temp_wav);
            return Ok(None);
        }

        // Determine the target path for SRT and embed operations.
        // In subtitle-only mode (output_path provided), place outputs relative
        // to the output path to avoid modifying the user's source video.
        let target_video = output_path.unwrap_or(video_path);
        let target = Path::new(target_video);

        // 2. Run whisper-cli — SRT is written next to the target video
        self.reporter
            .send_log(LogLevel::Info, "Running Whisper speech recognition...");
        let srt_path = self.run_whisper(
            &whisper_path,
            &model_path,
            &temp_wav,
            &target.with_extension("srt"),
            settings,
            &on_cancel,
        );

        // 3. Clean up temp WAV
        let _ = std::fs::remove_file(&temp_wav);

        let srt_path = srt_path?;
        if on_cancel() {
            let _ = std::fs::remove_file(&srt_path);
            return Ok(None);
        }

        // Check if SRT is empty
        let srt_content =
            std::fs::read_to_string(&srt_path).unwrap_or_default();
        if srt_content.trim().is_empty() {
            self.reporter.send_log(
                LogLevel::Warning,
                "Whisper produced empty transcription — no subtitles generated",
            );
            let _ = std::fs::remove_file(&srt_path);
            return Ok(None);
        }

        // 4. Handle output mode
        match settings.output {
            // Whisper runs AFTER the encode, so its output cannot be burnt in
            // on this pass — the encoder has already finished. Burn-in is
            // therefore only offered for a user-supplied file, handled in
            // pipeline_executor; here these modes fall back to the sidecar so
            // the transcription is not thrown away.
            SubtitleOutput::BurnIn | SubtitleOutput::BurnInAndSrt => {
                self.reporter.send_log(
                    LogLevel::Info,
                    &format!(
                        "Subtitles saved to: {} (burn-in applies to a supplied \
                         subtitle file; transcription runs after the encode)",
                        srt_path.display()
                    ),
                );
                Ok(Some(srt_path))
            }
            SubtitleOutput::SrtFile => {
                self.reporter.send_log(
                    LogLevel::Info,
                    &format!("Subtitles saved to: {}", srt_path.display()),
                );
                Ok(Some(srt_path))
            }
            SubtitleOutput::Embed => {
                // In subtitle-only mode, remux input → output with subtitles.
                // In post-encode mode, modify the output file in place.
                self.embed_subtitles(video_path, &srt_path, target, &on_cancel)?;
                let _ = std::fs::remove_file(&srt_path);
                Ok(None)
            }
            SubtitleOutput::Both => {
                self.embed_subtitles(video_path, &srt_path, target, &on_cancel)?;
                self.reporter.send_log(
                    LogLevel::Info,
                    &format!("Subtitles saved to: {}", srt_path.display()),
                );
                Ok(Some(srt_path))
            }
        }
    }

    /// Check if video has an audio track using ffprobe.
    /// Transcribe to an SRT and stop there — no muxing, no output-mode
    /// handling.
    ///
    /// This is what runs *before* the encode, so burn-in has something to draw.
    /// `window` is the trim applied to the encode, in seconds.
    pub fn transcribe<F>(
        &self,
        video_path: &str,
        settings: &SubtitleSettings,
        window: Option<(f64, Option<f64>)>,
        srt_path: &Path,
        on_cancel: F,
    ) -> Result<Option<PathBuf>>
    where
        F: Fn() -> bool,
    {
        if !Path::new(video_path).exists() {
            bail!("Video file not found: {}", video_path);
        }
        if !self.has_audio_track(video_path)? {
            self.reporter.send_log(
                LogLevel::Warning,
                "No audio track found — skipping subtitle generation",
            );
            return Ok(None);
        }

        let whisper_path = self.deps.whisper_path()?;
        let model_path = self.deps.whisper_model_path(&settings.model)?;

        self.reporter
            .send_log(LogLevel::Info, "Extracting audio for subtitle generation...");
        let temp_wav = self.extract_audio_range(video_path, window, &on_cancel)?;
        if on_cancel() {
            let _ = std::fs::remove_file(&temp_wav);
            return Ok(None);
        }

        let result = self.run_whisper(
            &whisper_path,
            &model_path,
            &temp_wav,
            srt_path,
            settings,
            &on_cancel,
        );
        let _ = std::fs::remove_file(&temp_wav);
        result?;

        if !srt_path.exists() {
            bail!("whisper produced no subtitle file at {}", srt_path.display());
        }
        Ok(Some(srt_path.to_path_buf()))
    }

    /// Multiplex an existing SRT into a finished video as a subtitle track.
    pub fn mux<F>(&self, video: &Path, srt_path: &Path, on_cancel: F) -> Result<()>
    where
        F: Fn() -> bool,
    {
        self.embed_subtitles(&video.to_string_lossy(), srt_path, video, &on_cancel)
    }

    fn has_audio_track(&self, video_path: &str) -> Result<bool> {
        let ffprobe_path = self.deps.ffprobe_path()?;
        let env = self.deps.build_environment();

        let output = Command::new(&ffprobe_path)
            .args([
                "-v",
                "quiet",
                "-select_streams",
                "a",
                "-show_entries",
                "stream=codec_type",
                "-of",
                "csv=p=0",
                video_path,
            ])
            .envs(&env)
            .output()
            .context("Failed to run ffprobe")?;

        Ok(!output.stdout.is_empty())
    }

    /// Probe the source file's comment metadata.
    fn probe_comment(&self, video_path: &str) -> Option<String> {
        let ffprobe_path = self.deps.ffprobe_path().ok()?;
        let env = self.deps.build_environment();

        let output = Command::new(&ffprobe_path)
            .args([
                "-v", "quiet",
                "-show_entries", "format_tags=comment",
                "-of", "csv=p=0",
                video_path,
            ])
            .envs(&env)
            .output()
            .ok()?;

        let comment = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if comment.is_empty() { None } else { Some(comment) }
    }

    /// Extract audio from video to 16kHz mono WAV.
    fn extract_audio<F>(&self, video_path: &str, on_cancel: &F) -> Result<PathBuf>
    where
        F: Fn() -> bool,
    {
        self.extract_audio_range(video_path, None, on_cancel)
    }

    /// Extract 16 kHz mono WAV, optionally only a `(start, duration)` window.
    ///
    /// The window matters when transcribing the *source* rather than the
    /// finished file. The encoder seeks the audio input to the trim point, so
    /// the output's audio starts there — a transcript of the whole source would
    /// be offset by exactly the trimmed-off head, and every cue would land
    /// early. Nothing else in the pipeline retimes audio: IVTC and frame-rate
    /// conversion change the video timeline only, and the audio keeps its
    /// original duration, so trim is the one correction needed.
    fn extract_audio_range<F>(
        &self,
        video_path: &str,
        window: Option<(f64, Option<f64>)>,
        on_cancel: &F,
    ) -> Result<PathBuf>
    where
        F: Fn() -> bool,
    {
        let ffmpeg_path = self.deps.ffmpeg_path()?;
        let env = self.deps.build_environment();

        let video = Path::new(video_path);
        let temp_wav = video.with_extension("whisper.wav");

        let mut args: Vec<String> = Vec::new();
        // Seek before -i so ffmpeg does not decode the discarded head.
        if let Some((start, _)) = window {
            if start > 0.0 {
                args.extend(["-ss".to_string(), format!("{start:.6}")]);
            }
        }
        args.extend(["-i".to_string(), video_path.to_string()]);
        if let Some((_, Some(duration))) = window {
            if duration > 0.0 {
                args.extend(["-t".to_string(), format!("{duration:.6}")]);
            }
        }
        args.extend([
            "-ar".to_string(), "16000".to_string(),
            "-ac".to_string(), "1".to_string(),
            "-vn".to_string(),
            "-y".to_string(),
            temp_wav.to_string_lossy().to_string(),
        ]);

        let mut child = Command::new(&ffmpeg_path)
            .args(&args)
            .envs(&env)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .context("Failed to start ffmpeg for audio extraction")?;

        // Wait with cancellation polling
        loop {
            if on_cancel() {
                let _ = child.kill();
                let _ = std::fs::remove_file(&temp_wav);
                bail!("Cancelled during audio extraction");
            }
            match child.try_wait()? {
                Some(status) => {
                    if !status.success() {
                        bail!("ffmpeg audio extraction failed with exit code: {}", status);
                    }
                    break;
                }
                None => thread::sleep(Duration::from_millis(500)),
            }
        }

        Ok(temp_wav)
    }

    /// Run whisper-cli and produce an SRT file.
    fn run_whisper<F>(
        &self,
        whisper_path: &Path,
        model_path: &Path,
        wav_path: &Path,
        srt_path: &Path,
        settings: &SubtitleSettings,
        on_cancel: &F,
    ) -> Result<PathBuf>
    where
        F: Fn() -> bool,
    {
        let srt_path = srt_path.to_path_buf();

        // whisper-cli appends .srt to -of when --output-srt is used, so the
        // base is the target with its extension stripped.
        let output_base = srt_path.with_extension("");

        let mut args = vec![
            "-m".to_string(),
            model_path.to_string_lossy().to_string(),
            "-f".to_string(),
            wav_path.to_string_lossy().to_string(),
            "--output-srt".to_string(),
            "--print-progress".to_string(),
            "-of".to_string(),
            output_base.to_string_lossy().to_string(),
        ];

        // Add language hint
        if let Some(ref lang) = settings.language {
            if lang != "auto" {
                args.push("-l".to_string());
                args.push(lang.clone());
            }
        }

        let mut child = Command::new(whisper_path)
            .args(&args)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .context("Failed to start whisper-cli")?;

        // Parse stderr for progress updates
        if let Some(stderr) = child.stderr.take() {
            let reporter = self.reporter.clone();
            thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines().map_while(Result::ok) {
                    // whisper.cpp outputs "whisper_full_with_state: progress = XX%"
                    if line.contains("progress =") {
                        if let Some(pct_str) = line.split("progress =").nth(1) {
                            let pct_str = pct_str.trim().trim_end_matches('%').trim();
                            reporter.send_log(
                                LogLevel::Info,
                                &format!("Whisper progress: {}%", pct_str),
                            );
                            if let Ok(pct) = pct_str.parse::<i32>() {
                                reporter.send_progress_phase(
                                    &ProgressInfo::new(pct, 100, 0.0, 0.0),
                                    "subtitles",
                                );
                            }
                        }
                    }
                }
            });
        }

        // Wait with cancellation polling
        loop {
            if on_cancel() {
                let _ = child.kill();
                let _ = std::fs::remove_file(&srt_path);
                bail!("Cancelled during subtitle generation");
            }
            match child.try_wait()? {
                Some(status) => {
                    if !status.success() {
                        bail!("whisper-cli failed with exit code: {}", status);
                    }
                    break;
                }
                None => thread::sleep(Duration::from_millis(500)),
            }
        }

        if !srt_path.exists() {
            bail!("whisper-cli did not produce SRT output at {}", srt_path.display());
        }

        Ok(srt_path)
    }

    /// Embed subtitles into video container via ffmpeg remux.
    ///
    /// `source_video` is the video to read from.
    /// `target_video` is where the result is written. When source == target,
    /// a temp file is used and the original is replaced (post-encode mode).
    /// When they differ (subtitle-only mode), the result is written directly
    /// to the target without modifying the source.
    fn embed_subtitles<F>(
        &self,
        source_video: &str,
        srt_path: &Path,
        target_video: &Path,
        on_cancel: &F,
    ) -> Result<()>
    where
        F: Fn() -> bool,
    {
        let ffmpeg_path = self.deps.ffmpeg_path()?;
        let env = self.deps.build_environment();

        // Determine subtitle codec based on target container
        let extension = target_video
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();

        let sub_codec = match extension.as_str() {
            "mp4" | "mov" | "m4v" => "mov_text",
            "mkv" | "mka" | "webm" => "srt",
            _ => {
                self.reporter.send_log(
                    LogLevel::Warning,
                    &format!(
                        "Container '{}' may not support embedded subtitles — falling back to SRT file",
                        extension
                    ),
                );
                return Ok(());
            }
        };

        self.reporter.send_log(LogLevel::Info, "Embedding subtitles into video...");
        // Signal indeterminate embedding phase (totalFrames=0 means indeterminate)
        self.reporter.send_progress_phase(
            &ProgressInfo::new(0, 0, 0.0, 0.0),
            "embedding",
        );

        let source = Path::new(source_video);
        let in_place = source == target_video;

        // When modifying in place, write to a temp file then rename.
        // When writing to a new file, write directly to the target.
        let output_path = if in_place {
            let orig_ext = target_video.extension().unwrap_or_default().to_string_lossy();
            target_video.with_extension(format!("tmp_sub_embed.{}", orig_ext))
        } else {
            target_video.to_path_buf()
        };
        let output_str = output_path.to_string_lossy().to_string();

        // Build comment metadata, preserving any existing comment from source
        let version = env!("CARGO_PKG_VERSION");
        let existing_comment = self.probe_comment(source_video);
        let comment = match existing_comment {
            Some(ref existing) => format!("VapourBox {} | {}", version, existing),
            None => format!("VapourBox {}", version),
        };
        let comment_arg = format!("comment={}", comment);

        let mut child = Command::new(&ffmpeg_path)
            .args([
                "-i",
                source_video,
                "-i",
                &srt_path.to_string_lossy(),
                "-c",
                "copy",
                "-c:s",
                sub_codec,
                "-metadata",
                &comment_arg,
                "-y",
                &output_str,
            ])
            .envs(&env)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .context("Failed to start ffmpeg for subtitle embedding")?;

        // Wait with cancellation polling, sending periodic heartbeats
        let mut heartbeat_counter = 0u32;
        loop {
            if on_cancel() {
                let _ = child.kill();
                let _ = std::fs::remove_file(&output_path);
                bail!("Cancelled during subtitle embedding");
            }
            match child.try_wait()? {
                Some(status) => {
                    if !status.success() {
                        let _ = std::fs::remove_file(&output_path);
                        bail!("ffmpeg subtitle embedding failed with exit code: {}", status);
                    }
                    break;
                }
                None => {
                    thread::sleep(Duration::from_millis(500));
                    heartbeat_counter += 1;
                    // Send heartbeat every ~2s to keep UI alive
                    if heartbeat_counter % 4 == 0 {
                        self.reporter.send_progress_phase(
                            &ProgressInfo::new(0, 0, 0.0, 0.0),
                            "embedding",
                        );
                    }
                }
            }
        }

        // If in-place, replace original with embedded version
        if in_place {
            std::fs::rename(&output_path, target_video)
                .context("Failed to replace video with subtitle-embedded version")?;
        }

        self.reporter
            .send_log(LogLevel::Info, "Subtitles embedded into video");
        Ok(())
    }
}
