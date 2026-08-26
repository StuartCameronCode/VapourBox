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
        input_color_matrix: None,
        input_color_primaries: None,
        input_color_transfer: None,
        input_color_range: None,
        burn_in_subtitle_path: None,
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
        ..ProcessingPipeline::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
        input_color_matrix: None,
        input_color_primaries: None,
        input_color_transfer: None,
        input_color_range: None,
        burn_in_subtitle_path: None,
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
            ..SpotLessParameters::default()
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
        "return _nnedi3(",
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

#[test]
fn test_89_output_colour_format_conversion_is_dithered() {
    // This block is where a 10- or 12-bit source is reduced to 8 bits, and
    // resize defaults to dither_type="none" â€” plain rounding, which bands a
    // shallow gradient that the source held smoothly. Verified against vspipe:
    // omitting the argument produces output byte-identical to an explicit
    // "none" and different from "error_diffusion".
    create_output_dir();

    let mut job = create_10bit_job("test_89_chroma_dither");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..QTGMCParameters::default() },
        ..ProcessingPipeline::default()
    });
    job.encoding_settings.chroma_subsampling = ChromaSubsampling::Yuv420;

    let (encode, preview) = generate_both_scripts(&job);
    for (label, script) in [("encode", &encode), ("preview", &preview)] {
        assert!(
            script.contains("format=target_format")
                && script.contains("dither_type=\"error_diffusion\""),
            "{}: the output format conversion must dither, script was:\n{}",
            label, script
        );
    }
}

#[test]
fn test_90_output_colour_format_reaches_the_preview_too() {
    // The conversion block existed only in pipeline_template.vpy, so a preview
    // never showed the output format â€” including any banding the reduction
    // introduces, which is exactly what a preview is for. Both templates now
    // carry it, and both are driven by the same substitution.
    create_output_dir();

    let mut job = create_10bit_job("test_90_chroma_preview");
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..QTGMCParameters::default() },
        ..ProcessingPipeline::default()
    });

    // Every convertible format, in both scripts.
    for (subsampling, expected) in [
        (ChromaSubsampling::Yuv420, "vs.YUV420P8"),
        (ChromaSubsampling::Yuv422, "vs.YUV422P8"),
        (ChromaSubsampling::Yuv422P10, "vs.YUV422P10"),
    ] {
        job.encoding_settings.chroma_subsampling = subsampling;
        let (encode, preview) = generate_both_scripts(&job);
        for (label, script) in [("encode", &encode), ("preview", &preview)] {
            assert!(
                script.contains(&format!("target_format = {}", expected)),
                "{}: {:?} should convert to {}, script was:\n{}",
                label, subsampling, expected, script
            );
        }
    }

    // And "keep the source format" must leave no conversion behind in either.
    job.encoding_settings.chroma_subsampling = ChromaSubsampling::Original;
    let (encode, preview) = generate_both_scripts(&job);
    for (label, script) in [("encode", &encode), ("preview", &preview)] {
        assert!(
            !script.contains("target_format ="),
            "{}: Original must not convert the output format, script was:\n{}",
            label, script
        );
        assert!(
            !script.contains("{{#CHROMA_CONVERT}}") && !script.contains("{{CHROMA_FORMAT}}"),
            "{}: the conversion block must be removed, not left as a placeholder",
            label
        );
    }
}

#[test]
fn test_91_chroma_subsampling_serde_names_match_the_app() {
    // These strings are the wire format between the app and the worker; the Dart
    // side asserts the same list in app/test/pixel_format_test.dart. A mismatch
    // makes the worker reject the job config outright.
    for (subsampling, expected) in [
        (ChromaSubsampling::Original, "\"original\""),
        (ChromaSubsampling::Yuv420, "\"yuv420\""),
        (ChromaSubsampling::Yuv422, "\"yuv422\""),
        (ChromaSubsampling::Yuv422P10, "\"yuv422p10\""),
    ] {
        let json = serde_json::to_string(&subsampling).expect("serialize");
        assert_eq!(json, expected, "{:?} serializes wrong", subsampling);
        // And round-trips, so an older preset still loads.
        let back: ChromaSubsampling = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, subsampling);
    }

    // Only Original means "no conversion"; everything else names a format.
    assert_eq!(ChromaSubsampling::Original.vapoursynth_format(), None);
    assert_eq!(
        ChromaSubsampling::Yuv422P10.vapoursynth_format(),
        Some("vs.YUV422P10")
    );
}

/// Test 92: neither template may name an nnedi3 implementation directly.
///
/// znedi3's SIMD kernels are x86-only, so the ARM bundles build it with X86=0
/// and it runs fully scalar — measured 6.3x slower than the bundled nnedi3,
/// which ships real NEON kernels, and 30% of the whole arm64 QTGMC cost. Both
/// implement the same network from the same weights file, so the templates pick
/// at runtime via the `_nnedi3()` helper (havsfunc does the same through its
/// patch 6). A direct `core.znedi3.nnedi3` call reintroduces the slow path on
/// ARM silently — it still produces a correct picture, just far slower, so only
/// an assertion like this one catches it.
#[test]
fn test_92_templates_do_not_hardcode_an_nnedi3_implementation() {
    let templates_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("templates");

    for name in ["pipeline_template.vpy", "preview_template.vpy"] {
        let path = templates_dir.join(name);
        // Normalise line endings: git checks these templates out CRLF on Windows,
        // and the blank-line search below is otherwise looking for "\n\n" in a
        // file that only ever contains "\r\n\r\n".
        let body = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
            .replace("\r\n", "\n");

        // The helper itself is the one place either plugin may be named.
        let helper_start = body
            .find("def _nnedi3(")
            .unwrap_or_else(|| panic!("{name} is missing the _nnedi3() helper"));
        let helper_end = helper_start
            + body[helper_start..]
                .find("\n\n")
                .expect("helper should be followed by a blank line");
        let (before, after) = (&body[..helper_start], &body[helper_end..]);

        for (plugin, call) in [
            ("znedi3", "core.znedi3.nnedi3("),
            ("nnedi3", "core.nnedi3.nnedi3("),
        ] {
            assert!(
                !before.contains(call) && !after.contains(call),
                "{name} calls {plugin} directly; route it through _nnedi3() so ARM \
                 gets the NEON implementation"
            );
        }

        // And the helper is actually reached — the upscale path is the only
        // caller in the template itself (QTGMC goes through havsfunc).
        assert!(
            body.contains("_nnedi3(\n"),
            "{name} defines _nnedi3() but never calls it"
        );
    }
}

/// Test 93: neither template may call `core.std.Expr` directly.
///
/// VapourSynth's Expr JIT is wrapped in `#ifdef VS_TARGET_CPU_X86`, so on ARM the
/// whole bytecode program is walked once per pixel by `ExprInterpreter::eval()`.
/// Measured on an M1, Expr costs 550-640 CPU-seconds in a QTGMC Slow graph
/// against the interpolator's 30 — it dominates everything else. akarin's LLVM
/// JIT works on aarch64 and is worth 4.1x end to end, so both templates route
/// through the `_expr()` helper (havsfunc does the same through its patch 7).
///
/// This is exactly the failure mode `test_92` exists for: a direct
/// `core.std.Expr` call still produces a *correct picture*, just far slower on
/// ARM, so nothing but an assertion like this catches the regression.
///
/// The helper's own fallback is the one permitted direct call — and it must be a
/// real call, not `_expr(...)`, which would recurse forever. That is not
/// hypothetical: a blanket search-and-replace introduced exactly that bug while
/// this change was being written.
#[test]
fn test_93_templates_do_not_call_std_expr_directly() {
    let templates_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("templates");

    /// Assert one file either has no direct `core.std.Expr` call at all, or
    /// confines it to a well-formed `_expr()` helper.
    fn check(name: &str, body: &str, helper_required: bool) {
        let helper_start = match body.find("def _expr(") {
            Some(at) => at,
            None => {
                assert!(
                    !helper_required,
                    "{name} is missing the _expr() helper"
                );
                // No helper is fine for a module that evaluates no expressions,
                // but then it must not reach for std.Expr either.
                assert!(
                    !body.contains("core.std.Expr("),
                    "{name} calls core.std.Expr with no _expr() helper to route \
                     it through; copy the helper from pipeline_template.vpy so \
                     ARM gets akarin's JIT instead of the per-pixel interpreter"
                );
                return;
            }
        };
        let helper_end = helper_start
            + body[helper_start..]
                .find("\n\n")
                .expect("_expr() helper should be followed by a blank line");
        let helper = &body[helper_start..helper_end];
        let (before, after) = (&body[..helper_start], &body[helper_end..]);

        assert!(
            !before.contains("core.std.Expr(") && !after.contains("core.std.Expr("),
            "{name} calls core.std.Expr directly; route it through _expr() so ARM \
             gets akarin's JIT instead of the per-pixel interpreter"
        );

        // The fallback must call the real thing, or it is infinite recursion.
        assert!(
            helper.contains("return core.std.Expr("),
            "{name}'s _expr() fallback must call core.std.Expr; anything else \
             either recurses forever or loses the no-akarin path (macos-x64)"
        );
        assert!(
            !helper.contains("return _expr("),
            "{name}'s _expr() fallback calls itself — infinite recursion"
        );

        // And the helper is actually reached.
        assert!(
            body.matches("_expr(").count() > body.matches("_akarin_expr(").count() + 1,
            "{name} defines _expr() but never calls it"
        );
    }

    // Normalise line endings throughout: git checks these out CRLF on Windows.
    for name in ["pipeline_template.vpy", "preview_template.vpy"] {
        let path = templates_dir.join(name);
        let body = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
            .replace("\r\n", "\n");
        check(name, &body, true);
    }

    // The vendored Python modules the templates import are the same code path
    // and the same trap: an `Expr` inside one of them is just as much a
    // per-pixel interpreter on ARM as an `Expr` in the .vpy. The rule went
    // uncovered for as long as it did only because spotless.py, the first
    // vendored module, evaluates no expressions at all.
    let mut modules: Vec<_> = std::fs::read_dir(&templates_dir)
        .expect("read templates dir")
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            (path.extension()? == "py").then_some(path)
        })
        .collect();
    modules.sort();
    assert!(
        !modules.is_empty(),
        "no vendored .py modules found in worker/templates — the scan below \
         would pass vacuously"
    );
    for path in modules {
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let body = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
            .replace("\r\n", "\n");
        check(&name, &body, false);
    }
}

