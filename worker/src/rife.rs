//! RIFE frame interpolation: where its files live, and whether it can run here.
//!
//! RIFE (`rife.RIFE`, ncnn on Vulkan) is the one Frame Rate method that needs
//! more than the deps bundle: a GPU with a working Vulkan driver, and on Windows
//! the MSVC OpenMP runtime. Without a Vulkan implementation the plugin does not
//! raise — it segfaults inside `ncnn::create_gpu_instance` — so a job cannot be
//! allowed to find out by trying. Instead this module runs the plugin once in a
//! throwaway vspipe, records how far it got, and turns the outcome into a reason
//! with a remedy the user can act on. The app shows that message the moment
//! RIFE is selected (`--probe-rife`), and the worker refuses a RIFE job with the
//! same message rather than emitting a script that would crash.
//!
//! The plugin lives in `vapoursynth/rife/`, outside the autoload directory, and
//! the script loads it explicitly — so nothing about it (a missing runtime DLL,
//! a driver that faults on load, AVX in a static initializer) can reach a job
//! that did not ask for RIFE.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The bundled model: RIFE 4.26, ncnn conversion, ensemble off.
pub const MODEL_DIR_NAME: &str = "rife-v4.26_ensembleFalse";

/// Marker the probe script prints to stderr as it passes each stage, so a
/// process that died without a message still says where it died.
const STAGE_MARKER: &str = "RIFE_PROBE:";

/// How long the probe may take. GPU initialisation and the first shader
/// compile take a second or two; a driver that hangs must not hang the app.
const PROBE_TIMEOUT: Duration = Duration::from_secs(60);

/// Whether the deps bundle for this platform ships RIFE at all.
///
/// macOS x64 is excluded because the only prebuilt dylib targets macOS 13
/// (the bundle's floor is 12) and runs AVX in a static initializer; linux-arm64
/// because upstream publishes no build. Both need a source build first.
pub fn platform_ships_rife(platform_suffix: &str) -> bool {
    matches!(platform_suffix, "macos-arm64" | "windows-x64" | "linux-x64")
}

/// The files RIFE needs, as laid out under `deps/<platform>/vapoursynth/rife/`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RifeFiles {
    pub plugin: PathBuf,
    pub model_dir: PathBuf,
    /// A library to load into the process before the plugin: MoltenVK on
    /// macOS, where the plugin resolves Vulkan from whatever is already loaded.
    pub preload: Option<PathBuf>,
}

impl RifeFiles {
    pub fn in_vapoursynth_dir(vs_dir: &Path, platform_suffix: &str) -> Self {
        let dir = vs_dir.join("rife");
        let (plugin, preload) = if platform_suffix.starts_with("macos") {
            ("librife.dylib", Some(dir.join("libMoltenVK.dylib")))
        } else if platform_suffix.starts_with("windows") {
            ("librife.dll", None)
        } else {
            ("librife.so", None)
        };
        Self {
            plugin: dir.join(plugin),
            model_dir: dir.join("models").join(MODEL_DIR_NAME),
            preload,
        }
    }

    /// Every file that must exist, in the order a user would want to hear
    /// about them.
    pub fn required(&self) -> Vec<PathBuf> {
        let mut files = vec![self.plugin.clone()];
        files.extend(self.preload.iter().cloned());
        files.push(self.model_dir.join("flownet.param"));
        files.push(self.model_dir.join("flownet.bin"));
        files
    }

    pub fn missing(&self) -> Vec<PathBuf> {
        self.required().into_iter().filter(|p| !p.is_file()).collect()
    }
}

/// Why RIFE cannot run here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RifeReason {
    /// No build of RIFE ships for this platform.
    UnsupportedPlatform,
    /// The installed deps bundle predates RIFE, or is missing its files.
    NotInstalled,
    /// No usable Vulkan device or driver.
    NoVulkan,
    /// A system library the plugin links against is not installed.
    MissingLibrary,
    /// The plugin would not load, for a reason the probe could not narrow.
    LoadFailed,
    /// The probe process crashed after the GPU was initialised.
    Crashed,
    /// The plugin used an instruction this CPU does not have (SIGILL, or
    /// Windows' 0xC000001D) — an x86 machine older than its build target.
    UnsupportedCpu,
    /// `VAPOURBOX_DISABLE_VULKAN` is set.
    Disabled,
    /// The probe itself could not be run or did not finish.
    ProbeFailed,
}

