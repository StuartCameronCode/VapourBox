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
//!
//! **14-bit is never piped** (task #23): fmtconv's `bitdepth` has no 14-bit
//! integer output (r31 and git-18a9cecb alike), and havsfunc returns to the
//! clip's own depth through it in `Bob`, `Resize(dmode=1)` and `Deblock_QED`.
//! A 14-bit clip failed QTGMC at every preset, Anti-aliasing (santiag) and
//! Deblock QED. A 14-bit (or 13-bit) source is decoded as 16-bit instead:
//! lossless (each 16-bit sample keeps the 14-bit value in its top bits; an
//! exact shift in limited range) and free (both are 2 bytes a sample). See
//! docs/reports/2026-11-14-bit-sources.
//!
//! **9-bit is never piped either** (task #31): CTMF has no 9-bit format, and
//! havsfunc reaches it through `MinBlur(r>=2)` (YAHR, HQDeringmod at HD,
//! ContraSharpening, SMDegrain's contrasharp at HD, MCTemporalDenoise's
//! pfMode 2, FineDehalo's contra). A 9-bit source is decoded as 10-bit
//! instead: lossless (an exact `<< 1` in limited range; full range keeps the
//! 9-bit value in the top 9 bits) and free. See docs/reports/2026-11-9-bit-sources.

/// Formats `templates/pipe_source.py` reads directly off the pipe.
///
/// KEEP IN SYNC with `_FORMAT_MAP` in that file —
/// `test_native_formats_match_pipe_source` fails if they drift.
pub const NATIVE_FORMATS: &[&str] = &[
    "yuv411p",
    "yuv420p",
    "yuv422p",
    "yuv444p",
    "yuv420p10le",
    "yuv422p10le",
    "yuv444p10le",
    "yuv420p12le",
    "yuv422p12le",
    "yuv444p12le",
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
///
/// `Ord` follows that declaration order, so `C420 < C422 < C444` and a
/// comparison reads as "carries at least as much chroma as".
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ChromaClass {
    C420,
    C422,
    C444,
}

impl ChromaClass {
    /// How this reads in a message to the user.
    pub fn label(&self) -> &'static str {
        match self {
            ChromaClass::C420 => "4:2:0",
            ChromaClass::C422 => "4:2:2",
            ChromaClass::C444 => "4:4:4",
        }
    }
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
                "Source pixel format {} is decoded as {} for processing",
                from, self.name
            )
        })
    }
}

