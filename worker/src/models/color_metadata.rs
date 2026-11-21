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
//! one. Nothing in ffmpeg should convert anything: the samples coming off the
//! pipe carry the source's matrix, except in one case the script itself
//! converts — a BT.601 source taken to BT.709 by Crop & Resize (app 1.7.0),
//! when the tags declared are `bt709_converted`'s and `VideoJob::
//! output_color_metadata` is the one place that decides which. See
//! docs/ENGINEERING_NOTES.md (2026-09-26).
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

/// The `MATRICES` FFmpeg 9's scaler can convert a frame from: its format
/// negotiation lists `unknown gbr bt709 fcc bt470bg smpte170m smpte240m
/// bt2020nc` (FFmpeg 9.0.2, task #76; `gbr` is `-colorspace`'s `rgb`). A frame
/// tagged with any other matrix fails every decode that converts its pixel
/// format ("Impossible to convert between the formats…"), so
/// [`ColorMetadata::scaler_stand_in`] names what such a frame is converted as.
/// `colour_tag_ffmpeg_test.dart` checks the list against each platform's
/// bundled ffmpeg (docs/reports/task-76-unconvertible-matrix-tags).
const SCALER_MATRICES: &[&str] = &[
    "rgb", "bt709", "fcc", "bt470bg", "smpte170m", "smpte240m", "bt2020nc",
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

/// Whether a raw ffprobe tag is present but not a value FFmpeg accepts.
/// Untagged (`unknown`, `N/A`, empty, absent) is not invalid: there is
/// nothing to neutralise.
fn is_invalid(value: Option<&str>, allowed: &[&str], also_valid: &[&str]) -> bool {
    let Some(v) = value.map(|v| v.trim().to_ascii_lowercase()) else {
        return false;
    };
    if v.is_empty() || v == "unknown" || v == "n/a" {
        return false;
    }
    !allowed.contains(&v.as_str()) && !also_valid.contains(&v.as_str())
}

/// The `setparams` that goes first in every decode of the source that may
/// convert its pixel format, or `None` when FFmpeg's scaler can convert a frame
/// with the source's tags as they are.
///
/// FFmpeg 9's scaler fails the whole decode on two kinds of tag:
///
/// - **An invalid one** — `[swscaler] Unsupported input … prim:reserved
///   trc:reserved`. ProRes is where this happens: Apple's ProRes spec writes
///   code 0 for "unknown", which FFmpeg reads as ISO 23091's `reserved` (so
///   FFmpeg's own `prores_metadata=color_primaries=unknown` produces such a
///   file). Each is cleared to `unknown`, on its own: clearing only the
///   primaries when the transfer is also reserved still fails
///   (docs/reports/2026-11-reserved-colour-tags). `ipt-c2` (Dolby Vision
///   profile 5) is cleared too: a DV5 picture is warned about, never blocked.
/// - **A valid matrix the scaler has no conversion for** (task #76): `ycgco`,
///   `bt2020c`, `smpte2085`, `chroma-derived-nc`/`-c`, `ictcp` (anything off
///   `SCALER_MATRICES`). It is replaced by [`ColorMetadata::scaler_stand_in`],
///   the matrix the preview reads it as (`swscale_matrix`, task #73), so a
///   converted picture matches the preview. Every conversion the app and the
///   worker make (YUV to JPEG, another subsampling, depth or packing) gives
///   the same bytes whichever matrix stands in; only YUV to RGB or gray reads
///   it (docs/reports/task-76-unconvertible-matrix-tags).
///
/// **A matrix the scaler converts is never touched.** Clearing a valid one
/// changes pixels: `yuv → gray16le` on a bt709-tagged picture differs by up to
/// ~28 8-bit levels from the same picture with `colorspace=unknown`.
///
/// Every decode puts this first in its one `-vf`: the app's "before" frame and
/// thumbnails (`ColorTags.decodeNeutraliser`, byte-identical; the case table
/// is `Tests/TestResources/decode_neutraliser_cases.json`), the detectors, and
/// the encode/preview decoders (a ProRes 4444 with alpha, `yuva444p12le`, or a
/// 9-bit source is converted to the pipe format there).
///
/// `gbr` is ffprobe's name for the RGB identity matrix (`-colorspace` spells it
/// `rgb`, hence `MATRICES`); swscale handles it, so it is left alone. The
/// primaries are the RAW ones: a `chroma-derived` matrix stands in by them.
pub fn decode_tag_neutraliser(
    matrix: Option<&str>,
    primaries: Option<&str>,
    transfer: Option<&str>,
) -> Option<String> {
    let mut params = Vec::new();
    if is_invalid(primaries, PRIMARIES, &[]) {
        params.push("color_primaries=unknown".to_string());
    }
    if is_invalid(transfer, TRANSFERS, &[]) {
        params.push("color_trc=unknown".to_string());
    }
    if is_invalid(matrix, MATRICES, &["gbr"]) {
        params.push("colorspace=unknown".to_string());
    } else if let Some(s) = ColorMetadata::from_raw(matrix, primaries, None, None).scaler_stand_in() {
        params.push(format!("colorspace={s}"));
    }
    (!params.is_empty()).then(|| format!("setparams={}", params.join(":")))
}

/// zimg's name for an FFmpeg `-color_primaries` value, or `None` where the
/// bundled VapourSynth resize has none (`smpte428`: "unrecognized primaries";
/// `jedec-p22` / `ebu3213`: reachable only by number).
fn zimg_primaries(ffmpeg: &str) -> Option<&'static str> {
    Some(match ffmpeg {
        "bt709" => "709",
        "bt470m" => "470m",
        "bt470bg" => "470bg",
        "smpte170m" => "170m",
        "smpte240m" => "240m",
        "film" => "film",
        "bt2020" => "2020",
        "smpte431" => "st431-2",
        "smpte432" => "st432-1",
        _ => return None,
    })
}

