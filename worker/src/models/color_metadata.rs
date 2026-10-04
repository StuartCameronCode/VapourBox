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
//! Note this is a *metadata* fix, not a pixel one. Nothing here converts
//! anything: the samples coming off the pipe already carry whatever matrix the
//! source used, and none of the passes re-matrix them. The bug was only ever
//! that we failed to say so on the way out.
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

    /// Output-stream flags for the encoder. Each tag is independent: a source
    /// that declares only a matrix gets only `-colorspace`, rather than having
    /// the other three guessed for it.
    pub fn to_ffmpeg_args(&self) -> Vec<String> {
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

    /// Whether the source declares full range. Anything else is limited, which
    /// is what an untagged SD capture almost always is.
    pub fn is_full_range(&self) -> bool {
        matches!(self.range.as_deref(), Some("pc") | Some("jpeg") | Some("full"))
    }

    /// The zimg `matrix_s` for converting an RGB colour into the source's YUV —
    /// used for border fills (issue #86), the only place the script turns RGB
    /// into YUV. Nothing re-matrixes the picture, so the samples still carry the
    /// source's matrix; untagged, it is the usual guess by frame height.
    ///
    /// Neutral fills (black/grey/white) come out identical under every matrix,
    /// so this only matters for a custom colour.
    pub fn zimg_matrix(&self, source_height: Option<i32>) -> &'static str {
        match self.matrix.as_deref() {
            Some("bt709") => "709",
            Some("fcc") => "fcc",
            Some("bt470bg") => "470bg",
            Some("smpte170m") => "170m",
            Some("smpte240m") => "240m",
            Some("ycgco") => "ycgco",
            Some("bt2020nc") => "2020ncl",
            Some("bt2020c") => "2020cl",
            Some("chroma-derived-nc") => "chromancl",
            Some("chroma-derived-c") => "chromacl",
            Some("ictcp") => "ictcp",
            _ if source_height.is_some_and(|h| h >= 720) => "709",
            _ => "170m",
        }
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
        let full = self.is_full_range();
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
            c.to_ffmpeg_args(),
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
            assert!(c.to_ffmpeg_args().is_empty());
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
        assert_eq!(c.to_ffmpeg_args(), vec!["-colorspace", "smpte170m"]);
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
    fn zimg_matrix_follows_the_tag_then_the_frame_height() {
        let tagged = ColorMetadata::from_raw(Some("bt470bg"), None, None, None);
        assert_eq!(tagged.zimg_matrix(Some(1080)), "470bg");
        let untagged = ColorMetadata::default();
        assert_eq!(untagged.zimg_matrix(Some(1080)), "709");
        assert_eq!(untagged.zimg_matrix(Some(576)), "170m");
        assert_eq!(untagged.zimg_matrix(None), "170m");
        // The identity matrix is RGB; guess as if untagged rather than feed
        // zimg an RGB->RGB matrix for a YUV clip.
        let rgb = ColorMetadata::from_raw(Some("rgb"), None, None, None);
        assert_eq!(rgb.zimg_matrix(Some(480)), "170m");
    }

    #[test]
    fn every_recognised_matrix_maps_to_a_zimg_name() {
        // Only the RGB identity, and SMPTE 2085 (which zimg does not implement),
        // may fall through to the height guess.
        for m in MATRICES.iter().filter(|m| !matches!(**m, "rgb" | "smpte2085")) {
            let c = ColorMetadata::from_raw(Some(m), None, None, None);
            assert_ne!(
                (c.zimg_matrix(Some(1080)), c.zimg_matrix(Some(480))),
                ("709", "170m"),
                "{m} is not mapped"
            );
        }
    }

    #[test]
    fn preview_drops_the_rgb_identity_matrix() {
        // swscale has no in_color_matrix entry for it.
        let c = ColorMetadata::from_raw(Some("rgb"), None, None, None);
        assert_eq!(c.swscale_input_opts(), vec!["in_range=tv"]);
    }
}
