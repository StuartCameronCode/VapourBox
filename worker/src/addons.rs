//! Manifest-described add-ons: optional third-party downloads (AI models, the
//! AI runtime) that VapourBox can use but never ships in the deps bundle.
//!
//! Each is described by one JSON file in `app/assets/addons/`, which the app
//! installs from (`ManifestAddonInstaller`, `app/lib/services/manifest_addon.dart`)
//! and which `build.rs` compiles in here, so both sides read the same
//! description (docs/ADDONS.md has the format). The app downloads, verifies
//! and unpacks an add-on into `<addons>/<id>/`, writing [`MARKER`] last; this
//! module only answers whether that happened for this platform and version,
//! and refuses a job that needs an add-on that isn't there, with the same kind
//! of message as `animejanai::MISSING_MESSAGE`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use serde::Deserialize;

include!(concat!(env!("OUT_DIR"), "/addon_manifests.rs"));

/// The commit marker an install ends with: `{id, version, platform}`.
pub const MARKER: &str = ".vapourbox-addon.json";

/// The AI runtime: ONNX Runtime and NumPy for the job's Python.
pub const AI_RUNTIME: &str = "ai-runtime";

/// DeepFilterNet's `deep-filter` program, for audio restoration's speech
/// enhancement (`audio_restoration.rs`).
pub const DEEPFILTERNET: &str = "deepfilternet";

/// Where in the add-ons UI to install them — named in every refusal.
const WHERE: &str = "Settings → Add-ons";

/// One file an add-on installs (the fields the worker needs).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestFile {
    pub name: String,
    #[serde(default)]
    pub platforms: Option<Vec<String>>,
    #[serde(default)]
    pub extract: Option<Vec<ArchiveMember>>,
    /// A program the worker runs: the app marks it executable on install.
    #[serde(default)]
    pub executable: bool,
}

impl ManifestFile {
    fn is_for(&self, platform: &str) -> bool {
        self.platforms.as_ref().map_or(true, |p| p.iter().any(|x| x == platform))
    }
}

/// A member kept from an archive entry.
#[derive(Debug, Clone, Deserialize)]
pub struct ArchiveMember {
    pub path: String,
    #[serde(default)]
    pub name: Option<String>,
}

impl ArchiveMember {
    fn installed_name(&self) -> &str {
        self.name.as_deref().unwrap_or_else(|| self.path.rsplit('/').next().unwrap_or(&self.path))
    }
}

/// `"all"` or a table of platform id → requirements.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
enum Platforms {
    All(String),
    Table(BTreeMap<String, serde_json::Value>),
}

/// An add-on manifest (the fields the worker needs).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub id: String,
    pub version: String,
    pub name: String,
    pub feature: String,
    pub kind: String,
    #[serde(default)]
    pub requires: Vec<String>,
    platforms: Platforms,
    pub files: Vec<ManifestFile>,
}

/// Every platform id add-ons are described for.
pub const PLATFORMS: &[&str] = &["macos-arm64", "macos-x64", "windows-x64", "linux-x64", "linux-arm64"];

impl Manifest {
    pub fn supports(&self, platform: &str) -> bool {
        match &self.platforms {
            Platforms::All(s) => s == "all" && PLATFORMS.contains(&platform),
            Platforms::Table(t) => t.contains_key(platform),
        }
    }

    /// The paths, relative to the add-on's directory, that a complete install
    /// on `platform` holds: a python add-on's `site-packages`, or a model
    /// pack's files (an archive's kept members by their installed names).
    pub fn expected_paths(&self, platform: &str) -> Vec<String> {
        if self.kind == "python" {
            return vec!["site-packages".to_string()];
        }
        let mut out = Vec::new();
        for f in self.files.iter().filter(|f| f.is_for(platform)) {
            match &f.extract {
                None => out.push(f.name.clone()),
                Some(members) => out.extend(members.iter().map(|m| m.installed_name().to_string())),
            }
        }
        out
    }
}

