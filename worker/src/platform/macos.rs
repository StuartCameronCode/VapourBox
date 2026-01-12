//! macOS-specific functionality.

use std::path::PathBuf;

/// Get the user's home directory.
pub fn home_dir() -> Option<PathBuf> {
    std::env::var("HOME").ok().map(PathBuf::from)
}

/// Get the application support directory.
pub fn app_support_dir() -> Option<PathBuf> {
    home_dir().map(|h| h.join("Library").join("Application Support").join("iDeinterlace"))
}

/// Get the cache directory.
pub fn cache_dir() -> Option<PathBuf> {
    home_dir().map(|h| h.join("Library").join("Caches").join("iDeinterlace"))
}
