//! What each output container holds and how it times it (task #49): the one
//! statement, `Tests/TestResources/output_capabilities.json`, compiled in by
//! `build.rs` and read by the app from its generated twin
//! (`app/lib/models/output_capabilities_table.dart`).
//!
//! Every container fact the worker acts on is a read of this table: the
//! stream start (`ContainerFormat::stores_stream_start`), the field flag
//! (`pipeline_executor::field_order_note`), the subtitle form, faststart and
//! `hvc1` (`is_iso_media`), AVI's block-align timing (`avi_header`), the
//! restored track's codec (`audio_restoration::restored_passthrough_codec`),
//! and which video, Convert and copied audio codecs each container takes.
//! `no_container_is_compared_outside_the_table` keeps it that way: a new
//! container fact belongs in the file, not in another `== ContainerFormat::Avi`.

use std::sync::OnceLock;

use serde::Deserialize;

use super::{AudioCodec, ContainerFormat, VideoCodec};

include!(concat!(env!("OUT_DIR"), "/output_capabilities.rs"));

/// Whether a video codec may be written to a container.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Verdict {
    /// The app offers it.
    Offered,
    /// FFmpeg writes it, but it is kept off (few players read it there).
    NotOffered,
    /// FFmpeg cannot write it.
    Refused,
}

/// How the container times its video.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VideoTimeBase {
    /// One tick per frame (AVI): a late picture becomes null frames.
    Frame,
    /// Per-packet timestamps.
    Timestamps,
}

/// How players time the container's audio.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AudioPacketTiming {
    /// A VBR chunk is timed by `nBlockAlign` (AVI, task #41).
    BlockAlign,
    /// Per-packet timestamps.
    Timestamps,
}

/// The form a muxed subtitle stream takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SubtitleForm {
    /// SRT copied as is (Matroska).
    Copy,
    /// Converted to `mov_text` (MP4/MOV).
    MovText,
    /// No subtitle stream (AVI).
    None,
}

/// One container's row of the table.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ContainerTraits {
    pub container: ContainerFormat,
    /// Whether the container records where each stream starts.
    pub stores_stream_start: bool,
    pub video_time_base: VideoTimeBase,
    /// Whether the container can flag an interlaced picture's field order.
    pub field_flag: bool,
    pub audio_packet_timing: AudioPacketTiming,
    /// The restored track's codec (ffmpeg name) under Passthrough, unless
    /// the video is an editing intermediate.
    pub restored_passthrough: String,
    pub subtitles: SubtitleForm,
    /// An ISO base media file (MP4/MOV): `+faststart` and `hvc1` apply.
    pub iso_media: bool,
}

/// One video codec × container row.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct VideoRow {
    pub codec: VideoCodec,
    pub container: ContainerFormat,
    pub verdict: Verdict,
    /// The refusal, exactly when not offered.
    pub message: Option<String>,
    /// The encoder the mux check uses in place of one a CI runner lacks.
    pub mux_encoder: Option<String>,
    /// A refused pair FFmpeg does write (AV1 in AVI, a non-standard tag).
    #[serde(default)]
    pub ffmpeg_writes: bool,
}

/// One Convert audio codec × container row (task #39's).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AudioConvertRow {
    pub codec: AudioCodec,
    pub container: ContainerFormat,
    pub supported: bool,
    pub message: Option<String>,
}

/// The whole table.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputCapabilities {
    pub containers: Vec<ContainerTraits>,
    pub video: Vec<VideoRow>,
    pub audio_convert: Vec<AudioConvertRow>,
    /// Codec names (ffprobe's `codec_name`) each container takes as a copy.
    pub audio_copy: std::collections::BTreeMap<ContainerFormat, Vec<String>>,
    pub audio_copy_message: String,
}

impl OutputCapabilities {
    /// The compiled-in table. `build.rs` has checked its shape; the enum
    /// names are checked here, on first use, and by `the_table_parses`.
    pub fn get() -> &'static OutputCapabilities {
        static TABLE: OnceLock<OutputCapabilities> = OnceLock::new();
        TABLE.get_or_init(|| {
            serde_json::from_str(TABLE_JSON)
                .unwrap_or_else(|e| panic!("Tests/TestResources/output_capabilities.json: {e}"))
        })
    }

    fn video_row(&self, codec: VideoCodec, container: ContainerFormat) -> &VideoRow {
        self.video
            .iter()
            .find(|r| r.codec == codec && r.container == container)
            .unwrap_or_else(|| panic!("output_capabilities.json has no row for {codec:?} in {container:?}"))
    }

    fn audio_row(&self, codec: AudioCodec, container: ContainerFormat) -> &AudioConvertRow {
        self.audio_convert
            .iter()
            .find(|r| r.codec == codec && r.container == container)
            .unwrap_or_else(|| panic!("output_capabilities.json has no row for {codec:?} in {container:?}"))
    }
}

