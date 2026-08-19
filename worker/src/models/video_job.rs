//! Video job configuration and encoding settings.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{QTGMCParameters, ProcessingPipeline, ColorMetadata};

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

    /// Full processing pipeline (new multi-pass system)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub processing_pipeline: Option<ProcessingPipeline>,

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

    /// Input video width in pixels (for pipe source).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_width: Option<i32>,

    /// Input video height in pixels (for pipe source).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_height: Option<i32>,

    /// Input pixel format string (e.g. "yuv420p", "yuv422p"). For pipe source.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_pixel_format: Option<String>,

    /// Source colour tags, read from ffprobe and re-declared on the output.
    /// The Y4M pipe strips them exactly as it strips SAR, so without these the
    /// output is untagged and every player reads it as BT.601 limited.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_color_matrix: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_color_primaries: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_color_transfer: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_color_range: Option<String>,

    /// A subtitle file to burn into the picture. Separate from the Whisper
    /// path: transcription currently runs *after* the encode, so its output
    /// cannot reach the encoder. A user-supplied file has no such problem.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub burn_in_subtitle_path: Option<String>,

}

impl VideoJob {
    /// The source's colour tags, validated. Empty when the source was untagged.
    pub fn color_metadata(&self) -> ColorMetadata {
        ColorMetadata::from_raw(
            self.input_color_matrix.as_deref(),
            self.input_color_primaries.as_deref(),
            self.input_color_transfer.as_deref(),
            self.input_color_range.as_deref(),
        )
    }

    /// The pixel format the encoder ffmpeg is handed on stdin.
    ///
    /// The output conversion is the last thing the `.vpy` does, so when one is
    /// selected it decides the format outright. With `Original` nothing
    /// converts and the pipe carries the format the decoder was asked for —
    /// which is the *pipe* format, not necessarily the source's own (see
    /// `pixel_format`, where an unreadable source is normalised on the way in).
    ///
    /// A pass that changes format mid-graph always restores it (Turn90,
    /// DeScratch, LUTDeCrawl all convert back), so the graph's output format is
    /// its input format. Custom VapourSynth could break that assumption, and
    /// like everything else about custom code, it is the user's to get right.
    pub fn encoder_input_pix_fmt(&self) -> String {
        self.encoding_settings
            .chroma_subsampling
            .ffmpeg_pix_fmt()
            .map(str::to_string)
            .unwrap_or_else(|| {
                crate::pixel_format::decode_pixel_format(self.input_pixel_format.as_deref()).name
            })
    }

    /// Get the effective processing pipeline.
    /// Uses processing_pipeline if set, otherwise creates one from legacy qtgmc_parameters.
    pub fn effective_pipeline(&self) -> ProcessingPipeline {
        self.processing_pipeline
            .clone()
            .unwrap_or_else(|| ProcessingPipeline::from_legacy(&self.qtgmc_parameters))
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
    /// Draw the subtitles into the picture itself.
    BurnIn,
    /// Draw them in AND keep the sidecar file.
    BurnInAndSrt,
}

impl SubtitleOutput {
    /// The subtitles are drawn into the picture during the encode, so the
    /// transcript has to exist before it starts.
    pub fn burns_in(self) -> bool {
        matches!(self, SubtitleOutput::BurnIn | SubtitleOutput::BurnInAndSrt)
    }

    /// The transcript is multiplexed into the finished file as a selectable
    /// track — a post-pass, because the file has to exist first.
    pub fn muxes(self) -> bool {
        matches!(self, SubtitleOutput::Embed | SubtitleOutput::Both)
    }

    /// The `.srt` is left beside the video rather than cleaned up.
    pub fn keeps_srt_file(self) -> bool {
        matches!(
            self,
            SubtitleOutput::SrtFile | SubtitleOutput::Both | SubtitleOutput::BurnInAndSrt
        )
    }
}

#[cfg(test)]
mod subtitle_output_tests {
    use super::SubtitleOutput;

    /// Every mode must do at least one of the three things, or choosing it
    /// silently produces nothing.
    #[test]
    fn every_mode_does_something() {
        for mode in [
            SubtitleOutput::SrtFile,
            SubtitleOutput::Embed,
            SubtitleOutput::Both,
            SubtitleOutput::BurnIn,
            SubtitleOutput::BurnInAndSrt,
        ] {
            assert!(
                mode.burns_in() || mode.muxes() || mode.keeps_srt_file(),
                "{mode:?} would produce no subtitles at all"
            );
        }
    }