/// Whether RIFE runs here, and if not, why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RifeStatus {
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<RifeReason>,
    /// The specific thing that failed (a missing file, a library name, the
    /// error text), shown under the remedy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl RifeStatus {
    pub fn available() -> Self {
        Self { available: true, reason: None, detail: None }
    }

    pub fn unavailable(reason: RifeReason, detail: impl Into<Option<String>>) -> Self {
        Self { available: false, reason: Some(reason), detail: detail.into() }
    }

    /// What to tell the user: what is wrong and what to do about it. `None`
    /// when RIFE is available. The app shows this verbatim and the worker
    /// fails a RIFE job with it, so there is one wording, written here.
    pub fn message(&self, platform_suffix: &str) -> Option<String> {
        let reason = self.reason?;
        let os = platform_suffix.split('-').next().unwrap_or("");
        let text = match reason {
            RifeReason::UnsupportedPlatform => {
                let which = match platform_suffix {
                    "macos-x64" => "Intel Macs",
                    "linux-arm64" => "Linux on ARM",
                    "windows-arm64" => "Windows on ARM",
                    _ => "this platform",
                };
                format!(
                    "RIFE isn't available for {which} yet: no build of it ships with \
                     VapourBox for this platform. Use Motion interpolation instead."
                )
            }
            RifeReason::NotInstalled => "RIFE's files aren't in the installed dependency \
                 bundle, which is probably older than this version of VapourBox. Restart \
                 VapourBox to let it download the current dependencies."
                .to_string(),
            RifeReason::NoVulkan => match os {
                "windows" => "RIFE needs a graphics card with Vulkan support, and none was \
                     found. Install or update the driver from your GPU's maker (NVIDIA, AMD \
                     or Intel) — Vulkan support comes with it — then restart VapourBox. \
                     Remote desktop sessions and virtual machines usually have no Vulkan \
                     device."
                    .to_string(),
                "linux" => "RIFE needs a graphics card with a Vulkan driver, and none was \
                     found. Install your distribution's Vulkan driver and loader (for \
                     example mesa-vulkan-drivers and libvulkan1 on Debian/Ubuntu, or \
                     mesa-vulkan-drivers and vulkan-loader on Fedora; NVIDIA's own driver \
                     includes Vulkan), then restart VapourBox."
                    .to_string(),
                _ => "RIFE could not open the GPU through Metal. This happens in virtual \
                     machines and some remote sessions; on a normal login it should work, \
                     so try restarting VapourBox."
                    .to_string(),
            },
            RifeReason::MissingLibrary => match os {
                "windows" => "RIFE needs the Microsoft Visual C++ Redistributable (x64), \
                     which isn't installed. Install the latest version from Microsoft \
                     (search for \"Visual C++ Redistributable latest supported downloads\"), \
                     then restart VapourBox."
                    .to_string(),
                _ => "RIFE needs a system library that isn't installed. Install it with \
                     your package manager (libgomp is in the libgomp1 or libgomp package), \
                     then restart VapourBox."
                    .to_string(),
            },
            RifeReason::LoadFailed => "RIFE's plugin failed to load on this computer. \
                 Restart VapourBox to re-check its dependencies; if this persists, please \
                 report it with the details below."
                .to_string(),
            RifeReason::Crashed => "RIFE crashed while testing the GPU. Updating your \
                 graphics driver usually fixes this; restart VapourBox afterwards."
                .to_string(),
            RifeReason::UnsupportedCpu => "RIFE's plugin needs a newer processor than \
                 this computer has (it uses instructions this CPU lacks). Use Motion \
                 interpolation instead."
                .to_string(),
            RifeReason::Disabled => "RIFE is turned off by the VAPOURBOX_DISABLE_VULKAN \
                 environment variable."
                .to_string(),
            RifeReason::ProbeFailed => "VapourBox couldn't check whether RIFE runs on this \
                 computer. Restart VapourBox to try again."
                .to_string(),
        };
        Some(match &self.detail {
            Some(d) if !d.is_empty() => format!("{text}\n\nDetails: {d}"),
            _ => text,
        })
    }

    /// The probe result as the JSON `--probe-rife` prints, message included.
    pub fn to_json(&self, platform_suffix: &str) -> serde_json::Value {
        let mut v = serde_json::to_value(self).unwrap_or_default();
        if let (Some(msg), Some(obj)) = (self.message(platform_suffix), v.as_object_mut()) {
            obj.insert("message".into(), serde_json::Value::String(msg));
        }
        v
    }
}