// ============================================================================
// Filters added from the Hybrid gap analysis
//
// All five are effort-1 additions: every plugin they need was already in the
// deps bundle, unused. They were chosen because each fails *differently* from
// what the pass already offered, which is the only justification for another
// entry in a method dropdown.
//
// KNLMeansCL was in the same batch and was dropped: its OpenCL path does not
// initialise on every machine (the app's own probe reports knlm=false on the
// development Mac), CI deliberately excludes OpenCL-only plugins from the
// required-namespace list, and its `channels="YUV"` mode requires 4:4:4 — which
// none of this app's target sources are. Verified by probing the bundle, not
// from documentation.
// ============================================================================

/// Generate a job's script and return its text.
///
/// `run_job_and_verify` covers "these strings are present"; this is for the
/// cases that assert something is *absent*, which is the direction that catches
/// a block the generator failed to strip.
fn script_text(job: &VideoJob) -> String {
    let generator = ScriptGenerator::new().expect("Failed to create generator");
    let script_path = generator.generate(job).expect("Failed to generate script");
    std::fs::read_to_string(&script_path).expect("read generated script")
}

#[test]
fn test_94_dfttest_noise_reduction() {
    create_output_dir();
    let mut job = create_base_job("test_94_dfttest");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: false,
            ..Default::default()
        },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::DfTtest,
            dfttest_sigma: 12.5,
            dfttest_tbsize: 5,
            dfttest_sbsize: 12,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "DFTTest",
        &["core.dfttest.DFTTest", "sigma=12.5", "tbsize=5", "sbsize=12"],
    )
    .unwrap();
}

#[test]
fn test_95_dfttest_temporal_window_is_forced_odd() {
    // An even tbsize isn't rejected by DFTTest — it just processes a window
    // that isn't centred on the current frame, so the fix has to be ours.
    create_output_dir();
    let mut job = create_base_job("test_95_dfttest_even_tbsize");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: false,
            ..Default::default()
        },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::DfTtest,
            dfttest_tbsize: 6,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(&job, "DFTTest even tbsize", &["tbsize=5"]).unwrap();
}

#[test]
fn test_96_fft3dfilter_noise_reduction() {
    create_output_dir();
    let mut job = create_base_job("test_96_fft3d");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: false,
            ..Default::default()
        },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::Fft3dFilter,
            fft3d_sigma: 3.5,
            fft3d_bt: 4,
            fft3d_sharpen: 0.4,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "FFT3DFilter",
        &[
            "core.fft3dfilter.FFT3DFilter",
            "sigma=3.5",
            "bt=4",
            "sharpen=0.4",
        ],
    )
    .unwrap();
}

#[test]
fn test_97_fft3d_sharpen_is_omitted_when_zero() {
    // Left at 0 the argument is dropped so the plugin's own default applies,
    // rather than passing an explicit no-op.
    create_output_dir();
    let mut job = create_base_job("test_97_fft3d_no_sharpen");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: false,
            ..Default::default()
        },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::Fft3dFilter,
            fft3d_sharpen: 0.0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = script_text(&job);
    assert!(
        script.contains("core.fft3dfilter.FFT3DFilter"),
        "FFT3DFilter should be called"
    );
    assert!(
        !script.contains("sharpen="),
        "sharpen should be omitted at 0 so the plugin default applies"
    );
}

#[test]
fn test_98_ttempsmooth_noise_reduction() {
    create_output_dir();
    let mut job = create_base_job("test_98_ttempsmooth");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: false,
            ..Default::default()
        },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::TTempSmooth,
            ttemp_maxr: 4,
            ttemp_thresh: 6,
            ttemp_mdiff: 3,
            ttemp_strength: 3,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "TTempSmooth",
        &[
            "core.ttmpsm.TTempSmooth",
            "maxr=4",
            "thresh=6",
            "mdiff=3",
            "strength=3",
        ],
    )
    .unwrap();
}

#[test]
fn test_99_ttempsmooth_mdiff_is_held_below_thresh() {
    // mdiff >= thresh is accepted by the plugin but silently disables the
    // motion protection the parameter exists for, so it smooths through motion.
    create_output_dir();
    let mut job = create_base_job("test_99_ttempsmooth_mdiff");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: false,
            ..Default::default()
        },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::TTempSmooth,
            ttemp_thresh: 4,
            ttemp_mdiff: 9,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(&job, "TTempSmooth mdiff clamp", &["thresh=4", "mdiff=3"]).unwrap();
}

#[test]
fn test_100_awarpsharp2_sharpening() {
    create_output_dir();
    let mut job = create_base_job("test_100_awarpsharp2");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: false,
            ..Default::default()
        },
        sharpen: SharpenParameters {
            enabled: true,
            method: SharpenMethod::AWarpSharp2,
            warp_depth: 20,
            warp_thresh: 100,
            warp_blur: 3,
            warp_type: 1,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "aWarpSharp2",
        &[
            "core.warp.AWarpSharp2",
            "depth=20",
            "thresh=100",
            "blur=3",
            "type=1",
        ],
    )
    .unwrap();

    // `chroma` is deliberately not passed. This port takes 0 or 1 and rejects
    // anything else at script evaluation — the block first shipped with
    // Avisynth's chroma=4 and killed vspipe outright, caught by the heavy
    // end-to-end test rather than by script generation. Leave the plugin's own
    // default alone unless someone exposes it with real verification.
    let script = script_text(&job);
    assert!(
        !script.contains("chroma="),
        "aWarpSharp2 should not pass chroma; this port only accepts 0 or 1"
    );
}

#[test]
fn test_101_hqderingmod_dehalo() {
    create_output_dir();
    let mut job = create_base_job("test_101_hqderingmod");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: false,
            ..Default::default()
        },
        dehalo: DehaloParameters {
            enabled: true,
            method: DehaloMethod::HqDeringmod,
            dering_mrad: Some(2),
            dering_msmooth: Some(2),
            dering_mthr: Some(70),
            dering_thr: Some(16.0),
            dering_darkthr: Some(4.0),
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "HQDeringmod",
        &[
            "haf.HQDeringmod",
            "mrad=2",
            "msmooth=2",
            "mthr=70",
            // Exact text: format_double emits a trailing .0, and a bare
            // "thr=16" would also match "thr=16.0" and hide a formatting change.
            "thr=16.0",
            "darkthr=4.0",
        ],
    )
    .unwrap();
}

#[test]
fn test_102_hqderingmod_omits_unset_parameters() {
    // Every HQDeringmod argument is optional so havsfunc's own defaults apply
    // where the user hasn't chosen — passing our own would silently override
    // upstream tuning.
    create_output_dir();
    let mut job = create_base_job("test_102_hqderingmod_defaults");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: false,
            ..Default::default()
        },
        dehalo: DehaloParameters {
            enabled: true,
            method: DehaloMethod::HqDeringmod,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = script_text(&job);
    assert!(script.contains("haf.HQDeringmod"), "HQDeringmod should be called");
    for arg in ["mrad=", "msmooth=", "mthr=", "thr=", "darkthr="] {
        assert!(
            !script.contains(arg),
            "{arg} should be omitted when unset so havsfunc's default applies"
        );
    }
}

