//! Locates bundled dependencies (vspipe, ffmpeg, Python, etc.)

use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;

use anyhow::{bail, Context, Result};

/// Platform-specific dependency locator.
pub struct DependencyLocator {
    base_path: PathBuf,
    platform: Platform,
}

#[derive(Debug, Clone, Copy)]
#[allow(dead_code)]
pub enum Platform {
    MacOSArm64,
    MacOSX64,
    WindowsX64,
    WindowsArm64,
    LinuxX64,
    LinuxArm64,
}

impl DependencyLocator {
    /// Create a new dependency locator.
    pub fn new() -> Result<Self> {
        let exe_path = env::current_exe().context("Failed to get executable path")?;
        let base_path = Self::find_deps_directory(&exe_path)?;
        let platform = Self::detect_platform();

        Ok(Self { base_path, platform })
    }

    /// Find the deps directory by searching various locations.
    fn find_deps_directory(#[allow(unused)] exe_path: &Path) -> Result<PathBuf> {
        // Development only (macOS/Windows): search upward from executable for project deps.
        // This is restricted to debug builds for security - release builds
        // should only check known production paths.
        // Linux always uses the production path since deps are built/downloaded
        // separately and installed to ~/.local/share/VapourBox/deps/.
        #[cfg(all(debug_assertions, not(target_os = "linux")))]
        {
            let mut current = exe_path.parent();
            while let Some(dir) = current {
                let deps_dir = dir.join("deps");
                if deps_dir.exists() {
                    // Verify this has our expected structure (windows-x64 or macos-arm64, etc.)
                    // to distinguish from Cargo's deps folder.
                    let has_platform_dir = deps_dir.join("windows-x64").exists()
                        || deps_dir.join("macos-arm64").exists()
                        || deps_dir.join("macos-x64").exists();
                    if has_platform_dir {
                        return Ok(deps_dir);
                    }
                }
                current = dir.parent();
            }
        }

        // Windows production: deps folder next to executable
        #[cfg(target_os = "windows")]
        {
            let exe_dir = exe_path.parent().unwrap_or(Path::new("."));
            let deps_dir = exe_dir.join("deps");
            if deps_dir.join("windows-x64").exists() {
                return Ok(deps_dir);
            }
        }

        // macOS production: Application Support (where downloaded deps go)
        #[cfg(target_os = "macos")]
        {
            if let Some(home) = env::var_os("HOME") {
                let app_support_deps = PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join("VapourBox")
                    .join("deps");
                if app_support_deps.join("macos-arm64").exists()
                    || app_support_deps.join("macos-x64").exists() {
                    return Ok(app_support_deps);
                }
                // Fallback to Application Support path (will be created when deps download)
                return Ok(app_support_deps);
            }
        }

        // Linux production: XDG_DATA_HOME or ~/.local/share (where downloaded deps go)
        #[cfg(target_os = "linux")]
        {
            let data_dir = if let Ok(xdg) = env::var("XDG_DATA_HOME") {
                PathBuf::from(xdg).join("VapourBox").join("deps")
            } else if let Some(home) = env::var_os("HOME") {
                PathBuf::from(home)
                    .join(".local")
                    .join("share")
                    .join("VapourBox")
                    .join("deps")
            } else {
                PathBuf::from("deps")
            };
            if data_dir.join("linux-x64").exists()
                || data_dir.join("linux-arm64").exists() {
                return Ok(data_dir);
            }
            // Fallback to XDG path (will be created when deps download)
            return Ok(data_dir);
        }

        #[allow(unreachable_code)]
        Ok(PathBuf::from("deps"))
    }

    /// Detect the current platform.
    fn detect_platform() -> Platform {
        #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
        return Platform::MacOSArm64;

        #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
        return Platform::MacOSX64;

        #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
        return Platform::WindowsX64;

        #[cfg(all(target_os = "windows", target_arch = "aarch64"))]
        return Platform::WindowsArm64;

        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        return Platform::LinuxX64;

        #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
        return Platform::LinuxArm64;

        #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
        compile_error!("Unsupported platform");
    }

