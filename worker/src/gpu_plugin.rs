//! The ncnn-on-Vulkan plugins: where their files live, and whether they can run
//! here.
//!
//! Two features run a neural network through ncnn on the GPU: RIFE frame
//! interpolation (`rife.RIFE`, the Frame Rate pass) and AI upscaling
//! (vs-mlrt's `ncnn.Model` with Real-ESRGAN / Real-CUGAN, the Crop & Resize
//! pass). Both need more than the deps bundle — a GPU with a working Vulkan
//! driver — and without a Vulkan implementation ncnn does not raise: it
//! segfaults inside `ncnn::create_gpu_instance`. So a job cannot be allowed to
//! find out by trying. Instead this module runs the plugin once in a throwaway
//! vspipe, records how far it got, and turns the outcome into a reason with a
//! remedy the user can act on. The app shows that message the moment the
//! feature is selected (`--probe-rife`, `--probe-upscale`), and the worker
//! refuses such a job with the same message rather than emitting a script that
//! would crash.
//!
//! Each plugin lives in its own directory under `vapoursynth/`, outside the
//! autoload directory, and the script loads it explicitly — so nothing about it
//! (a missing runtime DLL, a driver that faults on load, AVX in a static
//! initializer) can reach a job that did not ask for it. On macOS both resolve
//! Vulkan from MoltenVK, which is preloaded from `vapoursynth/moltenvk/`.
//!
//! The plugins are in the deps bundle; their models are not. Every AI model is
//! an add-on (docs/ADDONS.md): RIFE's is `frame-rate-rife` ([`RIFE_ADDON`]),
//! the upscalers' are listed in `upscale_addons.rs`, and a job that needs one
//! is refused through `ProcessingPipeline::required_addons` like any other
//! add-on. So the probe must not need a model either: it runs each plugin on a
//! stand-in network of its own — for VSNCNN a 264-byte ONNX convolution
//! compiled into the worker ([`NCNN_SELFTEST_MODEL`]), for RIFE a two-layer
//! ncnn network written beside the probe script ([`RIFE_SELFTEST_PARAM`]) —
//! and checks the answer. That tells "this computer can't run it" apart from
//! "the add-on isn't installed" before the user has downloaded anything.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// The add-on holding RIFE's model (`app/assets/addons/frame-rate-rife.json`).
pub const RIFE_ADDON: &str = "frame-rate-rife";

/// RIFE's model directory inside the add-on: 4.26, ncnn conversion, ensemble
/// off. The name is load-bearing: the plugin takes the model's version — and
/// with it the padding, 64 for 4.26 against 32 for most — from substrings of
/// this path, so the add-on installs its files under exactly this name.
pub const RIFE_MODEL_DIR_NAME: &str = "rife-v4.26_ensembleFalse";

/// Where a job's RIFE model is, under the add-ons directory.
pub fn rife_model_dir(addons_root: &Path) -> PathBuf {
    crate::addons::addon_dir(addons_root, RIFE_ADDON).join(RIFE_MODEL_DIR_NAME)
}

/// The upscaling probe's model: one 1x1 convolution that swaps the first and
/// third channels and adds 0.125 (`Scripts/models/make_ncnn_selftest.py`,
/// committed as `Tests/TestResources/ncnn_selftest.onnx`). Handed to VSNCNN as
/// bytes, so the probe needs no add-on and writes no model file.
pub const NCNN_SELFTEST_MODEL: &[u8] = include_bytes!("../../Tests/TestResources/ncnn_selftest.onnx");

/// The RIFE probe's stand-in for `flownet`: what RIFE's v4 path feeds the
/// network (`in0`, `in1`: the two frames; `in2`: the timestep) and extracts
/// (`out0`), with the average of the two frames in between. No weights, so
/// `flownet.bin` is empty. Run through the plugin's real pre- and
/// post-processing shaders, frame 1 of a doubled two-frame clip is exactly the
/// average of its two frames.
pub const RIFE_SELFTEST_PARAM: &str = "7767517\n\
    5 6\n\
    Input in0 0 1 in0\n\
    Input in1 0 1 in1\n\
    Input in2 0 1 in2\n\
    BinaryOp sum 2 1 in0 in1 sum 0=0\n\
    BinaryOp out0 1 1 sum out0 0=2 1=1 2=5.000000e-01\n";

/// The stand-in's directory name: RIFE reads the model version from the path,
/// so it must say v4 (and 4.26, for the real model's padding).
const RIFE_SELFTEST_DIR_NAME: &str = "rife-v4.26_selftest";

/// How far the probe's answer may be from the exact one: the networks run in
/// fp16, whose step near 0.7 is about 0.0005.
const SELFTEST_TOLERANCE: f64 = 0.01;

/// How long the probe may take. GPU initialisation and the first shader
/// compile take a second or two; a driver that hangs must not hang the app.
const PROBE_TIMEOUT: Duration = Duration::from_secs(60);

/// One of the ncnn-on-Vulkan features.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GpuPlugin {
    /// RIFE frame interpolation.
    Rife,
    /// Real-ESRGAN / Real-CUGAN upscaling through vs-mlrt's VSNCNN.
    Upscale,
}

