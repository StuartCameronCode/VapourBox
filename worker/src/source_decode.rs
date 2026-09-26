//! The ffmpeg arguments that decode the source into the raw pipe `pipe_source`
//! reads — the single place both the encode and the preview path get them from.
//!
//! `pipe_source.py` sizes every frame from the job's `input_width` x
//! `input_height` (ffprobe's `width`/`height`), so the decoder must emit frames
//! of exactly that size or the byte stream desyncs into garbage. Two rules keep
//! that true without ever resampling the picture:
//!
//! 1. **Decode the full stored frame** — `-apply_cropping codec`. Since FFmpeg
//!    7.1 the CLI applies *container* cropping by default: a QuickTime `clap`
//!    (clean aperture) atom or a Matroska `PixelCrop*` element is exported as
//!    frame-cropping side data and cut off at decode time. ffprobe's
//!    `width`/`height` do **not** include it (they report the full 720x576 of a
//!    720x576 ProRes with a 702-wide clean aperture; the crop only appears as
//!    `side_data_list: Frame Cropping`), so the default decode came out 702 wide
//!    against a job that said 720. `codec` keeps the *bitstream's* own cropping
//!    (the H.264/HEVC SPS crop that turns 1088 coded lines into 1080), which
//!    ffprobe's `width`/`height` already include — so the decoded size is the
//!    probed size by construction. The user's Crop controls are then the only
//!    crop the pipeline ever applies. (`none` would be wrong: it would decode an
//!    H.264 1080p stream at 1920x1088.)
//! 2. **A size mismatch is an error, never a resample.** This used to pass
//!    `-s WxH`, which "fixed" the clean-aperture desync by silently rescaling the
//!    702-wide crop back to 720 — cropped *and* resampled, with a 2.6%
//!    horizontal stretch. [`size_guard_filter`] instead passes frames of exactly
//!    the expected size through untouched (a full-frame `crop` is a pointer
//!    no-op) and fails the decode on any other size, including a mid-stream
//!    resolution change, which with no guard at all would desync into garbage.
//!
//! See docs/ENGINEERING_NOTES.md, "Clean aperture: decode the stored frame".

/// Input option placed before `-i` on every ffmpeg that decodes the source's
/// pictures for the pipeline (encode decoder, preview decoder). See the module
/// docs for why `codec` and not `none`/`all`.
pub const APPLY_CROPPING: [&str; 2] = ["-apply_cropping", "codec"];

/// The message ffmpeg's `crop` filter logs when [`size_guard_filter`] rejects a
/// frame. Used to recognise a guard failure in the decoder's stderr and replace
/// ffmpeg's cryptic wording with an explanation.
pub const SIZE_GUARD_SIGNATURE: &str = "Invalid too big or non positive size";

/// A `-vf` that passes `width`x`height` frames through unchanged and fails the
/// decode on anything else.
///
/// `crop` re-evaluates `w`/`h` whenever its input is (re)configured — at the
/// first frame and again on any mid-stream size change — and rejects a zero
/// size. So a matching frame is a full-frame, zero-copy crop, and a mismatch is
/// a hard error instead of either a rescale or a silently desynced raw stream.
pub fn size_guard_filter(width: i32, height: i32) -> String {
    format!(
        "crop=w='if(eq(iw\\,{w})\\,iw\\,0)':h='if(eq(ih\\,{h})\\,ih\\,0)':x=0:y=0:exact=1",
        w = width,
        h = height
    )
}

/// If a failed decoder's stderr shows the size guard tripped, the error to
/// report instead of ffmpeg's exit code.
pub fn explain_decoder_failure(stderr: &str, width: i32, height: i32) -> Option<String> {
    if !stderr.contains(SIZE_GUARD_SIGNATURE) {
        return None;
    }
    Some(format!(
        "The source decoded at a different frame size than the {}x{} it was probed at \
         (for example, its resolution changes part-way through). VapourBox does not \
         resample the source to hide this, since that would silently distort it. \
         Trim the job to a section with a single frame size, or convert the source \
         to one size first.",
        width, height
    ))
}

