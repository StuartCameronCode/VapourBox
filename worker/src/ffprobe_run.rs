//! One way to run an ffprobe whose answer decides a source's facts, saying
//! why it failed and retrying a transient failure (task #83).
//!
//! The source model's probes used to send ffprobe's stderr to null and turn
//! any failure into `None`, which the frame count read as "no edit-list
//! discards" or "no last picture" and silently fell back to `nb_frames`.
//! On Windows CI `small_clip.mp4` once counted 3154 (stored) instead of
//! 3151 (decoded) that way, with nothing in any log to say which probe
//! dropped out or why (docs/reports/task-83-mp4-tail-probe-flake).

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fmt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

/// How many times a count-deciding probe is run before it is given up.
pub const PROBE_ATTEMPTS: usize = 3;

/// The pauses between attempts (one fewer than [`PROBE_ATTEMPTS`]).
pub const RETRY_DELAYS: [Duration; 2] = [Duration::from_millis(100), Duration::from_millis(300)];

/// The most of ffprobe's stderr a failure keeps (its end).
const STDERR_KEEP: usize = 2048;

/// Why an ffprobe run gave no usable answer.
#[derive(Debug, Clone, PartialEq)]
pub enum ProbeFailure {
    /// The process could not be started.
    Spawn(String),
    /// It exited unsuccessfully: its status (decoded, so a Windows
    /// `0xC0000142` reads as a name) and the end of its stderr.
    Exit { status: String, stderr: String },
    /// It exited 0 with nothing on stdout (or nothing the probe can use).
    Empty { stderr: String },
    /// It exited 0 with output that could not be parsed.
    Unreadable { detail: String, stderr: String },
}

impl fmt::Display for ProbeFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let tail = |s: &str| if s.trim().is_empty() { String::new() } else { format!(": {}", s.trim()) };
        match self {
            ProbeFailure::Spawn(e) => write!(f, "ffprobe could not be started ({e})"),
            ProbeFailure::Exit { status, stderr } => write!(f, "ffprobe exited with {status}{}", tail(stderr)),
            ProbeFailure::Empty { stderr } => write!(f, "ffprobe exited 0 with no usable output{}", tail(stderr)),
            ProbeFailure::Unreadable { detail, stderr } => {
                write!(f, "ffprobe's output could not be read ({detail}){}", tail(stderr))
            }
        }
    }
}

impl std::error::Error for ProbeFailure {}

fn stderr_tail(bytes: &[u8]) -> String {
    let start = bytes.len().saturating_sub(STDERR_KEEP);
    String::from_utf8_lossy(&bytes[start..]).trim().to_string()
}

/// An exit status as a failure line: the code, and for a Windows NTSTATUS
/// its hex form and name, or the signal on Unix. A process that dies before
/// `main` (a DLL that would not initialise when many start at once) shows
/// only this.
fn describe_status(status: &std::process::ExitStatus) -> String {
    if let Some(code) = status.code() {
        return describe_code(code);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(sig) = status.signal() {
            return format!("signal {sig}");
        }
    }
    "an unknown status".to_string()
}

fn describe_code(code: i32) -> String {
    let name = match code as u32 {
        0xC000_0005 => Some("STATUS_ACCESS_VIOLATION"),
        0xC000_0135 => Some("STATUS_DLL_NOT_FOUND"),
        0xC000_0142 => Some("STATUS_DLL_INIT_FAILED"),
        0xC000_013A => Some("STATUS_CONTROL_C_EXIT"),
        0xC000_0017 => Some("STATUS_NO_MEMORY"),
        0xC000_009A => Some("STATUS_INSUFFICIENT_RESOURCES"),
        _ => None,
    };
    match name {
        Some(n) => format!("exit code {code} (0x{:08X}, {n})", code as u32),
        None if code < 0 => format!("exit code {code} (0x{:08X})", code as u32),
        None => format!("exit code {code}"),
    }
}

/// Run `ffprobe args input` once: its stdout, or why there is none.
pub fn run<S: AsRef<OsStr>>(
    ffprobe: &Path,
    env: &HashMap<String, String>,
    args: &[S],
    input: &str,
) -> Result<Vec<u8>, ProbeFailure> {
    let out = Command::new(ffprobe)
        .args(args)
        .arg(input)
        .envs(env)
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| ProbeFailure::Spawn(e.to_string()))?;
    if !out.status.success() {
        return Err(ProbeFailure::Exit {
            status: describe_status(&out.status),
            stderr: stderr_tail(&out.stderr),
        });
    }
    if out.stdout.iter().all(u8::is_ascii_whitespace) {
        return Err(ProbeFailure::Empty { stderr: stderr_tail(&out.stderr) });
    }
    Ok(out.stdout)
}

