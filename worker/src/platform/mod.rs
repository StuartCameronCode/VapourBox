//! Platform-specific functionality.

#[cfg(target_os = "macos")]
pub mod macos;

#[cfg(target_os = "windows")]
pub mod windows;

#[cfg(target_os = "linux")]
pub mod linux;

/// Re-export platform-specific items for the current platform.
#[cfg(target_os = "macos")]
pub use macos::*;

#[cfg(target_os = "windows")]
#[allow(unused_imports)]
pub use windows::*;

#[cfg(target_os = "linux")]
#[allow(unused_imports)]
pub use linux::*;
