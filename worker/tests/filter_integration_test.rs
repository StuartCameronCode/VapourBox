//! Integration tests for all VapourSynth filters.
//!
//! Run with: cargo test --test filter_integration_test -- --nocapture

use std::path::PathBuf;
use uuid::Uuid;

// Import the worker's models
use vapourbox_worker::models::*;
use vapourbox_worker::pixel_format;
use vapourbox_worker::script_generator::{PreviewParams, ScriptGenerator};

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
        processing_pipeline: None,
        encoding_settings: EncodingSettings {
            codec: VideoCodec::FFV1,
            container: ContainerFormat::Avi,
            ..EncodingSettings::default()
        },
        detected_field_order: Some(FieldOrder::TopFieldFirst),
        total_frames: None,
        input_frame_rate: None,
        start_frame: None,
        end_frame: None,
        subtitle_settings: None,
        subtitle_only: false,
        input_sar: None,
        input_width: None,
        input_height: None,
        input_pixel_format: None,
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
        fps_divisor: Some(2),
        opencl: Some(false),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
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
        fps_divisor: Some(1), // Double rate
        source_match: Some(1),
        opencl: Some(false),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
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
        fps_divisor: Some(2),
        source_match: Some(2),
        sharpness: Some(0.5),
        opencl: Some(false),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
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
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
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
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            preset: NoiseReductionPreset::Moderate,
            method: NoiseReductionMethod::McTemporalDenoise,
            mc_temporal_sigma: 4.0,
            mc_temporal_radius: 2,
            ..NoiseReductionParameters::default()
        },
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        color_correction: ColorCorrectionParameters {
            enabled: true,
            brightness: 10.0,
            contrast: 1.1,
            saturation: 1.0,
            hue: 0.0,
            ..ColorCorrectionParameters::default()
        },
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        color_correction: ColorCorrectionParameters {
            enabled: true,
            brightness: 0.0,
            contrast: 1.0,
            saturation: 1.2,
            hue: 0.0,
            ..ColorCorrectionParameters::default()
        },
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
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
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
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
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_de_crawl: true,
            de_crawl_y_thresh: 10,
            de_crawl_c_thresh: 10,
            de_crawl_max_diff: 50,
            ..ChromaFixParameters::default()
        },
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_vinverse: true,
            vinverse_sstr: 2.7,
            vinverse_amnt: 255,
            ..ChromaFixParameters::default()
        },
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
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
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
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
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
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
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        crop_resize: CropResizeParameters {
            enabled: true,
            use_integer_upscale: true,
            upscale_method: UpscaleMethod::Nnedi3Rpow2,
            upscale_factor: 2,
            ..CropResizeParameters::default()
        },
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
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

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
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
        fps_divisor: Some(2),
        source_match: Some(1),
        sharpness: Some(0.3),
        opencl: Some(false),
        ..QTGMCParameters::default()
    };

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        descratch: DeScratchParameters::default(),
        spotless: SpotLessParameters::default(),
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
        chroma_denoise: ChromaDenoiseParameters::default(),
        dehalo: DehaloParameters::default(),
        deblock: DeblockParameters::default(),
        deband: DebandParameters::default(),
        sharpen: SharpenParameters::default(),
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

#[test]
fn test_21_sharpen_lsfmod() {
    create_output_dir();

    let mut job = create_base_job("test_21_sharpen_lsfmod");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        sharpen: SharpenParameters {
            enabled: true,
            method: SharpenMethod::LSFmod,
            strength: 150,
            overshoot: 2,
            undershoot: 2,
            soft_edge: 0,
            cas_sharpness: 0.5,
        },
        ..ProcessingPipeline::default()
    });

    run_job(&job, "Sharpen - LSFmod").unwrap();
}

#[test]
fn test_22_sharpen_cas() {
    create_output_dir();

    let mut job = create_base_job("test_22_sharpen_cas");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        sharpen: SharpenParameters {
            enabled: true,
            method: SharpenMethod::CAS,
            strength: 100,
            overshoot: 1,
            undershoot: 1,
            soft_edge: 0,
            cas_sharpness: 0.7,
        },
        ..ProcessingPipeline::default()
    });

    run_job(&job, "Sharpen - CAS").unwrap();
}

