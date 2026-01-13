//! VapourSynth script generator.
//!
//! Generates .vpy scripts from templates by substituting pipeline parameters.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::models::{
    VideoJob, RestorationPipeline, NoiseReductionMethod, ResizeKernel, UpscaleMethod,
};

/// Generates VapourSynth scripts from templates.
pub struct ScriptGenerator {
    template: String,
}

impl ScriptGenerator {
    /// Create a new script generator, loading the template.
    pub fn new() -> Result<Self> {
        let template = Self::load_template()?;
        Ok(Self { template })
    }

    /// Generate a .vpy script file for the given job.
    /// Returns the path to the generated script.
    pub fn generate(&self, job: &VideoJob) -> Result<PathBuf> {
        let pipeline = job.effective_pipeline();
        let script = self.substitute_parameters(job, &pipeline);

        // Write to temp file
        let temp_dir = env::temp_dir();
        let script_path = temp_dir.join(format!("{}.vpy", job.id));

        fs::write(&script_path, &script)
            .with_context(|| format!("Failed to write script to {:?}", script_path))?;

        Ok(script_path)
    }

    /// Load the template from various locations.
    fn load_template() -> Result<String> {
        // Try locations in order of preference
        let exe_path = env::current_exe()?;
        let exe_dir = exe_path.parent().unwrap_or(Path::new("."));

        let search_paths = [
            // Next to executable - pipeline template first
            exe_dir.join("templates").join("pipeline_template.vpy"),
            exe_dir.join("Templates").join("pipeline_template.vpy"),
            // Fallback to legacy QTGMC template
            exe_dir.join("templates").join("qtgmc_template.vpy"),
            exe_dir.join("Templates").join("qtgmc_template.vpy"),
            // In parent (for development: worker/target/release -> worker/templates)
            exe_dir.join("..").join("..").join("templates").join("pipeline_template.vpy"),
            exe_dir.join("..").join("..").join("..").join("templates").join("pipeline_template.vpy"),
            exe_dir.join("..").join("..").join("templates").join("qtgmc_template.vpy"),
            exe_dir.join("..").join("..").join("..").join("templates").join("qtgmc_template.vpy"),
            // Relative to current dir
            PathBuf::from("templates").join("pipeline_template.vpy"),
            PathBuf::from("templates").join("qtgmc_template.vpy"),
            PathBuf::from("worker").join("templates").join("pipeline_template.vpy"),
            PathBuf::from("worker").join("templates").join("qtgmc_template.vpy"),
        ];

        for path in &search_paths {
            if path.exists() {
                if let Ok(content) = fs::read_to_string(path) {
                    eprintln!("Loaded template from: {:?}", path);
                    return Ok(content);
                }
            }
        }

        // Fallback to embedded template
        eprintln!("Using embedded fallback template");
        Ok(Self::embedded_template())
    }

