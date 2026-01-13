//! Video job configuration and encoding settings.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{QTGMCParameters, RestorationPipeline};

/// Represents a complete video processing job.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoJob {
    /// Unique job identifier
    pub id: Uuid,

    /// Input video file path
    pub input_path: String,

    /// Output video file path
    pub output_path: String,

    /// Legacy QTGMC deinterlacing parameters (for backwards compatibility)
    pub qtgmc_parameters: QTGMCParameters,

    /// Full restoration pipeline (new multi-pass system)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub restoration_pipeline: Option<RestorationPipeline>,

    /// FFmpeg encoding settings
    pub encoding_settings: EncodingSettings,

    /// Detected field order from input video
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detected_field_order: Option<FieldOrder>,

    /// Total frame count of input video
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_frames: Option<i32>,

    /// Input video frame rate
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_frame_rate: Option<f64>,
}

impl VideoJob {
    /// Get the effective restoration pipeline.
    /// Uses restoration_pipeline if set, otherwise creates one from legacy qtgmc_parameters.
    pub fn effective_pipeline(&self) -> RestorationPipeline {
        self.restoration_pipeline
            .clone()
            .unwrap_or_else(|| RestorationPipeline::from_legacy(&self.qtgmc_parameters))
    }
}

/// Video encoding settings for FFmpeg output.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EncodingSettings {
    /// Output video codec
    #[serde(default)]
    pub codec: VideoCodec,

    /// Encoder preset (speed/quality tradeoff)
    #[serde(default = "default_encoder_preset")]
    pub encoder_preset: String,

    /// Quality setting (CRF for H.264/H.265, quality level for ProRes)
    #[serde(default = "default_quality")]
    pub quality: i32,

    /// Copy audio stream without re-encoding
    #[serde(default = "default_true")]
    pub audio_copy: bool,

    /// Audio codec if not copying
    #[serde(default = "default_audio_codec")]
    pub audio_codec: String,

    /// Audio bitrate in kbps (if re-encoding)
    #[serde(default = "default_audio_bitrate")]
    pub audio_bitrate: i32,

    /// Additional FFmpeg arguments
    #[serde(default)]
    pub custom_ffmpeg_args: String,

    /// Output container format
    #[serde(default)]
    pub container: ContainerFormat,
}

fn default_encoder_preset() -> String {
    "medium".to_string()
}

fn default_quality() -> i32 {
    18
}

fn default_true() -> bool {
    true
}

fn default_audio_codec() -> String {
    "aac".to_string()
}

fn default_audio_bitrate() -> i32 {
    192
}

impl Default for EncodingSettings {
    fn default() -> Self {
        Self {
            codec: VideoCodec::default(),
            encoder_preset: default_encoder_preset(),
            quality: default_quality(),
            audio_copy: true,
            audio_codec: default_audio_codec(),
            audio_bitrate: default_audio_bitrate(),
            custom_ffmpeg_args: String::new(),
            container: ContainerFormat::default(),
        }
    }
}

/// Supported video codecs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum VideoCodec {
    #[default]
    #[serde(rename = "libx264")]
    H264,

    #[serde(rename = "libx265")]
    H265,

    #[serde(rename = "ffv1")]
    FFV1,

    #[serde(rename = "prores_ks -profile:v 0")]
    ProResProxy,

    #[serde(rename = "prores_ks -profile:v 1")]
    ProResLT,

    #[serde(rename = "prores_ks -profile:v 2")]
    ProRes422,

    #[serde(rename = "prores_ks -profile:v 3")]
    ProResHQ,
}

