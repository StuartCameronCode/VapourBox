//! Chooses the raw pixel format the decoder ffmpeg feeds down the pipe.
//!
//! `templates/pipe_source.py` reads raw planar frames off stdin, so it can only
//! handle the formats in its `_FORMAT_MAP`. The app passes ffprobe's `pix_fmt`
//! through verbatim, and ffprobe reports plenty of formats that aren't in that
//! map — `yuv411p` (NTSC DV), `yuva444p10le` (ProRes 4444), `gbrp`, `rgb24`,
//! `gray`, `nv12`, `p010le`, … Asking the decoder for one of those used to fail
//! the whole job with "Unsupported pixel format".
//!
//! So this module is the single place that decides the pipe format: pass the
//! source format through when pipe_source can read it, and otherwise pick the
//! nearest format that *is* readable and let the decoder convert. The choice is
//! always a superset of the source (never lower chroma resolution or bit depth),
//! so normalization can't degrade the image.

/// Formats `templates/pipe_source.py` reads directly off the pipe.
///
/// KEEP IN SYNC with `_FORMAT_MAP` in that file —
/// `test_native_formats_match_pipe_source` fails if they drift.
pub const NATIVE_FORMATS: &[&str] = &[
    "yuv411p",
    "yuv420p",
    "yuv422p",
    "yuv444p",
    "yuv420p9le",
    "yuv422p9le",
    "yuv444p9le",
    "yuv420p10le",
    "yuv422p10le",
    "yuv444p10le",
    "yuv420p12le",
    "yuv422p12le",
    "yuv444p12le",
    "yuv420p14le",
    "yuv422p14le",
    "yuv444p14le",
    "yuv420p16le",
    "yuv422p16le",
    "yuv444p16le",
    "yuvj420p",
    "yuvj422p",
    "yuvj444p",
];

/// The format used when the source's is unknown (matches the historical
/// default, so nothing changes for the common case).
pub const DEFAULT_FORMAT: &str = "yuv420p";

/// Chroma resolution class of a source format. Ordered so that a source is
/// always mapped to a class at least as detailed as its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ChromaClass {
    C420,
    C422,
    C444,
}

/// The pipe format for a job, plus what it was converted from (if anything).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PipeFormat {
    /// The `-pix_fmt` to request from the decoder ffmpeg, and the name handed
    /// to `create_pipe_clip`.
    pub name: String,
    /// `Some(source_format)` when the source can't be read off the pipe and the
    /// decoder converts it. `None` when the source format is used as-is.
    pub converted_from: Option<String>,
}

impl PipeFormat {
    /// A human-readable note about the conversion, for the job log.
    pub fn conversion_note(&self) -> Option<String> {
        self.converted_from.as_ref().map(|from| {
            format!(
                "Source pixel format {} can't be read directly; decoding as {} instead",
                from, self.name
            )
        })
    }
}

/// The raw pixel format to pipe for a source whose probed format is `probed`.
pub fn decode_pixel_format(probed: Option<&str>) -> PipeFormat {
    let probed = probed.map(str::trim).filter(|s| !s.is_empty());

    let Some(probed) = probed else {
        return PipeFormat {
            name: DEFAULT_FORMAT.to_string(),
            converted_from: None,
        };
    };

    let lower = probed.to_ascii_lowercase();
    if NATIVE_FORMATS.contains(&lower.as_str()) {
        return PipeFormat {
            name: lower,
            converted_from: None,
        };
    }

    let (class, depth) = classify(&lower);
    PipeFormat {
        name: native_name(class, depth),
        converted_from: Some(probed.to_string()),
    }
}

