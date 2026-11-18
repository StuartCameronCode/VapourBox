//! vspipe under the worker's own environment loads every plugin once (task #61).
//!
//! On macOS and Linux R78 autoloads `<deps>/vapoursynth/plugins` (it is
//! `<libdir>/plugins`), so `DependencyLocator::build_environment` must not also
//! set `VAPOURSYNTH_EXTRA_PLUGIN_PATH` there: with both, each plugin loads twice
//! and vspipe's stderr starts with 35+ "Plugin … already loaded" warnings, which
//! buried real errors (task #56 F9). Windows sets the variable, for
//! `vs-plugins`, which is not the autoload directory; it must load once too.
//!
//! Run with: cargo test --test vspipe_environment_test -- --nocapture

use std::process::Command;

use vapourbox_worker::dependency_locator::DependencyLocator;

/// Namespaces every platform's bundle carries (the full list is
/// `app/test/vapoursynth_integration_test.dart`'s); proof the plugins still
/// load without the variable.
const EXPECTED: &[&str] = &["std", "resize", "mv", "fmtc", "znedi3", "misc"];

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
