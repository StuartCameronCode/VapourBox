//! HDR sources (issue #133): the static metadata an HDR10 file carries beside
//! its colour tags, and what kind of Dolby Vision stream it is.
//!
//! The four colour tags (`ColorMetadata`) say a picture is PQ or HLG in
//! BT.2020, and they already reach the output. An HDR10 file also states the
//! mastering display's primaries and luminance and the content's light levels
//! (MaxCLL/MaxFALL), which a TV uses to tone-map it. Those travel as side data,
//! not tags: the Y4M pipe drops them along with everything else, and ffmpeg has
//! no command-line flag to attach them to frames. libx265 is the one encoder we
//! offer that takes them as options, so the worker reads them from the source
//! and hands them over in `-x265-params`. Any other encoder writes the tags
//! only, which is still a valid HDR file, just without the hints.
//!
//! Dolby Vision is read for one decision only. Its dynamic metadata (the RPU)
//! is not carried: every filter changes the picture it describes, and
//! re-injecting it is a separate tool. What matters is the base layer, which
//! is all a non-Dolby decoder (ffmpeg's included) ever shows:
//!
//! * Profiles 8.1, 7 and the like have an HDR10 base layer. It decodes, looks
//!   and processes as ordinary HDR10, and the output plays as HDR10.
//! * Profile 8.4 has an HLG base layer and is ordinary HLG likewise.
//! * Profile 5 (`dv_bl_signal_compatibility_id` 0) stores IPTPQc2, Dolby's own
//!   colour space, which only the RPU's reshaping turns back into YCbCr.
//!   Decoded without it, the picture is pink and green. Nothing in the bundled
//!   FFmpeg can apply the reshaping (libplacebo isn't built in on macOS), so
//!   the best we can do is say so.

use std::path::Path;
use std::process::{Command, Stdio};

use crate::models::{LogLevel, VideoCodec};

/// Packets ffprobe may read looking for the first frame's side data. One is
/// not enough: a decoder with reorder delay emits nothing for the first few.
const PROBE_PACKETS: &str = "%+#8";

/// Mastering display colour volume (SMPTE ST 2086), stored in the units
/// x265's `master-display` takes: chromaticities in 0.00002, luminance in
/// 0.0001 cd/m².
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MasteringDisplay {
    pub red: (u32, u32),
    pub green: (u32, u32),
    pub blue: (u32, u32),
    pub white_point: (u32, u32),
    pub max_luminance: u32,
    pub min_luminance: u32,
}

/// Content light level (MaxCLL / MaxFALL), in cd/m².
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContentLight {
    pub max_cll: u32,
    pub max_fall: u32,
}

/// What the Dolby Vision configuration record says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DolbyVision {
    /// `dv_profile`, or `None` when only per-frame RPUs were found.
    pub profile: Option<u32>,
    /// `dv_bl_signal_compatibility_id`: 0 is no backward-compatible base
    /// layer, 1 HDR10, 2 SDR, 4 HLG, 6 Blu-ray HDR10.
    pub compatibility_id: Option<u32>,
}

impl DolbyVision {
    /// Whether the base layer is Dolby's IPTPQc2 rather than YCbCr — the
    /// Profile 5 case, which decodes pink and green without the RPU.
    pub fn base_layer_is_undecodable(&self) -> bool {
        self.profile == Some(5) || self.compatibility_id == Some(0)
    }

    /// "Dolby Vision Profile 8.1", "Dolby Vision Profile 5", "Dolby Vision".
    pub fn label(&self) -> String {
        match (self.profile, self.compatibility_id) {
            (Some(p), Some(c)) if c > 0 => format!("Dolby Vision Profile {p}.{c}"),
            (Some(p), _) => format!("Dolby Vision Profile {p}"),
            (None, _) => "Dolby Vision".to_string(),
        }
    }
}

/// Everything the worker reads about a source's HDR beyond its colour tags.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HdrMetadata {
    pub mastering_display: Option<MasteringDisplay>,
    pub content_light: Option<ContentLight>,
    pub dolby_vision: Option<DolbyVision>,
}