impl ContainerFormat {
    /// This container's row of the table.
    pub fn traits(&self) -> &'static ContainerTraits {
        OutputCapabilities::get()
            .containers
            .iter()
            .find(|t| t.container == *self)
            .unwrap_or_else(|| panic!("output_capabilities.json has no row for {self:?}"))
    }

    /// Whether the container records where each stream starts. Matroska and
    /// MP4/MOV (an edit list) do, so a stream copy's pre-roll before a trim's
    /// in-point is stored as a later video start and stays in sync. AVI does
    /// not: everything plays from 0, so the pre-roll would run the sound late
    /// (`audio_restoration::needs_sound_cut`).
    pub fn stores_stream_start(&self) -> bool {
        self.traits().stores_stream_start
    }

    /// Whether this is an ISO base media file (MP4/MOV).
    pub fn is_iso_media(&self) -> bool {
        self.traits().iso_media
    }
}

impl VideoCodec {
    /// Whether `container` may hold this codec.
    pub fn container_verdict(&self, container: ContainerFormat) -> Verdict {
        OutputCapabilities::get().video_row(*self, container).verdict
    }

    /// Whether the worker writes this codec to `container`: every pair but
    /// a refused one (HuffYUV, ProRes or v210 in MP4 and AV1 in MOV, which
    /// FFmpeg can't write; AV1 in AVI). A pair the app doesn't offer (FFV1
    /// in MOV, H.265 in AVI) runs with a note: tests and hand-written jobs use
    /// some (the field-order test's HuffYUV in MOV). Dart's
    /// `supportsContainer` is the narrower `Offered`.
    pub fn allows_container(&self, container: ContainerFormat) -> bool {
        self.container_verdict(container) != Verdict::Refused
    }

    /// Why the worker refuses this codec in `container`, in the user's
    /// words, or `None` when it doesn't.
    pub fn container_problem(&self, container: ContainerFormat) -> Option<&'static str> {
        let row = OutputCapabilities::get().video_row(*self, container);
        (row.verdict == Verdict::Refused).then(|| row.message.as_deref()).flatten()
    }

    /// The job-log note for a pair the app doesn't offer, or `None`.
    pub fn container_note(&self, container: ContainerFormat) -> Option<&'static str> {
        let row = OutputCapabilities::get().video_row(*self, container);
        (row.verdict == Verdict::NotOffered).then(|| row.message.as_deref()).flatten()
    }
}

impl AudioCodec {
    /// Whether the bundled FFmpeg can mux this codec into the container
    /// (task #39). MOV takes neither FLAC nor Opus ("only supported in MP4")
    /// and AVI has no Opus tag; no option changes that, so Convert refuses
    /// those pairs. Twin of Dart's `AudioCodec.supportsContainer`;
    /// `output_capabilities_test.dart` checks the table against the muxers.
    pub fn supports_container(&self, container: ContainerFormat) -> bool {
        OutputCapabilities::get().audio_row(*self, container).supported
    }

    /// Why this codec can't go into the container, in the user's words, or
    /// `None` when it can. Twin of Dart's `AudioCodec.containerProblem`.
    pub fn container_problem(&self, container: ContainerFormat) -> Option<String> {
        OutputCapabilities::get().audio_row(*self, container).message.clone()
    }
}

/// Whether `container` can take a copy of an audio stream whose ffprobe
/// `codec_name` is `codec` (Passthrough). Twin of Dart's
/// `AudioCompatibilityService.isCodecCompatible`.
pub fn audio_copy_allowed(codec: &str, container: ContainerFormat) -> bool {
    let codec = codec.to_ascii_lowercase();
    OutputCapabilities::get()
        .audio_copy
        .get(&container)
        .is_some_and(|names| names.iter().any(|n| *n == codec))
}

