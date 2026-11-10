//! The AI runtime add-on (ONNX Runtime + NumPy, `app/assets/addons/ai-runtime.json`):
//! whether it runs here, and on which execution provider.
//!
//! Like the GPU plugins (`gpu_plugin.rs`), this is found out by running it
//! once in a throwaway vspipe rather than by a job: the probe script imports
//! ONNX Runtime from the add-on through `templates/ai_runtime.py` — exactly
//! the path a job's `{{#AI_RUNTIME}}` block takes — creates a session for the
//! committed self-test model on the preferred provider, runs it directly and
//! through a VapourSynth frame, and reports the result as JSON on stderr. The
//! outcome becomes an [`AiRuntimeStatus`] with a message the app shows
//! verbatim (`--probe-ai-runtime`). Only a positive result is cached, for the
//! boot, as for the GPU plugins.

use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::addons::{self, AddonState, AI_RUNTIME};
use crate::gpu_plugin::{py_str, run_vspipe_probe, ProbeExit};

/// Session creation can compile the model for the GPU (Core ML, DirectML);
/// a driver that hangs must not hang the app.
const PROBE_TIMEOUT: Duration = Duration::from_secs(90);

/// Stage marker the probe prints to stderr, so a silent crash says where.
const MARKER: &str = "AI_RUNTIME_PROBE:";
/// Prefix of the line carrying the self-test's JSON result.
const RESULT: &str = "AI_RUNTIME_RESULT:";

/// Why the AI runtime cannot run here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AiRuntimeReason {
    /// The add-on has no build for this platform (or this macOS is too old —
    /// the app decides that one before offering it).
    UnsupportedPlatform,
    /// The add-on is not installed.
    NotInstalled,
    /// An install of an older manifest version.
    Outdated,
    /// A system library onnxruntime needs is missing (Windows: the VC++ runtime).
    MissingLibrary,
    /// `import onnxruntime` failed for another reason.
    ImportFailed,
    /// The self-test model could not be run, or computed the wrong answer.
    SessionFailed,
    /// An instruction this CPU lacks.
    UnsupportedCpu,
    /// The probe process crashed.
    Crashed,
    /// The probe could not be run or did not finish.
    ProbeFailed,
}

/// Whether the AI runtime runs here, and how.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiRuntimeStatus {
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<AiRuntimeReason>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// onnxruntime's version.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Every execution provider the installed onnxruntime offers.
    #[serde(default)]
    pub providers: Vec<String>,
    /// The provider the self-test session ran on (its first registered one).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// Why the preferred GPU provider was not used, when it fell back to the CPU.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback: Option<String>,
}

impl AiRuntimeStatus {
    pub fn unavailable(reason: AiRuntimeReason, detail: impl Into<Option<String>>) -> Self {
        Self {
            available: false,
            reason: Some(reason),
            detail: detail.into(),
            version: None,
            providers: Vec::new(),
            provider: None,
            fallback: None,
        }
    }