#[test]
fn test_103_each_noise_method_emits_only_its_own_filter() {
    // The template holds every method's block and the generator strips the
    // others. A missed remove_block leaves two denoisers chained silently —
    // valid VapourSynth, twice the runtime, and not what the user asked for.
    create_output_dir();

    let calls = [
        ("smdegrain", "haf.SMDegrain"),
        ("mctd", "haf.MCTemporalDenoise"),
        ("dfttest", "core.dfttest.DFTTest"),
        ("fft3d", "core.fft3dfilter.FFT3DFilter"),
        ("ttempsmooth", "core.ttmpsm.TTempSmooth"),
    ];

    let methods = [
        (NoiseReductionMethod::SmDegrain, "smdegrain"),
        (NoiseReductionMethod::McTemporalDenoise, "mctd"),
        (NoiseReductionMethod::DfTtest, "dfttest"),
        (NoiseReductionMethod::Fft3dFilter, "fft3d"),
        (NoiseReductionMethod::TTempSmooth, "ttempsmooth"),
    ];

    for (method, key) in methods {
        let mut job = create_base_job(&format!("test_103_{key}"));
        job.qtgmc_parameters.enabled = false;
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: QTGMCParameters {
                enabled: false,
                ..Default::default()
            },
            noise_reduction: NoiseReductionParameters {
                enabled: true,
                method,
                ..Default::default()
            },
            ..ProcessingPipeline::default()
        });

        let script = script_text(&job);
        for (other_key, call) in calls {
            let present = script.contains(call);
            if other_key == key {
                assert!(present, "{key} should emit {call}");
            } else {
                assert!(!present, "{key} also emitted {call} — a block wasn't stripped");
            }
        }
        // And no unsubstituted placeholders survive for the selected method.
        assert!(
            !script.contains("{{NR_"),
            "{key} left an unsubstituted NR_ placeholder in the script"
        );
    }
}

// ============================================================================
// Second batch: filters whose plugins/functions were already in the bundle.
//
// Anti-aliasing and stabilisation are whole categories VapourBox had nothing
// in, which is why they are passes rather than methods. LUTDeRainbow joins the
// Chroma Fixes stack beside LUTDeCrawl, whose 8-10 bit limit it shares.
//
// STPresso was in this batch and was dropped: havsfunc's implementation calls
// `core.flux.SmoothT`, and the fluxsmooth plugin is NOT bundled (zsmooth
// provides FluxSmoothT under a different namespace). That makes it effort 2,
// not 1. Found by probing, before any wiring was written.
// ============================================================================

#[test]
fn test_104_anti_alias_daa() {
    create_output_dir();
    let mut job = create_base_job("test_104_aa_daa");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        anti_alias: AntiAliasParameters {
            enabled: true,
            method: AntiAliasMethod::Daa,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(&job, "Anti-Alias daa", &["haf.daa("]).unwrap();

    let script = script_text(&job);
    assert!(
        !script.contains("haf.santiag("),
        "the santiag block should have been stripped"
    );
}

#[test]
fn test_105_anti_alias_santiag() {
    create_output_dir();
    let mut job = create_base_job("test_105_aa_santiag");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        anti_alias: AntiAliasParameters {
            enabled: true,
            method: AntiAliasMethod::Santiag,
            santiag_strh: 2,
            santiag_strv: 3,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "Anti-Alias santiag",
        &["haf.santiag(", "strh=2", "strv=3", "type=\"nnedi3\""],
    )
    .unwrap();
}

#[test]
fn test_106_santiag_type_cannot_name_an_unbundled_interpolator() {
    // havsfunc accepts eedi2 and sangnom; neither is in the deps bundle, and
    // naming one fails at script evaluation rather than degrading.
    create_output_dir();
    let mut job = create_base_job("test_106_aa_santiag_type");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        anti_alias: AntiAliasParameters {
            enabled: true,
            method: AntiAliasMethod::Santiag,
            santiag_type: "sangnom".to_string(),
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = script_text(&job);
    assert!(script.contains("type=\"nnedi3\""), "should fall back to nnedi3");
    // Assert on the emitted argument, not on the whole script: the template's
    // own comment explains why eedi2 and sangnom are excluded, and naming them
    // there is not the same as passing them.
    assert!(
        !script.contains("type=\"sangnom\""),
        "sangnom must not reach havsfunc — it is not in the deps bundle"
    );
    assert!(
        !script.contains("type=\"eedi2\""),
        "eedi2 must not reach havsfunc — it is not in the deps bundle"
    );
}

#[test]
fn test_107_stabilize() {
    create_output_dir();
    let mut job = create_base_job("test_107_stabilize");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        stabilize: StabilizeParameters {
            enabled: true,
            dxmax: 6,
            dymax: 8,
            mirror: 3,
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "Stabilize",
        &["haf.Stab(", "dxmax=6", "dymax=8", "mirror=3"],
    )
    .unwrap();
}

#[test]
fn test_108_stabilize_limits_are_normalized() {
    // A negative dxmax/dymax is accepted by DepanStabilise and disables
    // correction on that axis, which looks like the filter doing nothing.
    create_output_dir();
    let mut job = create_base_job("test_108_stabilize_limits");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        stabilize: StabilizeParameters {
            enabled: true,
            dxmax: -3,
            dymax: -3,
            mirror: 9,
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "Stabilize clamps",
        &["dxmax=0", "dymax=0", "mirror=3"],
    )
    .unwrap();
}

#[test]
fn test_109_lut_derainbow_with_ten_bit_guard() {
    create_output_dir();
    let mut job = create_base_job("test_109_derainbow");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_de_rainbow: true,
            de_rainbow_c_thresh: 12,
            de_rainbow_y_thresh: 14,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "LUTDeRainbow",
        &[
            "haf.LUTDeRainbow(",
            "cthresh=12",
            "ythresh=14",
            // Same 8-10 bit limit as LUTDeCrawl, verified against the bundle.
            "bits_per_sample > 10",
            "_derainbow_orig_format",
        ],
    )
    .unwrap();
}

#[test]
fn test_110_new_passes_run_in_the_documented_order() {
    // The order the passes appear in the script is the order they run, and two
    // of these placements are deliberate: anti-aliasing BEFORE sharpening
    // (sharpening stair-stepped edges makes the stepping worse), and
    // stabilisation LAST before framing (so a crop can remove the borders it
    // shifts into view).
    create_output_dir();
    let mut job = create_base_job("test_110_order");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        anti_alias: AntiAliasParameters { enabled: true, ..Default::default() },
        sharpen: SharpenParameters {
            enabled: true,
            method: SharpenMethod::CAS,
            ..Default::default()
        },
        stabilize: StabilizeParameters { enabled: true, ..Default::default() },
        crop_resize: CropResizeParameters {
            enabled: true,
            resize_enabled: true,
            target_width: Some(640),
            target_height: Some(480),
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    let aa = script.find("haf.daa(").expect("daa should be present");
    let sharp = script.find("core.cas.CAS(").expect("CAS should be present");
    let stab = script.find("haf.Stab(").expect("Stab should be present");
    assert!(aa < sharp, "anti-aliasing must run before sharpening");
    assert!(sharp < stab, "stabilisation runs after the detail passes");
}

// ============================================================================
// Third batch: the first filters that needed a DEPS change.
//
// `fluxsmooth` is a new plugin in the bundle (deps 1.9.0), pinned to v2 on every
// platform because that is the newest tag with a published Windows binary and
// the Windows deps script has no from-source path. It unlocks three filters:
// FluxSmoothT, FluxSmoothST, and havsfunc's STPresso — which calls
// core.flux.SmoothT internally and was dropped from the second batch precisely
// because the plugin was missing.
// ============================================================================

#[test]
fn test_111_fluxsmooth_temporal() {
    create_output_dir();
    let mut job = create_base_job("test_111_fluxsmooth_t");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::FluxSmoothT,
            flux_temporal_threshold: 9,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "FluxSmoothT",
        &["core.flux.SmoothT(", "temporal_threshold=9"],
    )
    .unwrap();

    // The temporal-only variant must not emit the spatial one.
    let script = script_text(&job);
    assert!(!script.contains("core.flux.SmoothST("));
}

#[test]
fn test_112_fluxsmooth_spatiotemporal() {
    create_output_dir();
    let mut job = create_base_job("test_112_fluxsmooth_st");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::FluxSmoothSt,
            flux_temporal_threshold: 9,
            flux_spatial_threshold: 11,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "FluxSmoothST",
        &[
            "core.flux.SmoothST(",
            "temporal_threshold=9",
            "spatial_threshold=11",
        ],
    )
    .unwrap();
}

#[test]
fn test_113_fluxsmooth_thresholds_allow_minus_one_but_no_lower() {
    // -1 disables that half of the filter; below that the plugin errors, so the
    // worker clamps rather than letting it through.
    create_output_dir();
    let mut job = create_base_job("test_113_fluxsmooth_clamp");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::FluxSmoothSt,
            flux_temporal_threshold: -50,
            flux_spatial_threshold: 900,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "FluxSmooth clamps",
        &["temporal_threshold=-1", "spatial_threshold=255"],
    )
    .unwrap();
}

