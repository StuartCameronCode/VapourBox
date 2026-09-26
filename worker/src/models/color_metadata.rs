//! Colour metadata carried from the source to the encoder.
//!
//! The Y4M pipe from vspipe strips colour tags exactly as it strips the sample
//! aspect ratio — a clip carrying `_Matrix`/`_Primaries`/`_Transfer` frame
//! properties produces a Y4M header with none of them. So, like SAR, whatever
//! the pipeline did, something has to re-stamp them on the output. Without that
//! every file this app writes is untagged, and an untagged file is read as
//! BT.601 limited by every player — which silently shifts the colours of any
//! BT.709 or full-range source.
//!
//! The tags have to be declared on **both** sides of the encoder ffmpeg: on the
//! Y4M *input* (options before `-i -`) as well as on the output stream. This is
//! not a formality. FFmpeg negotiates the colour matrix and range through the
//! filter graph the way it negotiates the pixel format, so an untagged input
//! (`csp:unknown`) feeding an output tagged `bt709` makes ffmpeg auto-insert a
//! scaler — and swscale treats "unknown" as BT.601, so it *re-matrixes every
//! pixel* from 601 to 709 on the way through. Tagging only the output shifted
//! the colours of every encode from a tagged source (measured on FFmpeg 9.0.1:
//! a flat 10-bit 4:2:2 frame at Y/U/V 565/236/756 came back 546/259/741).
//! Declare the input as the same thing and there is nothing for the scaler to
//! convert, so the samples reach the encoder untouched. Output-only
//! `-color_primaries`/`-color_trc` also never reached the file at all (the
//! encoder takes those from the frames, which were untagged); declared on the
//! input they ride on the frames and are written.
//!
//! So this is a *metadata* fix, and the input-side declaration is what keeps it
//! one. Nothing here should convert anything: the samples coming off the pipe
//! already carry whatever matrix the source used, and none of the passes
//! re-matrix them. See docs/ENGINEERING_NOTES.md (2026-09-26).
//!
//! Values are validated against what FFmpeg actually accepts rather than passed
//! through, on the same principle as `parse_ratio`: a value we do not recognise
//! is dropped, so a surprising ffprobe string falls back to "untagged" instead
//! of reaching the encoder as a broken argument and failing the whole job.

use serde::{Deserialize, Serialize};

/// `-colorspace` values. ffprobe's `color_space` uses these same names.
const MATRICES: &[&str] = &[
    "rgb", "bt709", "fcc", "bt470bg", "smpte170m", "smpte240m", "ycgco",
    "bt2020nc", "bt2020c", "smpte2085", "chroma-derived-nc", "chroma-derived-c",
    "ictcp",
];

/// `-color_primaries` values, matching ffprobe's `color_primaries`.
const PRIMARIES: &[&str] = &[
    "bt709", "bt470m", "bt470bg", "smpte170m", "smpte240m", "film", "bt2020",
    "smpte428", "smpte431", "smpte432", "jedec-p22", "ebu3213",
];

/// `-color_trc` values, matching ffprobe's `color_transfer`.
const TRANSFERS: &[&str] = &[
    "bt709", "gamma22", "gamma28", "smpte170m", "smpte240m", "linear", "log100",
    "log316", "iec61966-2-4", "bt1361e", "iec61966-2-1", "bt2020-10",
    "bt2020-12", "smpte2084", "smpte428", "arib-std-b67",
];

/// `-color_range` values. ffprobe reports `tv`/`pc`; it also emits the longer
/// `mpeg`/`jpeg` spellings in some versions, which FFmpeg accepts as synonyms.
const RANGES: &[&str] = &["tv", "pc", "mpeg", "jpeg", "limited", "full"];

/// Normalise one ffprobe value: trim, lowercase, and drop anything not on the
/// allowed list. `unknown`, `N/A`, `reserved` and the empty string all fall out
/// here, which is what ffprobe reports for an untagged stream.
fn clean(value: Option<&str>, allowed: &[&str]) -> Option<String> {
    let v = value?.trim().to_ascii_lowercase();
    if v.is_empty() {
        return None;
    }
    allowed.contains(&v.as_str()).then_some(v)
}