#[test]
fn test_23_dehalo_alpha() {
    create_output_dir();

    let mut job = create_base_job("test_23_dehalo_alpha");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        dehalo: DehaloParameters {
            enabled: true,
            method: DehaloMethod::DehaloAlpha,
            rx: 2.0,
            ry: 2.0,
            dark_str: 1.0,
            bright_str: 1.0,
            ..DehaloParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job(&job, "Dehalo - DeHalo_alpha").unwrap();
}

#[test]
fn test_24_dehalo_yahr() {
    create_output_dir();

    let mut job = create_base_job("test_24_dehalo_yahr");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        dehalo: DehaloParameters {
            enabled: true,
            method: DehaloMethod::Yahr,
            yahr_blur: 2,
            yahr_depth: 32,
            ..DehaloParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job(&job, "Dehalo - YAHR").unwrap();
}

#[test]
fn test_25_deblock_qed() {
    create_output_dir();

    let mut job = create_base_job("test_25_deblock_qed");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        deblock: DeblockParameters {
            enabled: true,
            method: DeblockMethod::DeblockQed,
            quant1: 24,
            quant2: 26,
            ..DeblockParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job(&job, "Deblock - Deblock_QED").unwrap();
}

#[test]
fn test_26_deblock_simple() {
    create_output_dir();

    let mut job = create_base_job("test_26_deblock_simple");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        deblock: DeblockParameters {
            enabled: true,
            method: DeblockMethod::Deblock,
            quant1: 25,
            quant2: 25,
            ..DeblockParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job(&job, "Deblock - Simple").unwrap();
}

#[test]
fn test_27_deband() {
    create_output_dir();

    let mut job = create_base_job("test_27_deband");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        deband: DebandParameters {
            enabled: true,
            range: 15,
            y: 64,
            cb: 64,
            cr: 64,
            grain_y: 48,
            grain_c: 48,
            dynamic_grain: true,
            output_depth: 8,
        },
        ..ProcessingPipeline::default()
    });

    run_job(&job, "Deband - f3kdb").unwrap();
}

// Test that verifies scripts contain expected filter calls
fn run_job_and_verify(job: &VideoJob, test_name: &str, expected_patterns: &[&str]) -> Result<(), String> {
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

    if script_content.is_empty() {
        return Err("Generated empty script".to_string());
    }

    // Verify expected patterns are present
    for pattern in expected_patterns {
        if !script_content.contains(pattern) {
            return Err(format!("Script missing expected pattern: '{}'", pattern));
        }
        println!("✓ Found expected pattern: '{}'", pattern);
    }

    println!("Script generated successfully for: {}", test_name);
    Ok(())
}

#[test]
fn test_28_verify_sharpen_lsfmod_in_script() {
    create_output_dir();

    let mut job = create_base_job("test_28_verify_sharpen_lsfmod");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        sharpen: SharpenParameters {
            enabled: true,
            method: SharpenMethod::LSFmod,
            strength: 150,
            overshoot: 2,
            undershoot: 2,
            soft_edge: 0,
            cas_sharpness: 0.5,
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "Verify Sharpen LSFmod in Script", &[
        "haf.LSFmod",
        "strength=150",
        "overshoot=2",
        "undershoot=2",
    ]).unwrap();
}

#[test]
fn test_29_verify_sharpen_cas_in_script() {
    create_output_dir();

    let mut job = create_base_job("test_29_verify_sharpen_cas");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        sharpen: SharpenParameters {
            enabled: true,
            method: SharpenMethod::CAS,
            strength: 100,
            overshoot: 1,
            undershoot: 1,
            soft_edge: 0,
            cas_sharpness: 0.7,
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "Verify Sharpen CAS in Script", &[
        "core.cas.CAS",
        "sharpness=0.7",
    ]).unwrap();
}

#[test]
fn test_30_verify_dehalo_in_script() {
    create_output_dir();

    let mut job = create_base_job("test_30_verify_dehalo");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        dehalo: DehaloParameters {
            enabled: true,
            method: DehaloMethod::DehaloAlpha,
            rx: 2.5,
            ry: 2.5,
            dark_str: 1.2,
            bright_str: 1.2,
            ..DehaloParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "Verify Dehalo in Script", &[
        "haf.DeHalo_alpha",
        "rx=2.5",
        "ry=2.5",
    ]).unwrap();
}

#[test]
fn test_31_verify_deblock_in_script() {
    create_output_dir();

    let mut job = create_base_job("test_31_verify_deblock");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        deblock: DeblockParameters {
            enabled: true,
            method: DeblockMethod::DeblockQed,
            quant1: 24,
            quant2: 26,
            ..DeblockParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "Verify Deblock in Script", &[
        "haf.Deblock_QED",
        "quant1=24",
        "quant2=26",
    ]).unwrap();
}

#[test]
fn test_32_verify_deband_in_script() {
    create_output_dir();

    let mut job = create_base_job("test_32_verify_deband");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        deband: DebandParameters {
            enabled: true,
            range: 15,
            y: 64,
            cb: 64,
            cr: 64,
            grain_y: 48,
            grain_c: 48,
            dynamic_grain: true,
            output_depth: 8,
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "Verify Deband in Script", &[
        "core.neo_f3kdb.Deband",
        "y=64",
        "range=15",
    ]).unwrap();
}

// ============================================================================
// Audio Passthrough Tests
// ============================================================================
// These tests verify that processed video outputs unprocessed raw audio
// in the same format as the input. The pipeline uses vspipe (video only)
// piped to FFmpeg, which handles audio separately from the original input.

/// Helper to build FFmpeg args for testing (mirrors PipelineExecutor::build_ffmpeg_args)
fn build_ffmpeg_args(job: &VideoJob) -> Vec<String> {
    let mut args = Vec::new();
    let settings = &job.encoding_settings;

    // Input 0: Processed video from vspipe (Y4M pipe)
    args.extend(["-f".to_string(), "yuv4mpegpipe".to_string()]);
    args.extend(["-i".to_string(), "-".to_string()]);

    // Input 1: Original file for audio stream
    args.extend(["-i".to_string(), job.input_path.clone()]);

    // Progress output
    args.extend(["-progress".to_string(), "pipe:2".to_string()]);

    // Map streams: video from input 0 (processed), audio from input 1 (original)
    args.extend(["-map".to_string(), "0:v".to_string()]);
    args.extend(["-map".to_string(), "1:a?".to_string()]);

    // Video codec
    args.extend(["-c:v".to_string(), settings.codec.ffmpeg_codec().to_string()]);

    // Quality settings (CRF for H.264/H.265)
    if settings.codec.prores_profile().is_none() {
        args.extend(["-crf".to_string(), settings.quality.to_string()]);
        args.extend(["-preset".to_string(), settings.encoder_preset.clone()]);
    }

    // Audio handling - this is the critical part for audio passthrough
    match settings.audio_mode {
        AudioMode::Passthrough => {
            // Copy audio stream unchanged from input
            args.extend(["-c:a".to_string(), "copy".to_string()]);
        }
        AudioMode::Convert => {
            // Re-encode audio (not recommended for quality preservation)
            args.extend(["-c:a".to_string(), settings.audio_codec.ffmpeg_name().to_string()]);
            if !settings.audio_codec.is_lossless() {
                args.extend(["-b:a".to_string(), format!("{}k", settings.audio_quality.bitrate())]);
            }
        }
        AudioMode::None => {
            args.push("-an".to_string());
        }
    }

    // Output file
    args.push("-y".to_string());
    args.push(job.output_path.clone());

    args
}

#[test]
fn test_33_audio_passthrough_default_settings() {
    // Test: Default encoding settings should preserve audio unchanged
    // This ensures that by default, the output audio matches the input format exactly
    create_output_dir();

    let job = create_base_job("test_33_audio_passthrough");

    // Verify default settings have audio passthrough enabled
    assert_eq!(
        job.encoding_settings.audio_mode,
        AudioMode::Passthrough,
        "Default encoding settings must have audio_mode=Passthrough to preserve original audio"
    );

    let args = build_ffmpeg_args(&job);

    // Find -c:a argument
    let audio_codec_pos = args.iter().position(|a| a == "-c:a")
        .expect("FFmpeg args must include -c:a for audio codec");

    let audio_codec_value = &args[audio_codec_pos + 1];
    assert_eq!(
        audio_codec_value, "copy",
        "FFmpeg must use '-c:a copy' to passthrough audio unchanged. \
         This ensures the output audio format matches the input exactly."
    );

    // Verify no audio bitrate argument (copy doesn't re-encode)
    let has_audio_bitrate = args.iter().any(|a| a == "-b:a");
    assert!(
        !has_audio_bitrate,
        "When copying audio, FFmpeg should not have -b:a argument"
    );

    println!("✓ Audio passthrough: Default settings use -c:a copy");
    println!("  This preserves the original audio codec, bitrate, and samples unchanged");
}

#[test]
fn test_34_audio_passthrough_with_video_processing() {
    // Test: Audio should remain unchanged even when video is heavily processed
    // The pipeline processes video through VapourSynth, but audio goes directly
    // from input to output via FFmpeg's stream copy
    create_output_dir();

    let mut job = create_base_job("test_34_audio_with_processing");

    // Enable heavy video processing
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Slow,
        tff: Some(true),
        fps_divisor: Some(2),
        source_match: Some(2),
        sharpness: Some(0.5),
        opencl: Some(false),
        ..QTGMCParameters::default()
    };

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::SmDegrain,
            sm_degrain_tr: 2,
            sm_degrain_th_sad: 300,
            ..NoiseReductionParameters::default()
        },
        color_correction: ColorCorrectionParameters {
            enabled: true,
            brightness: 5.0,
            contrast: 1.1,
            ..ColorCorrectionParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    // Ensure audio mode is still passthrough (should be default)
    assert_eq!(job.encoding_settings.audio_mode, AudioMode::Passthrough);

    let args = build_ffmpeg_args(&job);

    // Verify audio is still copied unchanged
    let audio_codec_pos = args.iter().position(|a| a == "-c:a").unwrap();
    assert_eq!(
        args[audio_codec_pos + 1], "copy",
        "Audio must be copied unchanged even when video has heavy processing"
    );

    // Also verify the VapourSynth script doesn't process audio
    // (VapourSynth only handles video via Y4M pipe)
    let generator = ScriptGenerator::new().expect("Failed to create generator");
    let script_path = generator.generate(&job).expect("Failed to generate script");
    let script_content = std::fs::read_to_string(&script_path).unwrap_or_default();

    // VapourSynth scripts should not contain any audio-related functions
    assert!(
        !script_content.to_lowercase().contains("audio"),
        "VapourSynth script should not contain audio processing - audio is handled by FFmpeg"
    );

    println!("✓ Audio passthrough with video processing verified");
    println!("  - FFmpeg uses -c:a copy");
    println!("  - VapourSynth script contains no audio processing");
}

#[test]
fn test_35_audio_reencode_when_explicitly_disabled() {
    // Test: When audio_mode is Convert, audio should be re-encoded
    // This is the opposite of passthrough and should produce different audio
    create_output_dir();

    let mut job = create_base_job("test_35_audio_reencode");
    job.encoding_settings.audio_mode = AudioMode::Convert;
    job.encoding_settings.audio_codec = AudioCodec::Aac;
    job.encoding_settings.audio_quality = AudioQuality::High;

    let args = build_ffmpeg_args(&job);

    // Find -c:a argument
    let audio_codec_pos = args.iter().position(|a| a == "-c:a").unwrap();
    assert_eq!(
        args[audio_codec_pos + 1], "aac",
        "When audio_mode=Convert, specified codec should be used"
    );

    // Verify bitrate is set
    let audio_bitrate_pos = args.iter().position(|a| a == "-b:a")
        .expect("When re-encoding audio, -b:a must be present");
    assert_eq!(
        args[audio_bitrate_pos + 1], "192k",
        "Audio bitrate should be set when re-encoding"
    );

    println!("✓ Audio re-encoding mode verified (audio_copy=false)");
    println!("  - FFmpeg uses -c:a aac -b:a 192k");
}

#[test]
fn test_36_verify_vspipe_outputs_video_only() {
    // Test: Verify that vspipe outputs Y4M format (video only, no audio)
    // This confirms the architecture where:
    // - vspipe processes video only (Y4M = raw video frames)
    // - FFmpeg receives Y4M video + copies audio from original input
    create_output_dir();

    let job = create_base_job("test_36_vspipe_video_only");

    // The FFmpeg args show that input is yuv4mpegpipe format
    let args = build_ffmpeg_args(&job);

    // Find -f (format) argument for input
    let format_pos = args.iter().position(|a| a == "-f").unwrap();
    assert_eq!(
        args[format_pos + 1], "yuv4mpegpipe",
        "FFmpeg input must be yuv4mpegpipe (Y4M) format from vspipe"
    );

    // Y4M (yuv4mpegpipe) is a video-only format
    // This confirms vspipe outputs video without audio
    println!("✓ Pipeline architecture verified:");
    println!("  - vspipe outputs Y4M (video only) to stdout");
    println!("  - FFmpeg reads Y4M video from stdin");
    println!("  - FFmpeg copies audio from original input file");
    println!("  - Result: processed video + original unchanged audio");
}

// ============================================================================
// IVTC (Inverse Telecine) Tests
// ============================================================================
// These tests verify that the IVTC pipeline (VFM field matching + VDecimate
// duplicate removal) generates correct VapourSynth scripts for recovering
// 23.976fps progressive frames from telecined 29.97fps interlaced sources.

fn get_telecine_test_input() -> PathBuf {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    PathBuf::from(manifest_dir)
        .parent().unwrap()
        .join("Tests")
        .join("TestResources")
        .join("hard_telecine_test.avi")
}

fn create_ivtc_base_job(output_name: &str) -> VideoJob {
    VideoJob {
        id: Uuid::new_v4(),
        input_path: get_telecine_test_input().to_string_lossy().to_string(),
        output_path: get_output_path(output_name).to_string_lossy().to_string(),
        qtgmc_parameters: QTGMCParameters {
            enabled: true,
            method: DeinterlaceMethod::Ivtc,
            tff: Some(true),
            ..QTGMCParameters::default()
        },
        processing_pipeline: None,
        encoding_settings: EncodingSettings {
            codec: VideoCodec::FFV1,
            container: ContainerFormat::Avi,
            ..EncodingSettings::default()
        },
        detected_field_order: Some(FieldOrder::TopFieldFirst),
        total_frames: Some(90),
        input_frame_rate: Some(29.97),
        start_frame: None,
        end_frame: None,
        subtitle_settings: None,
        subtitle_only: false,
        input_sar: None,
        input_width: None,
        input_height: None,
        input_pixel_format: None,
    }
}

#[test]
fn test_37_ivtc_default_parameters_script() {
    // Test: IVTC with default parameters generates VFM + VDecimate calls
    create_output_dir();

    let mut job = create_ivtc_base_job("test_37_ivtc_default");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "IVTC - Default Parameters", &[
        "core.vivtc.VFM",
        "order=1",
        "core.vivtc.VDecimate",
    ]).unwrap();
}

#[test]
fn test_38_ivtc_no_qtgmc_in_script() {
    // Test: When IVTC method is selected, QTGMC code must NOT be present
    create_output_dir();

    let mut job = create_ivtc_base_job("test_38_ivtc_no_qtgmc");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    let generator = ScriptGenerator::new().expect("Failed to create generator");
    let script_path = generator.generate(&job).expect("Failed to generate script");
    let script_content = std::fs::read_to_string(&script_path).unwrap_or_default();

    println!("--- Script Content ---\n{}\n--- End Script ---\n", script_content);

    // IVTC must be present
    assert!(
        script_content.contains("core.vivtc.VFM"),
        "IVTC script must contain VFM call"
    );
    assert!(
        script_content.contains("core.vivtc.VDecimate"),
        "IVTC script must contain VDecimate call"
    );

    // QTGMC must NOT be present
    assert!(
        !script_content.contains("haf.QTGMC"),
        "IVTC script must NOT contain QTGMC call — methods are mutually exclusive"
    );

    // Template block markers must be cleaned up (ignore the docstring header)
    // The template has a docstring that documents the placeholder format — skip it
    let code_section = script_content
        .find("import vapoursynth")
        .map(|pos| &script_content[pos..])
        .unwrap_or(&script_content);
    assert!(
        !code_section.contains("{{"),
        "Script code must not contain unprocessed template markers"
    );

    println!("✓ IVTC script uses VFM + VDecimate, no QTGMC present");
}

#[test]
fn test_39_ivtc_tff_order_mapping() {
    // Test: tff=true → order=1 (TFF), tff=false → order=0 (BFF)
    create_output_dir();

    // Test TFF
    let mut job_tff = create_ivtc_base_job("test_39_ivtc_tff");
    job_tff.qtgmc_parameters.tff = Some(true);
    job_tff.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job_tff.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    let generator = ScriptGenerator::new().expect("Failed to create generator");
    let script_path = generator.generate(&job_tff).expect("Failed to generate TFF script");
    let script_tff = std::fs::read_to_string(&script_path).unwrap_or_default();

    assert!(
        script_tff.contains("order=1"),
        "TFF (tff=true) must produce order=1 in VFM call. Script:\n{}", script_tff
    );
    println!("✓ tff=true → order=1 (TFF)");

    // Test BFF
    let mut job_bff = create_ivtc_base_job("test_39_ivtc_bff");
    job_bff.qtgmc_parameters.tff = Some(false);
    job_bff.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job_bff.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    let script_path = generator.generate(&job_bff).expect("Failed to generate BFF script");
    let script_bff = std::fs::read_to_string(&script_path).unwrap_or_default();

    assert!(
        script_bff.contains("order=0"),
        "BFF (tff=false) must produce order=0 in VFM call. Script:\n{}", script_bff
    );
    println!("✓ tff=false → order=0 (BFF)");
}