/// The colour space a script conversion between YUV and RGB names to zimg
/// (`ColorMetadata::zimg_colorspace`, task #88). It renders its own Python,
/// so no template spells the arguments: a matrix-only colour space renders
/// exactly the text the templates had before (`matrix_s="709"`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ZimgColorspace {
    pub matrix: &'static str,
    pub transfer: Option<&'static str>,
    pub primaries: Option<&'static str>,
}

impl ZimgColorspace {
    fn matrix_only(matrix: &'static str) -> Self {
        Self { matrix, transfer: None, primaries: None }
    }

    fn ictcp(transfer: &'static str) -> Self {
        Self { matrix: "ictcp", transfer: Some(transfer), primaries: Some("2020") }
    }

    /// Transfer and primaries, on **both** sides of the call: R78's resize
    /// copies an unset output colour space from the input, not the other way
    /// round, so an RGB swatch (untagged) converted with only `transfer_s` /
    /// `primaries_s` still fails.
    fn extra_args(&self) -> String {
        let mut s = String::new();
        if let Some(t) = self.transfer {
            s.push_str(&format!(", transfer_in_s=\"{t}\", transfer_s=\"{t}\""));
        }
        if let Some(p) = self.primaries {
            s.push_str(&format!(", primaries_in_s=\"{p}\", primaries_s=\"{p}\""));
        }
        s
    }

    /// Keyword arguments for an RGB -> YUV `core.resize` call.
    pub fn to_yuv_args(&self) -> String {
        format!("matrix_s=\"{}\"{}", self.matrix, self.extra_args())
    }

    /// Keyword arguments for a YUV -> RGB `core.resize` call.
    pub fn from_yuv_args(&self) -> String {
        format!("matrix_in_s=\"{}\"{}", self.matrix, self.extra_args())
    }

    /// A Python literal for the template modules (`ai_runtime.zimg_args`):
    /// the matrix as a string when that is all there is, else a dict.
    pub fn py_literal(&self) -> String {
        if self.transfer.is_none() && self.primaries.is_none() {
            return format!("\"{}\"", self.matrix);
        }
        let mut parts = vec![format!("\"matrix\": \"{}\"", self.matrix)];
        if let Some(t) = self.transfer {
            parts.push(format!("\"transfer\": \"{t}\""));
        }
        if let Some(p) = self.primaries {
            parts.push(format!("\"primaries\": \"{p}\""));
        }
        format!("{{{}}}", parts.join(", "))
    }
}

