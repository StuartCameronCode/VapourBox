//! Pipeline executor for vspipe | ffmpeg.

use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::unix::process::ExitStatusExt;

use anyhow::{bail, Context, Result};

/// Marker embedded in the error when vspipe skips VapourSynth plugin autoload
/// (a required plugin namespace fails to register). Under heavy parallel CI
/// load this happens intermittently; the worker detects this marker and retries
/// the encode with a fresh vspipe, which re-runs autoload and almost always
/// succeeds. Kept as a stable substring so `main` can match it on the error.
pub const PLUGIN_AUTOLOAD_MARKER: &str = "[plugin-autoload-failed]";

/// `prores_ks` declares `bits_per_mb` with this maximum. Above it ffmpeg
/// rejects the option and the encode dies having written nothing, so a value
/// arriving from a preset or an imported config is clamped rather than passed.
pub const PRORES_MAX_BITS_PER_MB: u32 = 8192;

/// True if a vspipe stderr line is VapourSynth's plugin-autoload-skip signature
/// (e.g. "There is no attribute or namespace named fmtc. Did you mistype a
/// plugin namespace or forget to install a plugin?").
fn is_autoload_skip_line(line: &str) -> bool {
    line.contains("Did you mistype a plugin namespace")
        || line.contains("forget to install a plugin")
}

/// Whether a `progress=end` line belongs to the run currently executing.
///
/// The progress file is named `vb_progress_{job.id}`, and `job.id` is the queue
/// item's id — identical every time that item is re-run. ffmpeg writes
/// `progress=end` as it terminates, so a cancelled run leaves one behind, and
/// the next run's loop polls before its own ffmpeg has opened and truncated the
/// file.
///
/// Believing that line ends the progress loop on its first iteration. The worker
/// then blocks in `decoder.wait()` while the pipeline encodes at full speed
/// behind it: no progress is ever reported and the job never completes, so the
/// app sits on "processing" with a spinner. Four fixes were made in the app for
/// that symptom before the cause was found here.
///
/// A `progress=end` before this run has reported a single frame cannot be ours.
/// The file is also deleted before the pipeline starts; this is the belt to that
/// pair of braces, and the part that can be tested deterministically — the file
/// race depends on how fast ffmpeg opens its output, which is why the bug showed
/// up against a network share and never locally.
fn progress_end_is_ours(current_frame: i32) -> bool {
    current_frame > 0
}