impl VideoCodec {
    /// Get the FFmpeg codec string.
    pub fn ffmpeg_codec(&self) -> &'static str {
        match self {
            VideoCodec::H264 => "libx264",
            VideoCodec::H265 => "libx265",
            VideoCodec::FFV1 => "ffv1",
            VideoCodec::ProResProxy => "prores_ks",
            VideoCodec::ProResLT => "prores_ks",
            VideoCodec::ProRes422 => "prores_ks",
            VideoCodec::ProResHQ => "prores_ks",
        }
    }

    /// Get the ProRes profile value, if applicable.
    pub fn prores_profile(&self) -> Option<i32> {
        match self {
            VideoCodec::ProResProxy => Some(0),
            VideoCodec::ProResLT => Some(1),
            VideoCodec::ProRes422 => Some(2),
            VideoCodec::ProResHQ => Some(3),
            _ => None,
        }
    }

    /// Check if this is a ProRes codec.
    pub fn is_prores(&self) -> bool {
        self.prores_profile().is_some()
    }

    /// Check if this is FFV1 codec.
    pub fn is_ffv1(&self) -> bool {
        matches!(self, VideoCodec::FFV1)
    }

    /// Get the preferred container format for this codec.
    pub fn preferred_container(&self) -> ContainerFormat {
        if self.is_prores() {
            ContainerFormat::Mov
        } else if self.is_ffv1() {
            ContainerFormat::Avi
        } else {
            ContainerFormat::Mp4
        }
    }

    /// Human-readable display name.
    pub fn display_name(&self) -> &'static str {
        match self {
            VideoCodec::H264 => "H.264",
            VideoCodec::H265 => "H.265 (HEVC)",
            VideoCodec::FFV1 => "FFV1 (Lossless)",
            VideoCodec::ProResProxy => "ProRes Proxy",
            VideoCodec::ProResLT => "ProRes LT",
            VideoCodec::ProRes422 => "ProRes 422",
            VideoCodec::ProResHQ => "ProRes 422 HQ",
        }
    }
}

/// Output container formats.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ContainerFormat {
    #[default]
    Mp4,
    Mov,
    Mkv,
    Avi,
}

impl ContainerFormat {
    /// File extension for this container.
    pub fn extension(&self) -> &'static str {
        match self {
            ContainerFormat::Mp4 => "mp4",
            ContainerFormat::Mov => "mov",
            ContainerFormat::Mkv => "mkv",
            ContainerFormat::Avi => "avi",
        }
    }

    /// Human-readable display name.
    pub fn display_name(&self) -> &'static str {
        match self {
            ContainerFormat::Mp4 => "MP4",
            ContainerFormat::Mov => "QuickTime MOV",
            ContainerFormat::Mkv => "Matroska MKV",
            ContainerFormat::Avi => "AVI",
        }
    }
}

/// Video field order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FieldOrder {
    #[serde(rename = "tff")]
    TopFieldFirst,

    #[serde(rename = "bff")]
    BottomFieldFirst,

    Progressive,
    Unknown,
}

impl FieldOrder {
    /// Human-readable display name.
    pub fn display_name(&self) -> &'static str {
        match self {
            FieldOrder::TopFieldFirst => "Top Field First (TFF)",
            FieldOrder::BottomFieldFirst => "Bottom Field First (BFF)",
            FieldOrder::Progressive => "Progressive",
            FieldOrder::Unknown => "Unknown",
        }
    }

    /// Convert to QTGMC TFF parameter value.
    pub fn tff_value(&self) -> Option<bool> {
        match self {
            FieldOrder::TopFieldFirst => Some(true),
            FieldOrder::BottomFieldFirst => Some(false),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_video_codec_serialization() {
        assert_eq!(
            serde_json::to_string(&VideoCodec::H264).unwrap(),
            "\"libx264\""
        );
        assert_eq!(
            serde_json::to_string(&VideoCodec::ProResHQ).unwrap(),
            "\"prores_ks -profile:v 3\""
        );
    }

    #[test]
    fn test_container_format_serialization() {
        assert_eq!(
            serde_json::to_string(&ContainerFormat::Mp4).unwrap(),
            "\"mp4\""
        );
    }

    #[test]
    fn test_field_order_serialization() {
        assert_eq!(
            serde_json::to_string(&FieldOrder::TopFieldFirst).unwrap(),
            "\"tff\""
        );
    }
}