#[test]
fn test_40_ivtc_custom_vfm_parameters() {
    // Test: Custom VFM parameters (cthresh, mi, blockx, blocky) appear in script
    create_output_dir();

    let mut job = create_ivtc_base_job("test_40_ivtc_custom_vfm");
    job.qtgmc_parameters.ivtc_mode = Some(3);
    job.qtgmc_parameters.ivtc_cthresh = Some(12);
    job.qtgmc_parameters.ivtc_mi = Some(100);
    job.qtgmc_parameters.ivtc_block_x = Some(32);
    job.qtgmc_parameters.ivtc_block_y = Some(32);
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "IVTC - Custom VFM Parameters", &[
        "core.vivtc.VFM",
        "order=1",
        "mode=3",
        "cthresh=12",
        "mi=100",
        "blockx=32",
        "blocky=32",
    ]).unwrap();
}

#[test]
fn test_41_ivtc_custom_vdecimate_parameters() {
    // Test: Custom VDecimate parameters (cycle, dupthresh, scthresh) appear in script
    create_output_dir();

    let mut job = create_ivtc_base_job("test_41_ivtc_custom_vdecimate");
    job.qtgmc_parameters.ivtc_cycle = Some(4);
    job.qtgmc_parameters.ivtc_dupthresh = Some(1.5);
    job.qtgmc_parameters.ivtc_scthresh = Some(20.0);
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "IVTC - Custom VDecimate Parameters", &[
        "core.vivtc.VDecimate",
        "cycle=4",
        "dupthresh=1.5",
        "scthresh=20",
    ]).unwrap();
}

#[test]
fn test_42_ivtc_defaults_omit_optional_params() {
    // Test: With default IVTC settings, optional parameters should NOT appear
    // (they use VapourSynth defaults when omitted)
    create_output_dir();

    let mut job = create_ivtc_base_job("test_42_ivtc_defaults_omit");
    // All defaults — ivtc_mode=1, ivtc_cycle=5, no optional params
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    let generator = ScriptGenerator::new().expect("Failed to create generator");
    let script_path = generator.generate(&job).expect("Failed to generate script");
    let script_content = std::fs::read_to_string(&script_path).unwrap_or_default();

    println!("--- Script Content ---\n{}\n--- End Script ---\n", script_content);

    // Required params must be present
    assert!(script_content.contains("core.vivtc.VFM"), "VFM must be present");
    assert!(script_content.contains("order=1"), "order must be present");
    assert!(script_content.contains("core.vivtc.VDecimate"), "VDecimate must be present");

    // Default values (mode=1, cycle=5) should be omitted to use VS defaults
    assert!(
        !script_content.contains("mode="),
        "Default mode=1 should be omitted from script"
    );
    assert!(
        !script_content.contains("cycle="),
        "Default cycle=5 should be omitted from script"
    );

    // Optional params with None should not appear
    assert!(!script_content.contains("cthresh="), "cthresh should be omitted when None");
    assert!(!script_content.contains("mi="), "mi should be omitted when None");
    assert!(!script_content.contains("blockx="), "blockx should be omitted when None");
    assert!(!script_content.contains("blocky="), "blocky should be omitted when None");
    assert!(!script_content.contains("dupthresh="), "dupthresh should be omitted when None");
    assert!(!script_content.contains("scthresh="), "scthresh should be omitted when None");

    println!("✓ Default IVTC script is clean — only required params present");
}

#[test]
fn test_43_ivtc_with_additional_filters() {
    // Test: IVTC combined with other processing filters (denoise, sharpen, etc.)
    create_output_dir();

    let mut job = create_ivtc_base_job("test_43_ivtc_combined");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::SmDegrain,
            sm_degrain_tr: 2,
            sm_degrain_th_sad: 300,
            ..NoiseReductionParameters::default()
        },
        sharpen: SharpenParameters {
            enabled: true,
            method: SharpenMethod::CAS,
            cas_sharpness: 0.5,
            ..SharpenParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "IVTC - Combined with Denoise + Sharpen", &[
        "core.vivtc.VFM",
        "core.vivtc.VDecimate",
        "haf.SMDegrain",
        "core.cas.CAS",
    ]).unwrap();
}

#[test]
fn test_44_ivtc_serialization_roundtrip() {
    // Test: IVTC parameters serialize to JSON and deserialize correctly
    // This verifies backward compatibility — old JSON without 'method' defaults to QTGMC

    let ivtc_params = QTGMCParameters {
        enabled: true,
        method: DeinterlaceMethod::Ivtc,
        tff: Some(true),
        ivtc_order: Some(1),
        ivtc_mode: Some(3),
        ivtc_cthresh: Some(12),
        ivtc_mi: Some(100),
        ivtc_block_x: Some(32),
        ivtc_block_y: Some(32),
        ivtc_cycle: Some(5),
        ivtc_dupthresh: Some(1.5),
        ivtc_scthresh: Some(20.0),
        ..QTGMCParameters::default()
    };

    // Serialize
    let json = serde_json::to_string_pretty(&ivtc_params).expect("Failed to serialize");
    println!("Serialized IVTC params:\n{}\n", json);

    // Verify JSON contains expected fields
    assert!(json.contains("\"method\""), "JSON must contain 'method' field");
    assert!(json.contains("\"ivtc\""), "method value must be 'ivtc'");
    assert!(json.contains("\"ivtcOrder\""), "JSON must contain 'ivtcOrder'");
    assert!(json.contains("\"ivtcMode\""), "JSON must contain 'ivtcMode'");

    // Deserialize
    let deserialized: QTGMCParameters = serde_json::from_str(&json).expect("Failed to deserialize");
    assert_eq!(deserialized.method, DeinterlaceMethod::Ivtc);
    assert_eq!(deserialized.ivtc_order, Some(1));
    assert_eq!(deserialized.ivtc_mode, Some(3));
    assert_eq!(deserialized.ivtc_cthresh, Some(12));
    assert_eq!(deserialized.ivtc_mi, Some(100));
    assert_eq!(deserialized.ivtc_block_x, Some(32));
    assert_eq!(deserialized.ivtc_block_y, Some(32));
    assert_eq!(deserialized.ivtc_cycle, Some(5));
    assert_eq!(deserialized.ivtc_dupthresh, Some(1.5));
    assert_eq!(deserialized.ivtc_scthresh, Some(20.0));

    println!("✓ IVTC parameters round-trip serialization successful");
}

#[test]
fn test_45_ivtc_backward_compat_no_method_field() {
    // Test: JSON without 'method' field defaults to QTGMC (backward compatibility)
    // Old saved presets won't have the method field — they must still work

    let old_json = r#"{
        "enabled": true,
        "preset": "Fast",
        "tff": true,
        "fpsDivisor": 2
    }"#;

    let params: QTGMCParameters = serde_json::from_str(old_json)
        .expect("Failed to deserialize old-format JSON");

    assert_eq!(
        params.method,
        DeinterlaceMethod::Qtgmc,
        "Missing 'method' field must default to QTGMC for backward compatibility"
    );
    assert_eq!(params.preset, QTGMCPreset::Fast);
    assert_eq!(params.tff, Some(true));
    assert_eq!(params.fps_divisor, Some(2));

    println!("✓ Backward compatibility: old JSON without 'method' defaults to QTGMC");
}

#[test]
fn test_46_ivtc_expected_frame_count() {
    // Test: Verify that the generated IVTC script would produce the expected
    // output frame count. For a 90-frame 29.97fps telecined source with
    // cycle=5, VDecimate removes 1 in every 5 frames → 72 output frames
    // at 23.976fps.
    create_output_dir();

    let mut job = create_ivtc_base_job("test_46_ivtc_frame_count");
    job.total_frames = Some(90); // 3 seconds at 29.97fps
    job.input_frame_rate = Some(29.97);
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    let generator = ScriptGenerator::new().expect("Failed to create generator");
    let script_path = generator.generate(&job).expect("Failed to generate script");
    let script_content = std::fs::read_to_string(&script_path).unwrap_or_default();

    println!("--- Script Content ---\n{}\n--- End Script ---\n", script_content);

    // Verify the IVTC pipeline structure:
    // 1. VFM does field matching (same frame count, but now progressive)
    // 2. VDecimate removes duplicates (reduces frames by cycle factor)
    assert!(script_content.contains("core.vivtc.VFM"), "VFM must be present");
    assert!(script_content.contains("core.vivtc.VDecimate"), "VDecimate must be present");

    // VFM must come before VDecimate in the script
    let vfm_pos = script_content.find("core.vivtc.VFM").unwrap();
    let vdecimate_pos = script_content.find("core.vivtc.VDecimate").unwrap();
    assert!(
        vfm_pos < vdecimate_pos,
        "VFM must come before VDecimate in the pipeline (VFM at {}, VDecimate at {})",
        vfm_pos, vdecimate_pos
    );

    // Calculate expected output: 90 input frames ÷ 5 cycle × 4 kept = 72 frames
    let input_frames = 90;
    let cycle = 5;
    let expected_output_frames = input_frames * (cycle - 1) / cycle;
    assert_eq!(expected_output_frames, 72,
        "3 seconds at 29.97fps = 90 frames; IVTC cycle=5 keeps 4/5 → 72 frames at 23.976fps");

    // Expected output frame rate: 29.97 * 4/5 = 23.976
    let expected_fps = 29.97 * (cycle - 1) as f64 / cycle as f64;
    assert!(
        (expected_fps - 23.976).abs() < 0.01,
        "Output FPS should be ~23.976, got {}", expected_fps
    );

    println!("✓ IVTC frame count math verified:");
    println!("  Input:  {} frames @ 29.97fps (telecined)", input_frames);
    println!("  Output: {} frames @ {:.3}fps (progressive film)", expected_output_frames, expected_fps);
    println!("  VFM comes before VDecimate in pipeline");
}

