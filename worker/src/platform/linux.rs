//! Linux-specific functionality.

use std::path::PathBuf;

/// Get the user's home directory.
#[allow(dead_code)]
pub fn home_dir() -> Option<PathBuf> {
    std::env::var("HOME").ok().map(PathBuf::from)
}

/// Get the application data directory (XDG_DATA_HOME/VapourBox).
#[allow(dead_code)]
pub fn app_data_dir() -> Option<PathBuf> {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        return Some(PathBuf::from(xdg).join("VapourBox"));
    }
    home_dir().map(|h| h.join(".local").join("share").join("VapourBox"))
}

/// Get the cache directory (XDG_CACHE_HOME/VapourBox).
#[allow(dead_code)]
pub fn cache_dir() -> Option<PathBuf> {
    if let Ok(xdg) = std::env::var("XDG_CACHE_HOME") {
        return Some(PathBuf::from(xdg).join("VapourBox"));
    }
    home_dir().map(|h| h.join(".cache").join("VapourBox"))
}