    /// What to tell the user, remedy included; `None` when available. The app
    /// shows this verbatim.
    pub fn message(&self, platform: &str) -> Option<String> {
        use AiRuntimeReason as R;
        let reason = self.reason?;
        let name = addons::manifest(AI_RUNTIME).map(|m| m.name.as_str()).unwrap_or("The AI runtime");
        let text = match reason {
            R::UnsupportedPlatform => format!("The {name} add-on isn't available on this platform."),
            R::NotInstalled => format!(
                "The {name} add-on is not installed. It is a separate download: install it in \
                 Settings → Add-ons."
            ),
            R::Outdated => format!(
                "The installed {name} add-on is out of date for this version of VapourBox. \
                 Install it again in Settings → Add-ons."
            ),
            R::MissingLibrary => {
                if platform.starts_with("windows") {
                    "ONNX Runtime needs the Microsoft Visual C++ Redistributable (x64), which \
                     isn't installed. Install the latest version from Microsoft (search for \
                     \"Visual C++ Redistributable latest supported downloads\"), then restart \
                     VapourBox."
                        .to_string()
                } else {
                    "ONNX Runtime needs a system library that isn't installed; the details below \
                     name it. Install it with your package manager, then restart VapourBox."
                        .to_string()
                }
            }
            R::ImportFailed => format!(
                "The {name} add-on is installed but would not load. Remove it and install it \
                 again in Settings → Add-ons; if this persists, please report it with the \
                 details below."
            ),
            R::SessionFailed => format!(
                "The {name} add-on loaded but could not run its test model. Updating your \
                 graphics driver may help; if this persists, please report it with the details \
                 below."
            ),
            R::UnsupportedCpu => "ONNX Runtime needs a newer processor than this computer has \
                 (it uses instructions this CPU lacks)."
                .to_string(),
            R::Crashed => format!(
                "The {name} add-on crashed while testing itself. Updating your graphics driver \
                 usually fixes this; restart VapourBox afterwards."
            ),
            R::ProbeFailed => format!(
                "VapourBox couldn't check whether the {name} add-on runs on this computer. \
                 Restart VapourBox to try again."
            ),
        };
        Some(match &self.detail {
            Some(d) if !d.is_empty() => format!("{text}\n\nDetails: {d}"),
            _ => text,
        })
    }

    /// The JSON `--probe-ai-runtime` prints, message included.
    pub fn to_json(&self, platform: &str) -> serde_json::Value {
        let mut v = serde_json::to_value(self).unwrap_or_default();
        if let (Some(msg), Some(obj)) = (self.message(platform), v.as_object_mut()) {
            obj.insert("message".into(), serde_json::Value::String(msg));
        }
        v
    }
}

/// What the add-on files alone decide. `None`: installed — run the probe.
pub fn precheck(addons_root: &Path, platform: &str) -> Option<AiRuntimeStatus> {
    use AiRuntimeReason as R;
    match addons::state(addons_root, AI_RUNTIME, platform) {
        AddonState::Installed => None,
        AddonState::Unsupported | AddonState::Unknown => {
            Some(AiRuntimeStatus::unavailable(R::UnsupportedPlatform, None))
        }
        AddonState::Missing => Some(AiRuntimeStatus::unavailable(R::NotInstalled, None)),
        AddonState::Outdated { installed } => Some(AiRuntimeStatus::unavailable(
            R::Outdated,
            format!("installed version {installed}"),
        )),
    }
}

/// The probe script: the same import path a job takes, then the self-tests.
pub fn probe_script(templates_dir: &Path, addon_dir: &Path, force_cpu: bool) -> String {
    format!(
        "import sys, json\n\
         def stage(s):\n    print('{MARKER}' + s, file=sys.stderr, flush=True)\n\
         stage('start')\n\
         sys.path.insert(0, {templates})\n\
         import ai_runtime\n\
         stage('setup')\n\
         ai_runtime.setup({addon})\n\
         stage('import')\n\
         ai_runtime.ort()\n\
         stage('session')\n\
         result = ai_runtime.self_test(force_cpu={force})\n\
         stage('frames')\n\
         result['frame'] = ai_runtime.frame_test(force_cpu={force})\n\
         print('{RESULT}' + json.dumps(result), file=sys.stderr, flush=True)\n\
         import vapoursynth as vs\n\
         vs.core.std.BlankClip(width=16, height=16, length=1).set_output()\n",
        templates = py_str(templates_dir),
        addon = py_str(addon_dir),
        force = if force_cpu { "True" } else { "False" },
    )
}

