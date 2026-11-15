//! DVD import (task #27): `--dvd-extract` on the committed multi-title fixture,
//! through the worker binary and libdvdread as the app runs it, checked by
//! decoding the result.
//!
//! The fixture (Tests/TestResources/generate_dvd_titles_test.sh) is one title
//! set with three titles; every chapter is its own VOB ID with its own colour:
//!
//!   title 1  red 50 frames
//!   title 2  grey 60 x25, grey 120 x50, grey 180 x25 (three chapters)
//!   title 3  blue 75 frames
//!
//! Before the fix every case extracted the whole title set: 225 frames.
//!
//! Needs libdvdread and ffmpeg/ffprobe (the deps bundle in a debug build;
//! every platform's bundle carries libdvdread). Skips, saying why, when the
//! worker can't find or load libdvdread.
//!
//! Run with: cargo test --test dvd_extract_integration_test -- --nocapture

use std::path::{Path, PathBuf};
use std::process::Command;

use vapourbox_worker::dependency_locator::DependencyLocator;

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("Tests")
        .join("TestResources")
        .join("dvd_titles")
}

fn worker() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vapourbox-worker"))
}

/// What a frame shows, from its mean colour.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Shade {
    Red,
    Blue,
    Grey(u8),
    Other,
}

fn classify(r: f64, g: f64, b: f64) -> Shade {
    if r > 150.0 && g < 90.0 && b < 90.0 {
        Shade::Red
    } else if b > 150.0 && r < 90.0 && g < 90.0 {
        Shade::Blue
    } else if (r - g).abs() < 12.0 && (g - b).abs() < 12.0 {
        match [60u8, 120, 180].into_iter().find(|&l| (g - l as f64).abs() < 15.0) {
            Some(l) => Shade::Grey(l),
            None => Shade::Other,
        }
    } else {
        Shade::Other
    }
}

/// Every decoded frame's shade, as runs: [(shade, count), ...].
fn runs(ffmpeg: &Path, file: &Path) -> Vec<(Shade, usize)> {
    let out = Command::new(ffmpeg)
        .args(["-v", "error", "-i"])
        .arg(file)
        .args(["-map", "0:v:0", "-vf", "scale=8:8,format=rgb24", "-f", "rawvideo", "-"])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let mut runs: Vec<(Shade, usize)> = Vec::new();
    for frame in out.stdout.chunks(8 * 8 * 3) {
        let mean = |c: usize| frame.iter().skip(c).step_by(3).map(|&v| v as f64).sum::<f64>() / 64.0;
        let shade = classify(mean(0), mean(1), mean(2));
        match runs.last_mut() {
            Some((s, n)) if *s == shade => *n += 1,
            _ => runs.push((shade, 1)),
        }
    }
    runs
}

/// Video timestamps of every decoded frame.
fn frame_times(ffprobe: &Path, file: &Path) -> Vec<f64> {
    let out = Command::new(ffprobe)
        .args(["-v", "error", "-select_streams", "v:0", "-show_entries", "frame=best_effort_timestamp_time", "-of", "csv=p=0"])
        .arg(file)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.trim().trim_end_matches(',').parse().ok())
        .collect()
}

enum Outcome {
    Extracted(PathBuf),
    Failed(String),
    /// libdvdread is missing or will not load, with the worker's reason.
    NoLibDvdRead(String),
}

fn extract(dir: &Path, name: &str, args: &[&str]) -> Outcome {
    let out = dir.join(format!("{name}.mpg"));
    let r = worker()
        .arg("--dvd-extract")
        .arg(fixture())
        .args(args)
        .arg("--output")
        .arg(&out)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&r.stdout).to_string();
    // Missing, or present but unloadable: the published macOS arm64 bundle's
    // libdvdread links Homebrew's libdvdcss by absolute path, so it loads
    // only where Homebrew has libdvdcss (a bundle bug, filed separately).
    if stdout.contains("libdvdread not found") || stdout.contains("Failed to load libdvdread") {
        return Outcome::NoLibDvdRead(stdout);
    }
    if r.status.success() {
        assert!(out.exists(), "{stdout}");
        assert!(!dir.join(format!("{name}.mpg.part")).exists(), "the .part is cleaned up");
        Outcome::Extracted(out)
    } else {
        Outcome::Failed(stdout)
    }
}

