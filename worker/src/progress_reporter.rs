//! Progress reporting via JSON on stdout.

use std::io::{self, Write};
use std::sync::Mutex;

use crate::models::{LogLevel, ProgressInfo, WorkerMessage};

/// Thread-safe progress reporter that outputs JSON messages to stdout.
#[derive(Clone)]
pub struct ProgressReporter {
    inner: std::sync::Arc<ProgressReporterInner>,
}

struct ProgressReporterInner {
    output_lock: Mutex<()>,
}

impl ProgressReporter {
    /// Create a new progress reporter.
    pub fn new() -> Self {
        Self {
            inner: std::sync::Arc::new(ProgressReporterInner {
                output_lock: Mutex::new(()),
            }),
        }
    }

    /// Send a progress update.
    pub fn send_progress(&self, progress: &ProgressInfo) {
        let message = WorkerMessage::progress(progress);
        self.send_message(&message);
    }

    /// Send a log message.
    pub fn send_log(&self, level: LogLevel, message: &str) {
        let msg = WorkerMessage::log(level, message);
        self.send_message(&msg);
    }

    /// Send an error message.
    pub fn send_error(&self, message: &str) {
        let msg = WorkerMessage::error(message);
        self.send_message(&msg);
    }

    /// Send a completion message.
    pub fn send_complete(&self, success: bool, output_path: Option<&str>) {
        let msg = WorkerMessage::complete(success, output_path);
        self.send_message(&msg);
    }

    /// Send a raw message (thread-safe).
    fn send_message(&self, message: &WorkerMessage) {
        let _lock = self.inner.output_lock.lock().unwrap();

        match serde_json::to_string(message) {
            Ok(json) => {
                let stdout = io::stdout();
                let mut handle = stdout.lock();
                if let Err(e) = writeln!(handle, "{}", json) {
                    eprintln!("Failed to write to stdout: {}", e);
                }
                let _ = handle.flush();
            }
            Err(e) => {
                eprintln!("Failed to serialize message: {}", e);
            }
        }
    }
}

impl Default for ProgressReporter {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_reporter_creation() {
        let reporter = ProgressReporter::new();
        // Just verify it can be created and cloned
        let _clone = reporter.clone();
    }
}