/// The four colour tags, as read from the source and re-declared on the output.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ColorMetadata {
    pub matrix: Option<String>,
    pub primaries: Option<String>,
    pub transfer: Option<String>,
    pub range: Option<String>,
}

impl ColorMetadata {
    /// Build from raw ffprobe strings, dropping anything unrecognised.
    pub fn from_raw(
        matrix: Option<&str>,
        primaries: Option<&str>,
        transfer: Option<&str>,
        range: Option<&str>,
    ) -> Self {
        Self {
            matrix: clean(matrix, MATRICES),
            primaries: clean(primaries, PRIMARIES),
            transfer: clean(transfer, TRANSFERS),
            range: clean(range, RANGES),
        }
    }

    /// True when the source told us nothing worth re-declaring.
    pub fn is_empty(&self) -> bool {
        self.matrix.is_none()
            && self.primaries.is_none()
            && self.transfer.is_none()
            && self.range.is_none()
    }

    /// Input options for the Y4M pipe, placed between `-f yuv4mpegpipe` and
    /// `-i -`. They state what the samples already *are*, which the Y4M header
    /// cannot say. Without them ffmpeg sees an untagged input and, because the
    /// output is tagged, converts the pixels to match (see the module docs).
    pub fn to_ffmpeg_input_args(&self) -> Vec<String> {
        self.tag_args()
    }

    /// Output-stream flags for the encoder. Must always equal the input
    /// declaration: any difference between the two is carried out by ffmpeg as
    /// a conversion of the pixels, not a relabelling. Kept alongside the input
    /// side (rather than relying on the frames' tags alone) because without an
    /// explicit output range ffmpeg can negotiate a different one — a
    /// full-range source declared only on the input came out converted to
    /// limited.
    pub fn to_ffmpeg_output_args(&self) -> Vec<String> {
        self.tag_args()
    }

    /// The four tag flags, spelled the same way whether they are given as input
    /// (decoder) or output (encoder) options. Each tag is independent: a source
    /// that declares only a matrix gets only `-colorspace`, rather than having
    /// the other three guessed for it.
    fn tag_args(&self) -> Vec<String> {
        let mut args = Vec::new();
        for (flag, value) in [
            ("-colorspace", &self.matrix),
            ("-color_primaries", &self.primaries),
            ("-color_trc", &self.transfer),
            ("-color_range", &self.range),
        ] {
            if let Some(v) = value {
                args.push(flag.to_string());
                args.push(v.clone());
            }
        }
        args
    }