impl GpuPlugin {
    /// The name the user knows it by, at the start of every message.
    pub fn label(self) -> &'static str {
        match self {
            GpuPlugin::Rife => "RIFE",
            GpuPlugin::Upscale => "AI upscaling",
        }
    }

    /// Its directory under `vapoursynth/`.
    fn dir_name(self) -> &'static str {
        match self {
            GpuPlugin::Rife => "rife",
            GpuPlugin::Upscale => "ncnn",
        }
    }

    /// The VapourSynth namespace the plugin registers.
    pub fn namespace(self) -> &'static str {
        match self {
            GpuPlugin::Rife => "rife",
            GpuPlugin::Upscale => "ncnn",
        }
    }

    /// What to use instead, for the reasons the user cannot fix.
    fn alternative(self) -> &'static str {
        match self {
            GpuPlugin::Rife => "Use Motion interpolation instead.",
            GpuPlugin::Upscale => "Use NNEDI3 upscaling instead.",
        }
    }

    /// Marker the probe script prints to stderr as it passes each stage, so a
    /// process that died without a message still says where it died.
    fn stage_marker(self) -> &'static str {
        match self {
            GpuPlugin::Rife => "RIFE_PROBE:",
            GpuPlugin::Upscale => "UPSCALE_PROBE:",
        }
    }
}

/// Whether the deps bundle for this platform ships the plugin at all.
///
/// RIFE: macOS x64 is excluded because the only prebuilt dylib targets macOS 13
/// (the bundle's floor is 12) and runs AVX in a static initializer; linux-arm64
/// because upstream publishes no build. Both need a source build first.
pub fn platform_ships_rife(platform_suffix: &str) -> bool {
    matches!(platform_suffix, "macos-arm64" | "windows-x64" | "linux-x64")
}

/// AI upscaling: VSNCNN is built from source on macOS arm64 and Linux x64 (only
/// Windows has a published build). Neither Intel Macs nor linux-arm64 have the
/// MoltenVK copy / ncnn release this needs yet, as for RIFE.
pub fn platform_ships_upscale(platform_suffix: &str) -> bool {
    matches!(platform_suffix, "macos-arm64" | "windows-x64" | "linux-x64")
}

fn platform_ships(plugin: GpuPlugin, platform_suffix: &str) -> bool {
    match plugin {
        GpuPlugin::Rife => platform_ships_rife(platform_suffix),
        GpuPlugin::Upscale => platform_ships_upscale(platform_suffix),
    }
}

/// The files a plugin needs from the deps bundle, as laid out under
/// `deps/<platform>/vapoursynth/`. Its models are add-ons, not listed here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GpuPluginFiles {
    pub plugin: PathBuf,
    /// A library to load into the process before the plugin: MoltenVK on
    /// macOS, where ncnn resolves Vulkan from whatever is already loaded.
    pub preload: Option<PathBuf>,
}

impl GpuPluginFiles {
    pub fn in_vapoursynth_dir(plugin: GpuPlugin, vs_dir: &Path, platform_suffix: &str) -> Self {
        let dir = vs_dir.join(plugin.dir_name());
        let os = platform_suffix.split('-').next().unwrap_or("");
        // The names upstream ships them under (RIFE's Windows DLL keeps "lib").
        let file = match (plugin, os) {
            (GpuPlugin::Rife, "macos") => "librife.dylib",
            (GpuPlugin::Rife, "windows") => "librife.dll",
            (GpuPlugin::Rife, _) => "librife.so",
            (GpuPlugin::Upscale, "macos") => "libvsncnn.dylib",
            (GpuPlugin::Upscale, "windows") => "vsncnn.dll",
            (GpuPlugin::Upscale, _) => "libvsncnn.so",
        };
        let preload = platform_suffix
            .starts_with("macos")
            .then(|| vs_dir.join("moltenvk").join("libMoltenVK.dylib"));
        Self { plugin: dir.join(file), preload }
    }

    /// Every file that must exist, in the order a user would want to hear
    /// about them.
    pub fn required(&self) -> Vec<PathBuf> {
        let mut files = vec![self.plugin.clone()];
        files.extend(self.preload.iter().cloned());
        files
    }

    pub fn missing(&self) -> Vec<PathBuf> {
        self.required().into_iter().filter(|p| !p.is_file()).collect()
    }
}

/// Why a plugin cannot run here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GpuPluginReason {
    /// No build of it ships for this platform.
    UnsupportedPlatform,
    /// The installed deps bundle predates it, or is missing its files.
    NotInstalled,
    /// No usable Vulkan device or driver.
    NoVulkan,
    /// A system library the plugin links against is not installed.
    MissingLibrary,
    /// The plugin would not load, for a reason the probe could not narrow.
    LoadFailed,
    /// The probe process crashed after the GPU was initialised.
    Crashed,
    /// The plugin ran its self-test network on the GPU and got the wrong
    /// answer: a driver that computes garbage, whose output can't be trusted.
    WrongResult,
    /// The plugin used an instruction this CPU does not have (SIGILL, or
    /// Windows' 0xC000001D) — an x86 machine older than its build target.
    UnsupportedCpu,
    /// `VAPOURBOX_DISABLE_VULKAN` is set.
    Disabled,
    /// The probe itself could not be run or did not finish.
    ProbeFailed,
}