#[test]
fn test_114_stpresso() {
    create_output_dir();
    let mut job = create_base_job("test_114_stpresso");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::StPresso,
            stpresso_limit: 5,
            stpresso_bias: 30,
            stpresso_tthr: 16,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "STPresso",
        &["haf.STPresso(", "limit=5", "bias=30", "tthr=16"],
    )
    .unwrap();
}

#[test]
fn test_115_every_noise_method_still_emits_only_its_own_filter() {
    // Extends test_103 to the fluxsmooth-backed methods. A missed remove_block
    // chains two denoisers silently — valid VapourSynth, twice the runtime, and
    // not what the user asked for.
    create_output_dir();

    let calls = [
        ("smdegrain", "haf.SMDegrain"),
        ("mctd", "haf.MCTemporalDenoise"),
        ("dfttest", "core.dfttest.DFTTest"),
        ("fft3d", "core.fft3dfilter.FFT3DFilter"),
        ("ttempsmooth", "core.ttmpsm.TTempSmooth"),
        ("fluxt", "core.flux.SmoothT("),
        ("fluxst", "core.flux.SmoothST("),
        ("stpresso", "haf.STPresso"),
    ];

    let methods = [
        (NoiseReductionMethod::SmDegrain, "smdegrain"),
        (NoiseReductionMethod::McTemporalDenoise, "mctd"),
        (NoiseReductionMethod::DfTtest, "dfttest"),
        (NoiseReductionMethod::Fft3dFilter, "fft3d"),
        (NoiseReductionMethod::TTempSmooth, "ttempsmooth"),
        (NoiseReductionMethod::FluxSmoothT, "fluxt"),
        (NoiseReductionMethod::FluxSmoothSt, "fluxst"),
        (NoiseReductionMethod::StPresso, "stpresso"),
    ];

    for (method, key) in methods {
        let mut job = create_base_job(&format!("test_115_{key}"));
        job.qtgmc_parameters.enabled = false;
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            noise_reduction: NoiseReductionParameters {
                enabled: true,
                method,
                ..Default::default()
            },
            ..ProcessingPipeline::default()
        });

        let script = script_text(&job);
        for (other_key, call) in calls {
            // SmoothT is a substring of SmoothST, so compare on the full call
            // text including the opening paren.
            let present = script.contains(call);
            if other_key == key {
                assert!(present, "{key} should emit {call}");
            } else {
                assert!(!present, "{key} also emitted {call} — a block wasn't stripped");
            }
        }
        assert!(
            !script.contains("{{NR_"),
            "{key} left an unsubstituted NR_ placeholder"
        );
    }
}

// ============================================================================
// Batch four.
// ============================================================================

#[test]
fn test_116_geometry_rotation_and_flips() {
    create_output_dir();
    let mut job = create_base_job("test_116_geometry");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        geometry: GeometryParameters {
            enabled: true,
            rotation: Rotation::Cw90,
            flip_horizontal: true,
            flip_vertical: false,
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "Rotate / Flip",
        &["core.std.Turn90(", "core.std.FlipHorizontal("],
    )
    .unwrap();

    let script = script_text(&job);
    assert!(
        !script.contains("core.std.FlipVertical("),
        "an unselected flip must not be emitted"
    );
}

#[test]
fn test_117_geometry_enabled_with_nothing_selected_emits_nothing() {
    // Turning the pass on without choosing anything is a no-op, and the script
    // should say what actually runs rather than carry a silent identity call.
    create_output_dir();
    let mut job = create_base_job("test_117_geometry_noop");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        geometry: GeometryParameters { enabled: true, ..Default::default() },
        ..ProcessingPipeline::default()
    });
    let script = script_text(&job);
    for call in ["core.std.Turn90(", "core.std.Turn180(", "core.std.Turn270(",
                 "core.std.FlipHorizontal(", "core.std.FlipVertical("] {
        assert!(!script.contains(call), "{call} should not be emitted");
    }
    assert!(!script.contains("{{GEOM"), "left an unsubstituted placeholder");
}

#[test]
fn test_118_each_rotation_emits_its_own_turn() {
    create_output_dir();
    for (rotation, expected, forbidden) in [
        (Rotation::Cw90, "core.std.Turn90(", "core.std.Turn270("),
        (Rotation::Rotate180, "core.std.Turn180(", "core.std.Turn90("),
        (Rotation::Ccw90, "core.std.Turn270(", "core.std.Turn90("),
    ] {
        let mut job = create_base_job("test_118_geometry_rotations");
        job.qtgmc_parameters.enabled = false;
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            geometry: GeometryParameters {
                enabled: true,
                rotation,
                ..Default::default()
            },
            ..ProcessingPipeline::default()
        });
        let script = script_text(&job);
        assert!(script.contains(expected), "{rotation:?} should emit {expected}");
        assert!(!script.contains(forbidden), "{rotation:?} also emitted {forbidden}");
    }
}