/// [`run`], parsed as JSON.
pub fn run_json<S: AsRef<OsStr>>(
    ffprobe: &Path,
    env: &HashMap<String, String>,
    args: &[S],
    input: &str,
) -> Result<serde_json::Value, ProbeFailure> {
    parse_json(run(ffprobe, env, args, input)?)
}

/// ffprobe's stdout as JSON.
pub fn parse_json(stdout: Vec<u8>) -> Result<serde_json::Value, ProbeFailure> {
    serde_json::from_slice(&stdout)
        .map_err(|e| ProbeFailure::Unreadable { detail: e.to_string(), stderr: String::new() })
}

/// Run `attempt` up to [`PROBE_ATTEMPTS`] times, pausing `delays` between
/// tries, until it answers. Every failure is logged (`<what> failed (attempt
/// n of N): <reason>`), so a retried flake still leaves a trace; the last
/// failure is returned. A parsed answer is never re-asked.
pub fn retrying<T>(
    what: &str,
    delays: &[Duration],
    log: &(dyn Fn(&str) + Sync),
    mut attempt: impl FnMut() -> Result<T, ProbeFailure>,
) -> Result<T, ProbeFailure> {
    let mut n = 1;
    loop {
        match attempt() {
            Ok(v) => {
                if n > 1 {
                    log(&format!("{what} answered on attempt {n} of {PROBE_ATTEMPTS}"));
                }
                return Ok(v);
            }
            Err(e) => {
                log(&format!("{what} failed (attempt {n} of {PROBE_ATTEMPTS}): {e}"));
                if n >= PROBE_ATTEMPTS {
                    return Err(e);
                }
                if let Some(d) = delays.get(n - 1) {
                    std::thread::sleep(*d);
                }
                n += 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn exit() -> ProbeFailure {
        ProbeFailure::Exit { status: "exit code -1073741502 — STATUS_DLL_INIT_FAILED".into(), stderr: String::new() }
    }

    #[test]
    fn retrying_stops_at_the_first_answer_and_logs_each_failure() {
        let lines = Mutex::new(Vec::<String>::new());
        let log = |m: &str| lines.lock().unwrap().push(m.to_string());
        let mut calls = 0;
        let got = retrying("tail probe", &[], &log, || {
            calls += 1;
            if calls < 2 { Err(exit()) } else { Ok(7) }
        });
        assert_eq!(got, Ok(7));
        assert_eq!(calls, 2);
        let lines = lines.into_inner().unwrap();
        assert_eq!(lines.len(), 2, "{lines:?}");
        assert!(lines[0].starts_with("tail probe failed (attempt 1 of 3): ffprobe exited with exit code"));
        assert!(lines[1].contains("answered on attempt 2"));
    }

    #[test]
    fn retrying_gives_up_after_every_attempt_with_the_last_reason() {
        let log = |_: &str| {};
        let mut calls = 0;
        let got: Result<(), _> = retrying("head probe", &[], &log, || {
            calls += 1;
            Err(ProbeFailure::Empty { stderr: format!("try {calls}") })
        });
        assert_eq!(calls, PROBE_ATTEMPTS);
        assert_eq!(got, Err(ProbeFailure::Empty { stderr: "try 3".into() }));
    }

    #[test]
    fn a_failure_names_its_status_and_stderr() {
        let e = ProbeFailure::Exit { status: "exit code 1".into(), stderr: "Permission denied\n".into() };
        assert_eq!(e.to_string(), "ffprobe exited with exit code 1: Permission denied");
        assert_eq!(
            ProbeFailure::Empty { stderr: String::new() }.to_string(),
            "ffprobe exited 0 with no usable output"
        );
    }

    #[test]
    fn a_windows_status_is_named() {
        assert_eq!(describe_code(-1073741502), "exit code -1073741502 (0xC0000142, STATUS_DLL_INIT_FAILED)");
        assert_eq!(describe_code(1), "exit code 1");
        assert_eq!(describe_code(-2), "exit code -2 (0xFFFFFFFE)");
    }

    #[test]
    fn stderr_keeps_its_end() {
        let long = format!("{}END", "x".repeat(5000));
        let kept = stderr_tail(long.as_bytes());
        assert_eq!(kept.len(), STDERR_KEEP);
        assert!(kept.ends_with("END"));
    }
}
