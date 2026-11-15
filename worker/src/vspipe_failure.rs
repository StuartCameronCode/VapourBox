//! Which process a failed encode blames, and what vspipe said (task #28).
//!
//! The encode is `decoder | vspipe | ffmpeg`. When the encoder ffmpeg fails on
//! its own (an unavailable hardware encoder, a bad Custom FFmpeg Argument),
//! vspipe dies of SIGPIPE as a symptom, so the encoder's error is reported
//! first. The reverse used to be lost: when vspipe fails *before writing the
//! Y4M header* — a Python exception while the script is evaluated, a script
//! with no output, a native crash in a plugin — the encoder reads an empty pipe
//! and says only `Header too large`, and that was what the user saw. The cause,
//! including the templates' own deliberate refusals, was in debug logs only.
//!
//! [`blame`] is the one decision; [`vspipe_failure_message`] turns vspipe's
//! stderr into the job error. Both are pure, so they are tested against stderr
//! recorded from the real bundle (docs/ENGINEERING_NOTES.md, 2026-11-15).

use std::collections::VecDeque;

/// How many of vspipe's last stderr lines are kept for the job error. A
/// traceback through havsfunc (QTGMC → Bob → fmtc) runs to several frames of
/// two lines each, and the summary needs its last line.
pub const VSPIPE_TAIL_LINES: usize = 80;

/// The most traceback lines a job error carries. The summary is the first
/// line; this is context for whoever reads the log.
const TRACEBACK_LINES: usize = 30;

/// Add one vspipe stderr line to the bounded tail kept for the job error.
/// Drops empty lines and `INPUT_INFO:` (our own frame-count report) and strips
/// a Windows `\r`.
pub fn push_tail(tail: &mut VecDeque<String>, line: &str, cap: usize) {
    let line = line.trim_end_matches('\r');
    if line.trim().is_empty() || line.starts_with("INPUT_INFO:") {
        return;
    }
    tail.push_back(line.to_string());
    while tail.len() > cap {
        tail.pop_front();
    }
}

/// True if the encoder ffmpeg never received a Y4M header: vspipe wrote
/// nothing before its output closed.
pub fn encoder_got_no_header(encoder_tail: &str) -> bool {
    encoder_tail.contains("Header too large") || encoder_tail.contains("Error opening input file -.")
}

/// Which process's failure the job reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Blame {
    Encoder,
    Vspipe,
    Neither,
}

/// Decide whose error a finished encode reports.
///
/// `vspipe_failed` must already exclude SIGPIPE and the codes that mean a
/// closed pipe or an interrupt. The encoder still comes first, except when it
/// only failed because vspipe wrote nothing: all three conditions are needed.
/// On Windows a vspipe whose encoder died first exits 1 with an `fwrite()`
/// error rather than by SIGPIPE, and must not hide the encoder's real error —
/// which it can't, since an encoder that failed by itself never says
/// "Header too large".
pub fn blame(encoder_failed: bool, encoder_tail: &str, vspipe_failed: bool) -> Blame {
    if encoder_failed && vspipe_failed && encoder_got_no_header(encoder_tail) {
        Blame::Vspipe
    } else if encoder_failed {
        Blame::Encoder
    } else if vspipe_failed {
        Blame::Vspipe
    } else {
        Blame::Neither
    }
}

