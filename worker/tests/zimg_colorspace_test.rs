//! Every colour space the script's YUV <-> RGB conversions can name converts
//! in the bundled VapourSynth (task #88).
//!
//! `ColorMetadata::zimg_colorspace` decides what Borders, RIFE, AI upscaling,
//! Face Restoration and Colourisation pass to zimg. zimg refuses `2020cl`,
//! `chromancl`, `chromacl` and `ictcp` from the matrix alone ("Resize error
//! 3074"), which failed every such job. A unit test can only read the
//! decision; this one runs it. Every recognised matrix x primaries x
//! transfer tag (and untagged), at SD and HD height, is reduced to the
//! distinct colour spaces it gives, and each goes through one vspipe run,
//! with the argument text the template receives:
//!
//! 1. an RGB swatch to YUV, as `_border_color` does, at every output format
//!    a pass can hand it (4:2:0 / 4:2:2 / 4:4:4, 8 to 16 bits);
//! 2. gamut-legal content (random RGB through the same conversion) to RGBS
//!    and back, as RIFE and the AI upscale do, within 1 code (a quarter of
//!    an 8-bit level at 16 bits);
//! 3. black and white bars equal to the BT.709 reading's (every reading's),
//!    and grey too for every reading but ICtCp (NCL keeps it exactly);
//! 4. `ai_runtime.to_rgbs` / `from_rgbs` with the literal Face Restoration
//!    and Colourisation receive.
//!
//! See docs/reports/task-88-zimg-colour-tags.
//! Run with: cargo test --test zimg_colorspace_test -- --nocapture

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

use vapourbox_worker::dependency_locator::DependencyLocator;
use vapourbox_worker::models::{recognised_tags, ColorMetadata, ZimgColorspace};

fn colourspaces() -> Vec<(ZimgColorspace, String)> {
    let (matrices, primaries, transfers) = recognised_tags();
    let opt = |v: &'static [&'static str]| -> Vec<Option<&'static str>> {
        v.iter().map(|x| Some(*x)).chain([None]).collect()
    };
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for m in opt(matrices) {
        for p in opt(primaries) {
            for t in opt(transfers) {
                for h in [480, 1080] {
                    let cs = ColorMetadata::from_raw(m, p, t, None).zimg_colorspace(Some(h));
                    if seen.insert(format!("{cs:?}")) {
                        out.push((cs, format!("{m:?}/{p:?}/{t:?}@{h}")));
                    }
                }
            }
        }
    }
    out
}

const PRELUDE: &str = r#"
import sys, random
import vapoursynth as vs
core = vs.core
sys.path.insert(0, TEMPLATES)
import ai_runtime

FORMATS = [vs.YUV420P8, vs.YUV420P10, vs.YUV422P10, vs.YUV444P16]
W, H = 96, 64

def first(clip):
    f = clip.get_frame(0)
    return [f[p][0, 0] for p in range(clip.format.num_planes)]

def swatch(col, w=4, h=4):
    return core.std.BlankClip(width=w, height=h, format=vs.RGB24, color=col, length=1)

def content():
    rnd = random.Random(7)
    c = core.std.BlankClip(width=W, height=H, format=vs.RGB24, length=1)
    def fill(n, f):
        fo = f.copy()
        for p in range(3):
            a = fo[p]
            for y in range(H):
                for x in range(W):
                    a[y, x] = rnd.randint(0, 255)
        return fo
    # Cached once, so every read sees the same pixels.
    return core.std.ModifyFrame(c, c, fill)

CONTENT = content()

