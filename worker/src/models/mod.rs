//! Data models shared between the Flutter app and Rust worker.
//! These must serialize to/from JSON compatibly with the Dart equivalents.

mod video_job;
mod qtgmc_parameters;
mod progress_info;

pub use video_job::*;
pub use qtgmc_parameters::*;
pub use progress_info::*;
