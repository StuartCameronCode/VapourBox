//! Integration tests for all VapourSynth filters.
//!
//! Run with: cargo test --test filter_integration_test -- --nocapture

use std::path::PathBuf;
use std::process::Command;
use uuid::Uuid;

// Import the worker's models
use vapourbox_worker::models::*;
use vapourbox_worker::script_generator::ScriptGenerator;

fn get_test_input() -> PathBuf {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    PathBuf::from(manifest_dir)
        .parent().unwrap()
        .join("Tests")
        .join("TestResources")
        .join("interlaced_test.avi")
}

fn get_output_path(name: &str) -> PathBuf {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    PathBuf::from(manifest_dir)
        .parent().unwrap()
        .join("Tests")
        .join("TestOutput")
        .join(format!("{}.avi", name))
}

fn create_output_dir() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let output_dir = PathBuf::from(manifest_dir)
        .parent().unwrap()
        .join("Tests")
        .join("TestOutput");
    std::fs::create_dir_all(&output_dir).ok();
}

fn create_base_job(output_name: &str) -> VideoJob {
    VideoJob {
        id: Uuid::new_v4(),
        input_path: get_test_input().to_string_lossy().to_string(),
        output_path: get_output_path(output_name).to_string_lossy().to_string(),
        qtgmc_parameters: QTGMCParameters::default(),
        restoration_pipeline: None,
        encoding_settings: EncodingSettings {
            codec: VideoCodec::FFV1,
            container: ContainerFormat::Avi,
            ..EncodingSettings::default()
        },
        detected_field_order: Some(FieldOrder::TopFieldFirst),
        total_frames: None,
        input_frame_rate: None,
    }
}

fn run_job(job: &VideoJob, test_name: &str) -> Result<(), String> {
    println!("\n========================================");
    println!("TEST: {}", test_name);
    println!("Output: {}", job.output_path);
    println!("========================================\n");

    // Generate the script
    let generator = ScriptGenerator::new().map_err(|e| format!("Failed to create generator: {}", e))?;
    let script_path = generator.generate(job).map_err(|e| format!("Failed to generate script: {}", e))?;

    println!("Generated script: {:?}", script_path);

    // Print the script content for debugging
    let script_content = std::fs::read_to_string(&script_path).unwrap_or_default();
    println!("--- Script Content ---\n{}\n--- End Script ---\n", script_content);

    // For now, just verify script generation works
    // Full pipeline execution would require vspipe + ffmpeg setup

    if script_content.is_empty() {
        return Err("Generated empty script".to_string());
    }

    println!("Script generated successfully for: {}", test_name);
    Ok(())
}

#[test]
fn test_01_deinterlace_only_fast() {
    create_output_dir();

    let mut job = create_base_job("test_01_deinterlace_fast");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Fast,
        tff: Some(true),
        fps_divisor: 2,
        opencl: false,
        ..QTGMCParameters::default()
    };
    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..RestorationPipeline::default()
    });

    run_job(&job, "Deinterlace Only (Fast preset)").unwrap();
}

#[test]
fn test_02_deinterlace_only_medium() {
    create_output_dir();

    let mut job = create_base_job("test_02_deinterlace_medium");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Medium,
        tff: Some(true),
        fps_divisor: 1, // Double rate
        source_match: 1,
        opencl: false,
        ..QTGMCParameters::default()
    };
    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..RestorationPipeline::default()
    });

    run_job(&job, "Deinterlace Only (Medium preset, double rate)").unwrap();
}

#[test]
fn test_03_deinterlace_only_slow() {
    create_output_dir();

    let mut job = create_base_job("test_03_deinterlace_slow");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Slow,
        tff: Some(true),
        fps_divisor: 2,
        source_match: 2,
        sharpness: Some(0.5),
        opencl: false,
        ..QTGMCParameters::default()
    };
    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..RestorationPipeline::default()
    });

    run_job(&job, "Deinterlace Only (Slow preset, source match)").unwrap();
}

#[test]
fn test_04_noise_reduction_smdegrain_light() {
    create_output_dir();

    let mut job = create_base_job("test_04_nr_smdegrain_light");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            preset: NoiseReductionPreset::Light,
            method: NoiseReductionMethod::SmDegrain,
            sm_degrain_tr: 2,
            sm_degrain_th_sad: 200,
            sm_degrain_th_sadc: 100,
            sm_degrain_refine: true,
            sm_degrain_prefilter: 2,
            ..NoiseReductionParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Noise Reduction - SMDegrain Light").unwrap();
}

