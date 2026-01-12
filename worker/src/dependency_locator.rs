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

    /// Find the deps directory by searching upward from the executable.
    fn find_deps_directory(exe_path: &Path) -> Result<PathBuf> {
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

            // On macOS, check in Contents/ for app bundle
            #[cfg(target_os = "macos")]
            {
                let contents_deps = dir.join("Contents").join("deps");
                if contents_deps.exists() {
                    return Ok(contents_deps);
                }
            }

            current = dir.parent();
        }

        // Fallback to relative path
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

    /// Get the Python home directory.
    pub fn python_home(&self) -> PathBuf {
        let platform_dir = self.platform_dir();

        #[cfg(target_os = "macos")]
        {
            // macOS uses Python.framework
            platform_dir.join("python").join("Python.framework").join("Versions").join("Current")
        }

        #[cfg(target_os = "windows")]
        {
            // Windows: Python 3.8 is bundled inside VapourSynth portable
            platform_dir.join("vapoursynth")
        }
    }

    /// Get the Python path (site-packages and custom packages).
    pub fn python_path(&self) -> String {
        let platform_dir = self.platform_dir();
        let mut paths = Vec::new();

        #[cfg(target_os = "macos")]
        {
            // Custom Python packages first
            paths.push(platform_dir.join("python-packages").to_string_lossy().to_string());
            let python_home = self.python_home();
            paths.push(python_home.join("lib").join("python3.14").join("site-packages").to_string_lossy().to_string());
            paths.push(python_home.join("lib").join("python3.11").join("site-packages").to_string_lossy().to_string());
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
            paths.push(self.python_home().join("bin").to_string_lossy().to_string());
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

        // Set Python environment
        env.insert("PYTHONHOME".to_string(), self.python_home().to_string_lossy().to_string());
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
            // macOS library path
            let lib_path = self.platform_dir().join("vapoursynth");
            env.insert("DYLD_LIBRARY_PATH".to_string(), lib_path.to_string_lossy().to_string());
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
