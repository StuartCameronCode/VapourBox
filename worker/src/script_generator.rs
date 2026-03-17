//! VapourSynth script generator.
//!
//! Generates .vpy scripts from templates by substituting pipeline parameters.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::models::{
    VideoJob, RestorationPipeline, NoiseReductionMethod, ResizeKernel, UpscaleMethod,
    DehaloMethod, DeblockMethod, SharpenMethod, ChromaSubsampling, DeinterlaceMethod,
};

/// Generates VapourSynth scripts from templates.
pub struct ScriptGenerator {
    template: String,
    preview_template: String,
}

/// Parameters for preview script generation.
pub struct PreviewParams {
    /// Input video width
    pub width: i32,
    /// Input video height
    pub height: i32,
    /// FFmpeg pixel format string (e.g. "yuv420p")
    pub pix_fmt: String,
    /// Number of frames being piped
    pub num_frames: i32,
    /// FPS numerator
    pub fps_num: i32,
    /// FPS denominator
    pub fps_den: i32,
    /// Field order: 1 = BFF, 2 = TFF
    pub field_based: i32,
}

impl ScriptGenerator {
    /// Create a new script generator, loading the templates.
    pub fn new() -> Result<Self> {
        let template = Self::load_template()?;
        let preview_template = Self::load_preview_template()?;
        Ok(Self { template, preview_template })
    }

    /// Generate a .vpy script file for the given job.
    pub fn generate(&self, job: &VideoJob) -> Result<PathBuf> {
        let pipeline = job.effective_pipeline();

        let script = self.substitute_parameters(&self.template, job, &pipeline, &job.input_path);

        // Write to temp file
        let temp_dir = env::temp_dir();
        let script_path = temp_dir.join(format!("{}.vpy", job.id));

        fs::write(&script_path, &script)
            .with_context(|| format!("Failed to write script to {:?}", script_path))?;

        Ok(script_path)
    }

    /// Generate a preview .vpy script that reads raw frames from stdin pipe.
    /// Returns the path to the generated script.
    pub fn generate_preview(&self, job: &VideoJob, preview_params: &PreviewParams) -> Result<PathBuf> {
        let pipeline = job.effective_pipeline();

        // Start with preview template and substitute preview-specific params
        let mut script = self.preview_template.clone();

        // Pipe source directory (same as main pipeline)
        let pipe_source_dir = self.pipe_source_dir().unwrap_or_else(|_| env::temp_dir());
        let dir_str = pipe_source_dir.to_string_lossy().to_string();
        script = script.replace("{{PIPE_SOURCE_DIR}}", &dir_str);

        // Input video properties
        script = script.replace("{{INPUT_WIDTH}}", &preview_params.width.to_string());
        script = script.replace("{{INPUT_HEIGHT}}", &preview_params.height.to_string());
        script = script.replace("{{INPUT_PIX_FMT}}", &preview_params.pix_fmt);
        script = script.replace("{{TOTAL_FRAMES}}", &preview_params.num_frames.to_string());
        script = script.replace("{{FPS_NUM}}", &preview_params.fps_num.to_string());
        script = script.replace("{{FPS_DEN}}", &preview_params.fps_den.to_string());
        script = script.replace("{{FIELD_BASED}}", &preview_params.field_based.to_string());

        // Now apply the same pipeline substitutions
        script = self.substitute_parameters_on(&script, job, &pipeline);

        // Write to temp file
        let temp_dir = env::temp_dir();
        let script_path = temp_dir.join(format!("{}_preview.vpy", job.id));

        fs::write(&script_path, &script)
            .with_context(|| format!("Failed to write preview script to {:?}", script_path))?;

        Ok(script_path)
    }

    /// Load the template from various locations.
    fn load_template() -> Result<String> {
        Self::load_template_by_name("pipeline_template.vpy")
    }

    /// Load the preview template from various locations.
    fn load_preview_template() -> Result<String> {
        Self::load_template_by_name("preview_template.vpy")
    }