    /// Get the platform suffix for directory names.
    pub fn platform_suffix(&self) -> &'static str {
        match self.platform {
            Platform::MacOSArm64 => "macos-arm64",
            Platform::MacOSX64 => "macos-x64",
            Platform::WindowsX64 => "windows-x64",
            Platform::WindowsArm64 => "windows-arm64",
            Platform::LinuxX64 => "linux-x64",
            Platform::LinuxArm64 => "linux-arm64",
        }
    }

    /// Get the platform-specific deps directory.
    fn platform_dir(&self) -> PathBuf {
        self.base_path.join(self.platform_suffix())
    }

    /// Get the path to vspipe executable.
    pub fn vspipe_path(&self) -> Result<PathBuf> {
        let vs_dir = self.platform_dir().join("vapoursynth");

        #[cfg(target_os = "windows")]
        {
            // R78 ships Windows as a Python wheel, so vspipe.exe lives inside
            // the installed package next to libvapoursynth.dll rather than at
            // the root of the portable directory.
            let path = vs_dir
                .join("Lib")
                .join("site-packages")
                .join("vapoursynth")
                .join("vspipe.exe");
            if path.exists() {
                return Ok(path);
            }
            // Pre-R78 layouts kept it at the top level.
            for legacy in ["VSPipe.exe", "vspipe.exe"] {
                let alt = vs_dir.join(legacy);
                if alt.exists() {
                    return Ok(alt);
                }
            }
        }

        #[cfg(not(target_os = "windows"))]
        {
            // Prefer vspipe-bin directly over the wrapper script.
            // The wrapper is a bash script that spawns vspipe-bin as a child;
            // killing the wrapper leaves vspipe-bin orphaned (zombie on cancel).
            // By calling vspipe-bin directly, kill() works as expected.
            // The environment setup that the wrapper does is handled by
            // build_environment() instead.
            let bin_path = vs_dir.join("vspipe-bin");
            if bin_path.exists() {
                return Ok(bin_path);
            }
            let path = vs_dir.join("vspipe");
            if path.exists() {
                return Ok(path);
            }
        }

        // Try system PATH as last resort
        if let Ok(system_path) = which::which("vspipe") {
            return Ok(system_path);
        }

        bail!("vspipe not found in {:?}", vs_dir);
    }

    /// Whether a usable OpenCL device is available for the GPU NNEDI3CL path.
    ///
    /// Headless/VM/remote-desktop environments often have no OpenCL device, so
    /// NNEDI3CL fails at runtime ("Invalid Value"). We detect this by actually
    /// running NNEDI3CL through vspipe once, and cache the result keyed by the
    /// system **boot time** — GPU availability can change across boots (and we
    /// don't want to pay the probe on every interactive preview), but re-probing
    /// each boot keeps it current without a stale forever-cache. The
    /// `VAPOURBOX_DISABLE_OPENCL=1` env var forces a negative result (escape
    /// hatch for the remote-desktop-into-a-running-machine case, and for CI).
    pub fn opencl_available(&self) -> bool {
        static CACHE: OnceLock<bool> = OnceLock::new();
        *CACHE.get_or_init(|| self.compute_opencl_available())
    }

    fn compute_opencl_available(&self) -> bool {
        if env::var("VAPOURBOX_DISABLE_OPENCL")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false)
        {
            return false;
        }

        let boot = Self::boot_token();
        let cache_file = self.platform_dir().join("opencl-probe.json");

        // Reuse a cached result only if it was recorded during this boot.
        if !boot.is_empty() {
            if let Ok(txt) = std::fs::read_to_string(&cache_file) {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&txt) {
                    let cached_boot = json.get("boot").and_then(|v| v.as_str());
                    let cached = json.get("opencl").and_then(|v| v.as_bool());
                    if cached_boot == Some(boot.as_str()) {
                        if let Some(b) = cached {
                            return b;
                        }
                    }
                }
            }
        }

        let result = self.probe_opencl();
        let _ = std::fs::write(
            &cache_file,
            serde_json::json!({ "boot": boot, "opencl": result }).to_string(),
        );
        result
    }

    /// Whether the `knlm.KNLMeansCL` denoiser can actually run here.
    ///
    /// This is a SEPARATE capability from [`opencl_available`]: KNLMeansCL needs
    /// both the plugin to be bundled AND a usable OpenCL device, and it
    /// enumerates devices differently from NNEDI3CL — empirically NNEDI3CL can
    /// succeed while KNLMeansCL fails with `CL_INVALID_VALUE` on the same machine
    /// (e.g. Apple Silicon). So we probe KNLMeansCL directly rather than reusing
    /// the NNEDI3CL probe. Cached by boot time like [`opencl_available`].
    pub fn knlm_available(&self) -> bool {
        static CACHE: OnceLock<bool> = OnceLock::new();
        *CACHE.get_or_init(|| self.compute_knlm_available())
    }

    fn compute_knlm_available(&self) -> bool {
        // KNLMeansCL is OpenCL-only, so the disable switch applies here too.
        if env::var("VAPOURBOX_DISABLE_OPENCL")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false)
        {
            return false;
        }

        let boot = Self::boot_token();
        let cache_file = self.platform_dir().join("knlm-probe.json");

        if !boot.is_empty() {
            if let Ok(txt) = std::fs::read_to_string(&cache_file) {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&txt) {
                    let cached_boot = json.get("boot").and_then(|v| v.as_str());
                    let cached = json.get("knlm").and_then(|v| v.as_bool());
                    if cached_boot == Some(boot.as_str()) {
                        if let Some(b) = cached {
                            return b;
                        }
                    }
                }
            }
        }

        let result = self.probe_knlm();
        let _ = std::fs::write(
            &cache_file,
            serde_json::json!({ "boot": boot, "knlm": result }).to_string(),
        );
        result
    }

    /// Run KNLMeansCL through vspipe on a tiny clip; success ⇒ knlmeanscl usable
    /// (plugin present AND a usable OpenCL device).
    fn probe_knlm(&self) -> bool {
        let vspipe = match self.vspipe_path() {
            Ok(p) => p,
            Err(_) => return false,
        };
        let script = "import vapoursynth as vs\n\
                      core = vs.core\n\
                      clip = core.std.BlankClip(width=256, height=256, format=vs.YUV420P8, length=1)\n\
                      clip = core.knlm.KNLMeansCL(clip, d=0, h=1.0)\n\
                      clip.set_output()\n";
        let tmp = env::temp_dir().join(format!("vapourbox_knlm_probe_{}.vpy", std::process::id()));
        if std::fs::write(&tmp, script).is_err() {
            return false;
        }
        // `-e 0` processes frame 0 only, which forces KNLMeansCL to init OpenCL.
        let out = Command::new(&vspipe)
            .args(["-e", "0", tmp.to_string_lossy().as_ref(), "-"])
            .envs(self.build_environment())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .output();
        let _ = std::fs::remove_file(&tmp);
        matches!(out, Ok(o) if o.status.success())
    }

    /// Run NNEDI3CL through vspipe on a tiny clip; success ⇒ OpenCL usable.
    fn probe_opencl(&self) -> bool {
        let vspipe = match self.vspipe_path() {
            Ok(p) => p,
            Err(_) => return false,
        };
        let script = "import vapoursynth as vs\n\
                      core = vs.core\n\
                      clip = core.std.BlankClip(width=256, height=256, format=vs.YUV420P8, length=1)\n\
                      clip = core.nnedi3cl.NNEDI3CL(clip, field=1)\n\
                      clip.set_output()\n";
        let tmp = env::temp_dir().join(format!("vapourbox_opencl_probe_{}.vpy", std::process::id()));
        if std::fs::write(&tmp, script).is_err() {
            return false;
        }
        // `-e 0` processes frame 0 only, which forces NNEDI3CL to init OpenCL.
        let out = Command::new(&vspipe)
            .args(["-e", "0", tmp.to_string_lossy().as_ref(), "-"])
            .envs(self.build_environment())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .output();
        let _ = std::fs::remove_file(&tmp);
        matches!(out, Ok(o) if o.status.success())
    }

    /// A token that is stable within a boot and changes across reboots. Empty
    /// if it can't be determined (then we don't reuse the disk cache).
    fn boot_token() -> String {
        #[cfg(target_os = "macos")]
        {
            if let Ok(out) = Command::new("sysctl").args(["-n", "kern.boottime"]).output() {
                if out.status.success() {
                    return String::from_utf8_lossy(&out.stdout).trim().to_string();
                }
            }
        }
        #[cfg(target_os = "linux")]
        {
            if let Ok(stat) = std::fs::read_to_string("/proc/stat") {
                for line in stat.lines() {
                    if let Some(rest) = line.strip_prefix("btime ") {
                        return rest.trim().to_string();
                    }
                }
            }
        }
        #[cfg(target_os = "windows")]
        {
            if let Ok(out) = Command::new("powershell")
                .args([
                    "-NoProfile",
                    "-Command",
                    "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc()",
                ])
                .output()
            {
                if out.status.success() {
                    return String::from_utf8_lossy(&out.stdout).trim().to_string();
                }
            }
        }
        String::new()
    }

    /// Count the decodable video frames in `input` via ffprobe. Returns None if
    /// ffprobe is unavailable or the count can't be determined. Uses
    /// `-count_frames` (decodes) for an accurate count that matches what the
    /// decoder will actually pipe — header `nb_frames` is often wrong for AVI /
    /// lossless codecs (e.g. our lagarith test clip reports 79 but decodes 75).
    pub fn probe_frame_count(&self, input: &str) -> Option<i32> {
        let ffprobe = self.ffprobe_path().ok()?;
        let out = Command::new(&ffprobe)
            .args([
                "-v", "error",
                "-select_streams", "v:0",
                "-count_frames",
                "-show_entries", "stream=nb_read_frames",
                "-of", "default=nokey=1:noprint_wrappers=1",
                input,
            ])
            .envs(self.build_environment())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse::<i32>()
            .ok()
            .filter(|&n| n > 0)
    }

    /// Get the path to ffmpeg executable.
    pub fn ffmpeg_path(&self) -> Result<PathBuf> {
        let exe_name = if cfg!(windows) { "ffmpeg.exe" } else { "ffmpeg" };
        let path = self.platform_dir().join("ffmpeg").join(exe_name);

        if !path.exists() {
            // Try system PATH as last resort
            if let Ok(system_path) = which::which("ffmpeg") {
                return Ok(system_path);
            }

            bail!("ffmpeg not found at {:?}", path);
        }

        Ok(path)
    }

    /// Get the path to ffprobe executable.
    #[allow(dead_code)]
    pub fn ffprobe_path(&self) -> Result<PathBuf> {
        let exe_name = if cfg!(windows) { "ffprobe.exe" } else { "ffprobe" };
        let path = self.platform_dir().join("ffmpeg").join(exe_name);

        if !path.exists() {
            // Try system PATH as last resort
            if let Ok(system_path) = which::which("ffprobe") {
                return Ok(system_path);
            }

            bail!("ffprobe not found at {:?}", path);
        }

        Ok(path)
    }

    /// Get the Python home directory, or None if Python is not bundled.
    pub fn python_home(&self) -> Option<PathBuf> {
        let platform_dir = self.platform_dir();

        #[cfg(target_os = "macos")]
        {
            // macOS: Check for python-build-standalone embedded Python
            let python_dir = platform_dir.join("python");
            if python_dir.join("bin").join("python3.12").exists() {
                return Some(python_dir);
            }
            // Legacy: Check if Python.framework is bundled
            let python_framework = python_dir.join("Python.framework").join("Versions").join("Current");
            if python_framework.exists() {
                return Some(python_framework);
            }
            // Development mode: no bundled Python, use system Python
            None
        }

        #[cfg(target_os = "windows")]
        {
            // Windows: Python 3.8 is bundled inside VapourSynth portable
            Some(platform_dir.join("vapoursynth"))
        }

        #[cfg(target_os = "linux")]
        {
            // Linux: python-build-standalone, same layout as macOS
            let python_dir = platform_dir.join("python");
            if python_dir.join("bin").join("python3.12").exists() {
                return Some(python_dir);
            }
            None
        }
    }

    /// Get the Python path (site-packages and custom packages).
    pub fn python_path(&self) -> String {
        let platform_dir = self.platform_dir();
        let mut paths = Vec::new();

        #[cfg(target_os = "macos")]
        {
            // Custom Python packages first (always needed)
            paths.push(platform_dir.join("python-packages").to_string_lossy().to_string());

            // R78 ships VapourSynth as a Python package: libvapoursynth,
            // libvapoursynthfilters, libvsscript and the extension module all
            // live in <deps>/vapoursynth/. Putting the platform directory on
            // the path is what makes `import vapoursynth` resolve to it, and
            // it is also what lets `vapoursynth config` record the same
            // libvsscript path that vspipe-bin loads — the config is keyed by
            // that absolute path, so a mismatch means "Python executable and
            // library path couldn't be determined".
            paths.push(platform_dir.to_string_lossy().to_string());

            // Add bundled Python site-packages if available
            if let Some(python_home) = self.python_home() {
                // Python 3.12 from python-build-standalone
                paths.push(python_home.join("lib").join("python3.12").join("site-packages").to_string_lossy().to_string());
                // Legacy support for other Python versions
                paths.push(python_home.join("lib").join("python3.14").join("site-packages").to_string_lossy().to_string());
                paths.push(python_home.join("lib").join("python3.11").join("site-packages").to_string_lossy().to_string());
            }
        }

        #[cfg(target_os = "linux")]
        {
            // Linux: same layout as macOS
            paths.push(platform_dir.join("python-packages").to_string_lossy().to_string());

            // R78 ships VapourSynth as a Python package: libvapoursynth,
            // libvapoursynthfilters, libvsscript and the extension module all
            // live in <deps>/vapoursynth/. Putting the platform directory on
            // the path is what makes `import vapoursynth` resolve to it, and
            // it is also what lets `vapoursynth config` record the same
            // libvsscript path that vspipe-bin loads — the config is keyed by
            // that absolute path, so a mismatch means "Python executable and
            // library path couldn't be determined".
            paths.push(platform_dir.to_string_lossy().to_string());

            if let Some(python_home) = self.python_home() {
                paths.push(python_home.join("lib").join("python3.12").join("site-packages").to_string_lossy().to_string());
            }
        }

        #[cfg(target_os = "windows")]
        {
            // Windows: site-packages is inside VapourSynth directory
            paths.push(platform_dir.join("vapoursynth").join("Lib").join("site-packages").to_string_lossy().to_string());
        }

        #[cfg(target_os = "windows")]
        { paths.join(";") }

        #[cfg(not(target_os = "windows"))]
        { paths.join(":") }
    }

    /// Get the VapourSynth plugins directory.
    pub fn vapoursynth_plugin_path(&self) -> PathBuf {
        #[cfg(target_os = "windows")]
        {
            // Windows uses vs-plugins for clarity
            self.platform_dir().join("vapoursynth").join("vs-plugins")
        }

        #[cfg(not(target_os = "windows"))]
        {
            self.platform_dir().join("vapoursynth").join("plugins")
        }
    }

    /// Get the NNEDI3CL weights path.
    pub fn nnedi3cl_weights_path(&self) -> PathBuf {
        #[cfg(target_os = "windows")]
        {
            // Windows: weights are in the plugins directory
            self.vapoursynth_plugin_path().join("nnedi3_weights.bin")
        }

        #[cfg(not(target_os = "windows"))]
        {
            self.platform_dir().join("resources").join("NNEDI3CL").join("nnedi3_weights.bin")
        }
    }

    /// Get the bin directory (for PATH).
    pub fn bin_path(&self) -> String {
        let platform_dir = self.platform_dir();
        let mut paths = Vec::new();

        paths.push(platform_dir.join("ffmpeg").to_string_lossy().to_string());
        paths.push(platform_dir.join("vapoursynth").to_string_lossy().to_string());

        #[cfg(target_os = "macos")]
        {
            // Add bundled Python bin if available
            if let Some(python_home) = self.python_home() {
                paths.push(python_home.join("bin").to_string_lossy().to_string());
            }
        }

        #[cfg(target_os = "linux")]
        {
            // Add bundled Python bin if available (same as macOS)
            if let Some(python_home) = self.python_home() {
                paths.push(python_home.join("bin").to_string_lossy().to_string());
            }
        }

        // On Windows, Python is bundled inside vapoursynth directory (already in path)

        #[cfg(target_os = "windows")]
        { paths.join(";") }

        #[cfg(not(target_os = "windows"))]
        { paths.join(":") }
    }

    /// Get the addons directory path.
    pub fn addons_dir(&self) -> PathBuf {
        // Addons are stored as a sibling of deps:
        // Debug: search upward from exe for addons/ dir
        // Release macOS: ~/Library/Application Support/VapourBox/addons/
        // Release Windows: <exe-dir>/addons/
        #[cfg(debug_assertions)]
        {
            if let Ok(exe_path) = env::current_exe() {
                let mut current = exe_path.parent();
                while let Some(dir) = current {
                    let addons_dir = dir.join("addons");
                    if addons_dir.exists() {
                        return addons_dir;
                    }
                    current = dir.parent();
                }
            }
        }

        #[cfg(target_os = "windows")]
        {
            if let Ok(exe_path) = env::current_exe() {
                let exe_dir = exe_path.parent().unwrap_or(Path::new("."));
                return exe_dir.join("addons");
            }
        }

        #[cfg(target_os = "macos")]
        {
            if let Some(home) = env::var_os("HOME") {
                return PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join("VapourBox")
                    .join("addons");
            }
        }

        #[cfg(target_os = "linux")]
        {
            if let Ok(xdg) = env::var("XDG_DATA_HOME") {
                return PathBuf::from(xdg).join("VapourBox").join("addons");
            }
            if let Some(home) = env::var_os("HOME") {
                return PathBuf::from(home)
                    .join(".local")
                    .join("share")
                    .join("VapourBox")
                    .join("addons");
            }
        }

        PathBuf::from("addons")
    }

    /// Get the path to the libdvdread shared library.
    pub fn dvdread_library_path(&self) -> PathBuf {
        let platform_dir = self.platform_dir();

        #[cfg(target_os = "macos")]
        {
            platform_dir.join("lib").join("libdvdread.dylib")
        }

        #[cfg(target_os = "windows")]
        {
            platform_dir.join("lib").join("dvdread.dll")
        }

        #[cfg(target_os = "linux")]
        {
            platform_dir.join("lib").join("libdvdread.so")
        }
    }

    /// Get the path to the whisper-cli executable.
    ///
    /// macOS: addons/whisper/bin/whisper-cli (Homebrew bottle layout)
    /// Windows: addons/whisper/whisper-cli.exe (flat zip layout)
    pub fn whisper_path(&self) -> Result<PathBuf> {
        let path = if cfg!(windows) {
            self.addons_dir().join("whisper").join("whisper-cli.exe")
        } else {
            self.addons_dir().join("whisper").join("bin").join("whisper-cli")
        };
        if path.exists() {
            Ok(path)
        } else {
            bail!("whisper-cli not found at {:?}", path)
        }
    }

    /// Get the path to a whisper model file.
    pub fn whisper_model_path(&self, model: &str) -> Result<PathBuf> {
        let path = self
            .addons_dir()
            .join("whisper")
            .join("models")
            .join(format!("ggml-{}.bin", model));
        if path.exists() {
            Ok(path)
        } else {
            bail!("Whisper model '{}' not found at {:?}", model, path)
        }
    }

    /// Build environment variables for running vspipe/ffmpeg.
    pub fn build_environment(&self) -> std::collections::HashMap<String, String> {
        let mut env = std::collections::HashMap::new();

        // Clear problematic variables
        env.insert("PYTHONNOUSERSITE".to_string(), "1".to_string());

        // Set Python environment (only PYTHONHOME if Python is bundled)
        if let Some(python_home) = self.python_home() {
            env.insert("PYTHONHOME".to_string(), python_home.to_string_lossy().to_string());
        }
        env.insert("PYTHONPATH".to_string(), self.python_path());

        // Set VapourSynth plugin path.
        //
        // On macOS and Linux the plugins sit at <deps>/vapoursynth/plugins,
        // which is <libdir>/plugins relative to libvapoursynth, so R78
        // autoloads them and setting this as well would load every plugin
        // twice ("Plugin ... already loaded"). Windows keeps it: its plugins
        // live in vs-plugins, which is not the autoload directory.
        #[cfg(target_os = "windows")]
        env.insert(
            "VAPOURSYNTH_EXTRA_PLUGIN_PATH".to_string(),
            self.vapoursynth_plugin_path().to_string_lossy().to_string(),
        );

        // vsscript resolves the Python library through a config file keyed by
        // the libvsscript path, and writes it on first use by shelling out to
        // a `vapoursynth` executable. Give it a writable location inside the
        // deps tree and make sure the bundled python/bin (which carries that
        // shim) is reachable.
        #[cfg(not(target_os = "windows"))]
        {
            env.insert(
                "XDG_CONFIG_HOME".to_string(),
                self.platform_dir().join("config").to_string_lossy().to_string(),
            );
            let _ = std::fs::create_dir_all(self.platform_dir().join("config"));
        }

        // Set NNEDI3CL weights
        env.insert(
            "NNEDI3CL_WEIGHTS_PATH".to_string(),
            self.nnedi3cl_weights_path().to_string_lossy().to_string(),
        );

        // Set PATH
        let existing_path = std::env::var("PATH").unwrap_or_default();
        let new_path = format!(
            "{}{}{}",
            self.bin_path(),
            if cfg!(windows) { ";" } else { ":" },
            existing_path
        );
        env.insert("PATH".to_string(), new_path);

        #[cfg(target_os = "macos")]
        {
            // macOS library path for VapourSynth and Python
            let vs_lib_path = self.platform_dir().join("vapoursynth");
            let python_lib_path = self.platform_dir().join("python").join("lib");
            let existing_dyld = std::env::var("DYLD_LIBRARY_PATH").unwrap_or_default();
            let new_dyld = if existing_dyld.is_empty() {
                format!("{}:{}", vs_lib_path.to_string_lossy(), python_lib_path.to_string_lossy())
            } else {
                format!("{}:{}:{}", vs_lib_path.to_string_lossy(), python_lib_path.to_string_lossy(), existing_dyld)
            };
            env.insert("DYLD_LIBRARY_PATH".to_string(), new_dyld);

            // Point vspipe-bin at the bundled plugins. R74 removed the config
            // file mechanism (UserPluginDir / AutoloadUserPluginDir /
            // VAPOURSYNTH_CONF_PATH) in favour of this variable, which also
            // retires the per-process conf file we used to write: there is no
            // longer a shared file for concurrent runs to race on.
            let plugins_dir = vs_lib_path.join("plugins");
            env.insert(
                "VAPOURSYNTH_EXTRA_PLUGIN_PATH".to_string(),
                plugins_dir.to_string_lossy().to_string(),
            );
        }

        #[cfg(target_os = "linux")]
        {
            // Linux library path for VapourSynth and Python
            let vs_lib_path = self.platform_dir().join("vapoursynth");
            let python_lib_path = self.platform_dir().join("python").join("lib");
            let extra_lib_path = self.platform_dir().join("lib");
            let existing_ld = std::env::var("LD_LIBRARY_PATH").unwrap_or_default();
            let new_ld = if existing_ld.is_empty() {
                format!(
                    "{}:{}:{}",
                    vs_lib_path.to_string_lossy(),
                    python_lib_path.to_string_lossy(),
                    extra_lib_path.to_string_lossy()
                )
            } else {
                format!(
                    "{}:{}:{}:{}",
                    vs_lib_path.to_string_lossy(),
                    python_lib_path.to_string_lossy(),
                    extra_lib_path.to_string_lossy(),
                    existing_ld
                )
            };
            env.insert("LD_LIBRARY_PATH".to_string(), new_ld);

            // Bundled plugin path (same as macOS)
            let plugins_dir = vs_lib_path.join("plugins");
            env.insert(
                "VAPOURSYNTH_EXTRA_PLUGIN_PATH".to_string(),
                plugins_dir.to_string_lossy().to_string(),
            );
        }

        env
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_platform_suffix() {
        let locator = DependencyLocator {
            base_path: PathBuf::from("deps"),
            platform: Platform::WindowsX64,
        };
        assert_eq!(locator.platform_suffix(), "windows-x64");
    }
}