/// Turn a finished probe into a status. Pure, so every branch is testable.
pub fn classify(exit: &ProbeExit, stderr: &str) -> AiRuntimeStatus {
    use AiRuntimeReason as R;
    let result = stderr
        .lines()
        .filter_map(|l| l.trim().strip_prefix(RESULT))
        .last()
        .and_then(|j| serde_json::from_str::<serde_json::Value>(j).ok());
    if exit.success {
        if let Some(r) = result {
            let s = |k: &str| r.get(k).and_then(|v| v.as_str()).map(str::to_string);
            return AiRuntimeStatus {
                available: true,
                reason: None,
                detail: None,
                version: s("version"),
                providers: r
                    .get("providers")
                    .and_then(|v| v.as_array())
                    .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
                    .unwrap_or_default(),
                provider: s("provider"),
                fallback: s("fallback"),
            };
        }
        return AiRuntimeStatus::unavailable(R::ProbeFailed, "the self-test reported nothing".to_string());
    }
    if exit.timed_out {
        return AiRuntimeStatus::unavailable(
            R::ProbeFailed,
            format!("the test did not finish within {}s", PROBE_TIMEOUT.as_secs()),
        );
    }
    if exit.status.starts_with("signal 4 ") || exit.status.contains("illegal instruction") {
        return AiRuntimeStatus::unavailable(R::UnsupportedCpu, exit.status.clone());
    }
    let last = stderr.lines().filter_map(|l| l.trim().strip_prefix(MARKER)).last();
    let error = last_error_line(stderr);
    let or_status = |e: Option<String>| e.or_else(|| Some(format!("vspipe exited with {}", exit.status)));
    match last {
        Some("setup") if stderr.contains("is not installed") => {
            AiRuntimeStatus::unavailable(R::NotInstalled, error)
        }
        Some("import") | Some("setup")
            if stderr.contains("DLL load failed") || stderr.contains("cannot open shared object") =>
        {
            AiRuntimeStatus::unavailable(R::MissingLibrary, or_status(error))
        }
        Some("import") | Some("setup") if error.is_some() => AiRuntimeStatus::unavailable(R::ImportFailed, error),
        Some("session") | Some("frames") if error.is_some() => {
            AiRuntimeStatus::unavailable(R::SessionFailed, error)
        }
        Some("import") | Some("session") | Some("frames") => {
            AiRuntimeStatus::unavailable(R::Crashed, or_status(error))
        }
        _ => AiRuntimeStatus::unavailable(R::ProbeFailed, or_status(error)),
    }
}

/// The last line of a Python error, which names the actual failure.
fn last_error_line(stderr: &str) -> Option<String> {
    stderr
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with(MARKER) && !l.starts_with(RESULT))
        .filter(|l| l.contains("Error") || l.contains("error") || l.contains("Exception"))
        .last()
        .map(|l| l.chars().take(400).collect())
}

/// Run the probe through vspipe and classify it.
pub fn run_probe(
    vspipe: &Path,
    env: &HashMap<String, String>,
    templates_dir: &Path,
    addon_dir: &Path,
    force_cpu: bool,
) -> AiRuntimeStatus {
    let tmp = std::env::temp_dir().join(format!("vapourbox_ai_runtime_probe_{}.vpy", std::process::id()));
    if let Err(e) = std::fs::write(&tmp, probe_script(templates_dir, addon_dir, force_cpu)) {
        return AiRuntimeStatus::unavailable(
            AiRuntimeReason::ProbeFailed,
            format!("could not write the probe script: {e}"),
        );
    }
    let outcome = run_vspipe_probe(vspipe, &tmp, env, &["-s", "0", "-e", "0"], PROBE_TIMEOUT);
    let _ = std::fs::remove_file(&tmp);
    match outcome {
        Ok((exit, stderr)) => classify(&exit, &stderr),
        Err(e) => AiRuntimeStatus::unavailable(AiRuntimeReason::ProbeFailed, format!("could not run vspipe: {e}")),
    }
}