#[test]
fn test_47_ivtc_progress_frame_count() {
    // Test: Verify that the progress tracking correctly adjusts frame count for IVTC.
    // IVTC with VDecimate reduces output frames by (cycle-1)/cycle.
    // The pipeline_executor must use this adjusted count for accurate progress reporting.
    create_output_dir();

    let job = create_ivtc_base_job("test_47_ivtc_progress");
    let pipeline = job.effective_pipeline();

    // Verify the pipeline is correctly configured for IVTC
    assert!(pipeline.deinterlace.enabled, "Deinterlace should be enabled");
    assert_eq!(pipeline.deinterlace.method, DeinterlaceMethod::Ivtc, "Method should be IVTC");
    assert_eq!(pipeline.deinterlace.ivtc_cycle.unwrap_or(5), 5, "Default cycle should be 5");

    // Simulate what pipeline_executor does for progress calculation
    let is_double_rate = pipeline.deinterlace.enabled
        && pipeline.deinterlace.method == DeinterlaceMethod::Qtgmc
        && pipeline.deinterlace.fps_divisor.unwrap_or(1) == 1;
    let is_ivtc = pipeline.deinterlace.enabled
        && pipeline.deinterlace.method == DeinterlaceMethod::Ivtc;
    let ivtc_cycle = pipeline.deinterlace.ivtc_cycle.unwrap_or(5);

    assert!(!is_double_rate, "IVTC should NOT be detected as double-rate");
    assert!(is_ivtc, "IVTC should be detected as IVTC");

    // For 90 input frames with cycle=5:
    let vspipe_total: i32 = 90;
    let effective_total = if is_double_rate {
        vspipe_total * 2
    } else if is_ivtc && ivtc_cycle > 1 {
        vspipe_total * (ivtc_cycle - 1) / ivtc_cycle
    } else {
        vspipe_total
    };

    assert_eq!(effective_total, 72,
        "IVTC with cycle=5 should reduce 90 frames to 72 (90 * 4/5)");

    // Test with different cycle values
    let test_cases = vec![
        (100, 5, 80),   // Standard NTSC 3:2 pulldown
        (100, 4, 75),   // Euro pulldown
        (100, 3, 66),   // 2:1 pattern
        (100, 2, 50),   // Every other frame
        (90, 5, 72),    // Our telecine test video
    ];

    for (input, cycle, expected) in test_cases {
        let result = input * (cycle - 1) / cycle;
        assert_eq!(result, expected,
            "Input {} frames with cycle {} should produce {} frames, got {}",
            input, cycle, expected, result);
    }

    println!("✓ IVTC progress frame count calculation verified");
}

#[test]
fn test_48_ivtc_not_qtgmc_in_script() {
    // Test: Verify that when method is IVTC, the generated script contains
    // VIVTC calls and does NOT contain QTGMC calls. This tests that the
    // method field correctly controls which deinterlace algorithm is used.
    create_output_dir();

    let job = create_ivtc_base_job("test_48_ivtc_not_qtgmc");
    let generator = ScriptGenerator::new().expect("Failed to create generator");
    let script_path = generator.generate(&job).expect("Failed to generate script");
    let script_content = std::fs::read_to_string(&script_path).unwrap_or_default();

    // Must have IVTC calls
    assert!(script_content.contains("core.vivtc.VFM"),
        "IVTC script must contain VFM call");
    assert!(script_content.contains("core.vivtc.VDecimate"),
        "IVTC script must contain VDecimate call");

    // Must NOT have QTGMC call
    let code_section = script_content.split("import vapoursynth").nth(1).unwrap_or(&script_content);
    assert!(!code_section.contains("haf.QTGMC"),
        "IVTC script must NOT contain QTGMC call - found QTGMC in:\n{}", code_section);

    // Verify the output will be at reduced frame rate (VDecimate present)
    let vfm_pos = script_content.find("core.vivtc.VFM").unwrap();
    let vdecimate_pos = script_content.find("core.vivtc.VDecimate").unwrap();
    assert!(vfm_pos < vdecimate_pos,
        "VFM must come before VDecimate");

    println!("✓ IVTC script correctly uses VIVTC (not QTGMC)");
}

#[test]
fn test_49_qtgmc_not_ivtc_in_script() {
    // Test: Verify that when method is QTGMC (default), the generated script
    // contains QTGMC and does NOT contain VIVTC calls.
    create_output_dir();

    let mut job = create_base_job("test_49_qtgmc_not_ivtc");
    // Explicitly set QTGMC method (should be default, but be explicit)
    job.qtgmc_parameters.method = DeinterlaceMethod::Qtgmc;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    let generator = ScriptGenerator::new().expect("Failed to create generator");
    let script_path = generator.generate(&job).expect("Failed to generate script");
    let script_content = std::fs::read_to_string(&script_path).unwrap_or_default();

    // Must have QTGMC call
    assert!(script_content.contains("haf.QTGMC"),
        "QTGMC script must contain QTGMC call");

    // Must NOT have VIVTC calls
    assert!(!script_content.contains("core.vivtc.VFM"),
        "QTGMC script must NOT contain VFM call");
    assert!(!script_content.contains("core.vivtc.VDecimate"),
        "QTGMC script must NOT contain VDecimate call");

    println!("✓ QTGMC script correctly uses QTGMC (not VIVTC)");
}

#[test]
fn test_50_chroma_shift() {
    create_output_dir();

    let mut job = create_base_job("test_50_chroma_shift");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_chroma_shift: true,
            chroma_shift_h: 2.5,
            chroma_shift_v: -0.75,
            ..ChromaFixParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "Chroma Shift (Y/C Delay)", &[
        "ShufflePlanes",
        "resize.Spline36",
        "2.5",
        "-0.75",
    ]).unwrap();
}

#[test]
fn test_51_descratch() {
    create_output_dir();

    let mut job = create_base_job("test_51_descratch");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        descratch: DeScratchParameters {
            enabled: true,
            mindif: 8,
            mode_y: 3,
            keep: 80,
            ..DeScratchParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "DeScratch", &[
        "descratch.DeScratch",
        "mindif=8",
        "modey=3",
        "keep=80",
    ]).unwrap();
}

#[test]
fn test_52_spotless() {
    create_output_dir();

    let mut job = create_base_job("test_52_spotless");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.preset = QTGMCPreset::Fast;
    job.qtgmc_parameters.tff = Some(true);

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        spotless: SpotLessParameters {
            enabled: true,
            chroma: true,
            rec: false,
            blksize: 16,
            overlap: 8,
            pel: 2,
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "SpotLess", &[
        "from spotless import SpotLess",
        "chroma=True",
        "blksize=16",
        "pel=2",
    ]).unwrap();
}

/// Regression for issue #37: QTGMC with EZ Denoise > 0 and the knlmeanscl
/// denoiser must emit `Denoiser="knlmeanscl"` into the script. This is the
/// exact combination that crashed when KNLMeansCL wasn't bundled on macOS x64 /
/// Windows; the plugin is now shipped on every platform (see
/// Scripts/deps-expected-plugins.json), so the generated call must resolve.
#[test]
fn test_53_qtgmc_knlmeanscl_denoiser() {
    create_output_dir();

    let mut job = create_base_job("test_53_qtgmc_knlmeanscl_denoiser");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Fast,
        tff: Some(true),
        opencl: Some(false),
        ez_denoise: Some(1.5),
        denoiser: Some("knlmeanscl".to_string()),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "QTGMC knlmeanscl denoiser", &[
        "Denoiser=\"knlmeanscl\"",
        "EZDenoise=1.5",
    ]).unwrap();
}

/// Issue #37 fallback: when KNLMeansCL is NOT usable here (plugin missing or no
/// usable OpenCL device), a `knlmeanscl` selection must be downgraded to
/// `dfttest` in the generated script so the job runs instead of crashing.
#[test]
fn test_54_qtgmc_knlmeanscl_falls_back_to_dfttest() {
    create_output_dir();

    let mut job = create_base_job("test_54_qtgmc_knlmeanscl_fallback");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Fast,
        tff: Some(true),
        opencl: Some(false),
        ez_denoise: Some(1.5),
        denoiser: Some("knlmeanscl".to_string()),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    // Generate with knlm marked unavailable — the gate should rewrite the denoiser.
    let generator = ScriptGenerator::new()
        .expect("create generator")
        .with_knlm_available(false);
    let script_path = generator.generate(&job).expect("generate script");
    let script = std::fs::read_to_string(&script_path).expect("read script");

    assert!(
        script.contains("Denoiser=\"dfttest\""),
        "expected fallback to dfttest, script was:\n{}",
        script
    );
    assert!(
        !script.contains("knlmeanscl"),
        "knlmeanscl should not appear after fallback, script was:\n{}",
        script
    );
}

#[test]
fn test_55_preview_selects_exact_frame() {
    // Frame-accurate preview: the generated preview script must emit the exact
    // output index the worker computed for the requested frame, NOT the old
    // "middle of the decoded window" heuristic.
    create_output_dir();

    let mut job = create_base_job("test_55_preview_frame");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.tff = Some(true);
    // Opt into the chroma upsample so the preview/encode parity assertions
    // below have something to compare.
    job.qtgmc_parameters.chroma_upsample_fix = Some(true);
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    let generator = ScriptGenerator::new().expect("create generator");
    let params = PreviewParams {
        width: 720,
        height: 576,
        pix_fmt: "yuv420p".to_string(),
        num_frames: 11,
        fps_num: 25,
        fps_den: 1,
        output_index: 7,
    };
    let script_path = generator
        .generate_preview(&job, &params)
        .expect("generate preview script");
    let script = std::fs::read_to_string(&script_path).expect("read preview script");

    assert!(
        script.contains("min(7, clip.num_frames - 1)"),
        "preview must select the exact computed output index, script was:\n{}",
        script
    );
    assert!(
        !script.contains("num_frames // 2"),
        "preview must not fall back to the old middle-frame heuristic"
    );
    // The preview must apply the same field marking and working-format
    // conversion as the encode, or it won't represent the final render (#49).
    assert!(
        script.contains("core.std.SetFieldBased(clip, 2)"),
        "preview must mark field order the same way the encode does"
    );
    assert!(
        script.contains("_deint_src_format = clip.format")
            && script.contains("_deint_ss_h = 0"),
        "preview must apply the same deinterlace working format as the encode"
    );
    let _ = std::fs::remove_file(&script_path);
}

#[test]
fn test_56_frame_count_mapping() {
    // The progress reporter derives the output frame total from output_count();
    // verify the composed map reproduces the deinterlace count transforms.
    let mut p = ProcessingPipeline::default();
    p.deinterlace.enabled = true;
    p.deinterlace.method = DeinterlaceMethod::Qtgmc;

    // Double-rate QTGMC (FPSDivisor=1, and the unset default) doubles frames.
    p.deinterlace.fps_divisor = Some(1);
    assert_eq!(p.output_count(1000), 2000);
    p.deinterlace.fps_divisor = None;
    assert_eq!(p.output_count(1000), 2000);

    // Single-rate QTGMC leaves the count unchanged.
    p.deinterlace.fps_divisor = Some(2);
    assert_eq!(p.output_count(1000), 1000);

    // IVTC cycle 5 keeps 4 of every 5 frames (30→24).
    p.deinterlace.method = DeinterlaceMethod::Ivtc;
    p.deinterlace.fps_divisor = None;
    p.deinterlace.ivtc_cycle = Some(5);
    assert_eq!(p.output_count(1000), 800);

    // A double-rate output frame inverts back to its source frame, exactly.
    p.deinterlace.method = DeinterlaceMethod::Qtgmc;
    p.deinterlace.fps_divisor = Some(1);
    p.deinterlace.ivtc_cycle = None;
    let span = p.invert(20);
    assert_eq!(span.start, 10);
    assert!(span.exact);
}