/// Everything the platform and file checks can decide without running
/// anything. `None` means "it should work — run the probe".
pub fn precheck(platform_suffix: &str, files: &RifeFiles) -> Option<RifeStatus> {
    if !platform_ships_rife(platform_suffix) {
        return Some(RifeStatus::unavailable(RifeReason::UnsupportedPlatform, None));
    }
    let missing = files.missing();
    if !missing.is_empty() {
        let list = missing.iter().map(|p| p.display().to_string()).collect::<Vec<_>>();
        return Some(RifeStatus::unavailable(
            RifeReason::NotInstalled,
            format!("missing {}", list.join(", ")),
        ));
    }
    None
}

/// A Python string literal for a path, for substitution into a script.
pub fn py_str(path: &Path) -> String {
    let s = path.to_string_lossy();
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\'' => out.push_str("\\'"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c => out.push(c),
        }
    }
    out.push('\'');
    out
}

/// The probe: load the plugin, create the GPU instance, and render one
/// interpolated frame — the three places it has been seen to fail.
pub fn probe_script(files: &RifeFiles, platform_suffix: &str) -> String {
    // Shared libraries whose absence makes the plugin fail to load with only a
    // generic "module not found". Checked first so the user is told which one.
    let runtime_libs: &[&str] = if platform_suffix.starts_with("windows") {
        &["vcomp140.dll", "msvcp140.dll", "msvcp140_atomic_wait.dll", "vcruntime140.dll", "vcruntime140_1.dll"]
    } else if platform_suffix.starts_with("linux") {
        &["libgomp.so.1"]
    } else {
        &[]
    };
    let libs = runtime_libs.iter().map(|l| format!("'{l}'")).collect::<Vec<_>>().join(", ");
    let preload = files.preload.as_deref().map(py_str).unwrap_or_else(|| "None".into());
    format!(
        "import sys, ctypes\n\
         def stage(s):\n    print('{marker}' + s, file=sys.stderr, flush=True)\n\
         for lib in [{libs}]:\n    try:\n        ctypes.CDLL(lib)\n    except OSError:\n        stage('missing:' + lib)\n\
         stage('preload')\n\
         if {preload}:\n    ctypes.CDLL({preload}, mode=ctypes.RTLD_GLOBAL)\n\
         import vapoursynth as vs\n\
         core = vs.core\n\
         stage('load')\n\
         if not hasattr(core, 'rife'):\n    core.std.LoadPlugin({plugin})\n\
         stage('init')\n\
         clip = core.std.BlankClip(width=64, height=64, format=vs.RGBS, length=2, fpsnum=25, fpsden=1)\n\
         clip = core.rife.RIFE(clip, model_path={model}, fps_num=50, fps_den=1)\n\
         stage('render')\n\
         clip.set_output()\n",
        marker = STAGE_MARKER,
        plugin = py_str(&files.plugin),
        model = py_str(&files.model_dir),
    )
}

/// How the probe process ended.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProbeExit {
    pub success: bool,
    pub timed_out: bool,
    /// Human-readable exit status for a failure (`signal 11 (SIGSEGV)` …).
    pub status: String,
}