/// Whether a plugin runs here, and if not, why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GpuPluginStatus {
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<GpuPluginReason>,
    /// The specific thing that failed (a missing file, a library name, the
    /// error text), shown under the remedy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl GpuPluginStatus {
    pub fn available() -> Self {
        Self { available: true, reason: None, detail: None }
    }

    pub fn unavailable(reason: GpuPluginReason, detail: impl Into<Option<String>>) -> Self {
        Self { available: false, reason: Some(reason), detail: detail.into() }
    }

    /// What to tell the user: what is wrong and what to do about it. `None`
    /// when the plugin is available. The app shows this verbatim and the worker
    /// fails such a job with it, so there is one wording, written here.
    pub fn message(&self, plugin: GpuPlugin, platform_suffix: &str) -> Option<String> {
        use GpuPluginReason as R;
        let reason = self.reason?;
        let name = plugin.label();
        let os = platform_suffix.split('-').next().unwrap_or("");
        let text = match reason {
            R::UnsupportedPlatform => {
                let which = match platform_suffix {
                    "macos-x64" => "Intel Macs",
                    "linux-arm64" => "Linux on ARM",
                    "windows-arm64" => "Windows on ARM",
                    _ => "this platform",
                };
                format!(
                    "{name} isn't available for {which} yet: no build of it ships with \
                     VapourBox for this platform. {}",
                    plugin.alternative()
                )
            }
            R::NotInstalled => format!(
                "{name}'s files aren't in the installed dependency bundle, which is \
                 probably older than this version of VapourBox. Restart VapourBox to let \
                 it download the current dependencies."
            ),
            R::NoVulkan => match os {
                "windows" => format!(
                    "{name} needs a graphics card with Vulkan support, and none was \
                     found. Install or update the driver from your GPU's maker (NVIDIA, \
                     AMD or Intel) — Vulkan support comes with it — then restart \
                     VapourBox. Remote desktop sessions and virtual machines usually have \
                     no Vulkan device."
                ),
                "linux" => format!(
                    "{name} needs a graphics card with a Vulkan driver, and none was \
                     found. Install your distribution's Vulkan driver and loader (for \
                     example mesa-vulkan-drivers and libvulkan1 on Debian/Ubuntu, or \
                     mesa-vulkan-drivers and vulkan-loader on Fedora; NVIDIA's own driver \
                     includes Vulkan), then restart VapourBox."
                ),
                _ => format!(
                    "{name} could not open the GPU through Metal. This happens in virtual \
                     machines and some remote sessions; on a normal login it should work, \
                     so try restarting VapourBox."
                ),
            },
            R::MissingLibrary => match os {
                "windows" => format!(
                    "{name} needs the Microsoft Visual C++ Redistributable (x64), which \
                     isn't installed. Install the latest version from Microsoft (search \
                     for \"Visual C++ Redistributable latest supported downloads\"), then \
                     restart VapourBox."
                ),
                _ => format!(
                    "{name} needs a system library that isn't installed. Install it with \
                     your package manager (libgomp is in the libgomp1 or libgomp package), \
                     then restart VapourBox."
                ),
            },
            R::LoadFailed => format!(
                "{name}'s plugin failed to load on this computer. Restart VapourBox to \
                 re-check its dependencies; if this persists, please report it with the \
                 details below."
            ),
            R::Crashed => format!(
                "{name} crashed while testing the GPU. Updating your graphics driver \
                 usually fixes this; restart VapourBox afterwards."
            ),
            R::WrongResult => format!(
                "{name} ran on the GPU but got a test calculation wrong, so its output \
                 can't be trusted. Updating your graphics driver usually fixes this; \
                 restart VapourBox afterwards."
            ),
            R::UnsupportedCpu => format!(
                "{name}'s plugin needs a newer processor than this computer has (it uses \
                 instructions this CPU lacks). {}",
                plugin.alternative()
            ),
            R::Disabled => format!(
                "{name} is turned off by the VAPOURBOX_DISABLE_VULKAN environment variable."
            ),
            R::ProbeFailed => format!(
                "VapourBox couldn't check whether {name} runs on this computer. Restart \
                 VapourBox to try again."
            ),
        };
        Some(match &self.detail {
            Some(d) if !d.is_empty() => format!("{text}\n\nDetails: {d}"),
            _ => text,
        })
    }

    /// The probe result as the JSON the `--probe-*` flags print, message included.
    pub fn to_json(&self, plugin: GpuPlugin, platform_suffix: &str) -> serde_json::Value {
        let mut v = serde_json::to_value(self).unwrap_or_default();
        if let (Some(msg), Some(obj)) = (self.message(plugin, platform_suffix), v.as_object_mut()) {
            obj.insert("message".into(), serde_json::Value::String(msg));
        }
        v
    }
}