/// Chroma class and bit depth of an FFmpeg pixel format name.
///
/// Unrecognized names fall back to 4:4:4 16-bit — the format that can hold any
/// integer source ffmpeg produces, so an exotic input degrades in speed rather
/// than in quality.
fn classify(name: &str) -> (ChromaClass, u32) {
    // Semi-planar and packed formats whose digits are subsampling or channel
    // width rather than a bit depth, so the generic parse below can't be used.
    let explicit: &[(&str, ChromaClass, u32)] = &[
        ("nv12", ChromaClass::C420, 8),
        ("nv21", ChromaClass::C420, 8),
        ("nv16", ChromaClass::C422, 8),
        ("nv24", ChromaClass::C444, 8),
        ("nv42", ChromaClass::C444, 8),
        ("p010", ChromaClass::C420, 10),
        ("p012", ChromaClass::C420, 12),
        ("p016", ChromaClass::C420, 16),
        ("p210", ChromaClass::C422, 10),
        ("p212", ChromaClass::C422, 12),
        ("p216", ChromaClass::C422, 16),
        ("p410", ChromaClass::C444, 10),
        ("p412", ChromaClass::C444, 12),
        ("p416", ChromaClass::C444, 16),
        ("rgb24", ChromaClass::C444, 8),
        ("bgr24", ChromaClass::C444, 8),
        ("rgb48", ChromaClass::C444, 16),
        ("bgr48", ChromaClass::C444, 16),
        ("rgba64", ChromaClass::C444, 16),
        ("bgra64", ChromaClass::C444, 16),
    ];

    let stem = name.strip_suffix("le").or_else(|| name.strip_suffix("be")).unwrap_or(name);
    for (prefix, class, depth) in explicit {
        if stem == *prefix {
            return (*class, *depth);
        }
    }

    // Planar YUV (incl. yuvj/yuva) — the subsampling code carries the class and
    // an optional `p<depth>` the bit depth: yuv411p, yuva444p10le, yuv440p12le.
    for prefix in ["yuva", "yuvj", "yuv"] {
        if let Some(rest) = stem.strip_prefix(prefix) {
            if rest.len() >= 3 && rest[..3].chars().all(|c| c.is_ascii_digit()) {
                let class = match &rest[..3] {
                    // 4:1:0 and 4:1:1 subsample chroma more coarsely than 4:2:2
                    // horizontally, so 4:2:2 is a superset of both. 4:4:0 is a
                    // superset horizontally and equal vertically.
                    "410" | "411" | "422" | "440" => ChromaClass::C422,
                    "420" => ChromaClass::C420,
                    _ => ChromaClass::C444,
                };
                return (class, parse_depth(&rest[3..]).unwrap_or(8));
            }
        }
    }

    // Planar RGB and grayscale. Gray has no chroma at all, so any class holds
    // it; 4:2:0 is the cheapest.
    for (prefix, class) in [
        ("gbrap", ChromaClass::C444),
        ("gbrp", ChromaClass::C444),
        ("gray", ChromaClass::C420),
        ("ya", ChromaClass::C420),
    ] {
        if let Some(rest) = stem.strip_prefix(prefix) {
            return (class, parse_depth(rest).unwrap_or(8));
        }
    }

    // Packed RGB variants (rgba, argb, bgr0, rgb565, …) and anything else.
    if stem.starts_with("rgb") || stem.starts_with("bgr") || stem.starts_with("argb")
        || stem.starts_with("abgr")
    {
        return (ChromaClass::C444, 8);
    }

    (ChromaClass::C444, 16)
}

/// Bit depth from the tail of a format name (`"p10"` -> 10, `"12"` -> 12,
/// `""` -> None). Float depths (`f32`) map to 16, the deepest integer format
/// the pipeline works in.
fn parse_depth(tail: &str) -> Option<u32> {
    let tail = tail.strip_prefix('p').unwrap_or(tail);
    if tail.starts_with('f') {
        return Some(16);
    }
    if tail.is_empty() || !tail.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    tail.parse().ok()
}

