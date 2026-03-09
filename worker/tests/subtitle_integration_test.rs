//! Integration test for subtitle generation using Whisper.
//!
//! Prerequisites:
//! - whisper-cli binary at addons/whisper/bin/whisper-cli (Homebrew bottle)
//! - whisper small model at addons/whisper/models/ggml-small.bin
//! - ffmpeg/ffprobe in deps/ (standard VapourBox deps)
//!
//! Run with: cargo test --test subtitle_integration_test -- --nocapture

use std::path::PathBuf;

use vapourbox_worker::dependency_locator::DependencyLocator;
use vapourbox_worker::models::{SubtitleOutput, SubtitleSettings};
use vapourbox_worker::progress_reporter::ProgressReporter;
use vapourbox_worker::subtitle_generator::SubtitleGenerator;

fn get_test_video() -> PathBuf {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    PathBuf::from(manifest_dir)
        .parent()
        .unwrap()
        .join("Tests")
        .join("TestResources")
        .join("small_clip.mp4")
}

fn get_output_dir() -> PathBuf {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    PathBuf::from(manifest_dir)
        .parent()
        .unwrap()
        .join("Tests")
        .join("TestOutput")
}

/// Test subtitle generation with the small model.
#[test]
fn test_subtitle_generation_srt_file() {
    let video_path = get_test_video();
    assert!(
        video_path.exists(),
        "Test video not found: {:?}",
        video_path
    );

    let output_dir = get_output_dir();
    std::fs::create_dir_all(&output_dir).ok();

    // Copy video to output dir so the .srt file goes there
    let test_video = output_dir.join("subtitle_test.mp4");
    std::fs::copy(&video_path, &test_video).expect("Failed to copy test video");

    let reporter = ProgressReporter::new();
    let deps = DependencyLocator::new().expect("Failed to create DependencyLocator");

    // Verify whisper-cli and model are available
    let whisper_path = deps.whisper_path();
    assert!(
        whisper_path.is_ok(),
        "whisper-cli not found. Install to addons/whisper/bin/whisper-cli. Error: {:?}",
        whisper_path.err()
    );
    println!("whisper-cli: {:?}", whisper_path.unwrap());

    let model_path = deps.whisper_model_path("small");
    assert!(
        model_path.is_ok(),
        "Whisper small model not found. Download to addons/whisper/models/ggml-small.bin. Error: {:?}",
        model_path.err()
    );
    println!("Model: {:?}", model_path.unwrap());

    let settings = SubtitleSettings {
        enabled: true,
        model: "small".to_string(),
        output: SubtitleOutput::SrtFile,
        language: Some("en".to_string()),
    };

    let sub_gen = SubtitleGenerator::new(reporter, deps);

    let result = sub_gen.generate(
        &test_video.to_string_lossy(),
        &settings,
        || false, // never cancel
        None,     // no separate output path (post-encode style)
    );

    match &result {
        Ok(Some(srt_path)) => {
            println!("\nSRT file generated: {:?}", srt_path);
            let content = std::fs::read_to_string(srt_path).unwrap();
            println!("\n--- SRT Content ---");
            println!("{}", content);
            println!("--- End SRT ---\n");

            assert!(!content.trim().is_empty(), "SRT file should not be empty");
        }
        Ok(None) => {
            panic!("Expected SRT file but got None (no subtitles generated)");
        }
        Err(e) => {
            panic!("Subtitle generation failed: {:#}", e);
        }
    }

    // Clean up test video copy (keep the .srt for inspection)
    let _ = std::fs::remove_file(&test_video);
}