/// Parse an ffprobe rational ("34000/50000", "1000", "0/1").
fn rational(value: &serde_json::Value) -> Option<f64> {
    let s = match value {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        _ => return None,
    };
    let (n, d) = s.trim().split_once('/').unwrap_or((s.trim(), "1"));
    let (n, d) = (n.parse::<f64>().ok()?, d.parse::<f64>().ok()?);
    (d != 0.0 && n >= 0.0).then(|| n / d)
}

fn uint(value: Option<&serde_json::Value>) -> Option<u32> {
    value?.as_u64().and_then(|v| u32::try_from(v).ok())
}

fn parse_mastering(entry: &serde_json::Value) -> Option<MasteringDisplay> {
    let chroma = |key: &str| -> Option<u32> {
        let v = rational(entry.get(key)?)?;
        (v > 0.0 && v <= 1.0).then(|| (v * 50_000.0).round() as u32)
    };
    let luminance = |key: &str| -> Option<u32> {
        Some((rational(entry.get(key)?)? * 10_000.0).round() as u32)
    };
    // x265 wants the whole string or nothing: a file that declares only the
    // luminance (or only the primaries) gets no mastering SEI rather than
    // invented values for the rest.
    let md = MasteringDisplay {
        red: (chroma("red_x")?, chroma("red_y")?),
        green: (chroma("green_x")?, chroma("green_y")?),
        blue: (chroma("blue_x")?, chroma("blue_y")?),
        white_point: (chroma("white_point_x")?, chroma("white_point_y")?),
        max_luminance: luminance("max_luminance")?,
        min_luminance: luminance("min_luminance")?,
    };
    (md.max_luminance > md.min_luminance).then_some(md)
}

fn parse_content_light(entry: &serde_json::Value) -> Option<ContentLight> {
    let cl = ContentLight {
        max_cll: uint(entry.get("max_content"))?,
        max_fall: uint(entry.get("max_average"))?,
    };
    (cl.max_cll > 0 || cl.max_fall > 0).then_some(cl)
}

impl HdrMetadata {
    /// Read from `ffprobe -show_streams -show_frames -of json` output.
    ///
    /// Stream-level side data (an MP4 `mdcv`/`clli` box, Matroska's colour
    /// elements, the `dvcC`/`dvvC` record) wins; the first frame's SEI is the
    /// fallback, since a raw or remuxed stream often has only that.
    pub fn from_ffprobe_json(json: &serde_json::Value) -> Self {
        let empty = Vec::new();
        let side_data = |v: Option<&serde_json::Value>| -> Vec<serde_json::Value> {
            v.and_then(|v| v.get("side_data_list"))
                .and_then(|l| l.as_array())
                .unwrap_or(&empty)
                .clone()
        };
        let stream = side_data(json.get("streams").and_then(|s| s.get(0)));
        let frames: Vec<Vec<serde_json::Value>> = json
            .get("frames")
            .and_then(|f| f.as_array())
            .map(|f| f.iter().map(|frame| side_data(Some(frame))).collect())
            .unwrap_or_default();

        let find = |kind: &str| -> Vec<&serde_json::Value> {
            stream
                .iter()
                .chain(frames.iter().flatten())
                .filter(|e| e.get("side_data_type").and_then(|t| t.as_str()) == Some(kind))
                .collect()
        };

        let dolby_vision = find("DOVI configuration record")
            .first()
            .map(|e| DolbyVision {
                profile: uint(e.get("dv_profile")),
                compatibility_id: uint(e.get("dv_bl_signal_compatibility_id")),
            })
            .or_else(|| {
                (!find("Dolby Vision RPU Data").is_empty()
                    || !find("Dolby Vision Metadata").is_empty())
                .then_some(DolbyVision { profile: None, compatibility_id: None })
            });

        Self {
            mastering_display: find("Mastering display metadata")
                .into_iter()
                .find_map(parse_mastering),
            content_light: find("Content light level metadata")
                .into_iter()
                .find_map(parse_content_light),
            dolby_vision,
        }
    }

    /// Probe a source. Never fails: a file ffprobe can't read is treated as
    /// carrying no HDR metadata, which only means the output doesn't either.
    pub fn probe(
        ffprobe: &Path,
        env: &std::collections::HashMap<String, String>,
        input: &str,
    ) -> Self {
        let out = Command::new(ffprobe)
            .args([
                "-v", "error",
                "-select_streams", "v:0",
                "-read_intervals", PROBE_PACKETS,
                "-show_streams",
                "-show_frames",
                "-of", "json",
                input,
            ])
            .envs(env)
            .stderr(Stdio::null())
            .output();
        out.ok()
            .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
            .map(|json| Self::from_ffprobe_json(&json))
            .unwrap_or_default()
    }