impl Manifest {
    /// The program this add-on installs for `platform` (the file marked
    /// `executable`), by its installed name.
    pub fn executable_for(&self, platform: &str) -> Option<&str> {
        self.files.iter().find(|f| f.executable && f.is_for(platform)).map(|f| f.name.as_str())
    }
}

/// Every compiled-in manifest, sorted by id.
pub fn manifests() -> &'static [Manifest] {
    static ALL: OnceLock<Vec<Manifest>> = OnceLock::new();
    ALL.get_or_init(|| {
        let mut v: Vec<Manifest> = MANIFESTS
            .iter()
            .map(|(file, json)| {
                serde_json::from_str(json)
                    .unwrap_or_else(|e| panic!("add-on manifest {file} does not parse: {e}"))
            })
            .collect();
        v.sort_by(|a, b| a.id.cmp(&b.id));
        v
    })
}

pub fn manifest(id: &str) -> Option<&'static Manifest> {
    manifests().iter().find(|m| m.id == id)
}

/// The add-on's directory under the add-ons directory.
pub fn addon_dir(addons_root: &Path, id: &str) -> PathBuf {
    addons_root.join(id)
}

/// A python add-on's packages directory, which the script puts on `sys.path`.
pub fn site_packages(addons_root: &Path, id: &str) -> PathBuf {
    addon_dir(addons_root, id).join("site-packages")
}

/// What is installed of one add-on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AddonState {
    Installed,
    /// Nothing, or an incomplete install.
    Missing,
    /// An install of another version (the manifest was updated since).
    Outdated { installed: String },
    /// No build of it for this platform.
    Unsupported,
    /// No manifest by that id: a bug, not a user problem.
    Unknown,
}

/// Whether `id` is installed for `platform` in `addons_root`.
pub fn state(addons_root: &Path, id: &str, platform: &str) -> AddonState {
    let Some(m) = manifest(id) else { return AddonState::Unknown };
    if !m.supports(platform) {
        return AddonState::Unsupported;
    }
    let dir = addon_dir(addons_root, id);
    let marker: Option<serde_json::Value> = std::fs::read_to_string(dir.join(MARKER))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok());
    let Some(marker) = marker else { return AddonState::Missing };
    if marker.get("id").and_then(|v| v.as_str()) != Some(id)
        || marker.get("platform").and_then(|v| v.as_str()) != Some(platform)
    {
        return AddonState::Missing;
    }
    let version = marker.get("version").and_then(|v| v.as_str()).unwrap_or("");
    if version != m.version {
        return AddonState::Outdated { installed: version.to_string() };
    }
    if m.expected_paths(platform).iter().all(|p| dir.join(p).exists()) {
        AddonState::Installed
    } else {
        AddonState::Missing
    }
}

pub fn is_installed(addons_root: &Path, id: &str, platform: &str) -> bool {
    state(addons_root, id, platform) == AddonState::Installed
}

/// The add-ons one feature of a job needs: what `ProcessingPipeline::required_addons`
/// returns, and what `ScriptGenerator` checks before writing a script.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AddonNeed {
    /// The feature as the user knows it, starting the refusal message.
    pub feature: &'static str,
    /// The add-on ids it uses (their own requirements are added automatically).
    pub ids: Vec<&'static str>,
}

/// `ids` and everything they require, requirements first, each once.
pub fn with_requirements(ids: &[&str]) -> Vec<String> {
    fn visit(id: &str, out: &mut Vec<String>) {
        if out.iter().any(|x| x == id) {
            return;
        }
        if let Some(m) = manifest(id) {
            for r in &m.requires {
                visit(r, out);
            }
        }
        out.push(id.to_string());
    }
    let mut out = Vec::new();
    for id in ids {
        visit(id, &mut out);
    }
    out
}

/// Whether a job needing `ids` needs the AI runtime (directly or through a
/// model add-on that requires it) — what decides the script's `AI_RUNTIME`
/// block.
pub fn needs_ai_runtime(ids: &[&str]) -> bool {
    with_requirements(ids).iter().any(|i| i == AI_RUNTIME)
}