def tolerance(fmt):
    # One code up to 10 bits; a quarter of an 8-bit level deeper (float32
    # through PQ moves a 16-bit sample by up to ~34 codes, 0.13 levels).
    bits = core.get_video_format(fmt).bits_per_sample
    return max(1, (1 << (bits - 8)) // 4)

def max_diff(a, b):
    fa, fb = a.get_frame(0), b.get_frame(0)
    m = 0
    for p in range(a.format.num_planes):
        pa, pb = fa[p], fb[p]
        for y in range(a.height):
            for x in range(a.width):
                m = max(m, abs(pa[y, x] - pb[y, x]))
    return m

def reference(col, fmt):
    return first(core.resize.Point(swatch(col), format=fmt, matrix_s="709", range_s="limited"))

failures = []
def check(name, ok, detail=""):
    if not ok:
        failures.append(f"{name}: {detail}")
"#;

fn case_code(i: usize, cs: &ZimgColorspace, from: &str) -> String {
    let to_yuv = cs.to_yuv_args();
    let from_yuv = cs.from_yuv_args();
    let literal = cs.py_literal();
    let keeps_grey = cs.matrix != "ictcp";
    format!(
        r#"
def case_{i}():
    name = {name:?}
    try:
        for fmt in FORMATS:
            # 1 + 3: the border swatch
            for col in ([0, 0, 0], [255, 255, 255], [128, 128, 128], [200, 40, 90]):
                got = first(core.resize.Point(swatch(col), format=fmt, {to_yuv}, range_s="limited"))
                if col != [200, 40, 90] and (col != [128, 128, 128] or {keeps_grey}):
                    check(name, got == reference(col, fmt), f"{{col}} -> {{got}}, 709 gives {{reference(col, fmt)}} ({{fmt}})")
            # 2: the RIFE / AI upscale round trip
            yuv = core.resize.Point(CONTENT, format=fmt, {to_yuv}, range_s="limited")
            yuv = core.std.RemoveFrameProps(yuv, props=["_Matrix", "_Transfer", "_Primaries", "_Range", "_ColorRange"])
            rgb = core.resize.Bicubic(yuv, format=vs.RGBS, {from_yuv}, range_in_s="limited")
            back = core.resize.Bicubic(rgb, format=fmt, {to_yuv}, range_s="limited", dither_type="none")
            if core.get_video_format(fmt).subsampling_w == 0:
                d = max_diff(yuv, back)
                check(name, d <= tolerance(fmt), f"round trip off by {{d}} codes ({{fmt}})")
            else:
                back.get_frame(0)
            # 4: Face Restoration / Colourisation's helpers
            vf = core.get_video_format(fmt)
            again = ai_runtime.from_rgbs(ai_runtime.to_rgbs(yuv, {literal}, "limited"), vf, {literal}, "limited")
            if vf.subsampling_w == 0:
                d = max_diff(yuv, again)
                check(name, d <= tolerance(fmt), f"ai_runtime round trip off by {{d}} codes ({{fmt}})")
            # Colourisation's float RGB -> YUV444PS -> source format
            ps = core.resize.Bilinear(core.resize.Point(CONTENT, format=vs.RGBS), format=vs.YUV444PS,
                                      matrix_in_s="rgb", **ai_runtime.zimg_args({literal}, "out"))
            core.resize.Bicubic(ps, format=fmt, range_s="limited", dither_type="error_diffusion",
                                **ai_runtime.zimg_args({literal}, "both")).get_frame(0)
    except vs.Error as e:
        check(name, False, str(e))
    print("CASE " + name, file=sys.stderr)
case_{i}()
"#,
        name = format!("{} (from {from})", to_yuv),
        keeps_grey = if keeps_grey { "True" } else { "False" },
    )
}

#[test]
fn every_zimg_colourspace_converts_in_the_bundle() {
    let cases = colourspaces();
    // The four that need more than a matrix are all reached.
    for m in ["chromancl", "ictcp"] {
        assert!(cases.iter().any(|(c, _)| c.matrix == m), "{m} not reached");
    }

    let templates = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("templates");
    let mut script = format!("TEMPLATES = {:?}\n", templates.to_string_lossy());
    script.push_str(PRELUDE);
    for (i, (cs, from)) in cases.iter().enumerate() {
        script.push_str(&case_code(i, cs, from));
    }
    script.push_str(
        "print('FAILURES %d' % len(failures), file=sys.stderr)\n\
         for f in failures:\n    print('FAIL ' + f, file=sys.stderr)\n\
         core.std.BlankClip(length=1).set_output()\n",
    );

    let deps = DependencyLocator::new().expect("locate dependencies");
    let vspipe = deps.vspipe_path().expect("locate vspipe");
    let path = std::env::temp_dir().join(format!("vapourbox_zimg_cs_{}.vpy", std::process::id()));
    std::fs::write(&path, &script).expect("write script");
    let out = Command::new(&vspipe)
        .args(["-i", path.to_str().unwrap(), "-"])
        .envs(&deps.build_environment())
        .output()
        .expect("run vspipe");
    let _ = std::fs::remove_file(&path);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "vspipe failed ({}):\n{stderr}", out.status);

    let ran = stderr.lines().filter(|l| l.starts_with("CASE ")).count();
    assert_eq!(ran, cases.len(), "not every case ran:\n{stderr}");
    let failures: Vec<&str> = stderr.lines().filter(|l| l.starts_with("FAIL ")).collect();
    assert!(
        failures.is_empty(),
        "{} of {} colour spaces failed:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
    println!("{} colour spaces convert", cases.len());
}