    #[test]
    fn burning_in_and_muxing_are_independent() {
        // Burn-in draws pixels; muxing adds a track the player can switch off.
        // A mode may do either, and "both" here means sidecar + track.
        assert!(SubtitleOutput::BurnIn.burns_in());
        assert!(!SubtitleOutput::BurnIn.muxes());
        assert!(!SubtitleOutput::BurnIn.keeps_srt_file());

        assert!(SubtitleOutput::Both.muxes());
        assert!(SubtitleOutput::Both.keeps_srt_file());
        assert!(!SubtitleOutput::Both.burns_in());

        assert!(SubtitleOutput::BurnInAndSrt.burns_in());
        assert!(SubtitleOutput::BurnInAndSrt.keeps_srt_file());
    }

    /// Embed must not also leave a stray sidecar — that was the old behaviour
    /// and it is why the file is deleted after muxing.
    #[test]
    fn embed_alone_leaves_no_sidecar() {
        assert!(SubtitleOutput::Embed.muxes());
        assert!(!SubtitleOutput::Embed.keeps_srt_file());
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

    /// User-supplied VapourSynth, injected after every built-in pass. Same
    /// footing as custom_ffmpeg_args: an escape hatch for someone who knows
    /// what they are doing, gated behind advanced mode in the UI.
    #[serde(default)]
    pub custom_vapoursynth: String,

    /// Output container format
    #[serde(default)]
    pub container: ContainerFormat,

    /// Target video bitrate in kbps. Used by Intel-Mac VideoToolbox (which has no
    /// constant-quality mode), where the UI exposes a native bitrate control
    /// instead of the CRF slider. `None` falls back to a resolution-derived
    /// estimate; ignored by all other encoder families.
    #[serde(default)]
    pub video_bitrate_kbps: Option<u32>,
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
/// Mirrors `ChromaSubsampling` in `app/lib/models/encoding_settings.dart` — the
/// serde names here must match that enum's `value` strings.
pub enum ChromaSubsampling {
    /// Keep original format (no conversion), bit depth included.
    #[default]
    Original,
    /// Convert to 8-bit YUV420 for maximum compatibility.
    Yuv420,
    /// Convert to 10-bit YUV420 — the only 10-bit layout NVENC, QSV and AMF can
    /// encode, so it keeps a 10-bit source's grading where 4:2:2 fails outright
    /// on most GPUs (issue #74).
    Yuv420P10,
    /// Convert to 8-bit YUV422 for higher chroma quality.
    Yuv422,
    /// Convert to 10-bit YUV422 — keeps a 10-bit source's precision while
    /// normalizing chroma, and gives an 8-bit source headroom for gradients.
    Yuv422P10,
}

impl ChromaSubsampling {
    /// The VapourSynth format constant the pipeline converts to, or `None` for
    /// `Original` (no conversion at all).
    pub fn vapoursynth_format(&self) -> Option<&'static str> {
        match self {
            ChromaSubsampling::Original => None,
            ChromaSubsampling::Yuv420 => Some("vs.YUV420P8"),
            ChromaSubsampling::Yuv420P10 => Some("vs.YUV420P10"),
            ChromaSubsampling::Yuv422 => Some("vs.YUV422P8"),
            ChromaSubsampling::Yuv422P10 => Some("vs.YUV422P10"),
        }
    }

    /// The same format as an FFmpeg pixel-format name — what actually comes out
    /// of the Y4M pipe once the conversion above has run. `None` for `Original`,
    /// where the format is the source's and only the pipe knows it.
    ///
    /// Keep in step with [`vapoursynth_format`](Self::vapoursynth_format): the
    /// two describe the same conversion, and
    /// `chroma_subsampling_names_agree` fails if a variant gains one and not
    /// the other.
    pub fn ffmpeg_pix_fmt(&self) -> Option<&'static str> {
        match self {
            ChromaSubsampling::Original => None,
            ChromaSubsampling::Yuv420 => Some("yuv420p"),
            ChromaSubsampling::Yuv420P10 => Some("yuv420p10le"),
            ChromaSubsampling::Yuv422 => Some("yuv422p"),
            ChromaSubsampling::Yuv422P10 => Some("yuv422p10le"),
        }
    }
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
            custom_vapoursynth: String::new(),
            container: ContainerFormat::default(),
            video_bitrate_kbps: None,
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