    /// swscale input options for the preview's YUV→RGB conversion.
    ///
    /// The preview's second stage reads a Y4M pipe, which carries no colour
    /// information, so swscale would otherwise guess the matrix — while the
    /// app's "before" thumbnail comes from a separate ffmpeg call on the
    /// original file that *does* see the real tags. That mismatch showed a hue
    /// shift no filter had caused. `in_range` was previously hardcoded `tv`,
    /// which also stretched a full-range source a second time.
    ///
    /// swscale spells the matrix differently from `-colorspace` in one case:
    /// it wants `bt470bg` for 601 PAL, which matches, but it has no entry for
    /// the RGB identity matrix, so that is dropped.
    pub fn swscale_input_opts(&self) -> Vec<String> {
        let mut opts = Vec::new();
        if let Some(m) = self.matrix.as_deref() {
            if m != "rgb" {
                opts.push(format!("in_color_matrix={m}"));
            }
        }
        // Anything but an explicit full-range tag is treated as limited, which
        // is what an untagged SD capture almost always is.
        let full = matches!(self.range.as_deref(), Some("pc") | Some("jpeg") | Some("full"));
        opts.push(format!("in_range={}", if full { "pc" } else { "tv" }));
        opts
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognised_values_survive() {
        let c = ColorMetadata::from_raw(Some("bt709"), Some("bt709"), Some("bt709"), Some("tv"));
        assert_eq!(
            c.to_ffmpeg_output_args(),
            vec![
                "-colorspace", "bt709",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-color_range", "tv",
            ]
        );
    }

    #[test]
    fn untagged_streams_produce_nothing() {
        // What ffprobe actually reports for a stream with no colour tags.
        for junk in ["unknown", "N/A", "", "  ", "reserved"] {
            let c = ColorMetadata::from_raw(Some(junk), Some(junk), Some(junk), Some(junk));
            assert!(c.is_empty(), "{junk:?} should not be stamped");
            assert!(c.to_ffmpeg_output_args().is_empty());
        }
        assert!(ColorMetadata::from_raw(None, None, None, None).is_empty());
    }

    #[test]
    fn unrecognised_values_are_dropped_not_forwarded() {
        // A value we do not know must never reach ffmpeg, or it fails the whole
        // encode on an argument the user cannot see or fix.
        let c = ColorMetadata::from_raw(Some("bt709; rm -rf"), Some("nonsense"), None, Some("wat"));
        assert!(c.is_empty());
    }

    #[test]
    fn each_tag_is_independent() {
        // A source that declares only a matrix gets only -colorspace; the other
        // three are not guessed on its behalf.
        let c = ColorMetadata::from_raw(Some("smpte170m"), None, None, None);
        assert_eq!(c.to_ffmpeg_output_args(), vec!["-colorspace", "smpte170m"]);
    }

    #[test]
    fn values_are_normalised() {
        let c = ColorMetadata::from_raw(Some("BT709"), None, None, Some(" PC "));
        assert_eq!(c.matrix.as_deref(), Some("bt709"));
        assert_eq!(c.range.as_deref(), Some("pc"));
    }

    #[test]
    fn preview_defaults_to_limited_range() {
        // The old hardcoded behaviour, preserved for untagged sources.
        let c = ColorMetadata::default();
        assert_eq!(c.swscale_input_opts(), vec!["in_range=tv"]);
    }

    #[test]
    fn preview_honours_a_full_range_source() {
        let c = ColorMetadata::from_raw(Some("bt709"), None, None, Some("pc"));
        assert_eq!(
            c.swscale_input_opts(),
            vec!["in_color_matrix=bt709", "in_range=pc"]
        );
    }

    #[test]
    fn preview_drops_the_rgb_identity_matrix() {
        // swscale has no in_color_matrix entry for it.
        let c = ColorMetadata::from_raw(Some("rgb"), None, None, None);
        assert_eq!(c.swscale_input_opts(), vec!["in_range=tv"]);
    }

    /// Any difference between what the Y4M input is declared as and what the
    /// output is tagged as, ffmpeg carries out as a pixel conversion. The two
    /// lists must be identical, tag for tag, whatever subset the source has.
    #[test]
    fn input_and_output_declarations_always_agree() {
        let cases = [
            ColorMetadata::default(),
            ColorMetadata::from_raw(Some("bt709"), Some("bt709"), Some("bt709"), Some("tv")),
            ColorMetadata::from_raw(Some("bt709"), None, None, Some("pc")),
            ColorMetadata::from_raw(Some("smpte170m"), None, None, None),
            ColorMetadata::from_raw(None, Some("bt2020"), Some("smpte2084"), None),
            ColorMetadata::from_raw(Some("rgb"), None, None, Some("jpeg")),
        ];
        for c in cases {
            assert_eq!(c.to_ffmpeg_input_args(), c.to_ffmpeg_output_args(), "{c:?}");
        }
    }

    #[test]
    fn input_declaration_carries_every_tag() {
        let c = ColorMetadata::from_raw(Some("bt709"), Some("bt709"), Some("bt709"), Some("tv"));
        assert_eq!(
            c.to_ffmpeg_input_args(),
            vec![
                "-colorspace", "bt709",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-color_range", "tv",
            ]
        );
        assert!(ColorMetadata::default().to_ffmpeg_input_args().is_empty());
    }
}
