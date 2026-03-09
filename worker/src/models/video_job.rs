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

    /// Start frame for partial export (inclusive). None means start from beginning.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_frame: Option<i32>,

    /// End frame for partial export (inclusive). None means export to end.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_frame: Option<i32>,

    /// Subtitle generation settings (runs post-encode).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle_settings: Option<SubtitleSettings>,

    /// When true, skip video processing and only generate subtitles from input.
    #[serde(default)]
    pub subtitle_only: bool,

    /// Input sample aspect ratio (e.g. "10:11"). None means 1:1 (square pixels).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_sar: Option<String>,
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

/// Subtitle generation settings using Whisper AI.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleSettings {
    pub enabled: bool,

    #[serde(default = "default_whisper_model")]
    pub model: String,

    #[serde(default)]
    pub output: SubtitleOutput,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
}

fn default_whisper_model() -> String {
    "medium".to_string()
}

/// Subtitle output mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SubtitleOutput {
    #[default]
    SrtFile,
    Embed,
    Both,
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

    /// Audio handling mode
    #[serde(default)]
    pub audio_mode: AudioMode,

    /// Audio codec for re-encoding (when audio_mode == Convert)
    #[serde(default)]
    pub audio_codec: AudioCodec,

    /// Audio quality preset (when audio_mode == Convert and codec is lossy)
    #[serde(default)]
    pub audio_quality: AudioQuality,

    /// Output chroma subsampling format
    #[serde(default)]
    pub chroma_subsampling: ChromaSubsampling,

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

/// Audio handling mode for output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum AudioMode {
    /// Copy audio stream without re-encoding.
    #[default]
    Passthrough,
    /// Re-encode audio with selected codec and quality.
    Convert,
    /// No audio in output.
    None,
}

/// Audio codecs for re-encoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum AudioCodec {
    #[default]
    #[serde(rename = "aac")]
    Aac,
    #[serde(rename = "libmp3lame")]
    Mp3,
    #[serde(rename = "ac3")]
    Ac3,
    #[serde(rename = "flac")]
    Flac,
    #[serde(rename = "libopus")]
    Opus,
    #[serde(rename = "pcm_s16le")]
    Pcm,
}

impl AudioCodec {
    /// Get the FFmpeg codec name.
    pub fn ffmpeg_name(&self) -> &'static str {
        match self {
            AudioCodec::Aac => "aac",
            AudioCodec::Mp3 => "libmp3lame",
            AudioCodec::Ac3 => "ac3",
            AudioCodec::Flac => "flac",
            AudioCodec::Opus => "libopus",
            AudioCodec::Pcm => "pcm_s16le",
        }
    }

    /// Whether this is a lossless codec (no bitrate needed).
    pub fn is_lossless(&self) -> bool {
        matches!(self, AudioCodec::Flac | AudioCodec::Pcm)
    }
}

/// Audio quality presets (bitrate in kbps).
/// Serializes as integers to match Dart's json_serializable output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AudioQuality {
    Low,
    Medium,
    #[default]
    High,
    VeryHigh,
}

impl AudioQuality {
    /// Get the bitrate in kbps.
    pub fn bitrate(&self) -> i32 {
        match self {
            AudioQuality::Low => 96,
            AudioQuality::Medium => 128,
            AudioQuality::High => 192,
            AudioQuality::VeryHigh => 256,
        }
    }

    fn from_int(value: i64) -> Option<Self> {
        match value {
            96 => Some(AudioQuality::Low),
            128 => Some(AudioQuality::Medium),
            192 => Some(AudioQuality::High),
            256 => Some(AudioQuality::VeryHigh),
            _ => None,
        }
    }
}

impl serde::Serialize for AudioQuality {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_i32(self.bitrate())
    }
}

impl<'de> serde::Deserialize<'de> for AudioQuality {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct AudioQualityVisitor;

        impl<'de> serde::de::Visitor<'de> for AudioQualityVisitor {
            type Value = AudioQuality;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("an integer (96, 128, 192, or 256)")
            }