/// Format an exit status for error messages, including signal info on Unix and
/// the NTSTATUS meaning of a Windows crash code.
pub(crate) fn format_exit_status(status: &std::process::ExitStatus) -> String {
    if let Some(code) = status.code() {
        if let Some(explanation) = windows_crash_explanation(code) {
            return format!("exit code {} — {}", code, explanation);
        }
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

/// Plain-language meaning of a Windows NTSTATUS exit code, if it is one.
///
/// A native crash inside a plugin kills vspipe before it writes the Y4M header,
/// so the *encoder* ffmpeg is what reports a failure ("Header too large") and
/// the only trace of the real cause is this number. Reported as a bare
/// `exit code -1073741795`, it names nothing at all: issue #82 took a round trip
/// with the reporter to establish that it meant a plugin needing AVX2 on a CPU
/// without it, and issue #83's CTMF crash reads almost identically.
///
/// Deliberately not `#[cfg(windows)]`: these are Windows codes, but a Unix
/// process exit code is 0-255 so there is nothing to collide with, and decoding
/// them everywhere keeps the mapping testable on every platform.
fn windows_crash_explanation(code: i32) -> Option<&'static str> {
    match code as u32 {
        0xC000_0005 => Some(
            "access violation inside vspipe or a plugin (a native crash, not a script error)",
        ),
        0xC000_001D => Some(
            "illegal instruction: a plugin used a CPU feature this machine does not have. \
             Run the worker with --probe-cpu to see what it has",
        ),
        0xC000_00FD => Some("stack overflow inside vspipe or a plugin"),
        0xC000_0409 => Some("fail-fast: a plugin detected memory corruption and aborted"),
        0xC000_0094 => Some("integer divide by zero inside vspipe or a plugin"),
        _ => None,
    }
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

/// Whether the decoder ffmpeg's exit only says vspipe stopped reading its
/// output: success, an interrupt, or a failed write to the pipe.
///
/// A closed pipe is SIGPIPE (141) on Linux and EPIPE (224) on macOS, but on
/// Windows the write fails with EINVAL and ffmpeg exits -22, a code it also
/// uses for real argument errors. So a muxer write failure is recognised by
/// what the decoder said: its only output is the raw pipe, so a muxing error
/// can only be that pipe closing.
fn decoder_lost_its_reader(code: i32, stderr_tail: &str) -> bool {
    matches!(code, 0 | 130 | 141 | 224)
        || stderr_tail.contains("Error submitting a packet to the muxer")
        || stderr_tail.contains("Error muxing a packet")
}

/// Decode window for a frame-accurate preview of source frame `target`, given
/// a temporal `radius`. Returns `(first, local, num_frames)`:
/// - `first`: first source frame to decode (clamped so it never goes below 0),
/// - `local`: the target's index *within* the decoded window,
/// - `num_frames`: how many source frames to decode — the window is
///   `[first ..= target + radius]`.
///
/// Pulled out as a pure function so the clamp-at-start behaviour (which the old
/// "middle of 11 frames" heuristic got wrong near the head of the clip) is unit
/// testable without ffmpeg.
fn preview_window(target: i32, radius: i32) -> (i32, i32, i32) {
    let target = target.max(0);
    let radius = radius.max(0);
    let first = (target - radius).max(0);
    let local = target - first;
    let num_frames = local + radius + 1;
    (first, local, num_frames)
}

use crate::audio_restoration::{self, RestoredTrack};
/// The `PREVIEW_INFO:` line a preview reports on stderr after rendering: the
/// frame it rendered, which of that frame's outputs, and — when not square —
/// the display aspect the encode will declare for it. The PNG carries no
/// aspect, so without that last token the app had to guess, and it guessed the
/// *source's* shape: a 720x576 4:3 source upscaled and padded to 1920x1080 was
/// drawn squashed into 4:3 (issue #149).
fn preview_info_line(job: &VideoJob, target: i32, out: &crate::models::PreviewOutput) -> String {
    let mut line = format!(
        "PREVIEW_INFO:frame={} sub_frame={} sub_frames={} generated={}",
        target, out.sub_frame, out.sub_frames, out.generated as u8
    );
    if let Some(token) = job
        .effective_pipeline()
        .output_aspect(job.input_sar.as_deref())
        .preview_token()
    {
        line.push(' ');
        line.push_str(&token);
    }
    line
}

use crate::comment_metadata::{self, CommentFile};
use crate::gpu_plugin::GpuPlugin;
use crate::hdr_metadata::HdrMetadata;
use crate::dependency_locator::DependencyLocator;
use crate::models::{AspectDeclaration, ContainerFormat, DeinterlaceMethod, EncoderFamily, FieldOrderSignal, LogLevel, ProgressInfo, SubtitleOutput, VideoCodec, VideoJob};
use crate::pixel_format;
use crate::source_decode;
use crate::progress_reporter::ProgressReporter;
use crate::script_generator::{PreviewParams, ScriptGenerator};
use crate::source_timing::SourceTimeline;

/// The encoder arguments that declare a still-interlaced picture's field order.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct FieldOrderArgs {
    /// Before `-i -` on the Y4M input: `-top 1` (TFF) or `-top 0` (BFF).
    pub input: Vec<String>,
    /// After the codec's quality args: `-flags +ildct` for ProRes; for x264
    /// `-flags +ildct -x264-params tff=1|bff=1`.
    pub encoder: Vec<String>,
}

/// The one decision about how the encode declares field order, used by every
/// builder of the encoder's arguments. Which codecs take part, and how, is
/// `VideoCodec::field_order_signal`.
///
/// vspipe writes `Ip` (progressive) in every Y4M header, whatever
/// `_FieldBased` says, so without this an interlaced picture is written as
/// progressive by every codec. Measured against FFmpeg 9.0
/// (docs/reports/2026-11-v210-field-order, docs/reports/2026-11-field-order-other-codecs):
///
/// - `-field_order tt` as an output option is inert: the encoder's field
///   order is overwritten from the frames' flags.
/// - `-top 1|0` on the Y4M input flags the frames, which gives `fiel 0x0209`
///   (TFF) / `0x020e` (BFF) in MOV and `tb` / `bt` in MKV, and FFV1 writes it
///   in its own bitstream too. AVI has no field order to write. `setfield` in
///   `-vf` works too, but a Custom FFmpeg Argument `-vf` replaces the chain
///   and would drop it.
/// - ProRes also carries a field flag in its own frame header, which stays
///   progressive unless the frame is coded as fields (`-flags +ildct`).
/// - `-top` alone changes nothing in an x264 stream. `+ildct` makes it MBAFF,
///   but libx264 starts from its default top-field-first and only follows the
///   frame flags later: on a BFF picture the fields are coded bottom-first
///   while the `pic_struct` SEI said top-first on 46 of 79 frames. Naming the
///   order in `-x264-params` makes every frame agree. A Custom FFmpeg
///   Argument `-x264-params` comes later and replaces it (the stream stays
///   MBAFF; only a BFF picture's SEI goes back to disagreeing).
pub fn field_order_args(job: &VideoJob) -> FieldOrderArgs {
    let codec = job.encoding_settings.codec;
    let signal = codec.field_order_signal();
    if signal == FieldOrderSignal::None {
        return FieldOrderArgs::default();
    }
    let pipeline = job.effective_pipeline();
    let Some(tff) = ScriptGenerator::output_field_order(job, &pipeline) else {
        return FieldOrderArgs::default();
    };
    let ildct = || vec!["-flags".to_string(), "+ildct".to_string()];
    FieldOrderArgs {
        input: vec!["-top".to_string(), if tff { "1" } else { "0" }.to_string()],
        encoder: match signal {
            FieldOrderSignal::None | FieldOrderSignal::Container => Vec::new(),
            FieldOrderSignal::ProResFields => ildct(),
            FieldOrderSignal::X264Interlaced => {
                let mut a = ildct();
                a.extend([
                    "-x264-params".to_string(),
                    if tff { "tff=1" } else { "bff=1" }.to_string(),
                ]);
                a
            }
        },
    }
}

/// The job-log line for a picture left interlaced that the output cannot
/// declare as such, or `None` when it can (or the picture is progressive).
///
/// Players then show it as progressive, combing on every moving edge, and an
/// editor treats each woven frame as one picture. Said rather than refused:
/// the user may want exactly this file.
pub fn field_order_note(job: &VideoJob) -> Option<String> {
    let codec = job.encoding_settings.codec;
    let pipeline = job.effective_pipeline();
    ScriptGenerator::output_field_order(job, &pipeline)?;
    match codec.field_order_signal() {
        FieldOrderSignal::None => Some(format!(
            "The picture is still interlaced, but {} cannot mark it as interlaced, so players \
             will show it as progressive. Deinterlace it, or choose H.264, ProRes, v210 or FFV1 \
             to keep the fields.",
            codec.display_name()
        )),
        // FFV1 writes the field order in its own bitstream, so AVI keeps it.
        FieldOrderSignal::Container
            if job.encoding_settings.container == ContainerFormat::Avi
                && codec != VideoCodec::FFV1 =>
        {
            Some(format!(
                "The picture is still interlaced, but AVI cannot record its field order, so \
                 {} in AVI will be read as progressive. MKV or MOV keep it.",
                codec.display_name()
            ))
        }
        _ => None,
    }
}

/// Whether an MP4/MOV output gets `-movflags +faststart`. Not for v210:
/// faststart rewrites the whole file in a second pass to move the index to
/// the front, which at ~1 Gbit/s (an hour of 1080p is ~500 GB) doubles the
/// disk I/O and needs the space twice, for a streaming feature no editor uses.
pub fn uses_faststart(codec: VideoCodec) -> bool {
    !codec.is_uncompressed()
}

/// Executes the ffmpeg (decode) | vspipe | ffmpeg (encode) pipeline.
pub struct PipelineExecutor {
    reporter: ProgressReporter,
    deps: DependencyLocator,
    decoder_process: Option<Child>,
    vspipe_process: Option<Child>,
    ffmpeg_process: Option<Child>,
    /// A variable-frame-rate source's timeline (see `source_timing`), from
    /// which the encode and preview decoders take their window. `None` for a
    /// constant-rate source.
    timeline: Option<SourceTimeline>,
    /// The track audio restoration rendered for this job, mapped in place of
    /// the source's stream (see `audio_restoration`). `None` otherwise.
    restored_audio: Option<RestoredTrack>,
}

/// Watches for the pipeline making no progress at all.
///
/// Time is injected rather than read from the clock so the decision is testable:
/// the hang this guards against cannot be reproduced on demand, which is exactly
/// why a watchdog is the right answer to it.
struct StallWatchdog {
    /// `None` disables the watchdog entirely.
    limit: Option<Duration>,
    last_frame: i32,
    last_progress_at: Instant,
}

impl StallWatchdog {
    fn new(limit: Option<Duration>, now: Instant) -> Self {
        Self {
            limit,
            // No frame count has been seen yet, and 0 is a real value (nothing
            // encoded), so start from one the encoder can never report.
            last_frame: -1,
            last_progress_at: now,
        }
    }

    /// Feed the latest frame count. Returns how long the pipeline has been stuck
    /// once that exceeds the limit, and `None` while it is still healthy.
    fn tick(&mut self, frame: i32, now: Instant) -> Option<Duration> {
        // Any movement resets the clock. A single frame can legitimately take a
        // long time (QTGMC at Placebo on a large frame), hence a limit in minutes
        // rather than seconds.
        if frame != self.last_frame {
            self.last_frame = frame;
            self.last_progress_at = now;
            return None;
        }

        let limit = self.limit?;
        let stalled_for = now.duration_since(self.last_progress_at);
        (stalled_for >= limit).then_some(stalled_for)
    }

    /// How far the job got, for the error message.
    fn stage(frame: i32) -> String {
        if frame > 0 {
            format!("encoding (last frame {})", frame)
        } else {
            "starting up (no frame encoded yet)".to_string()
        }
    }
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
            timeline: None,
            restored_audio: None,
        })
    }

    /// Set the source's variable-frame-rate timeline (see `self.timeline`).
    pub fn with_timeline(mut self, timeline: Option<SourceTimeline>) -> Self {
        self.timeline = timeline;
        self
    }

    /// Use a restored audio track (see `self.restored_audio`).
    pub fn with_restored_audio(mut self, track: Option<RestoredTrack>) -> Self {
        self.restored_audio = track;
        self
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
            &format!("VAPOURSYNTH_EXTRA_PLUGIN_PATH: {:?}", env.get("VAPOURSYNTH_EXTRA_PLUGIN_PATH")),
        );

        // Determine input pixel format for the decoder. Formats pipe_source
        // can't read off the pipe (yuv411p was one until #50; RGB, gray,
        // semi-planar and alpha formats still are) are converted here rather
        // than failing the job — see pixel_format.rs.
        let pipe_format = pixel_format::decode_pixel_format(job.input_pixel_format.as_deref());
        if let Some(note) = pipe_format.conversion_note() {
            self.reporter.send_log(LogLevel::Info, &note);
        }
        let pix_fmt = pipe_format.name.as_str();
        // Declared frame size — must match the dimensions pipe_source uses in
        // the template (see script_generator), so the raw stream stays aligned.
        // The decoder is built to produce exactly this size without resampling
        // (full stored frame, size-guarded) — see source_decode.rs.
        let width = job.input_width.unwrap_or(720);
        let height = job.input_height.unwrap_or(480);

        // Frame trimming is handled by the decoder (faster than VapourSynth
        // trimming since FFmpeg can seek using the container index).
        //
        // A VFR source decodes its stored frames for the trim's window instead
        // — the same `window_for_trim` the script was generated from.
        // Clears a tag FFmpeg's scaler refuses (`reserved`), in case the
        // decoder converts to the pipe format — see source_decode.rs.
        let tag_fix = job.decode_tag_neutraliser();
        let decoder_args = match &self.timeline {
            Some(t) => source_decode::timeline_decoder_args(
                &job.input_path,
                width,
                height,
                pix_fmt,
                &t.window_for_trim(job.start_frame, job.end_frame),
                "pipe:1",
                tag_fix.as_deref(),
                job.seek_plan(),
            ),
            None => source_decode::encode_decoder_args(
                &job.input_path,
                width,
                height,
                pix_fmt,
                job.input_frame_rate,
                job.start_frame,
                job.end_frame,
                job.total_frames,
                job.video_start(),
                tag_fix.as_deref(),
                job.seek_plan(),
                job.source_grid(),
            ),
        };

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

        // Delete any file left over from a previous run of this job BEFORE the
        // pipeline starts.
        //
        // The name is derived from job.id, which is the queue item's id and so is
        // identical every time that item is re-run. ffmpeg writes `progress=end`
        // as it terminates, so a cancelled run leaves one behind — and the next
        // run's progress loop polls immediately, before its own ffmpeg has opened
        // and truncated the file. It reads the previous run's tail, concludes the
        // encode has already finished, breaks out of the loop on its first
        // iteration, and blocks forever in decoder.wait() while the pipeline
        // encodes at full speed behind it. No progress is ever reported and the
        // job never completes: the app sits on "processing" with a spinner.
        //
        // Whether that happens is a race between our first poll and ffmpeg's
        // truncate, which is why it came and went and never reproduced under
        // test — every test used a fresh job id, so the file never pre-existed.
        let _ = fs::remove_file(&progress_file);

        // The output's comment goes to ffmpeg in a file: a source's comment
        // can be long enough to overflow Windows' command line (issue #138).
        let existing_comment = self.deps.ffprobe_path().ok().and_then(|ffprobe| {
            comment_metadata::probe(&ffprobe, &self.deps.build_environment(), &job.input_path)
        });
        let comment_file = CommentFile::write(
            &job.id.to_string(),
            &comment_metadata::output_comment(existing_comment.as_deref()),
        )?;
        // HDR10 static metadata and Dolby Vision (issue #133): side data the
        // pipe drops, read from the source for the encoder.
        let hdr = match self.deps.ffprobe_path() {
            Ok(ffprobe) => HdrMetadata::probe(&ffprobe, &self.deps.build_environment(), &job.input_path),
            Err(_) => HdrMetadata::default(),
        };
        let hdr_transfer = job.color_metadata().is_hdr();
        for (level, line) in hdr.log_lines(job.encoding_settings.codec, hdr_transfer) {
            self.reporter.send_log(level, &line);
        }
        let ffmpeg_args = self.build_ffmpeg_args(
            job,
            &progress_file,
            input_sar.as_deref(),
            &comment_file,
            &hdr,
        );

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
            // Keep a bounded tail: enough to recognise a size-guard failure
            // (source_decode::explain_decoder_failure) and to report the cause.
            let mut tail: Vec<String> = Vec::new();
            for line in reader.lines().map_while(Result::ok) {
                decoder_reporter.send_log(LogLevel::Debug, &format!("decoder stderr: {}", line));
                tail.push(line);
                if tail.len() > 40 {
                    tail.remove(0);
                }
            }
            tail.join("\n")
        });

        // Parse vspipe stderr for input info (in background thread)
        let total_frames = Arc::new(AtomicI32::new(0));
        let total_frames_clone = total_frames.clone();
        let reporter_clone = self.reporter.clone();

        let vspipe_thread = thread::spawn(move || {
            let reader = BufReader::new(vspipe_stderr);
            let mut autoload_failed = false;
            for line in reader.lines().map_while(Result::ok) {
                // Log all stderr for debugging
                reporter_clone.send_log(LogLevel::Debug, &format!("vspipe stderr: {}", line));

                // Detect the plugin-autoload-skip signature so the worker can
                // retry the encode (intermittent under heavy parallel load).
                if is_autoload_skip_line(&line) {
                    autoload_failed = true;
                }

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
            autoload_failed
        });

        // How the pipeline remaps the frame count (double-rate QTGMC ×2, IVTC
        // decimation ×(cycle-1)/cycle, …). vspipe reports the *source* count via
        // INPUT_INFO; output_count() turns it into the encoder's output count.
        let pipeline = job.effective_pipeline();

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

        // Stall watchdog (#50). Nothing else in this loop has a time limit: if a
        // child process wedges — the encoder blocked on an input that never
        // ends, vspipe deadlocked against a full pipe — ffmpeg never writes
        // progress=end and never exits, so the loop spins forever, the worker
        // never reports `complete`, and the UI sits on "processing" with no
        // diagnostics at all. That is the hang reported in #50, and whatever its
        // root cause, hanging silently is the wrong failure mode.
        let mut watchdog = StallWatchdog::new(Self::stall_timeout(), Instant::now());

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
                        ffmpeg_done = progress_end_is_ours(current_frame);
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
                    let mut effective_total = pipeline.output_count(vspipe_total as u64) as i32;

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

            if let Some(stalled_for) = watchdog.tick(current_frame, Instant::now()) {
                // Say how far it got before giving up: without this the user has
                // a hang and nothing to report.
                let stage = StallWatchdog::stage(current_frame);
                reporter.send_log(
                    LogLevel::Error,
                    &format!(
                        "No progress for {}s while {} — giving up rather than hanging. \
                         The decoder, vspipe or the encoder has stopped making progress.",
                        stalled_for.as_secs(),
                        stage
                    ),
                );
                // Kill the children first: the waits below would otherwise block
                // on the same wedged process.
                self.terminate();
                let _ = fs::remove_file(&progress_file);
                bail!(
                    "Stalled: no progress for {}s while {}. Set \
                     VAPOURBOX_STALL_TIMEOUT_SECS to change this limit, or 0 to wait forever.",
                    stalled_for.as_secs(),
                    stage
                );
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
        let decoder_stderr_tail = decoder_stderr_thread.join().unwrap_or_default();
        let vspipe_autoload_failed = vspipe_thread.join().unwrap_or(false);
        let ffmpeg_stderr_tail = ffmpeg_stderr_thread.join().unwrap_or_default();

        // Clean up progress file
        let _ = fs::remove_file(&progress_file);

        // A plugin-autoload skip in vspipe is the ROOT cause of any downstream
        // ffmpeg failure (ffmpeg gets no input and exits non-zero). Surface it
        // first, with the retry marker, so the worker re-runs the encode with a
        // fresh vspipe instead of reporting the misleading ffmpeg error. Don't
        // treat it as failure if the job was cancelled.
        if vspipe_autoload_failed && !on_cancel() {
            bail!(
                "{} vspipe failed to autoload a required VapourSynth plugin",
                PLUGIN_AUTOLOAD_MARKER
            );
        }

        // A decoder that stopped because the source isn't the size it was
        // probed at is the ROOT cause of whatever vspipe/ffmpeg then report
        // (a short or empty raw stream), so it is surfaced before them.
        if let Some(status) = decoder_status {
            if !status.success() && !on_cancel() {
                if let Some(msg) =
                    source_decode::explain_decoder_failure(&decoder_stderr_tail, width, height)
                {
                    bail!("{}", msg);
                }
            }
        }

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

        // The decoder may fail writing to a pipe vspipe has finished reading
        // (e.g. IVTC VDecimate reads fewer frames than available). Harmless:
        // vspipe and the encoder have already been checked above.
        if let Some(status) = decoder_status {
            let code = status.code().unwrap_or(-1);
            if !decoder_lost_its_reader(code, &decoder_stderr_tail) {
                let tail = decoder_stderr_tail.trim();
                if tail.is_empty() {
                    bail!("Decoder ffmpeg exited with {}", format_exit_status(&status));
                }
                bail!("Decoder ffmpeg exited with {}:\n{}", format_exit_status(&status), tail);
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
    fn build_ffmpeg_args(
        &self,
        job: &VideoJob,
        progress_file: &Path,
        input_sar: Option<&str>,
        comment_file: &CommentFile,
        hdr: &HdrMetadata,
    ) -> Vec<String> {
        let mut args = Vec::new();
        let settings = &job.encoding_settings;

        // Input 0: Processed video from vspipe (Y4M pipe)
        args.extend(["-f".to_string(), "yuv4mpegpipe".to_string()]);
        // Declare what the piped samples already are. The Y4M header cannot
        // carry colour tags, and an untagged input feeding the tagged output
        // below is not a relabelling: ffmpeg auto-inserts a scaler that reads
        // "unknown" as BT.601 and re-matrixes every pixel to the output's tag.
        // Declaring the same tags here leaves it nothing to convert. Must match
        // the output flags exactly — see ColorMetadata.
        args.extend(job.output_color_metadata().to_ffmpeg_input_args());
        // Field order of a still-interlaced picture, for the codecs that flag
        // it: the Y4M header always says progressive, so it is declared here,
        // on the input, where a Custom FFmpeg Argument `-vf` cannot drop it.
        let field_order = field_order_args(job);
        args.extend(field_order.input.iter().cloned());
        args.extend(["-i".to_string(), "-".to_string()]);

        // Input 1: Original file for audio stream
        // (Y4M from vspipe contains only video, so we need the original file for audio)
        // When trimming, seek the audio input to the same start point so ffmpeg
        // doesn't read the entire audio track (which hangs for small segments of
        // large files). One decision with the video delay below and Audio
        // Restoration's window: `VideoJob::source_audio_start`.
        args.extend(source_audio_input_seek(job));
        args.extend(["-i".to_string(), job.input_path.clone()]);

        // Input 2: the output's comment, as an FFMETADATA file (issue #138)
        args.extend(comment_file.input_args());

        // Input 3: the restored audio track, when audio restoration ran.
        args.extend(audio_restoration::encode_input_args(self.restored_audio.as_ref()));

        // Progress output to a temp file (avoids Windows pipe buffering delay)
        args.extend(["-progress".to_string(), progress_file.to_string_lossy().to_string()]);

        // Map streams: video from input 0 (processed), audio and subtitles from input 1 (original)
        args.extend(["-map".to_string(), "0:v".to_string()]);  // Video from Y4M pipe
        // Audio from the original (every stream, `1:a?`), or — when audio
        // restoration rendered a track — that track (input 3) first, then the
        // source's other audio streams. One decision site: audio_restoration.
        args.extend(audio_restoration::encode_map_args(settings, self.restored_audio.as_ref(), 3));

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
        // ProRes and x264 code a still-interlaced picture as fields (`+ildct`).
        args.extend(field_order.encoder.iter().cloned());
        if let Some(note) = field_order_note(job) {
            self.reporter.send_log(LogLevel::Info, &note);
        }

        // HDR10 mastering display / content light level (issue #133). The pipe
        // drops them with the rest of the side data; x265 is the one encoder
        // that takes them as options. A Custom FFmpeg Argument `-x265-params`
        // comes later and replaces these.
        args.extend(hdr.encoder_args(settings.codec, job.color_metadata().is_hdr()));

        // Force a compatible output pixel format for codecs that can't accept the
        // pipeline's native format (e.g. classic HuffYUV requires yuv422p, and
        // NVENC/QSV cannot encode 4:2:2 on most hardware — issue #74).
        let encoder_input = job.encoder_input_pix_fmt();
        if let Some(pix_fmt) = settings.codec.forced_pix_fmt(&encoder_input) {
            // Say so in the job log. A silent conversion is the right behaviour
            // — failing the whole encode helps nobody — but it changes the
            // output, so it must not also be invisible.
            if let Some(note) =
                Self::pix_fmt_change_note(settings.codec, &encoder_input, pix_fmt)
            {
                self.reporter.send_log(LogLevel::Info, &note);
            }
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
            if uses_faststart(settings.codec) {
                args.extend(["-movflags".to_string(), "+faststart".to_string()]);
            }
        }

        // Declare the output's aspect ratio. The Y4M pipe from vspipe strips it,
        // so it has to be re-applied whatever the pipeline did — including when
        // a resize ran, which used to drop it and leave an anamorphic source
        // squashed (#50).
        let pipeline = job.effective_pipeline();
        // `output_aspect` adjusts the SAR for a quarter turn; the preview
        // reports the same decision, so the two cannot disagree (#149).
        //
        // Filters accumulate into one chain. ffmpeg takes the LAST -vf and
        // silently drops any earlier one, so appending a second would throw
        // away the aspect stamp — which is exactly how burnt-in subtitles
        // would have broken issue #50's third leg.
        let mut vf: Vec<String> = Vec::new();

        // A source whose video starts after its sound keeps that layout: the
        // picture is delayed by the gap (first, so burn-in draws each cue at
        // its output time). See `VideoJob::output_video_delay`.
        vf.extend(video_delay_filters(job));

        match pipeline.output_aspect(input_sar) {
            AspectDeclaration::Sar(sar) => {
                // '/' as the ratio separator — ':' is ffmpeg's filter option separator.
                vf.push(format!("setsar={}", sar.replace(':', "/")));
            }
            AspectDeclaration::Dar(dar) => {
                // ffmpeg derives the SAR from the actual frame size, which only
                // it knows: the dimensions are computed inside the .vpy.
                vf.push(format!("setdar={}", dar));
            }
            AspectDeclaration::None => {}
        }

        // Burn subtitles into the picture, if a file was supplied. This runs
        // after the whole VapourSynth graph, which for subtitles is correct
        // rather than merely tolerable — they are the last thing applied.
        if let Some(path) = job.burn_in_subtitle_path.as_deref() {
            if !path.trim().is_empty() {
                // Escape for ffmpeg's filter-argument parser: backslash, colon
                // and single quote all terminate or alter the argument, and a
                // Windows path contains the first two by construction.
                let escaped = path
                    .replace('\\', "/")
                    .replace('\'', "\\\\'")
                    .replace(':', "\\\\:");
                vf.push(format!("subtitles='{}'", escaped));
            }
        }

        if !vf.is_empty() {
            args.extend(["-vf".to_string(), vf.join(",")]);
        }
        args.extend(video_delay_encoder_args(job));
        if job.output_video_delay() > 0.0
            && settings.custom_ffmpeg_args.split_whitespace().any(|a| a == "-vf" || a.starts_with("-vf:") || a == "-filter:v")
        {
            self.reporter.send_log(
                LogLevel::Warning,
                "A Custom FFmpeg Argument replaces the video filter chain, which also drops the delay that keeps \
                 this source's picture in sync with its sound (its video starts after its audio).",
            );
        }

        // Re-declare the source's colour tags for exactly the same reason as the
        // SAR above: the Y4M pipe strips them, so an untagged output results and
        // every player then reads it as BT.601 limited. Nothing in the pipeline
        // re-matrixes the samples, so the source's tags still describe them.
        // These equal the input-side declaration on the pipe, which is what
        // stops ffmpeg treating them as a conversion target. A Custom FFmpeg
        // Argument such as `-colorspace smpte170m` still wins (it comes later)
        // and is then a genuine conversion from the source's real matrix.
        args.extend(job.output_color_metadata().to_ffmpeg_output_args());

        // Audio handling: copy / convert / none, and a restored track is
        // always encoded (see audio_restoration::encode_codec_args).
        args.extend(audio_restoration::encode_codec_args(settings, self.restored_audio.as_ref()));

        // Timestamp normalization for modes that change frame rate.
        // Fixes audio sync offset caused by mismatched initial PTS between the
        // Y4M pipe (starts at 0) and audio from the original container.
        // Safe/no-op when timestamps are already aligned.
        let is_framerate_change = pipeline.deinterlace.enabled
            && match pipeline.deinterlace.method {
                DeinterlaceMethod::Ivtc => true,
                DeinterlaceMethod::SoftTelecine => pipeline.soft_telecine_decimates(),
                _ => false,
            };
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

        // Embed VapourBox version in output metadata, preserving any existing
        // comment: the global tags come from input 2, the metadata file.
        args.extend(CommentFile::map_args(2));

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

    /// What to tell the user when [`VideoCodec::forced_pix_fmt`] overrides the
    /// format the pipeline produced, or `None` when there is nothing to say.
    ///
    /// Split out of `build_ffmpeg_args` so it can be tested: the arg-building
    /// mirror used by the unit tests does not log, so any message written
    /// inline there ships as unverified prose.
    ///
    /// The wording matters because the two reasons a format is overridden are
    /// opposites. For a hardware encoder it is a genuine limitation and
    /// something is lost. For ProRes it is the profile's definition — the
    /// encoder could take the source format perfectly well, and a 4:2:0 source
    /// into ProRes 4444 is *padded up*, losing nothing. The original single
    /// sentence ("X cannot encode Y") was written for the first case and would
    /// have told ProRes users their encoder was broken while it did exactly
    /// what they asked.
    fn pix_fmt_change_note(codec: VideoCodec, from: &str, to: &str) -> Option<String> {
        if from == to {
            return None;
        }

        let (from_chroma, from_depth) = pixel_format::chroma_and_depth(from);
        let (to_chroma, to_depth) = pixel_format::chroma_and_depth(to);

        if codec.is_prores() || codec.is_uncompressed() {
            // Nothing is lost when both chroma and depth are kept or widened,
            // which is the common case for a ProRes job: say nothing rather
            // than report a conversion as if it were a cost.
            if to_chroma >= from_chroma && to_depth >= from_depth {
                return None;
            }
            return Some(format!(
                "{} stores {}; converting {} to {} for output",
                codec.display_name(),
                to_chroma.label(),
                from,
                to
            ));
        }

        Some(format!(
            "{} cannot encode {}; converting to {} for output",
            codec.display_name(),
            from,
            to
        ))
    }

    /// Build encoder-family-specific quality and preset arguments.
    fn build_encoder_quality_args(args: &mut Vec<String>, job: &VideoJob) {
        let settings = &job.encoding_settings;
        // Never pass another family's preset vocabulary to the encoder — ffmpeg
        // rejects the option and the encode dies. See `normalized_preset`.
        let preset = settings.codec.normalized_preset(&settings.encoder_preset);
        if let Some(profile) = settings.codec.prores_profile() {
            args.push("-profile:v".to_string());
            args.push(profile.to_string());

            // The three advanced ProRes options, each omitted when unset so the
            // default command line is exactly what it was before they existed.
            if settings.prores_vendor_apl0 {
                args.extend(["-vendor".to_string(), "apl0".to_string()]);
            }
            if let Some(bits) = settings.prores_bits_per_mb {
                // 0 is the plugin's own "use the profile default", which is
                // what omitting the option already does — and the encoder
                // rejects anything above 8192 outright, killing the job on a
                // value the user cannot see. Clamped here rather than only in
                // the UI, because a saved preset or an imported job config can
                // carry either. Same reasoning as `normalized_preset`.
                if bits > 0 {
                    args.extend([
                        "-bits_per_mb".to_string(),
                        bits.min(PRORES_MAX_BITS_PER_MB).to_string(),
                    ]);
                }
            }
            if let Some(mat) = settings.prores_quant_mat {
                args.extend([
                    "-quant_mat".to_string(),
                    mat.ffmpeg_name().to_string(),
                ]);
            }
        } else {
            match settings.codec.encoder_family() {
                EncoderFamily::Software => {
                    args.extend(["-crf".to_string(), settings.quality.to_string()]);
                    args.extend(["-preset".to_string(), preset.clone()]);
                }
                EncoderFamily::Nvenc => {
                    // VBR with constant quality (-cq) provides much better quality
                    // than constqp mode. -b:v 0 removes bitrate ceiling so the
                    // encoder allocates whatever bitrate the content needs.
                    args.extend(["-rc".to_string(), "vbr".to_string()]);
                    args.extend(["-cq".to_string(), settings.quality.to_string()]);
                    args.extend(["-b:v".to_string(), "0".to_string()]);
                    args.extend(["-preset".to_string(), preset.clone()]);
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
                    args.extend(["-preset".to_string(), preset.clone()]);
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
                    // B-frames were left on the encoder's default QP while I and
                    // P were pinned, so a GOP could mix a chosen quality with an
                    // unrelated one. AMF ignores the option on ASICs without
                    // B-frame support, so setting it is safe either way.
                    args.extend(["-qp_b".to_string(), settings.quality.to_string()]);
                    args.extend(["-quality".to_string(), preset.clone()]);
                }
                EncoderFamily::Lossless | EncoderFamily::ProRes | EncoderFamily::Uncompressed => {
                    // No quality/preset args needed
                }
            }
        }
    }

    /// Generate a preview of a specific source frame as PNG to stdout.
    ///
    /// Frame-accurate: decodes a window of source frames centred on
    /// `frame_index`, pipes the raw data through the full VapourSynth pipeline,
    /// then emits the exact output frame that `frame_index` maps to (accounting
    /// for any frame-rate change such as QTGMC double-rate). The requested frame
    /// is echoed back on stderr as `PREVIEW_INFO:frame=N sub_frame=K
    /// sub_frames=C generated=0|1 [sar=N/D | dar=N/D]` so the caller can
    /// label the result truthfully and draw it at the encode's display aspect
    /// (see [`preview_info_line`]).
    pub fn generate_preview(&self, job: &VideoJob, frame_index: i32, sub_frame: u32) -> Result<()> {
        use std::io::Write;

        let ffmpeg_path = self.deps.ffmpeg_path()?;
        let vspipe_path = self.deps.vspipe_path()?;
        let env = self.deps.build_environment();

        let target = frame_index.max(0);
        let frame_rate = job.input_frame_rate.unwrap_or(29.97);
        // Same normalization as the encode path, so a preview and the final
        // render always read the source through the same pipe format.
        let pipe_format = pixel_format::decode_pixel_format(job.input_pixel_format.as_deref());
        let pix_fmt = pipe_format.name.as_str();
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

        // Decode a window [first .. target+radius] of source frames so every
        // temporal filter has context, then emit exactly the target frame.
        let pipeline = job.effective_pipeline();
        let radius = pipeline.total_radius() as i32;
        let (first, local, num_frames) = preview_window(target, radius);

        // Seek so the FIRST decoded frame is exactly `first`. With `-ss` before
        // `-i` ffmpeg does an accurate (decode-and-discard) seek that keeps the
        // first frame whose PTS >= the seek time. Targeting the midpoint of the
        // interval *before* `first` (i.e. (first - 0.5)/fps) lands squarely on
        // `first` for CFR sources, avoiding the ±1-frame ambiguity of seeking to
        // the frame boundary itself.
        let seek_time = source_decode::seek_time(first as i64, frame_rate, job.video_start());
        // A VFR source's window is in grid slots, decoded from its stored
        // frames — the same derivation as the encode (issue #137).
        let window = self
            .timeline
            .as_ref()
            .map(|t| t.window(first as usize, (first + num_frames - 1) as usize));

        // Output frame the target source frame maps to after the pipeline (e.g.
        // ×2 for QTGMC double-rate), or the `sub_frame`th of those in its time
        // span, in the encode's phase. The template clamps defensively.
        let origin = job.start_frame.unwrap_or(0).max(0) as u64;
        let out = pipeline.preview_output(origin, first as u64, target as u64, sub_frame as u64);
        let output_index = out.local_index as i32;

        let decoder_seek = match &window {
            Some(w) => w.seek_time.unwrap_or(0.0),
            None => seek_time.unwrap_or(0.0),
        };
        // On an MPEG-TS/PS the decoder seeks a GOP earlier and trims to the
        // target (source_decode rule 6); say so, with what it actually runs.
        let planned = source_decode::decoder_seek(
            (decoder_seek > 0.0).then_some(decoder_seek),
            job.seek_plan(),
        );
        let plan_note = match (&window, job.source_grid()) {
            // Without a VFR timeline, a source with a grid starts there
            // (source_decode rule 7): say what the decoder actually runs.
            (None, Some(g)) => {
                let start = source_decode::decode_start(
                    first as i64, frame_rate, job.video_start(), job.seek_plan(), Some(g),
                );
                format!(
                    ", grid {}/{} from slot {}: -ss {:.6}s",
                    g.rate_num, g.rate_den, first, start.ss.unwrap_or(0.0)
                )
            }
            _ => match planned.trim_from {
                Some(t) => format!(
                    ", MPEG-TS/PS: -ss {:.6}s, trim from {:.6}s",
                    planned.ss.unwrap_or(0.0),
                    t
                ),
                None => String::new(),
            },
        };
        eprintln!(
            "Preview: source frame {} (window {}..{}, local {}, output index {}, output {} of {}, rate pad {}) seek {:.6}s ({}x{} {}{}{})",
            target, first, target + radius, local, output_index, out.sub_frame + 1, out.sub_frames, out.rate_pad,
            decoder_seek, width, height, pix_fmt,
            if window.is_some() { ", variable frame rate" } else { "" },
            plan_note
        );

        // Field order is derived inside the script generator (see
        // ScriptGenerator::field_based_for) so the preview and the encode can
        // never disagree about it — issue #49.

        // FPS as rational
        let script_generator = ScriptGenerator::new()?
            .with_opencl_available(self.deps.opencl_available())
            .with_knlm_available(self.deps.knlm_available())
            .with_rife(if job.effective_pipeline().uses_rife() {
                self.deps.gpu_plugin_runtime(GpuPlugin::Rife)
            } else {
                Err("RIFE is not used by this job.".into())
            })
            .with_upscale(if job.effective_pipeline().uses_ai_upscale() {
                self.deps.gpu_plugin_runtime(GpuPlugin::Upscale)
            } else {
                Err("AI upscaling is not used by this job.".into())
            })
            .with_knlm(if job.effective_pipeline().uses_knlm() {
                self.deps.knlm_runtime()
            } else {
                Err("KNLMeans is not used by this job.".into())
            })
            .with_animejanai(self.deps.animejanai_runtime())
            .with_addons(self.deps.addons_dir(), self.deps.platform_suffix())
            .with_timeline(window.clone());
        let (fps_num, fps_den) = script_generator.frame_rate_to_rational(frame_rate);

        let preview_params = PreviewParams {
            width,
            height,
            pix_fmt: pix_fmt.to_string(),
            num_frames,
            fps_num,
            fps_den,
            output_index,
            rate_pad: out.rate_pad,
            source_frame_offset: first,
        };

        let script_path = script_generator.generate_preview(job, &preview_params)?;

        eprintln!("Generated preview script: {:?}", script_path);

        // Decode frames to a temp raw file (avoids rawvideo muxer pipe issues on Windows)
        // For 11 frames this is tiny (~9MB) and near-instant with keyframe seeking
        let temp_dir = std::env::temp_dir().join(format!("vapourbox_preview_{}", job.id));
        fs::create_dir_all(&temp_dir)
            .with_context(|| format!("Failed to create temp dir: {:?}", temp_dir))?;
        let raw_path = temp_dir.join("frames.raw");

        // Same decode as the encode path: the full stored frame at exactly the
        // probed size, never resampled — see source_decode.rs.
        let tag_fix = job.decode_tag_neutraliser();
        let decoder_args = match &window {
            Some(w) => source_decode::timeline_decoder_args(
                &job.input_path,
                width,
                height,
                pix_fmt,
                w,
                raw_path.to_string_lossy().as_ref(),
                tag_fix.as_deref(),
                job.seek_plan(),
            ),
            None => source_decode::preview_decoder_args(
                &job.input_path,
                first as i64,
                frame_rate,
                num_frames,
                width,
                height,
                pix_fmt,
                raw_path.to_string_lossy().as_ref(),
                job.video_start(),
                tag_fix.as_deref(),
                job.seek_plan(),
                job.source_grid(),
            ),
        };
        let extract_result = Command::new(&ffmpeg_path)
            .args(decoder_args)
            .envs(&env)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .with_context(|| "Failed to run ffmpeg for frame extraction")?;

        if !extract_result.status.success() {
            let stderr = String::from_utf8_lossy(&extract_result.stderr);
            let _ = fs::remove_dir_all(&temp_dir);
            if let Some(msg) = source_decode::explain_decoder_failure(&stderr, width, height) {
                bail!("{}", msg);
            }
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

        // Start encoder FFmpeg — converts Y4M to PNG.
        //
        // The Y4M pipe carries no colour information, so swscale would guess the
        // matrix here — while the app's "before" thumbnail comes from a separate
        // ffmpeg call on the original file that does see the real tags. That
        // mismatch showed a hue shift no filter had caused. `in_range` was also
        // hardcoded to `tv`, which stretched a full-range source a second time.
        //
        // An HDR source is tone-mapped for display instead (issue #133), with
        // the same chain the app uses for its "before" frame.
        //
        // The OUTPUT's tags, not the source's: when Crop & Resize converts a
        // BT.601 source to BT.709, the pipe carries 709 samples, and reading
        // them as 601 would show a colour shift the encode does not have.
        let color = job.output_color_metadata();
        let scale_filter = color.display_tonemap_filter().unwrap_or_else(|| {
            let mut scale_opts = color.swscale_input_opts();
            scale_opts.push("out_range=pc".to_string());
            format!("scale={}", scale_opts.join(":"))
        });
        let ffmpeg_enc = Command::new(&ffmpeg_path)
            .args([
                "-f", "yuv4mpegpipe",
                "-i", "pipe:0",
                "-vframes", "1",
                "-vf", &scale_filter,
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

        // Echo the frame we actually rendered so the caller can label it (the
        // PNG itself is the only thing on stdout, so this goes to stderr).
        eprintln!("{}", preview_info_line(job, target, &out));

        // Write PNG to stdout
        std::io::stdout().write_all(&output.stdout)?;
        std::io::stdout().flush()?;

        Ok(())
    }

    /// How long the pipeline may make no progress before the job is failed
    /// instead of hanging (#50).
    ///
    /// `None` disables the watchdog. The default is deliberately generous: a
    /// single frame of QTGMC at Placebo on a large frame can take a long time,
    /// and finalizing a big MP4 can pause the frame counter. What it catches is
    /// the case where nothing will ever move again.
    fn stall_timeout() -> Option<Duration> {
        const DEFAULT_SECS: u64 = 600;

        match std::env::var("VAPOURBOX_STALL_TIMEOUT_SECS") {
            Ok(value) => match value.trim().parse::<u64>() {
                // An explicit 0 means "wait forever", for debugging a stall.
                Ok(0) => None,
                Ok(secs) => Some(Duration::from_secs(secs)),
                Err(_) => Some(Duration::from_secs(DEFAULT_SECS)),
            },
            Err(_) => Some(Duration::from_secs(DEFAULT_SECS)),
        }
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


/// Ticks per second of the time base the video delay is stamped in. A
/// multiple of every broadcast rate's frame duration (25, 50, 24, 30, 60, and
/// their /1001 variants all take a whole number of ticks), so the frames stay
/// evenly spaced; the encoder's default, 1/fps, would round the delay to a
/// whole frame (measured: 10 ms off on a 1.01 s gap).
pub const VIDEO_DELAY_TIMESCALE: u64 = 120_000;

/// The encoder `-vf` entries that delay the picture by
/// `VideoJob::output_video_delay`, or none.
pub fn video_delay_filters(job: &VideoJob) -> Vec<String> {
    let delay = job.output_video_delay();
    if delay <= 0.0 {
        return Vec::new();
    }
    let ticks = (delay * VIDEO_DELAY_TIMESCALE as f64).round() as u64;
    vec![
        format!("settb=1/{VIDEO_DELAY_TIMESCALE}"),
        format!("setpts=PTS+{ticks}"),
    ]
}

/// The output option that keeps [`video_delay_filters`]' time base through the
/// encoder, or none.
pub fn video_delay_encoder_args(job: &VideoJob) -> Vec<String> {
    if job.output_video_delay() <= 0.0 {
        return Vec::new();
    }
    vec!["-enc_time_base:v".to_string(), format!("1/{VIDEO_DELAY_TIMESCALE}")]
}

/// The `-ss` before the source input the encoder takes its sound from, or none.
pub fn source_audio_input_seek(job: &VideoJob) -> Vec<String> {
    let start = job.source_audio_start();
    if start > 0.0 {
        vec!["-ss".to_string(), format!("{:.6}", start)]
    } else {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AudioCodec, AudioMode, AudioQuality, ChromaSubsampling, EncodingSettings, ProResQuantMat, QTGMCParameters, VideoCodec};
    use uuid::Uuid;

    /// The two codes that have actually cost debugging time must be named in
    /// the error, and an ordinary exit code must not be dressed up as a crash.
    ///
    /// `-1073741795` was all the reporter of issue #82 had to go on, and it took
    /// a round trip to establish that it meant "a plugin needs AVX2 and this CPU
    /// has none". `-1073741819` is the CTMF crash of issue #83. A tool exiting
    /// 1 or 255 is not a fault code and must read as it always did.
    #[test]
    fn windows_crash_codes_are_named_in_the_error() {
        let illegal = windows_crash_explanation(0xC000_001D_u32 as i32)
            .expect("0xC000001D must be explained");
        assert!(
            illegal.contains("illegal instruction") && illegal.contains("CPU feature"),
            "the AVX2 case must say what it means: {illegal}"
        );
        assert!(
            illegal.contains("--probe-cpu"),
            "and how to find out what this machine has: {illegal}"
        );

        let violation = windows_crash_explanation(0xC000_0005_u32 as i32)
            .expect("0xC0000005 must be explained");
        assert!(violation.contains("access violation"), "got: {violation}");

        // Not fault codes: a real exit status from a tool that ran and failed.
        for ordinary in [0, 1, 2, 130, 141, 255, -1] {
            assert!(
                windows_crash_explanation(ordinary).is_none(),
                "{ordinary} is an exit code, not a crash"
            );
        }
    }

    /// A leftover `progress=end` must not end a run that has produced no frames.
    ///
    /// This is the bug that produced "the UI sits on processing with a spinner
    /// and never updates". The progress file is keyed on job.id, which is the
    /// queue item's id and so is reused on every re-run of that item; a
    /// cancelled run leaves `progress=end` behind, and the next run read it
    /// before its own ffmpeg had truncated the file, broke out of the progress
    /// loop immediately, and blocked in decoder.wait() forever.
    ///
    /// It is tested here rather than end-to-end because the failure is a race
    /// between the first poll and ffmpeg's truncate: it reproduces reliably over
    /// a network share and essentially never against a local file, so an
    /// integration test passes with or without the fix. (Verified: the heavy
    /// stale-progress tests pass against the broken worker too.)
    #[test]
    fn test_94_stale_progress_end_is_not_ours() {
        assert!(
            !progress_end_is_ours(0),
            "a progress=end seen before this run reported any frame is a \
             leftover from the previous run; trusting it ends the loop on the \
             first iteration and hangs the job"
        );
    }

    #[test]
    fn test_95_progress_end_after_frames_ends_the_run() {
        assert!(
            progress_end_is_ours(1),
            "once this run has reported frames, progress=end is genuinely ours \
             and must end the loop — otherwise the job never finishes"
        );
        assert!(progress_end_is_ours(150_000));
    }

    /// The decoder's write into a pipe vspipe has closed, as each platform
    /// reports it. Windows' wording is the one that failed the DV 4:1:1 job.
    #[test]
    fn test_decoder_closed_pipe_is_harmless_on_every_platform() {
        let windows = "[vost#0:0/rawvideo @ 0000] Error submitting a packet to the muxer: Invalid argument\n\
                       [out#0/rawvideo @ 0000] Error muxing a packet\n\
                       [out#0/rawvideo @ 0000] Task finished with error code: -22 (Invalid argument)";
        assert!(decoder_lost_its_reader(-22, windows));
        assert!(decoder_lost_its_reader(224, "Error muxing a packet: Broken pipe"));
        assert!(decoder_lost_its_reader(141, ""));
        assert!(decoder_lost_its_reader(0, ""));
        // A real failure, with the same exit code, still fails the job.
        assert!(!decoder_lost_its_reader(-22, "Option foo not found."));
        assert!(!decoder_lost_its_reader(1, "pipe:1: Invalid data found when processing input"));
    }

    #[test]
    fn test_preview_window_centered() {
        // Mid-clip: window is symmetric, target sits at `radius` within it.
        assert_eq!(preview_window(100, 5), (95, 5, 11));
    }

    #[test]
    fn test_preview_window_clamped_near_start() {
        // Near the head the window can't extend below frame 0, so `first`
        // clamps and the target's local index shrinks accordingly — the case
        // the old "middle of 11" heuristic rendered as the wrong frame.
        assert_eq!(preview_window(2, 5), (0, 2, 8));
        assert_eq!(preview_window(0, 5), (0, 0, 6));
    }

    #[test]
    fn test_preview_window_zero_radius() {
        // Degenerate radius still yields a single-frame window at the target.
        assert_eq!(preview_window(42, 0), (42, 0, 1));
        // Negative inputs are clamped, never panicking.
        assert_eq!(preview_window(-3, 5), (0, 0, 6));
    }

    #[test]
    fn test_watchdog_resets_on_any_movement() {
        let start = Instant::now();
        let limit = Duration::from_secs(60);
        let mut watchdog = StallWatchdog::new(Some(limit), start);

        // Nothing encoded yet, but well inside the limit.
        assert_eq!(watchdog.tick(0, start + Duration::from_secs(30)), None);
        // A frame arrives at 30s, so the clock restarts from there...
        assert_eq!(watchdog.tick(1, start + Duration::from_secs(30)), None);
        // ...and 59s later is still fine, even though 89s have passed overall.
        assert_eq!(watchdog.tick(1, start + Duration::from_secs(89)), None);
        // One more frame and we are healthy again.
        assert_eq!(watchdog.tick(2, start + Duration::from_secs(89)), None);
        assert_eq!(watchdog.tick(2, start + Duration::from_secs(140)), None);
    }

    #[test]
    fn test_watchdog_trips_once_the_limit_is_reached() {
        let start = Instant::now();
        let limit = Duration::from_secs(60);
        let mut watchdog = StallWatchdog::new(Some(limit), start);

        // Frame 7 arrives, then nothing ever again.
        assert_eq!(watchdog.tick(7, start), None);
        assert_eq!(watchdog.tick(7, start + Duration::from_secs(59)), None);
        assert_eq!(
            watchdog.tick(7, start + Duration::from_secs(60)),
            Some(Duration::from_secs(60)),
            "exactly at the limit counts as stalled"
        );
        assert_eq!(
            watchdog.tick(7, start + Duration::from_secs(120)),
            Some(Duration::from_secs(120))
        );
    }

    #[test]
    fn test_watchdog_trips_when_nothing_is_ever_encoded() {
        // The reported symptom: a job that never produces a frame at all. Frame 0
        // must not be mistaken for "progress arrived", or the watchdog would
        // reset forever on a pipeline that never started.
        let start = Instant::now();
        let mut watchdog = StallWatchdog::new(Some(Duration::from_secs(60)), start);

        assert_eq!(watchdog.tick(0, start), None, "first sighting is not a stall");
        assert_eq!(
            watchdog.tick(0, start + Duration::from_secs(61)),
            Some(Duration::from_secs(61))
        );
        assert_eq!(StallWatchdog::stage(0), "starting up (no frame encoded yet)");
        assert_eq!(StallWatchdog::stage(1234), "encoding (last frame 1234)");
    }

    #[test]
    fn test_watchdog_disabled_never_trips() {
        let start = Instant::now();
        let mut watchdog = StallWatchdog::new(None, start);
        assert_eq!(watchdog.tick(3, start), None);
        // Ten hours with no movement, and still no complaint.
        assert_eq!(watchdog.tick(3, start + Duration::from_secs(36_000)), None);
    }

    #[test]
    fn test_stall_timeout_default_and_override() {
        // Serial within this test: the env var is process-global.
        let restore = std::env::var("VAPOURBOX_STALL_TIMEOUT_SECS").ok();

        std::env::remove_var("VAPOURBOX_STALL_TIMEOUT_SECS");
        assert_eq!(PipelineExecutor::stall_timeout(), Some(Duration::from_secs(600)));

        std::env::set_var("VAPOURBOX_STALL_TIMEOUT_SECS", "90");
        assert_eq!(PipelineExecutor::stall_timeout(), Some(Duration::from_secs(90)));

        // 0 means "wait forever", for debugging an actual stall.
        std::env::set_var("VAPOURBOX_STALL_TIMEOUT_SECS", "0");
        assert_eq!(PipelineExecutor::stall_timeout(), None);

        // Garbage falls back to the default rather than disabling the guard.
        std::env::set_var("VAPOURBOX_STALL_TIMEOUT_SECS", "soon");
        assert_eq!(PipelineExecutor::stall_timeout(), Some(Duration::from_secs(600)));

        match restore {
            Some(value) => std::env::set_var("VAPOURBOX_STALL_TIMEOUT_SECS", value),
            None => std::env::remove_var("VAPOURBOX_STALL_TIMEOUT_SECS"),
        }
    }

    #[test]
    fn test_is_autoload_skip_line() {
        // The two real VapourSynth phrasings seen in the wild (missing namespace
        // vs missing attribute) both end with this guidance.
        assert!(is_autoload_skip_line(
            "Python exception: There is no attribute or namespace named fmtc. \
             Did you mistype a plugin namespace or forget to install a plugin?"
        ));
        assert!(is_autoload_skip_line(
            "AttributeError: No attribute with the name knlm exists. \
             Did you mistype a plugin namespace or forget to install a plugin?"
        ));
        // Unrelated stderr must not trip the retry.
        assert!(!is_autoload_skip_line("vspipe stderr: Output 0 done"));
        assert!(!is_autoload_skip_line("INPUT_INFO:frames=100,fps_num=25,fps_den=1"));
    }

    thread_local! {
        static TEST_HDR: std::cell::RefCell<HdrMetadata> = std::cell::RefCell::new(HdrMetadata::default());
    }

    /// Build args as if the source had probed as `hdr`.
    fn build_ffmpeg_args_with_hdr(job: &VideoJob, hdr: HdrMetadata) -> Vec<String> {
        TEST_HDR.with(|h| *h.borrow_mut() = hdr);
        let args = build_ffmpeg_args_for_test(job);
        TEST_HDR.with(|h| *h.borrow_mut() = HdrMetadata::default());
        args
    }

    /// An HDR10 source encoded with x265 keeps its mastering display and light
    /// levels; the same source to any other encoder, or an SDR one, gets none.
    #[test]
    fn test_hdr10_metadata_reaches_x265_only() {
        use crate::hdr_metadata::{ContentLight, MasteringDisplay};
        let hdr = HdrMetadata {
            mastering_display: Some(MasteringDisplay {
                red: (34000, 16000),
                green: (13250, 34500),
                blue: (7500, 3000),
                white_point: (15635, 16450),
                max_luminance: 10_000_000,
                min_luminance: 1,
            }),
            content_light: Some(ContentLight { max_cll: 1000, max_fall: 400 }),
            dolby_vision: None,
        };
        let mut job = create_test_job("out.mkv");
        job.input_color_matrix = Some("bt2020nc".to_string());
        job.input_color_primaries = Some("bt2020".to_string());
        job.input_color_transfer = Some("smpte2084".to_string());
        job.encoding_settings.codec = VideoCodec::H265;

        let args = build_ffmpeg_args_with_hdr(&job, hdr.clone());
        let i = args.iter().position(|a| a == "-x265-params").expect("-x265-params");
        assert_eq!(
            args[i + 1],
            "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"
        );
        // Before the output path and any custom arguments, so those still win.
        assert!(i < args.iter().position(|a| a == "-y").unwrap());

        job.encoding_settings.codec = VideoCodec::H264;
        assert!(!build_ffmpeg_args_with_hdr(&job, hdr.clone()).iter().any(|a| a == "-x265-params"));

        job.encoding_settings.codec = VideoCodec::H265;
        job.input_color_transfer = Some("bt709".to_string());
        assert!(!build_ffmpeg_args_with_hdr(&job, hdr).iter().any(|a| a == "-x265-params"));
    }

    /// Issue #138: the source's comment is unbounded, so the real builder
    /// must hand it to ffmpeg as the metadata file (input 2, after the source)
    /// and never put it on the command line, where a long one overflowed
    /// Windows' 32,767-character limit and ffmpeg could not start.
    #[test]
    fn test_real_ffmpeg_builder_takes_the_comment_from_a_file() {
        let src = include_str!("pipeline_executor.rs").replace("\r\n", "\n");
        let start = src.find("fn build_ffmpeg_args(\n").expect("real builder");
        let body = &src[start..];
        let body = &body[..body.find("\n    }\n").expect("end of builder")];
        assert!(!body.contains("\"-metadata\""), "no -metadata on the command line");
        let source = body
            .find(r#"args.extend(["-i".to_string(), job.input_path.clone()]);"#)
            .expect("source input");
        let file = body.find("comment_file.input_args()").expect("metadata file input");
        assert!(source < file, "the metadata file must be input 2, after the source");
        assert!(body.contains("CommentFile::map_args(2)"));
    }

    /// The real builder must carry the same call as the copy above.
    #[test]
    fn test_real_ffmpeg_builder_passes_hdr_metadata() {
        let src = include_str!("pipeline_executor.rs").replace("\r\n", "\n");
        let start = src.find("fn build_ffmpeg_args(\n").expect("real builder");
        let body = &src[start..];
        let body = &body[..body.find("\n    }\n").expect("end of builder")];
        assert!(
            body.contains("hdr.encoder_args(settings.codec, job.color_metadata().is_hdr())"),
            "build_ffmpeg_args must pass the HDR10 metadata to the encoder"
        );
    }

    /// The real builder takes every audio decision from audio_restoration,
    /// with the restored track as input 3 (after the source and the metadata
    /// file); the copy below cannot show that, having neither.
    #[test]
    fn test_real_ffmpeg_builder_delegates_audio_to_audio_restoration() {
        let src = include_str!("pipeline_executor.rs").replace("\r\n", "\n");
        let start = src.find("fn build_ffmpeg_args(\n").expect("real builder");
        let body = &src[start..];
        let body = &body[..body.find("\n    }\n").expect("end of builder")];
        let file = body.find("comment_file.input_args()").expect("metadata file input");
        let track = body
            .find("audio_restoration::encode_input_args(self.restored_audio.as_ref())")
            .expect("restored track input");
        assert!(file < track, "the restored track must be input 3, after the metadata file");
        assert!(body.contains("audio_restoration::encode_map_args(settings, self.restored_audio.as_ref(), 3)"));
        assert!(body.contains("audio_restoration::encode_codec_args(settings, self.restored_audio.as_ref())"));
        assert!(!body.contains("\"1:a?\""), "audio mapping belongs to audio_restoration");
        assert_eq!(body.matches("\"-af\"").count(), 0, "the encode never filters audio itself");
    }

    /// A source whose video starts after its sound keeps that layout: the
    /// encoder delays the picture by the gap in a fine time base and copies
    /// the sound from the container's start. Trimmed, both start at the
    /// in-point and the sound's seek carries the gap. No gap, no change.
    #[test]
    fn a_late_video_is_delayed_in_the_encoder_not_cut_from_the_sound() {
        let mut job = create_test_job("/tmp/out.mkv");
        job.input_frame_rate = Some(25.0);
        assert!(video_delay_filters(&job).is_empty());
        assert!(video_delay_encoder_args(&job).is_empty());
        assert!(source_audio_input_seek(&job).is_empty());

        job.video_start_offset = Some(1.010022);
        assert_eq!(video_delay_filters(&job), ["settb=1/120000", "setpts=PTS+121203"]);
        assert_eq!(video_delay_encoder_args(&job), ["-enc_time_base:v", "1/120000"]);
        assert!(source_audio_input_seek(&job).is_empty(), "the sound is copied from the start");

        job.start_frame = Some(30);
        assert!(video_delay_filters(&job).is_empty());
        assert_eq!(source_audio_input_seek(&job), ["-ss", "2.210022"]);

        // Every broadcast rate's frame is a whole number of ticks.
        for (num, den) in [(25u64, 1u64), (50, 1), (24, 1), (30, 1), (60, 1), (24000, 1001), (30000, 1001), (60000, 1001)] {
            assert_eq!((VIDEO_DELAY_TIMESCALE * den) % num, 0, "{num}/{den}");
        }
    }

    /// The real builder takes the delay and the sound's seek from the helpers
    /// above, the delay first in the one -vf (so burn-in draws at output time).
    #[test]
    fn test_real_ffmpeg_builder_uses_the_video_start_helpers() {
        let src = include_str!("pipeline_executor.rs").replace("\r\n", "\n");
        let start = src.find("fn build_ffmpeg_args(\n").expect("real builder");
        let body = &src[start..];
        let body = &body[..body.find("\n    }\n").expect("end of builder")];
        let seek = body.find("args.extend(source_audio_input_seek(job));").expect("audio seek");
        let input = body.find(r#"args.extend(["-i".to_string(), job.input_path.clone()]);"#).unwrap();
        assert!(seek < input, "the sound's seek is an input option of the source");
        let delay = body.find("vf.extend(video_delay_filters(job));").expect("delay filters");
        let aspect = body.find("pipeline.output_aspect(input_sar)").unwrap();
        let burn = body.find("subtitles='{}'").unwrap();
        assert!(delay < aspect && delay < burn, "the delay comes first in the chain");
        assert!(body.contains("args.extend(video_delay_encoder_args(job));"));
        assert!(!body.contains("start as f64 / fps"), "no second derivation of the sound's start");
    }

    /// Helper to build FFmpeg args without requiring a full PipelineExecutor.
    /// This mirrors the logic in PipelineExecutor::build_ffmpeg_args for testing.
    fn build_ffmpeg_args_for_test(job: &VideoJob) -> Vec<String> {
        let mut args = Vec::new();
        let settings = &job.encoding_settings;

        // Input 0: Processed video from vspipe (Y4M pipe), with the source's
        // colour tags declared on it (mirrors build_ffmpeg_args).
        args.extend(["-f".to_string(), "yuv4mpegpipe".to_string()]);
        args.extend(job.output_color_metadata().to_ffmpeg_input_args());
        let field_order = field_order_args(job);
        args.extend(field_order.input.iter().cloned());
        args.extend(["-i".to_string(), "-".to_string()]);

        // Input 1: Original file for audio stream, seeked as build_ffmpeg_args does
        args.extend(source_audio_input_seek(job));
        args.extend(["-i".to_string(), job.input_path.clone()]);

        // Progress output to temp file
        args.extend(["-progress".to_string(), "/tmp/test_progress.txt".to_string()]);

        // A late video's delay (mirrors build_ffmpeg_args; the rest of its -vf
        // chain is not mirrored here).
        let delay = video_delay_filters(job);
        if !delay.is_empty() {
            args.extend(["-vf".to_string(), delay.join(",")]);
        }
        args.extend(video_delay_encoder_args(job));

        // Map streams: video from input 0 (processed), audio from input 1 (original) if not disabled
        args.extend(["-map".to_string(), "0:v".to_string()]);
        args.extend(audio_restoration::encode_map_args(settings, None, 2));

        // Video codec
        args.extend(["-c:v".to_string(), settings.codec.ffmpeg_codec().to_string()]);

        // Encoder-family-specific quality and preset args
        PipelineExecutor::build_encoder_quality_args(&mut args, job);
        args.extend(field_order.encoder.iter().cloned());

        // HDR10 static metadata (mirrors build_ffmpeg_args); the probe needs a
        // real file, so tests set `TEST_HDR` through `with_hdr` instead.
        args.extend(TEST_HDR.with(|h| {
            h.borrow().encoder_args(settings.codec, job.color_metadata().is_hdr())
        }));

        // Force a compatible output pixel format (e.g. HuffYUV requires yuv422p,
        // NVENC/QSV cannot encode 4:2:2 on most hardware)
        if let Some(pix_fmt) = settings.codec.forced_pix_fmt(&job.encoder_input_pix_fmt()) {
            args.extend(["-pix_fmt".to_string(), pix_fmt.to_string()]);
        }

        // MP4/MOV container fixups (mirrors build_ffmpeg_args): hvc1 tag for HEVC
        // so Apple players accept it, plus +faststart.
        if matches!(settings.container, ContainerFormat::Mp4 | ContainerFormat::Mov) {
            if settings.codec.is_h265() {
                args.extend(["-tag:v".to_string(), "hvc1".to_string()]);
            }
            if uses_faststart(settings.codec) {
                args.extend(["-movflags".to_string(), "+faststart".to_string()]);
            }
        }

        // Colour tags. This helper duplicates build_ffmpeg_args rather than
        // calling it, so anything added there has to be added here too — the
        // SAR block was missed that way and is still absent below.
        args.extend(job.output_color_metadata().to_ffmpeg_output_args());

        // Audio handling (mirrors build_ffmpeg_args; no restored track here).
        args.extend(audio_restoration::encode_codec_args(settings, None));

        // Custom arguments
        if !settings.custom_ffmpeg_args.is_empty() {
            args.extend(settings.custom_ffmpeg_args.split_whitespace().map(String::from));
        }

        // Output file (force overwrite)
        args.push("-y".to_string());
        args.push(job.output_path.clone());

        args
    }

    fn preview_out() -> crate::models::PreviewOutput {
        crate::models::PreviewOutput {
            local_index: 3,
            rate_pad: 0,
            sub_frame: 0,
            sub_frames: 2,
            generated: false,
        }
    }

    /// The preview reports the aspect the encode will declare, so the app can
    /// draw the processed frame at its own shape (issue #149).
    #[test]
    fn preview_info_reports_the_output_aspect() {
        let mut job = create_test_job("/tmp/out.mkv");
        job.input_sar = Some("16:15".to_string());
        assert_eq!(
            preview_info_line(&job, 7, &preview_out()),
            "PREVIEW_INFO:frame=7 sub_frame=0 sub_frames=2 generated=0 sar=16/15"
        );

        // Squaring the pixels resamples the grid: nothing to declare.
        let mut pipeline = job.effective_pipeline();
        pipeline.crop_resize.enabled = true;
        pipeline.crop_resize.pixel_aspect = crate::models::PixelAspectMode::Square;
        job.processing_pipeline = Some(pipeline.clone());
        assert_eq!(
            preview_info_line(&job, 7, &preview_out()),
            "PREVIEW_INFO:frame=7 sub_frame=0 sub_frames=2 generated=0"
        );

        // A forced display aspect is reported as a DAR.
        pipeline.crop_resize.pixel_aspect = crate::models::PixelAspectMode::Preserve;
        pipeline.crop_resize.display_aspect = Some("16:9".to_string());
        job.processing_pipeline = Some(pipeline);
        assert!(preview_info_line(&job, 7, &preview_out()).ends_with(" dar=16/9"));

        // Square-pixel source, nothing changed: the line is what it always was.
        let job = create_test_job("/tmp/out.mkv");
        assert_eq!(
            preview_info_line(&job, 7, &preview_out()),
            "PREVIEW_INFO:frame=7 sub_frame=0 sub_frames=2 generated=0"
        );
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
            input_color_matrix: None,
            input_color_primaries: None,
            input_color_transfer: None,
            input_color_range: None,
            burn_in_subtitle_path: None,
            pitch_factors_path: None,
            video_start_offset: None,
            seek_plan: None,
            source_grid: None,
            source_has_audio: None,
        }
    }

    /// Colour tags survive the pipe and reach the encoder.
    ///
    /// The Y4M pipe from vspipe strips colour metadata exactly as it strips
    /// SAR, so an output that is not explicitly re-tagged is read as BT.601
    /// limited by every player. Every file this app wrote was untagged until
    /// this landed, which silently shifted the colours of any BT.709 or
    /// full-range source.
    #[test]
    fn test_color_tags_are_declared_on_the_output() {
        let mut job = create_test_job("out.mkv");
        job.input_color_matrix = Some("bt709".to_string());
        job.input_color_primaries = Some("bt709".to_string());
        job.input_color_transfer = Some("bt709".to_string());
        job.input_color_range = Some("tv".to_string());

        let args = build_ffmpeg_args_for_test(&job);
        let pair = |flag: &str| {
            args.iter().position(|a| a == flag).map(|i| args[i + 1].clone())
        };
        assert_eq!(pair("-colorspace").as_deref(), Some("bt709"));
        assert_eq!(pair("-color_primaries").as_deref(), Some("bt709"));
        assert_eq!(pair("-color_trc").as_deref(), Some("bt709"));
        assert_eq!(pair("-color_range").as_deref(), Some("tv"));
    }

    /// The tags must also be declared on the Y4M *input*, identically.
    ///
    /// Output-only tags are not a relabelling: ffmpeg sees an untagged input,
    /// auto-inserts a scaler, reads "unknown" as BT.601 and re-matrixes every
    /// pixel to the output's tag. Measured on FFmpeg 9.0.1 (2026-09-26), a flat
    /// 10-bit frame at Y/U/V 565/236/756 came back 546/259/741 from a bt709
    /// source. Declaring the input as the same thing leaves nothing to convert.
    #[test]
    fn test_color_tags_are_declared_on_the_y4m_input_too() {
        let mut job = create_test_job("out.mkv");
        job.input_color_matrix = Some("bt709".to_string());
        job.input_color_primaries = Some("bt709".to_string());
        job.input_color_transfer = Some("bt709".to_string());
        job.input_color_range = Some("tv".to_string());

        let args = build_ffmpeg_args_for_test(&job);
        let pipe_input = args
            .windows(2)
            .position(|w| w[0] == "-i" && w[1] == "-")
            .expect("the Y4M pipe input");
        let y4m_format = args
            .windows(2)
            .position(|w| w[0] == "-f" && w[1] == "yuv4mpegpipe")
            .expect("-f yuv4mpegpipe");
        let second_input = pipe_input
            + 2
            + args[pipe_input + 2..].iter().position(|a| a == "-i").expect("audio input");

        // Input options apply to the next -i only, so they must sit between the
        // pipe's -f and its -i, not before the format or after the input.
        let input_side = &args[y4m_format + 2..pipe_input];
        let output_side: Vec<String> = {
            let tail = &args[second_input + 2..];
            let flags = ["-colorspace", "-color_primaries", "-color_trc", "-color_range"];
            tail.windows(2)
                .filter(|w| flags.contains(&w[0].as_str()))
                .flat_map(|w| [w[0].clone(), w[1].clone()])
                .collect()
        };
        let expected = job.output_color_metadata().to_ffmpeg_output_args();
        assert_eq!(input_side, expected.as_slice(), "input declaration");
        assert_eq!(output_side, expected, "output tags");
    }

    /// `build_ffmpeg_args_for_test` duplicates `build_ffmpeg_args` rather than
    /// calling it (the real one needs a located deps bundle), so the test above
    /// only proves the copy. Pin the real function to the same shape by its
    /// source: the input declaration must come before the pipe's `-i`.
    #[test]
    fn test_real_ffmpeg_builder_declares_colour_on_the_pipe_input() {
        // A Windows checkout gives this file CRLF, and the end-of-function
        // pattern below spans a line break.
        let src = include_str!("pipeline_executor.rs").replace("\r\n", "\n");
        let start = src.find("fn build_ffmpeg_args(\n").expect("real builder");
        let body = &src[start..];
        let body = &body[..body.find("\n    }\n").expect("end of builder")];
        let declare = body.find("to_ffmpeg_input_args()").expect(
            "build_ffmpeg_args must declare the colour tags on the Y4M input",
        );
        let pipe_input = body
            .find(r#"args.extend(["-i".to_string(), "-".to_string()]);"#)
            .expect("pipe input");
        let y4m = body.find(r#""yuv4mpegpipe""#).expect("y4m format");
        assert!(
            y4m < declare && declare < pipe_input,
            "the input declaration must sit between -f yuv4mpegpipe and -i -"
        );
        assert!(
            body.contains("to_ffmpeg_output_args()"),
            "build_ffmpeg_args must still tag the output"
        );
        // Both sides describe what the SCRIPT delivers, which is not the
        // source's colour when it converts to BT.709.
        assert!(
            !body.contains("job.color_metadata().to_ffmpeg"),
            "the encoder must be told the output's colour, not the source's"
        );
    }

    /// An untagged source must stay untagged rather than being guessed at.
    #[test]
    fn test_untagged_source_declares_nothing() {
        let job = create_test_job("out.mkv");
        let args = build_ffmpeg_args_for_test(&job);
        for flag in ["-colorspace", "-color_primaries", "-color_trc", "-color_range"] {
            assert!(!args.iter().any(|a| a == flag), "{flag} should be absent");
        }
    }

    /// An SD BT.601 source resized to 1080 lines is converted to BT.709 by the
    /// script (app 1.7.0), so both sides of the encoder must say 709 — the
    /// source's 601 tags there would relabel the converted samples back.
    #[test]
    fn test_sd_to_hd_declares_the_converted_bt709_on_both_sides() {
        let mut job = create_test_job("out.mkv");
        job.input_width = Some(720);
        job.input_height = Some(576);
        job.input_color_matrix = Some("bt470bg".to_string());
        job.input_color_primaries = Some("bt470bg".to_string());
        job.input_color_range = Some("tv".to_string());
        let mut pipeline = crate::models::ProcessingPipeline::default();
        pipeline.deinterlace.enabled = false;
        pipeline.crop_resize.enabled = true;
        pipeline.crop_resize.resize_enabled = true;
        pipeline.crop_resize.target_width = Some(1920);
        pipeline.crop_resize.target_height = Some(1080);
        job.processing_pipeline = Some(pipeline.clone());
        let args = build_ffmpeg_args_for_test(&job);
        let pairs: Vec<(String, String)> = args
            .windows(2)
            .filter(|w| w[0] == "-colorspace" || w[0] == "-color_primaries" || w[0] == "-color_trc")
            .map(|w| (w[0].clone(), w[1].clone()))
            .collect();
        let expected = |flag: &str, v: &str| (flag.to_string(), v.to_string());
        assert_eq!(
            pairs,
            vec![
                expected("-colorspace", "bt709"),
                expected("-color_primaries", "bt470bg"),
                expected("-color_trc", "bt709"),
                expected("-colorspace", "bt709"),
                expected("-color_primaries", "bt470bg"),
                expected("-color_trc", "bt709"),
            ]
        );

        // Off: the source's tags, exactly as before the option existed.
        pipeline.crop_resize.convert_to_bt709 = crate::models::Bt709Conversion::Off;
        job.processing_pipeline = Some(pipeline);
        let args = build_ffmpeg_args_for_test(&job);
        assert_eq!(args.iter().filter(|a| *a == "bt470bg").count(), 4);
        assert!(!args.iter().any(|a| a == "bt709"));
    }

    /// ffprobe says "unknown" for an untagged stream; that must not be
    /// forwarded as if it were a value, or the encode fails on an argument the
    /// user can neither see nor fix.
    #[test]
    fn test_unknown_from_ffprobe_is_not_forwarded() {
        let mut job = create_test_job("out.mkv");
        job.input_color_matrix = Some("unknown".to_string());
        job.input_color_range = Some("unknown".to_string());
        let args = build_ffmpeg_args_for_test(&job);
        assert!(!args.iter().any(|a| a == "-colorspace"));
        assert!(!args.iter().any(|a| a == "-color_range"));
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

    /// Issue #74, end to end: the reported job was a CineForm `yuv422p10le`
    /// source at the default "Match source" colour format, encoded with
    /// h264_nvenc. With nothing forced, ffmpeg negotiated `yuv422p` (which the
    /// encoder advertises) and the RTX 4070 Super rejected it at open, so the
    /// job produced zero frames.
    #[test]
    fn test_nvenc_422_source_gets_an_encodable_pix_fmt() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H264Nvenc;
        job.input_pixel_format = Some("yuv422p10le".to_string());
        assert_eq!(
            job.encoding_settings.chroma_subsampling,
            ChromaSubsampling::Original,
            "the reported job used the default colour format"
        );

        let args = build_ffmpeg_args_for_test(&job);
        let idx = args
            .iter()
            .position(|a| a == "-pix_fmt")
            .expect("NVENC must not be left to negotiate a 4:2:2 source");
        assert_eq!(args[idx + 1], "yuv420p");
    }

    /// The same source into HEVC keeps its 10 bits — only the chroma has to go.
    #[test]
    fn test_hevc_nvenc_422_source_keeps_10_bits() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H265Nvenc;
        job.input_pixel_format = Some("yuv422p10le".to_string());

        let args = build_ffmpeg_args_for_test(&job);
        let idx = args.iter().position(|a| a == "-pix_fmt").unwrap();
        assert_eq!(args[idx + 1], "p010le");
    }

    /// Choosing a 4:2:2 output format explicitly is the other route to the same
    /// failure: the conversion is done by the `.vpy`, so the source format never
    /// enters into it.
    #[test]
    fn test_nvenc_422_output_format_is_also_guarded() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H265Nvenc;
        job.encoding_settings.chroma_subsampling = ChromaSubsampling::Yuv422P10;
        // An 8-bit 4:2:0 source — the pipeline is what makes it 4:2:2.
        job.input_pixel_format = Some("yuv420p".to_string());

        assert_eq!(job.encoder_input_pix_fmt(), "yuv422p10le");
        let args = build_ffmpeg_args_for_test(&job);
        let idx = args.iter().position(|a| a == "-pix_fmt").unwrap();
        assert_eq!(args[idx + 1], "p010le");
    }

    /// The ProRes pin has to reach the actual argument list, not just
    /// `forced_pix_fmt` — that is the whole point of it.
    #[test]
    fn test_prores_pin_reaches_the_args() {
        for (codec, expected) in [
            (VideoCodec::ProResProxy, "yuv422p10le"),
            (VideoCodec::ProResHQ, "yuv422p10le"),
        ] {
            let mut job = create_test_job("output.mov");
            job.encoding_settings.codec = codec;
            job.encoding_settings.container = ContainerFormat::Mov;
            job.input_pixel_format = Some("yuv420p".to_string());

            let args = build_ffmpeg_args_for_test(&job);
            let idx = args
                .iter()
                .position(|a| a == "-pix_fmt")
                .unwrap_or_else(|| panic!("{codec:?} emitted no -pix_fmt"));
            assert_eq!(args[idx + 1], expected, "{codec:?}");

            // And the profile still goes out alongside it.
            let p = args.iter().position(|a| a == "-profile:v").unwrap();
            assert_eq!(args[p + 1], codec.prores_profile().unwrap().to_string());
        }
    }

    /// The three advanced ProRes options must be absent unless asked for, so a
    /// job that does not use them produces exactly the command line it always
    /// did — and must be clamped when they are, because ffmpeg rejects an
    /// out-of-range `bits_per_mb` and kills the encode.
    #[test]
    fn test_prores_advanced_flags_are_emitted_only_when_set() {
        let base = || {
            let mut job = create_test_job("output.mov");
            job.encoding_settings.codec = VideoCodec::ProResHQ;
            job.encoding_settings.container = ContainerFormat::Mov;
            job
        };

        // Default: the profile, and none of the three.
        let args = build_ffmpeg_args_for_test(&base());
        assert!(args.contains(&"-profile:v".to_string()));
        for flag in ["-vendor", "-bits_per_mb", "-quant_mat"] {
            assert!(
                !args.contains(&flag.to_string()),
                "{flag} must not appear unless set"
            );
        }

        // Vendor tag.
        let mut job = base();
        job.encoding_settings.prores_vendor_apl0 = true;
        let args = build_ffmpeg_args_for_test(&job);
        let i = args.iter().position(|a| a == "-vendor").expect("-vendor");
        assert_eq!(args[i + 1], "apl0");

        // Bits per macroblock, in range.
        let mut job = base();
        job.encoding_settings.prores_bits_per_mb = Some(8000);
        let args = build_ffmpeg_args_for_test(&job);
        let i = args.iter().position(|a| a == "-bits_per_mb").unwrap();
        assert_eq!(args[i + 1], "8000");

        // Zero is the plugin's "use the profile default", which is what
        // omitting the option already does — so emit nothing rather than a
        // value that reads as a deliberate choice.
        let mut job = base();
        job.encoding_settings.prores_bits_per_mb = Some(0);
        let args = build_ffmpeg_args_for_test(&job);
        assert!(!args.contains(&"-bits_per_mb".to_string()));

        // Out of range is clamped, not forwarded: ffmpeg would reject it and
        // the whole encode would fail on an option the user cannot see.
        let mut job = base();
        job.encoding_settings.prores_bits_per_mb = Some(99_999);
        let args = build_ffmpeg_args_for_test(&job);
        let i = args.iter().position(|a| a == "-bits_per_mb").unwrap();
        assert_eq!(args[i + 1], PRORES_MAX_BITS_PER_MB.to_string());

        // Quantisation matrix.
        let mut job = base();
        job.encoding_settings.prores_quant_mat = Some(ProResQuantMat::Hq);
        let args = build_ffmpeg_args_for_test(&job);
        let i = args.iter().position(|a| a == "-quant_mat").unwrap();
        assert_eq!(args[i + 1], "hq");
    }

    /// The options are ProRes-only. Emitting them beside another encoder would
    /// be an ffmpeg error at best and a silently ignored option at worst.
    #[test]
    fn test_prores_advanced_flags_never_reach_another_encoder() {
        for codec in [VideoCodec::H264, VideoCodec::H265Nvenc, VideoCodec::FFV1] {
            let mut job = create_test_job("output.mkv");
            job.encoding_settings.codec = codec;
            job.encoding_settings.container = ContainerFormat::Mkv;
            job.encoding_settings.prores_vendor_apl0 = true;
            job.encoding_settings.prores_bits_per_mb = Some(8000);
            job.encoding_settings.prores_quant_mat = Some(ProResQuantMat::Hq);

            let args = build_ffmpeg_args_for_test(&job);
            for flag in ["-vendor", "-bits_per_mb", "-quant_mat"] {
                assert!(
                    !args.contains(&flag.to_string()),
                    "{codec:?} must not be given {flag}"
                );
            }
        }
    }

    /// The job log must not tell a ProRes user their encoder "cannot encode"
    /// a format it simply stores differently — and must say nothing at all when
    /// the pin costs them nothing, which is the common case.
    #[test]
    fn test_prores_pin_message_does_not_claim_a_loss() {
        // Padding 4:2:0 up to 4:2:2 loses nothing: stay quiet.
        assert_eq!(
            PipelineExecutor::pix_fmt_change_note(
                VideoCodec::ProResHQ,
                "yuv420p",
                "yuv422p10le"
            ),
            None
        );
        // Same format in and out: nothing to report either.
        assert_eq!(
            PipelineExecutor::pix_fmt_change_note(
                VideoCodec::ProRes422,
                "yuv422p10le",
                "yuv422p10le"
            ),
            None
        );

        // Dropping 4:4:4 to 4:2:2 is a real loss and must be reported — but as
        // what ProRes stores, not as an encoder limitation.
        let note = PipelineExecutor::pix_fmt_change_note(
            VideoCodec::ProResHQ,
            "yuv444p10le",
            "yuv422p10le",
        )
        .expect("a chroma reduction must be logged");
        assert!(note.contains("4:2:2"), "note should name the layout: {note}");
        assert!(note.contains("yuv444p10le") && note.contains("yuv422p10le"));
        assert!(
            !note.contains("cannot encode"),
            "ProRes can encode it; the profile decides the layout: {note}"
        );

        // A hardware encoder keeps the original wording, which is accurate there.
        let hw = PipelineExecutor::pix_fmt_change_note(
            VideoCodec::H265Nvenc,
            "yuv422p10le",
            "p010le",
        )
        .expect("a hardware substitution must be logged");
        assert!(hw.contains("cannot encode"), "{hw}");
    }

    /// A 4:2:0 source into NVENC must emit no `-pix_fmt` at all, so the fix
    /// changes nothing for the jobs that already worked.
    #[test]
    fn test_nvenc_420_source_is_untouched() {
        for fmt in ["yuv420p", "yuv420p10le"] {
            let mut job = create_test_job("output.mp4");
            job.encoding_settings.codec = VideoCodec::H265Nvenc;
            job.input_pixel_format = Some(fmt.to_string());

            let args = build_ffmpeg_args_for_test(&job);
            assert!(
                !args.contains(&"-pix_fmt".to_string()),
                "{fmt} is encodable; NVENC should negotiate it"
            );
        }
    }

    /// x264 handles 4:2:2 natively. Forcing a format here would throw away
    /// chroma the encoder was perfectly able to keep.
    #[test]
    fn test_software_encoder_keeps_422() {
        let mut job = create_test_job("output.mkv");
        job.encoding_settings.codec = VideoCodec::H264;
        job.input_pixel_format = Some("yuv422p10le".to_string());

        let args = build_ffmpeg_args_for_test(&job);
        assert!(!args.contains(&"-pix_fmt".to_string()));
    }

    /// Custom FFmpeg Arguments are appended last, so a user who knows their
    /// card really does have 4:2:2 can still ask for it — ffmpeg takes the
    /// later `-pix_fmt`. That is the escape hatch this guard relies on.
    #[test]
    fn test_custom_args_can_override_the_forced_format() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H264Nvenc;
        job.input_pixel_format = Some("yuv422p10le".to_string());
        job.encoding_settings.custom_ffmpeg_args = "-pix_fmt yuv422p".to_string();

        let args = build_ffmpeg_args_for_test(&job);
        let last = args
            .iter()
            .rposition(|a| a == "-pix_fmt")
            .expect("both formats should be present");
        assert_eq!(args[last + 1], "yuv422p", "the user's choice must win");
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

    /// v210: the codec, its one pixel format, and nothing a quality family
    /// would add — the data rate is fixed by the frame size.
    #[test]
    fn test_ffmpeg_args_v210() {
        for container in [ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi] {
            let mut job = create_test_job(&format!("output.{}", container.extension()));
            job.encoding_settings.codec = VideoCodec::V210;
            job.encoding_settings.container = container;
            job.input_pixel_format = Some("yuv420p".to_string());
            let args = build_ffmpeg_args_for_test(&job);

            let at = |flag: &str| args.iter().position(|a| a == flag);
            assert_eq!(args[at("-c:v").unwrap() + 1], "v210");
            assert_eq!(args[at("-pix_fmt").unwrap() + 1], "yuv422p10le");
            for absent in ["-crf", "-preset", "-profile:v", "-q:v", "-b:v", "-cq", "-qp_i", "-global_quality"] {
                assert!(at(absent).is_none(), "{container:?}: v210 must not get {absent}: {args:?}");
            }
            assert!(
                !args.iter().any(|a| a.contains("faststart")),
                "{container:?}: no faststart for v210 (a second full pass over a huge file)"
            );
        }
    }

    /// Faststart stays for every other codec in MP4/MOV.
    #[test]
    fn test_faststart_only_skipped_for_uncompressed() {
        for codec in VideoCodec::ALL.iter().copied() {
            assert_eq!(uses_faststart(codec), !codec.is_uncompressed(), "{codec:?}");
        }
        let mut job = create_test_job("output.mov");
        job.encoding_settings.codec = VideoCodec::ProResHQ;
        job.encoding_settings.container = ContainerFormat::Mov;
        assert!(build_ffmpeg_args_for_test(&job).contains(&"+faststart".to_string()));
    }

    /// The pipe already delivers 10-bit 4:2:2 for v210 (the script converts,
    /// field-aware), so the job log says nothing about a conversion.
    #[test]
    fn test_v210_pix_fmt_note() {
        assert_eq!(
            PipelineExecutor::pix_fmt_change_note(VideoCodec::V210, "yuv422p10le", "yuv422p10le"),
            None
        );
        assert_eq!(
            PipelineExecutor::pix_fmt_change_note(VideoCodec::V210, "yuv420p", "yuv422p10le"),
            None,
            "padding up loses nothing"
        );
        let note = PipelineExecutor::pix_fmt_change_note(VideoCodec::V210, "yuv444p10le", "yuv422p10le")
            .expect("4:4:4 down to 4:2:2 is said");
        assert!(note.contains("stores"), "{note}");
        assert!(!note.contains("cannot encode"), "{note}");
    }

    fn field_order_job(codec: VideoCodec, container: ContainerFormat) -> VideoJob {
        let mut job = create_test_job(&format!("output.{}", container.extension()));
        job.encoding_settings.codec = codec;
        job.encoding_settings.container = container;
        let mut pipeline = crate::models::ProcessingPipeline::default();
        pipeline.deinterlace.enabled = false;
        job.processing_pipeline = Some(pipeline);
        job
    }

    /// What each codec is expected to emit for a still-interlaced picture,
    /// written out per codec rather than read from `field_order_signal`, so
    /// this test is not the function restated. Exhaustive: a new codec fails
    /// to compile here until it is decided
    /// (docs/reports/2026-11-field-order-other-codecs).
    #[derive(Debug, Clone, Copy, PartialEq)]
    enum ExpectFieldOrder {
        Nothing,
        TopOnly,
        ProResFields,
        X264Mbaff,
    }

    fn expected_field_order(codec: VideoCodec) -> ExpectFieldOrder {
        use ExpectFieldOrder::*;
        match codec {
            VideoCodec::V210 | VideoCodec::FFV1 | VideoCodec::Huffyuv | VideoCodec::Ffvhuff => TopOnly,
            VideoCodec::ProResProxy
            | VideoCodec::ProResLT
            | VideoCodec::ProRes422
            | VideoCodec::ProResHQ
            | VideoCodec::ProRes4444
            | VideoCodec::ProRes4444Xq => ProResFields,
            VideoCodec::H264 => X264Mbaff,
            VideoCodec::H265
            | VideoCodec::H264Nvenc
            | VideoCodec::H265Nvenc
            | VideoCodec::H264Qsv
            | VideoCodec::H265Qsv
            | VideoCodec::H264Videotoolbox
            | VideoCodec::H265Videotoolbox
            | VideoCodec::H264Amf
            | VideoCodec::H265Amf => Nothing,
        }
    }

    /// Field order reaches the encoder only when the picture is still
    /// interlaced, on the pipe input (`-top`, ahead of `-i -`); ProRes and
    /// x264 alone code fields (`+ildct`), x264 names the order in
    /// `-x264-params`, and x265 / the hardware encoders get nothing. Every
    /// codec in every container.
    #[test]
    fn test_field_order_args_matrix() {
        use crate::models::FieldOrder;
        // (deinterlace on, detected order, stabilize pitch) -> expected top
        let cases: [(bool, Option<FieldOrder>, bool, Option<&str>); 6] = [
            (true, Some(FieldOrder::TopFieldFirst), false, None),
            (false, Some(FieldOrder::TopFieldFirst), false, Some("1")),
            (false, Some(FieldOrder::BottomFieldFirst), false, Some("0")),
            (false, Some(FieldOrder::Progressive), false, None),
            (false, None, false, None),
            (false, Some(FieldOrder::TopFieldFirst), true, None),
        ];
        let containers = [ContainerFormat::Mp4, ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi];
        for codec in VideoCodec::ALL.iter().copied() {
            let kind = expected_field_order(codec);
            assert_eq!(codec.flags_field_order(), kind != ExpectFieldOrder::Nothing, "{codec:?}");
            for container in containers {
                for (deint, order, pitch, expected) in cases {
                    let mut job = field_order_job(codec, container);
                    job.detected_field_order = order;
                    let p = job.processing_pipeline.as_mut().unwrap();
                    p.deinterlace.enabled = deint;
                    if pitch {
                        p.stabilize.enabled = true;
                        p.stabilize.pitch_mode = crate::models::PitchMode::Auto;
                    }
                    let args = build_ffmpeg_args_for_test(&job);
                    let ctx = format!("{codec:?} {container:?} deint={deint} {order:?} pitch={pitch}: {args:?}");
                    let has = |a: &str| args.iter().any(|x| x == a);
                    let x264_params = args
                        .iter()
                        .position(|a| a == "-x264-params")
                        .map(|i| args[i + 1].clone());
                    let expected = if kind == ExpectFieldOrder::Nothing { None } else { expected };
                    match expected {
                        Some(v) => {
                            let top = args.iter().position(|a| a == "-top").expect(&ctx);
                            let pipe = args.windows(2).position(|w| w[0] == "-i" && w[1] == "-").unwrap();
                            assert_eq!(args[top + 1], v, "{ctx}");
                            assert!(top < pipe, "-top must be an input option of the pipe: {ctx}");
                            let fields = matches!(kind, ExpectFieldOrder::ProResFields | ExpectFieldOrder::X264Mbaff);
                            assert_eq!(has("+ildct"), fields, "{ctx}");
                            if fields {
                                let f = args.iter().position(|a| a == "+ildct").unwrap();
                                assert!(f > pipe && args[f - 1] == "-flags", "+ildct is an encoder option: {ctx}");
                            }
                            let want = (kind == ExpectFieldOrder::X264Mbaff)
                                .then(|| if v == "1" { "tff=1" } else { "bff=1" }.to_string());
                            assert_eq!(x264_params, want, "{ctx}");
                        }
                        None => {
                            assert!(!has("-top"), "{ctx}");
                            assert!(!has("+ildct"), "{ctx}");
                            assert_eq!(x264_params, None, "{ctx}");
                        }
                    }
                    // Never the inert output option, never x265's interlace
                    // mode (it declares each woven frame a single field).
                    assert!(!has("-field_order"), "{ctx}");
                    assert!(!args.iter().any(|a| a.contains("interlace")), "{ctx}");
                }
            }
        }
    }

    /// The job log says so when a still-interlaced picture goes out
    /// unflagged: x265, the hardware encoders, and the container-only codecs
    /// in AVI (FFV1's own bitstream carries it there). Never for a picture
    /// that is progressive.
    #[test]
    fn test_field_order_note() {
        use crate::models::FieldOrder;
        let containers = [ContainerFormat::Mp4, ContainerFormat::Mov, ContainerFormat::Mkv, ContainerFormat::Avi];
        for codec in VideoCodec::ALL.iter().copied() {
            let kind = expected_field_order(codec);
            for container in containers {
                for order in [FieldOrder::TopFieldFirst, FieldOrder::BottomFieldFirst] {
                    let mut job = field_order_job(codec, container);
                    job.detected_field_order = Some(order);
                    let note = field_order_note(&job);
                    let expect = kind == ExpectFieldOrder::Nothing
                        || (kind == ExpectFieldOrder::TopOnly
                            && container == ContainerFormat::Avi
                            && codec != VideoCodec::FFV1);
                    assert_eq!(note.is_some(), expect, "{codec:?} {container:?}: {note:?}");
                    if let Some(n) = note {
                        assert!(n.contains(codec.display_name()), "{n}");
                    }
                    // Deinterlaced, or never interlaced: nothing to say.
                    job.processing_pipeline.as_mut().unwrap().deinterlace.enabled = true;
                    assert_eq!(field_order_note(&job), None, "{codec:?} {container:?}");
                    job.processing_pipeline.as_mut().unwrap().deinterlace.enabled = false;
                    job.detected_field_order = Some(FieldOrder::Progressive);
                    assert_eq!(field_order_note(&job), None, "{codec:?} {container:?}");
                }
            }
        }
    }

    /// The real builder takes field order from the same helper, on the pipe.
    #[test]
    fn test_real_ffmpeg_builder_declares_field_order_on_the_pipe() {
        let src = include_str!("pipeline_executor.rs").replace("\r\n", "\n");
        let start = src.find("fn build_ffmpeg_args(\n").expect("real builder");
        let body = &src[start..];
        let body = &body[..body.find("\n    }\n").expect("end of builder")];
        let helper = body.find("field_order_args(job)").expect("field order helper");
        let input = body.find("field_order.input").expect("input args");
        let pipe = body
            .find(r#"args.extend(["-i".to_string(), "-".to_string()]);"#)
            .expect("pipe input");
        assert!(helper < input && input < pipe, "-top belongs before -i -");
        assert!(body.contains("field_order.encoder"), "ProRes/x264 +ildct");
        assert!(body.contains("field_order_note(job)"), "the job log says when it cannot");
        assert!(body.contains("uses_faststart(settings.codec)"));
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

        let qp_b_idx = args.iter().position(|a| a == "-qp_b");
        assert!(qp_b_idx.is_some(), "AMF should pin -qp_b too (issue #51)");
        assert_eq!(args[qp_b_idx.unwrap() + 1], "20");

        let quality_idx = args.iter().position(|a| a == "-quality");
        assert!(quality_idx.is_some(), "AMF should use -quality");
        assert_eq!(args[quality_idx.unwrap() + 1], "balanced");

        assert!(!args.contains(&"-crf".to_string()), "AMF should not use -crf");
    }

    /// Issue #51: left to negotiate, a >8-bit source reaches AMF as p010 and
    /// 10-bit HEVC encode only exists on some AMD ASICs — elsewhere the runtime
    /// faults rather than failing cleanly. Pin the format both encoders always
    /// support.
    #[test]
    fn test_ffmpeg_args_amf_forces_nv12() {
        for codec in [VideoCodec::H264Amf, VideoCodec::H265Amf] {
            let mut job = create_test_job("output.mp4");
            job.encoding_settings.codec = codec;

            let args = build_ffmpeg_args_for_test(&job);

            let idx = args.iter().position(|a| a == "-pix_fmt");
            assert!(idx.is_some(), "{:?} should force a pixel format", codec);
            assert_eq!(args[idx.unwrap() + 1], "nv12", "codec {:?}", codec);
        }
    }

    /// A preset from another encoder family (a saved preset carrying x264's
    /// "medium", say) must not reach ffmpeg — it rejects the option and the
    /// whole encode fails. Each family falls back to its own default instead.
    #[test]
    fn test_ffmpeg_args_foreign_preset_falls_back() {
        let cases = [
            (VideoCodec::H264Amf, "-quality", "balanced"),
            (VideoCodec::H264Nvenc, "-preset", "p4"),
            (VideoCodec::H264Qsv, "-preset", "medium"),
        ];

        for (codec, flag, expected) in cases {
            let mut job = create_test_job("output.mp4");
            job.encoding_settings.codec = codec;
            // "placebo" is x264-only — meaningless to every hardware family.
            job.encoding_settings.encoder_preset = "placebo".to_string();

            let args = build_ffmpeg_args_for_test(&job);
            let idx = args.iter().position(|a| a == flag);
            assert!(idx.is_some(), "{:?} should pass {}", codec, flag);
            assert_eq!(args[idx.unwrap() + 1], expected, "codec {:?}", codec);
        }
    }

    /// A preset the encoder *does* accept passes through untouched.
    #[test]
    fn test_ffmpeg_args_valid_preset_preserved() {
        let mut job = create_test_job("output.mp4");
        job.encoding_settings.codec = VideoCodec::H265Amf;
        job.encoding_settings.encoder_preset = "speed".to_string();

        let args = build_ffmpeg_args_for_test(&job);
        let idx = args.iter().position(|a| a == "-quality").unwrap();
        assert_eq!(args[idx + 1], "speed");

        // Software x264 keeps its own vocabulary.
        let mut sw = create_test_job("output.mp4");
        sw.encoding_settings.codec = VideoCodec::H264;
        sw.encoding_settings.encoder_preset = "veryslow".to_string();
        let sw_args = build_ffmpeg_args_for_test(&sw);
        let sw_idx = sw_args.iter().position(|a| a == "-preset").unwrap();
        assert_eq!(sw_args[sw_idx + 1], "veryslow");
    }
}