    /// x265's spelling of the static metadata, or `None` when there is none.
    pub fn x265_params(&self) -> Option<String> {
        let mut params = Vec::new();
        if let Some(md) = self.mastering_display {
            params.push(format!(
                "master-display=G({},{})B({},{})R({},{})WP({},{})L({},{})",
                md.green.0, md.green.1,
                md.blue.0, md.blue.1,
                md.red.0, md.red.1,
                md.white_point.0, md.white_point.1,
                md.max_luminance, md.min_luminance,
            ));
        }
        if let Some(cl) = self.content_light {
            params.push(format!("max-cll={},{}", cl.max_cll, cl.max_fall));
        }
        (!params.is_empty()).then(|| params.join(":"))
    }

    /// Encoder options that carry the static metadata, for `codec`. Only
    /// libx265 takes them on the command line; every other encoder gets
    /// nothing (and `log_lines` says so). Nothing either for a source whose
    /// tags aren't PQ/HLG: mastering SEI on an SDR file is a wrong statement.
    pub fn encoder_args(&self, codec: VideoCodec, hdr_transfer: bool) -> Vec<String> {
        if !hdr_transfer {
            return Vec::new();
        }
        match (codec, self.x265_params()) {
            (VideoCodec::H265, Some(params)) => vec!["-x265-params".to_string(), params],
            _ => Vec::new(),
        }
    }

