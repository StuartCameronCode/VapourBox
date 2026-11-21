//! An MP4 edit list's frame count under load (task #83): `--probe-source`
//! run many times at once, as `cargo test` runs the integration tests, must
//! count the decoded pictures every time, never the stored ones.
//!
//! On Windows CI `small_clip.mp4` once counted 3154 (`nb_frames`) instead of
//! 3151: a probe that sees the edit list's discards dropped out and the
//! count fell back to the stored one, silently. The probes now retry, list
//! every packet when the tail window gives nothing, and fail the probe
//! rather than fall back (docs/reports/task-83-mp4-tail-probe-flake).
//!
//! Needs ffprobe (the deps bundle in a debug build).
//! Run with: cargo test --test source_model_integration_test -- --nocapture

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

/// Runs per fixture, and how many at once.
const RUNS: usize = 24;
const AT_ONCE: usize = 8;

#[test]
fn an_edit_list_counts_its_decoded_pictures_under_load() {
    // small_clip.mp4: 3154 stored, 3 pre-roll discards (task #54).
    // edit_list_bframes.mp4: 146 stored, 125 kept, 128 grid slots.
    let cases = [("small_clip.mp4", 3151, 3154), ("edit_list_bframes.mp4", 128, 146)];
    let jobs: Vec<(&str, i64, i64)> = (0..RUNS).flat_map(|_| cases).collect();
    let mut failures = Vec::new();
    let mut retried = 0;
    for chunk in jobs.chunks(AT_ONCE) {
        let children: Vec<_> = chunk
            .iter()
            .map(|(name, want, stored)| {
                let child = Command::new(env!("CARGO_BIN_EXE_vapourbox-worker"))
                    .arg("--probe-source")
                    .arg(resource(name))
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::piped())
                    .spawn()
                    .unwrap();
                (child, *name, *want, *stored)
            })
            .collect();
        for (child, name, want, stored) in children {
            let out = child.wait_with_output().unwrap();
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            if stderr.contains("failed (attempt") {
                retried += 1;
                eprintln!("{name}: a probe was retried:\n{stderr}");
            }
            let model: Option<serde_json::Value> = serde_json::from_str(stdout.trim()).ok();
            let count = model.as_ref().and_then(|m| m["video"]["frameCount"].as_i64());
            let stored_seen = model.as_ref().and_then(|m| m["video"]["storedFrames"].as_i64());
            if !out.status.success() || count != Some(want) || stored_seen != Some(stored) {
                failures.push(format!(
                    "{name}: frameCount {count:?} (want {want}), storedFrames {stored_seen:?}, {}\nstdout: {stdout}\nstderr:\n{stderr}",
                    out.status
                ));
            }
        }
    }
    eprintln!("{} probes, {retried} with a retried ffprobe run", jobs.len());
    assert!(failures.is_empty(), "{} of {} probes wrong:\n{}", failures.len(), jobs.len(), failures.join("\n"));
}
