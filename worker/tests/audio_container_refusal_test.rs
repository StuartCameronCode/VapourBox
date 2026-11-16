//! Task #39: a Convert codec the container can't hold (Opus in MOV/AVI, FLAC
//! in MOV) is refused by the worker binary before any work, with our message
//! rather than ffmpeg's "Could not write header". No deps needed: the refusal
//! comes before every probe.
//!
//! Run with: cargo test --test audio_container_refusal_test

use std::process::Command;

use uuid::Uuid;
use vapourbox_worker::models::*;

fn job(dir: &std::path::Path, codec: AudioCodec, container: ContainerFormat) -> VideoJob {
    let input = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("Tests/TestResources/small_clip.mp4");
    let mut j: VideoJob = serde_json::from_value(serde_json::json!({
        "id": Uuid::new_v4(),
        "inputPath": input.to_string_lossy(),
        "outputPath": dir.join(format!("out.{}", container.extension())).to_string_lossy(),
        "qtgmcParameters": {},
        "encodingSettings": {},
    }))
    .unwrap();
    j.encoding_settings.codec = VideoCodec::FFV1;
    j.encoding_settings.container = container;
    j.encoding_settings.audio_mode = AudioMode::Convert;
    j.encoding_settings.audio_codec = codec;
    j
}

#[test]
fn unsupported_convert_pairs_are_refused_before_any_work() {
    for (codec, container) in [
        (AudioCodec::Opus, ContainerFormat::Mov),
        (AudioCodec::Opus, ContainerFormat::Avi),
        (AudioCodec::Flac, ContainerFormat::Mov),
    ] {
        let dir = std::env::temp_dir().join(format!("vb_audio_refusal_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let j = job(&dir, codec, container);
        let config = dir.join("job.json");
        std::fs::write(&config, serde_json::to_string(&j).unwrap()).unwrap();

        let out = Command::new(env!("CARGO_BIN_EXE_vapourbox-worker"))
            .arg("--config")
            .arg(&config)
            .env("TMPDIR", &dir)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert_eq!(out.status.code(), Some(1), "{codec:?}/{container:?}: {stdout}");

        let want = codec.container_problem(container).unwrap();
        let error = stdout
            .lines()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .find(|m| m["type"] == "error")
            .unwrap_or_else(|| panic!("no error message: {stdout}"));
        assert_eq!(error["message"], want.as_str(), "the job error is our message, unwrapped");
        assert!(!stdout.contains("Generating VapourSynth script"), "{stdout}");

        let left: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n != "job.json")
            .collect();
        assert!(left.is_empty(), "nothing written (no .vpy, no output): {left:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// Task #49: a video codec FFmpeg can't write to the container (HuffYUV,
/// ProRes or v210 in MP4; AV1 in MOV) or AV1 in AVI is refused the same way,
/// in the table's words.
#[test]
fn video_pairs_ffmpeg_cannot_write_are_refused_before_any_work() {
    for (video, container) in [
        (VideoCodec::Huffyuv, ContainerFormat::Mp4),
        (VideoCodec::ProResHQ, ContainerFormat::Mp4),
        (VideoCodec::V210, ContainerFormat::Mp4),
        (VideoCodec::Av1, ContainerFormat::Mov),
        (VideoCodec::Av1, ContainerFormat::Avi),
    ] {
        let dir = std::env::temp_dir().join(format!("vb_video_refusal_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut j = job(&dir, AudioCodec::Aac, container);
        j.encoding_settings.codec = video;
        let config = dir.join("job.json");
        std::fs::write(&config, serde_json::to_string(&j).unwrap()).unwrap();
        let out = Command::new(env!("CARGO_BIN_EXE_vapourbox-worker"))
            .arg("--config")
            .arg(&config)
            .env("TMPDIR", &dir)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert_eq!(out.status.code(), Some(1), "{video:?}/{container:?}: {stdout}");
        let error = stdout
            .lines()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .find(|m| m["type"] == "error")
            .unwrap_or_else(|| panic!("no error message: {stdout}"));
        assert_eq!(error["message"], video.container_problem(container).unwrap());
        assert!(!stdout.contains("Generating VapourSynth script"), "{stdout}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