/// Everything the platform and file checks can decide without running
/// anything. `None` means "it should work — run the probe".
pub fn precheck(
    plugin: GpuPlugin,
    platform_suffix: &str,
    files: &GpuPluginFiles,
) -> Option<GpuPluginStatus> {
    if !platform_ships(plugin, platform_suffix) {
        return Some(GpuPluginStatus::unavailable(GpuPluginReason::UnsupportedPlatform, None));
    }
    let missing = files.missing();
    if !missing.is_empty() {
        let list = missing.iter().map(|p| p.display().to_string()).collect::<Vec<_>>();
        return Some(GpuPluginStatus::unavailable(
            GpuPluginReason::NotInstalled,
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

/// Bytes as a Python `bytes.fromhex(...)` expression.
fn py_bytes(data: &[u8]) -> String {
    let hex: String = data.iter().map(|b| format!("{b:02x}")).collect();
    format!("bytes.fromhex('{hex}')")
}

/// The probe: load the plugin, create the GPU instance, and run its stand-in
/// network on one frame — the three places it has been seen to fail — then
/// check the answer. `selftest_dir` is where [`write_rife_selftest`] put RIFE's
/// stand-in model (unused for the upscaler, whose model is in the script).
pub fn probe_script(
    plugin: GpuPlugin,
    files: &GpuPluginFiles,
    platform_suffix: &str,
    selftest_dir: &Path,
) -> String {
    // Shared libraries whose absence makes the plugin fail to load with only a
    // generic "module not found". Checked first so the user is told which one.
    // VSNCNN's Windows build links its runtime statically.
    let runtime_libs: &[&str] = match plugin {
        GpuPlugin::Rife if platform_suffix.starts_with("windows") => &[
            "vcomp140.dll",
            "msvcp140.dll",
            "msvcp140_atomic_wait.dll",
            "vcruntime140.dll",
            "vcruntime140_1.dll",
        ],
        _ if platform_suffix.starts_with("linux") => &["libgomp.so.1"],
        _ => &[],
    };
    let libs = runtime_libs.iter().map(|l| format!("'{l}'")).collect::<Vec<_>>().join(", ");
    let preload = files.preload.as_deref().map(py_str).unwrap_or_else(|| "None".into());
    // The clip, the call that makes ncnn create its GPU instance and run the
    // stand-in network, and the answer frame 1 must hold.
    let (clip, call, expected) = match plugin {
        // Two different frames, doubled: frame 1 is the network's average.
        GpuPlugin::Rife => (
            "clip = core.std.BlankClip(width=64, height=64, format=vs.RGBS, length=1, fpsnum=25, fpsden=1, color=[0.2, 0.4, 0.6])\n\
             clip = clip + core.std.BlankClip(clip, color=[0.6, 0.4, 0.2])",
            format!(
                "clip = core.rife.RIFE(clip, model_path={}, fps_num=50, fps_den=1)",
                py_str(selftest_dir)
            ),
            "[0.4, 0.4, 0.4]",
        ),
        // Swap the first and third channels, add 0.125.
        GpuPlugin::Upscale => (
            "clip = core.std.BlankClip(width=64, height=64, format=vs.RGBS, length=2, fpsnum=25, fpsden=1, color=[0.2, 0.4, 0.6])",
            format!(
                "clip = core.ncnn.Model(clip, network_path={}, path_is_serialization=True, fp16=True)",
                py_bytes(NCNN_SELFTEST_MODEL)
            ),
            "[0.725, 0.525, 0.325]",
        ),
    };
    format!(
        "import sys, ctypes\n\
         def stage(s):\n    print('{marker}' + s, file=sys.stderr, flush=True)\n\
         for lib in [{libs}]:\n    try:\n        ctypes.CDLL(lib)\n    except OSError:\n        stage('missing:' + lib)\n\
         stage('preload')\n\
         if {preload}:\n    ctypes.CDLL({preload}, mode=ctypes.RTLD_GLOBAL)\n\
         import vapoursynth as vs\n\
         core = vs.core\n\
         stage('load')\n\
         if not hasattr(core, '{namespace}'):\n    core.std.LoadPlugin({plugin_path})\n\
         stage('init')\n\
         {clip}\n\
         {call}\n\
         stage('render')\n\
         f = clip.get_frame(1)\n\
         got = [float(f[p][8, 8]) for p in range(3)]\n\
         del f\n\
         if any(abs(g - e) > {tol} for g, e in zip(got, {expected})):\n    \
         stage('wrong')\n    \
         raise vs.Error('self-test result ' + repr(got) + ', expected ' + repr({expected}))\n\
         stage('verified')\n\
         clip.set_output()\n",
        marker = plugin.stage_marker(),
        namespace = plugin.namespace(),
        plugin_path = py_str(&files.plugin),
        tol = SELFTEST_TOLERANCE,
    )
}

/// Write RIFE's stand-in model ([`RIFE_SELFTEST_PARAM`], an empty
/// `flownet.bin`) into a directory under `parent`, returning that directory.
pub fn write_rife_selftest(parent: &Path) -> std::io::Result<PathBuf> {
    let dir = parent.join(RIFE_SELFTEST_DIR_NAME);
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join("flownet.param"), RIFE_SELFTEST_PARAM)?;
    std::fs::write(dir.join("flownet.bin"), b"")?;
    Ok(dir)
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
pub fn classify(plugin: GpuPlugin, exit: &ProbeExit, stderr: &str) -> GpuPluginStatus {
    use GpuPluginReason as R;
    if exit.success {
        return GpuPluginStatus::available();
    }
    if exit.timed_out {
        return GpuPluginStatus::unavailable(
            R::ProbeFailed,
            format!("the GPU test did not finish within {}s", PROBE_TIMEOUT.as_secs()),
        );
    }

    let marker = plugin.stage_marker();
    let stages: Vec<&str> = stderr
        .lines()
        .filter_map(|l| l.trim().strip_prefix(marker))
        .collect();
    let missing: Vec<&str> = stages.iter().filter_map(|s| s.strip_prefix("missing:")).collect();
    let last = stages.iter().rev().find(|s| !s.starts_with("missing:")).copied();
    let error = last_error_line(marker, stderr);

    // An illegal instruction is the CPU, wherever it happened.
    if exit.status.starts_with("signal 4 ") || exit.status.contains("illegal instruction") {
        return GpuPluginStatus::unavailable(R::UnsupportedCpu, exit.status.clone());
    }

    // RIFE's and VSNCNN's own words for "no Vulkan device".
    if stderr.contains("failed to create GPU instance")
        || stderr.contains("invalid GPU device")
        || stderr.contains("get_gpu_device failed")
    {
        return GpuPluginStatus::unavailable(R::NoVulkan, error);
    }
    // The stand-in network did not load. Nothing the user installs fixes that
    // (it is part of the probe, not an add-on), so it is a plugin fault.
    if stderr.contains("failed to load model") || stderr.contains("load param failed") {
        return GpuPluginStatus::unavailable(R::LoadFailed, error);
    }
    match last {
        Some("wrong") => GpuPluginStatus::unavailable(R::WrongResult, error),
        // The plugin would not load. A runtime library the pre-check could not
        // open is the likeliest cause, and the one the user can fix.
        Some("load") if !missing.is_empty() => GpuPluginStatus::unavailable(
            R::MissingLibrary,
            format!("could not load {}", missing.join(", ")),
        ),
        Some("load") | Some("preload") => GpuPluginStatus::unavailable(
            R::LoadFailed,
            error.or_else(|| Some(format!("vspipe exited with {}", exit.status))),
        ),
        // Died creating the GPU instance without an error: no Vulkan loader or
        // driver for ncnn to call into.
        Some("init") => GpuPluginStatus::unavailable(
            R::NoVulkan,
            error.or_else(|| Some(format!("the GPU could not be initialised ({})", exit.status))),
        ),
        Some("render") => GpuPluginStatus::unavailable(
            R::Crashed,
            error.or_else(|| Some(format!("vspipe exited with {}", exit.status))),
        ),
        _ => GpuPluginStatus::unavailable(
            R::ProbeFailed,
            error.or_else(|| Some(format!("vspipe exited with {}", exit.status))),
        ),
    }
}

/// The last line of a Python/VapourSynth error, which names the actual failure.
fn last_error_line(marker: &str, stderr: &str) -> Option<String> {
    stderr
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with(marker) && !l.starts_with('['))
        .filter(|l| l.contains("Error") || l.contains("error") || l.contains("Failed"))
        .last()
        .map(|l| l.chars().take(400).collect())
}

/// Run the probe script through vspipe and classify the result.
pub fn run_probe(
    plugin: GpuPlugin,
    vspipe: &Path,
    env: &HashMap<String, String>,
    files: &GpuPluginFiles,
    platform_suffix: &str,
) -> GpuPluginStatus {
    let work = std::env::temp_dir().join(format!(
        "vapourbox_{}_probe_{}",
        plugin.namespace(),
        std::process::id()
    ));
    let tmp = work.join("probe.vpy");
    let written = std::fs::create_dir_all(&work).and_then(|_| {
        let selftest = match plugin {
            GpuPlugin::Rife => write_rife_selftest(&work)?,
            GpuPlugin::Upscale => work.clone(),
        };
        std::fs::write(&tmp, probe_script(plugin, files, platform_suffix, &selftest))
    });
    if let Err(e) = written {
        let _ = std::fs::remove_dir_all(&work);
        return GpuPluginStatus::unavailable(
            GpuPluginReason::ProbeFailed,
            format!("could not write the probe script: {e}"),
        );
    }
    let exit_and_stderr = run_with_timeout(vspipe, &tmp, env);
    let _ = std::fs::remove_dir_all(&work);
    match exit_and_stderr {
        Ok((exit, stderr)) => classify(plugin, &exit, &stderr),
        Err(e) => GpuPluginStatus::unavailable(
            GpuPluginReason::ProbeFailed,
            format!("could not run vspipe: {e}"),
        ),
    }
}

fn run_with_timeout(
    vspipe: &Path,
    script: &Path,
    env: &HashMap<String, String>,
) -> std::io::Result<(ProbeExit, String)> {
    // Frame 1: for RIFE's 2x output the first interpolated frame (frame 0 is a
    // copy and would never touch the GPU); for upscaling, any frame runs it.
    run_vspipe_probe(vspipe, script, env, &["-s", "1", "-e", "1"], PROBE_TIMEOUT)
}

/// Run a probe script through vspipe with `args` (the frame range), output
/// discarded, killing it after `timeout`; returns how it ended and its stderr.
/// Shared with the AI runtime's probe (`ai_runtime.rs`).
pub(crate) fn run_vspipe_probe(
    vspipe: &Path,
    script: &Path,
    env: &HashMap<String, String>,
    args: &[&str],
    timeout: Duration,
) -> std::io::Result<(ProbeExit, String)> {
    let mut child = Command::new(vspipe)
        .args(args)
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
        if start.elapsed() > timeout {
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
    use GpuPlugin::{Rife, Upscale};
    use GpuPluginReason as R;

    fn failed(status: &str) -> ProbeExit {
        ProbeExit { success: false, timed_out: false, status: status.into() }
    }

    #[test]
    fn layout_per_platform() {
        let mac = GpuPluginFiles::in_vapoursynth_dir(Rife, Path::new("/d/vapoursynth"), "macos-arm64");
        assert_eq!(mac.plugin, Path::new("/d/vapoursynth/rife/librife.dylib"));
        assert_eq!(mac.preload.as_deref(), Some(Path::new("/d/vapoursynth/moltenvk/libMoltenVK.dylib")));
        let win = GpuPluginFiles::in_vapoursynth_dir(Rife, Path::new("D:/v"), "windows-x64");
        assert!(win.plugin.ends_with("rife/librife.dll"));
        assert_eq!(win.preload, None);
        let linux = GpuPluginFiles::in_vapoursynth_dir(Rife, Path::new("/v"), "linux-x64");
        assert!(linux.plugin.ends_with("rife/librife.so"));
        // MoltenVK is required on macOS, and only there. No model is: they
        // are add-ons.
        assert_eq!(mac.required(), [mac.plugin.clone(), mac.preload.clone().unwrap()]);
        assert_eq!(linux.required(), [linux.plugin.clone()]);

        let mac = GpuPluginFiles::in_vapoursynth_dir(Upscale, Path::new("/d/vapoursynth"), "macos-arm64");
        assert_eq!(mac.plugin, Path::new("/d/vapoursynth/ncnn/libvsncnn.dylib"));
        assert_eq!(mac.preload.as_deref(), Some(Path::new("/d/vapoursynth/moltenvk/libMoltenVK.dylib")));
        let win = GpuPluginFiles::in_vapoursynth_dir(Upscale, Path::new("D:/v"), "windows-x64");
        assert!(win.plugin.ends_with("ncnn/vsncnn.dll"));
        let linux = GpuPluginFiles::in_vapoursynth_dir(Upscale, Path::new("/v"), "linux-x64");
        assert!(linux.plugin.ends_with("ncnn/libvsncnn.so"));
        assert_eq!(linux.required(), [linux.plugin.clone()]);
        // A job's RIFE model is the add-on's, in the directory whose name
        // tells the plugin which version (and padding) it is.
        assert_eq!(
            rife_model_dir(Path::new("/a")),
            Path::new("/a/frame-rate-rife/rife-v4.26_ensembleFalse")
        );
    }

    #[test]
    fn unsupported_platforms_are_reported_before_anything_runs() {
        for plugin in [Rife, Upscale] {
            let files = GpuPluginFiles::in_vapoursynth_dir(plugin, Path::new("/nonexistent"), "macos-x64");
            for p in ["macos-x64", "linux-arm64", "windows-arm64"] {
                let s = precheck(plugin, p, &files).expect("must decide without probing");
                assert_eq!(s.reason, Some(R::UnsupportedPlatform), "{plugin:?} {p}");
            }
            // A shipping platform with no files is "not installed", not unsupported.
            let files = GpuPluginFiles::in_vapoursynth_dir(plugin, Path::new("/nonexistent"), "linux-x64");
            let s = precheck(plugin, "linux-x64", &files).unwrap();
            assert_eq!(s.reason, Some(R::NotInstalled));
        }
        let files = GpuPluginFiles::in_vapoursynth_dir(Rife, Path::new("/nonexistent"), "linux-x64");
        assert!(precheck(Rife, "linux-x64", &files).unwrap().detail.unwrap().contains("librife.so"));
    }

    #[test]
    fn every_reason_has_a_message_on_every_platform() {
        let reasons = [
            R::UnsupportedPlatform,
            R::NotInstalled,
            R::NoVulkan,
            R::MissingLibrary,
            R::LoadFailed,
            R::Crashed,
            R::WrongResult,
            R::UnsupportedCpu,
            R::Disabled,
            R::ProbeFailed,
        ];
        for plugin in [Rife, Upscale] {
            for platform in ["macos-arm64", "macos-x64", "windows-x64", "linux-x64", "linux-arm64"] {
                for r in reasons {
                    let m = GpuPluginStatus::unavailable(r, None).message(plugin, platform).unwrap();
                    assert!(m.len() > 40, "{platform} {r:?}: {m}");
                    assert!(m.contains(plugin.label()), "{plugin:?} {r:?}: {m}");
                }
            }
            assert_eq!(GpuPluginStatus::available().message(plugin, "linux-x64"), None);
        }
        let with_detail = GpuPluginStatus::unavailable(R::MissingLibrary, "could not load vcomp140.dll".to_string());
        let m = with_detail.message(Rife, "windows-x64").unwrap();
        assert!(m.contains("Visual C++ Redistributable") && m.contains("vcomp140.dll"));
        let m = GpuPluginStatus::unavailable(R::UnsupportedPlatform, None).message(Upscale, "macos-x64").unwrap();
        assert!(m.contains("NNEDI3"), "{m}");
    }

    #[test]
    fn json_carries_the_message() {
        let v = GpuPluginStatus::unavailable(R::NoVulkan, None).to_json(Rife, "windows-x64");
        assert_eq!(v["available"], false);
        assert_eq!(v["reason"], "noVulkan");
        assert!(v["message"].as_str().unwrap().contains("Vulkan"));
        let ok = GpuPluginStatus::available().to_json(Upscale, "windows-x64");
        assert_eq!(ok, serde_json::json!({ "available": true }));
    }

    #[test]
    fn classify_success() {
        let ok = ProbeExit { success: true, ..Default::default() };
        assert!(classify(Rife, &ok, "RIFE_PROBE:render\n").available);
    }

    #[test]
    fn classify_segfault_creating_the_gpu_instance_is_no_vulkan() {
        // What macOS does with no MoltenVK in the process, reproduced 2026-10-24.
        let s = classify(Rife, &failed("signal 11 (SIGSEGV)"), "RIFE_PROBE:preload\nRIFE_PROBE:load\nRIFE_PROBE:init\n");
        assert_eq!(s.reason, Some(R::NoVulkan));
        let s = classify(Upscale, &failed("signal 11 (SIGSEGV)"), "UPSCALE_PROBE:load\nUPSCALE_PROBE:init\n");
        assert_eq!(s.reason, Some(R::NoVulkan));
    }

    #[test]
    fn classify_plugin_errors() {
        let gpu = "RIFE_PROBE:init\nvapoursynth.Error: RIFE: failed to create GPU instance\n";
        assert_eq!(classify(Rife, &failed("exit code 1"), gpu).reason, Some(R::NoVulkan));
        let dev = "RIFE_PROBE:init\nvapoursynth.Error: RIFE: invalid GPU device\n";
        assert_eq!(classify(Rife, &failed("exit code 1"), dev).reason, Some(R::NoVulkan));
        // The stand-in model is part of the probe: failing to load it is the
        // plugin's fault, never a missing add-on.
        let model = "RIFE_PROBE:init\nvapoursynth.Error: RIFE: failed to load model\n";
        assert_eq!(classify(Rife, &failed("exit code 1"), model).reason, Some(R::LoadFailed));
        // VSNCNN's words.
        let dev = "UPSCALE_PROBE:init\nvapoursynth.Error: ncnn.Model: get_gpu_device failed\n";
        assert_eq!(classify(Upscale, &failed("exit code 1"), dev).reason, Some(R::NoVulkan));
        let param = "UPSCALE_PROBE:init\nvapoursynth.Error: ncnn.Model: load param failed\n";
        assert_eq!(classify(Upscale, &failed("exit code 1"), param).reason, Some(R::LoadFailed));
        // A self-test that ran but computed the wrong answer.
        let wrong = "UPSCALE_PROBE:render\nUPSCALE_PROBE:wrong\n\
                     vapoursynth.Error: self-test result [0.0, 0.0, 0.0], expected [0.725, 0.525, 0.325]\n";
        let s = classify(Upscale, &failed("exit code 1"), wrong);
        assert_eq!(s.reason, Some(R::WrongResult));
        assert!(s.detail.unwrap().contains("expected"));
    }

    #[test]
    fn classify_load_failure_names_the_missing_runtime() {
        let err = "RIFE_PROBE:missing:vcomp140.dll\nRIFE_PROBE:preload\nRIFE_PROBE:load\n\
                   vapoursynth.Error: Failed to load C:\\deps\\librife.dll. GetLastError() returned 126.\n";
        let s = classify(Rife, &failed("exit code 1"), err);
        assert_eq!(s.reason, Some(R::MissingLibrary));
        assert!(s.detail.unwrap().contains("vcomp140.dll"));
        // With every runtime present, the loader's own error is the detail.
        let s = classify(Rife, &failed("exit code 1"), &err.replace("RIFE_PROBE:missing:vcomp140.dll\n", ""));
        assert_eq!(s.reason, Some(R::LoadFailed));
        assert!(s.detail.unwrap().contains("GetLastError() returned 126"));
    }

    #[test]
    fn classify_crash_while_rendering_and_timeouts() {
        let s = classify(Rife, &failed("signal 11 (SIGSEGV)"), "RIFE_PROBE:init\nRIFE_PROBE:render\n");
        assert_eq!(s.reason, Some(R::Crashed));
        assert!(s.detail.unwrap().contains("SIGSEGV"));
        let t = ProbeExit { success: false, timed_out: true, status: "timed out".into() };
        assert_eq!(classify(Rife, &t, "").reason, Some(R::ProbeFailed));
        // vspipe that never reached the script at all.
        assert_eq!(classify(Rife, &failed("exit code 1"), "").reason, Some(R::ProbeFailed));
    }

    #[test]
    fn classify_reads_only_its_own_markers() {
        // An upscale probe's stderr is not read as RIFE's, or the reverse.
        let s = classify(Upscale, &failed("signal 11 (SIGSEGV)"), "RIFE_PROBE:init\nRIFE_PROBE:render\n");
        assert_eq!(s.reason, Some(R::ProbeFailed));
    }

    #[test]
    fn classify_illegal_instruction_is_the_cpu() {
        let sigill = classify(Rife, &failed("signal 4 (unknown)"), "RIFE_PROBE:load\n");
        assert_eq!(sigill.reason, Some(R::UnsupportedCpu));
        let win = failed("exit code -1073741795 — illegal instruction: a plugin used a CPU feature");
        assert_eq!(classify(Rife, &win, "RIFE_PROBE:load\n").reason, Some(R::UnsupportedCpu));
    }

    #[test]
    fn py_str_escapes_windows_paths_and_quotes() {
        assert_eq!(py_str(Path::new(r"C:\Users\o'brien\rife")), r"'C:\\Users\\o\'brien\\rife'");
        assert_eq!(py_str(Path::new("/a/b")), "'/a/b'");
    }

    #[test]
    fn probe_script_preloads_only_where_a_preload_exists() {
        let selftest = Path::new("/t/rife-v4.26_selftest");
        let mac = GpuPluginFiles::in_vapoursynth_dir(Rife, Path::new("/v"), "macos-arm64");
        let s = probe_script(Rife, &mac, "macos-arm64", selftest);
        let preload = py_str(mac.preload.as_deref().unwrap());
        assert!(s.contains(&format!("ctypes.CDLL({preload}, mode=ctypes.RTLD_GLOBAL)")));
        let win = GpuPluginFiles::in_vapoursynth_dir(Rife, Path::new("C:/v"), "windows-x64");
        let s = probe_script(Rife, &win, "windows-x64", selftest);
        assert!(s.contains("if None:"));
        assert!(s.contains("'vcomp140.dll'"));
        // VSNCNN's Windows DLL needs no VC++ runtime, and loads by its own namespace.
        let win = GpuPluginFiles::in_vapoursynth_dir(Upscale, Path::new("C:/v"), "windows-x64");
        let s = probe_script(Upscale, &win, "windows-x64", selftest);
        assert!(!s.contains("vcomp140"));
        assert!(s.contains("hasattr(core, 'ncnn')") && s.contains("core.ncnn.Model("));
    }

    #[test]
    fn probes_run_a_stand_in_model_never_an_addon() {
        // The probes must work before any model add-on is installed: RIFE's
        // runs the stand-in written beside the script, VSNCNN's the model
        // embedded in it, and both check the answer.
        let selftest = Path::new("/t/rife-v4.26_selftest");
        for platform in ["macos-arm64", "windows-x64", "linux-x64"] {
            let files = GpuPluginFiles::in_vapoursynth_dir(Rife, Path::new("/v"), platform);
            let s = probe_script(Rife, &files, platform, selftest);
            assert!(s.contains(&format!("model_path={}", py_str(selftest))), "{s}");
            assert!(!s.contains(RIFE_MODEL_DIR_NAME) && !s.contains(RIFE_ADDON));
            assert!(s.contains("stage('wrong')") && s.contains("[0.4, 0.4, 0.4]"));

            let files = GpuPluginFiles::in_vapoursynth_dir(Upscale, Path::new("/v"), platform);
            let s = probe_script(Upscale, &files, platform, selftest);
            assert!(s.contains("path_is_serialization=True"), "{s}");
            assert!(s.contains(&py_bytes(NCNN_SELFTEST_MODEL)));
            assert!(!s.contains(".onnx"), "no model file: {s}");
            assert!(s.contains("[0.725, 0.525, 0.325]"));
        }
    }

    #[test]
    fn rife_stand_in_is_written_where_the_plugin_reads_v4() {
        let tmp = std::env::temp_dir().join(format!("vb-rife-selftest-{}", std::process::id()));
        let dir = write_rife_selftest(&tmp).unwrap();
        // The plugin decides "v4, padding 64" from the path.
        assert!(dir.to_string_lossy().contains("rife-v4.26"));
        assert_eq!(std::fs::read_to_string(dir.join("flownet.param")).unwrap(), RIFE_SELFTEST_PARAM);
        assert_eq!(std::fs::read(dir.join("flownet.bin")).unwrap().len(), 0);
        // An ncnn param file: magic, then the layer and blob counts it declares.
        let lines: Vec<&str> = RIFE_SELFTEST_PARAM.lines().collect();
        assert_eq!(lines[0], "7767517");
        assert_eq!(lines[1], format!("{} 6", lines.len() - 2));
        for blob in ["in0", "in1", "in2", "out0"] {
            assert!(RIFE_SELFTEST_PARAM.split_whitespace().any(|t| t == blob), "{blob}");
        }
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn rife_addon_matches_the_plugin() {
        let m = crate::addons::manifest(RIFE_ADDON).expect("frame-rate-rife.json");
        // Offered exactly where the plugin ships.
        for p in crate::addons::PLATFORMS {
            assert_eq!(m.supports(p), platform_ships_rife(p), "{p}");
        }
        // Installed under the directory name the plugin reads its version from.
        let mut paths = m.expected_paths("macos-arm64");
        paths.sort();
        assert_eq!(
            paths,
            [format!("{RIFE_MODEL_DIR_NAME}/flownet.bin"), format!("{RIFE_MODEL_DIR_NAME}/flownet.param")]
        );
        // Run by the bundled plugin, not ONNX Runtime.
        assert!(!crate::addons::needs_ai_runtime(&[RIFE_ADDON]));
    }

    #[test]
    fn ncnn_selftest_is_the_committed_model() {
        // Scripts/models/make_ncnn_selftest.py writes this file; the worker
        // embeds it. A 1x1 convolution: tiny, so the probe script stays small.
        assert!(NCNN_SELFTEST_MODEL.len() < 1024, "{}", NCNN_SELFTEST_MODEL.len());
        let committed = std::fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../Tests/TestResources/ncnn_selftest.onnx"),
        )
        .unwrap();
        assert_eq!(committed, NCNN_SELFTEST_MODEL);
        assert!(NCNN_SELFTEST_MODEL.windows(4).any(|w| w == b"Conv"));
    }
}
