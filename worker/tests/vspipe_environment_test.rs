//! vspipe under the worker's own environment loads every plugin once (task #61).
//!
//! On macOS and Linux R78 autoloads `<deps>/vapoursynth/plugins` (it is
//! `<libdir>/plugins`), so `DependencyLocator::build_environment` must not also
//! set `VAPOURSYNTH_EXTRA_PLUGIN_PATH` there: with both, each plugin loads twice
//! and vspipe's stderr starts with 35+ "Plugin … already loaded" warnings, which
//! buried real errors (task #56 F9). Windows sets the variable, for
//! `vs-plugins`, which is not the autoload directory; it must load once too.
//!
//! Every plugin must also load at all (task #116). deps-v1.18.0-rc3's Windows
//! bundle shipped DCTFilter, DFTTest and FFT3DFilter without their FFTW DLL in
//! `vs-plugins`; vspipe printed "Failed to load … GetLastError() returned 126"
//! for each, and this test, which only looked for duplicates, passed.
//!
//! Run with: cargo test --test vspipe_environment_test -- --nocapture

use std::process::Command;

use vapourbox_worker::dependency_locator::DependencyLocator;

/// Namespaces every platform's bundle carries (the full list is
/// `app/test/vapoursynth_integration_test.dart`'s); proof the plugins still
/// load without the variable.
/// `dctf`, `dfttest` and `fft3dfilter` are the FFTW plugins (task #116).
const EXPECTED: &[&str] = &[
    "std", "resize", "mv", "fmtc", "znedi3", "misc", "dctf", "dfttest", "fft3dfilter",
];

#[test]
fn vspipe_loads_each_plugin_once() {
    let deps = DependencyLocator::new().expect("locate dependencies");
    let vspipe = deps.vspipe_path().expect("locate vspipe");
    let env = deps.build_environment();

    let script = std::env::temp_dir()
        .join(format!("vapourbox_vspipe_env_{}.vpy", std::process::id()));
    std::fs::write(
        &script,
        "import sys\n\
         import vapoursynth as vs\n\
         core = vs.core\n\
         core.std.BlankClip(length=1).set_output()\n\
         print('NAMESPACES ' + ' '.join(sorted(p.namespace for p in core.plugins())), file=sys.stderr)\n",
    )
    .expect("write script");

    let out = Command::new(&vspipe)
        .args(["-i", script.to_str().unwrap(), "-"])
        .envs(&env)
        .output()
        .expect("run vspipe");
    let _ = std::fs::remove_file(&script);
    let stderr = String::from_utf8_lossy(&out.stderr);

    assert!(out.status.success(), "vspipe -i failed ({}):\n{stderr}", out.status);

    let duplicates: Vec<&str> = stderr.lines().filter(|l| l.contains("already loaded")).collect();
    assert!(
        duplicates.is_empty(),
        "{} plugin(s) loaded twice under build_environment() \
         (VAPOURSYNTH_EXTRA_PLUGIN_PATH = {:?}):\n{}",
        duplicates.len(),
        env.get("VAPOURSYNTH_EXTRA_PLUGIN_PATH"),
        duplicates.join("\n")
    );

    let load_failures: Vec<&str> = stderr.lines().filter(|l| l.contains("Failed to load")).collect();
    assert!(
        load_failures.is_empty(),
        "{} plugin(s) failed to load under build_environment() \
         (a DLL they import is probably not beside them, task #116):\n{}",
        load_failures.len(),
        load_failures.join("\n")
    );

    let namespaces: Vec<&str> = stderr
        .lines()
        .find_map(|l| l.strip_prefix("NAMESPACES "))
        .unwrap_or_else(|| panic!("script printed no namespaces:\n{stderr}"))
        .split_whitespace()
        .collect();
    for ns in EXPECTED {
        assert!(namespaces.contains(ns), "plugin namespace '{ns}' not loaded: {namespaces:?}");
    }
}