#[test]
fn each_title_and_chapter_range_is_extracted_alone() {
    assert!(fixture().join("VIDEO_TS").join("VIDEO_TS.IFO").exists(), "missing fixture {:?}", fixture());
    let deps = DependencyLocator::new().expect("locate dependencies");
    let ffmpeg = deps.ffmpeg_path().expect("locate ffmpeg");
    let ffprobe = deps.ffprobe_path().expect("locate ffprobe");

    let dir = std::env::temp_dir().join(format!("vb_dvd_extract_it_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();

    use Shade::*;
    let cases: [(&str, &[&str], &[(Shade, usize)]); 5] = [
        ("t1", &["--title", "1"], &[(Red, 50)]),
        ("t2", &["--title", "2"], &[(Grey(60), 25), (Grey(120), 50), (Grey(180), 25)]),
        ("t2_ch2-3", &["--title", "2", "--chapters", "2-3"], &[(Grey(120), 50), (Grey(180), 25)]),
        ("t2_ch2", &["--title", "2", "--chapters", "2"], &[(Grey(120), 50)]),
        ("t3", &["--title", "3"], &[(Blue, 75)]),
    ];

    for (name, args, expected) in cases {
        let file = match extract(&dir, name, args) {
            Outcome::Extracted(f) => f,
            Outcome::NoLibDvdRead(log) => {
                eprintln!("SKIP: the worker cannot load libdvdread: {log}");
                let _ = std::fs::remove_dir_all(&dir);
                return;
            }
            Outcome::Failed(log) => panic!("{name}: extraction failed: {log}"),
        };

        let got = runs(&ffmpeg, &file);
        assert_eq!(got, expected, "{name}: pictures");

        // One continuous timeline (task #21's join ran on the chapters' VOB
        // IDs), as long as its pictures.
        let frames: usize = expected.iter().map(|(_, n)| n).sum();
        // The muxer leaves the last picture of the PS without a timestamp
        // (task #26), so that one may be missing.
        let times = frame_times(&ffprobe, &file);
        assert!(times.len() == frames || times.len() == frames - 1, "{name}: {} timestamps for {frames} frames", times.len());
        let span = (times[times.len() - 1] - times[0]) * 25.0 + 1.0;
        assert!((span - times.len() as f64).abs() < 0.5, "{name}: {} timestamps span {span} frames", times.len());
        assert!(times.windows(2).all(|w| w[1] > w[0]), "{name}: timestamps go back");
    }

    // A chapter the title lacks is refused, with the count.
    match extract(&dir, "t2_ch2-5", &["--title", "2", "--chapters", "2-5"]) {
        Outcome::Failed(log) => assert!(log.contains("the title has 3 chapters; asked for 2-5"), "{log}"),
        _ => panic!("chapters 2-5 of a 3-chapter title must fail"),
    }
    assert!(!dir.join("t2_ch2-5.mpg").exists());
    // As is a title the disc doesn't have, and a malformed range.
    assert!(matches!(extract(&dir, "t4", &["--title", "4"]), Outcome::Failed(_)));
    let r = worker()
        .args(["--dvd-extract"])
        .arg(fixture())
        .args(["--title", "2", "--chapters", "2-x", "--output"])
        .arg(dir.join("bad.mpg"))
        .output()
        .unwrap();
    assert!(!r.status.success());
    assert!(String::from_utf8_lossy(&r.stderr).contains("--chapters"), "{}", String::from_utf8_lossy(&r.stderr));

    let _ = std::fs::remove_dir_all(&dir);
}
