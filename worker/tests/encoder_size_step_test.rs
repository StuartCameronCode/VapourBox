//! `VideoCodec::size_step` against the bundled FFmpeg (task #97).
//!
//! A picture off its chroma grid (a 63x33 4:2:0 source, stored by VP9, AV1,
//! MJPEG, FFV1, ProRes and others) is padded onto the grid for VapourSynth,
//! and the encoder's `crop` takes it back to the size the encoder can store:
//! `VideoJob::grid_output`, which reads `size_step`. This encodes each
//! software encoder at 63x33, 63x32, 64x33 and 64x32 in each format the
//! worker can hand it (through `forced_pix_fmt`, as a job does) and checks
//! that a size the table allows is stored exactly that size, and one it
//! refuses is refused by the encoder. Hardware encoders can't run here; the
//! table holds them to even sizes (VideoToolbox, the one that can, takes an
//! odd size and silently drops a row and column).
//! See docs/reports/task-97-off-grid-sources.
//! Run with: cargo test --test encoder_size_step_test -- --nocapture

use std::process::Command;

use vapourbox_worker::dependency_locator::DependencyLocator;
use vapourbox_worker::models::VideoCodec;

#[test]
fn every_software_encoder_stores_exactly_the_sizes_its_step_allows() {
    let deps = DependencyLocator::new().expect("locate dependencies");
    let ffmpeg = deps.ffmpeg_path().expect("locate ffmpeg");
    let ffprobe = deps.ffprobe_path().expect("locate ffprobe");
    let env = deps.build_environment();
    let dir = std::env::temp_dir().join(format!("vapourbox_size_step_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();

    let codecs = [
        VideoCodec::H264,
        VideoCodec::H265,
        VideoCodec::Av1,
        VideoCodec::FFV1,
        VideoCodec::Huffyuv,
        VideoCodec::Ffvhuff,
        VideoCodec::ProRes422,
        VideoCodec::ProRes4444,
        VideoCodec::V210,
    ];
    let mut failures = Vec::new();
    for codec in codecs {
        for input in ["yuv420p", "yuv422p10le", "yuv444p"] {
            let fmt = codec.forced_pix_fmt(input).unwrap_or(input);
            let (sx, sy) = codec.size_step(fmt);
            for (w, h) in [(63, 33), (63, 32), (64, 33), (64, 32)] {
                let allowed = w % sx == 0 && h % sy == 0;
                let out = dir.join(format!("{}_{fmt}_{w}x{h}.mkv", codec.ffmpeg_codec()));
                let mut args: Vec<String> = [
                    "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=128x96:r=25:d=0.08",
                    "-vf",
                ]
                .iter()
                .map(|s| s.to_string())
                .collect();
                args.push(format!("scale={w}:{h},format={fmt}"));
                args.extend(["-c:v".to_string(), codec.ffmpeg_codec().to_string()]);
                if let Some(p) = codec.prores_profile() {
                    args.extend(["-profile:v".to_string(), p.to_string()]);
                }
                args.extend(["-pix_fmt".to_string(), fmt.to_string()]);
                args.push(out.to_string_lossy().to_string());
                let run = Command::new(&ffmpeg).args(&args).envs(&env).output().expect("run ffmpeg");
                let stored = if run.status.success() {
                    let probe = Command::new(&ffprobe)
                        .args(["-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0"])
                        .arg(&out)
                        .envs(&env)
                        .output()
                        .expect("run ffprobe");
                    Some(String::from_utf8_lossy(&probe.stdout).trim().to_string())
                } else {
                    None
                };
                let case = format!("{codec:?} {fmt} {w}x{h} (step {sx}x{sy})");
                match (allowed, stored) {
                    (true, Some(s)) if s == format!("{w},{h}") => {}
                    (true, s) => failures.push(format!(
                        "{case}: allowed, but stored {s:?}: {}",
                        String::from_utf8_lossy(&run.stderr).lines().next().unwrap_or("")
                    )),
                    (false, None) => {}
                    (false, Some(s)) => failures.push(format!(
                        "{case}: the step refuses it but the encoder stored {s}: the table is stricter than measured"
                    )),
                }
            }
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