/// The job error for a failed vspipe.
///
/// `status` is `format_exit_status`'s text; `crashed` is true when the status
/// is a signal or a Windows crash code (a native crash, which prints no
/// Python error); `tail` is vspipe's last stderr lines.
pub fn vspipe_failure_message(status: &str, crashed: bool, tail: &str) -> String {
    let lines: Vec<&str> = tail.lines().map(|l| l.trim_end_matches('\r')).collect();
    let exited = format!("(vspipe exited with {})", status);

    // A Python exception while the script was evaluated.
    if lines.iter().any(|l| l.trim_start().starts_with("Script evaluation failed")) {
        let reason = lines
            .iter()
            .rev()
            .find_map(|l| l.trim_start().strip_prefix("Python exception:"))
            .map(str::trim)
            .filter(|r| !r.is_empty())
            .map(str::to_string)
            .or_else(|| last_exception_line(&lines))
            .unwrap_or_else(|| "see the traceback below".to_string());
        return with_traceback(format!("The VapourSynth script failed: {}", reason), &lines, &exited);
    }

    // An exception, or a filter's error, while a frame was being made.
    if let Some(pos) = lines.iter().rposition(|l| l.contains("Failed to retrieve frame ")) {
        let line = lines[pos];
        let after = &line[line.find("Failed to retrieve frame ").unwrap() + "Failed to retrieve frame ".len()..];
        let frame: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
        let inline = line
            .split_once("with error:")
            .map(|(_, e)| e.trim())
            .filter(|e| !e.is_empty())
            .map(str::to_string);
        let reason = inline
            .or_else(|| last_exception_line(&lines[pos..]))
            .unwrap_or_else(|| "see the traceback below".to_string());
        let summary = if frame.is_empty() {
            format!("VapourSynth failed on a frame: {}", reason)
        } else {
            format!("VapourSynth failed on output frame {}: {}", frame, reason)
        };
        return with_traceback(summary, &lines, &exited);
    }

    // vspipe's own error line (no output node, an output Y4M can't carry, …).
    if let Some(line) = lines.iter().rev().find(|l| {
        let t = l.trim_start();
        t.starts_with("Error:") || t.starts_with("Failed to retrieve output node")
    }) {
        return format!("vspipe failed: {}\n{}", line.trim(), exited);
    }

    let mut message = format!("vspipe exited with {}", status);
    if crashed {
        message.push_str(
            " — a native crash inside vspipe or a plugin; no Python error was printed",
        );
    }
    let context: Vec<&str> = lines
        .iter()
        .copied()
        .filter(|l| !is_progress_trailer(l))
        .collect();
    if !context.is_empty() {
        let start = context.len().saturating_sub(10);
        message.push_str(":\n");
        message.push_str(&context[start..].join("\n"));
    }
    message
}

/// vspipe's closing statistics line, which says nothing about the failure.
fn is_progress_trailer(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("Output ") && t.contains(" frames in ")
}

/// The last line of the last traceback: the exception type and message
/// (`RuntimeError: …`), the first unindented line after the frames.
fn last_exception_line(lines: &[&str]) -> Option<String> {
    let start = lines
        .iter()
        .rposition(|l| l.trim_start().starts_with("Traceback (most recent call last)"))?;
    lines[start + 1..]
        .iter()
        .rev()
        .find(|l| !l.trim().is_empty() && !l.starts_with(' ') && !l.starts_with('\t') && !is_progress_trailer(l))
        .map(|l| l.trim().to_string())
}