/// The native format name for a chroma class at (at least) `depth` bits.
fn native_name(class: ChromaClass, depth: u32) -> String {
    // The depths VapourSynth has integer formats for. Round *up* so the pipe
    // format never has less precision than the source.
    let depth = [8, 9, 10, 12, 14, 16]
        .into_iter()
        .find(|d| *d >= depth)
        .unwrap_or(16);

    let class = match class {
        ChromaClass::C420 => "420",
        ChromaClass::C422 => "422",
        ChromaClass::C444 => "444",
    };

    if depth == 8 {
        format!("yuv{}p", class)
    } else {
        format!("yuv{}p{}le", class, depth)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name_of(probed: &str) -> String {
        decode_pixel_format(Some(probed)).name
    }

    #[test]
    fn test_native_formats_pass_through() {
        for fmt in NATIVE_FORMATS {
            let result = decode_pixel_format(Some(fmt));
            assert_eq!(&result.name, fmt);
            assert_eq!(result.converted_from, None, "{} should not convert", fmt);
        }
    }

    #[test]
    fn test_missing_format_uses_default() {
        assert_eq!(decode_pixel_format(None).name, DEFAULT_FORMAT);
        assert_eq!(decode_pixel_format(Some("  ")).name, DEFAULT_FORMAT);
        assert_eq!(decode_pixel_format(None).converted_from, None);
    }

    /// The bug from issue #50: NTSC DV is 4:1:1 and used to fail outright.
    #[test]
    fn test_dv_411_is_native() {
        let result = decode_pixel_format(Some("yuv411p"));
        assert_eq!(result.name, "yuv411p");
        assert_eq!(result.converted_from, None);
    }

    #[test]
    fn test_case_and_whitespace_are_normalized() {
        assert_eq!(name_of(" YUV420P "), "yuv420p");
    }

    #[test]
    fn test_exotic_planar_yuv_maps_to_superset() {
        // 4:1:0 and 4:4:0 are supersets of neither 4:2:0 nor each other, so both
        // go to 4:2:2 — never to something with less chroma than the source.
        assert_eq!(name_of("yuv410p"), "yuv422p");
        assert_eq!(name_of("yuv440p"), "yuv422p");
        assert_eq!(name_of("yuv440p10le"), "yuv422p10le");
        // Alpha is dropped (the pipeline has no use for it) but depth is kept.
        assert_eq!(name_of("yuva444p10le"), "yuv444p10le");
        assert_eq!(name_of("yuva420p"), "yuv420p");
    }

    #[test]
    fn test_depth_rounds_up_to_a_supported_depth() {
        // 11/13/15-bit don't exist in ffmpeg, but rounding up is what keeps an
        // unexpected depth from silently truncating.
        assert_eq!(native_name(ChromaClass::C420, 11), "yuv420p12le");
        assert_eq!(native_name(ChromaClass::C444, 13), "yuv444p14le");
        assert_eq!(native_name(ChromaClass::C422, 17), "yuv422p16le");
        assert_eq!(name_of("yuv444p32le"), "yuv444p16le");
    }

    #[test]
    fn test_rgb_and_gray_sources() {
        assert_eq!(name_of("rgb24"), "yuv444p");
        assert_eq!(name_of("rgba"), "yuv444p");
        assert_eq!(name_of("bgr48le"), "yuv444p16le");
        assert_eq!(name_of("gbrp"), "yuv444p");
        assert_eq!(name_of("gbrp10le"), "yuv444p10le");
        assert_eq!(name_of("gbrpf32le"), "yuv444p16le");
        assert_eq!(name_of("gray"), "yuv420p");
        assert_eq!(name_of("gray10le"), "yuv420p10le");
    }

    #[test]
    fn test_semi_planar_sources() {
        assert_eq!(name_of("nv12"), "yuv420p");
        assert_eq!(name_of("nv16"), "yuv422p");
        assert_eq!(name_of("p010le"), "yuv420p10le");
        assert_eq!(name_of("p416le"), "yuv444p16le");
    }

    #[test]
    fn test_unknown_format_falls_back_losslessly() {
        // Never seen this name? Pick the format that can hold anything.
        assert_eq!(name_of("some_future_format"), "yuv444p16le");
    }

    #[test]
    fn test_conversion_is_reported() {
        let result = decode_pixel_format(Some("rgb24"));
        assert_eq!(result.converted_from.as_deref(), Some("rgb24"));
        let note = result.conversion_note().unwrap();
        assert!(note.contains("rgb24"), "note should name the source: {}", note);
        assert!(note.contains("yuv444p"), "note should name the pipe format: {}", note);
    }

    /// The Python side is the actual consumer of these names, so a format added
    /// to one list and not the other is a runtime failure. Parse its map.
    #[test]
    fn test_native_formats_match_pipe_source() {
        let dir = crate::script_generator::ScriptGenerator::pipe_source_dir()
            .expect("pipe_source.py should be findable in tests");
        let source = std::fs::read_to_string(dir.join("pipe_source.py"))
            .expect("pipe_source.py should be readable");

        let map = source
            .split_once("_FORMAT_MAP = {")
            .expect("pipe_source.py should define _FORMAT_MAP")
            .1
            .split_once('}')
            .expect("_FORMAT_MAP should be closed")
            .0;

        let mut keys: Vec<&str> = map
            .lines()
            .filter_map(|line| line.trim().strip_prefix('\''))
            .filter_map(|rest| rest.split_once('\''))
            .map(|(key, _)| key)
            .collect();
        keys.sort_unstable();

        let mut native: Vec<&str> = NATIVE_FORMATS.to_vec();
        native.sort_unstable();

        assert_eq!(
            keys, native,
            "NATIVE_FORMATS and pipe_source.py's _FORMAT_MAP have drifted"
        );
    }
}