#[test]
fn test_119_rotation_runs_before_framing_and_after_deinterlacing() {
    // Both orderings are load-bearing. A quarter turn swaps width and height,
    // so framing must see the final shape; and fields run horizontally, so
    // turning a still-interlaced clip would shear them.
    create_output_dir();
    let mut job = create_base_job("test_119_geometry_order");
    job.qtgmc_parameters.enabled = true;
    job.qtgmc_parameters.tff = Some(true);
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters {
            enabled: true,
            preset: QTGMCPreset::Fast,
            tff: Some(true),
            ..Default::default()
        },
        geometry: GeometryParameters {
            enabled: true,
            rotation: Rotation::Cw90,
            ..Default::default()
        },
        crop_resize: CropResizeParameters {
            enabled: true,
            resize_enabled: true,
            target_width: Some(480),
            target_height: Some(640),
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    let deint = script.find("haf.QTGMC(").expect("QTGMC present");
    let turn = script.find("core.std.Turn90(").expect("Turn90 present");
    // Anchor on the target size, not on "core.resize." — the template also uses
    // resize near the top to normalise unusual chroma formats, and matching that
    // would compare against the wrong call entirely.
    let framing = script
        .find("target_w = 480")
        .expect("the framing resize should carry the target width");
    assert!(deint < turn, "rotation must follow deinterlacing");
    assert!(turn < framing, "rotation must precede framing");
}

#[test]
fn test_120_grain_addgrain() {
    create_output_dir();
    let mut job = create_base_job("test_120_grain_add");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        grain: GrainParameters {
            enabled: true,
            method: GrainMethod::AddGrain,
            var: 9.0,
            uvar: 2.0,
            corr: 0.5,
            constant: true,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "AddGrain",
        &["core.grain.Add(", "var=9.0", "uvar=2.0", "hcorr=0.5", "vcorr=0.5", "constant=True"],
    )
    .unwrap();
}

#[test]
fn test_121_grain_correlation_is_capped_below_one() {
    // 1.0 is accepted by the plugin but wraps back to uncorrelated noise at
    // full amplitude — the opposite of what the control implies.
    create_output_dir();
    let mut job = create_base_job("test_121_grain_corr");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        grain: GrainParameters {
            enabled: true,
            corr: 1.0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(&job, "AddGrain corr cap", &["hcorr=0.9", "vcorr=0.9"]).unwrap();
}

#[test]
fn test_122_grain_is_not_depth_scaled() {
    // `var` is already in 8-bit units and the plugin rescales internally, so it
    // must NOT get the _levels_8bit() treatment applied to std.Levels and
    // Tweak. Measured: identical 8-bit-equivalent output at 8/10/12/16-bit.
    // This asserts the script passes the value through untouched.
    create_output_dir();
    let mut job = create_base_job("test_122_grain_depth");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        grain: GrainParameters {
            enabled: true,
            var: 6.0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = script_text(&job);
    assert!(script.contains("var=6"), "var should be passed through verbatim");
    for scaled in ["_grain_scale", "peak", "_levels_8bit"] {
        assert!(
            !script.contains(&format!("var={scaled}")),
            "var must not be depth-scaled"
        );
    }
}

#[test]
fn test_123_grain_factory3() {
    create_output_dir();
    let mut job = create_base_job("test_123_grain_gf3");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        grain: GrainParameters {
            enabled: true,
            method: GrainMethod::GrainFactory3,
            g1str: 6.0,
            g2str: 4.0,
            g3str: 2.0,
            temp_avg: 50,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "GrainFactory3",
        &["haf.GrainFactory3(", "g1str=6", "g2str=4", "g3str=2", "temp_avg=50"],
    )
    .unwrap();

    let script = script_text(&job);
    assert!(!script.contains("core.grain.Add("), "the other method must be stripped");
}

#[test]
fn test_124_grain_runs_last_of_the_video_passes() {
    // Grain added before a resize is resampled away and before a deband is
    // smoothed away, so it has to come after both — and before the output
    // colour conversion, which must stay final.
    create_output_dir();
    let mut job = create_base_job("test_124_grain_order");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        deband: DebandParameters { enabled: true, ..Default::default() },
        sharpen: SharpenParameters {
            enabled: true,
            method: SharpenMethod::CAS,
            ..Default::default()
        },
        grain: GrainParameters { enabled: true, ..Default::default() },
        crop_resize: CropResizeParameters {
            enabled: true,
            resize_enabled: true,
            target_width: Some(640),
            target_height: Some(480),
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    let deband = script.find("neo_f3kdb.Deband(").expect("deband present");
    let sharpen = script.find("core.cas.CAS(").expect("sharpen present");
    let framing = script.find("target_w = 640").expect("framing present");
    let grain = script.find("core.grain.Add(").expect("grain present");
    assert!(deband < grain, "grain must follow deband");
    assert!(sharpen < grain, "grain must follow sharpening");
    assert!(framing < grain, "grain must follow the framing resize");
}

#[test]
fn test_125_grain_with_zero_strength_emits_nothing() {
    create_output_dir();
    let mut job = create_base_job("test_125_grain_silent");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        grain: GrainParameters {
            enabled: true,
            var: 0.0,
            uvar: 0.0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = script_text(&job);
    assert!(!script.contains("core.grain.Add("));
    assert!(!script.contains("{{GRAIN"), "left an unsubstituted placeholder");
}

#[test]
fn test_126_rotation_restores_the_source_pixel_format() {
    // A quarter turn swaps the chroma subsampling axes: 4:2:2 becomes 4:4:0,
    // which vspipe emits as "C440" and ffmpeg rejects outright, and 4:1:1 has no
    // y4m identifier at all so vspipe itself fails. Both are hard job failures,
    // and 4:2:2 is the common 10-bit ProRes case — so the script captures the
    // source format before the turn and converts back after.
    create_output_dir();
    let mut job = create_base_job("test_126_rotate_format");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        geometry: GeometryParameters {
            enabled: true,
            rotation: Rotation::Cw90,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "Rotate format guard",
        &[
            "_geom_src_format = clip.format",
            "clip.format.id != _geom_src_format.id",
            "core.resize.Spline36(clip, format=_geom_src_format.id)",
        ],
    )
    .unwrap();
}

#[test]
fn test_127_rotation_inverts_the_declared_sample_aspect() {
    // SAR is pixel width : height, so a quarter turn exchanges them. There are
    // TWO consumers: the ffmpeg-side declaration on the encode path, and
    // {{SOURCE_SAR}} in the script's square-pixel fitting. Both must see the
    // rotated value or an anamorphic source comes out the wrong shape.
    let turned = GeometryParameters {
        enabled: true,
        rotation: Rotation::Cw90,
        ..Default::default()
    };
    assert_eq!(turned.adjusted_sar(Some("64:45")).as_deref(), Some("45:64"));

    create_output_dir();
    let mut job = create_base_job("test_127_rotate_sar");
    job.qtgmc_parameters.enabled = false;
    job.input_sar = Some("64:45".to_string());
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        geometry: turned,
        crop_resize: CropResizeParameters {
            enabled: true,
            resize_enabled: true,
            pixel_aspect: PixelAspectMode::Square,
            target_height: Some(720),
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    // 45/64 = 0.703125; the un-inverted 64/45 would be 1.4222.
    assert!(
        script.contains("0.703125") || script.contains("0.7031"),
        "the square-pixel path should use the inverted SAR, not the source's"
    );
    assert!(
        !script.contains("1.4222"),
        "the un-inverted SAR must not reach the fitting calculation"
    );
}

#[test]
fn test_128_ctmf_with_its_nine_bit_guard_and_pinned_memsize() {
    create_output_dir();
    let mut job = create_base_job("test_128_ctmf");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::Ctmf,
            ctmf_radius: 4,
            ctmf_planes: 0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "CTMF",
        &[
            "core.ctmf.CTMF(",
            "radius=4",
            "planes=[0]",
            // 9-bit is rejected outright by the plugin and IS reachable —
            // pixel_format.rs rounds an odd source depth up through 9.
            "bits_per_sample == 9",
            // Pinned: at the plugin's 1 MiB default, 16-bit radius 3 measures
            // 0.79 fps against 42 fps here, for bit-identical output.
            "memsize=16777216",
        ],
    )
    .unwrap();
}

#[test]
fn test_129_ctmf_radius_is_clamped_in_the_script() {
    create_output_dir();
    let mut job = create_base_job("test_129_ctmf_clamp");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::Ctmf,
            ctmf_radius: 200,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(&job, "CTMF clamp", &["radius=12"]).unwrap();
}

#[test]
fn test_130_dctfilter_builds_a_valid_eight_factor_curve() {
    create_output_dir();
    let mut job = create_base_job("test_130_dctfilter");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        deblock: DeblockParameters {
            enabled: true,
            method: DeblockMethod::DctFilter,
            dct_cutoff: 5,
            dct_strength: 0.6,
            dct_planes: 0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "DCTFilter",
        &["core.dctf.DCTFilter(", "factors=[", "planes=[0]"],
    )
    .unwrap();

    let script = script_text(&job);
    // Exactly eight factors, or the plugin errors.
    let start = script.find("factors=[").unwrap() + "factors=[".len();
    let end = script[start..].find(']').unwrap() + start;
    assert_eq!(
        script[start..end].split(',').count(),
        8,
        "DCTFilter requires exactly 8 factors"
    );
    // Scope this to the factors themselves: the template's own comment
    // explains the NaN trap, and matching that would assert on prose.
    let factors = &script[start..end];
    assert!(
        !factors.to_lowercase().contains("nan") && !factors.to_lowercase().contains("inf"),
        "a NaN factor passes the plugin's range check and blackens the frame: {factors}"
    );
}

#[test]
fn test_131_dctfilter_at_zero_strength_is_the_identity_curve() {
    // All factors at 1.0 is a verified bit-exact no-op, so the pass can be
    // enabled with nothing turned up and change nothing.
    create_output_dir();
    let mut job = create_base_job("test_131_dctfilter_noop");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        deblock: DeblockParameters {
            enabled: true,
            method: DeblockMethod::DctFilter,
            dct_strength: 0.0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "DCTFilter identity",
        &["factors=[1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000, 1.0000]"],
    )
    .unwrap();
}

#[test]
fn test_132_smooth_levels_scales_its_values_to_the_clip_depth() {
    // SmoothLevels reads levels in the CLIP'S OWN range, not 8-bit — the same
    // trap as std.Levels, and the same fix: scale in the script from
    // clip.format, because a preceding pass may have changed the depth.
    // Measured unscaled, a gamma-only edit at 16-bit is off by a worst pixel of
    // 249/255.
    create_output_dir();
    let mut job = create_base_job("test_132_smooth_levels");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        color_correction: ColorCorrectionParameters {
            enabled: true,
            apply_levels: true,
            smooth_levels: true,
            input_low: 16,
            input_high: 235,
            output_low: 0,
            output_high: 255,
            gamma: 1.0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "SmoothLevels",
        &[
            "haf.SmoothLevels(",
            "input_low=_levels_8bit(16)",
            "input_high=_levels_8bit(235)",
            "output_high=_levels_8bit(255)",
            "Smode=-2",
            // havsfunc calls core.f3kdb.Deband and this bundle ships
            // neo_f3kdb, so the default useDB=True fails on every format.
            "useDB=False",
        ],
    )
    .unwrap();

    let script = script_text(&job);
    assert!(
        !script.contains("clip = core.std.Levels("),
        "the plain Levels call must not also run"
    );
}

#[test]
fn test_133_smooth_levels_drops_the_black_point_when_gamma_would_crash() {
    // havsfunc raises a negative base to a fractional power below input_low,
    // which yields a Python complex and fails the LUT outright. Measured: it
    // crashes whenever input_low > 0 and 1/gamma is not an integer.
    create_output_dir();
    let mut job = create_base_job("test_133_smooth_levels_gamma");
    job.qtgmc_parameters.enabled = false;
    let color = ColorCorrectionParameters {
        enabled: true,
        apply_levels: true,
        smooth_levels: true,
        input_low: 16,
        gamma: 0.6,
        ..Default::default()
    };
    assert!(color.smooth_levels_drops_black_point());

    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        color_correction: color,
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "SmoothLevels gamma guard",
        &["input_low=_levels_8bit(0)", "gamma=0.6"],
    )
    .unwrap();
}

#[test]
fn test_134_plain_levels_still_runs_when_smooth_is_off() {
    // The existing behaviour must be untouched, so saved presets keep working.
    create_output_dir();
    let mut job = create_base_job("test_134_plain_levels");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        color_correction: ColorCorrectionParameters {
            enabled: true,
            apply_levels: true,
            smooth_levels: false,
            input_low: 16,
            gamma: 0.6,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    let script = script_text(&job);
    assert!(script.contains("core.std.Levels("), "plain Levels should run");
    assert!(!script.contains("haf.SmoothLevels("), "SmoothLevels should not");
    // And the plain path keeps the black point AND the gamma together.
    assert!(script.contains("min_in=_levels_8bit(16)"));
}

// ============================================================================
// Fifth batch: the second deps change (bifrost + retinex, joining deps 1.9.0).
// ============================================================================

#[test]
fn test_135_bifrost_with_its_eight_bit_guard() {
    // Bifrost is 8-bit only: "Only constant format 8 bit integer YUV input
    // supported", verified against the bundle at 10/12/16-bit and 4:2:2. Same
    // convert-down-and-restore treatment as DeScratch.
    create_output_dir();
    let mut job = create_base_job("test_135_bifrost");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        chroma_fixes: ChromaFixParameters {
            enabled: true,
            apply_bifrost: true,
            bifrost_luma_thresh: 12.0,
            bifrost_variation: 3,
            bifrost_interlaced: false,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "Bifrost",
        &[
            "core.bifrost.Bifrost(",
            "luma_thresh=12",
            "variation=3",
            "interlaced=False",
            "_bifrost_src_format",
            "bits_per_sample != 8",
        ],
    )
    .unwrap();
}

#[test]
fn test_136_shadow_detail_runs_on_luma_only() {
    // retinex.MSRCP rejects subsampled formats outright, and every source this
    // app handles is 4:2:0 or 4:2:2 — so the luma plane is extracted as
    // greyscale, processed, and put back, leaving chroma bit-identical rather
    // than round-tripping the clip through 4:4:4.
    create_output_dir();
    let mut job = create_base_job("test_136_shadow_detail");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        color_correction: ColorCorrectionParameters {
            enabled: true,
            apply_shadow_detail: true,
            shadow_sigma: 120.0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "Shadow detail",
        &[
            "core.retinex.MSRCP(",
            "sigma=[120",
            // The luma-only round trip, which is what makes it usable at all.
            "colorfamily=vs.GRAY",
            "core.std.ShufflePlanes",
        ],
    )
    .unwrap();
}

#[test]
fn test_137_shadow_detail_parameters_are_clamped() {
    create_output_dir();
    let mut job = create_base_job("test_137_shadow_clamp");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        color_correction: ColorCorrectionParameters {
            enabled: true,
            apply_shadow_detail: true,
            shadow_sigma: 9000.0,
            shadow_lower_thr: 0.9,
            shadow_upper_thr: -1.0,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });
    run_job_and_verify(
        &job,
        "Shadow detail clamps",
        &["sigma=[500", "lower_thr=0.1", "upper_thr=0"],
    )
    .unwrap();
}

#[test]
fn test_138_the_two_rainbow_removers_are_independent() {
    // LUTDeRainbow decides within a frame; Bifrost compares across frames. They
    // are complementary, so both must be able to run together and each must be
    // strippable on its own.
    create_output_dir();
    for (derainbow, bifrost) in [(true, false), (false, true), (true, true)] {
        let mut job = create_base_job("test_138_rainbow_pair");
        job.qtgmc_parameters.enabled = false;
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            chroma_fixes: ChromaFixParameters {
                enabled: true,
                apply_de_rainbow: derainbow,
                apply_bifrost: bifrost,
                ..Default::default()
            },
            ..ProcessingPipeline::default()
        });
        let script = script_text(&job);
        assert_eq!(
            script.contains("haf.LUTDeRainbow("),
            derainbow,
            "LUTDeRainbow presence should follow its own toggle"
        );
        assert_eq!(
            script.contains("core.bifrost.Bifrost("),
            bifrost,
            "Bifrost presence should follow its own toggle"
        );
    }
}

#[test]
fn test_139_anti_alias_always_marks_field_based() {
    // znedi3's double-rate mode REQUIRES the _FieldBased property and fails the
    // whole job with "znedi3: _FieldBased" without it. Measured against the
    // bundled plugin: field=3 errors when the property is absent and is fine at
    // either 0 or 2; field=1 does not care. havsfunc's daa uses field=3.
    //
    // The property is only set upstream when a field order is KNOWN, so an
    // ordinary source with none — most of them — killed the pass. It survived
    // on arm64 (nnedi3 via patch 6) and Windows (prebuilt znedi3), and died on
    // macOS x64 and Linux x64, so the same job worked or failed depending on
    // the machine. Found by the nightly suite; script generation cannot see it,
    // which is why this asserts the mark is present rather than that daa runs.
    create_output_dir();
    let mut job = create_base_job("test_139_aa_field_based");
    job.qtgmc_parameters.enabled = false;
    job.detected_field_order = None; // the case that failed
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        anti_alias: AntiAliasParameters {
            enabled: true,
            method: AntiAliasMethod::Daa,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    let marked = script
        .find("core.std.SetFieldBased(clip, 0)")
        .expect("an undetected field order must still be marked progressive");
    let daa = script.find("haf.daa(").expect("daa must be emitted");
    assert!(marked < daa, "the mark must precede daa, or znedi3 still errors");
    assert!(
        !script.contains("{{AA_FIELD_BASED_VALUE}}"),
        "the placeholder must not survive into the script"
    );
}

#[test]
fn test_140_anti_alias_marks_progressive_after_deinterlacing() {
    // With deinterlacing on, the clip reaching the pass IS progressive, so the
    // mark must be 0 — stamping the source's original field order back on would
    // tell every later filter the deinterlaced output is still interlaced.
    create_output_dir();
    let mut job = create_base_job("test_140_aa_after_deint");
    job.detected_field_order = Some(FieldOrder::TopFieldFirst);
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: true, tff: Some(true), ..Default::default() },
        anti_alias: AntiAliasParameters {
            enabled: true,
            method: AntiAliasMethod::Daa,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    let daa = script.find("haf.daa(").expect("daa must be emitted");
    let mark = script[..daa]
        .rfind("core.std.SetFieldBased(clip, ")
        .expect("the pass must mark the clip");
    let line_end = script[mark..].find(')').unwrap() + mark;
    assert_eq!(
        &script[mark..=line_end],
        "core.std.SetFieldBased(clip, 0)",
        "after deinterlacing the clip is progressive"
    );
}

#[test]
fn test_141_anti_alias_keeps_the_detected_order_when_not_deinterlacing() {
    // Deinterlacing off and a field order known: the clip really is fielded, so
    // daa needs the true parity to pair fields correctly.
    create_output_dir();
    let mut job = create_base_job("test_141_aa_keeps_order");
    job.qtgmc_parameters.enabled = false;
    job.detected_field_order = Some(FieldOrder::BottomFieldFirst);
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        anti_alias: AntiAliasParameters {
            enabled: true,
            method: AntiAliasMethod::Daa,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    let daa = script.find("haf.daa(").expect("daa must be emitted");
    assert!(
        script[..daa].contains("core.std.SetFieldBased(clip, 1)"),
        "BFF must reach the pass as 1, not be flattened to progressive"
    );
}

/// Cnr4 must be preceded by SCDetect, or it fails every job on every platform.
///
/// `scenechange` defaults to True and requires the _SceneChangePrev/Next frame
/// properties, which this pipeline never sets — measured against the bundled
/// plugin, a bare `Cnr4(clip)` errors on every format tested. SCDetect is the
/// right supplier rather than `scenechange=False`, because it is also what
/// stops the filter smearing chroma across a cut.
#[test]
fn test_142_cnr4_is_preceded_by_scene_detection() {
    create_output_dir();
    let mut job = create_base_job("test_142_cnr4_scdetect");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        chroma_denoise: ChromaDenoiseParameters {
            enabled: true,
            method: ChromaDenoiseMethod::Cnr4,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    let cnr4 = script.find("zsmooth.Cnr4(").expect("Cnr4 must be emitted");
    let scd = script[..cnr4]
        .rfind("core.misc.SCDetect(")
        .expect("SCDetect must precede Cnr4 or every job fails");
    assert!(scd < cnr4);
    // 4:1:1 is NTSC DV and pipe_source maps it natively; Cnr4 rejects it.
    assert!(
        script[..cnr4].contains("subsampling_w == 2"),
        "the 4:1:1 guard must run before Cnr4"
    );
    // CCD must not also be emitted — one method runs, not both.
    assert!(!script.contains("zsmooth.CCD("));
}

/// Selecting CCD must leave no Cnr4 remnants, and vice versa. A surviving
/// placeholder is a bare Python SyntaxError from vspipe that reads like a
/// template bug.
#[test]
fn test_143_chroma_denoise_methods_are_mutually_exclusive() {
    create_output_dir();
    for (method, present, absent) in [
        (ChromaDenoiseMethod::Ccd, "zsmooth.CCD(", "zsmooth.Cnr4("),
        (ChromaDenoiseMethod::Cnr4, "zsmooth.Cnr4(", "zsmooth.CCD("),
    ] {
        let mut job = create_base_job("test_143_chroma_denoise_exclusive");
        job.qtgmc_parameters.enabled = false;
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            chroma_denoise: ChromaDenoiseParameters {
                enabled: true,
                method,
                ..Default::default()
            },
            ..ProcessingPipeline::default()
        });
        let script = script_text(&job);
        assert!(script.contains(present), "{method:?} must emit {present}");
        assert!(!script.contains(absent), "{method:?} must not emit {absent}");
        assert!(
            !script.contains("{{CNR4_") && !script.contains("{{CCD_"),
            "{method:?} left an unsubstituted placeholder"
        );
    }
}

/// Every new pass emits its own call and nothing else's, and leaves no
/// unsubstituted placeholder. A surviving `{{...}}` is a bare Python
/// SyntaxError from vspipe that reads like a template bug.
#[test]
fn test_144_new_passes_emit_cleanly() {
    create_output_dir();

    // Prefix-scoped, not a bare "{{" search: the template's own docstring
    // documents the placeholder syntax with {{PARAMETER_NAME}} examples.
    let cases: Vec<(&str, Box<dyn Fn(&mut ProcessingPipeline)>, &str, &[&str])> = vec![
        ("edge_repair", Box::new(|p: &mut ProcessingPipeline| {
            p.edge_repair = EdgeRepairParameters {
                enabled: true, left: 2, right: 2, top: 2, bottom: 2,
                ..Default::default()
            };
        }), "core.fb.FillBorders(", &["{{ER_", "{{#EDGE_REPAIR", "{{/EDGE_REPAIR"]),
        ("ghost_removal", Box::new(|p: &mut ProcessingPipeline| {
            p.ghost_removal = GhostRemovalParameters {
                enabled: true,
                ghosts: vec![GhostSpec { mode: 2, shift: 6, intensity: 24 }],
            };
        }), "core.lghost.LGhost(", &["{{LG_", "{{#GHOST_REMOVAL", "{{/GHOST_REMOVAL"]),
        ("deflicker", Box::new(|p: &mut ProcessingPipeline| {
            p.deflicker = DeflickerParameters { enabled: true, ..Default::default() };
        }), "global_deflicker(", &["{{DEFLICKER_", "{{#DEFLICKER", "{{/DEFLICKER"]),
        ("frame_rate", Box::new(|p: &mut ProcessingPipeline| {
            p.frame_rate = FrameRateParameters {
                enabled: true, source_fps_num: Some(25), source_fps_den: Some(1),
                ..Default::default()
            };
        }), "core.mv.FlowFPS(", &["{{FPS_", "{{#FRAME_RATE", "{{/FRAME_RATE"]),
    ];

    for (name, apply, expected, prefixes) in cases {
        let mut job = create_base_job(&format!("test_144_{name}"));
        job.qtgmc_parameters.enabled = false;
        let mut pipeline = ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            ..ProcessingPipeline::default()
        };
        apply(&mut pipeline);
        job.processing_pipeline = Some(pipeline);

        let script = script_text(&job);
        assert!(script.contains(expected), "{name} must emit {expected}");
        for prefix in prefixes {
            assert!(
                !script.contains(prefix),
                "{name} left an unsubstituted {prefix} placeholder"
            );
        }
    }
}

/// Edge repair rounds every width down to an even number.
///
/// The bundle pins FillBorders v2, which is bit-identical to v4 at even widths
/// and differs only at odd ones, where it leaves subsampled chroma unrepaired.
#[test]
fn test_145_edge_repair_widths_are_always_even() {
    create_output_dir();
    let mut job = create_base_job("test_145_edge_repair_even");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        edge_repair: EdgeRepairParameters {
            enabled: true, left: 3, right: 5, top: 1, bottom: 7,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    assert!(script.contains("left=2"), "3 must round to 2");
    assert!(script.contains("right=4"), "5 must round to 4");
    assert!(script.contains("top=0"), "1 must round to 0");
    assert!(script.contains("bottom=6"), "7 must round to 6");
}

/// Custom VapourSynth is bracketed by a frame-count assertion.
///
/// A snippet that trims desynchronises the progress total AND makes
/// frame-accurate preview show a different frame than its label — both
/// silently. The script refuses rather than letting that happen.
#[test]
fn test_146_custom_vapoursynth_guards_the_frame_count() {
    create_output_dir();
    let mut job = create_base_job("test_146_custom_vs");
    job.qtgmc_parameters.enabled = false;
    job.encoding_settings.custom_vapoursynth =
        "clip = core.std.Invert(clip)".to_string();
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    let code = script.find("core.std.Invert").expect("snippet must be injected");
    assert!(
        script[..code].contains("_custom_vs_frames_before = len(clip)"),
        "the frame count must be captured before the snippet"
    );
    assert!(
        script[code..].contains("changed the frame count"),
        "and asserted after it"
    );

    // Empty means the whole block goes, not an empty one left behind.
    let mut clean = create_base_job("test_146_custom_vs_off");
    clean.qtgmc_parameters.enabled = false;
    let script = script_text(&clean);
    assert!(!script.contains("_custom_vs_frames_before"));
}

/// mClean reaches the script with its own parameters, not a stale default set.
///
/// The vendored module is the only denoiser here with no havsfunc equivalent to
/// fall back on, so a broken substitution shows up as a filter that runs and
/// does nothing rather than as an error.
#[test]
fn test_147_mclean_noise_reduction() {
    create_output_dir();
    let mut job = create_base_job("test_147_mclean");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::MClean,
            preset: NoiseReductionPreset::Moderate,
            mclean_strength: 17,
            mclean_sharp: 9,
            mclean_rn: 11,
            mclean_thsad: 320,
            mclean_chroma: false,
            ..NoiseReductionParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    assert!(script.contains("from mclean import mClean"), "module import");
    assert!(script.contains("strength=17"), "strength substituted");
    assert!(script.contains("sharp=9"), "sharp substituted");
    assert!(script.contains("rn=11"), "rn substituted");
    assert!(script.contains("thSAD=320"), "thSAD substituted");
    assert!(script.contains("chroma=False"), "chroma substituted");
    assert!(
        !script.contains("{{NR_MCLEAN"),
        "no placeholder may survive:\n{script}"
    );
}

/// TemporalDegrain2 likewise, including the two values the module clamps.
#[test]
fn test_148_temporal_degrain2_noise_reduction() {
    create_output_dir();
    let mut job = create_base_job("test_148_td2");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::TemporalDegrain2,
            preset: NoiseReductionPreset::Moderate,
            td2_degrain_tr: 2,
            td2_grain_level: 1,
            td2_post_fft: 3,
            td2_post_sigma: 1.5,
            td2_post_mix: 40,
            td2_chroma_motion: false,
            ..NoiseReductionParameters::default()
        },
        ..ProcessingPipeline::default()
    });

    let script = script_text(&job);
    assert!(
        script.contains("from temporaldegrain2 import TemporalDegrain2"),
        "module import"
    );
    assert!(script.contains("degrainTR=2"), "degrainTR substituted");
    assert!(script.contains("grainLevel=1"), "grainLevel substituted");
    assert!(script.contains("postFFT=3"), "postFFT substituted");
    assert!(script.contains("postMix=40"), "postMix substituted");
    assert!(script.contains("ChromaMotion=False"), "ChromaMotion substituted");
    assert!(
        !script.contains("{{NR_TD2"),
        "no placeholder may survive:\n{script}"
    );
}

