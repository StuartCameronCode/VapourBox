//! A vspipe that has said its last word but does not exit (task #122).
//!
//! On Windows runners vspipe was seen stuck in `ExitProcess`
//! (`NtTerminateProcess`, its last thread suspended), so the worker's
//! `vspipe.wait()` never returned and the preview never came back. The
//! cause is Windows Defender's real-time protection: it suspends vspipe's
//! last thread during exit and does not resume it (347 of 3,000 previews
//! with it on, none with it off; docs/reports/task-122-vspipe-exit-hang).
//! vspipe does nothing wrong, so the fix is here. A vspipe that has printed
//! the line R78's `main` prints just
//! before it returns is given [`DEFAULT_GRACE`] to exit and is then stopped,
//! and the job says so. A vspipe that is still working is never touched: the
//! guard only starts counting at a final line.
//!
//! The final lines are R78's (`src/vspipe/vspipe.cpp`): `Output N frames in
//! …` / `Output N samples in …` after any output, the error lines of a
//! script, output node or header that `main` returns 1 after. A frame error
//! (`Error: Failed to retrieve frame …`) is *not* final: `outputNode` prints
//! it, and `main` then still prints `Output N frames`. So an `Output` line
//! does not mean the frames were written; [`FinalLine::saw_error`] says
//! whether any `Error:` line came before it.

use std::io;
use std::process::{Child, ExitStatus};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// How long a vspipe that printed its final line may take to exit.
/// A normal exit takes well under a second; this allows for a loaded machine
/// freeing a large graph.
pub const DEFAULT_GRACE: Duration = Duration::from_secs(30);

/// How long to wait for a killed vspipe to be gone before calling it
/// unkillable.
pub const KILL_WAIT: Duration = Duration::from_secs(10);

/// The environment variable that overrides [`DEFAULT_GRACE`], in seconds;
/// 0 waits forever.
pub const GRACE_ENV: &str = "VAPOURBOX_VSPIPE_EXIT_GRACE_SECS";

/// Which kind of final line vspipe printed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FinalKind {
    /// `Output N frames in …` / `Output N samples in …`.
    Output,
    /// An error `main` returns 1 after.
    Error,
}

/// Classify one line of vspipe's stderr: `Some` when R78's `main` prints it
/// just before returning.
pub fn final_kind(line: &str) -> Option<FinalKind> {
    let line = line.trim_end_matches(['\r', '\n']);
    if is_output_summary(line) {
        return Some(FinalKind::Output);
    }
    const ERROR_PREFIXES: &[&str] = &[
        "Script evaluation failed:",
        "Failed to retrieve output node",
        "Cannot output clips with varying dimensions",
        "Error: can't apply selected header type to video",
        "Error: can't apply apply selected header type to audio",
        "Error: can only apply y4m headers to",
        "Error: no y4m identifier exists for current format",
        "Error: fwrite() call failed when writing initial header",
        "Error: failed to write timecodes file header",
        "Error: failed to write JSON file header",
        "Error: failed to finalize JSON file",
        "Error: cannot create valid w64 header",
        "Error: cannot create valid wav header",
        "Failed to initialize VSScript",
        "Failed to get VapourSynth API pointer",
        "Failed to create core",
    ];
    ERROR_PREFIXES
        .iter()
        .any(|p| line.starts_with(p))
        .then_some(FinalKind::Error)
}

/// `Output <int> frames in <float> seconds` or `Output <int> samples in …`.
fn is_output_summary(line: &str) -> bool {
    let Some(rest) = line.strip_prefix("Output ") else { return false };
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    if digits == 0 {
        return false;
    }
    let rest = &rest[digits..];
    let Some(rest) = rest
        .strip_prefix(" frames in ")
        .or_else(|| rest.strip_prefix(" samples in "))
    else {
        return false;
    };
    let number = rest.bytes().take_while(|b| b.is_ascii_digit() || *b == b'.').count();
    number > 0 && rest[number..].starts_with(" seconds")
}

/// The final line vspipe printed, and when.
#[derive(Debug, Clone)]
pub struct FinalLine {
    pub at: Instant,
    pub line: String,
    pub kind: FinalKind,
    /// An `Error:` line came before it (a frame that failed: the output was
    /// not written, whatever the `Output` line says).
    pub saw_error: bool,
}

impl FinalLine {
    /// vspipe's own verdict: it finished its output with no error.
    pub fn finished_cleanly(&self) -> bool {
        self.kind == FinalKind::Output && !self.saw_error
    }
}