/// Turn a finished probe into a status. Pure, so every branch is testable.
pub fn classify(exit: &ProbeExit, stderr: &str) -> RifeStatus {
    if exit.success {
        return RifeStatus::available();
    }
    if exit.timed_out {
        return RifeStatus::unavailable(
            RifeReason::ProbeFailed,
            format!("the GPU test did not finish within {}s", PROBE_TIMEOUT.as_secs()),
        );
    }

    let stages: Vec<&str> = stderr
        .lines()
        .filter_map(|l| l.trim().strip_prefix(STAGE_MARKER))
        .collect();
    let missing: Vec<&str> = stages.iter().filter_map(|s| s.strip_prefix("missing:")).collect();
    let last = stages.iter().rev().find(|s| !s.starts_with("missing:")).copied();
    let error = last_error_line(stderr);

    // An illegal instruction is the CPU, wherever it happened.
    if exit.status.starts_with("signal 4 ") || exit.status.contains("illegal instruction") {
        return RifeStatus::unavailable(RifeReason::UnsupportedCpu, exit.status.clone());
    }

    if stderr.contains("failed to create GPU instance") || stderr.contains("invalid GPU device") {
        return RifeStatus::unavailable(RifeReason::NoVulkan, error);
    }
    if stderr.contains("failed to load model") {
        return RifeStatus::unavailable(RifeReason::NotInstalled, error);
    }
    match last {
        // The plugin would not load. A runtime library the pre-check could not
        // open is the likeliest cause, and the one the user can fix.
        Some("load") if !missing.is_empty() => RifeStatus::unavailable(
            RifeReason::MissingLibrary,
            format!("could not load {}", missing.join(", ")),
        ),
        Some("load") | Some("preload") => RifeStatus::unavailable(
            RifeReason::LoadFailed,
            error.or_else(|| Some(format!("vspipe exited with {}", exit.status))),
        ),
        // Died creating the GPU instance without an error: no Vulkan loader or
        // driver for ncnn to call into.
        Some("init") => RifeStatus::unavailable(
            RifeReason::NoVulkan,
            error.or_else(|| Some(format!("the GPU could not be initialised ({})", exit.status))),
        ),
        Some("render") => RifeStatus::unavailable(
            RifeReason::Crashed,
            error.or_else(|| Some(format!("vspipe exited with {}", exit.status))),
        ),
        _ => RifeStatus::unavailable(
            RifeReason::ProbeFailed,
            error.or_else(|| Some(format!("vspipe exited with {}", exit.status))),
        ),
    }
}

/// The last line of a Python/VapourSynth error, which names the actual failure.
fn last_error_line(stderr: &str) -> Option<String> {
    stderr
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with(STAGE_MARKER) && !l.starts_with('['))
        .filter(|l| l.contains("Error") || l.contains("error") || l.contains("Failed"))
        .last()
        .map(|l| l.chars().take(400).collect())
}

/// Run the probe script through vspipe and classify the result.
pub fn run_probe(
    vspipe: &Path,
    env: &HashMap<String, String>,
    files: &RifeFiles,
    platform_suffix: &str,
) -> RifeStatus {
    let script = probe_script(files, platform_suffix);
    let tmp = std::env::temp_dir().join(format!("vapourbox_rife_probe_{}.vpy", std::process::id()));
    if let Err(e) = std::fs::write(&tmp, script) {
        return RifeStatus::unavailable(RifeReason::ProbeFailed, format!("could not write the probe script: {e}"));
    }
    let exit_and_stderr = run_with_timeout(vspipe, &tmp, env);
    let _ = std::fs::remove_file(&tmp);
    match exit_and_stderr {
        Ok((exit, stderr)) => classify(&exit, &stderr),
        Err(e) => RifeStatus::unavailable(RifeReason::ProbeFailed, format!("could not run vspipe: {e}")),
    }
}