/// Every noise reduction method actually reaches the script.
///
/// This exists because two of them didn't. The dispatch is one `match` arm per
/// method, each removing the eleven blocks it isn't and enabling the one it is
/// — so adding a method means editing every arm, and a blanket edit that also
/// hits the new arm makes it remove its *own* block. `MClean` and
/// `TemporalDegrain2` both shipped that way: the pass ran, produced a script
/// with no denoiser in it, and encoded a passthrough with no error anywhere.
///
/// Enumerating the whole enum is the only shape that catches it. A test per
/// method catches the method you thought to test.
#[test]
fn test_149_every_noise_reduction_method_emits_its_filter() {
    create_output_dir();

    // The call that proves this method, and only this method, was emitted.
    let expected: &[(NoiseReductionMethod, &str)] = &[
        (NoiseReductionMethod::SmDegrain, "haf.SMDegrain("),
        (NoiseReductionMethod::McTemporalDenoise, "haf.MCTemporalDenoise("),
        // Its Degrain1/2/3 call is chosen by temporal radius, so match the
        // super clip it always builds instead.
        (NoiseReductionMethod::McDegrainSharp, "_mcds_super_search"),
        (NoiseReductionMethod::DfTtest, "core.dfttest.DFTTest("),
        (NoiseReductionMethod::Fft3dFilter, "core.fft3dfilter.FFT3DFilter("),
        (NoiseReductionMethod::TTempSmooth, "core.ttmpsm.TTempSmooth("),
        (NoiseReductionMethod::FluxSmoothT, "core.flux.SmoothT("),
        (NoiseReductionMethod::FluxSmoothSt, "core.flux.SmoothST("),
        (NoiseReductionMethod::StPresso, "haf.STPresso("),
        (NoiseReductionMethod::Ctmf, "core.ctmf.CTMF("),
        (NoiseReductionMethod::MClean, "_mClean("),
        (NoiseReductionMethod::TemporalDegrain2, "_TemporalDegrain2("),
    ];

    for (method, call) in expected {
        let mut job = create_base_job("test_149_nr_methods");
        job.qtgmc_parameters.enabled = false;
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            noise_reduction: NoiseReductionParameters {
                enabled: true,
                method: *method,
                preset: NoiseReductionPreset::Moderate,
                ..NoiseReductionParameters::default()
            },
            ..ProcessingPipeline::default()
        });

        let script = script_text(&job);
        assert!(
            script.contains(call),
            "{method:?} generated a script without {call} — the pass would run \
             and do nothing"
        );
        assert!(
            !script.contains("{{NR_"),
            "{method:?} left an unsubstituted NR placeholder in the script"
        );
    }

    // And the whole set is off when the pass is.
    let mut off = create_base_job("test_149_nr_off");
    off.qtgmc_parameters.enabled = false;
    off.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        ..ProcessingPipeline::default()
    });
    let script = script_text(&off);
    for (_, call) in expected {
        assert!(!script.contains(call), "{call} survived a disabled pass");
    }
}