/// Why a copy of `codec` can't go into `container`, or `None` when it can.
/// The same words as Dart's `AudioCompatibilityService.copyProblem`.
pub fn audio_copy_problem(codec: &str, container: ContainerFormat) -> Option<String> {
    if audio_copy_allowed(codec, container) {
        return None;
    }
    let others: Vec<&str> = ContainerFormat::ALL
        .iter()
        .filter(|&&k| k != container && audio_copy_allowed(codec, k))
        .map(|k| k.short_name())
        .collect();
    let mut message = OutputCapabilities::get()
        .audio_copy_message
        .replace("{codec}", &codec.to_ascii_uppercase())
        .replace("{container}", container.short_name());
    message = if others.is_empty() {
        message.replace(", or save as {containers}", "")
    } else {
        message.replace("{containers}", &super::video_job::join_or(&others))
    };
    Some(message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AudioMode, EncodingSettings};

    #[test]
    fn the_table_parses() {
        let t = OutputCapabilities::get();
        assert_eq!(t.containers.len(), ContainerFormat::ALL.len());
    }

    /// Every container has one row; every video and Convert codec has one
    /// row per container; the copy map names every container.
    #[test]
    fn the_table_is_complete() {
        let t = OutputCapabilities::get();
        for &k in ContainerFormat::ALL {
            assert_eq!(t.containers.iter().filter(|r| r.container == k).count(), 1, "{k:?}");
            assert!(t.audio_copy.contains_key(&k), "{k:?}");
            for &c in VideoCodec::ALL {
                assert_eq!(t.video.iter().filter(|r| r.codec == c && r.container == k).count(), 1, "{c:?}/{k:?}");
            }
            for &c in AudioCodec::ALL {
                assert_eq!(
                    t.audio_convert.iter().filter(|r| r.codec == c && r.container == k).count(),
                    1,
                    "{c:?}/{k:?}"
                );
            }
        }
        assert_eq!(t.video.len(), VideoCodec::ALL.len() * ContainerFormat::ALL.len());
        assert_eq!(t.audio_convert.len(), AudioCodec::ALL.len() * ContainerFormat::ALL.len());
    }

    /// The table agrees with itself: the restored track can be copied into
    /// its container, every codec's preferred container is offered, and the
    /// app's fallbacks (AAC, PCM) fit everywhere.
    #[test]
    fn the_table_is_consistent() {
        for &k in ContainerFormat::ALL {
            let t = k.traits();
            assert!(audio_copy_allowed(&t.restored_passthrough, k), "{k:?}: {}", t.restored_passthrough);
            assert!(audio_copy_allowed("pcm_s24le", k), "{k:?}: the editing intermediates' restored track");
            assert!(AudioCodec::Aac.supports_container(k), "{k:?}");
            assert!(AudioCodec::Pcm.supports_container(k), "{k:?}");
            // A container that can't record a stream start times by frame.
            assert_eq!(t.stores_stream_start, t.video_time_base == VideoTimeBase::Timestamps, "{k:?}");
            for &c in AudioCodec::ALL {
                // ffprobe names what libmp3lame and libopus write mp3 and opus.
                let probed = c.ffmpeg_name().trim_start_matches("lib").replace("mp3lame", "mp3");
                if c.supports_container(k) {
                    assert!(audio_copy_allowed(&probed, k), "Convert {c:?} into {k:?} but its copy is refused");
                }
            }
        }
        for &c in VideoCodec::ALL {
            assert_eq!(c.container_verdict(c.preferred_container()), Verdict::Offered, "{c:?}");
            assert!(ContainerFormat::ALL.iter().any(|&k| c.allows_container(k)), "{c:?}");
        }
    }

    /// The worker refuses every refused pair with the row's words, notes
    /// every pair the app doesn't offer, and says nothing about the rest.
    #[test]
    fn video_refusals_follow_the_verdicts() {
        for &k in ContainerFormat::ALL {
            for &c in VideoCodec::ALL {
                let v = c.container_verdict(k);
                assert_eq!(c.allows_container(k), v != Verdict::Refused);
                assert_eq!(c.container_problem(k).is_some(), v == Verdict::Refused, "{c:?}/{k:?}");
                assert_eq!(c.container_note(k).is_some(), v == Verdict::NotOffered, "{c:?}/{k:?}");
            }
        }
        let t = OutputCapabilities::get();
        assert!(t.video.iter().all(|r| !r.ffmpeg_writes || r.verdict == Verdict::Refused));
        assert_eq!(VideoCodec::Av1.container_verdict(ContainerFormat::Mov), Verdict::Refused);
        assert_eq!(VideoCodec::Av1.container_verdict(ContainerFormat::Avi), Verdict::Refused);
        assert_eq!(VideoCodec::FFV1.container_verdict(ContainerFormat::Mov), Verdict::NotOffered);
        assert_eq!(VideoCodec::Huffyuv.container_verdict(ContainerFormat::Mp4), Verdict::Refused);
        assert_eq!(VideoCodec::H265.container_verdict(ContainerFormat::Avi), Verdict::NotOffered);
        assert!(VideoCodec::Av1.container_problem(ContainerFormat::Mov).unwrap().contains("Choose MP4 or MKV"));
    }

    #[test]
    fn the_traits_are_what_the_rules_say() {
        let avi = ContainerFormat::Avi.traits();
        assert!(!avi.stores_stream_start && !avi.field_flag && !avi.iso_media);
        assert_eq!(avi.audio_packet_timing, AudioPacketTiming::BlockAlign);
        assert_eq!(avi.subtitles, SubtitleForm::None);
        assert_eq!(ContainerFormat::Mkv.traits().subtitles, SubtitleForm::Copy);
        for k in [ContainerFormat::Mp4, ContainerFormat::Mov] {
            assert!(k.is_iso_media());
            assert_eq!(k.traits().subtitles, SubtitleForm::MovText);
        }
        assert!(!ContainerFormat::Mkv.is_iso_media());
    }

    #[test]
    fn copy_problems() {
        assert!(audio_copy_allowed("mp2", ContainerFormat::Avi));
        assert!(audio_copy_allowed("AAC", ContainerFormat::Mp4));
        assert_eq!(audio_copy_problem("aac", ContainerFormat::Mp4), None);
        assert_eq!(
            audio_copy_problem("opus", ContainerFormat::Avi).as_deref(),
            Some("OPUS audio can't be copied into AVI files. Choose Convert in Settings \u{2192} Audio, or save as MP4 or MKV.")
        );
        assert_eq!(
            audio_copy_problem("wmav2", ContainerFormat::Mkv).as_deref(),
            Some("WMAV2 audio can't be copied into MKV files. Choose Convert in Settings \u{2192} Audio.")
        );
    }

    /// Convert's codec x container table and its wording (task #39).
    #[test]
    fn convert_refusals_follow_the_table() {
        for row in &OutputCapabilities::get().audio_convert {
            let (codec, container) = (row.codec, row.container);
            assert_eq!(codec.container_problem(container), row.message);
            let mut settings = EncodingSettings::default();
            settings.audio_codec = codec;
            settings.container = container;
            settings.audio_mode = AudioMode::Convert;
            assert_eq!(settings.audio_container_problem(), row.message);
            for mode in [AudioMode::Passthrough, AudioMode::None] {
                settings.audio_mode = mode;
                assert_eq!(settings.audio_container_problem(), None, "{mode:?}");
            }
        }
    }
}