    /// Substitute parameters in the template.
    fn substitute_parameters(&self, job: &VideoJob, pipeline: &RestorationPipeline) -> String {
        let mut script = self.template.clone();
        let params = &job.qtgmc_parameters;

        // Input path (escape backslashes for Python)
        let escaped_input = job.input_path.replace('\\', "\\\\");
        script = script.replace("{{INPUT_PATH}}", &escaped_input);

        // ====================================================================
        // PRE-CROP PASS
        // ====================================================================
        let crop = &pipeline.crop_resize;
        if crop.enabled && crop.crop_enabled &&
           (crop.crop_left > 0 || crop.crop_right > 0 || crop.crop_top > 0 || crop.crop_bottom > 0) {
            script = script.replace("{{#PRE_CROP}}", "");
            script = script.replace("{{/PRE_CROP}}", "");
            script = script.replace("{{CROP_LEFT}}", &crop.crop_left.to_string());
            script = script.replace("{{CROP_RIGHT}}", &crop.crop_right.to_string());
            script = script.replace("{{CROP_TOP}}", &crop.crop_top.to_string());
            script = script.replace("{{CROP_BOTTOM}}", &crop.crop_bottom.to_string());
        } else {
            script = remove_block("{{#PRE_CROP}}", "{{/PRE_CROP}}", script);
        }

        // ====================================================================
        // DEINTERLACE PASS (QTGMC)
        // ====================================================================
        if pipeline.deinterlace.enabled {
            script = script.replace("{{#DEINTERLACE}}", "");
            script = script.replace("{{/DEINTERLACE}}", "");

            // Preset (required)
            script = script.replace("{{PRESET}}", params.preset.as_str());

            // Process optional QTGMC parameters
            script = process_optional_bool("TFF", params.tff, script);
            script = process_optional_int("INPUT_TYPE", if params.input_type != 0 { Some(params.input_type) } else { None }, script);
            script = process_optional_int("FPS_DIVISOR", if params.fps_divisor != 1 { Some(params.fps_divisor) } else { None }, script);

            // Quality parameters
            script = process_optional_int("TR0", params.tr0, script);
            script = process_optional_int("TR1", params.tr1, script);
            script = process_optional_int("TR2", params.tr2, script);
            script = process_optional_int("REP0", params.rep0, script);
            script = process_optional_int("REP1", if params.rep1 != 0 { Some(params.rep1) } else { None }, script);
            script = process_optional_int("REP2", params.rep2, script);
            script = process_optional_bool("REP_CHROMA", if !params.rep_chroma { Some(false) } else { None }, script);

            // Interpolation
            script = process_optional_string("EDI_MODE", params.edi_mode.as_deref(), script);
            script = process_optional_int("NN_SIZE", params.nn_size, script);
            script = process_optional_int("NN_NEURONS", params.nn_neurons, script);
            script = process_optional_int("EDI_QUAL", if params.edi_qual != 1 { Some(params.edi_qual) } else { None }, script);
            script = process_optional_int("EDI_MAX_D", params.edi_max_d, script);
            script = process_optional_string("CHROMA_EDI", if params.chroma_edi.is_empty() { None } else { Some(&params.chroma_edi) }, script);

            // Motion analysis
            script = process_optional_int("BLOCK_SIZE", params.block_size, script);
            script = process_optional_int("OVERLAP", params.overlap, script);
            script = process_optional_int("SEARCH", params.search, script);
            script = process_optional_int("SEARCH_PARAM", params.search_param, script);
            script = process_optional_int("PEL_SEARCH", params.pel_search, script);
            script = process_optional_bool("CHROMA_MOTION", params.chroma_motion, script);
            script = process_optional_bool("TRUE_MOTION", if params.true_motion { Some(true) } else { None }, script);
            script = process_optional_int("LAMBDA", params.lambda, script);
            script = process_optional_int("LSAD", params.lsad, script);
            script = process_optional_int("P_NEW", params.p_new, script);
            script = process_optional_int("P_LEVEL", params.p_level, script);
            script = process_optional_bool("GLOBAL_MOTION", if !params.global_motion { Some(false) } else { None }, script);
            script = process_optional_int("DCT", if params.dct != 0 { Some(params.dct) } else { None }, script);
            script = process_optional_int("SUB_PEL", params.sub_pel, script);
            script = process_optional_int("SUB_PEL_INTERP", if params.sub_pel_interp != 2 { Some(params.sub_pel_interp) } else { None }, script);

            // Thresholds
            script = process_optional_int("TH_SAD1", if params.th_sad1 != 640 { Some(params.th_sad1) } else { None }, script);
            script = process_optional_int("TH_SAD2", if params.th_sad2 != 256 { Some(params.th_sad2) } else { None }, script);
            script = process_optional_int("TH_SCD1", if params.th_scd1 != 180 { Some(params.th_scd1) } else { None }, script);
            script = process_optional_int("TH_SCD2", if params.th_scd2 != 98 { Some(params.th_scd2) } else { None }, script);

            // Sharpening
            script = process_optional_double("SHARPNESS", params.sharpness, script);
            script = process_optional_int("S_MODE", params.s_mode, script);
            script = process_optional_int("SL_MODE", params.sl_mode, script);
            script = process_optional_int("SL_RAD", params.sl_rad, script);
            script = process_optional_int("S_OVS", if params.s_ovs != 0 { Some(params.s_ovs) } else { None }, script);
            script = process_optional_double("SV_THIN", if params.sv_thin != 0.0 { Some(params.sv_thin) } else { None }, script);
            script = process_optional_int("SBB", params.sbb, script);
            script = process_optional_int("SRCH_CLIP_PP", params.srch_clip_pp, script);

            // Noise processing
            script = process_optional_int("NOISE_PROCESS", params.noise_process, script);
            script = process_optional_double("EZ_DENOISE", params.ez_denoise, script);
            script = process_optional_double("EZ_KEEP_GRAIN", params.ez_keep_grain, script);
            script = process_optional_string("NOISE_PRESET", if params.noise_preset != "Fast" { Some(&params.noise_preset) } else { None }, script);
            script = process_optional_string("DENOISER", params.denoiser.as_deref(), script);
            script = process_optional_int("FFT_THREADS", if params.fft_threads != 1 { Some(params.fft_threads) } else { None }, script);
            script = process_optional_bool("DENOISE_MC", params.denoise_mc, script);
            script = process_optional_int("NOISE_TR", params.noise_tr, script);
            script = process_optional_double("SIGMA", params.sigma, script);
            script = process_optional_bool("CHROMA_NOISE", if params.chroma_noise { Some(true) } else { None }, script);
            script = process_optional_double("SHOW_NOISE", if params.show_noise != 0.0 { Some(params.show_noise) } else { None }, script);
            script = process_optional_double("GRAIN_RESTORE", params.grain_restore, script);
            script = process_optional_double("NOISE_RESTORE", params.noise_restore, script);
            script = process_optional_string("NOISE_DEINT", params.noise_deint.as_deref(), script);
            script = process_optional_bool("STABILIZE_NOISE", params.stabilize_noise, script);

            // Source matching
            script = process_optional_int("SOURCE_MATCH", if params.source_match != 0 { Some(params.source_match) } else { None }, script);
            script = process_optional_string("MATCH_PRESET", params.match_preset.as_deref(), script);
            script = process_optional_string("MATCH_EDI", params.match_edi.as_deref(), script);
            script = process_optional_string("MATCH_PRESET2", params.match_preset2.as_deref(), script);
            script = process_optional_string("MATCH_EDI2", params.match_edi2.as_deref(), script);
            script = process_optional_int("MATCH_TR2", if params.match_tr2 != 1 { Some(params.match_tr2) } else { None }, script);
            script = process_optional_double("MATCH_ENHANCE", if (params.match_enhance - 0.5).abs() > 0.001 { Some(params.match_enhance) } else { None }, script);
            script = process_optional_int("LOSSLESS", if params.lossless != 0 { Some(params.lossless) } else { None }, script);

            // Advanced
            script = process_optional_bool("BORDER", if params.border { Some(true) } else { None }, script);
            script = process_optional_bool("PRECISE", params.precise, script);
            script = process_optional_int("FORCE_TR", if params.force_tr != 0 { Some(params.force_tr) } else { None }, script);

            // GPU
            script = process_optional_bool("OPENCL", Some(params.opencl), script);
            script = process_optional_int("DEVICE", params.device, script);
        } else {
            script = remove_block("{{#DEINTERLACE}}", "{{/DEINTERLACE}}", script);
        }

        // ====================================================================
        // NOISE REDUCTION PASS
        // ====================================================================
        let nr = &pipeline.noise_reduction;
        if nr.enabled {
            script = script.replace("{{#NOISE_REDUCTION}}", "");
            script = script.replace("{{/NOISE_REDUCTION}}", "");

            match nr.method {
                NoiseReductionMethod::SmDegrain => {
                    script = script.replace("{{#NR_SMDEGRAIN}}", "");
                    script = script.replace("{{/NR_SMDEGRAIN}}", "");
                    script = remove_block("{{#NR_MCTD}}", "{{/NR_MCTD}}", script);
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);

                    script = process_optional_int("NR_TR", Some(nr.sm_degrain_tr), script);
                    script = process_optional_int("NR_TH_SAD", Some(nr.sm_degrain_th_sad), script);
                    script = process_optional_int("NR_TH_SADC", if nr.sm_degrain_th_sadc != nr.sm_degrain_th_sad { Some(nr.sm_degrain_th_sadc) } else { None }, script);
                    script = process_optional_bool("NR_REFINE_MOTION", Some(nr.sm_degrain_refine), script);
                    script = process_optional_int("NR_PREFILTER", if nr.sm_degrain_prefilter != 2 { Some(nr.sm_degrain_prefilter) } else { None }, script);
                    script = process_optional_bool("NR_CONTRASHARP", None, script); // Not in current model
                }
                NoiseReductionMethod::McTemporalDenoise => {
                    script = remove_block("{{#NR_SMDEGRAIN}}", "{{/NR_SMDEGRAIN}}", script);
                    script = script.replace("{{#NR_MCTD}}", "");
                    script = script.replace("{{/NR_MCTD}}", "");
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);

                    script = process_optional_double("NR_SIGMA", Some(nr.mc_temporal_sigma), script);
                    script = process_optional_int("NR_RADIUS", Some(nr.mc_temporal_radius), script);
                }
                NoiseReductionMethod::QtgmcBuiltin => {
                    // QTGMC built-in denoising is handled in the QTGMC pass itself
                    script = remove_block("{{#NR_SMDEGRAIN}}", "{{/NR_SMDEGRAIN}}", script);
                    script = remove_block("{{#NR_MCTD}}", "{{/NR_MCTD}}", script);
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);
                }
            }
        } else {
            script = remove_block("{{#NOISE_REDUCTION}}", "{{/NOISE_REDUCTION}}", script);
        }

        // ====================================================================
        // CHROMA FIXES PASS
        // ====================================================================
        let chroma = &pipeline.chroma_fixes;
        if chroma.enabled {
            script = script.replace("{{#CHROMA_FIXES}}", "");
            script = script.replace("{{/CHROMA_FIXES}}", "");

            // FixChromaBleedingMod
            if chroma.apply_chroma_bleeding_fix {
                script = script.replace("{{#CHROMA_FIX_BLEEDING}}", "");
                script = script.replace("{{/CHROMA_FIX_BLEEDING}}", "");
                script = process_optional_int("CHROMA_CX", Some(chroma.chroma_bleed_cx), script);
                script = process_optional_int("CHROMA_CY", Some(chroma.chroma_bleed_cy), script);
                // havsfunc uses thr (threshold) and strength parameters
                script = process_optional_double("CHROMA_THR", Some(chroma.chroma_bleed_c_blur), script);
                script = process_optional_double("CHROMA_STRENGTH", Some(chroma.chroma_bleed_strength), script);
            } else {
                script = remove_block("{{#CHROMA_FIX_BLEEDING}}", "{{/CHROMA_FIX_BLEEDING}}", script);
            }

            // LUTDeCrawl
            if chroma.apply_de_crawl {
                script = script.replace("{{#CHROMA_DECRAWL}}", "");
                script = script.replace("{{/CHROMA_DECRAWL}}", "");
                script = process_optional_int("DECRAWL_YTHRESH", Some(chroma.de_crawl_y_thresh), script);
                script = process_optional_int("DECRAWL_CTHRESH", Some(chroma.de_crawl_c_thresh), script);
                script = process_optional_int("DECRAWL_MAXDIFF", Some(chroma.de_crawl_max_diff), script);
            } else {
                script = remove_block("{{#CHROMA_DECRAWL}}", "{{/CHROMA_DECRAWL}}", script);
            }

            // Vinverse
            if chroma.apply_vinverse {
                script = script.replace("{{#CHROMA_VINVERSE}}", "");
                script = script.replace("{{/CHROMA_VINVERSE}}", "");
                script = process_optional_double("VINVERSE_SSTR", Some(chroma.vinverse_sstr), script);
                script = process_optional_int("VINVERSE_AMNT", Some(chroma.vinverse_amnt), script);
                // Note: havsfunc Vinverse doesn't have scl parameter, only sstr, amnt, chroma
            } else {
                script = remove_block("{{#CHROMA_VINVERSE}}", "{{/CHROMA_VINVERSE}}", script);
            }
        } else {
            script = remove_block("{{#CHROMA_FIXES}}", "{{/CHROMA_FIXES}}", script);
        }

        // ====================================================================
        // COLOR CORRECTION PASS
        // ====================================================================
        let color = &pipeline.color_correction;
        if color.enabled {
            script = script.replace("{{#COLOR_CORRECTION}}", "");
            script = script.replace("{{/COLOR_CORRECTION}}", "");

            // Tweak (brightness, contrast, saturation, hue)
            let has_tweak = (color.brightness - 0.0).abs() > 0.001
                || (color.contrast - 1.0).abs() > 0.001
                || (color.saturation - 1.0).abs() > 0.001
                || (color.hue - 0.0).abs() > 0.001;

            if has_tweak {
                script = script.replace("{{#COLOR_TWEAK}}", "");
                script = script.replace("{{/COLOR_TWEAK}}", "");
                script = process_optional_double("COLOR_BRIGHTNESS", if color.brightness != 0.0 { Some(color.brightness) } else { None }, script);
                script = process_optional_double("COLOR_CONTRAST", if color.contrast != 1.0 { Some(color.contrast) } else { None }, script);
                script = process_optional_double("COLOR_SATURATION", if color.saturation != 1.0 { Some(color.saturation) } else { None }, script);
                script = process_optional_double("COLOR_HUE", if color.hue != 0.0 { Some(color.hue) } else { None }, script);
            } else {
                script = remove_block("{{#COLOR_TWEAK}}", "{{/COLOR_TWEAK}}", script);
            }

            // Levels
            let has_levels = color.input_low != 0
                || color.input_high != 255
                || color.output_low != 0
                || color.output_high != 255
                || (color.gamma - 1.0).abs() > 0.001;

            if has_levels {
                script = script.replace("{{#COLOR_LEVELS}}", "");
                script = script.replace("{{/COLOR_LEVELS}}", "");
                script = process_optional_int("LEVELS_INPUT_LOW", if color.input_low != 0 { Some(color.input_low) } else { None }, script);
                script = process_optional_int("LEVELS_INPUT_HIGH", if color.input_high != 255 { Some(color.input_high) } else { None }, script);
                script = process_optional_int("LEVELS_OUTPUT_LOW", if color.output_low != 0 { Some(color.output_low) } else { None }, script);
                script = process_optional_int("LEVELS_OUTPUT_HIGH", if color.output_high != 255 { Some(color.output_high) } else { None }, script);
                script = process_optional_double("LEVELS_GAMMA", if (color.gamma - 1.0).abs() > 0.001 { Some(color.gamma) } else { None }, script);
            } else {
                script = remove_block("{{#COLOR_LEVELS}}", "{{/COLOR_LEVELS}}", script);
            }
        } else {
            script = remove_block("{{#COLOR_CORRECTION}}", "{{/COLOR_CORRECTION}}", script);
        }

        // ====================================================================
        // RESIZE PASS
        // ====================================================================
        let resize = &pipeline.crop_resize;
        if resize.enabled && (resize.resize_enabled || resize.use_integer_upscale) {
            script = script.replace("{{#RESIZE}}", "");
            script = script.replace("{{/RESIZE}}", "");

            // Integer upscale
            if resize.use_integer_upscale {
                script = script.replace("{{#RESIZE_INTEGER_UPSCALE}}", "");
                script = script.replace("{{/RESIZE_INTEGER_UPSCALE}}", "");
                script = script.replace("{{UPSCALE_FACTOR}}", &resize.upscale_factor.to_string());

                match resize.upscale_method {
                    UpscaleMethod::Nnedi3Rpow2 => {
                        script = script.replace("{{#UPSCALE_NNEDI3}}", "");
                        script = script.replace("{{/UPSCALE_NNEDI3}}", "");
                        script = remove_block("{{#UPSCALE_EEDI3}}", "{{/UPSCALE_EEDI3}}", script);
                    }
                    UpscaleMethod::Eedi3Rpow2 => {
                        script = remove_block("{{#UPSCALE_NNEDI3}}", "{{/UPSCALE_NNEDI3}}", script);
                        script = script.replace("{{#UPSCALE_EEDI3}}", "");
                        script = script.replace("{{/UPSCALE_EEDI3}}", "");
                    }
                    UpscaleMethod::Spline36 => {
                        // For spline36 "upscale", we use resize instead
                        script = remove_block("{{#UPSCALE_NNEDI3}}", "{{/UPSCALE_NNEDI3}}", script);
                        script = remove_block("{{#UPSCALE_EEDI3}}", "{{/UPSCALE_EEDI3}}", script);
                    }
                }
            } else {
                script = remove_block("{{#RESIZE_INTEGER_UPSCALE}}", "{{/RESIZE_INTEGER_UPSCALE}}", script);
            }

            // Standard resize
            if resize.resize_enabled {
                let width = resize.target_width.unwrap_or(1920);
                let height = resize.target_height.unwrap_or(1080);
                script = script.replace("{{TARGET_WIDTH}}", &width.to_string());
                script = script.replace("{{TARGET_HEIGHT}}", &height.to_string());

                match resize.kernel {
                    ResizeKernel::Spline36 | ResizeKernel::Nnedi3 | ResizeKernel::Eedi3 => {
                        // Nnedi3/Eedi3 are for integer upscaling; for standard resize use Spline36
                        script = script.replace("{{#RESIZE_SPLINE36}}", "");
                        script = script.replace("{{/RESIZE_SPLINE36}}", "");
                        script = remove_block("{{#RESIZE_LANCZOS}}", "{{/RESIZE_LANCZOS}}", script);
                        script = remove_block("{{#RESIZE_BICUBIC}}", "{{/RESIZE_BICUBIC}}", script);
                        script = remove_block("{{#RESIZE_BILINEAR}}", "{{/RESIZE_BILINEAR}}", script);
                    }
                    ResizeKernel::Lanczos => {
                        script = remove_block("{{#RESIZE_SPLINE36}}", "{{/RESIZE_SPLINE36}}", script);
                        script = script.replace("{{#RESIZE_LANCZOS}}", "");
                        script = script.replace("{{/RESIZE_LANCZOS}}", "");
                        script = remove_block("{{#RESIZE_BICUBIC}}", "{{/RESIZE_BICUBIC}}", script);
                        script = remove_block("{{#RESIZE_BILINEAR}}", "{{/RESIZE_BILINEAR}}", script);
                    }
                    ResizeKernel::Bicubic => {
                        script = remove_block("{{#RESIZE_SPLINE36}}", "{{/RESIZE_SPLINE36}}", script);
                        script = remove_block("{{#RESIZE_LANCZOS}}", "{{/RESIZE_LANCZOS}}", script);
                        script = script.replace("{{#RESIZE_BICUBIC}}", "");
                        script = script.replace("{{/RESIZE_BICUBIC}}", "");
                        script = remove_block("{{#RESIZE_BILINEAR}}", "{{/RESIZE_BILINEAR}}", script);
                    }
                    ResizeKernel::Bilinear => {
                        script = remove_block("{{#RESIZE_SPLINE36}}", "{{/RESIZE_SPLINE36}}", script);
                        script = remove_block("{{#RESIZE_LANCZOS}}", "{{/RESIZE_LANCZOS}}", script);
                        script = remove_block("{{#RESIZE_BICUBIC}}", "{{/RESIZE_BICUBIC}}", script);
                        script = script.replace("{{#RESIZE_BILINEAR}}", "");
                        script = script.replace("{{/RESIZE_BILINEAR}}", "");
                    }
                }
            } else {
                script = remove_block("{{#RESIZE_SPLINE36}}", "{{/RESIZE_SPLINE36}}", script);
                script = remove_block("{{#RESIZE_LANCZOS}}", "{{/RESIZE_LANCZOS}}", script);
                script = remove_block("{{#RESIZE_BICUBIC}}", "{{/RESIZE_BICUBIC}}", script);
                script = remove_block("{{#RESIZE_BILINEAR}}", "{{/RESIZE_BILINEAR}}", script);
            }
        } else {
            script = remove_block("{{#RESIZE}}", "{{/RESIZE}}", script);
        }

        script
    }

    /// Embedded fallback template.
    fn embedded_template() -> String {
        r#"import vapoursynth as vs
import sys

core = vs.core

# Load input video using ffms2 for frame-accurate seeking
clip = core.ffms2.Source(source=r"{{INPUT_PATH}}")

# Get input properties for progress tracking
input_fps_num = clip.fps.numerator
input_fps_den = clip.fps.denominator
total_frames = clip.num_frames
print(f"INPUT_INFO:frames={total_frames},fps_num={input_fps_num},fps_den={input_fps_den}", file=sys.stderr)

# Import havsfunc for QTGMC
import havsfunc as haf

# Apply QTGMC deinterlacing
clip = haf.QTGMC(
    clip,
    Preset="{{PRESET}}",
{{#TFF}}
    TFF={{TFF}},
{{/TFF}}
{{#FPS_DIVISOR}}
    FPSDivisor={{FPS_DIVISOR}},
{{/FPS_DIVISOR}}
{{#OPENCL}}
    opencl={{OPENCL}},
{{/OPENCL}}
)

# Output the processed clip
clip.set_output()
"#.to_string()
    }
}

/// Process an optional integer parameter.
fn process_optional_int(name: &str, value: Option<i32>, mut script: String) -> String {
    let start_tag = format!("{{{{#{}}}}}", name);
    let end_tag = format!("{{{{/{}}}}}", name);
    let placeholder = format!("{{{{{}}}}}", name);

    if let Some(val) = value {
        // Include the block with substituted value
        script = script.replace(&start_tag, "");
        script = script.replace(&end_tag, "");
        script = script.replace(&placeholder, &val.to_string());
    } else {
        // Remove the entire block
        script = remove_block(&start_tag, &end_tag, script);
    }
    script
}

/// Process an optional double parameter.
fn process_optional_double(name: &str, value: Option<f64>, mut script: String) -> String {
    let start_tag = format!("{{{{#{}}}}}", name);
    let end_tag = format!("{{{{/{}}}}}", name);
    let placeholder = format!("{{{{{}}}}}", name);

    if let Some(val) = value {
        script = script.replace(&start_tag, "");
        script = script.replace(&end_tag, "");
        // Format with minimal precision
        let formatted = if val.fract() == 0.0 {
            format!("{:.1}", val)
        } else {
            format!("{:.4}", val).trim_end_matches('0').trim_end_matches('.').to_string()
        };
        script = script.replace(&placeholder, &formatted);
    } else {
        script = remove_block(&start_tag, &end_tag, script);
    }
    script
}

/// Process an optional boolean parameter.
fn process_optional_bool(name: &str, value: Option<bool>, mut script: String) -> String {
    let start_tag = format!("{{{{#{}}}}}", name);
    let end_tag = format!("{{{{/{}}}}}", name);
    let placeholder = format!("{{{{{}}}}}", name);

    if let Some(val) = value {
        script = script.replace(&start_tag, "");
        script = script.replace(&end_tag, "");
        script = script.replace(&placeholder, if val { "True" } else { "False" });
    } else {
        script = remove_block(&start_tag, &end_tag, script);
    }
    script
}

/// Process an optional string parameter.
fn process_optional_string(name: &str, value: Option<&str>, mut script: String) -> String {
    let start_tag = format!("{{{{#{}}}}}", name);
    let end_tag = format!("{{{{/{}}}}}", name);
    let placeholder = format!("{{{{{}}}}}", name);

    if let Some(val) = value {
        script = script.replace(&start_tag, "");
        script = script.replace(&end_tag, "");
        script = script.replace(&placeholder, val);
    } else {
        script = remove_block(&start_tag, &end_tag, script);
    }
    script
}

/// Remove a block from start tag to end tag (including the line).
fn remove_block(start_tag: &str, end_tag: &str, mut script: String) -> String {
    while let Some(start_pos) = script.find(start_tag) {
        if let Some(end_offset) = script[start_pos..].find(end_tag) {
            let end_pos = start_pos + end_offset + end_tag.len();
            // Try to remove the whole line including newline
            let remove_end = if script[end_pos..].starts_with('\n') {
                end_pos + 1
            } else {
                end_pos
            };
            script = format!("{}{}", &script[..start_pos], &script[remove_end..]);
        } else {
            break;
        }
    }
    script
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_remove_block() {
        let input = "before\n{{#TEST}}content{{/TEST}}\nafter";
        let result = remove_block("{{#TEST}}", "{{/TEST}}", input.to_string());
        assert_eq!(result, "before\nafter");
    }

    #[test]
    fn test_process_optional_int_with_value() {
        let input = "prefix{{#NUM}}value={{NUM}},{{/NUM}}suffix";
        let result = process_optional_int("NUM", Some(42), input.to_string());
        assert_eq!(result, "prefixvalue=42,suffix");
    }

    #[test]
    fn test_process_optional_int_without_value() {
        let input = "prefix{{#NUM}}value={{NUM}},{{/NUM}}suffix";
        let result = process_optional_int("NUM", None, input.to_string());
        assert_eq!(result, "prefixsuffix");
    }
}