/// `VAPOURBOX_AI_FORCE_CPU=1`: run on the CPU only (also read by ai_runtime.py).
pub fn force_cpu_requested() -> bool {
    std::env::var("VAPOURBOX_AI_FORCE_CPU")
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use AiRuntimeReason as R;

    fn exit(success: bool, status: &str) -> ProbeExit {
        ProbeExit { success, timed_out: false, status: status.into() }
    }

    #[test]
    fn a_successful_probe_reports_its_provider() {
        let stderr = "AI_RUNTIME_PROBE:start\nAI_RUNTIME_PROBE:session\nAI_RUNTIME_PROBE:frames\n\
            AI_RUNTIME_RESULT:{\"version\": \"1.31.1\", \"providers\": [\"CoreMLExecutionProvider\", \
            \"CPUExecutionProvider\"], \"provider\": \"CoreMLExecutionProvider\", \"fallback\": null}\n";
        let s = classify(&exit(true, "0"), stderr);
        assert!(s.available);
        assert_eq!(s.provider.as_deref(), Some("CoreMLExecutionProvider"));
        assert_eq!(s.version.as_deref(), Some("1.31.1"));
        assert_eq!(s.providers.len(), 2);
        assert_eq!(s.fallback, None);
        assert_eq!(s.message("macos-arm64"), None);
        assert!(!classify(&exit(true, "0"), "AI_RUNTIME_PROBE:start\n").available);
    }

    #[test]
    fn failures_are_classified_by_stage() {
        let cases = [
            ("AI_RUNTIME_PROBE:setup\nRuntimeError: The AI runtime add-on is not installed (no x)", R::NotInstalled),
            ("AI_RUNTIME_PROBE:import\nImportError: DLL load failed while importing onnxruntime_pybind11_state", R::MissingLibrary),
            ("AI_RUNTIME_PROBE:import\nModuleNotFoundError: No module named 'numpy'", R::ImportFailed),
            ("AI_RUNTIME_PROBE:session\nonnxruntime.capi.onnxruntime_pybind11_state.Fail: [ONNXRuntimeError]", R::SessionFailed),
            ("AI_RUNTIME_PROBE:frames\nRuntimeError: wrong pixels", R::SessionFailed),
            ("AI_RUNTIME_PROBE:session\n", R::Crashed),
            ("", R::ProbeFailed),
        ];
        for (stderr, want) in cases {
            assert_eq!(classify(&exit(false, "exit code 1"), stderr).reason, Some(want), "{stderr}");
        }
        assert_eq!(
            classify(&exit(false, "signal 4 (SIGILL)"), "AI_RUNTIME_PROBE:import\n").reason,
            Some(R::UnsupportedCpu)
        );
        let t = ProbeExit { success: false, timed_out: true, status: "timed out".into() };
        assert_eq!(classify(&t, "").reason, Some(R::ProbeFailed));
    }

    #[test]
    fn every_reason_has_a_message() {
        for r in [
            R::UnsupportedPlatform, R::NotInstalled, R::Outdated, R::MissingLibrary, R::ImportFailed,
            R::SessionFailed, R::UnsupportedCpu, R::Crashed, R::ProbeFailed,
        ] {
            for p in addons::PLATFORMS {
                let m = AiRuntimeStatus::unavailable(r, Some("d".into())).message(p).unwrap();
                assert!(m.ends_with("Details: d"), "{m}");
            }
        }
        let m = AiRuntimeStatus::unavailable(R::NotInstalled, None).message("linux-x64").unwrap();
        assert!(m.contains("Settings → Add-ons"), "{m}");
        let j = AiRuntimeStatus::unavailable(R::NotInstalled, None).to_json("linux-x64");
        assert_eq!(j["available"], false);
        assert_eq!(j["reason"], "notInstalled");
        assert!(j["message"].as_str().unwrap().contains("not installed"));
    }

    #[test]
    fn precheck_needs_an_install() {
        let root = std::env::temp_dir().join(format!("vb-ai-precheck-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(precheck(&root, "linux-x64").unwrap().reason, Some(R::NotInstalled));
        assert_eq!(precheck(&root, "windows-arm64").unwrap().reason, Some(R::UnsupportedPlatform));
    }

    #[test]
    fn the_probe_script_uses_the_template_helper() {
        let s = probe_script(Path::new("/t"), Path::new("/a/ai-runtime"), true);
        assert!(s.contains("sys.path.insert(0, '/t')"));
        assert!(s.contains("ai_runtime.setup('/a/ai-runtime')"));
        assert!(s.contains("self_test(force_cpu=True)"));
        assert!(s.contains("frame_test(force_cpu=True)"));
        assert!(s.contains(".set_output()"));
    }
}