    /// Load a template by name from various locations.
    fn load_template_by_name(name: &str) -> Result<String> {
        let exe_path = env::current_exe()?;
        let exe_dir = exe_path.parent().unwrap_or(Path::new("."));

        let search_paths = [
            // Next to executable (production: Contents/MacOS/)
            exe_dir.join("templates").join(name),
            exe_dir.join("Templates").join(name),
            // In Resources (macOS app bundle: Contents/Resources/templates/)
            exe_dir.join("..").join("Resources").join("templates").join(name),
            exe_dir.join("..").join("Resources").join("Templates").join(name),
            // In parent (development: worker/target/debug -> worker/templates)
            exe_dir.join("..").join("..").join("templates").join(name),
            exe_dir.join("..").join("..").join("..").join("templates").join(name),
            // Relative to current dir
            PathBuf::from("templates").join(name),
            PathBuf::from("worker").join("templates").join(name),
        ];

        for path in &search_paths {
            if path.exists() {
                if let Ok(content) = fs::read_to_string(path) {
                    eprintln!("Loaded template from: {:?}", path);
                    return Ok(content);
                }
            }
        }

        let searched: Vec<String> = search_paths.iter()
            .map(|p| p.display().to_string())
            .collect();
        anyhow::bail!(
            "Could not find template '{}'. Searched paths:\n  {}",
            name,
            searched.join("\n  ")
        )
    }

    /// Substitute parameters in a script string.
    fn substitute_parameters(&self, template: &str, job: &VideoJob, pipeline: &RestorationPipeline, _input_path: &str) -> String {
        let mut script = template.to_string();

        // Pipe source parameters — FFmpeg decodes, pipes raw frames to VapourSynth via stdin
        let pipe_source_dir = self.pipe_source_dir().unwrap_or_else(|_| env::temp_dir());
        // Template uses r"..." raw string, so backslashes are literal — no escaping needed
        let dir_str = pipe_source_dir.to_string_lossy().to_string();
        script = script.replace("{{PIPE_SOURCE_DIR}}", &dir_str);

        // Input video properties (from ffprobe, passed via job)
        script = script.replace("{{INPUT_WIDTH}}", &job.input_width.unwrap_or(720).to_string());
        script = script.replace("{{INPUT_HEIGHT}}", &job.input_height.unwrap_or(480).to_string());
        script = script.replace("{{INPUT_PIX_FMT}}", job.input_pixel_format.as_deref().unwrap_or("yuv420p"));

        // Total frames — use job value or fallback
        let total_frames = job.total_frames.unwrap_or(1);
        script = script.replace("{{TOTAL_FRAMES}}", &total_frames.to_string());

        // FPS as rational number
        let (fps_num, fps_den) = self.frame_rate_to_rational(job.input_frame_rate.unwrap_or(29.97));
        script = script.replace("{{INPUT_FPS_NUM}}", &fps_num.to_string());
        script = script.replace("{{INPUT_FPS_DEN}}", &fps_den.to_string());

        // Field order — set from detected field order or TFF parameter
        let field_based = match job.detected_field_order {
            Some(crate::models::FieldOrder::TopFieldFirst) => Some(2),
            Some(crate::models::FieldOrder::BottomFieldFirst) => Some(1),
            _ => {
                // Fall back to QTGMC TFF parameter
                if pipeline.deinterlace.enabled {
                    Some(if pipeline.deinterlace.tff.unwrap_or(true) { 2 } else { 1 })
                } else {
                    None
                }
            }
        };
        if let Some(fb) = field_based {
            script = script.replace("{{#SET_FIELD_BASED}}", "");
            script = script.replace("{{/SET_FIELD_BASED}}", "");
            script = script.replace("{{FIELD_BASED}}", &fb.to_string());
        } else {
            script = remove_block("{{#SET_FIELD_BASED}}", "{{/SET_FIELD_BASED}}", script);
        }

        self.substitute_parameters_on(&script, job, pipeline)
    }

    /// Get the directory where pipe_source.py lives (same search as templates).
    fn pipe_source_dir(&self) -> Result<PathBuf> {
        let exe_path = env::current_exe()?;
        let exe_dir = exe_path.parent().unwrap_or(Path::new("."));

        let search_paths = [
            exe_dir.join("templates"),
            exe_dir.join("Templates"),
            exe_dir.join("..").join("Resources").join("templates"),
            exe_dir.join("..").join("Resources").join("Templates"),
            exe_dir.join("..").join("..").join("templates"),
            exe_dir.join("..").join("..").join("..").join("templates"),
            PathBuf::from("templates"),
            PathBuf::from("worker").join("templates"),
        ];

        for path in &search_paths {
            if path.join("pipe_source.py").exists() {
                // Use canonicalize for a clean absolute path, but strip the \\?\ prefix
                // that Windows adds — Python can't handle extended-length path syntax.
                let canonical = fs::canonicalize(path)?;
                let path_str = canonical.to_string_lossy();
                if path_str.starts_with(r"\\?\") {
                    return Ok(PathBuf::from(&path_str[4..]));
                }
                return Ok(canonical);
            }
        }

        anyhow::bail!("Could not find pipe_source.py in template search paths")
    }