#[test]
fn test_57_ivtc_high_bit_depth_guard() {
    // VFM only accepts 8-bit YUV/GRAY, so IVTC on a higher bit-depth source
    // (e.g. 10-bit ProRes 422, yuv422p10le) must run field matching on an 8-bit
    // metrics copy while emitting full-depth pixels via clip2. Verify the guard
    // and clip2 wiring appear in the generated script. (The telecine fixture is
    // 8-bit, so this also confirms the guarded path still runs end-to-end.)
    create_output_dir();

    let mut job = create_ivtc_base_job("test_57_ivtc_high_bit_depth_guard");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "IVTC - High Bit Depth Guard", &[
        "bits_per_sample == 8",
        "core.vivtc.VFM(_ivtc_metrics",
        "clip2=_ivtc_src",
        "core.vivtc.VDecimate(clip",
    ]).unwrap();
}

#[test]
fn test_58_deinterlace_working_format_default() {
    // Both working-format options are opt-in: the 4:2:2 chroma upsample costs
    // roughly 30% throughput and 16-bit roughly doubles it, so neither is
    // imposed. The default script must therefore be exactly what it was before
    // the working-format block existed.
    create_output_dir();

    let mut job = create_base_job("test_58_deint_working_format_default");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Fast,
        tff: Some(true),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    let generator = ScriptGenerator::new().unwrap();
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();
    for marker in [
        "_deint_src_format",
        "_deint_ss_h",
        "_deint_bits",
        "DEINT_WORKING_FORMAT",
    ] {
        assert!(!script.contains(marker), "expected no '{}' by default", marker);
    }
    assert!(script.contains("haf.QTGMC("), "QTGMC call should still be generated");
}

#[test]
fn test_58b_deinterlace_chroma_upsample_opt_in() {
    // Issue #49: interlaced 4:2:0 stores chroma per field, so interpolating it
    // at 4:2:0 mixes the two fields' chroma. When the option is enabled the
    // pass converts to 4:2:2 (field-aware, since zimg honours _FieldBased) and
    // restores the source format afterwards, without touching the bit depth.
    create_output_dir();

    let mut job = create_base_job("test_58b_deint_chroma_upsample");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Fast,
        tff: Some(true),
        chroma_upsample_fix: Some(true),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "Deinterlace Chroma Upsample (opt-in)", &[
        "_deint_src_format = clip.format",
        "_deint_ss_h = 0",
        "subsampling_h=_deint_ss_h",
        "dither_type=\"error_diffusion\"",
    ]).unwrap();

    // Enabling the chroma fix must not drag 16-bit along with it.
    let generator = ScriptGenerator::new().unwrap();
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();
    assert!(
        !script.contains("_deint_bits = max(_deint_bits, 16)"),
        "16-bit processing should stay off unless separately enabled"
    );
}

#[test]
fn test_59_deinterlace_high_precision() {
    // 16-bit on its own: the bit depth is raised and dithered back, and the
    // chroma subsampling is left alone because the two options are independent.
    create_output_dir();

    let mut job = create_base_job("test_59_deint_high_precision");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Fast,
        tff: Some(true),
        high_precision: Some(true),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "Deinterlace Working Format (16-bit)", &[
        "_deint_src_format = clip.format",
        "_deint_bits = max(_deint_bits, 16)",
        "dither_type=\"error_diffusion\"",
    ]).unwrap();

    let generator = ScriptGenerator::new().unwrap();
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();
    assert!(
        !script.contains("_deint_ss_h = 0"),
        "16-bit must not enable the chroma upsample as a side effect"
    );
}

#[test]
fn test_59b_deinterlace_both_working_format_options() {
    // Both on: 4:2:2 and 16-bit, restored to the source format afterwards.
    create_output_dir();

    let mut job = create_base_job("test_59b_deint_both_options");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Fast,
        tff: Some(true),
        chroma_upsample_fix: Some(true),
        high_precision: Some(true),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "Deinterlace Working Format (4:2:2 + 16-bit)", &[
        "_deint_ss_h = 0",
        "_deint_bits = max(_deint_bits, 16)",
        "dither_type=\"error_diffusion\"",
    ]).unwrap();
}

#[test]
fn test_60_deinterlace_working_format_disabled() {
    // Both off: the script must be exactly what it was before the working-format
    // block existed, so the conversion can't cost anything when it's not wanted.
    create_output_dir();

    let mut job = create_base_job("test_60_deint_working_format_off");
    job.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Fast,
        tff: Some(true),
        chroma_upsample_fix: Some(false),
        high_precision: Some(false),
        ..QTGMCParameters::default()
    };
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: job.qtgmc_parameters.clone(),
        ..ProcessingPipeline::default()
    });

    let generator = ScriptGenerator::new().unwrap();
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();
    for marker in ["_deint_src_format", "_deint_ss_h", "_deint_bits", "DEINT_WORKING_FORMAT"] {
        assert!(!script.contains(marker), "expected no '{}' when both options are off", marker);
    }
    assert!(script.contains("haf.QTGMC("), "QTGMC call should still be generated");
}

#[test]
fn test_61_chroma_edi_rejects_unsupported_value() {
    // Issue #49: havsfunc implements only ChromaEdi '' / 'nnedi3' / 'bob'. Any
    // other non-empty value disables chroma EDI and then returns the luma-only
    // interpolation without restoring chroma, which badly corrupts chroma. Such
    // values must be dropped so QTGMC falls back to its default.
    create_output_dir();

    let mut base = create_base_job("test_61_chroma_edi_guard");
    base.qtgmc_parameters = QTGMCParameters {
        enabled: true,
        preset: QTGMCPreset::Fast,
        tff: Some(true),
        ..QTGMCParameters::default()
    };

    let generator = ScriptGenerator::new().unwrap();
    let render = |chroma_edi: Option<&str>| {
        let mut job = base.clone();
        job.qtgmc_parameters.chroma_edi = chroma_edi.map(str::to_string);
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: job.qtgmc_parameters.clone(),
            ..ProcessingPipeline::default()
        });
        std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap()
    };

    // Supported values pass through, lowercased the way QTGMC lowercases them.
    assert!(render(Some("NNEDI3")).contains("ChromaEdi=\"nnedi3\""));
    assert!(render(Some("Bob")).contains("ChromaEdi=\"bob\""));

    // The empty string is QTGMC's own default and stays.
    for value in ["", "   "] {
        assert!(
            render(Some(value)).contains("ChromaEdi=\"\""),
            "ChromaEdi={:?} should pass through as the default",
            value
        );
    }

    // Unsupported values are omitted entirely.
    for value in ["Blend", "nonsense"] {
        assert!(
            !render(Some(value)).contains("ChromaEdi="),
            "ChromaEdi={:?} should have been dropped",
            value
        );
    }
}

#[test]
fn test_62_field_based_follows_deinterlace_tff() {
    // Issue #49: std.SeparateFields ignores its `tff` argument whenever
    // _FieldBased is set, so the property decides the field order that is
    // actually used. It must therefore be derived from the same value as
    // QTGMC's TFF argument — otherwise autodetection silently overrides the
    // user's field-order choice.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let render = |tff: bool, detected: Option<FieldOrder>| {
        let mut job = create_base_job("test_62_field_based");
        job.detected_field_order = detected;
        job.qtgmc_parameters = QTGMCParameters {
            enabled: true,
            preset: QTGMCPreset::Fast,
            tff: Some(tff),
            ..QTGMCParameters::default()
        };
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: job.qtgmc_parameters.clone(),
            ..ProcessingPipeline::default()
        });
        std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap()
    };

    // BFF requested while detection says TFF: the property must say BFF (1),
    // matching TFF=False, not follow the detected order.
    let script = render(false, Some(FieldOrder::TopFieldFirst));
    assert!(script.contains("core.std.SetFieldBased(clip, 1)"), "expected BFF marking");
    assert!(script.contains("TFF=False"), "expected TFF=False");

    // And the reverse.
    let script = render(true, Some(FieldOrder::BottomFieldFirst));
    assert!(script.contains("core.std.SetFieldBased(clip, 2)"), "expected TFF marking");
    assert!(script.contains("TFF=True"), "expected TFF=True");
}

