//! Preview pipeline integration test.
//!
//! Regression test for a colour-format/frame-size desync: `pal-sd-25.mov` is a
//! 10-bit 4:2:2 ProRes file whose ffprobe-reported coded size (720x576) differs
//! from the size ffmpeg actually decodes (702x576 clean aperture). If the
//! decoder's raw output size doesn't match what `pipe_source` expects, frames
//! desync and the processed preview is garbage.
//!
//! With all filters disabled the preview is a passthrough, so the processed
//! frame must closely match a direct decode of the same source frame.
//!
//! Run with: cargo test --test preview_integration_test -- --nocapture

use std::path::PathBuf;
use std::process::Command;
use uuid::Uuid;

use vapourbox_worker::dependency_locator::DependencyLocator;
use vapourbox_worker::models::*;

const WIDTH: i32 = 720;
const HEIGHT: i32 = 576;
const FPS: f64 = 25.0;
const FRAME: i64 = 10;
const PIX_FMT: &str = "yuv422p10le";

fn test_resource(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("Tests")
        .join("TestResources")
        .join(name)
}

fn test_output_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("Tests")
        .join("TestOutput");
    std::fs::create_dir_all(&dir).ok();
    dir
}

#[test]
fn test_preview_10bit_422_matches_source_frame() {
    let src = test_resource("pal-sd-25.mov");
    assert!(src.exists(), "Test video not found: {:?}", src);

    let out_dir = test_output_dir();

    // Build a preview job with all filters disabled (passthrough).
    let job = VideoJob {
        id: Uuid::new_v4(),
        input_path: src.to_string_lossy().to_string(),
        output_path: out_dir.join("preview_unused.mov").to_string_lossy().to_string(),
        // All filters disabled — a pure passthrough preview.
        qtgmc_parameters: QTGMCParameters {
            enabled: false,
            ..QTGMCParameters::default()
        },
        processing_pipeline: Some(ProcessingPipeline {
            deinterlace: QTGMCParameters {
                enabled: false,
                ..QTGMCParameters::default()
            },
            ..ProcessingPipeline::default()
        }),
        encoding_settings: EncodingSettings::default(),
        detected_field_order: None,
        total_frames: None,
        input_frame_rate: Some(FPS),
        start_frame: None,
        end_frame: None,
        subtitle_settings: None,
        subtitle_only: false,
        input_sar: None,
        input_width: Some(WIDTH),
        input_height: Some(HEIGHT),
        input_pixel_format: Some(PIX_FMT.to_string()),
        input_color_matrix: None,
        input_color_primaries: None,
        input_color_transfer: None,
        input_color_range: None,
        burn_in_subtitle_path: None,
    };

    let cfg_path = out_dir.join("preview_pal_job.json");
    std::fs::write(&cfg_path, serde_json::to_string(&job).expect("serialize job"))
        .expect("write job config");

    // Run the worker in preview mode; stdout is the processed-frame PNG.
    let output = Command::new(env!("CARGO_BIN_EXE_vapourbox-worker"))
        .args([
            "--preview",
            "--frame",
            &FRAME.to_string(),
            "--config",
            cfg_path.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run worker in preview mode");

    assert!(
        output.status.success(),
        "preview mode failed:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!output.stdout.is_empty(), "preview produced no PNG output");

    let preview_png = out_dir.join("preview_out.png");
    std::fs::write(&preview_png, &output.stdout).expect("write preview png");

    // Use the same ffmpeg + environment the worker used.
    let deps = DependencyLocator::new().expect("locate dependencies");
    let ffmpeg = deps.ffmpeg_path().expect("locate ffmpeg");
    let env = deps.build_environment();

    let ffmpeg_to_rgb = |label: &str, input_args: &[&str]| -> Vec<u8> {
        let raw = out_dir.join(format!("{}.rgb", label));
        let mut cmd = Command::new(&ffmpeg);
        cmd.envs(&env).args(["-y", "-v", "error"]).args(input_args).args([
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            raw.to_str().unwrap(),
        ]);
        let status = cmd.status().expect("run ffmpeg");
        assert!(status.success(), "ffmpeg conversion for '{}' failed", label);
        std::fs::read(&raw).expect("read rgb")
    };

    // Processed preview frame -> rgb24.
    let preview_rgb = ffmpeg_to_rgb("preview", &["-i", preview_png.to_str().unwrap()]);

    // Reference: decode the same source frame, forced to the pipeline's declared
    // dimensions and the same range scaling — the "correct passthrough" result.
    let time = FRAME as f64 / FPS;
    let reference_rgb = ffmpeg_to_rgb(
        "reference",
        &[
            "-ss",
            &format!("{:.6}", time),
            "-i",
            src.to_str().unwrap(),
            "-map",
            "0:v:0",
            "-frames:v",
            "1",
            "-vf",
            &format!("scale={}:{}:in_range=tv:out_range=pc", WIDTH, HEIGHT),
        ],
    );

    assert_eq!(
        preview_rgb.len(),
        reference_rgb.len(),
        "preview ({} bytes) and reference ({} bytes) differ in size — frame/format desync",
        preview_rgb.len(),
        reference_rgb.len()
    );
    assert_eq!(
        preview_rgb.len(),
        (WIDTH * HEIGHT * 3) as usize,
        "unexpected frame size"
    );

    let total_diff: u64 = preview_rgb
        .iter()
        .zip(reference_rgb.iter())
        .map(|(a, b)| (*a as i32 - *b as i32).unsigned_abs() as u64)
        .sum();
    let mean_abs_diff = total_diff as f64 / preview_rgb.len() as f64;
    println!(
        "Preview vs source frame mean abs diff = {:.2} (0 = identical)",
        mean_abs_diff
    );

    // Garbage (format/size desync) yields a mean abs diff of ~60-120; a correct
    // passthrough is only a few units off (10->8 bit rounding, scaler).
    assert!(
        mean_abs_diff < 20.0,
        "Processed preview does not match the source frame (mean abs diff {:.2}). \
         Likely a colour-format / frame-size desync producing garbage.",
        mean_abs_diff
    );
}