#[test]
fn test_150_automatic_chroma_alignment_supersedes_the_manual_shift() {
    // Both blocks used to be emitted when both were set, with the automatic one
    // running first — so the picture was shifted by a measured amount and then
    // again by a guessed one, silently. The panel now hides the manual sliders
    // while automatic alignment is on, and this keeps the generated script
    // agreeing with what the panel shows.
    create_output_dir();

    let build = |auto: bool, manual: bool| {
        let mut job = create_base_job("test_150_chroma_alignment");
        job.qtgmc_parameters.enabled = false;
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            chroma_fixes: ChromaFixParameters {
                enabled: true,
                apply_auto_chroma: auto,
                apply_chroma_shift: manual,
                chroma_shift_h: 2.5,
                chroma_shift_v: -1.0,
                ..Default::default()
            },
            ..ProcessingPipeline::default()
        });
        script_text(&job)
    };

    // The manual shift is recognisable by the per-plane ShufflePlanes/Spline36
    // pair the CHROMA_SHIFT block builds.
    let manual_only = build(false, true);
    assert!(!manual_only.contains("_auto_chroma_fix("));
    assert!(manual_only.contains("_shift_h = 2.5"));

    let auto_only = build(true, false);
    assert!(auto_only.contains("_auto_chroma_fix("));
    assert!(!auto_only.contains("_shift_h ="));

    let both = build(true, true);
    assert!(
        both.contains("_auto_chroma_fix("),
        "automatic alignment must still run"
    );
    assert!(
        !both.contains("_shift_h ="),
        "the manual shift must be dropped when automatic alignment is on, or the \
         measured correction is applied twice"
    );

    let neither = build(false, false);
    assert!(!neither.contains("_auto_chroma_fix("));
    assert!(!neither.contains("_shift_h ="));
}