/// Everything the encode path's decoder ffmpeg needs, in order. Writes the raw
/// frames to stdout (`pipe:1`) for vspipe.
///
/// `pix_fmt` must be `pixel_format::decode_pixel_format`'s answer — the same one
/// the generated script declares (see "Source Pixel Formats" in CLAUDE.md).
#[allow(clippy::too_many_arguments)]
pub fn encode_decoder_args(
    input_path: &str,
    width: i32,
    height: i32,
    pix_fmt: &str,
    input_frame_rate: Option<f64>,
    start_frame: Option<i32>,
    end_frame: Option<i32>,
    total_frames: Option<i32>,
) -> Vec<String> {
    let mut args: Vec<String> = Vec::new();

    // Seek to the start frame if specified (before -i for an accurate,
    // fast decode-seek). Target the midpoint of the interval *before*
    // `start` so the first kept frame (PTS >= seek time) is exactly `start`,
    // not start±1 — the boundary `start/fps` is ambiguous under PTS rounding.
    if let Some(start) = start_frame {
        if start > 0 {
            let fps = input_frame_rate.unwrap_or(29.97);
            let seek_time = ((start as f64 - 0.5) / fps).max(0.0);
            args.push("-ss".to_string());
            args.push(format!("{:.6}", seek_time));
        }
    }

    args.extend(APPLY_CROPPING.iter().map(|s| s.to_string()));
    args.extend([
        "-i".to_string(), input_path.to_string(),
        "-map".to_string(), "0:v:0".to_string(), // only first video stream
        "-vf".to_string(), size_guard_filter(width, height),
        "-f".to_string(), "rawvideo".to_string(),
        "-pix_fmt".to_string(), pix_fmt.to_string(),
        "-v".to_string(), "error".to_string(),
    ]);

    // Limit decoder frame count to match what pipe_source expects.
    // Without this, the decoder can send more frames than TOTAL_FRAMES
    // (e.g. MPEG-2 telecine produces duplicate frames), causing a broken
    // pipe when vspipe closes stdin before the decoder finishes.
    // For trimmed exports, limit to the trimmed range instead.
    if let (Some(start), Some(end)) = (start_frame, end_frame) {
        let count = end - start + 1;
        if count > 0 {
            args.push("-frames:v".to_string());
            args.push(count.to_string());
        }
    } else if let Some(end) = end_frame {
        let count = end + 1;
        args.push("-frames:v".to_string());
        args.push(count.to_string());
    } else if let Some(total) = total_frames {
        args.push("-frames:v".to_string());
        args.push(total.to_string());
    }

    args.push("pipe:1".to_string()); // stdout via FFmpeg pipe protocol
    args
}

