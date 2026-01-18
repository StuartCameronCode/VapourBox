//! Locates bundled dependencies (vspipe, ffmpeg, Python, etc.)

use std::env;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};

/// Platform-specific dependency locator.
pub struct DependencyLocator {
    base_path: PathBuf,
    platform: Platform,
}

#[derive(Debug, Clone, Copy)]
pub enum Platform {
    MacOSArm64,
    MacOSX64,
    WindowsX64,
    WindowsArm64,
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
    fn find_deps_directory(exe_path: &Path) -> Result<PathBuf> {
        // On macOS, first check Application Support (where downloaded deps go)
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
            }
        }

        // Search upward from executable
        let mut current = exe_path.parent();

        while let Some(dir) = current {
            // Check for deps directory with platform subdirectory
            // This ensures we find the project deps, not Cargo's deps
            let deps_dir = dir.join("deps");
            if deps_dir.exists() {
                // Verify this has our expected structure (windows-x64 or macos-arm64, etc.)
                let has_platform_dir = deps_dir.join("windows-x64").exists()
                    || deps_dir.join("macos-arm64").exists()
                    || deps_dir.join("macos-x64").exists();
                if has_platform_dir {
                    return Ok(deps_dir);
                }
            }

            current = dir.parent();
        }

        // Fallback: Application Support on macOS, relative path otherwise
        #[cfg(target_os = "macos")]
        {
            if let Some(home) = env::var_os("HOME") {
                return Ok(PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join("VapourBox")
                    .join("deps"));
            }
        }

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

        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        compile_error!("Unsupported platform");
    }

    /// Get the platform suffix for directory names.
    pub fn platform_suffix(&self) -> &'static str {
        match self.platform {
            Platform::MacOSArm64 => "macos-arm64",
            Platform::MacOSX64 => "macos-x64",
            Platform::WindowsX64 => "windows-x64",
            Platform::WindowsArm64 => "windows-arm64",
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
            // Windows: VapourSynth portable uses VSPipe.exe
            let path = vs_dir.join("VSPipe.exe");
            if path.exists() {
                return Ok(path);
            }
            // Fallback to lowercase
            let alt = vs_dir.join("vspipe.exe");
            if alt.exists() {
                return Ok(alt);
            }
        }

        #[cfg(not(target_os = "windows"))]
        {
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
    }

    /// Get the Python path (site-packages and custom packages).
    pub fn python_path(&self) -> String {
        let platform_dir = self.platform_dir();
        let mut paths = Vec::new();

        #[cfg(target_os = "macos")]
        {
            // Custom Python packages first (always needed)
            paths.push(platform_dir.join("python-packages").to_string_lossy().to_string());

            // Add bundled Python site-packages if available
            if let Some(python_home) = self.python_home() {
                // Python 3.12 from python-build-standalone
                paths.push(python_home.join("lib").join("python3.12").join("site-packages").to_string_lossy().to_string());
                // Legacy support for other Python versions
                paths.push(python_home.join("lib").join("python3.14").join("site-packages").to_string_lossy().to_string());
                paths.push(python_home.join("lib").join("python3.11").join("site-packages").to_string_lossy().to_string());
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

        // On Windows, Python is bundled inside vapoursynth directory (already in path)

        #[cfg(target_os = "windows")]
        { paths.join(";") }

        #[cfg(not(target_os = "windows"))]
        { paths.join(":") }
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

        // Set VapourSynth plugin path
        env.insert(
            "VAPOURSYNTH_PLUGIN_PATH".to_string(),
            self.vapoursynth_plugin_path().to_string_lossy().to_string(),
        );

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