/// Shared between the thread reading vspipe's stderr and the one waiting
/// for it.
#[derive(Debug, Clone, Default)]
pub struct ExitGuard {
    inner: Arc<Mutex<GuardState>>,
}

#[derive(Debug, Default)]
struct GuardState {
    saw_error: bool,
    last: Option<FinalLine>,
}

impl ExitGuard {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed one line of vspipe's stderr. Returns the kind when it is final.
    pub fn observe(&self, line: &str) -> Option<FinalKind> {
        self.observe_at(line, Instant::now())
    }

    pub fn observe_at(&self, line: &str, now: Instant) -> Option<FinalKind> {
        let mut state = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if line.starts_with("Error:") {
            state.saw_error = true;
        }
        let kind = final_kind(line)?;
        let saw_error = state.saw_error;
        state.last = Some(FinalLine { at: now, line: line.trim_end().to_string(), kind, saw_error });
        Some(kind)
    }

    /// The final line, if vspipe has printed one.
    pub fn final_line(&self) -> Option<FinalLine> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).last.clone()
    }

    /// The final line, once it is at least `grace` old (`None` grace: never).
    pub fn overdue(&self, grace: Option<Duration>, now: Instant) -> Option<FinalLine> {
        let grace = grace?;
        self.final_line()
            .filter(|f| now.saturating_duration_since(f.at) >= grace)
    }
}

/// [`DEFAULT_GRACE`], or [`GRACE_ENV`]'s value; `None` (wait forever) for 0.
pub fn grace_from_env() -> Option<Duration> {
    grace_from(std::env::var(GRACE_ENV).ok().as_deref())
}

fn grace_from(value: Option<&str>) -> Option<Duration> {
    match value.map(|v| v.trim().parse::<u64>()) {
        Some(Ok(0)) => None,
        Some(Ok(secs)) => Some(Duration::from_secs(secs)),
        _ => Some(DEFAULT_GRACE),
    }
}

/// What can be waited for and killed: a [`Child`], or a fake in tests.
pub trait Waitable {
    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>>;
    fn kill(&mut self) -> io::Result<()>;
}

impl Waitable for Child {
    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        Child::try_wait(self)
    }
    fn kill(&mut self) -> io::Result<()> {
        Child::kill(self)
    }
}

/// How the wait for vspipe ended.
#[derive(Debug, Clone)]
pub enum ExitOutcome {
    /// It exited by itself.
    Exited(ExitStatus),
    /// It printed `line` and had not exited `waited` later, so it was killed;
    /// `status` is the killed process's status.
    KilledAfterFinal { line: FinalLine, waited: Duration, status: ExitStatus },
    /// It printed `line`, was killed `waited` later, and was still there
    /// [`KILL_WAIT`] after that.
    Unkillable { line: FinalLine, waited: Duration },
}

impl ExitOutcome {
    /// One line for the job log, for the outcomes the guard caused.
    pub fn note(&self) -> Option<String> {
        match self {
            ExitOutcome::Exited(_) => None,
            ExitOutcome::KilledAfterFinal { line, waited, .. } => Some(format!(
                "vspipe printed \"{}\" but had not exited {}s later; stopped it (task #122)",
                line.line,
                waited.as_secs()
            )),
            ExitOutcome::Unkillable { line, waited } => Some(format!(
                "vspipe printed \"{}\" but had not exited {}s later, and was still running \
                 {}s after it was stopped: Windows could not end the process (task #122)",
                line.line,
                waited.as_secs(),
                KILL_WAIT.as_secs()
            )),
        }
    }
}

/// Stop a vspipe that has been past its final line for `grace`; wait up to
/// `kill_wait` for it to go.
pub fn stop_overdue<C: Waitable>(
    child: &mut C,
    line: FinalLine,
    kill_wait: Duration,
    poll: Duration,
) -> io::Result<ExitOutcome> {
    let waited = line.at.elapsed();
    // An error here is "already exited" on every platform; the wait says.
    let _ = child.kill();
    let deadline = Instant::now() + kill_wait;
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(ExitOutcome::KilledAfterFinal { line, waited, status });
        }
        if Instant::now() >= deadline {
            return Ok(ExitOutcome::Unkillable { line, waited });
        }
        thread::sleep(poll);
    }
}

/// Wait for vspipe like `Child::wait`, except that once it has printed its
/// final line and `grace` has passed, it is killed (see the module docs).
pub fn wait_after_final<C: Waitable>(
    child: &mut C,
    guard: &ExitGuard,
    grace: Option<Duration>,
    kill_wait: Duration,
    poll: Duration,
) -> io::Result<ExitOutcome> {
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(ExitOutcome::Exited(status));
        }
        if let Some(line) = guard.overdue(grace, Instant::now()) {
            return stop_overdue(child, line, kill_wait, poll);
        }
        thread::sleep(poll);
    }
}

