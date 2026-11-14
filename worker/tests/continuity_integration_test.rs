//! Timestamp resets (task #21): `--scan-timestamps` and `--make-continuous`
//! on the committed reset fixtures, through the worker binary as the app
//! runs it. Needs ffmpeg/ffprobe (the deps bundle in a debug build).
//!
//! The fixtures (Tests/TestResources/generate_mpeg_seek_test.sh) are two
//! 150-picture halves, each with its own clock, joined byte for byte: the
//! clock goes back at picture 150.
//!
//! Run with: cargo test --test continuity_integration_test -- --nocapture

use std::path::PathBuf;
use std::process::Command;

fn resource(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("Tests")
        .join("TestResources")
        .join(name)
}

fn worker() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vapourbox-worker"))
}

fn scan(path: &std::path::Path) -> serde_json::Value {
    let out = worker().arg("--scan-timestamps").arg(path).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stdout));
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn reset_fixtures_scan_then_join_into_one_timeline() {
    for (name, format) in [("seek_reset_dvd_pal.mpg", "mpeg"), ("seek_reset_h264.ts", "mpegts")] {
        let src = resource(name);
        assert!(src.exists(), "missing {:?}", src);

        let s = scan(&src);
        assert_eq!(s["format"], format, "{s}");
        assert_eq!(s["videoPackets"], 300, "{s}");
        let video: Vec<&serde_json::Value> = s["resets"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["codecType"] == "video")
            .collect();
        assert_eq!(video.len(), 1, "{s}");
        assert_eq!(video[0]["packet"], 150, "{s}");

        let dir = std::env::temp_dir().join(format!("vb_continuity_it_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let out = dir.join(format!("joined_{name}"));
        let r = worker()
            .arg("--make-continuous")
            .arg(&src)
            .arg("--output")
            .arg(&out)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&r.stdout);
        assert!(r.status.success(), "{stdout}");
        assert!(stdout.contains("\"phase\":\"joining\""), "{stdout}");

        let j = scan(&out);
        assert_eq!(j["format"], format, "same container: {j}");
        assert_eq!(j["resets"].as_array().unwrap().len(), 0, "{j}");
        assert_eq!(j["videoPackets"], 300, "{j}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[test]
fn a_source_without_a_reset_is_not_copied() {
    for name in ["seek_dvd_pal.mpg", "seek_gop_late_video.ts", "pal-dvbt-fieldcoded-25i.ts"] {
        let s = scan(&resource(name));
        assert_eq!(s["applies"], true, "{name}: {s}");
        assert_eq!(s["resets"].as_array().unwrap().len(), 0, "{name}: {s}");
    }
    let s = scan(&resource("small_clip.mp4"));
    assert_eq!(s["applies"], false, "{s}");

    let out = std::env::temp_dir().join(format!("vb_continuity_none_{}.mpg", std::process::id()));
    let r = worker()
        .arg("--make-continuous")
        .arg(resource("seek_dvd_pal.mpg"))
        .arg("--output")
        .arg(&out)
        .output()
        .unwrap();
    assert!(!r.status.success());
    assert!(String::from_utf8_lossy(&r.stdout).contains("no timestamp reset"));
    assert!(!out.exists());
}