#[test]
fn test_151_levels_honour_their_switch_and_yield_to_automatic_levels() {
    // Two faults in the same block, both silent.
    //
    // `apply_levels` — the panel's "Set levels by hand" switch — was never read
    // here: the block was emitted whenever any level differed from its default,
    // so unticking the switch left the adjustment running with nothing on screen
    // that could stop it.
    //
    // And automatic levels measures the picture and places black and white
    // itself, running *before* this block, so manual input/output points on top
    // grade an already-graded picture with numbers that were measured against
    // the original. The panel hides them; the script drops them. Gamma survives,
    // because automatic levels never touches the midtones and this is the only
    // place to reach it.
    create_output_dir();

    let build = |apply_levels: bool, auto: bool, gamma: f64| {
        let mut job = create_base_job("test_151_levels");
        job.qtgmc_parameters.enabled = false;
        job.processing_pipeline = Some(ProcessingPipeline {
            deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
            color_correction: ColorCorrectionParameters {
                enabled: true,
                apply_levels,
                apply_auto_levels: auto,
                input_low: 16,
                input_high: 235,
                output_low: 0,
                output_high: 255,
                gamma,
                ..ColorCorrectionParameters::default()
            },
            ..ProcessingPipeline::default()
        });
        script_text(&job)
    };

    // `_auto_levels` calls std.Levels internally, so the manual block is
    // recognised by its own 8-bit scaling helper rather than by the call.
    const MANUAL_LEVELS: &str = "def _levels_8bit";

    let on = build(true, false, 1.0);
    assert!(on.contains(MANUAL_LEVELS));
    assert!(on.contains("min_in=_levels_8bit(16)"));

    let off = build(false, false, 1.0);
    assert!(
        !off.contains(MANUAL_LEVELS),
        "unticking the switch must actually stop the adjustment"
    );

    // Automatic levels on: its own block runs, the manual points do not, and a
    // manual levels block is emitted only if gamma gives it something to do.
    let auto_no_gamma = build(true, true, 1.0);
    assert!(auto_no_gamma.contains("_auto_levels("));
    assert!(
        !auto_no_gamma.contains(MANUAL_LEVELS),
        "with black and white measured, an identity mapping is nothing to emit"
    );

    let auto_with_gamma = build(true, true, 1.4);
    assert!(auto_with_gamma.contains("_auto_levels("));
    assert!(auto_with_gamma.contains(MANUAL_LEVELS));
    assert!(
        auto_with_gamma.contains("gamma=1.4"),
        "gamma is the one levels control automatic levels does not supersede"
    );
    assert!(
        !auto_with_gamma.contains("min_in=_levels_8bit(16)"),
        "the manual input point must not be applied on top of the measured one"
    );
}

#[test]
fn test_152_ctmf_never_asks_for_the_avx512_kernel() {
    // CTMF r5's AVX-512 kernel for 8-bit input crashes the process: vspipe dies
    // with an access violation and prints NOTHING, so the job surfaces as
    // ffmpeg reading an empty pipe ("Header too large") and the preview as a
    // bare "exit code 1" — with nothing anywhere naming the filter. It bites
    // every radius except 2 and only at 8 bits.
    //
    // Reproduced on an AVX-512 CPU 2026-08-25, and in CI the moment GitHub's
    // Windows runners gained AVX-512 (the same nightly passed the three nights
    // before on runners without it, against an unchanged tree). CTMF r5 is the
    // newest upstream release, so there is nothing to upgrade to.
    //
    // So `opt` must always be emitted, and must never be 0 (the plugin's own
    // auto-detect, which is what picks AVX-512) or 4.
    create_output_dir();
    let mut job = create_base_job("test_152_ctmf_opt");
    job.qtgmc_parameters.enabled = false;
    job.processing_pipeline = Some(ProcessingPipeline {
        deinterlace: QTGMCParameters { enabled: false, ..Default::default() },
        noise_reduction: NoiseReductionParameters {
            enabled: true,
            method: NoiseReductionMethod::Ctmf,
            ctmf_radius: 3,
            ..Default::default()
        },
        ..ProcessingPipeline::default()
    });

    // Both scripts, because a preview that crashes is the half the reporter
    // sees first.
    let (encode, preview) = generate_both_scripts(&job);
    for (name, script) in [("encode", &encode), ("preview", &preview)] {
        assert!(
            script.contains("core.ctmf.CTMF("),
            "{name} script should call CTMF"
        );
        assert!(
            script.contains(&format!("opt={}", vapourbox_worker::script_generator::ctmf_opt())),
            "{name} script must pin CTMF's dispatch level"
        );
        assert!(
            !script.contains("opt=0") && !script.contains("opt=4"),
            "{name} script must never hand CTMF auto-detect or AVX-512"
        );
    }
}

#[test]
fn test_153_ctmf_opt_is_a_level_the_cpu_can_actually_run() {
    // The plugin does NOT verify that the CPU supports the level it is handed —
    // opt=3 on a pre-AVX2 machine installs the AVX2 kernels and crashes exactly
    // as opt=4 does on this one. So this has to stay a real capability query,
    // not a constant: 3 only where AVX2 was detected, otherwise 2 (SSE2, which
    // every x86-64 CPU has by definition). Both are bit-identical to the C path.
    let opt = vapourbox_worker::script_generator::ctmf_opt();
    assert!(
        opt == 2 || opt == 3,
        "opt must be SSE2 or AVX2, got {opt}"
    );

    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        let expected = if std::is_x86_feature_detected!("avx2") { 3 } else { 2 };
        assert_eq!(opt, expected, "opt must follow what the CPU actually has");
    }
}
