//! VapourBox Worker Library
//!
//! Provides video processing functionality using VapourSynth.

pub mod models;
pub mod comment_metadata;
pub mod crop_detect;
pub mod cpu;
pub mod dependency_locator;
pub mod dvd_reader;
pub mod filter_registry;
pub mod filter_schema;
pub mod pipeline_executor;
pub mod pixel_format;
pub mod source_decode;
pub mod source_timing;
pub mod progress_reporter;
pub mod addons;
pub mod audio_restoration;
pub mod ai_runtime;
pub mod animejanai;
pub mod upscale_addons;
pub mod gpu_plugin;
pub mod hdr_metadata;
pub mod native_res;
pub mod noise_halo;
pub mod schema_script_generator;
pub mod script_generator;
pub mod subtitle_generator;
pub mod platform;