#[test]
fn test_05_noise_reduction_smdegrain_heavy() {
    create_output_dir();

    let mut job = create_base_job("test_05_nr_smdegrain_heavy");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            preset: NoiseReductionPreset::Heavy,
            method: NoiseReductionMethod::SmDegrain,
            sm_degrain_tr: 3,
            sm_degrain_th_sad: 400,
            sm_degrain_th_sadc: 200,
            sm_degrain_refine: true,
            sm_degrain_prefilter: 3,
            ..NoiseReductionParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Noise Reduction - SMDegrain Heavy").unwrap();
}

#[test]
fn test_06_noise_reduction_mctemporal() {
    create_output_dir();

    let mut job = create_base_job("test_06_nr_mctemporal");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            preset: NoiseReductionPreset::Moderate,
            method: NoiseReductionMethod::McTemporalDenoise,
            mc_temporal_sigma: 4.0,
            mc_temporal_radius: 2,
            ..NoiseReductionParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Noise Reduction - MCTemporalDenoise").unwrap();
}

#[test]
fn test_07_color_correction_brightness_contrast() {
    create_output_dir();

    let mut job = create_base_job("test_07_color_brightness_contrast");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        color_correction: ColorCorrectionParameters {
            enabled: true,
            brightness: 10.0,
            contrast: 1.1,
            saturation: 1.0,
            hue: 0.0,
            ..ColorCorrectionParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Color Correction - Brightness/Contrast").unwrap();
}

#[test]
fn test_08_color_correction_saturation() {
    create_output_dir();

    let mut job = create_base_job("test_08_color_saturation");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        color_correction: ColorCorrectionParameters {
            enabled: true,
            brightness: 0.0,
            contrast: 1.0,
            saturation: 1.2,
            hue: 0.0,
            ..ColorCorrectionParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Color Correction - Saturation Boost").unwrap();
}

#[test]
fn test_09_color_correction_levels() {
    create_output_dir();

    let mut job = create_base_job("test_09_color_levels");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        color_correction: ColorCorrectionParameters {
            enabled: true,
            apply_levels: true,
            input_low: 16,
            input_high: 235,
            output_low: 0,
            output_high: 255,
            gamma: 1.0,
            ..ColorCorrectionParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Color Correction - Levels (TV to PC range)").unwrap();
}

#[test]
fn test_10_chroma_fix_bleeding() {
    create_output_dir();

    let mut job = create_base_job("test_10_chroma_bleeding");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_chroma_bleeding_fix: true,
            chroma_bleed_cx: 4,
            chroma_bleed_cy: 4,
            chroma_bleed_c_blur: 0.7,
            chroma_bleed_strength: 1.0,
            ..ChromaFixParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Chroma Fix - Bleeding Fix").unwrap();
}

#[test]
fn test_11_chroma_fix_decrawl() {
    create_output_dir();

    let mut job = create_base_job("test_11_chroma_decrawl");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_de_crawl: true,
            de_crawl_y_thresh: 10,
            de_crawl_c_thresh: 10,
            de_crawl_max_diff: 50,
            ..ChromaFixParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Chroma Fix - DeCrawl").unwrap();
}

#[test]
fn test_12_chroma_fix_vinverse() {
    create_output_dir();

    let mut job = create_base_job("test_12_chroma_vinverse");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_vinverse: true,
            vinverse_sstr: 2.7,
            vinverse_amnt: 255,
            vinverse_scl: 12,
            ..ChromaFixParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Chroma Fix - Vinverse").unwrap();
}

#[test]
fn test_13_crop_overscan() {
    create_output_dir();

    let mut job = create_base_job("test_13_crop_overscan");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        crop_resize: CropResizeParameters {
            enabled: true,
            crop_enabled: true,
            crop_left: 8,
            crop_right: 8,
            crop_top: 8,
            crop_bottom: 8,
            ..CropResizeParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Crop - Remove Overscan (8px each side)").unwrap();
}

#[test]
fn test_14_resize_720p() {
    create_output_dir();

    let mut job = create_base_job("test_14_resize_720p");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        crop_resize: CropResizeParameters {
            enabled: true,
            resize_enabled: true,
            target_width: Some(1280),
            target_height: Some(720),
            kernel: ResizeKernel::Spline36,
            maintain_aspect: true,
            ..CropResizeParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Resize - 720p Spline36").unwrap();
}

#[test]
fn test_15_resize_lanczos() {
    create_output_dir();

    let mut job = create_base_job("test_15_resize_lanczos");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        crop_resize: CropResizeParameters {
            enabled: true,
            resize_enabled: true,
            target_width: Some(1920),
            target_height: Some(1080),
            kernel: ResizeKernel::Lanczos,
            maintain_aspect: true,
            ..CropResizeParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Resize - 1080p Lanczos").unwrap();
}

#[test]
fn test_16_upscale_nnedi3_2x() {
    create_output_dir();

    let mut job = create_base_job("test_16_upscale_nnedi3_2x");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        crop_resize: CropResizeParameters {
            enabled: true,
            use_integer_upscale: true,
            upscale_method: UpscaleMethod::Nnedi3Rpow2,
            upscale_factor: 2,
            ..CropResizeParameters::default()
        },
        ..RestorationPipeline::default()
    });

    run_job(&job, "Upscale - NNEDI3 2x").unwrap();
}

#[test]
fn test_17_codec_ffv1() {
    create_output_dir();

    let mut job = create_base_job("test_17_codec_ffv1");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);
    job.encoding_settings.codec = VideoCodec::FFV1;
    job.encoding_settings.container = ContainerFormat::Avi;

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..RestorationPipeline::default()
    });

    run_job(&job, "Codec - FFV1 (Lossless)").unwrap();
}

#[test]
fn test_18_codec_h264() {
    create_output_dir();

    let mut job = create_base_job("test_18_codec_h264");
    job.output_path = get_output_path("test_18_codec_h264").to_string_lossy().replace(".avi", ".mp4");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);
    job.encoding_settings.codec = VideoCodec::H264;
    job.encoding_settings.container = ContainerFormat::Mp4;
    job.encoding_settings.quality = 18;

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..RestorationPipeline::default()
    });

    run_job(&job, "Codec - H.264 CRF 18").unwrap();
}