    #[serde(rename = "huffyuv")]
    Huffyuv,

    #[serde(rename = "ffvhuff")]
    Ffvhuff,

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
            VideoCodec::Huffyuv => "huffyuv",
            VideoCodec::Ffvhuff => "ffvhuff",
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

    /// Check if this is a lossless codec (FFV1, HuffYUV, FFVHuff).
    pub fn is_lossless(&self) -> bool {
        matches!(self.encoder_family(), EncoderFamily::Lossless)
    }

    /// FFmpeg output pixel format to force for this codec, given the format the
    /// pipeline will actually hand it (`encoder_input`, from
    /// [`VideoJob::encoder_input_pix_fmt`]). `None` leaves the choice to
    /// ffmpeg's own negotiation.
    ///
    /// Two of these are unconditional, because the encoder takes one format
    /// whatever the source was. The NVENC/QSV arm is not: it must only fire
    /// when the pipeline's format is genuinely unencodable, or it would drag a
    /// perfectly good 10-bit 4:2:0 source down to 8-bit for no reason.
    ///
    /// **Do not assume ffmpeg's negotiation handles this.** An encoder's
    /// declared pix_fmt list is static, but NVENC's real capabilities are
    /// queried from the driver at `avcodec_open2`. A recent ffmpeg built
    /// against NVENC SDK 13 advertises `yuv422p` on `h264_nvenc` for
    /// Blackwell's 4:2:2 support, so negotiation happily picks it for a 4:2:2
    /// source — and every pre-Blackwell card then fails the job outright with
    /// "YUV422P not supported / No capable devices found" (issue #74, on an
    /// RTX 4070 Super). Negotiation cannot avoid this, because the list it
    /// negotiates against is wrong for the hardware in the machine.
    ///
    /// Custom FFmpeg Arguments still wins in every case: they are appended
    /// last, so a later `-pix_fmt` overrides this one. That is the escape hatch
    /// for someone whose card really does have the mode we refuse to assume.
    pub fn forced_pix_fmt(&self, encoder_input: &str) -> Option<&'static str> {
        match self {
            // Classic HuffYUV only supports yuv422p (not yuv420p); ffvhuff and
            // the others accept yuv420p.
            VideoCodec::Huffyuv => return Some("yuv422p"),
            // AMF takes nv12 natively. Left to negotiate, ffmpeg will hand a
            // >8-bit source to the encoder as p010, and 10-bit HEVC encode is
            // only supported on some AMD ASICs — where it isn't, the AMF
            // runtime faults (0xC0000005) instead of failing cleanly, which is
            // one candidate for the crashes in issue #51. h264_amf has no
            // 10-bit mode at all. Pinning nv12 makes the conversion explicit
            // and identical on every card.
            VideoCodec::H264Amf | VideoCodec::H265Amf => return Some("nv12"),
            _ => {}
        }

        let family = self.encoder_family();
        if !matches!(family, EncoderFamily::Nvenc | EncoderFamily::Qsv) {
            return None;
        }

        let (class, depth) = crate::pixel_format::chroma_and_depth(encoder_input);

        // 4:2:0 is the only chroma layout every NVENC and QSV part encodes.
        // 4:2:2 is Blackwell-only on NVENC and needs a recent VDENC on QSV;
        // 4:4:4 needs a profile this pipeline never selects (`build_encoder_
        // quality_args` pins h264_nvenc to `-profile:v high`, which is 4:2:0).
        let chroma_unsupported = class != crate::pixel_format::ChromaClass::C420;
        // Neither family has a 10-bit H.264 mode at all.
        let depth_unsupported = depth > 8 && self.is_h264();

        if !chroma_unsupported && !depth_unsupported {
            return None;
        }