    /// Convert a floating-point frame rate to a rational number (num/den).
    pub fn frame_rate_to_rational(&self, fps: f64) -> (i32, i32) {
        // Common frame rates
        let common = [
            (23.976, 24000, 1001),
            (24.0, 24, 1),
            (25.0, 25, 1),
            (29.97, 30000, 1001),
            (30.0, 30, 1),
            (50.0, 50, 1),
            (59.94, 60000, 1001),
            (60.0, 60, 1),
        ];

        for (rate, num, den) in common {
            if (fps - rate).abs() < 0.01 {
                return (num, den);
            }
        }

        // Fallback: multiply by 1000 and simplify
        let num = (fps * 1000.0).round() as i32;
        (num, 1000)
    }

    /// Substitute pipeline parameters on an already-prepared script.
    fn substitute_parameters_on(&self, script: &str, job: &VideoJob, pipeline: &RestorationPipeline) -> String {
        let mut script = script.to_string();
        let params = &pipeline.deinterlace;

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
        // DEINTERLACE PASS
        // ====================================================================
        if pipeline.deinterlace.enabled {
            script = script.replace("{{#DEINTERLACE}}", "");
            script = script.replace("{{/DEINTERLACE}}", "");

            match params.method {
                DeinterlaceMethod::Qtgmc => {
                    // Enable QTGMC block, remove IVTC and Soft Telecine blocks
                    script = script.replace("{{#DEINT_QTGMC}}", "");
                    script = script.replace("{{/DEINT_QTGMC}}", "");
                    script = remove_block("{{#DEINT_IVTC}}", "{{/DEINT_IVTC}}", script);
                    script = remove_block("{{#DEINT_SOFT_TELECINE}}", "{{/DEINT_SOFT_TELECINE}}", script);

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
                }
                DeinterlaceMethod::Ivtc => {
                    // Enable IVTC block, remove QTGMC and Soft Telecine blocks
                    script = remove_block("{{#DEINT_QTGMC}}", "{{/DEINT_QTGMC}}", script);
                    script = script.replace("{{#DEINT_IVTC}}", "");
                    script = script.replace("{{/DEINT_IVTC}}", "");
                    script = remove_block("{{#DEINT_SOFT_TELECINE}}", "{{/DEINT_SOFT_TELECINE}}", script);

                    // Derive IVTC_ORDER from tff field (TFF→1, BFF→0), falling back to ivtc_order
                    let order = match params.tff {
                        Some(true) => 1,
                        Some(false) => 0,
                        None => params.ivtc_order,
                    };
                    script = script.replace("{{IVTC_ORDER}}", &order.to_string());

                    // VFM parameters
                    script = process_optional_int("IVTC_MODE", if params.ivtc_mode != 1 { Some(params.ivtc_mode) } else { None }, script);
                    script = process_optional_int("IVTC_CTHRESH", params.ivtc_cthresh, script);
                    script = process_optional_int("IVTC_MI", params.ivtc_mi, script);
                    script = process_optional_int("IVTC_BLOCK_X", params.ivtc_block_x, script);
                    script = process_optional_int("IVTC_BLOCK_Y", params.ivtc_block_y, script);

                    // VDecimate parameters
                    script = process_optional_int("IVTC_CYCLE", if params.ivtc_cycle != 5 { Some(params.ivtc_cycle) } else { None }, script);
                    script = process_optional_double("IVTC_DUPTHRESH", params.ivtc_dupthresh, script);
                    script = process_optional_double("IVTC_SCTHRESH", params.ivtc_scthresh, script);
                }
                DeinterlaceMethod::SoftTelecine => {
                    // Enable Soft Telecine block, remove QTGMC and IVTC blocks
                    script = remove_block("{{#DEINT_QTGMC}}", "{{/DEINT_QTGMC}}", script);
                    script = remove_block("{{#DEINT_IVTC}}", "{{/DEINT_IVTC}}", script);
                    script = script.replace("{{#DEINT_SOFT_TELECINE}}", "");
                    script = script.replace("{{/DEINT_SOFT_TELECINE}}", "");
                }
            }
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
        // DEHALO PASS
        // ====================================================================
        let dehalo = &pipeline.dehalo;
        if dehalo.enabled {
            script = script.replace("{{#DEHALO}}", "");
            script = script.replace("{{/DEHALO}}", "");

            match dehalo.method {
                DehaloMethod::DehaloAlpha => {
                    script = script.replace("{{#DEHALO_DEHALO_ALPHA}}", "");
                    script = script.replace("{{/DEHALO_DEHALO_ALPHA}}", "");
                    script = remove_block("{{#DEHALO_FINE_DEHALO}}", "{{/DEHALO_FINE_DEHALO}}", script);
                    script = remove_block("{{#DEHALO_YAHR}}", "{{/DEHALO_YAHR}}", script);
                }
                DehaloMethod::FineDehalo => {
                    script = remove_block("{{#DEHALO_DEHALO_ALPHA}}", "{{/DEHALO_DEHALO_ALPHA}}", script);
                    script = script.replace("{{#DEHALO_FINE_DEHALO}}", "");
                    script = script.replace("{{/DEHALO_FINE_DEHALO}}", "");
                    script = remove_block("{{#DEHALO_YAHR}}", "{{/DEHALO_YAHR}}", script);
                    script = process_optional_int("DEHALO_LOW_THRESHOLD", Some(dehalo.low_threshold), script);
                    script = process_optional_int("DEHALO_HIGH_THRESHOLD", Some(dehalo.high_threshold), script);
                }
                DehaloMethod::Yahr => {
                    script = remove_block("{{#DEHALO_DEHALO_ALPHA}}", "{{/DEHALO_DEHALO_ALPHA}}", script);
                    script = remove_block("{{#DEHALO_FINE_DEHALO}}", "{{/DEHALO_FINE_DEHALO}}", script);
                    script = script.replace("{{#DEHALO_YAHR}}", "");
                    script = script.replace("{{/DEHALO_YAHR}}", "");
                    script = process_optional_int("DEHALO_YAHR_BLUR", Some(dehalo.yahr_blur), script);
                    script = process_optional_int("DEHALO_YAHR_DEPTH", Some(dehalo.yahr_depth), script);
                }
            }

            // Common parameters for DeHalo_alpha and FineDehalo
            if dehalo.method != DehaloMethod::Yahr {
                script = process_optional_double("DEHALO_RX", Some(dehalo.rx), script);
                script = process_optional_double("DEHALO_RY", Some(dehalo.ry), script);
                script = process_optional_double("DEHALO_DARKSTR", Some(dehalo.dark_str), script);
                script = process_optional_double("DEHALO_BRIGHTSTR", Some(dehalo.bright_str), script);
            }
        } else {
            script = remove_block("{{#DEHALO}}", "{{/DEHALO}}", script);
        }

        // ====================================================================
        // DEBLOCK PASS
        // ====================================================================
        let deblock = &pipeline.deblock;
        if deblock.enabled {
            script = script.replace("{{#DEBLOCK}}", "");
            script = script.replace("{{/DEBLOCK}}", "");

            match deblock.method {
                DeblockMethod::DeblockQed => {
                    script = script.replace("{{#DEBLOCK_QED}}", "");
                    script = script.replace("{{/DEBLOCK_QED}}", "");
                    script = remove_block("{{#DEBLOCK_SIMPLE}}", "{{/DEBLOCK_SIMPLE}}", script);

                    script = process_optional_int("DEBLOCK_QUANT1", Some(deblock.quant1), script);
                    script = process_optional_int("DEBLOCK_QUANT2", Some(deblock.quant2), script);
                    script = process_optional_int("DEBLOCK_AOFFSET1", Some(deblock.a_offset1), script);
                    script = process_optional_int("DEBLOCK_AOFFSET2", Some(deblock.a_offset2), script);
                }
                DeblockMethod::Deblock => {
                    script = remove_block("{{#DEBLOCK_QED}}", "{{/DEBLOCK_QED}}", script);
                    script = script.replace("{{#DEBLOCK_SIMPLE}}", "");
                    script = script.replace("{{/DEBLOCK_SIMPLE}}", "");

                    script = process_optional_int("DEBLOCK_QUANT1", Some(deblock.quant1), script);
                }
            }
        } else {
            script = remove_block("{{#DEBLOCK}}", "{{/DEBLOCK}}", script);
        }

        // ====================================================================
        // DEBAND PASS (f3kdb)
        // ====================================================================
        let deband = &pipeline.deband;
        if deband.enabled {
            script = script.replace("{{#DEBAND}}", "");
            script = script.replace("{{/DEBAND}}", "");

            script = process_optional_int("DEBAND_RANGE", Some(deband.range), script);
            script = process_optional_int("DEBAND_Y", Some(deband.y), script);
            script = process_optional_int("DEBAND_CB", Some(deband.cb), script);
            script = process_optional_int("DEBAND_CR", Some(deband.cr), script);
            script = process_optional_int("DEBAND_GRAINY", Some(deband.grain_y), script);
            script = process_optional_int("DEBAND_GRAINC", Some(deband.grain_c), script);
            script = process_optional_bool("DEBAND_DYNAMIC_GRAIN", Some(deband.dynamic_grain), script);
            script = process_optional_int("DEBAND_OUTPUT_DEPTH", Some(deband.output_depth), script);
        } else {
            script = remove_block("{{#DEBAND}}", "{{/DEBAND}}", script);
        }

        // ====================================================================
        // SHARPEN PASS
        // ====================================================================
        let sharpen = &pipeline.sharpen;
        if sharpen.enabled {
            script = script.replace("{{#SHARPEN}}", "");
            script = script.replace("{{/SHARPEN}}", "");

            match sharpen.method {
                SharpenMethod::LSFmod => {
                    script = script.replace("{{#SHARPEN_LSFMOD}}", "");
                    script = script.replace("{{/SHARPEN_LSFMOD}}", "");
                    script = remove_block("{{#SHARPEN_CAS}}", "{{/SHARPEN_CAS}}", script);

                    script = process_optional_int("SHARPEN_STRENGTH", Some(sharpen.strength), script);
                    script = process_optional_int("SHARPEN_OVERSHOOT", Some(sharpen.overshoot), script);
                    script = process_optional_int("SHARPEN_UNDERSHOOT", Some(sharpen.undershoot), script);
                    script = process_optional_int("SHARPEN_SOFT_EDGE", Some(sharpen.soft_edge), script);
                }
                SharpenMethod::CAS => {
                    script = remove_block("{{#SHARPEN_LSFMOD}}", "{{/SHARPEN_LSFMOD}}", script);
                    script = script.replace("{{#SHARPEN_CAS}}", "");
                    script = script.replace("{{/SHARPEN_CAS}}", "");

                    script = process_optional_double("SHARPEN_CAS_SHARPNESS", Some(sharpen.cas_sharpness), script);
                }
            }
        } else {
            script = remove_block("{{#SHARPEN}}", "{{/SHARPEN}}", script);
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
                script = script.replace("{{#RESIZE_STANDARD}}", "");
                script = script.replace("{{/RESIZE_STANDARD}}", "");

                // Use -1 for unspecified dimensions (maintain aspect will calculate)
                let width = resize.target_width.unwrap_or(-1);
                let height = resize.target_height.unwrap_or(-1);
                script = script.replace("{{TARGET_WIDTH}}", &width.to_string());
                script = script.replace("{{TARGET_HEIGHT}}", &height.to_string());

                // Handle maintain aspect ratio
                if resize.maintain_aspect {
                    script = script.replace("{{#MAINTAIN_ASPECT}}", "");
                    script = script.replace("{{/MAINTAIN_ASPECT}}", "");
                } else {
                    script = remove_block("{{#MAINTAIN_ASPECT}}", "{{/MAINTAIN_ASPECT}}", script);
                }

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
                script = remove_block("{{#RESIZE_STANDARD}}", "{{/RESIZE_STANDARD}}", script);
            }
        } else {
            script = remove_block("{{#RESIZE}}", "{{/RESIZE}}", script);
        }

        // ====================================================================
        // OUTPUT CHROMA SUBSAMPLING CONVERSION
        // ====================================================================
        match job.encoding_settings.chroma_subsampling {
            ChromaSubsampling::Original => {
                script = remove_block("{{#CHROMA_CONVERT}}", "{{/CHROMA_CONVERT}}", script);
            }
            ChromaSubsampling::Yuv420 => {
                script = script.replace("{{#CHROMA_CONVERT}}", "");
                script = script.replace("{{/CHROMA_CONVERT}}", "");
                // Use YUV420P8 for 8-bit, YUV420P16 for higher bit depth
                // We'll default to 8-bit since that's most common for deinterlaced content
                script = script.replace("{{CHROMA_FORMAT}}", "vs.YUV420P8");
            }
            ChromaSubsampling::Yuv422 => {
                script = script.replace("{{#CHROMA_CONVERT}}", "");
                script = script.replace("{{/CHROMA_CONVERT}}", "");
                script = script.replace("{{CHROMA_FORMAT}}", "vs.YUV422P8");
            }
        }

        script
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