    /// What the job log should say about this source's HDR, one line each.
    /// `hdr_transfer` is whether the colour tags are PQ or HLG.
    pub fn log_lines(&self, codec: VideoCodec, hdr_transfer: bool) -> Vec<(LogLevel, String)> {
        let mut lines = Vec::new();
        if let Some(dv) = self.dolby_vision {
            if dv.base_layer_is_undecodable() {
                lines.push((LogLevel::Warning, format!(
                    "{}: this file stores its picture in Dolby's own IPT colour space, \
                     which only a Dolby Vision decoder can convert. VapourBox cannot, \
                     so the colours in the output will be wrong (pink and green).",
                    dv.label()
                )));
            } else {
                lines.push((LogLevel::Info, format!(
                    "{}: processing the HDR base layer. The Dolby Vision dynamic \
                     metadata is not carried over, so the output plays as standard HDR.",
                    dv.label()
                )));
            }
        }
        if hdr_transfer && self.x265_params().is_some() {
            if codec == VideoCodec::H265 {
                lines.push((
                    LogLevel::Info,
                    "HDR10 mastering display / light level metadata carried to the output.".to_string(),
                ));
            } else {
                lines.push((LogLevel::Info, format!(
                    "HDR10 mastering display / light level metadata is only written by \
                     H.265 (x265); {} keeps the HDR colour tags without it.",
                    codec.ffmpeg_codec()
                )));
            }
        }
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// ffprobe's own output for a Dolby Vision 8.1 MP4 made with x265 +
    /// dovi_tool: the config record and HDR10 metadata at stream level.
    fn profile_8_1() -> serde_json::Value {
        json!({
            "streams": [{
                "side_data_list": [
                    {
                        "side_data_type": "DOVI configuration record",
                        "dv_version_major": 1, "dv_version_minor": 0,
                        "dv_profile": 8, "dv_level": 1,
                        "rpu_present_flag": 1, "el_present_flag": 0, "bl_present_flag": 1,
                        "dv_bl_signal_compatibility_id": 1
                    },
                    {
                        "side_data_type": "Mastering display metadata",
                        "red_x": "34000/50000", "red_y": "16000/50000",
                        "green_x": "13250/50000", "green_y": "34500/50000",
                        "blue_x": "7500/50000", "blue_y": "3000/50000",
                        "white_point_x": "15635/50000", "white_point_y": "16450/50000",
                        "min_luminance": "1/10000", "max_luminance": "10000000/10000"
                    },
                    {
                        "side_data_type": "Content light level metadata",
                        "max_content": 1000, "max_average": 400
                    }
                ]
            }],
            "frames": []
        })
    }

    #[test]
    fn reads_profile_8_1_and_its_hdr10_metadata() {
        let hdr = HdrMetadata::from_ffprobe_json(&profile_8_1());
        let dv = hdr.dolby_vision.expect("Dolby Vision");
        assert_eq!(dv.profile, Some(8));
        assert_eq!(dv.label(), "Dolby Vision Profile 8.1");
        assert!(!dv.base_layer_is_undecodable());
        assert_eq!(
            hdr.x265_params().as_deref(),
            Some("master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400")
        );
    }

    /// x265 reads the string back exactly: the values must round-trip from the
    /// rationals ffprobe prints, not drift by a unit through float arithmetic.
    #[test]
    fn mastering_values_round_trip_exactly() {
        let hdr = HdrMetadata::from_ffprobe_json(&profile_8_1());
        let md = hdr.mastering_display.unwrap();
        assert_eq!(md.red, (34000, 16000));
        assert_eq!(md.white_point, (15635, 16450));
        assert_eq!((md.max_luminance, md.min_luminance), (10_000_000, 1));
    }

    #[test]
    fn profile_5_is_flagged_undecodable() {
        let json = json!({"streams": [{"side_data_list": [{
            "side_data_type": "DOVI configuration record",
            "dv_profile": 5, "dv_level": 6, "dv_bl_signal_compatibility_id": 0
        }]}]});
        let dv = HdrMetadata::from_ffprobe_json(&json).dolby_vision.unwrap();
        assert!(dv.base_layer_is_undecodable());
        assert_eq!(dv.label(), "Dolby Vision Profile 5");
        let lines = HdrMetadata { dolby_vision: Some(dv), ..Default::default() }
            .log_lines(VideoCodec::H265, true);
        assert_eq!(lines[0].0, LogLevel::Warning);
        assert!(lines[0].1.contains("pink and green"), "{lines:?}");
    }

    /// A raw or remuxed stream has no container-level boxes; the first frame's
    /// SEI still says what it is.
    #[test]
    fn falls_back_to_frame_side_data() {
        let json = json!({
            "streams": [{}],
            "frames": [
                {},
                {"side_data_list": [
                    {"side_data_type": "Content light level metadata", "max_content": 600, "max_average": 120},
                    {"side_data_type": "Dolby Vision RPU Data"}
                ]}
            ]
        });
        let hdr = HdrMetadata::from_ffprobe_json(&json);
        assert_eq!(hdr.content_light, Some(ContentLight { max_cll: 600, max_fall: 120 }));
        assert_eq!(hdr.dolby_vision.unwrap().label(), "Dolby Vision");
        assert_eq!(hdr.x265_params().as_deref(), Some("max-cll=600,120"));
    }

    /// Half a mastering record must not become an invented whole one.
    #[test]
    fn incomplete_mastering_record_is_dropped() {
        let json = json!({"streams": [{"side_data_list": [{
            "side_data_type": "Mastering display metadata",
            "min_luminance": "1/10000", "max_luminance": "10000000/10000"
        }]}]});
        let hdr = HdrMetadata::from_ffprobe_json(&json);
        assert_eq!(hdr.mastering_display, None);
        assert_eq!(hdr.x265_params(), None);
    }

    #[test]
    fn sdr_source_has_nothing_to_say() {
        let hdr = HdrMetadata::from_ffprobe_json(&json!({"streams": [{}], "frames": [{}]}));
        assert_eq!(hdr, HdrMetadata::default());
        for codec in VideoCodec::ALL {
            assert!(hdr.encoder_args(*codec, true).is_empty());
            assert!(hdr.log_lines(*codec, false).is_empty());
        }
    }

    /// Only libx265 takes the metadata on the command line; any other encoder
    /// handed `-x265-params` would fail to open.
    #[test]
    fn only_x265_gets_the_metadata() {
        let hdr = HdrMetadata::from_ffprobe_json(&profile_8_1());
        for codec in VideoCodec::ALL {
            assert!(hdr.encoder_args(*codec, false).is_empty(), "SDR tags: nothing");
            let args = hdr.encoder_args(*codec, true);
            if *codec == VideoCodec::H265 {
                assert_eq!(args[0], "-x265-params");
            } else {
                assert!(args.is_empty(), "{codec:?} must not get x265 options");
            }
        }
    }
}