            fn visit_i64<E>(self, value: i64) -> Result<AudioQuality, E>
            where
                E: serde::de::Error,
            {
                AudioQuality::from_int(value)
                    .ok_or_else(|| E::custom(format!("unknown audio quality: {}", value)))
            }

            fn visit_u64<E>(self, value: u64) -> Result<AudioQuality, E>
            where
                E: serde::de::Error,
            {
                self.visit_i64(value as i64)
            }
        }

        deserializer.deserialize_any(AudioQualityVisitor)
    }
}

/// Output chroma subsampling format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ChromaSubsampling {
    /// Keep original format (no conversion).
    #[default]
    Original,
    /// Convert to YUV420 for maximum compatibility.
    Yuv420,
    /// Convert to YUV422 for higher chroma quality.
    Yuv422,
}

impl Default for EncodingSettings {
    fn default() -> Self {
        Self {
            codec: VideoCodec::default(),
            encoder_preset: default_encoder_preset(),
            quality: default_quality(),
            audio_mode: AudioMode::default(),
            audio_codec: AudioCodec::default(),
            audio_quality: AudioQuality::default(),
            chroma_subsampling: ChromaSubsampling::default(),
            custom_ffmpeg_args: String::new(),
            container: ContainerFormat::default(),
        }
    }
}

/// Supported video codecs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum VideoCodec {
    // Software encoders
    #[default]
    #[serde(rename = "libx264")]
    H264,

    #[serde(rename = "libx265")]
    H265,

    // NVIDIA NVENC
    #[serde(rename = "h264_nvenc")]
    H264Nvenc,

    #[serde(rename = "hevc_nvenc")]
    H265Nvenc,

    // Intel QSV
    #[serde(rename = "h264_qsv")]
    H264Qsv,

    #[serde(rename = "hevc_qsv")]
    H265Qsv,

    // Apple VideoToolbox
    #[serde(rename = "h264_videotoolbox")]
    H264Videotoolbox,

    #[serde(rename = "hevc_videotoolbox")]
    H265Videotoolbox,

    // AMD AMF
    #[serde(rename = "h264_amf")]
    H264Amf,

    #[serde(rename = "hevc_amf")]
    H265Amf,

    // Lossless / ProRes
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

/// Encoder family for grouping quality/preset logic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EncoderFamily {
    Software,
    Nvenc,
    Qsv,
    Videotoolbox,
    Amf,
    ProRes,
    Lossless,
}