/// The preview path's decoder: `num_frames` raw frames from `seek_time` into
/// `output_path`. Same cropping and size rules as [`encode_decoder_args`].
pub fn preview_decoder_args(
    input_path: &str,
    seek_time: f64,
    num_frames: i32,
    width: i32,
    height: i32,
    pix_fmt: &str,
    output_path: &str,
) -> Vec<String> {
    let mut args: Vec<String> = vec!["-ss".to_string(), format!("{:.6}", seek_time)];
    args.extend(APPLY_CROPPING.iter().map(|s| s.to_string()));
    args.extend([
        "-i".to_string(), input_path.to_string(),
        "-map".to_string(), "0:v:0".to_string(),
        "-frames:v".to_string(), num_frames.to_string(),
        "-vf".to_string(), size_guard_filter(width, height),
        "-f".to_string(), "rawvideo".to_string(),
        "-pix_fmt".to_string(), pix_fmt.to_string(),
        "-v".to_string(), "error".to_string(),
        "-y".to_string(),
        output_path.to_string(),
    ]);
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_args() -> Vec<String> {
        encode_decoder_args("in.mov", 720, 576, "yuv422p10le", Some(25.0), None, None, Some(100))
    }

    fn preview_args() -> Vec<String> {
        preview_decoder_args("in.mov", 0.38, 11, 720, 576, "yuv422p10le", "frames.raw")
    }

    fn pos(args: &[String], flag: &str) -> Option<usize> {
        args.iter().position(|a| a == flag)
    }

    /// Both decoders, so every assertion below covers both paths.
    fn both() -> [(&'static str, Vec<String>); 2] {
        [("encode", encode_args()), ("preview", preview_args())]
    }

    #[test]
    fn decoders_never_rescale_the_source() {
        // `-s WxH` on the decoder output silently resamples a source that
        // decodes at another size (a clean aperture: 702 -> 720). Neither it nor
        // a scale filter may come back.
        for (path, args) in both() {
            assert!(pos(&args, "-s").is_none(), "{path} decoder passes -s: {args:?}");
            assert!(
                !args.iter().any(|a| a.contains("scale")),
                "{path} decoder scales: {args:?}"
            );
        }
    }

    #[test]
    fn decoders_keep_the_container_crop_off() {
        // `-apply_cropping codec` is an INPUT option: it must precede `-i`, or
        // ffmpeg applies it to the output and the clap crop still happens.
        for (path, args) in both() {
            let ac = pos(&args, "-apply_cropping")
                .unwrap_or_else(|| panic!("{path} decoder has no -apply_cropping: {args:?}"));
            assert_eq!(args[ac + 1], "codec", "{path}: must be `codec`, not none/all");
            assert!(ac < pos(&args, "-i").unwrap(), "{path}: -apply_cropping after -i");
        }
    }

    #[test]
    fn decoders_guard_the_probed_size() {
        for (path, args) in both() {
            let vf = pos(&args, "-vf").unwrap_or_else(|| panic!("{path}: no -vf"));
            assert_eq!(args[vf + 1], size_guard_filter(720, 576), "{path}");
            // Exactly one -vf: ffmpeg honours only the last.
            assert_eq!(args.iter().filter(|a| *a == "-vf").count(), 1, "{path}");
            assert!(vf > pos(&args, "-i").unwrap(), "{path}: -vf must be an output option");
        }
    }

    #[test]
    fn size_guard_is_a_full_frame_crop_that_rejects_other_sizes() {
        let g = size_guard_filter(720, 576);
        assert_eq!(
            g,
            "crop=w='if(eq(iw\\,720)\\,iw\\,0)':h='if(eq(ih\\,576)\\,ih\\,0)':x=0:y=0:exact=1"
        );
        // Anchored at the origin — never a centred crop of a larger frame.
        assert!(g.contains(":x=0:y=0"));
    }

    #[test]
    fn decoders_use_the_pipe_format() {
        for (path, args) in both() {
            let pf = pos(&args, "-pix_fmt").unwrap();
            assert_eq!(args[pf + 1], "yuv422p10le", "{path}");
        }
    }

    #[test]
    fn encode_decoder_trims_and_limits_frames() {
        let args = encode_decoder_args("in.mov", 720, 576, "yuv420p", Some(25.0), Some(10), Some(19), None);
        // Seek before -i, to the midpoint before the start frame.
        let ss = pos(&args, "-ss").unwrap();
        assert!(ss < pos(&args, "-i").unwrap());
        assert_eq!(args[ss + 1], "0.380000");
        let fv = pos(&args, "-frames:v").unwrap();
        assert_eq!(args[fv + 1], "10");
        assert_eq!(args.last().unwrap(), "pipe:1");

        let untrimmed = encode_args();
        assert!(pos(&untrimmed, "-ss").is_none());
        assert_eq!(untrimmed[pos(&untrimmed, "-frames:v").unwrap() + 1], "100");
    }

    #[test]
    fn preview_decoder_writes_the_raw_file() {
        let args = preview_args();
        assert_eq!(args[0], "-ss");
        assert_eq!(args[pos(&args, "-frames:v").unwrap() + 1], "11");
        assert_eq!(args.last().unwrap(), "frames.raw");
    }

    #[test]
    fn guard_failures_are_explained() {
        let stderr = "[Parsed_crop_0 @ 0x6000] Invalid too big or non positive size for width '0' or height '576'\n\
                      [Parsed_crop_0 @ 0x6000] Failed to configure input pad on Parsed_crop_0";
        let msg = explain_decoder_failure(stderr, 720, 576).expect("guard failure recognised");
        assert!(msg.contains("720x576"));
        assert!(explain_decoder_failure("Broken pipe", 720, 576).is_none());
    }
}
