//! Progress information and worker messages.

use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};

/// Progress information reported by the worker process.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressInfo {
    /// Current frame being processed
    pub frame: i32,

    /// Total frames in the video
    pub total_frames: i32,

    /// Current processing speed in frames per second
    pub fps: f64,

    /// Estimated time remaining in seconds
    pub eta: f64,
}

impl ProgressInfo {
    /// Create a new progress info.
    pub fn new(frame: i32, total_frames: i32, fps: f64, eta: f64) -> Self {
        Self {
            frame,
            total_frames,
            fps,
            eta,
        }
    }

    /// Progress as a fraction (0.0 to 1.0).
    pub fn progress(&self) -> f64 {
        if self.total_frames <= 0 {
            return 0.0;
        }
        (self.frame as f64) / (self.total_frames as f64)
    }

    /// Progress as a percentage (0 to 100).
    pub fn percent_complete(&self) -> i32 {
        (self.progress() * 100.0) as i32
    }

    /// Formatted ETA string (e.g., "1h 23m 45s").
    pub fn eta_formatted(&self) -> String {
        if self.eta <= 0.0 || !self.eta.is_finite() {
            return "--".to_string();
        }

        let total_secs = self.eta as i64;
        let hours = total_secs / 3600;
        let minutes = (total_secs % 3600) / 60;
        let seconds = total_secs % 60;

        if hours > 0 {
            format!("{}h {:02}m {:02}s", hours, minutes, seconds)
        } else if minutes > 0 {
            format!("{}m {:02}s", minutes, seconds)
        } else {
            format!("{}s", seconds)
        }
    }

    /// Formatted FPS string.
    pub fn fps_formatted(&self) -> String {
        if self.fps <= 0.0 || !self.fps.is_finite() {
            return "-- fps".to_string();
        }
        format!("{:.1} fps", self.fps)
    }
}

/// Messages sent from worker to main app via stdout.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum WorkerMessage {
    /// Progress update
    Progress {
        frame: i32,
        #[serde(rename = "totalFrames")]
        total_frames: i32,
        fps: f64,
        eta: f64,
    },

    /// Log message
    Log {
        level: String,
        message: String,
    },

    /// Error message
    Error {
        message: String,
    },

    /// Job completion
    Complete {
        success: bool,
        #[serde(rename = "outputPath", skip_serializing_if = "Option::is_none")]
        output_path: Option<String>,
    },
}

impl WorkerMessage {
    /// Create a progress message.
    pub fn progress(info: &ProgressInfo) -> Self {
        WorkerMessage::Progress {
            frame: info.frame,
            total_frames: info.total_frames,
            fps: info.fps,
            eta: info.eta,
        }
    }

    /// Create a log message.
    pub fn log(level: LogLevel, message: &str) -> Self {
        WorkerMessage::Log {
            level: level.as_str().to_string(),
            message: message.to_string(),
        }
    }

    /// Create an error message.
    pub fn error(message: &str) -> Self {
        WorkerMessage::Error {
            message: message.to_string(),
        }
    }

    /// Create a completion message.
    pub fn complete(success: bool, output_path: Option<&str>) -> Self {
        WorkerMessage::Complete {
            success,
            output_path: output_path.map(String::from),
        }
    }
}

/// Log message from worker.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogMessage {
    pub level: LogLevel,
    pub message: String,
    pub timestamp: DateTime<Utc>,
}

impl LogMessage {
    pub fn new(level: LogLevel, message: &str) -> Self {
        Self {
            level,
            message: message.to_string(),
            timestamp: Utc::now(),
        }
    }
}

/// Log levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Debug,
    Info,
    Warning,
    Error,
}

impl LogLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            LogLevel::Debug => "debug",
            LogLevel::Info => "info",
            LogLevel::Warning => "warning",
            LogLevel::Error => "error",
        }
    }
}

/// Processing state machine.
#[derive(Debug, Clone, PartialEq)]
pub enum ProcessingState {
    Idle,
    PreparingJob,
    Processing { progress: f64 },
    Cancelling,
    Completed { success: bool },
    Failed { error: String },
}

impl ProcessingState {
    /// Check if processing is active.
    pub fn is_active(&self) -> bool {
        matches!(
            self,
            ProcessingState::PreparingJob
                | ProcessingState::Processing { .. }
                | ProcessingState::Cancelling
        )
    }

    /// Check if cancellation is possible.
    pub fn can_cancel(&self) -> bool {
        matches!(
            self,
            ProcessingState::PreparingJob | ProcessingState::Processing { .. }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_progress_info() {
        let info = ProgressInfo::new(500, 1000, 25.0, 20.0);
        assert_eq!(info.progress(), 0.5);
        assert_eq!(info.percent_complete(), 50);
        assert_eq!(info.eta_formatted(), "20s");
        assert_eq!(info.fps_formatted(), "25.0 fps");
    }

    #[test]
    fn test_worker_message_serialization() {
        let msg = WorkerMessage::progress(&ProgressInfo::new(100, 1000, 30.0, 30.0));
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"progress\""));
        assert!(json.contains("\"frame\":100"));
    }

    #[test]
    fn test_log_message_serialization() {
        let msg = WorkerMessage::log(LogLevel::Info, "Test message");
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"log\""));
        assert!(json.contains("\"level\":\"info\""));
    }
}