/// Every tag value `from_raw` keeps, for tests that sweep them (task #88's
/// `zimg_colorspace_test`, which runs each through the bundled VapourSynth).
#[doc(hidden)]
pub fn recognised_tags() -> (&'static [&'static str], &'static [&'static str], &'static [&'static str]) {
    (MATRICES, PRIMARIES, TRANSFERS)
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

    /// Whether the source declares full range. Anything else is limited, which
    /// is what an untagged SD capture almost always is.
    pub fn is_full_range(&self) -> bool {
        matches!(self.range.as_deref(), Some("pc") | Some("jpeg") | Some("full"))
    }

    /// The zimg matrix name of `zimg_colorspace` — the matrix only. Used where
    /// the matrix alone is wanted (`is_bt601_family`, the BT.601 → BT.709
    /// block, which only a BT.601 picture reaches). **Any conversion between
    /// YUV and RGB takes its arguments from `zimg_colorspace`**, never a bare
    /// `matrix_s` built from this: four matrices need a transfer and
    /// primaries too (task #88).
    pub fn zimg_matrix(&self, source_height: Option<i32>) -> &'static str {
        self.zimg_colorspace(source_height).matrix
    }

    /// The colour space the script's own conversions between YUV and RGB use
    /// for this picture: border fills (issue #86), RIFE, AI upscaling, Face
    /// Restoration and Colourisation. Nothing re-matrixes the picture, so the
    /// samples still carry the source's matrix; untagged, it is the usual
    /// guess by frame height.
    ///
    /// zimg converts most matrices from the matrix alone, but refuses four
    /// without more ("Resize error 3074: invalid colorspace definition";
    /// task #88, docs/reports/task-88-zimg-colour-tags):
    ///
    /// - `chroma-derived-nc` is exact: `chromancl` with the source's
    ///   primaries, which is lossless and keeps every neutral. With BT.709 or
    ///   BT.2020 primaries it *is* `709` / `2020ncl` (measured identical), so
    ///   those are named directly. Primaries that are untagged, or that zimg
    ///   has no name for (`smpte428`, `jedec-p22`, `ebu3213`), leave nothing
    ///   to derive coefficients from: the height guess, as untagged.
    /// - `bt2020c` and `chroma-derived-c` are read as their NCL twin (the same
    ///   coefficients). zimg's constant-luminance conversion linearises with
    ///   the display EOTF but encodes Y' with the OETF, so it does not keep
    ///   grey (grey 128 came out Y' 434, not 504), and it refuses PQ and HLG
    ///   outright. NCL keeps every neutral exact for any decoder, and it is
    ///   how the preview (`swscale_matrix`) and the decodes
    ///   (`scaler_stand_in`) read these tags.
    /// - `ictcp` is exact with a PQ or HLG transfer: zimg converts it only
    ///   then, and only with BT.2020 primaries, which are the only ones ICtCp
    ///   is defined with, so they are passed whatever the tag says. On any
    ///   other transfer it cannot be converted, and is read as `2020ncl`, as
    ///   the preview reads it.
    pub fn zimg_colorspace(&self, source_height: Option<i32>) -> ZimgColorspace {
        let only = ZimgColorspace::matrix_only;
        let guess = || only(if source_height.is_some_and(|h| h >= 720) { "709" } else { "170m" });
        match self.matrix.as_deref() {
            Some("bt709") => only("709"),
            Some("fcc") => only("fcc"),
            Some("bt470bg") => only("470bg"),
            Some("smpte170m") => only("170m"),
            Some("smpte240m") => only("240m"),
            Some("ycgco") => only("ycgco"),
            Some("bt2020nc") => only("2020ncl"),
            Some("bt2020c") => only("2020ncl"),
            Some("chroma-derived-nc") | Some("chroma-derived-c") => {
                match self.primaries.as_deref() {
                    Some("bt709") => only("709"),
                    Some("bt2020") => only("2020ncl"),
                    p => match p.and_then(zimg_primaries) {
                        Some(z) => ZimgColorspace { matrix: "chromancl", transfer: None, primaries: Some(z) },
                        None => guess(),
                    },
                }
            }
            Some("ictcp") => match self.transfer.as_deref() {
                Some("smpte2084") => ZimgColorspace::ictcp("st2084"),
                Some("arib-std-b67") => ZimgColorspace::ictcp("std-b67"),
                _ => only("2020ncl"),
            },
            // rgb, smpte2085 (zimg has no Y'D'zD'x) and untagged.
            _ => guess(),
        }
    }

    /// Whether the picture's colour is BT.601: tagged `bt470bg` (PAL) or
    /// `smpte170m` (NTSC), or untagged below HD height, which is how the rest
    /// of the app (`zimg_matrix`) and every player read an untagged SD file.
    /// Never an HDR picture.
    pub fn is_bt601_family(&self, source_height: Option<i32>) -> bool {
        if self.is_hdr() {
            return false;
        }
        match self.matrix.as_deref() {
            Some("bt470bg") | Some("smpte170m") => true,
            Some(_) => false,
            None => self.zimg_matrix(source_height) == "170m",
        }
    }

    /// The primaries a BT.601 picture was made for: its tag, else PAL's
    /// (EBU, `bt470bg`) for a 576- or 288-line picture or a `bt470bg` matrix,
    /// else NTSC's (SMPTE C, `smpte170m`).
    fn bt601_primaries(&self, source_height: Option<i32>) -> String {
        if let Some(p) = &self.primaries {
            return p.clone();
        }
        let pal = self.matrix.as_deref() == Some("bt470bg")
            || matches!(source_height, Some(576) | Some(288));
        if pal { "bt470bg" } else { "smpte170m" }.to_string()
    }

    /// The tags of a BT.601 picture after its samples are converted to the
    /// BT.709 matrix (the script's `COLOR_709` block, app 1.7.0).
    ///
    /// The matrix and transfer say 709. BT.601's transfer is the same curve as
    /// BT.709's, and PAL's nominal gamma-2.8 tag has never described a real
    /// camera, so relabelling it changes nothing about the samples.
    ///
    /// The **primaries keep the source's** (tagged, or PAL/NTSC by height),
    /// because only the matrix is converted: the samples still describe the
    /// source's primaries. Converting the gamut as well was measured and
    /// rejected (docs/reports/2026-11-crop-detect-709/): SMPTE C to BT.709
    /// moves a 75% green from RGB (0,191,0) to (55,188,0) and a 75% magenta's
    /// green from 0 to 47, which every player that does not colour-manage
    /// (most of them) would show as a hue shift of its own, while a player
    /// that does colour-manage reads the source's primaries from the tag. The
    /// range is the source's (limited when untagged), declared explicitly.
    pub fn bt709_converted(&self, source_height: Option<i32>) -> ColorMetadata {
        let transfer = match self.transfer.as_deref() {
            None | Some("bt709") | Some("smpte170m") | Some("gamma22") | Some("gamma28") => {
                "bt709".to_string()
            }
            Some(other) => other.to_string(),
        };
        ColorMetadata {
            matrix: Some("bt709".to_string()),
            primaries: Some(self.bt601_primaries(source_height)),
            transfer: Some(transfer),
            range: Some(self.range.clone().unwrap_or_else(|| "tv".to_string())),
        }
    }

    /// Whether the transfer is HDR: PQ (HDR10, and the base layer of most
    /// Dolby Vision) or HLG.
    pub fn is_hdr(&self) -> bool {
        matches!(self.transfer.as_deref(), Some("smpte2084") | Some("arib-std-b67"))
    }

    /// The ffmpeg filter chain that shows an HDR picture on an SDR screen, or
    /// `None` for an SDR source (issue #133). Display only: the encode keeps
    /// the HDR picture and its tags.
    ///
    /// Without it a PQ frame is shown as if it were BT.709 — grey, dim and
    /// desaturated, since PQ code values sit far lower than SDR ones and the
    /// BT.2020 primaries are read as 709's. This linearises, maps the
    /// primaries to 709 and tone-maps highlights (Hable) before re-encoding as
    /// 709. The app's "before" frames and timeline thumbnails use the same
    /// chain (`HdrDisplay.toneMapFilter` in Dart, kept identical by a test on
    /// each side) so before and after compare like for like.
    ///
    /// The source's tags are declared with `setparams` first, because the
    /// preview reads a Y4M pipe that carries none, and zscale cannot find a
    /// conversion path from "unspecified". The chain ends in `rgb24` tagged
    /// `gbr`: zscale leaves the source's YUV matrix on its RGB output, and a
    /// JPEG encode would then convert to YUV with BT.2020's matrix while every
    /// decoder reads JPEG as BT.601 — a hue shift measured at up to 21 levels.
    pub fn display_tonemap_filter(&self) -> Option<String> {
        if !self.is_hdr() {
            return None;
        }
        // Values zscale can linearise from. Anything else is far more likely a
        // mislabelled BT.2020 file than a real alternative. `bt2020c` is read
        // as NCL (the same Kr/Kb): zimg refuses constant luminance with a PQ or
        // HLG transfer ("invalid colorspace definition"), so it had no
        // picture at all (task #76).
        let matrix = match self.matrix.as_deref() {
            Some(m @ ("bt709" | "bt2020nc")) => m,
            _ => "bt2020nc",
        };
        let primaries = match self.primaries.as_deref() {
            Some(p @ ("bt709" | "bt2020" | "smpte432")) => p,
            _ => "bt2020",
        };
        let transfer = self.transfer.as_deref().unwrap_or("smpte2084");
        let range = if self.is_full_range() { "pc" } else { "tv" };
        Some(format!(
            "setparams=colorspace={matrix}:color_primaries={primaries}:color_trc={transfer}:range={range},\
             zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,\
             tonemap=tonemap=hable:desat=0,zscale=t=bt709:r=full,\
             format=rgb24,setparams=colorspace=gbr"
        ))
    }

    /// The matrix the preview's `scale=in_color_matrix=` names for this
    /// picture, or `None` to leave it out (swscale then reads BT.601).
    ///
    /// FFmpeg 9's `scale` knows only auto, bt601/bt470/smpte170m/bt470bg,
    /// bt709, fcc, smpte240m and bt2020/bt2020nc, and has no conversion at all
    /// for the other H.273 matrices (even by number: "Unsupported input color
    /// matrix"), so a tag it can't name failed the whole preview (task #73,
    /// docs/reports/task-73-swscale-matrix-tags). Each is mapped to the
    /// nearest matrix scale has, or left out:
    ///
    /// - `bt2020c` -> `bt2020`: the same Kr/Kb as NCL, the nearest swscale
    ///   can do (FFmpeg's own swscale read it so before 9).
    /// - `chroma-derived-nc`/`-c` -> `bt709` or `bt2020` when the primaries
    ///   are those (H.273 derives exactly those coefficients from them), else
    ///   left out.
    /// - `ictcp` -> `bt2020`: ICtCp exists only with BT.2100's primaries, so an
    ///   SDR picture tagged with it is most likely BT.2020 YCbCr (as
    ///   `display_tonemap_filter` reads it).
    /// - `ycgco`, `smpte2085`, `rgb` -> left out: no YCbCr matrix comes close
    ///   (YCgCo's Cg/Co are not colour differences; Y'D'zD'x is for XYZ).
    ///   The preview's colours are then wrong; the encode keeps the samples
    ///   and the tag.
    ///
    /// The six that need this also fail any decode that converts a frame
    /// TAGGED with them, which [`scaler_stand_in`](Self::scaler_stand_in)
    /// handles from this same table (task #76).
    pub fn swscale_matrix(&self) -> Option<&'static str> {
        let derived = || match self.primaries.as_deref() {
            Some("bt709") => Some("bt709"),
            Some("bt2020") => Some("bt2020"),
            _ => None,
        };
        match self.matrix.as_deref()? {
            "bt709" => Some("bt709"),
            "fcc" => Some("fcc"),
            "bt470bg" => Some("bt470bg"),
            "smpte170m" => Some("smpte170m"),
            "smpte240m" => Some("smpte240m"),
            "bt2020nc" => Some("bt2020nc"),
            "bt2020c" => Some("bt2020"),
            "chroma-derived-nc" => derived(),
            "chroma-derived-c" => derived(),
            "ictcp" => Some("bt2020"),
            "ycgco" => None,
            "smpte2085" => None,
            "rgb" => None,
            _ => None,
        }
    }

    /// The matrix FFmpeg converts a frame tagged with this matrix as, when its
    /// scaler can't convert that matrix itself (it is off `SCALER_MATRICES`),
    /// spelled as a `-colorspace` / `setparams` value; `None` when the scaler
    /// converts the tag as it is, or there is none (task #76).
    ///
    /// It is the preview's reading ([`swscale_matrix`](Self::swscale_matrix),
    /// task #73), so a converted picture matches the preview: `bt2020c` and
    /// `ictcp` stand in as `bt2020nc`, `chroma-derived-*` as `bt709` or
    /// `bt2020nc` by the primaries, `ycgco` and `smpte2085` as `unknown`.
    pub fn scaler_stand_in(&self) -> Option<&'static str> {
        let m = self.matrix.as_deref()?;
        if SCALER_MATRICES.contains(&m) {
            return None;
        }
        Some(match self.swscale_matrix() {
            Some("bt2020") => "bt2020nc",
            Some(m) => m,
            None => "unknown",
        })
    }

    /// The filters that end the encoder's one `-vf` when the output's matrix
    /// is one FFmpeg's scaler can't convert, or `None` (task #76).
    ///
    /// The Y4M input and the output are both declared with the true tag, as
    /// always. When the encoder then needs another pixel format (AMF's `nv12`
    /// pin, NVENC's p010, an encoder that refuses the pipe's format, a Custom
    /// `-pix_fmt`), ffmpeg inserts a scaler, which fails on the tag. Declaring
    /// the stand-in instead fails too (the output tag is a negotiation target
    /// the scaler can't produce) or loses the tag. So the tag is swapped for
    /// its stand-in around an explicit `scale`, which negotiates its output
    /// format with the encoder exactly as the inserted scaler would, and is put
    /// back after it. Measured: samples identical to an untagged encode
    /// through the same conversion, and to the encode without the bridge when
    /// nothing converts (docs/reports/task-76-unconvertible-matrix-tags).
    pub fn encoder_matrix_bridge(&self) -> Option<String> {
        let stand_in = self.scaler_stand_in()?;
        let tag = self.matrix.as_deref()?;
        Some(format!(
            "setparams=colorspace={stand_in},scale,setparams=colorspace={tag}"
        ))
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
    /// The matrix is `swscale_matrix()`: `scale` has no entry for the RGB
    /// identity or for six valid tags (task #73).
    pub fn swscale_input_opts(&self) -> Vec<String> {
        let mut opts = Vec::new();
        if let Some(m) = self.swscale_matrix() {
            opts.push(format!("in_color_matrix={m}"));
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

    /// The shared case table (`Tests/TestResources/decode_neutraliser_cases.json`):
    /// `color_tags_test.dart` checks `ColorTags.decodeNeutraliser` against the
    /// same rows, so the two stay byte-identical.
    #[test]
    fn decode_tag_neutraliser_matches_the_shared_table() {
        let table: serde_json::Value = serde_json::from_str(include_str!(
            "../../../Tests/TestResources/decode_neutraliser_cases.json"
        ))
        .unwrap();
        let cases = table["cases"].as_array().unwrap();
        assert!(cases.len() > 25);
        for c in cases {
            assert_eq!(
                decode_tag_neutraliser(
                    c["matrix"].as_str(),
                    c["primaries"].as_str(),
                    c["transfer"].as_str()
                )
                .as_deref(),
                c["filter"].as_str(),
                "{c}"
            );
        }
    }

    /// A tag the scaler converts must never be cleared or changed: a valid
    /// matrix changes pixels when it is (see `decode_tag_neutraliser`).
    #[test]
    fn decode_tag_neutraliser_never_touches_a_tag_the_scaler_converts() {
        let prims: Vec<Option<&str>> =
            PRIMARIES.iter().map(|p| Some(*p)).chain([None]).collect();
        for m in SCALER_MATRICES.iter().chain(&["gbr"]) {
            for p in &prims {
                assert_eq!(decode_tag_neutraliser(Some(m), *p, None), None, "{m}/{p:?}");
            }
        }
        for t in TRANSFERS {
            assert_eq!(decode_tag_neutraliser(None, None, Some(t)), None, "{t}");
        }
    }

    /// Every matrix is either converted by the scaler as it is, or stands in
    /// as one it converts (`unknown` included), whatever the primaries. A tag
    /// added to `MATRICES` fails here until it is decided.
    #[test]
    fn every_matrix_is_converted_or_stands_in_as_one_that_is() {
        let prims: Vec<Option<&str>> =
            PRIMARIES.iter().map(|p| Some(*p)).chain([None]).collect();
        for m in MATRICES {
            for p in &prims {
                let c = ColorMetadata::from_raw(Some(m), *p, None, None);
                match c.scaler_stand_in() {
                    None => assert!(SCALER_MATRICES.contains(m), "{m} has no stand-in"),
                    Some(s) => {
                        assert!(!SCALER_MATRICES.contains(m), "{m} needs none");
                        assert!(s == "unknown" || SCALER_MATRICES.contains(&s), "{m}/{p:?}: {s}");
                        assert_eq!(
                            decode_tag_neutraliser(Some(m), *p, None),
                            Some(format!("setparams=colorspace={s}")),
                            "{m}/{p:?}"
                        );
                    }
                }
            }
        }
        // The six the negotiation list leaves out (FFmpeg 9.0.2).
        let off: Vec<&str> =
            MATRICES.iter().copied().filter(|m| !SCALER_MATRICES.contains(m)).collect();
        assert_eq!(
            off,
            ["ycgco", "bt2020c", "smpte2085", "chroma-derived-nc", "chroma-derived-c", "ictcp"]
        );
    }

    #[test]
    fn encoder_bridge_only_for_a_matrix_the_scaler_cannot_convert() {
        for m in SCALER_MATRICES {
            let c = ColorMetadata::from_raw(Some(m), Some("bt709"), None, None);
            assert_eq!(c.encoder_matrix_bridge(), None, "{m}");
        }
        assert_eq!(ColorMetadata::default().encoder_matrix_bridge(), None);
        let c = ColorMetadata::from_raw(Some("ycgco"), None, None, None);
        assert_eq!(
            c.encoder_matrix_bridge().as_deref(),
            Some("setparams=colorspace=unknown,scale,setparams=colorspace=ycgco")
        );
        let c = ColorMetadata::from_raw(Some("bt2020c"), Some("bt2020"), Some("smpte2084"), None);
        assert_eq!(
            c.encoder_matrix_bridge().as_deref(),
            Some("setparams=colorspace=bt2020nc,scale,setparams=colorspace=bt2020c")
        );
        let c = ColorMetadata::from_raw(Some("chroma-derived-nc"), Some("bt709"), None, None);
        assert_eq!(
            c.encoder_matrix_bridge().as_deref(),
            Some("setparams=colorspace=bt709,scale,setparams=colorspace=chroma-derived-nc")
        );
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

    /// One decision per `MATRICES` entry (task #88): a tag added to
    /// `MATRICES` fails here until its zimg reading is chosen.
    /// (matrix, with bt709 primaries + PQ, with bt470bg primaries + bt709
    /// transfer, untagged primaries and transfer), each at 1080 lines.
    #[test]
    fn zimg_colorspace_decides_every_matrix() {
        let m = ZimgColorspace::matrix_only;
        let cl = |p| ZimgColorspace { matrix: "chromancl", transfer: None, primaries: Some(p) };
        let table: &[(&str, [ZimgColorspace; 3])] = &[
            ("rgb", [m("709"); 3]),
            ("bt709", [m("709"); 3]),
            ("fcc", [m("fcc"); 3]),
            ("bt470bg", [m("470bg"); 3]),
            ("smpte170m", [m("170m"); 3]),
            ("smpte240m", [m("240m"); 3]),
            ("ycgco", [m("ycgco"); 3]),
            ("bt2020nc", [m("2020ncl"); 3]),
            ("bt2020c", [m("2020ncl"); 3]),
            ("smpte2085", [m("709"); 3]),
            ("chroma-derived-nc", [m("709"), cl("470bg"), m("709")]),
            ("chroma-derived-c", [m("709"), cl("470bg"), m("709")]),
            ("ictcp", [ZimgColorspace::ictcp("st2084"), m("2020ncl"), m("2020ncl")]),
        ];
        let keys: Vec<&str> = table.iter().map(|(m, _)| *m).collect();
        assert_eq!(keys, MATRICES, "decide the zimg reading of every matrix");
        let tags = [(Some("bt709"), Some("smpte2084")), (Some("bt470bg"), Some("bt709")), (None, None)];
        for (matrix, want) in table {
            for ((p, t), w) in tags.iter().zip(want) {
                let c = ColorMetadata::from_raw(Some(matrix), *p, *t, None);
                assert_eq!(c.zimg_colorspace(Some(1080)), *w, "{matrix} / {p:?} / {t:?}");
            }
        }
    }

    #[test]
    fn zimg_colorspace_rows() {
        let cs = |m, p, t| ColorMetadata::from_raw(Some(m), p, t, None).zimg_colorspace(Some(480));
        // chroma-derived: BT.2020 primaries are 2020ncl; a name zimg lacks
        // falls back to the height guess.
        assert_eq!(cs("chroma-derived-nc", Some("bt2020"), None).matrix, "2020ncl");
        assert_eq!(cs("chroma-derived-c", Some("smpte432"), None).primaries, Some("st432-1"));
        for p in ["smpte428", "jedec-p22", "ebu3213"] {
            assert_eq!(cs("chroma-derived-nc", Some(p), None), ZimgColorspace::matrix_only("170m"), "{p}");
        }
        // ictcp: HLG too, with BT.2020 primaries whatever the tag says.
        assert_eq!(cs("ictcp", Some("bt709"), Some("arib-std-b67")), ZimgColorspace::ictcp("std-b67"));
        assert_eq!(cs("ictcp", None, Some("bt2020-10")).matrix, "2020ncl");
        // bt2020c is never CL, HDR included.
        assert_eq!(cs("bt2020c", Some("bt2020"), Some("smpte2084")), ZimgColorspace::matrix_only("2020ncl"));
    }

    #[test]
    fn zimg_colorspace_renders_python() {
        let ictcp = ZimgColorspace::ictcp("st2084");
        assert_eq!(
            ictcp.to_yuv_args(),
            r#"matrix_s="ictcp", transfer_in_s="st2084", transfer_s="st2084", primaries_in_s="2020", primaries_s="2020""#
        );
        assert_eq!(
            ictcp.from_yuv_args(),
            r#"matrix_in_s="ictcp", transfer_in_s="st2084", transfer_s="st2084", primaries_in_s="2020", primaries_s="2020""#
        );
        assert_eq!(
            ictcp.py_literal(),
            r#"{"matrix": "ictcp", "transfer": "st2084", "primaries": "2020"}"#
        );
        let derived = ZimgColorspace { matrix: "chromancl", transfer: None, primaries: Some("470bg") };
        assert_eq!(derived.to_yuv_args(), r#"matrix_s="chromancl", primaries_in_s="470bg", primaries_s="470bg""#);
        assert_eq!(derived.py_literal(), r#"{"matrix": "chromancl", "primaries": "470bg"}"#);
    }

    /// Every tag that converted before task #88 renders exactly the text the
    /// templates had (`matrix_s="<zimg_matrix>"`), so its scripts are
    /// byte-identical.
    #[test]
    fn matrix_only_colourspaces_render_as_before() {
        for m in MATRICES.iter().map(|m| Some(*m)).chain([None]) {
            if matches!(m, Some("chroma-derived-nc" | "chroma-derived-c" | "ictcp")) {
                continue;
            }
            for p in PRIMARIES.iter().map(|p| Some(*p)).chain([None]) {
                for t in TRANSFERS.iter().map(|t| Some(*t)).chain([None]) {
                    let c = ColorMetadata::from_raw(m, p, t, None).zimg_colorspace(Some(1080));
                    assert_eq!(c.to_yuv_args(), format!("matrix_s=\"{}\"", c.matrix), "{m:?}");
                    assert_eq!(c.from_yuv_args(), format!("matrix_in_s=\"{}\"", c.matrix), "{m:?}");
                    assert_eq!(c.py_literal(), format!("\"{}\"", c.matrix), "{m:?}");
                }
            }
        }
    }

    #[test]
    fn sdr_sources_are_not_tone_mapped() {
        for c in [
            ColorMetadata::default(),
            ColorMetadata::from_raw(Some("bt709"), Some("bt709"), Some("bt709"), Some("tv")),
            ColorMetadata::from_raw(Some("bt2020nc"), Some("bt2020"), Some("bt2020-10"), None),
        ] {
            assert!(!c.is_hdr());
            assert_eq!(c.display_tonemap_filter(), None, "{c:?}");
        }
    }

    /// The exact chain. `HdrDisplay.toneMapFilter` in the app asserts the same
    /// string for the same tags — change both together, or the before and
    /// after frames stop matching.
    #[test]
    fn hdr10_tone_map_chain() {
        let c = ColorMetadata::from_raw(Some("bt2020nc"), Some("bt2020"), Some("smpte2084"), Some("tv"));
        assert!(c.is_hdr());
        assert_eq!(
            c.display_tonemap_filter().as_deref(),
            Some(
                "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084:range=tv,\
                 zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,\
                 tonemap=tonemap=hable:desat=0,zscale=t=bt709:r=full,\
                 format=rgb24,setparams=colorspace=gbr"
            )
        );
    }

    /// HLG keeps its own transfer; a PQ file missing its matrix and primaries
    /// (or carrying ones zscale can't use) is read as BT.2020.
    #[test]
    fn hlg_and_partly_tagged_hdr() {
        let hlg = ColorMetadata::from_raw(Some("bt2020nc"), Some("bt2020"), Some("arib-std-b67"), Some("pc"));
        let f = hlg.display_tonemap_filter().unwrap();
        assert!(f.starts_with(
            "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=arib-std-b67:range=pc,"
        ), "{f}");
        // zimg refuses constant luminance with PQ/HLG: bt2020c reads as NCL.
        for t in ["smpte2084", "arib-std-b67"] {
            let cl = ColorMetadata::from_raw(Some("bt2020c"), Some("bt2020"), Some(t), None);
            assert!(cl.display_tonemap_filter().unwrap().starts_with(
                &format!("setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc={t}:")
            ));
        }
        let bare = ColorMetadata::from_raw(Some("smpte2085"), None, Some("smpte2084"), None);
        assert!(bare.display_tonemap_filter().unwrap().starts_with(
            "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084:range=tv,"
        ));
    }

    /// `scale`'s `in_color_matrix` constants, from `ffmpeg -h filter=scale`
    /// of the bundled FFmpeg 9.0.2 (task #73). `preview_scale_ffmpeg_test.dart`
    /// runs every case of `preview_scale_cases.json` through each platform's
    /// bundled ffmpeg, so a build without one of these fails the push gate.
    const SWSCALE_IN_COLOR_MATRIX: &[&str] = &[
        "auto", "bt601", "bt470", "smpte170m", "bt470bg", "bt709", "fcc",
        "smpte240m", "bt2020", "bt2020nc",
    ];

    #[test]
    fn every_matrix_previews_with_a_name_scale_accepts() {
        let prims: Vec<Option<&str>> =
            PRIMARIES.iter().map(|p| Some(*p)).chain([None]).collect();
        for m in MATRICES.iter().map(|m| Some(*m)).chain([None]) {
            for p in &prims {
                let c = ColorMetadata::from_raw(m, *p, None, None);
                for o in c.swscale_input_opts() {
                    if let Some(v) = o.strip_prefix("in_color_matrix=") {
                        assert!(SWSCALE_IN_COLOR_MATRIX.contains(&v), "{m:?}/{p:?}: {o}");
                    }
                }
            }
        }
    }

    /// One decision per `MATRICES` entry, made on purpose: a tag added to
    /// `MATRICES` fails here until its preview reading is chosen.
    #[test]
    fn every_matrix_has_a_decided_preview_reading() {
        // (matrix, with bt709 primaries, with bt2020, with none)
        let table: &[(&str, [Option<&str>; 3])] = &[
            ("rgb", [None, None, None]),
            ("bt709", [Some("bt709"); 3]),
            ("fcc", [Some("fcc"); 3]),
            ("bt470bg", [Some("bt470bg"); 3]),
            ("smpte170m", [Some("smpte170m"); 3]),
            ("smpte240m", [Some("smpte240m"); 3]),
            ("ycgco", [None, None, None]),
            ("bt2020nc", [Some("bt2020nc"); 3]),
            ("bt2020c", [Some("bt2020"); 3]),
            ("smpte2085", [None, None, None]),
            ("chroma-derived-nc", [Some("bt709"), Some("bt2020"), None]),
            ("chroma-derived-c", [Some("bt709"), Some("bt2020"), None]),
            ("ictcp", [Some("bt2020"); 3]),
        ];
        let keys: Vec<&str> = table.iter().map(|(m, _)| *m).collect();
        assert_eq!(keys, MATRICES, "decide the preview reading of every matrix");
        for (m, want) in table {
            for (p, w) in [Some("bt709"), Some("bt2020"), None].iter().zip(want) {
                let c = ColorMetadata::from_raw(Some(m), *p, None, None);
                assert_eq!(c.swscale_matrix(), *w, "{m} / {p:?}");
            }
        }
        // Other primaries leave a derived matrix to auto.
        let c = ColorMetadata::from_raw(Some("chroma-derived-nc"), Some("bt470bg"), None, None);
        assert_eq!(c.swscale_input_opts(), vec!["in_range=tv"]);
        assert_eq!(ColorMetadata::default().swscale_matrix(), None);
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

    #[test]
    fn bt601_family_is_tagged_or_untagged_sd() {
        let tagged = |m: &str| ColorMetadata::from_raw(Some(m), None, None, None);
        assert!(tagged("bt470bg").is_bt601_family(Some(1080)));
        assert!(tagged("smpte170m").is_bt601_family(Some(480)));
        assert!(!tagged("bt709").is_bt601_family(Some(576)));
        assert!(!tagged("bt2020nc").is_bt601_family(Some(576)));
        let untagged = ColorMetadata::default();
        assert!(untagged.is_bt601_family(Some(576)));
        assert!(!untagged.is_bt601_family(Some(720)));
        // HDR is never 601, whatever its matrix says.
        let hdr = ColorMetadata::from_raw(Some("bt470bg"), None, Some("smpte2084"), None);
        assert!(!hdr.is_bt601_family(Some(576)));
    }

    #[test]
    fn bt709_converted_keeps_primaries_and_range() {
        // PAL, fully tagged: matrix and transfer become 709, primaries stay.
        let pal = ColorMetadata::from_raw(Some("bt470bg"), Some("bt470bg"), None, Some("tv"));
        assert_eq!(
            pal.bt709_converted(Some(576)).to_ffmpeg_output_args(),
            vec![
                "-colorspace", "bt709",
                "-color_primaries", "bt470bg",
                "-color_trc", "bt709",
                "-color_range", "tv",
            ]
        );
        // Untagged: primaries by height (576 is PAL, 480 NTSC), range limited.
        let untagged = ColorMetadata::default();
        let pal = untagged.bt709_converted(Some(576));
        assert_eq!(pal.primaries.as_deref(), Some("bt470bg"));
        assert_eq!(pal.range.as_deref(), Some("tv"));
        let ntsc = untagged.bt709_converted(Some(480));
        assert_eq!(ntsc.primaries.as_deref(), Some("smpte170m"));
        // A full-range source stays full range.
        let full = ColorMetadata::from_raw(Some("smpte170m"), None, Some("smpte170m"), Some("pc"));
        let out = full.bt709_converted(Some(480));
        assert_eq!(out.range.as_deref(), Some("pc"));
        assert_eq!(out.transfer.as_deref(), Some("bt709"));
        assert_eq!(out.zimg_matrix(Some(480)), "709");
    }
}