#[allow(dead_code)]
impl VideoCodec {
    /// Get the FFmpeg codec string.
    pub fn ffmpeg_codec(&self) -> &'static str {
        match self {
            VideoCodec::H264 => "libx264",
            VideoCodec::H265 => "libx265",
            VideoCodec::H264Nvenc => "h264_nvenc",
            VideoCodec::H265Nvenc => "hevc_nvenc",
            VideoCodec::H264Qsv => "h264_qsv",
            VideoCodec::H265Qsv => "hevc_qsv",
            VideoCodec::H264Videotoolbox => "h264_videotoolbox",
            VideoCodec::H265Videotoolbox => "hevc_videotoolbox",
            VideoCodec::H264Amf => "h264_amf",
            VideoCodec::H265Amf => "hevc_amf",
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

    /// Whether this codec produces H.264 output.
    pub fn is_h264(&self) -> bool {
        matches!(self, VideoCodec::H264 | VideoCodec::H264Nvenc | VideoCodec::H264Qsv |
                       VideoCodec::H264Videotoolbox | VideoCodec::H264Amf)
    }

    /// Whether this codec produces H.265 output.
    pub fn is_h265(&self) -> bool {
        matches!(self, VideoCodec::H265 | VideoCodec::H265Nvenc | VideoCodec::H265Qsv |
                       VideoCodec::H265Videotoolbox | VideoCodec::H265Amf)
    }

    /// Whether this is a hardware-accelerated encoder.
    pub fn is_hardware(&self) -> bool {
        !matches!(self.encoder_family(), EncoderFamily::Software | EncoderFamily::ProRes | EncoderFamily::Lossless)
    }

    /// Get the encoder family for this codec.
    pub fn encoder_family(&self) -> EncoderFamily {
        match self {
            VideoCodec::H264 | VideoCodec::H265 => EncoderFamily::Software,
            VideoCodec::H264Nvenc | VideoCodec::H265Nvenc => EncoderFamily::Nvenc,
            VideoCodec::H264Qsv | VideoCodec::H265Qsv => EncoderFamily::Qsv,
            VideoCodec::H264Videotoolbox | VideoCodec::H265Videotoolbox => EncoderFamily::Videotoolbox,
            VideoCodec::H264Amf | VideoCodec::H265Amf => EncoderFamily::Amf,
            VideoCodec::FFV1 => EncoderFamily::Lossless,
            _ => EncoderFamily::ProRes,
        }
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
            VideoCodec::H264Nvenc => "H.264 (NVENC)",
            VideoCodec::H265Nvenc => "H.265 (NVENC)",
            VideoCodec::H264Qsv => "H.264 (Intel QSV)",
            VideoCodec::H265Qsv => "H.265 (Intel QSV)",
            VideoCodec::H264Videotoolbox => "H.264 (VideoToolbox)",
            VideoCodec::H265Videotoolbox => "H.265 (VideoToolbox)",
            VideoCodec::H264Amf => "H.264 (AMD AMF)",
            VideoCodec::H265Amf => "H.265 (AMD AMF)",
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

#[allow(dead_code)]
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

#[allow(dead_code)]
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
        assert_eq!(
            serde_json::to_string(&VideoCodec::H264Nvenc).unwrap(),
            "\"h264_nvenc\""
        );
        assert_eq!(
            serde_json::to_string(&VideoCodec::H265Nvenc).unwrap(),
            "\"hevc_nvenc\""
        );
        assert_eq!(
            serde_json::to_string(&VideoCodec::H264Qsv).unwrap(),
            "\"h264_qsv\""
        );
        assert_eq!(
            serde_json::to_string(&VideoCodec::H264Videotoolbox).unwrap(),
            "\"h264_videotoolbox\""
        );
        assert_eq!(
            serde_json::to_string(&VideoCodec::H264Amf).unwrap(),
            "\"h264_amf\""
        );
    }

    #[test]
    fn test_video_codec_encoder_family() {
        assert_eq!(VideoCodec::H264.encoder_family(), EncoderFamily::Software);
        assert_eq!(VideoCodec::H265.encoder_family(), EncoderFamily::Software);
        assert_eq!(VideoCodec::H264Nvenc.encoder_family(), EncoderFamily::Nvenc);
        assert_eq!(VideoCodec::H265Nvenc.encoder_family(), EncoderFamily::Nvenc);
        assert_eq!(VideoCodec::H264Qsv.encoder_family(), EncoderFamily::Qsv);
        assert_eq!(VideoCodec::H264Videotoolbox.encoder_family(), EncoderFamily::Videotoolbox);
        assert_eq!(VideoCodec::H264Amf.encoder_family(), EncoderFamily::Amf);
        assert_eq!(VideoCodec::FFV1.encoder_family(), EncoderFamily::Lossless);
        assert_eq!(VideoCodec::ProResHQ.encoder_family(), EncoderFamily::ProRes);
    }

    #[test]
    fn test_video_codec_is_hardware() {
        assert!(!VideoCodec::H264.is_hardware());
        assert!(!VideoCodec::H265.is_hardware());
        assert!(VideoCodec::H264Nvenc.is_hardware());
        assert!(VideoCodec::H265Nvenc.is_hardware());
        assert!(VideoCodec::H264Qsv.is_hardware());
        assert!(VideoCodec::H264Videotoolbox.is_hardware());
        assert!(VideoCodec::H264Amf.is_hardware());
        assert!(!VideoCodec::FFV1.is_hardware());
        assert!(!VideoCodec::ProResHQ.is_hardware());
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
