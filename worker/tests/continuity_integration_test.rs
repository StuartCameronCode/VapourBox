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
        // The picture decides the join (task #58): the scan carries a plan.
        assert!(s["join"]["streams"].as_array().is_some_and(|v| !v.is_empty()), "{s}");

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

/// `--probe-source`'s model line and its stderr, where every probe that
/// failed says why (task #83).
fn probe_with_log(path: &std::path::Path, defer: bool) -> (String, String) {
    let mut c = worker();
    c.arg("--probe-source").arg(path);
    if defer {
        c.arg("--defer-scan");
    }
    let out = c.output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    assert!(out.status.success(), "{}\nstderr:\n{stderr}", String::from_utf8_lossy(&out.stdout));
    (String::from_utf8(out.stdout).unwrap().trim().to_string(), stderr)
}

fn probe(path: &std::path::Path, defer: bool) -> String {
    probe_with_log(path, defer).0
}

/// Task #55: `--defer-scan` leaves a TS/PS's whole-file scan out of the
/// model, and `--complete-source` finishes it, with progress, into exactly
/// the model `--probe-source` makes in one go. Any other format has nothing
/// to defer and its model is byte for byte the same.
#[test]
fn a_deferred_scan_completes_to_the_same_model() {
    let dir = std::env::temp_dir().join(format!("vb_continuity_defer_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    for name in ["seek_reset_dvd_pal.mpg", "seek_reset_h264.ts", "seek_dvd_pal.mpg", "small_clip.mp4"] {
        let src = resource(name);
        let (full, full_log) = probe_with_log(&src, false);
        let (deferred, deferred_log) = probe_with_log(&src, true);
        let ts_ps = !name.ends_with(".mp4");
        let d: serde_json::Value = serde_json::from_str(&deferred).unwrap();
        if !ts_ps {
            assert_eq!(
                deferred, full,
                "{name}: nothing to defer\n--defer-scan stderr:\n{deferred_log}\n--probe-source stderr:\n{full_log}"
            );
            continue;
        }
        assert_eq!(d["continuityDeferred"], true, "{name}: {deferred}");
        assert!(d["continuity"].is_null(), "{name}: {deferred}");

        let model_file = dir.join(format!("{name}.json"));
        std::fs::write(&model_file, &deferred).unwrap();
        let out = worker().arg("--complete-source").arg(&model_file).output().unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "{name}: {stdout}");
        let lines: Vec<&str> = stdout.lines().collect();
        let fractions: Vec<f64> = lines
            .iter()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .filter(|j| j["type"] == "progress" && j["phase"] == "scanning")
            .map(|j| j["frame"].as_f64().unwrap() / j["totalFrames"].as_f64().unwrap())
            .collect();
        assert!(fractions.len() > 2, "{name}: progress while reading: {stdout}");
        assert!(fractions.windows(2).all(|w| w[1] >= w[0]), "{name}: {fractions:?}");
        assert_eq!(*fractions.last().unwrap(), 1.0, "{name}: {fractions:?}");
        assert_eq!(lines.last().unwrap().trim(), full, "{name}: the completed model");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// Task #55: given the source model (`--source`), `--make-continuous` uses
/// its scan instead of reading the whole source a second time, and makes
/// the same copy.
#[test]
fn the_join_uses_the_models_scan() {
    let dir = std::env::temp_dir().join(format!("vb_continuity_known_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let src = resource("seek_reset_dvd_pal.mpg");
    let model_file = dir.join("model.json");
    std::fs::write(&model_file, probe(&src, false)).unwrap();
    let join = |out: &std::path::Path, with_model: bool| {
        let mut c = worker();
        c.arg("--make-continuous").arg(&src).arg("--output").arg(out);
        if with_model {
            c.arg("--source").arg(&model_file);
        }
        let r = c.output().unwrap();
        assert!(r.status.success(), "{}", String::from_utf8_lossy(&r.stdout));
        String::from_utf8_lossy(&r.stdout).to_string()
    };
    let (a, b) = (dir.join("a.mpg"), dir.join("b.mpg"));
    assert!(join(&a, true).contains("Using the source model's timestamp scan"));
    assert!(!join(&b, false).contains("Using the source model's timestamp scan"));
    assert_eq!(std::fs::read(&a).unwrap(), std::fs::read(&b).unwrap(), "the same copy");

    // A model of another file is not used.
    let other = dir.join("other.json");
    std::fs::write(&other, probe(&resource("seek_reset_h264.ts"), false)).unwrap();
    let r = worker()
        .arg("--make-continuous")
        .arg(&src)
        .arg("--output")
        .arg(dir.join("c.mpg"))
        .arg("--source")
        .arg(&other)
        .output()
        .unwrap();
    assert!(r.status.success());
    assert!(!String::from_utf8_lossy(&r.stdout).contains("Using the source model"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A planned join whose copy does not check out falls back to ffmpeg's own
/// correction (how every reset was joined before task #58), rather than
/// leaving the source unjoined.
#[test]
fn a_planned_join_that_fails_falls_back_to_ffmpegs_correction() {
    use vapourbox_worker::dependency_locator::DependencyLocator;
    use vapourbox_worker::source_continuity::{make_continuous, scan as scan_file};
    let d = DependencyLocator::new().expect("deps");
    let (ffmpeg, ffprobe, env) = (d.ffmpeg_path().unwrap(), d.ffprobe_path().unwrap(), d.build_environment());
    let src = resource("seek_reset_dvd_pal.mpg");
    let src = src.to_str().unwrap();
    let mut source = scan_file(&ffprobe, &env, src).unwrap();
    // A plan that leaves the clock going back: its copy keeps the reset.
    let plan = source.join.as_mut().expect("a plan");
    for s in &mut plan.streams {
        for c in &mut s.cuts {
            c.offset = 0.0;
        }
    }
    let out = std::env::temp_dir().join(format!("vb_continuity_fallback_{}.mpg", std::process::id()));
    let copy = make_continuous(&ffmpeg, &ffprobe, &env, src, &source, &out, |_| {}).expect("the fallback joins");
    assert!(copy.resets.is_empty(), "{:?}", copy.resets);
    assert_eq!(copy.video_packets, 300);
    let _ = std::fs::remove_file(&out);
}