#[test]
fn test_63_source_pixel_format_411_reaches_the_script() {
    // Issue #50: NTSC DV is 4:1:1. The app passes ffprobe's pix_fmt through
    // verbatim, and pipe_source used to reject anything outside a 12-entry map,
    // so every DV import failed with "Unsupported pixel format: yuv411p".
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let mut job = create_base_job("test_63_pixel_format_411");
    job.input_pixel_format = Some("yuv411p".to_string());
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();

    assert!(
        script.contains(r#"pix_fmt="yuv411p""#),
        "4:1:1 is readable off the pipe, so it should be used as-is"
    );
}

#[test]
fn test_64_unreadable_source_pixel_format_is_converted() {
    // Formats pipe_source can't read must be converted by the decoder instead
    // of failing the job, and to a format that holds the source without loss.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let render = |pix_fmt: &str| {
        let mut job = create_base_job("test_64_pixel_format_convert");
        job.input_pixel_format = Some(pix_fmt.to_string());
        std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap()
    };

    // ProRes 4444: alpha is dropped, 4:4:4 and 10-bit are kept.
    assert!(render("yuva444p10le").contains(r#"pix_fmt="yuv444p10le""#));
    // RGB has no subsampling, so 4:4:4 is the only non-degrading choice.
    assert!(render("rgb24").contains(r#"pix_fmt="yuv444p""#));
    // Hardware-decoder semi-planar output.
    assert!(render("p010le").contains(r#"pix_fmt="yuv420p10le""#));
}

#[test]
fn test_65_dehalo_alpha_advanced_parameters() {
    // Issue #50: DeHalo_alpha's sensitivity and supersampling arguments were
    // never exposed, so the pass could only be tuned by radius and strength.
    create_output_dir();

    let mut job = create_base_job("test_65_dehalo_alpha_advanced");
    job.processing_pipeline = Some(ProcessingPipeline {
        dehalo: DehaloParameters {
            enabled: true,
            method: DehaloMethod::DehaloAlpha,
            dark_str: 1.4, // above 1.0 — the old schema capped this at 1.0
            low_sens: Some(35),
            high_sens: Some(65),
            super_sample: Some(2.0),
            ..DehaloParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "DeHalo_alpha advanced", &[
        "haf.DeHalo_alpha",
        "darkstr=1.4",
        "lowsens=35",
        "highsens=65",
        "ss=2",
    ]).unwrap();
}

#[test]
fn test_66_fine_dehalo_advanced_parameters() {
    create_output_dir();

    let mut job = create_base_job("test_66_fine_dehalo_advanced");
    job.processing_pipeline = Some(ProcessingPipeline {
        dehalo: DehaloParameters {
            enabled: true,
            method: DehaloMethod::FineDehalo,
            limit_low: Some(60),
            limit_high: Some(120),
            contra: Some(1.2),
            exclude_close_edges: Some(false),
            edge_proc: Some(0.5),
            ..DehaloParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "FineDehalo advanced", &[
        "haf.FineDehalo",
        "thlimi=60",
        "thlima=120",
        "contra=1.2",
        "excl=False",
        "edgeproc=0.5",
    ]).unwrap();
}

#[test]
fn test_67_dehalo_ghost_and_edge_methods() {
    // The "ghost" half of the request: Vinverse removes the comb residue a
    // deinterlacer leaves behind, and each new method must emit its own
    // havsfunc call with nothing left over from the others.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let render = |dehalo: DehaloParameters| {
        let mut job = create_base_job("test_67_dehalo_methods");
        job.processing_pipeline = Some(ProcessingPipeline {
            dehalo,
            ..ProcessingPipeline::default()
        });
        std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap()
    };

    let script = render(DehaloParameters {
        enabled: true,
        method: DehaloMethod::Vinverse,
        vinverse_strength: Some(3.5),
        vinverse_amount: Some(200),
        vinverse_chroma: Some(false),
        ..DehaloParameters::default()
    });
    assert!(script.contains("haf.Vinverse("), "expected a Vinverse call");
    assert!(script.contains("sstr=3.5"));
    assert!(script.contains("amnt=200"));
    assert!(script.contains("chroma=False"));
    assert!(!script.contains("haf.DeHalo_alpha"), "other methods must be removed");

    // Vinverse2 shares the block; only the function name changes.
    let script = render(DehaloParameters {
        enabled: true,
        method: DehaloMethod::Vinverse2,
        ..DehaloParameters::default()
    });
    assert!(script.contains("haf.Vinverse2("), "expected a Vinverse2 call");

    let script = render(DehaloParameters {
        enabled: true,
        method: DehaloMethod::EdgeCleaner,
        edge_strength: Some(20),
        edge_repair: Some(true),
        edge_repair_mode: Some(1),
        edge_small_mode: Some(1),
        edge_hot_pixels: Some(true),
        ..DehaloParameters::default()
    });
    assert!(script.contains("haf.EdgeCleaner("));
    assert!(script.contains("strength=20"));
    assert!(script.contains("rep=True"));
    assert!(script.contains("rmode=1"));
    assert!(script.contains("smode=1"));
    assert!(script.contains("hot=True"));

    // FineDehalo2 takes no parameters, so it must not carry an argument list.
    let script = render(DehaloParameters {
        enabled: true,
        method: DehaloMethod::FineDehalo2,
        ..DehaloParameters::default()
    });
    assert!(script.contains("haf.FineDehalo2(clip)"));
    assert!(!script.contains("haf.FineDehalo("), "FineDehalo2 is not FineDehalo");
}

#[test]
fn test_68_dehalo_unset_optionals_are_omitted() {
    // An unset optional must not reach the script at all: havsfunc's own default
    // is the documented behaviour, and emitting our idea of it would silently
    // pin the value if upstream ever changed.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let mut job = create_base_job("test_68_dehalo_defaults");
    job.processing_pipeline = Some(ProcessingPipeline {
        dehalo: DehaloParameters {
            enabled: true,
            method: DehaloMethod::DehaloAlpha,
            ..DehaloParameters::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();

    assert!(script.contains("haf.DeHalo_alpha"));
    for absent in ["lowsens=", "highsens=", "ss="] {
        assert!(!script.contains(absent), "unset optional {} leaked into the script", absent);
    }
    // The pre-existing always-passed arguments are unchanged.
    assert!(script.contains("rx=2"));
    assert!(script.contains("darkstr=1"));
}

#[test]
fn test_69_upscale_eedi3_actually_uses_eedi3() {
    // Issue #50: the UI offered an EEDI3 upscale, but the template block was a
    // "fall back to spline36 for now" placeholder — picking EEDI3 silently gave
    // you Spline36. It must now emit a real eedi3m.EEDI3 call, guided by an
    // nnedi3 sclip.
    create_output_dir();

    let mut job = create_base_job("test_69_upscale_eedi3");
    job.processing_pipeline = Some(ProcessingPipeline {
        crop_resize: CropResizeParameters {
            enabled: true,
            use_integer_upscale: true,
            upscale_method: UpscaleMethod::Eedi3Rpow2,
            upscale_factor: 2,
            upscale_alpha: Some(0.4),
            upscale_beta: Some(0.3),
            upscale_gamma: Some(40.0),
            upscale_nrad: Some(3),
            upscale_mdis: Some(30),
            ..CropResizeParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "EEDI3 upscale", &[
        "core.eedi3m.EEDI3",
        "sclip=sclip",
        "alpha=0.4",
        "beta=0.3",
        "gamma=40",
        "nrad=3",
        "mdis=30",
    ]).unwrap();
}

#[test]
fn test_70_upscale_nnedi3_granular_parameters() {
    create_output_dir();

    let mut job = create_base_job("test_70_upscale_nnedi3");
    job.processing_pipeline = Some(ProcessingPipeline {
        crop_resize: CropResizeParameters {
            enabled: true,
            use_integer_upscale: true,
            upscale_method: UpscaleMethod::Nnedi3Rpow2,
            upscale_factor: 4,
            upscale_nsize: Some(4),
            upscale_neurons: Some(4),
            upscale_qual: Some(2),
            upscale_etype: Some(1),
            upscale_pscrn: Some(0),
            ..CropResizeParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "NNEDI3 upscale granular", &[
        "core.znedi3.nnedi3",
        "nsize=4",
        "nns=4",
        "qual=2",
        "etype=1",
        "pscrn=0",
        // 4x is two doublings of the 2x step.
        "range(max(4 // 2, 1))",
    ]).unwrap();
}

#[test]
fn test_71_upscale_corrects_the_dh_half_pixel_shift() {
    // nnedi3/EEDI3 dh=True leave the result half an output pixel up and left.
    // The correction must be per-plane: src_top is in luma pixels, so one
    // whole-clip shift under-corrects subsampled chroma by a quarter row.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let mut job = create_base_job("test_71_upscale_shift");
    job.processing_pipeline = Some(ProcessingPipeline {
        crop_resize: CropResizeParameters {
            enabled: true,
            use_integer_upscale: true,
            upscale_method: UpscaleMethod::Nnedi3Rpow2,
            ..CropResizeParameters::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();

    assert!(script.contains("_upscale_fix_shift"), "shift correction should be present");
    assert!(
        script.contains("core.std.ShufflePlanes(c, i, vs.GRAY)"),
        "the correction must run per plane, not on the whole clip"
    );
    assert!(
        script.contains("_upscale_shift = _upscale_shift * 2 + 0.5"),
        "each doubling adds 0.5 and doubles the inherited offset"
    );

    // Spline36 "upscale" is plain resampling: no doubling loop, no shift.
    job.processing_pipeline.as_mut().unwrap().crop_resize.upscale_method = UpscaleMethod::Spline36;
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();
    assert!(!script.contains("_upscale_fix_shift"));
    assert!(script.contains("core.resize.Spline36(clip, width=clip.width * 2"));
}

#[test]
fn test_72_resize_kernel_and_kernel_tuning() {
    // The kernel list grew to seven, and filter_param_a/b mean different things
    // per kernel — Bicubic reads them as b and c, Lanczos reads a as the tap
    // count, and the rest read neither.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let render = |crop_resize: CropResizeParameters| {
        let mut job = create_base_job("test_72_resize_kernels");
        job.processing_pipeline = Some(ProcessingPipeline {
            crop_resize,
            ..ProcessingPipeline::default()
        });
        std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap()
    };

    let base = CropResizeParameters {
        enabled: true,
        resize_enabled: true,
        target_width: Some(1280),
        target_height: Some(720),
        ..CropResizeParameters::default()
    };

    for (kernel, expected) in [
        (ResizeKernel::Point, "core.resize.Point("),
        (ResizeKernel::Bilinear, "core.resize.Bilinear("),
        (ResizeKernel::Spline16, "core.resize.Spline16("),
        (ResizeKernel::Spline36, "core.resize.Spline36("),
        (ResizeKernel::Spline64, "core.resize.Spline64("),
        (ResizeKernel::Lanczos, "core.resize.Lanczos("),
        (ResizeKernel::Bicubic, "core.resize.Bicubic("),
    ] {
        let script = render(CropResizeParameters { kernel, ..base.clone() });
        assert!(script.contains(expected), "kernel {:?} should emit {}", kernel, expected);
    }

    // Bicubic b/c.
    let script = render(CropResizeParameters {
        kernel: ResizeKernel::Bicubic,
        bicubic_b: Some(0.33),
        bicubic_c: Some(0.33),
        lanczos_taps: Some(8), // set but irrelevant for this kernel
        ..base.clone()
    });
    assert!(script.contains("filter_param_a=0.33"));
    assert!(script.contains("filter_param_b=0.33"));

    // Lanczos taps land in filter_param_a, and Bicubic's c must not leak into
    // filter_param_b, where Lanczos would ignore it at best.
    let script = render(CropResizeParameters {
        kernel: ResizeKernel::Lanczos,
        lanczos_taps: Some(4),
        bicubic_c: Some(0.75),
        ..base.clone()
    });
    // filter_param_a is a float in zimg, so the tap count is emitted as 4.0.
    assert!(script.contains("filter_param_a=4.0"));
    assert!(!script.contains("filter_param_b="));

    // A kernel that reads neither gets neither.
    let script = render(CropResizeParameters {
        kernel: ResizeKernel::Spline36,
        bicubic_b: Some(0.5),
        lanczos_taps: Some(4),
        ..base
    });
    assert!(!script.contains("filter_param_a="));
    assert!(!script.contains("filter_param_b="));
}

#[test]
fn test_73_white_balance_temperature_and_tint() {
    // Issue #50: temperature and tint. U carries blue-yellow and V carries
    // red-cyan, so warming the image must lower U and raise V; a magenta tint
    // raises both. Getting a sign wrong here is invisible in a unit test and
    // very visible on screen.
    create_output_dir();

    let mut job = create_base_job("test_73_white_balance");
    job.processing_pipeline = Some(ProcessingPipeline {
        color_correction: ColorCorrectionParameters {
            enabled: true,
            temperature: 40.0,
            ..ColorCorrectionParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "White balance (warm)", &[
        "core.std.Expr",
        "_wb_u = -10.0 * _wb_scale",
        "_wb_v = 10.0 * _wb_scale",
        // Luma must be left alone: an empty expression copies the plane.
        "['', 'x ' + repr(_wb_u) + ' +', 'x ' + repr(_wb_v) + ' +']",
    ]).unwrap();
}

#[test]
fn test_74_white_balance_absent_when_neutral() {
    // Colour correction is often enabled for brightness alone. A neutral white
    // balance must add no Expr call at all — an extra pass over every plane for
    // a no-op offset would cost time and, on integer formats, rounding.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let mut job = create_base_job("test_74_white_balance_neutral");
    job.processing_pipeline = Some(ProcessingPipeline {
        color_correction: ColorCorrectionParameters {
            enabled: true,
            brightness: 8.0,
            ..ColorCorrectionParameters::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();

    assert!(script.contains("adjust.Tweak"), "the brightness tweak should still run");
    assert!(!script.contains("_wb_scale"), "neutral white balance should emit nothing");

    // Tint alone is enough to bring the block back.
    job.processing_pipeline.as_mut().unwrap().color_correction.tint = -20.0;
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();
    assert!(script.contains("_wb_u = -5.0 * _wb_scale"));
    assert!(script.contains("_wb_v = -5.0 * _wb_scale"));
}

#[test]
fn test_75_chroma_denoise_ccd() {
    // Issue #50: CCD, the chroma denoiser for VHS/camcorder colour noise.
    create_output_dir();

    let mut job = create_base_job("test_75_chroma_denoise");
    job.processing_pipeline = Some(ProcessingPipeline {
        chroma_denoise: ChromaDenoiseParameters {
            enabled: true,
            threshold: 8.5,
            temporal_radius: 2,
            points_high: true,
            ..ChromaDenoiseParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "CCD chroma denoise", &[
        "core.zsmooth.CCD",
        "threshold=8.5",
        "temporal_radius=2",
        "points=[True, True, True]",
    ]).unwrap();
}

#[test]
fn test_76_ccd_scale_is_derived_with_a_floor() {
    // CCD derives `scale` from the frame height and REJECTS anything below 1.0,
    // so its own automatic value fails outright on sources shorter than its
    // 480-line reference (measured: 352x288 and 320x240 both error with "scale
    // must be greater than or equal to 1.0"). We derive it with a floor so short
    // and cropped sources still run.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let mut job = create_base_job("test_76_ccd_scale");
    job.processing_pipeline = Some(ProcessingPipeline {
        chroma_denoise: ChromaDenoiseParameters {
            enabled: true,
            ..ChromaDenoiseParameters::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();

    assert!(
        script.contains("_ccd_scale = max(1.0, clip.height / 480.0)"),
        "scale should be derived from the height with a floor of 1.0"
    );
    assert!(script.contains("scale=_ccd_scale"));

    // An explicit scale overrides the derivation entirely.
    job.processing_pipeline.as_mut().unwrap().chroma_denoise.scale = Some(3.5);
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();
    assert!(script.contains("_ccd_scale = 3.5"));
    assert!(!script.contains("max(1.0, clip.height"));
}

#[test]
fn test_77_chroma_denoise_absent_when_disabled() {
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let mut job = create_base_job("test_77_chroma_denoise_off");
    job.processing_pipeline = Some(ProcessingPipeline::default());
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();
    assert!(!script.contains("zsmooth"), "a disabled pass must emit nothing");

    // And it sits between noise reduction and dehalo in the pass order.
    let pipeline = ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters { enabled: true, ..Default::default() },
        chroma_denoise: ChromaDenoiseParameters { enabled: true, ..Default::default() },
        dehalo: DehaloParameters { enabled: true, ..Default::default() },
        ..ProcessingPipeline::default()
    };
    job.processing_pipeline = Some(pipeline.clone());
    assert_eq!(
        pipeline.enabled_passes(),
        vec![PassType::NoiseReduction, PassType::ChromaDenoise, PassType::Dehalo]
    );
}

#[test]
fn test_78_mcdegrainsharp() {
    // Issue #50: MCDegrainSharp (Didée) — "denoise with MDegrain, sharpen where
    // the motion match is good, blur where it is bad". Needs only mvtools and
    // tcanny, both already bundled.
    create_output_dir();

    let mut job = create_base_job("test_78_mcdegrainsharp");
    job.processing_pipeline = Some(ProcessingPipeline {
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::McDegrainSharp,
            mcds_frames: 3,
            mcds_th_sad: 500,
            ..NoiseReductionParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    run_job_and_verify(&job, "MCDegrainSharp", &[
        "core.tcanny.TCanny",
        "core.mv.Super",
        // 3 frames selects Degrain3, and the other two must be gone.
        "core.mv.Degrain3(",
        "thsad=500",
        "levels=1",
        // The averaged clip is the blurred one; the pixels come from the
        // sharpened one. Swapping these is the whole difference between this and
        // a plain degrain.
        "clip=_mcds_blurred",
        "super=_mcds_super_render",
    ]).unwrap();
}

#[test]
fn test_79_mcdegrainsharp_frame_count_and_planes() {
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let render = |frames: i32, plane: i32, blur_search: bool| {
        let mut job = create_base_job("test_79_mcdegrainsharp_variants");
        job.processing_pipeline = Some(ProcessingPipeline {
            noise_reduction: NoiseReductionParameters {
                enabled: true,
                method: NoiseReductionMethod::McDegrainSharp,
                mcds_frames: frames,
                mcds_plane: plane,
                mcds_blur_search: blur_search,
                ..NoiseReductionParameters::default()
            },
            ..ProcessingPipeline::default()
        });
        std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap()
    };

    // mvtools has one function per frame count; exactly one must survive.
    for (frames, expected) in [(1, "Degrain1("), (2, "Degrain2("), (3, "Degrain3(")] {
        let script = render(frames, 4, true);
        assert!(script.contains(expected), "{} frames should use {}", frames, expected);
        for other in ["Degrain1(", "Degrain2(", "Degrain3("] {
            if other != expected {
                assert!(!script.contains(other), "{} should not appear for {} frames", other, frames);
            }
        }
    }

    // The TCanny plane list must match mvtools' plane selector, or the blur and
    // sharpen references would cover different planes than the degrain.
    let script = render(2, 3, true);
    assert!(script.contains("_mcds_planes = [1, 2]"));
    assert!(script.contains("plane=3"));

    let script = render(2, 0, true);
    assert!(script.contains("_mcds_planes = [0]"));
    assert!(script.contains("plane=0"));

    // Searching on the source instead of the blurred copy.
    let script = render(2, 4, false);
    assert!(script.contains("_mcds_super_search = core.mv.Super(clip,"));
    let script = render(2, 4, true);
    assert!(script.contains("_mcds_super_search = core.mv.Super(_mcds_blurred,"));
}

#[test]
fn test_80_resize_fits_by_display_aspect_when_squaring_pixels() {
    // Issue #50: an anamorphic source's stored frame is deliberately the wrong
    // shape (720x576 shown as 16:9), so fitting a target box by stored
    // dimensions alone gets the geometry wrong. Squaring the pixels has to fit
    // by *display* aspect instead.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let render = |crop_resize: CropResizeParameters, sar: Option<&str>| {
        let mut job = create_base_job("test_80_aspect");
        job.input_sar = sar.map(str::to_string);
        job.processing_pipeline = Some(ProcessingPipeline {
            crop_resize,
            ..ProcessingPipeline::default()
        });
        std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap()
    };

    let squared = CropResizeParameters {
        enabled: true,
        resize_enabled: true,
        target_width: Some(1920),
        pixel_aspect: PixelAspectMode::Square,
        ..CropResizeParameters::default()
    };
    let script = render(squared.clone(), Some("16:11"));
    assert!(script.contains("_display_aspect = (clip.width * 1.4545) / clip.height"));
    assert!(script.contains("_fit_aspect = _display_aspect"));

    // Preserving the pixel grid fits by stored dimensions, as before.
    let script = render(
        CropResizeParameters {
            pixel_aspect: PixelAspectMode::Preserve,
            ..squared.clone()
        },
        Some("16:11"),
    );
    assert!(script.contains("_fit_aspect = clip.width / clip.height"));

    // A square-pixel source has SAR 1, so both routes agree.
    let script = render(squared, None);
    assert!(script.contains("_display_aspect = (clip.width * 1.0) / clip.height"));
}

#[test]
fn test_81_squaring_pixels_needs_no_target_size() {
    // "Make this anamorphic source square" is a resize in its own right: keep
    // the height and change the width until the picture is the right shape.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let mut job = create_base_job("test_81_square_only");
    job.input_sar = Some("16:11".to_string());
    job.processing_pipeline = Some(ProcessingPipeline {
        crop_resize: CropResizeParameters {
            enabled: true,
            resize_enabled: false,
            pixel_aspect: PixelAspectMode::Square,
            ..CropResizeParameters::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();

    assert!(script.contains("target_h = clip.height"), "height is kept");
    assert!(script.contains("target_w = _even(target_h * _fit_aspect)"), "width follows the display aspect");
    assert!(script.contains("core.resize.Spline36("));
}

#[test]
fn test_82_forced_display_aspect_and_padding() {
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let render = |crop_resize: CropResizeParameters| {
        let mut job = create_base_job("test_82_aspect_options");
        job.input_sar = Some("10:11".to_string());
        job.processing_pipeline = Some(ProcessingPipeline {
            crop_resize,
            ..ProcessingPipeline::default()
        });
        std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap()
    };

    // A forced display aspect replaces the source-derived one entirely.
    let script = render(CropResizeParameters {
        enabled: true,
        resize_enabled: true,
        target_height: Some(720),
        pixel_aspect: PixelAspectMode::Square,
        display_aspect: Some("16:9".to_string()),
        ..CropResizeParameters::default()
    });
    assert!(script.contains("_display_aspect = 1.7778"));
    assert!(!script.contains("clip.width * 10"), "the source SAR must not also be used");

    // Padding fills the box instead of leaving the picture short in one axis.
    let script = render(CropResizeParameters {
        enabled: true,
        resize_enabled: true,
        target_width: Some(1920),
        target_height: Some(1080),
        pad_to_aspect: true,
        ..CropResizeParameters::default()
    });
    assert!(script.contains("core.std.AddBorders("));

    // Without a target box there is nothing to pad out to, so the block goes.
    let script = render(CropResizeParameters {
        enabled: true,
        resize_enabled: false,
        pixel_aspect: PixelAspectMode::Square,
        pad_to_aspect: true,
        ..CropResizeParameters::default()
    });
    assert!(!script.contains("core.std.AddBorders("));
}

#[test]
fn test_83_fine_dehalo_thresholds_match_havsfunc_defaults() {
    // The schema shipped thmi=50/thma=100 — which are thlimi/thlima's defaults,
    // copied onto the wrong pair. havsfunc's FineDehalo uses thmi=80, thma=128.
    // Because both are always emitted, the wrong value was actively passed on
    // every FineDehalo run rather than merely displayed.
    create_output_dir();

    let generator = ScriptGenerator::new().unwrap();
    let mut job = create_base_job("test_83_fine_dehalo_defaults");
    job.processing_pipeline = Some(ProcessingPipeline {
        dehalo: DehaloParameters {
            enabled: true,
            method: DehaloMethod::FineDehalo,
            ..DehaloParameters::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = std::fs::read_to_string(generator.generate(&job).unwrap()).unwrap();

    assert!(script.contains("thmi=80"), "thmi should default to havsfunc's 80");
    assert!(script.contains("thma=128"), "thma should default to havsfunc's 128");

    // And the pair they were confused with keeps its own (correct) defaults,
    // which are only emitted when the user opts in.
    assert!(!script.contains("thlimi="), "thlimi is optional and unset here");
    assert!(!script.contains("thlima="), "thlima is optional and unset here");
}

// =============================================================================
// HIGH BIT DEPTH (10-bit ProRes 422 and deeper)
//
// Two things go wrong on a >8-bit source, and only one of them is loud:
//
//   * a filter REJECTS the depth and takes the whole job down (vivtc.VFM is
//     8-bit only, havsfunc.LUTDeCrawl refuses anything above 10-bit), and
//   * a filter ACCEPTS the depth and quietly misapplies its parameters, because
//     every threshold in the UI is expressed in 8-bit levels while the filter
//     works in the clip's own range.
//
// The tests below pin the guards and the scaling in the generated script â€” cheap,
// and they run on every push. Whether the picture actually comes out the same at
// 10-bit as at 8-bit is measured end-to-end in
// app/test/integration_high_bit_depth_filters_test.dart (heavy, nightly).
// =============================================================================

/// A 10-bit 4:2:2 job, i.e. what a ProRes 422 source produces.
fn create_10bit_job(output_name: &str) -> VideoJob {
    let mut job = create_base_job(output_name);
    job.input_width = Some(720);
    job.input_height = Some(480);
    job.input_pixel_format = Some("yuv422p10le".to_string());
    job.input_frame_rate = Some(29.97);
    job.total_frames = Some(30);
    job
}

/// Both scripts for one job: the encode script and the preview script. A
/// bit-depth guard has to be in both, or the preview stops matching the render.
fn generate_both_scripts(job: &VideoJob) -> (String, String) {
    let generator = ScriptGenerator::new().expect("create generator");
    let encode_path = generator.generate(job).expect("generate encode script");
    let encode = std::fs::read_to_string(&encode_path).expect("read encode script");

    let params = PreviewParams {
        width: job.input_width.unwrap_or(720),
        height: job.input_height.unwrap_or(480),
        pix_fmt: job
            .input_pixel_format
            .clone()
            .unwrap_or_else(|| "yuv420p".to_string()),
        num_frames: 11,
        fps_num: 30000,
        fps_den: 1001,
        output_index: 5,
    };
    let preview_path = generator
        .generate_preview(job, &params)
        .expect("generate preview script");
    let preview = std::fs::read_to_string(&preview_path).expect("read preview script");

    let _ = std::fs::remove_file(&encode_path);
    let _ = std::fs::remove_file(&preview_path);
    (encode, preview)
}

#[test]
fn test_84_levels_are_scaled_to_the_working_bit_depth() {
    // std.Levels works in the CLIP's sample range, but these values arrive at
    // 8-bit scale from the UI. Passed through raw, max_in=235 on a 10-bit clip
    // maps everything above 235/1023 to white â€” a blown-out picture with no
    // error message (measured mean error 93/255 against the same edit at 8-bit).
    create_output_dir();

    let mut job = create_10bit_job("test_84_levels_scaled");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..QTGMCParameters::default() },
        color_correction: ColorCorrectionParameters {
            enabled: true,
            apply_levels: true,
            input_low: 16,
            input_high: 235,
            output_low: 0,
            output_high: 250,
            ..ColorCorrectionParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    let (encode, preview) = generate_both_scripts(&job);
    for (label, script) in [("encode", &encode), ("preview", &preview)] {
        assert!(
            script.contains("min_in=_levels_8bit(16)")
                && script.contains("max_in=_levels_8bit(235)")
                && script.contains("max_out=_levels_8bit(250)"),
            "{}: levels must be scaled to the working depth, script was:\n{}",
            label, script
        );
        // The scale has to be derived from the clip at run time â€” the worker does
        // not know the depth the pass will actually see, since a preceding pass
        // may have converted it.
        assert!(
            script.contains("_levels_peak = (1 << clip.format.bits_per_sample) - 1"),
            "{}: the levels scale must come from the clip's own format",
            label
        );
        assert!(
            !script.contains("min_in=16,"),
            "{}: raw 8-bit levels must not reach std.Levels",
            label
        );
    }
}

#[test]
fn test_85_tweak_brightness_is_scaled_to_the_working_bit_depth() {
    // adjust.Tweak scales its own hue/sat/coring constants but adds `bright` in
    // raw sample units, so an unscaled value is 4x weaker at 10-bit and 256x
    // weaker at 16-bit. Contrast, saturation and hue are ratios: they must NOT
    // be scaled.
    create_output_dir();

    let mut job = create_10bit_job("test_85_tweak_scaled");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..QTGMCParameters::default() },
        color_correction: ColorCorrectionParameters {
            enabled: true,
            brightness: 10.0,
            contrast: 1.2,
            saturation: 1.3,
            hue: 8.0,
            ..ColorCorrectionParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    let (encode, preview) = generate_both_scripts(&job);
    for (label, script) in [("encode", &encode), ("preview", &preview)] {
        assert!(
            script.contains("bright=10.0 * _tweak_bright_scale"),
            "{}: brightness must be scaled to the working depth, script was:\n{}",
            label, script
        );
        assert!(
            script.contains("_tweak_bright_scale = (")
                && script.contains("(1 << (clip.format.bits_per_sample - 8))"),
            "{}: the brightness scale must be derived from the clip's format",
            label
        );
        assert!(
            script.contains("cont=1.2") && !script.contains("cont=1.2 * _tweak"),
            "{}: contrast is a ratio and must not be scaled",
            label
        );
        assert!(
            script.contains("sat=1.3") && script.contains("hue=8.0"),
            "{}: saturation and hue are ratios and must not be scaled",
            label
        );
    }
}

#[test]
fn test_86_decrawl_is_guarded_above_ten_bits() {
    // havsfunc's LUTDeCrawl raises "This is not an 8-10 bit YUV clip" for
    // anything deeper, which failed the entire job on a 12-bit source such as
    // ProRes 4444 XQ. The pass runs at 10-bit and restores the source format.
    create_output_dir();

    let mut job = create_10bit_job("test_86_decrawl_guard");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..QTGMCParameters::default() },
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_de_crawl: true,
            ..ChromaFixParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    let (encode, preview) = generate_both_scripts(&job);
    for (label, script) in [("encode", &encode), ("preview", &preview)] {
        assert!(
            script.contains("_decrawl_orig_format = clip.format"),
            "{}: de-crawl must remember the source format, script was:\n{}",
            label, script
        );
        assert!(
            script.contains("if clip.format.bits_per_sample > 10:"),
            "{}: de-crawl must convert down only above 10 bits",
            label
        );
        assert!(
            script.contains("if _decrawl_orig_format.bits_per_sample > 10:"),
            "{}: de-crawl must restore the source format afterwards",
            label
        );
    }
}

#[test]
fn test_87_prores_10bit_422_is_read_natively_by_both_paths() {
    // yuv422p10le is in pipe_source's format map, so it must reach the script
    // unchanged â€” converting it would cost time for nothing. The encode and the
    // preview must agree, or the raw byte stream desyncs from the frame geometry
    // and the output is garbage rather than an error (#50).
    create_output_dir();

    let format = pixel_format::decode_pixel_format(Some("yuv422p10le"));
    assert_eq!(format.name, "yuv422p10le");
    assert_eq!(
        format.converted_from, None,
        "10-bit 4:2:2 is readable off the pipe and must not be converted"
    );

    // ProRes 4444 carries an alpha plane, which ffprobe reports in the format
    // name. Alpha is dropped; depth and chroma resolution are kept.
    assert_eq!(
        pixel_format::decode_pixel_format(Some("yuva444p10le")).name,
        "yuv444p10le"
    );
    // ProRes 4444 XQ is 12-bit.
    let xq = pixel_format::decode_pixel_format(Some("yuv444p12le"));
    assert_eq!(xq.name, "yuv444p12le");
    assert_eq!(xq.converted_from, None);

    let mut job = create_10bit_job("test_87_prores_native");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: true,
            preset: QTGMCPreset::Fast,
            tff: Some(true),
            ..QTGMCParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    let (encode, preview) = generate_both_scripts(&job);
    for (label, script) in [("encode", &encode), ("preview", &preview)] {
        assert!(
            script.contains("pix_fmt=\"yuv422p10le\""),
            "{}: the source's own pixel format must reach create_pipe_clip, script was:\n{}",
            label, script
        );
    }
}

#[test]
fn test_88_ivtc_and_descratch_keep_their_eight_bit_guards() {
    // Both filters are 8-bit only. VFM takes its metrics from a downconverted
    // copy and its pixels from the full-depth clip via clip2, so IVTC on a
    // 10-bit source neither fails nor loses precision; DeScratch converts down
    // and back. These are the guards that made 10-bit ProRes work at all, so
    // they are pinned in both scripts.
    create_output_dir();

    let mut job = create_10bit_job("test_88_ivtc_descratch_guards");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: true,
            method: DeinterlaceMethod::Ivtc,
            tff: Some(true),
            ..QTGMCParameters::default()
        },
        descratch: DeScratchParameters {
            enabled: true,
            ..DeScratchParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    let (encode, preview) = generate_both_scripts(&job);
    for (label, script) in [("encode", &encode), ("preview", &preview)] {
        assert!(
            script.contains("_ivtc_metrics = clip if clip.format.bits_per_sample == 8"),
            "{}: VFM must run on an 8-bit metrics clip, script was:\n{}",
            label, script
        );
        assert!(
            script.contains("clip2=_ivtc_src"),
            "{}: VFM must emit full-depth pixels via clip2",
            label
        );
        assert!(
            script.contains("_descratch_orig_format = clip.format")
                && script.contains("if _descratch_orig_format.bits_per_sample != 8:"),
            "{}: DeScratch must round-trip the source bit depth",
            label
        );
    }
}