#[test]
fn test_19_codec_h265() {
    create_output_dir();

    let mut job = create_base_job("test_19_codec_h265");
    job.output_path = get_output_path("test_19_codec_h265").to_string_lossy().replace(".avi", ".mp4");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);
    job.encoding_settings.codec = VideoCodec::H265;
    job.encoding_settings.container = ContainerFormat::Mp4;
    job.encoding_settings.quality = 20;

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..RestorationPipeline::default()
    });

    run_job(&job, "Codec - H.265 CRF 20").unwrap();
}

#[test]
fn test_20_combined_all_filters() {
    create_output_dir();

    let mut job = create_base_job("test_20_combined_all");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Medium,
        tff: Some(true),
        fps_divisor: 2,
        source_match: 1,
        sharpness: Some(0.3),
        opencl: false,
        ..QTGMCParameters::default()
    };

    job.restoration_pipeline = Some(RestorationPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::SmDegrain,
            sm_degrain_tr: 2,
            sm_degrain_th_sad: 250,
            sm_degrain_th_sadc: 125,
            sm_degrain_refine: true,
            sm_degrain_prefilter: 2,
            ..NoiseReductionParameters::default()
        },
        color_correction: ColorCorrectionParameters {
            enabled: true,
            brightness: 5.0,
            contrast: 1.05,
            saturation: 1.1,
            ..ColorCorrectionParameters::default()
        },
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_chroma_bleeding_fix: true,
            chroma_bleed_cx: 4,
            chroma_bleed_cy: 4,
            chroma_bleed_c_blur: 0.7,
            chroma_bleed_strength: 0.8,
            apply_vinverse: true,
            vinverse_sstr: 2.0,
            vinverse_amnt: 200,
            vinverse_scl: 12,
            ..ChromaFixParameters::default()
        },
        crop_resize: CropResizeParameters {
            enabled: true,
            crop_enabled: true,
            crop_left: 4,
            crop_right: 4,
            crop_top: 4,
            crop_bottom: 4,
            resize_enabled: true,
            target_width: Some(1280),
            target_height: Some(720),
            kernel: ResizeKernel::Spline36,
            maintain_aspect: true,
            ..CropResizeParameters::default()
        },
    });

    run_job(&job, "Combined - All Filters Active").unwrap();
}
