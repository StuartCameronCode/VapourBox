//! Windows-specific functionality.

use std::path::PathBuf;

/// Get the user's home directory.
#[allow(dead_code)]
pub fn home_dir() -> Option<PathBuf> {
    std::env::var("USERPROFILE").ok().map(PathBuf::from)
}

/// Get the application data directory.
#[allow(dead_code)]
pub fn app_data_dir() -> Option<PathBuf> {
    std::env::var("LOCALAPPDATA")
        .ok()
        .map(|p| PathBuf::from(p).join("VapourBox"))
}

/// Get the cache directory (same as app data on Windows).
#[allow(dead_code)]
pub fn cache_dir() -> Option<PathBuf> {
    app_data_dir().map(|p| p.join("Cache"))
}