fn run_with_timeout(
    vspipe: &Path,
    script: &Path,
    env: &HashMap<String, String>,
) -> std::io::Result<(ProbeExit, String)> {
    // Frame 1 of 2x output is the first interpolated one; frame 0 is a copy
    // and would never touch the GPU.
    let mut child = Command::new(vspipe)
        .args(["-s", "1", "-e", "1"])
        .arg(script)
        .arg("-")
        .envs(env)
        .env("MVK_CONFIG_LOG_LEVEL", "0")
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stderr = child.stderr.take();
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(e) = stderr.as_mut() {
            let _ = e.read_to_string(&mut s);
        }
        s
    });
    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break Some(status);
        }
        if start.elapsed() > PROBE_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let stderr = reader.join().unwrap_or_default();
    let exit = match status {
        Some(s) => ProbeExit {
            success: s.success(),
            timed_out: false,
            status: crate::pipeline_executor::format_exit_status(&s),
        },
        None => ProbeExit { success: false, timed_out: true, status: "timed out".into() },
    };
    Ok((exit, stderr))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn failed(status: &str) -> ProbeExit {
        ProbeExit { success: false, timed_out: false, status: status.into() }
    }

    #[test]
    fn layout_per_platform() {
        let mac = RifeFiles::in_vapoursynth_dir(Path::new("/d/vapoursynth"), "macos-arm64");
        assert_eq!(mac.plugin, Path::new("/d/vapoursynth/rife/librife.dylib"));
        assert_eq!(mac.preload.as_deref(), Some(Path::new("/d/vapoursynth/rife/libMoltenVK.dylib")));
        assert!(mac.model_dir.ends_with("rife/models/rife-v4.26_ensembleFalse"));
        let win = RifeFiles::in_vapoursynth_dir(Path::new("D:/v"), "windows-x64");
        assert!(win.plugin.ends_with("rife/librife.dll"));
        assert_eq!(win.preload, None);
        let linux = RifeFiles::in_vapoursynth_dir(Path::new("/v"), "linux-x64");
        assert!(linux.plugin.ends_with("rife/librife.so"));
        // MoltenVK is required on macOS, and only there.
        assert_eq!(mac.required().len(), 4);
        assert_eq!(linux.required().len(), 3);
    }

    #[test]
    fn unsupported_platforms_are_reported_before_anything_runs() {
        let files = RifeFiles::in_vapoursynth_dir(Path::new("/nonexistent"), "macos-x64");
        for p in ["macos-x64", "linux-arm64", "windows-arm64"] {
            let s = precheck(p, &files).expect("must decide without probing");
            assert_eq!(s.reason, Some(RifeReason::UnsupportedPlatform), "{p}");
        }
        // A shipping platform with no files is "not installed", not unsupported.
        let files = RifeFiles::in_vapoursynth_dir(Path::new("/nonexistent"), "linux-x64");
        let s = precheck("linux-x64", &files).unwrap();
        assert_eq!(s.reason, Some(RifeReason::NotInstalled));
        assert!(s.detail.unwrap().contains("librife.so"));
    }

    #[test]
    fn every_reason_has_a_message_on_every_platform() {
        let reasons = [
            RifeReason::UnsupportedPlatform,
            RifeReason::NotInstalled,
            RifeReason::NoVulkan,
            RifeReason::MissingLibrary,
            RifeReason::LoadFailed,
            RifeReason::Crashed,
            RifeReason::UnsupportedCpu,
            RifeReason::Disabled,
            RifeReason::ProbeFailed,
        ];
        for platform in ["macos-arm64", "macos-x64", "windows-x64", "linux-x64", "linux-arm64"] {
            for r in reasons {
                let m = RifeStatus::unavailable(r, None).message(platform).unwrap();
                assert!(m.len() > 40, "{platform} {r:?}: {m}");
            }
        }
        assert_eq!(RifeStatus::available().message("linux-x64"), None);
        let with_detail = RifeStatus::unavailable(RifeReason::MissingLibrary, "could not load vcomp140.dll".to_string());
        let m = with_detail.message("windows-x64").unwrap();
        assert!(m.contains("Visual C++ Redistributable") && m.contains("vcomp140.dll"));
    }

    #[test]
    fn json_carries_the_message() {
        let v = RifeStatus::unavailable(RifeReason::NoVulkan, None).to_json("windows-x64");
        assert_eq!(v["available"], false);
        assert_eq!(v["reason"], "noVulkan");
        assert!(v["message"].as_str().unwrap().contains("Vulkan"));
        let ok = RifeStatus::available().to_json("windows-x64");
        assert_eq!(ok, serde_json::json!({ "available": true }));
    }

    #[test]
    fn classify_success() {
        let ok = ProbeExit { success: true, ..Default::default() };
        assert!(classify(&ok, "RIFE_PROBE:render\n").available);
    }

    #[test]
    fn classify_segfault_creating_the_gpu_instance_is_no_vulkan() {
        // What macOS does with no MoltenVK in the process, reproduced 2026-10-24.
        let s = classify(&failed("signal 11 (SIGSEGV)"), "RIFE_PROBE:preload\nRIFE_PROBE:load\nRIFE_PROBE:init\n");
        assert_eq!(s.reason, Some(RifeReason::NoVulkan));
    }

    #[test]
    fn classify_plugin_errors() {
        let gpu = "RIFE_PROBE:init\nvapoursynth.Error: RIFE: failed to create GPU instance\n";
        assert_eq!(classify(&failed("exit code 1"), gpu).reason, Some(RifeReason::NoVulkan));
        let dev = "RIFE_PROBE:init\nvapoursynth.Error: RIFE: invalid GPU device\n";
        assert_eq!(classify(&failed("exit code 1"), dev).reason, Some(RifeReason::NoVulkan));
        let model = "RIFE_PROBE:init\nvapoursynth.Error: RIFE: failed to load model\n";
        assert_eq!(classify(&failed("exit code 1"), model).reason, Some(RifeReason::NotInstalled));
    }

    #[test]
    fn classify_load_failure_names_the_missing_runtime() {
        let err = "RIFE_PROBE:missing:vcomp140.dll\nRIFE_PROBE:preload\nRIFE_PROBE:load\n\
                   vapoursynth.Error: Failed to load C:\\deps\\librife.dll. GetLastError() returned 126.\n";
        let s = classify(&failed("exit code 1"), err);
        assert_eq!(s.reason, Some(RifeReason::MissingLibrary));
        assert!(s.detail.unwrap().contains("vcomp140.dll"));
        // With every runtime present, the loader's own error is the detail.
        let s = classify(&failed("exit code 1"), &err.replace("RIFE_PROBE:missing:vcomp140.dll\n", ""));
        assert_eq!(s.reason, Some(RifeReason::LoadFailed));
        assert!(s.detail.unwrap().contains("GetLastError() returned 126"));
    }

    #[test]
    fn classify_crash_while_rendering_and_timeouts() {
        let s = classify(&failed("signal 11 (SIGSEGV)"), "RIFE_PROBE:init\nRIFE_PROBE:render\n");
        assert_eq!(s.reason, Some(RifeReason::Crashed));
        assert!(s.detail.unwrap().contains("SIGSEGV"));
        let t = ProbeExit { success: false, timed_out: true, status: "timed out".into() };
        assert_eq!(classify(&t, "").reason, Some(RifeReason::ProbeFailed));
        // vspipe that never reached the script at all.
        assert_eq!(classify(&failed("exit code 1"), "").reason, Some(RifeReason::ProbeFailed));
    }

    #[test]
    fn classify_illegal_instruction_is_the_cpu() {
        let sigill = classify(&failed("signal 4 (unknown)"), "RIFE_PROBE:load\n");
        assert_eq!(sigill.reason, Some(RifeReason::UnsupportedCpu));
        let win = failed("exit code -1073741795 — illegal instruction: a plugin used a CPU feature");
        assert_eq!(classify(&win, "RIFE_PROBE:load\n").reason, Some(RifeReason::UnsupportedCpu));
    }

    #[test]
    fn py_str_escapes_windows_paths_and_quotes() {
        assert_eq!(py_str(Path::new(r"C:\Users\o'brien\rife")), r"'C:\\Users\\o\'brien\\rife'");
        assert_eq!(py_str(Path::new("/a/b")), "'/a/b'");
    }

    #[test]
    fn probe_script_preloads_only_where_a_preload_exists() {
        let mac = RifeFiles::in_vapoursynth_dir(Path::new("/v"), "macos-arm64");
        let s = probe_script(&mac, "macos-arm64");
        let preload = py_str(mac.preload.as_deref().unwrap());
        assert!(s.contains(&format!("ctypes.CDLL({preload}, mode=ctypes.RTLD_GLOBAL)")));
        let win = RifeFiles::in_vapoursynth_dir(Path::new("C:/v"), "windows-x64");
        let s = probe_script(&win, "windows-x64");
        assert!(s.contains("if None:"));
        assert!(s.contains("'vcomp140.dll'"));
    }
}