/// Refuse, with a message the user can act on, unless every add-on in `ids`
/// (and everything they require) is installed. `feature` is what the user
/// chose ("Face restoration"), at the start of the message.
pub fn require(addons_root: &Path, ids: &[&str], feature: &str, platform: &str) -> anyhow::Result<()> {
    match missing_message(addons_root, ids, feature, platform) {
        None => Ok(()),
        Some(message) => anyhow::bail!("{message}"),
    }
}

/// The refusal [`require`] gives, or `None` when everything is installed.
pub fn missing_message(addons_root: &Path, ids: &[&str], feature: &str, platform: &str) -> Option<String> {
    let mut missing = Vec::new();
    let mut outdated = Vec::new();
    for id in with_requirements(ids) {
        let name = manifest(&id).map(|m| m.name.clone()).unwrap_or_else(|| id.clone());
        match state(addons_root, &id, platform) {
            AddonState::Installed => {}
            AddonState::Unknown => {
                return Some(format!("{feature} needs an add-on this version of VapourBox doesn't know (\"{id}\")."))
            }
            AddonState::Unsupported => {
                return Some(format!(
                    "{feature} needs the {name} add-on, which isn't available on this platform."
                ))
            }
            AddonState::Missing => missing.push(name),
            AddonState::Outdated { installed } => outdated.push((name, installed)),
        }
    }
    if missing.is_empty() && outdated.is_empty() {
        return None;
    }
    let mut parts = Vec::new();
    match missing.len() {
        0 => {}
        1 => parts.push(format!(
            "{feature} needs the {} add-on, which is not installed. It is a separate download: \
             install it in {WHERE}, or choose {feature} again to be offered it.",
            missing[0]
        )),
        _ => parts.push(format!(
            "{feature} needs these add-ons, which are not installed: {}. They are separate \
             downloads: install them in {WHERE}, or choose {feature} again to be offered them.",
            missing.join(", ")
        )),
    }
    for (name, installed) in outdated {
        parts.push(format!(
            "The installed {name} add-on (version {installed}) is out of date for this version \
             of VapourBox. Install it again in {WHERE}."
        ));
    }
    Some(parts.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("vb-addons-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn install(root: &Path, id: &str, version: &str, platform: &str) {
        let m = manifest(id).unwrap();
        let dir = addon_dir(root, id);
        std::fs::create_dir_all(&dir).unwrap();
        for p in m.expected_paths(platform) {
            if m.kind == "python" {
                std::fs::create_dir_all(dir.join(p)).unwrap();
            } else {
                std::fs::write(dir.join(p), b"x").unwrap();
            }
        }
        std::fs::write(
            dir.join(MARKER),
            serde_json::json!({"id": id, "version": version, "platform": platform}).to_string(),
        )
        .unwrap();
    }

    /// The compiled-in set is exactly the directory's: build.rs found them all.
    #[test]
    fn compiled_manifests_match_the_app_directory() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../app/assets/addons");
        let mut on_disk: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.ends_with(".json"))
            .collect();
        on_disk.sort();
        let compiled: Vec<String> = MANIFESTS.iter().map(|(n, _)| n.to_string()).collect();
        assert_eq!(compiled, on_disk);
        for m in manifests() {
            // One file per add-on, named after it.
            assert!(on_disk.contains(&format!("{}.json", m.id)), "{}", m.id);
            assert!(matches!(m.kind.as_str(), "files" | "python"), "{}", m.id);
            for r in &m.requires {
                assert!(manifest(r).is_some(), "{} requires unknown {r}", m.id);
            }
            for p in PLATFORMS {
                if m.supports(p) {
                    assert!(!m.expected_paths(p).is_empty(), "{} has nothing for {p}", m.id);
                }
            }
        }
        assert!(manifest(AI_RUNTIME).is_some());
    }

    #[test]
    fn ai_runtime_is_python_on_every_platform() {
        let m = manifest(AI_RUNTIME).unwrap();
        assert_eq!(m.kind, "python");
        for p in PLATFORMS {
            assert!(m.supports(p), "{p}");
            assert_eq!(m.expected_paths(p), vec!["site-packages".to_string()]);
            assert_eq!(m.files.iter().filter(|f| f.is_for(p)).count(), 2, "onnxruntime + numpy on {p}");
        }
    }

    #[test]
    fn installed_needs_the_marker_for_this_version_and_platform() {
        let root = tmp("state");
        let v = manifest(AI_RUNTIME).unwrap().version.clone();
        assert_eq!(state(&root, AI_RUNTIME, "linux-x64"), AddonState::Missing);
        // Files without the marker: an interrupted install.
        std::fs::create_dir_all(site_packages(&root, AI_RUNTIME)).unwrap();
        assert_eq!(state(&root, AI_RUNTIME, "linux-x64"), AddonState::Missing);
        install(&root, AI_RUNTIME, &v, "linux-x64");
        assert!(is_installed(&root, AI_RUNTIME, "linux-x64"));
        // Another platform's install (a copied add-ons directory) is not this one's.
        assert_eq!(state(&root, AI_RUNTIME, "linux-arm64"), AddonState::Missing);
        install(&root, AI_RUNTIME, "0.0.1", "linux-x64");
        assert_eq!(
            state(&root, AI_RUNTIME, "linux-x64"),
            AddonState::Outdated { installed: "0.0.1".into() }
        );
        assert_eq!(state(&root, "no-such-addon", "linux-x64"), AddonState::Unknown);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn require_names_the_addon_and_where_to_get_it() {
        let root = tmp("require");
        let err = require(&root, &[AI_RUNTIME], "Face restoration", "macos-arm64").unwrap_err().to_string();
        assert!(err.starts_with("Face restoration needs the AI runtime (ONNX Runtime) add-on"), "{err}");
        assert!(err.contains("Settings → Add-ons"), "{err}");
        let v = manifest(AI_RUNTIME).unwrap().version.clone();
        install(&root, AI_RUNTIME, &v, "macos-arm64");
        require(&root, &[AI_RUNTIME], "Face restoration", "macos-arm64").unwrap();
        require(&root, &[], "Nothing", "macos-arm64").unwrap();
        install(&root, AI_RUNTIME, "0.0.1", "macos-arm64");
        let err = require(&root, &[AI_RUNTIME], "Face restoration", "macos-arm64").unwrap_err().to_string();
        assert!(err.contains("out of date") && err.contains("0.0.1"), "{err}");
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// DeepFilterNet is one program per platform, each the platform's own
    /// upstream build, marked executable so the app sets the bit on install.
    #[test]
    fn deepfilternet_has_one_program_per_platform() {
        let m = manifest(DEEPFILTERNET).unwrap();
        assert_eq!(m.kind, "files");
        for p in PLATFORMS {
            assert!(m.supports(p), "{p}");
            let exe = m.executable_for(p).unwrap_or_else(|| panic!("no program for {p}"));
            assert_eq!(m.expected_paths(p), vec![exe.to_string()]);
            assert_eq!(exe.ends_with(".exe"), *p == "windows-x64", "{exe}");
        }
        // Nothing else is marked executable.
        assert!(manifest(AI_RUNTIME).unwrap().files.iter().all(|f| !f.executable));
    }

    #[test]
    fn requirements_come_first() {
        assert_eq!(with_requirements(&[AI_RUNTIME, AI_RUNTIME]), vec![AI_RUNTIME.to_string()]);
        assert!(needs_ai_runtime(&[AI_RUNTIME]));
        assert!(!needs_ai_runtime(&[]));
        for m in manifests() {
            let order = with_requirements(&[m.id.as_str()]);
            assert_eq!(order.last(), Some(&m.id));
            for r in &m.requires {
                assert!(order.iter().position(|x| x == r) < order.iter().position(|x| x == &m.id));
            }
        }
    }
}
