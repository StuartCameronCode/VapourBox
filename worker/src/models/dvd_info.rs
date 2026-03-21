//! DVD information models for title enumeration.

use serde::{Deserialize, Serialize};

/// Complete information about a DVD disc.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DvdInfo {
    /// Volume label (disc name)
    pub volume_label: String,

    /// Path to the DVD mount point or device
    pub device_path: String,

    /// List of titles on the disc
    pub titles: Vec<DvdTitle>,
}

/// Information about a single DVD title.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DvdTitle {
    /// Title index (1-based)
    pub index: u32,

    /// Duration in seconds
    pub duration_seconds: f64,

    /// Chapters within this title
    pub chapters: Vec<DvdChapter>,

    /// Audio tracks
    pub audio_tracks: Vec<DvdAudioTrack>,

    /// Video width in pixels
    pub width: u32,

    /// Video height in pixels (480 for NTSC, 576 for PAL)
    pub height: u32,

    /// Frame rate (29.97 for NTSC, 25.0 for PAL)
    pub frame_rate: f64,

    /// Aspect ratio string ("4:3" or "16:9")
    pub aspect_ratio: String,

    /// Number of angles
    pub angles: u32,

    /// VTS (Video Title Set) number this title belongs to
    pub vts_number: u32,
}

/// Information about a single chapter within a title.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DvdChapter {
    /// Chapter index (1-based)
    pub index: u32,

    /// Duration in seconds (0 if unknown)
    pub duration_seconds: f64,
}

/// Information about an audio track.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DvdAudioTrack {
    /// Track index (0-based)
    pub index: u32,

    /// Language code (e.g., "en", "fr", "und" for undefined)
    pub language: String,

    /// Audio format (e.g., "AC3", "DTS", "LPCM", "MPEG-1", "MPEG-2")
    pub format: String,

    /// Number of channels (e.g., 2 for stereo, 6 for 5.1)
    pub channels: u32,

    /// Sample rate in Hz (e.g., 48000)
    pub sample_rate: u32,
}