/// Join a reader thread, giving up after `limit`: a thread reading a pipe
/// an unkillable vspipe still holds would never end.
pub fn join_bounded<T>(handle: thread::JoinHandle<T>, limit: Duration) -> Option<T> {
    let deadline = Instant::now() + limit;
    while !handle.is_finished() {
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(5));
    }
    handle.join().ok()
}

/// The status text for vspipe's failure message when the guard stopped it.
pub fn stopped_status(status_text: &str, waited: Duration) -> String {
    format!("{status_text}, stopped {}s after its last line (task #122)", waited.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    // The format strings of R78's vspipe.cpp, as printed.
    #[test]
    fn output_summaries_are_final() {
        assert_eq!(final_kind("Output 1 frames in 0.42 seconds (2.38 fps)"), Some(FinalKind::Output));
        assert_eq!(final_kind("Output 1234 frames in 61.00 seconds (20.23 fps)\r\n"), Some(FinalKind::Output));
        assert_eq!(final_kind("Output 48000 samples in 0.10 seconds (480000.00 sps)"), Some(FinalKind::Output));
        assert_eq!(final_kind("Output 0 frames in inf seconds"), None);
        assert_eq!(final_kind("Output frames in 1.0 seconds"), None);
        assert_eq!(final_kind("Output 3 fields in 1.0 seconds"), None);
        assert_eq!(final_kind("  Output 1 frames in 0.4 seconds"), None);
    }

    #[test]
    fn main_error_returns_are_final() {
        for line in [
            "Script evaluation failed:",
            "Script evaluation failed:\nPython exception: boom",
            "Failed to retrieve output node. Invalid index specified?",
            "Cannot output clips with varying dimensions",
            "Error: can't apply selected header type to video",
            "Error: can only apply y4m headers to YUV and Gray format clips without alpha",
            "Error: no y4m identifier exists for current format",
            "Error: fwrite() call failed when writing initial header, errno: 32",
            "Failed to initialize VSScript. VSScript reported error: x",
            "Failed to create core",
        ] {
            assert_eq!(final_kind(line), Some(FinalKind::Error), "{line}");
        }
    }

    #[test]
    fn progress_and_frame_errors_are_not_final() {
        for line in [
            "Script evaluation done in 0.31 seconds",
            "Error: Failed to retrieve frame 0 with error: Traceback",
            "Error: fwrite() call failed when writing frame: 3, errno: 32",
            "INPUT_INFO:frames=10,fps_num=25,fps_den=1",
            "Information: VapourSynth Video Processing Library",
            "",
        ] {
            assert_eq!(final_kind(line), None, "{line}");
        }
    }

    #[test]
    fn an_output_line_after_a_frame_error_is_not_clean() {
        let guard = ExitGuard::new();
        assert_eq!(guard.observe("Error: Failed to retrieve frame 0 with error: x"), None);
        assert_eq!(guard.observe("Output 1 frames in 0.10 seconds (10.00 fps)"), Some(FinalKind::Output));
        let f = guard.final_line().unwrap();
        assert!(f.saw_error);
        assert!(!f.finished_cleanly());

        let clean = ExitGuard::new();
        clean.observe("Script evaluation done in 0.31 seconds");
        clean.observe("Output 1 frames in 0.10 seconds (10.00 fps)");
        assert!(clean.final_line().unwrap().finished_cleanly());
    }

    #[test]
    fn overdue_counts_from_the_final_line() {
        let guard = ExitGuard::new();
        let t0 = Instant::now();
        assert!(guard.overdue(Some(Duration::from_secs(30)), t0 + Duration::from_secs(99)).is_none());
        guard.observe_at("Output 1 frames in 0.10 seconds (10.00 fps)", t0);
        assert!(guard.overdue(Some(Duration::from_secs(30)), t0 + Duration::from_secs(29)).is_none());
        assert!(guard.overdue(Some(Duration::from_secs(30)), t0 + Duration::from_secs(30)).is_some());
        assert!(guard.overdue(None, t0 + Duration::from_secs(3600)).is_none());
    }

    #[test]
    fn grace_reads_the_environment_value() {
        assert_eq!(grace_from(None), Some(DEFAULT_GRACE));
        assert_eq!(grace_from(Some("5")), Some(Duration::from_secs(5)));
        assert_eq!(grace_from(Some(" 12 ")), Some(Duration::from_secs(12)));
        assert_eq!(grace_from(Some("0")), None);
        assert_eq!(grace_from(Some("soon")), Some(DEFAULT_GRACE));
    }

    /// A process that never exits by itself; `dies_on_kill` says whether a
    /// kill ends it.
    struct Fake {
        dies_on_kill: bool,
        killed: bool,
        status: ExitStatus,
    }

    impl Waitable for Fake {
        fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
            Ok((self.killed && self.dies_on_kill).then_some(self.status))
        }
        fn kill(&mut self) -> io::Result<()> {
            self.killed = true;
            Ok(())
        }
    }

    fn some_status() -> ExitStatus {
        std::process::Command::new(if cfg!(windows) { "cmd" } else { "true" })
            .args(if cfg!(windows) { &["/C", "exit 0"][..] } else { &[][..] })
            .status()
            .unwrap()
    }

    const MS: Duration = Duration::from_millis(1);

    #[test]
    fn a_running_vspipe_is_left_alone_until_its_final_line() {
        let guard = ExitGuard::new();
        let mut fake = Fake { dies_on_kill: true, killed: false, status: some_status() };
        let g = guard.clone();
        let feeder = thread::spawn(move || {
            thread::sleep(Duration::from_millis(150));
            g.observe("Output 1 frames in 0.01 seconds (100.00 fps)");
        });
        let start = Instant::now();
        let outcome =
            wait_after_final(&mut fake, &guard, Some(Duration::from_millis(100)), KILL_WAIT, MS).unwrap();
        feeder.join().unwrap();
        // Not killed before the line (150 ms) plus the grace (100 ms).
        assert!(start.elapsed() >= Duration::from_millis(250));
        match outcome {
            ExitOutcome::KilledAfterFinal { line, .. } => assert!(line.finished_cleanly()),
            other => panic!("{other:?}"),
        }
        assert!(fake.killed);
    }

    #[test]
    fn a_vspipe_a_kill_cannot_end_is_reported_not_waited_for() {
        let guard = ExitGuard::new();
        guard.observe("Script evaluation failed:");
        let mut fake = Fake { dies_on_kill: false, killed: false, status: some_status() };
        let outcome = wait_after_final(
            &mut fake,
            &guard,
            Some(Duration::ZERO),
            Duration::from_millis(50),
            MS,
        )
        .unwrap();
        match &outcome {
            ExitOutcome::Unkillable { line, .. } => assert_eq!(line.kind, FinalKind::Error),
            other => panic!("{other:?}"),
        }
        assert!(outcome.note().unwrap().contains("could not end the process"));
    }

    #[test]
    fn a_real_child_that_hangs_after_its_final_line_is_stopped() {
        // A stand-in for vspipe: prints R78's summary, then never exits.
        let mut child = if cfg!(windows) {
            std::process::Command::new("powershell")
                .args(["-NoProfile", "-Command",
                    "[Console]::Error.WriteLine('Output 1 frames in 0.01 seconds (100.00 fps)'); Start-Sleep 600"])
                .stderr(std::process::Stdio::piped())
                .spawn()
                .unwrap()
        } else {
            std::process::Command::new("sh")
                .args(["-c", "echo 'Output 1 frames in 0.01 seconds (100.00 fps)' >&2; exec sleep 600"])
                .stderr(std::process::Stdio::piped())
                .spawn()
                .unwrap()
        };
        let guard = ExitGuard::new();
        let stderr = child.stderr.take().unwrap();
        let g = guard.clone();
        let reader = thread::spawn(move || {
            use std::io::BufRead;
            for line in io::BufReader::new(stderr).lines().map_while(Result::ok) {
                g.observe(&line);
            }
        });
        let start = Instant::now();
        let outcome = wait_after_final(
            &mut child,
            &guard,
            Some(Duration::from_millis(200)),
            KILL_WAIT,
            Duration::from_millis(10),
        )
        .unwrap();
        assert!(matches!(outcome, ExitOutcome::KilledAfterFinal { .. }), "{outcome:?}");
        assert!(start.elapsed() < Duration::from_secs(20));
        reader.join().unwrap();
    }

    #[test]
    fn a_vspipe_that_exits_is_just_waited_for() {
        let mut child = std::process::Command::new(if cfg!(windows) { "cmd" } else { "true" })
            .args(if cfg!(windows) { &["/C", "exit 0"][..] } else { &[][..] })
            .spawn()
            .unwrap();
        let outcome =
            wait_after_final(&mut child, &ExitGuard::new(), Some(DEFAULT_GRACE), KILL_WAIT, MS).unwrap();
        assert!(matches!(outcome, ExitOutcome::Exited(s) if s.success()));
    }
}