        // NVENC names planar 4:2:0 `yuv420p`; QSV's native format is the
        // semi-planar `nv12`. Both are 8-bit 4:2:0 and either encoder accepts
        // either, but each family's own name is the one that avoids a
        // needless swscale hop.
        let planar = matches!(family, EncoderFamily::Nvenc);
        Some(if self.is_h264() {
            // H.264: 8-bit 4:2:0 is the only option on either family.
            if planar { "yuv420p" } else { "nv12" }
        } else if depth > 8 {
            // HEVC: drop the chroma, but keep the source's precision. Every
            // NVENC from Pascal on, and every QSV with an HEVC VDENC, takes
            // 10-bit 4:2:0.
            "p010le"
        } else if planar {
            "yuv420p"
        } else {
            "nv12"
        })
    }

    /// Encoder presets this codec accepts. Mirrors `availablePresets` in
    /// `app/lib/models/video_job.dart` — keep the two in step.
    pub fn available_presets(&self) -> &'static [&'static str] {
        match self.encoder_family() {
            EncoderFamily::Software => &[
                "ultrafast", "superfast", "veryfast", "faster", "fast", "medium",
                "slow", "slower", "veryslow", "placebo",
            ],
            EncoderFamily::Nvenc => &["p1", "p2", "p3", "p4", "p5", "p6", "p7"],
            EncoderFamily::Qsv => &[
                "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow",
            ],
            EncoderFamily::Amf => &["speed", "balanced", "quality"],
            // VideoToolbox, ProRes and the lossless codecs take no preset.
            _ => &[],
        }
    }

    /// The preset to fall back on when the configured one isn't accepted.
    pub fn default_preset(&self) -> &'static str {
        match self.encoder_family() {
            EncoderFamily::Nvenc => "p4",
            EncoderFamily::Amf => "balanced",
            _ => "medium",
        }
    }

    /// The configured preset if this encoder accepts it, else its default.
    ///
    /// Preset vocabularies are per-family and don't overlap — x264's "medium"
    /// means nothing to AMF, which wants speed/balanced/quality. A saved preset
    /// or an imported job config can pair a codec with another family's preset,
    /// and passing that through makes ffmpeg reject the option and fail the
    /// whole encode. Falling back keeps the job running with a sane setting.
    pub fn normalized_preset(&self, configured: &str) -> String {
        let allowed = self.available_presets();
        if allowed.is_empty() || allowed.contains(&configured) {
            configured.to_string()
        } else {
            self.default_preset().to_string()
        }
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
            VideoCodec::FFV1 | VideoCodec::Huffyuv | VideoCodec::Ffvhuff => EncoderFamily::Lossless,
            _ => EncoderFamily::ProRes,
        }
    }

    /// Get the preferred container format for this codec.
    pub fn preferred_container(&self) -> ContainerFormat {
        if self.is_prores() {
            ContainerFormat::Mov
        } else if self.is_lossless() {
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
            VideoCodec::Huffyuv => "HuffYUV (Lossless)",
            VideoCodec::Ffvhuff => "FFVHuff (Lossless)",
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

    /// Issue #74: a 4:2:2 source killed every NVENC job on pre-Blackwell
    /// hardware, because a recent ffmpeg advertises `yuv422p` on `h264_nvenc`
    /// and only the driver knows the card can't do it. The pipeline must pick
    /// the format itself rather than leaving it to negotiation.
    #[test]
    fn test_nvenc_cannot_be_handed_422() {
        // The exact case reported: CineForm yuv422p10le -> h264_nvenc.
        assert_eq!(
            VideoCodec::H264Nvenc.forced_pix_fmt("yuv422p10le"),
            Some("yuv420p")
        );
        // HEVC drops the chroma but keeps the 10 bits.
        assert_eq!(
            VideoCodec::H265Nvenc.forced_pix_fmt("yuv422p10le"),
            Some("p010le")
        );
        // 8-bit 4:2:2 needs no depth change, only the chroma.
        assert_eq!(
            VideoCodec::H265Nvenc.forced_pix_fmt("yuv422p"),
            Some("yuv420p")
        );
        // 4:4:4 is equally unencodable: `build_encoder_quality_args` pins
        // h264_nvenc to `-profile:v high`, which is a 4:2:0 profile.
        assert_eq!(
            VideoCodec::H264Nvenc.forced_pix_fmt("yuv444p"),
            Some("yuv420p")
        );
    }

    /// The guard must stay off for what already worked. Pinning NVENC
    /// unconditionally (as AMF is pinned) would silently flatten a 10-bit
    /// 4:2:0 source to 8-bit for everyone it currently serves correctly.
    #[test]
    fn test_nvenc_leaves_encodable_formats_alone() {
        assert_eq!(VideoCodec::H264Nvenc.forced_pix_fmt("yuv420p"), None);
        assert_eq!(VideoCodec::H265Nvenc.forced_pix_fmt("yuv420p"), None);
        // 10-bit 4:2:0 into HEVC is exactly what NVENC is good at — untouched.
        assert_eq!(VideoCodec::H265Nvenc.forced_pix_fmt("yuv420p10le"), None);
        assert_eq!(VideoCodec::H265Nvenc.forced_pix_fmt("p010le"), None);
    }

    /// H.264 has no 10-bit mode on either hardware family, so depth alone is
    /// enough to force a conversion even when the chroma is already fine.
    #[test]
    fn test_h264_hardware_has_no_10_bit_mode() {
        assert_eq!(
            VideoCodec::H264Nvenc.forced_pix_fmt("yuv420p10le"),
            Some("yuv420p")
        );
        assert_eq!(
            VideoCodec::H264Qsv.forced_pix_fmt("yuv420p10le"),
            Some("nv12")
        );
    }

    /// QSV is the same class of trap — `hevc_qsv` advertises 4:2:2 (`y210le`)
    /// on builds where the hardware may not have it. Not reported, guarded on
    /// the same reasoning. QSV's native layout is semi-planar, so it gets
    /// nv12 where NVENC gets yuv420p.
    #[test]
    fn test_qsv_takes_its_own_native_formats() {
        assert_eq!(VideoCodec::H264Qsv.forced_pix_fmt("yuv422p"), Some("nv12"));
        assert_eq!(
            VideoCodec::H265Qsv.forced_pix_fmt("yuv422p10le"),
            Some("p010le")
        );
        assert_eq!(VideoCodec::H265Qsv.forced_pix_fmt("yuv422p"), Some("nv12"));
        assert_eq!(VideoCodec::H264Qsv.forced_pix_fmt("yuv420p"), None);
    }

    /// The two unconditional pins predate this and must not become conditional:
    /// they hold whatever the pipeline's format is.
    #[test]
    fn test_unconditional_pins_ignore_the_input_format() {
        for fmt in ["yuv420p", "yuv422p10le", "yuv444p16le", "nv12"] {
            assert_eq!(VideoCodec::Huffyuv.forced_pix_fmt(fmt), Some("yuv422p"));
            assert_eq!(VideoCodec::H264Amf.forced_pix_fmt(fmt), Some("nv12"));
            assert_eq!(VideoCodec::H265Amf.forced_pix_fmt(fmt), Some("nv12"));
        }
    }

    /// Software, ProRes, lossless and VideoToolbox negotiate correctly on their
    /// own — VideoToolbox never advertises a mode it lacks, which is the whole
    /// difference from NVENC. Forcing a format on them would only throw away
    /// chroma they can keep.
    #[test]
    fn test_negotiating_encoders_are_left_alone() {
        for codec in [
            VideoCodec::H264,
            VideoCodec::H265,
            VideoCodec::H264Videotoolbox,
            VideoCodec::H265Videotoolbox,
            VideoCodec::ProRes422,
            VideoCodec::FFV1,
            VideoCodec::Ffvhuff,
        ] {
            for fmt in ["yuv420p", "yuv422p10le", "yuv444p16le"] {
                assert_eq!(
                    codec.forced_pix_fmt(fmt),
                    None,
                    "{codec:?} should negotiate {fmt} itself"
                );
            }
        }
    }

    /// The two names for the output conversion describe the same thing, so a
    /// variant gaining one and not the other is a bug — the ffmpeg name is what
    /// decides whether a hardware encoder can take it.
    #[test]
    fn chroma_subsampling_names_agree() {
        for cs in [
            ChromaSubsampling::Original,
            ChromaSubsampling::Yuv420,
            ChromaSubsampling::Yuv420P10,
            ChromaSubsampling::Yuv422,
            ChromaSubsampling::Yuv422P10,
        ] {
            assert_eq!(
                cs.vapoursynth_format().is_some(),
                cs.ffmpeg_pix_fmt().is_some(),
                "{cs:?} declares one output format name but not the other"
            );
        }
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