/// `summary`, then the last traceback (bounded), then the exit status.
fn with_traceback(summary: String, lines: &[&str], exited: &str) -> String {
    let mut out = summary;
    if let Some(start) = lines
        .iter()
        .rposition(|l| l.trim_start().starts_with("Traceback (most recent call last)"))
    {
        let body: Vec<&str> = lines[start..]
            .iter()
            .copied()
            .filter(|l| !l.trim().is_empty() && !is_progress_trailer(l))
            .collect();
        let shown = if body.len() > TRACEBACK_LINES {
            let mut v = vec![body[0], "  …"];
            v.extend_from_slice(&body[body.len() - (TRACEBACK_LINES - 2)..]);
            v
        } else {
            body
        };
        out.push_str("\n\n");
        out.push_str(&shown.join("\n"));
    }
    out.push('\n');
    out.push_str(exited);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // Recorded on macOS arm64, deps 1.16.0 (VapourSynth R78, FFmpeg 9.0),
    // 2026-11-15, with `vspipe -c y4m job.vpy - | ffmpeg -f yuv4mpegpipe -i - …`.
    // The scratch path of the script is normalised to /tmp/vb_job.vpy.

    /// The encoder's stderr whenever vspipe wrote nothing (exit 234 on macOS).
    const ENCODER_NO_HEADER: &str = "[in#0 @ 0x121004330] Header too large.\n\
        [in#0 @ 0x121004200] Error opening input: Invalid argument\n\
        Error opening input file -.\n\
        Error opening input files: Invalid argument";

    /// `fmtc.bitdepth(bits=14)`: task #23's trigger, at script evaluation.
    const BITDEPTH: &str = r#"Script evaluation failed:
Python exception: bitdepth: output pixel bitdepth not supported.

Traceback (most recent call last):
  File "vapoursynth.pyx", line 3832, in vapoursynth._vpy_evaluate
  File "vapoursynth.pyx", line 3833, in vapoursynth._vpy_evaluate
  File "/tmp/vb_job.vpy", line 4, in <module>
    c = core.fmtc.bitdepth(c, bits=14)
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "vapoursynth.pyx", line 3559, in vapoursynth.Function.__call__
vapoursynth.Error: bitdepth: output pixel bitdepth not supported.
"#;

    const CUSTOM_RAISE: &str = r#"Script evaluation failed:
Python exception: custom code says no

Traceback (most recent call last):
  File "vapoursynth.pyx", line 3832, in vapoursynth._vpy_evaluate
  File "vapoursynth.pyx", line 3833, in vapoursynth._vpy_evaluate
  File "/tmp/vb_job.vpy", line 6, in <module>
    helper()
  File "/tmp/vb_job.vpy", line 5, in helper
    raise ValueError("custom code says no")
ValueError: custom code says no
"#;

    const SYNTAX: &str = r#"Script evaluation failed:
Python exception: '(' was never closed (syntax.vpy, line 3)

Traceback (most recent call last):
  File "vapoursynth.pyx", line 3824, in vapoursynth._vpy_evaluate
  File "/tmp/vb_job.vpy", line 3
    c = core.std.BlankClip(format=vs.YUV420P8, length=100
                          ^
SyntaxError: '(' was never closed
"#;

    const NO_OUTPUT: &str = "Failed to retrieve output node. Invalid index specified?";

    const RGB_OUTPUT: &str = "Error: can only apply y4m headers to YUV and Gray format clips without alpha\n\
        Output 10 frames in 2569165.87 seconds (0.00 fps)";

    /// An exception on frame 50 of 100; the encoder exited 0 with 50 frames.
    const FRAME_TIME: &str = r#"Error: Failed to retrieve frame 50 with error:
Traceback (most recent call last):
  File "vapoursynth.pyx", line 3652, in vapoursynth.publicFunction
  File "vapoursynth.pyx", line 3654, in vapoursynth.publicFunction
  File "vapoursynth.pyx", line 932, in vapoursynth.FuncData.__call__
  File "/tmp/vb_job.vpy", line 6, in bad
    raise RuntimeError("frame-time failure")
RuntimeError: frame-time failure

Output 97 frames in 0.06 seconds (1646.73 fps)
"#;

    fn first_line(s: &str) -> &str {
        s.lines().next().unwrap()
    }

    #[test]
    fn the_encoder_is_blamed_unless_it_only_saw_an_empty_pipe() {
        // Task #23's job: vspipe failed at evaluation, ffmpeg read nothing.
        assert_eq!(blame(true, ENCODER_NO_HEADER, true), Blame::Vspipe);
        // A failed hardware encoder: vspipe died of SIGPIPE (not "failed").
        let unknown = "[vost#0:0 @ 0x1] Unknown encoder 'h264_qsv'\nError selecting an encoder";
        assert_eq!(blame(true, unknown, false), Blame::Encoder);
        // Windows: vspipe exits 1 with a write error when the encoder dies
        // first. The encoder's own error must still win.
        assert_eq!(blame(true, unknown, true), Blame::Encoder);
        // No header but vspipe ended cleanly or by SIGPIPE: nothing better to say.
        assert_eq!(blame(true, ENCODER_NO_HEADER, false), Blame::Encoder);
        // A frame-time exception: the encoder finished with what it got.
        assert_eq!(blame(false, "", true), Blame::Vspipe);
        assert_eq!(blame(false, "", false), Blame::Neither);
    }

    #[test]
    fn encoder_no_header_is_recognised_by_either_line() {
        assert!(encoder_got_no_header(ENCODER_NO_HEADER));
        assert!(encoder_got_no_header("[in#0 @ 0x1] Header too large."));
        assert!(encoder_got_no_header("Error opening input file -."));
        assert!(!encoder_got_no_header("Unknown encoder 'h264_qsv'"));
    }

    #[test]
    fn a_script_evaluation_error_names_the_python_exception() {
        let m = vspipe_failure_message("exit code 1", false, BITDEPTH);
        assert_eq!(
            first_line(&m),
            "The VapourSynth script failed: bitdepth: output pixel bitdepth not supported."
        );
        assert!(m.contains("File \"/tmp/vb_job.vpy\", line 4, in <module>"));
        assert!(m.contains("c = core.fmtc.bitdepth(c, bits=14)"));
        assert!(m.ends_with("(vspipe exited with exit code 1)"));
        assert!(!m.contains("Script evaluation failed"));

        let m = vspipe_failure_message("exit code 1", false, CUSTOM_RAISE);
        assert_eq!(first_line(&m), "The VapourSynth script failed: custom code says no");
        assert!(m.contains("raise ValueError(\"custom code says no\")"));

        let m = vspipe_failure_message("exit code 1", false, SYNTAX);
        assert_eq!(
            first_line(&m),
            "The VapourSynth script failed: '(' was never closed (syntax.vpy, line 3)"
        );
    }

    #[test]
    fn a_frame_time_error_names_the_frame_and_the_exception() {
        let m = vspipe_failure_message("exit code 1", false, FRAME_TIME);
        assert_eq!(
            first_line(&m),
            "VapourSynth failed on output frame 50: RuntimeError: frame-time failure"
        );
        assert!(m.contains("File \"/tmp/vb_job.vpy\", line 6, in bad"));
        assert!(!m.contains("Output 97 frames"));
    }

    #[test]
    fn a_native_filter_error_on_a_frame_is_taken_from_the_same_line() {
        let tail = "Error: Failed to retrieve frame 7 with error: Resize error: bad things\n\
                    Output 7 frames in 0.10 seconds (70.00 fps)";
        let m = vspipe_failure_message("exit code 1", false, tail);
        assert_eq!(first_line(&m), "VapourSynth failed on output frame 7: Resize error: bad things");
    }

    #[test]
    fn vspipe_own_errors_are_quoted() {
        let m = vspipe_failure_message("exit code 1", false, NO_OUTPUT);
        assert_eq!(first_line(&m), "vspipe failed: Failed to retrieve output node. Invalid index specified?");
        let m = vspipe_failure_message("exit code 1", false, RGB_OUTPUT);
        assert_eq!(
            first_line(&m),
            "vspipe failed: Error: can only apply y4m headers to YUV and Gray format clips without alpha"
        );
    }

    #[test]
    fn a_native_crash_says_so() {
        let win = "exit code -1073741819 — access violation inside vspipe or a plugin \
                   (a native crash, not a script error)";
        let m = vspipe_failure_message(win, true, "");
        assert!(m.starts_with(&format!("vspipe exited with {}", win)));
        assert!(m.contains("no Python error was printed"));

        let m = vspipe_failure_message("signal 11 (SIGSEGV)", true, "");
        assert_eq!(
            m,
            "vspipe exited with signal 11 (SIGSEGV) — a native crash inside vspipe or a plugin; \
             no Python error was printed"
        );
        // An ordinary exit code with no text is not dressed up as a crash.
        assert_eq!(vspipe_failure_message("exit code 1", false, ""), "vspipe exited with exit code 1");
    }

    #[test]
    fn windows_line_endings_give_the_same_message() {
        let crlf = BITDEPTH.replace('\n', "\r\n");
        assert_eq!(
            vspipe_failure_message("exit code 1", false, &crlf),
            vspipe_failure_message("exit code 1", false, BITDEPTH)
        );
        // Lines arrive one at a time through push_tail, which strips the `\r`.
        let mut tail = VecDeque::new();
        for line in crlf.split('\n') {
            push_tail(&mut tail, line, VSPIPE_TAIL_LINES);
        }
        let joined = tail.into_iter().collect::<Vec<_>>().join("\n");
        assert!(!joined.contains('\r'));
        assert_eq!(
            first_line(&vspipe_failure_message("exit code 1", false, &joined)),
            "The VapourSynth script failed: bitdepth: output pixel bitdepth not supported."
        );
    }

    #[test]
    fn a_long_traceback_is_bounded_and_keeps_its_end() {
        let mut tail = String::from("Script evaluation failed:\nPython exception: deep\n\nTraceback (most recent call last):\n");
        for i in 0..100 {
            tail.push_str(&format!("  File \"havsfunc.py\", line {i}, in f{i}\n    f{}()\n", i + 1));
        }
        tail.push_str("vapoursynth.Error: deep\n");
        let m = vspipe_failure_message("exit code 1", false, &tail);
        assert!(m.lines().count() <= TRACEBACK_LINES + 4, "{} lines", m.lines().count());
        assert!(m.contains("vapoursynth.Error: deep"));
        assert!(m.contains("Traceback (most recent call last):"));
    }

    #[test]
    fn push_tail_keeps_the_last_lines_that_matter() {
        let mut tail = VecDeque::new();
        push_tail(&mut tail, "INPUT_INFO:frames=100,fps_num=25,fps_den=1", 3);
        push_tail(&mut tail, "", 3);
        push_tail(&mut tail, "   ", 3);
        for i in 0..5 {
            push_tail(&mut tail, &format!("line {i}\r"), 3);
        }
        assert_eq!(tail, VecDeque::from(vec!["line 2".to_string(), "line 3".into(), "line 4".into()]));
    }
}