#[cfg(test)]
mod lint {
    use std::path::Path;

    /// The non-test part of a Rust source: everything before its
    /// `#[cfg(test)]` module.
    fn non_test(text: &str) -> &str {
        text.find("#[cfg(test)]\nmod ").map_or(text, |i| &text[..i])
    }

    fn sources(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                sources(&p, out);
            } else if p.extension().is_some_and(|x| x == "rs") {
                out.push(p);
            }
        }
    }

    /// No worker code outside this module compares against or matches on a
    /// container (task #49): a container fact is a column of
    /// `output_capabilities.json`, read through `ContainerFormat::traits`.
    /// Allowed: the enum's own name functions (an arm whose value is a
    /// string literal), `ALL`, defaults and assignments.
    #[test]
    fn no_container_is_compared_outside_the_table() {
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = Vec::new();
        sources(&src, &mut files);
        let mut found = Vec::new();
        for f in files {
            if f.ends_with("models/output_capabilities.rs") {
                continue;
            }
            // A Windows checkout has CRLF line endings; `non_test` looks for "\n".
            let text = std::fs::read_to_string(&f).unwrap().replace("\r\n", "\n");
            for (n, line) in non_test(&text).lines().enumerate() {
                let code = line.split("//").next().unwrap();
                let compares = code.contains("== ContainerFormat::")
                    || code.contains("!= ContainerFormat::")
                    || (code.contains("matches!(") && code.contains("ContainerFormat::"));
                let arm = code.contains("ContainerFormat::")
                    && code.contains("=>")
                    && !code.split("=>").nth(1).unwrap_or("").trim_start().starts_with('"');
                if compares || arm {
                    found.push(format!("{}:{}: {}", f.strip_prefix(&src).unwrap().display(), n + 1, line.trim()));
                }
            }
        }
        assert!(
            found.is_empty(),
            "container decisions belong in Tests/TestResources/output_capabilities.json \
             (read through ContainerFormat::traits):\n{}",
            found.join("\n")
        );
    }
}