/// Chroma class and bit depth of an FFmpeg pixel format name.
///
/// Public counterpart of [`classify`]. `VideoCodec::forced_pix_fmt` needs it to
/// decide whether the format the pipeline will hand a hardware encoder is one
/// that encoder can actually take — a question about the *output* of the graph,
/// where the rest of this module is about its input.
pub fn chroma_and_depth(name: &str) -> (ChromaClass, u32) {
    classify(&name.to_ascii_lowercase())
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
                    // 4:1:0 and 4:1:1 have at most 4:2:2's chroma on each
                    // axis, so 4:2:2 holds both. 4:4:0 (JPEG/MJPEG cameras)
                    // has full horizontal chroma, which 4:2:2 halves: only
                    // 4:4:4 holds it on both axes (task #100). It falls
                    // through to the C444 arm.
                    "410" | "411" | "422" => ChromaClass::C422,
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
    // The depths the pipeline works in. Round *up* so the pipe format never
    // has less precision than the source. 9 and 14 are deliberately absent:
    // CTMF has no 9-bit format and havsfunc's MinBlur(r>=2) calls it (task
    // #31, docs/reports/2026-11-9-bit-sources); fmtconv can't write 14-bit,
    // and havsfunc's Bob/Resize/Deblock_QED go back to the clip's depth
    // through it (task #23, docs/reports/2026-11-14-bit-sources).
    let depth = [8, 10, 12, 16]
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

/// The chroma grid of an FFmpeg pixel format: luma samples per chroma sample
/// across and down (4:2:0 `(2, 2)`, 4:2:2 `(2, 1)`, 4:1:1 `(4, 1)`, 4:4:4,
/// RGB and gray `(1, 1)`).
///
/// A frame whose size isn't a multiple of its format's grid is "off the
/// chroma grid" (task #97): FFmpeg stores and decodes it (its last chroma
/// sample covers fewer luma samples), but VapourSynth refuses a clip of that
/// format and size outright (`BlankClip: invalid width`).
pub fn chroma_grid(name: &str) -> (i32, i32) {
    let lower = name.trim().to_ascii_lowercase();
    let stem = lower.strip_suffix("le").or_else(|| lower.strip_suffix("be")).unwrap_or(&lower);
    for prefix in ["yuva", "yuvj", "yuv"] {
        if let Some(rest) = stem.strip_prefix(prefix) {
            if rest.len() >= 3 && rest[..3].chars().all(|c| c.is_ascii_digit()) {
                return match &rest[..3] {
                    "410" => (4, 2),
                    "411" => (4, 1),
                    "420" => (2, 2),
                    "422" => (2, 1),
                    "440" => (1, 2),
                    _ => (1, 1),
                };
            }
        }
    }
    match stem {
        "nv12" | "nv21" | "p010" | "p012" | "p016" => (2, 2),
        "nv16" | "p210" | "p212" | "p216" => (2, 1),
        _ => (1, 1),
    }
}

/// `value` rounded up to a multiple of `step` (a `step` below 1 counts as 1).
pub fn ceil_to(value: i32, step: i32) -> i32 {
    let step = step.max(1);
    (value + step - 1).div_euclid(step) * step
}

/// The columns and rows a `width` x `height` frame of `pix_fmt` lacks to
/// reach its chroma grid: `(0, 0)` for every frame VapourSynth accepts.
/// `pipe_source` repeats the last column / row into them (task #97).
pub fn grid_pad(pix_fmt: &str, width: i32, height: i32) -> (i32, i32) {
    let (gw, gh) = chroma_grid(pix_fmt);
    (ceil_to(width, gw) - width, ceil_to(height, gh) - height)
}

/// The least common multiple of two grid steps.
pub fn lcm(a: i32, b: i32) -> i32 {
    let (a, b) = (a.max(1), b.max(1));
    let (mut x, mut y) = (a, b);
    while y != 0 {
        (x, y) = (y, x % y);
    }
    a / x * b
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
        // 4:1:0 (quarter horizontal, half vertical) fits in 4:2:2. 4:4:0 has
        // full horizontal chroma, so only 4:4:4 holds it (task #100: it used to
        // go to 4:2:2, which halved it).
        assert_eq!(name_of("yuv410p"), "yuv422p");
        assert_eq!(name_of("yuv440p"), "yuv444p");
        assert_eq!(name_of("yuvj440p"), "yuv444p");
        assert_eq!(name_of("yuv440p10le"), "yuv444p10le");
        assert_eq!(name_of("yuv440p12le"), "yuv444p12le");
        // Alpha is dropped (the pipeline has no use for it) but depth is kept.
        assert_eq!(name_of("yuva444p10le"), "yuv444p10le");
        assert_eq!(name_of("yuva420p"), "yuv420p");
    }

    /// Task #100: 4:4:0 was piped as 4:2:2, which halves its horizontal
    /// chroma, because the class was judged on one axis. Check both axes for
    /// every planar YUV code, prefix and depth, so a wrong class fails here
    /// and not only on a hand-written row.
    #[test]
    fn pipe_format_never_has_less_chroma_on_either_axis() {
        for code in ["410", "411", "420", "422", "440", "444"] {
            let (sh, sv) = chroma_grid(&format!("yuv{code}p"));
            for prefix in ["yuv", "yuvj", "yuva"] {
                for depth in ["p", "p9le", "p10le", "p12le", "p14le", "p16le", "p10be"] {
                    let src = format!("{prefix}{code}{depth}");
                    let pipe = name_of(&src);
                    assert!(pipe.starts_with("yuv"), "{src} pipes as non-YUV {pipe}");
                    // chroma_grid: luma samples per chroma sample, each axis.
                    let (ph, pv) = chroma_grid(&pipe);
                    assert!(
                        ph <= sh && pv <= sv,
                        "{src} pipes as {pipe}: {ph}x{pv} subsampling loses chroma of {sh}x{sv}"
                    );
                }
            }
        }
    }

    #[test]
    fn test_depth_rounds_up_to_a_supported_depth() {
        // 11/13/15-bit don't exist in ffmpeg, but rounding up is what keeps an
        // unexpected depth from silently truncating.
        assert_eq!(native_name(ChromaClass::C420, 11), "yuv420p12le");
        assert_eq!(native_name(ChromaClass::C444, 13), "yuv444p16le");
        assert_eq!(native_name(ChromaClass::C422, 17), "yuv422p16le");
        assert_eq!(name_of("yuv444p32le"), "yuv444p16le");
    }

    /// Task #23: fmtconv has no 14-bit output, so QTGMC, santiag and
    /// Deblock_QED all failed on a 14-bit clip. Every 14-bit source decodes
    /// as 16-bit, keeping its chroma class.
    #[test]
    fn test_14_bit_sources_decode_as_16() {
        for (probed, expected) in [
            ("yuv420p14le", "yuv420p16le"),
            ("yuv422p14le", "yuv422p16le"),
            ("yuv444p14le", "yuv444p16le"),
            ("yuv420p14be", "yuv420p16le"),
            ("yuva444p14le", "yuv444p16le"),
            ("gray14le", "yuv420p16le"),
            ("gbrp14le", "yuv444p16le"),
            ("gbrap14le", "yuv444p16le"),
        ] {
            let result = decode_pixel_format(Some(probed));
            assert_eq!(result.name, expected, "{}", probed);
            assert_eq!(result.converted_from.as_deref(), Some(probed), "{}", probed);
        }
    }

    /// Task #31: CTMF has no 9-bit format, and havsfunc reaches it through
    /// MinBlur(r>=2) (YAHR and more). Every 9-bit source decodes as 10-bit,
    /// keeping its chroma class.
    #[test]
    fn test_9_bit_sources_decode_as_10() {
        for (probed, expected) in [
            ("yuv420p9le", "yuv420p10le"),
            ("yuv422p9le", "yuv422p10le"),
            ("yuv444p9le", "yuv444p10le"),
            ("yuv420p9be", "yuv420p10le"),
            ("yuva444p9le", "yuv444p10le"),
            ("gray9le", "yuv420p10le"),
            ("gbrp9le", "yuv444p10le"),
        ] {
            let result = decode_pixel_format(Some(probed));
            assert_eq!(result.name, expected, "{}", probed);
            assert_eq!(result.converted_from.as_deref(), Some(probed), "{}", probed);
        }
    }

    /// Nothing at 9 or 14 bits may come back into the pipe list: 9 is the
    /// depth CTMF refuses (task #31), 14 the one havsfunc's fmtconv calls
    /// refuse (task #23).
    #[test]
    fn test_no_native_format_is_9_or_14_bit() {
        for fmt in NATIVE_FORMATS {
            let depth = classify(fmt).1;
            assert_ne!(depth, 9, "{} is 9-bit", fmt);
            assert_ne!(depth, 14, "{} is 14-bit", fmt);
        }
        for class in [ChromaClass::C420, ChromaClass::C422, ChromaClass::C444] {
            for depth in 1..=16 {
                let d = classify(&native_name(class, depth)).1;
                assert!(d != 9 && d != 14, "{:?} at {} pipes {}-bit", class, depth, d);
            }
        }
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

    /// The grid of every format pipe_source reads, and of the encoder-side
    /// names that matter (task #97).
    #[test]
    fn chroma_grid_of_every_native_format() {
        let expected = [
            ("yuv411p", (4, 1)),
            ("yuv420p", (2, 2)), ("yuvj420p", (2, 2)), ("yuv420p10le", (2, 2)),
            ("yuv420p12le", (2, 2)), ("yuv420p16le", (2, 2)),
            ("yuv422p", (2, 1)), ("yuvj422p", (2, 1)), ("yuv422p10le", (2, 1)),
            ("yuv422p12le", (2, 1)), ("yuv422p16le", (2, 1)),
            ("yuv444p", (1, 1)), ("yuvj444p", (1, 1)), ("yuv444p10le", (1, 1)),
            ("yuv444p12le", (1, 1)), ("yuv444p16le", (1, 1)),
        ];
        assert_eq!(expected.len(), NATIVE_FORMATS.len());
        for (name, grid) in expected {
            assert!(NATIVE_FORMATS.contains(&name), "{name}");
            assert_eq!(chroma_grid(name), grid, "{name}");
        }
        for (name, grid) in [
            ("nv12", (2, 2)), ("p010le", (2, 2)), ("nv16", (2, 1)), ("yuv440p", (1, 2)),
            ("yuv410p", (4, 2)), ("gray", (1, 1)), ("gbrp10le", (1, 1)), ("rgb24", (1, 1)),
            ("YUV420P10LE", (2, 2)),
        ] {
            assert_eq!(chroma_grid(name), grid, "{name}");
        }
    }

    #[test]
    fn grid_pad_is_zero_on_the_grid_and_reaches_it_otherwise() {
        assert_eq!(grid_pad("yuv420p", 720, 480), (0, 0));
        assert_eq!(grid_pad("yuv420p", 720, 486), (0, 0));
        assert_eq!(grid_pad("yuv420p", 64, 33), (0, 1));
        assert_eq!(grid_pad("yuv420p", 63, 32), (1, 0));
        assert_eq!(grid_pad("yuv420p10le", 1279, 719), (1, 1));
        assert_eq!(grid_pad("yuv422p", 63, 33), (1, 0));
        assert_eq!(grid_pad("yuv444p", 63, 33), (0, 0));
        assert_eq!(grid_pad("yuv411p", 62, 32), (2, 0));
        assert_eq!(grid_pad("yuv411p", 63, 33), (1, 0));
        assert_eq!(ceil_to(33, 2), 34);
        assert_eq!(ceil_to(32, 2), 32);
        assert_eq!(ceil_to(7, 1), 7);
        assert_eq!(lcm(4, 2), 4);
        assert_eq!(lcm(2, 1), 2);
        assert_eq!(lcm(1, 1), 1);
    }
}
