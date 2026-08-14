//! VapourSynth script generator.
//!
//! Generates .vpy scripts from templates by substituting pipeline parameters.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::models::{
    VideoJob, ProcessingPipeline, NoiseReductionMethod, UpscaleMethod, CCD_REFERENCE_HEIGHT,
    parse_ratio,
    DehaloMethod, DeblockMethod, SharpenMethod, DeinterlaceMethod,
    FieldOrder,
};

/// Generates VapourSynth scripts from templates.
pub struct ScriptGenerator {
    template: String,
    preview_template: String,
    /// Whether a usable OpenCL device is available. When false, the GPU
    /// NNEDI3CL path is never emitted (QTGMC falls back to CPU NNEDI3), so the
    /// script runs on headless/VM/remote-desktop machines without a GPU.
    /// Defaults to true; callers set it from `DependencyLocator::opencl_available()`.
    opencl_available: bool,
    /// Whether the `knlm.KNLMeansCL` denoiser can actually run here (plugin
    /// present AND a usable OpenCL device). When false, a `Denoiser="knlmeanscl"`
    /// selection is downgraded to `"dfttest"` so the job doesn't crash with
    /// `knlm.KNLMeansCL: CL_INVALID_VALUE` / a missing-namespace error. Defaults
    /// to true; callers set it from `DependencyLocator::knlm_available()`.
    knlm_available: bool,
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
    /// Output frame index to emit as the preview (after the pipeline runs on
    /// the decoded window). Accounts for any frame-rate change in the pipeline.
    pub output_index: i32,
}

impl ScriptGenerator {
    /// Create a new script generator, loading the templates.
    pub fn new() -> Result<Self> {
        let template = Self::load_template()?;
        let preview_template = Self::load_preview_template()?;
        Ok(Self { template, preview_template, opencl_available: true, knlm_available: true })
    }

    /// Set whether OpenCL is available (probe result from `DependencyLocator`).
    /// When false, the GPU NNEDI3CL path is suppressed and QTGMC uses CPU NNEDI3.
    pub fn with_opencl_available(mut self, available: bool) -> Self {
        self.opencl_available = available;
        self
    }

    /// Set whether the knlmeanscl denoiser is usable (probe result from
    /// `DependencyLocator`). When false, a `Denoiser="knlmeanscl"` selection is
    /// downgraded to `"dfttest"` so QTGMC denoising doesn't crash.
    pub fn with_knlm_available(mut self, available: bool) -> Self {
        self.knlm_available = available;
        self
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
        let pipe_source_dir = Self::pipe_source_dir().unwrap_or_else(|_| env::temp_dir());
        let dir_str = pipe_source_dir.to_string_lossy().to_string();
        script = script.replace("{{PIPE_SOURCE_DIR}}", &dir_str);

        // Input video properties
        script = script.replace("{{INPUT_WIDTH}}", &preview_params.width.to_string());
        script = script.replace("{{INPUT_HEIGHT}}", &preview_params.height.to_string());
        script = script.replace("{{INPUT_PIX_FMT}}", &preview_params.pix_fmt);
        script = script.replace("{{TOTAL_FRAMES}}", &preview_params.num_frames.to_string());
        script = script.replace("{{FPS_NUM}}", &preview_params.fps_num.to_string());
        script = script.replace("{{FPS_DEN}}", &preview_params.fps_den.to_string());
        script = script.replace("{{PREVIEW_OUTPUT_INDEX}}", &preview_params.output_index.to_string());
        // Field-based: same derivation as the encode path, so the preview can't
        // deinterlace at a different field order than the final render.
        if let Some(fb) = Self::field_based_for(job, &pipeline) {
            script = script.replace("{{#SET_FIELD_BASED}}", "");
            script = script.replace("{{/SET_FIELD_BASED}}", "");
            script = script.replace("{{FIELD_BASED}}", &fb.to_string());
        } else {
            script = remove_block("{{#SET_FIELD_BASED}}", "{{/SET_FIELD_BASED}}", script);
        }

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

    /// The `_FieldBased` value to mark the source clip with, or `None` to leave
    /// it unmarked.
    ///
    /// This is the single derivation used by both the encode and the preview
    /// path. It must stay that way: `std.SeparateFields` ignores its `tff`
    /// argument whenever `_FieldBased` is set, so the property — not QTGMC's
    /// `TFF=` parameter — decides the field order that is actually used. Two
    /// derivations that can disagree means the user's field-order choice can be
    /// silently overridden, and preview can disagree with the encode (issue #49).
    pub fn field_based_for(job: &VideoJob, pipeline: &ProcessingPipeline) -> Option<i32> {
        if pipeline.deinterlace.enabled {
            // Deinterlacing: the pass's own field order is authoritative.
            Some(if pipeline.deinterlace.tff.unwrap_or(true) { 2 } else { 1 })
        } else {
            // Not deinterlacing: still mark what was detected, so field-aware
            // chroma resampling in any later resize stays correct.
            match job.detected_field_order {
                Some(FieldOrder::TopFieldFirst) => Some(2),
                Some(FieldOrder::BottomFieldFirst) => Some(1),
                _ => None,
            }
        }
    }

    /// Substitute parameters in a script string.
    fn substitute_parameters(&self, template: &str, job: &VideoJob, pipeline: &ProcessingPipeline, _input_path: &str) -> String {
        let mut script = template.to_string();

        // Pipe source parameters — FFmpeg decodes, pipes raw frames to VapourSynth via stdin
        let pipe_source_dir = Self::pipe_source_dir().unwrap_or_else(|_| env::temp_dir());
        // Template uses r"..." raw string, so backslashes are literal — no escaping needed
        let dir_str = pipe_source_dir.to_string_lossy().to_string();
        script = script.replace("{{PIPE_SOURCE_DIR}}", &dir_str);

        // Input video properties (from ffprobe, passed via job)
        script = script.replace("{{INPUT_WIDTH}}", &job.input_width.unwrap_or(720).to_string());
        script = script.replace("{{INPUT_HEIGHT}}", &job.input_height.unwrap_or(480).to_string());
        // Must be the format the decoder is actually told to emit — see
        // pixel_format.rs, which both paths derive from the job.
        let pipe_format = crate::pixel_format::decode_pixel_format(job.input_pixel_format.as_deref());
        script = script.replace("{{INPUT_PIX_FMT}}", &pipe_format.name);

        // Total frames — use job value or fallback
        let total_frames = job.total_frames.unwrap_or(1);
        script = script.replace("{{TOTAL_FRAMES}}", &total_frames.to_string());

        // FPS as rational number
        let (fps_num, fps_den) = self.frame_rate_to_rational(job.input_frame_rate.unwrap_or(29.97));
        script = script.replace("{{INPUT_FPS_NUM}}", &fps_num.to_string());
        script = script.replace("{{INPUT_FPS_DEN}}", &fps_den.to_string());

        // Field order.
        //
        // When deinterlacing, this MUST come from the same value as the
        // deinterlacer's TFF argument: std.SeparateFields ignores its `tff`
        // argument whenever _FieldBased is set, so deriving the two from
        // different sources lets the property silently override the user's
        // field-order choice (issue #49). `field_based_for` is the single
        // derivation shared with the preview path.
        let field_based = ScriptGenerator::field_based_for(job, pipeline);
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
    pub fn pipe_source_dir() -> Result<PathBuf> {
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
    fn substitute_parameters_on(&self, script: &str, job: &VideoJob, pipeline: &ProcessingPipeline) -> String {
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

                    // Working format around the QTGMC call (issue #49): 4:2:2
                    // chroma and/or 16-bit, restored to the source format after.
                    // Only emitted when at least one of them is on, so the
                    // common case generates exactly the script it did before.
                    let chroma_fix = params.chroma_upsample_fix_enabled();
                    let high_precision = params.high_precision_enabled();
                    if chroma_fix || high_precision {
                        script = script.replace("{{#DEINT_WORKING_FORMAT}}", "");
                        script = script.replace("{{/DEINT_WORKING_FORMAT}}", "");
                        script = script.replace("{{#DEINT_RESTORE_FORMAT}}", "");
                        script = script.replace("{{/DEINT_RESTORE_FORMAT}}", "");
                        if chroma_fix {
                            script = script.replace("{{#DEINT_WF_CHROMA}}", "");
                            script = script.replace("{{/DEINT_WF_CHROMA}}", "");
                        } else {
                            script = remove_block("{{#DEINT_WF_CHROMA}}", "{{/DEINT_WF_CHROMA}}", script);
                        }
                        if high_precision {
                            script = script.replace("{{#DEINT_WF_BITS}}", "");
                            script = script.replace("{{/DEINT_WF_BITS}}", "");
                        } else {
                            script = remove_block("{{#DEINT_WF_BITS}}", "{{/DEINT_WF_BITS}}", script);
                        }
                    } else {
                        script = remove_block("{{#DEINT_WORKING_FORMAT}}", "{{/DEINT_WORKING_FORMAT}}", script);
                        script = remove_block("{{#DEINT_RESTORE_FORMAT}}", "{{/DEINT_RESTORE_FORMAT}}", script);
                    }

                    // Preset (required)
                    script = script.replace("{{PRESET}}", params.preset.as_str());

                    // Process optional QTGMC parameters
                    script = process_optional_bool("TFF", params.tff, script);
                    script = process_optional_int("INPUT_TYPE", params.input_type, script);
                    script = process_optional_int("FPS_DIVISOR", params.fps_divisor, script);

                    // Quality parameters
                    script = process_optional_int("TR0", params.tr0, script);
                    script = process_optional_int("TR1", params.tr1, script);
                    script = process_optional_int("TR2", params.tr2, script);
                    script = process_optional_int("REP0", params.rep0, script);
                    script = process_optional_int("REP1", params.rep1, script);
                    script = process_optional_int("REP2", params.rep2, script);
                    script = process_optional_bool("REP_CHROMA", params.rep_chroma, script);

                    // Interpolation
                    script = process_optional_string("EDI_MODE", params.edi_mode.as_deref(), script);
                    script = process_optional_int("NN_SIZE", params.nn_size, script);
                    script = process_optional_int("NN_NEURONS", params.nn_neurons, script);
                    script = process_optional_int("EDI_QUAL", params.edi_qual, script);
                    script = process_optional_int("EDI_MAX_D", params.edi_max_d, script);
                    // Only values havsfunc implements — anything else silently
                    // breaks chroma (issue #49). See normalized_chroma_edi.
                    script = process_optional_string("CHROMA_EDI", params.normalized_chroma_edi().as_deref(), script);

                    // Motion analysis
                    script = process_optional_int("BLOCK_SIZE", params.block_size, script);
                    script = process_optional_int("OVERLAP", params.overlap, script);
                    script = process_optional_int("SEARCH", params.search, script);
                    script = process_optional_int("SEARCH_PARAM", params.search_param, script);
                    script = process_optional_int("PEL_SEARCH", params.pel_search, script);
                    script = process_optional_bool("CHROMA_MOTION", params.chroma_motion, script);
                    script = process_optional_bool("TRUE_MOTION", params.true_motion, script);
                    script = process_optional_int("LAMBDA", params.lambda, script);
                    script = process_optional_int("LSAD", params.lsad, script);
                    script = process_optional_int("P_NEW", params.p_new, script);
                    script = process_optional_int("P_LEVEL", params.p_level, script);
                    script = process_optional_bool("GLOBAL_MOTION", params.global_motion, script);
                    script = process_optional_int("DCT", params.dct, script);
                    script = process_optional_int("SUB_PEL", params.sub_pel, script);
                    script = process_optional_int("SUB_PEL_INTERP", params.sub_pel_interp, script);

                    // Thresholds
                    script = process_optional_int("TH_SAD1", params.th_sad1, script);
                    script = process_optional_int("TH_SAD2", params.th_sad2, script);
                    script = process_optional_int("TH_SCD1", params.th_scd1, script);
                    script = process_optional_int("TH_SCD2", params.th_scd2, script);

                    // Sharpening
                    script = process_optional_double("SHARPNESS", params.sharpness, script);
                    script = process_optional_int("S_MODE", params.s_mode, script);
                    script = process_optional_int("SL_MODE", params.sl_mode, script);
                    script = process_optional_int("SL_RAD", params.sl_rad, script);
                    script = process_optional_int("S_OVS", params.s_ovs, script);
                    script = process_optional_double("SV_THIN", params.sv_thin, script);
                    script = process_optional_int("SBB", params.sbb, script);
                    script = process_optional_int("SRCH_CLIP_PP", params.srch_clip_pp, script);

                    // Noise processing
                    // When noise reduction is set to QTGMC built-in, use the noise
                    // reduction model's values (which the user set in the NR panel)
                    // instead of the QTGMC model's values.
                    let nr = &pipeline.noise_reduction;
                    let (ez_denoise, ez_keep_grain) = if nr.enabled
                        && nr.method == NoiseReductionMethod::QtgmcBuiltin
                        && (nr.qtgmc_ez_denoise > 0.0 || nr.qtgmc_ez_keep_grain > 0.0)
                    {
                        (Some(nr.qtgmc_ez_denoise), Some(nr.qtgmc_ez_keep_grain))
                    } else {
                        (params.ez_denoise, params.ez_keep_grain)
                    };
                    script = process_optional_int("NOISE_PROCESS", params.noise_process, script);
                    script = process_optional_double("EZ_DENOISE", ez_denoise, script);
                    script = process_optional_double("EZ_KEEP_GRAIN", ez_keep_grain, script);
                    script = process_optional_string("NOISE_PRESET", params.noise_preset.as_deref(), script);
                    // Gate the knlmeanscl denoiser on actual availability: if it's
                    // selected but KNLMeansCL can't run here (plugin missing or no
                    // usable OpenCL device), fall back to dfttest so the job
                    // doesn't crash with a missing-namespace / CL_INVALID_VALUE
                    // error. Any other denoiser passes through unchanged.
                    let denoiser = gate_knlm_denoiser(params.denoiser.as_deref(), self.knlm_available);
                    if params.denoiser.as_deref() == Some("knlmeanscl")
                        && denoiser.as_deref() == Some("dfttest")
                    {
                        eprintln!(
                            "knlmeanscl denoiser selected but KNLMeansCL is unavailable \
                             here (plugin missing or no usable OpenCL device) — falling \
                             back to dfttest"
                        );
                    }
                    script = process_optional_string("DENOISER", denoiser.as_deref(), script);
                    script = process_optional_int("FFT_THREADS", params.fft_threads, script);
                    script = process_optional_bool("DENOISE_MC", params.denoise_mc, script);
                    script = process_optional_int("NOISE_TR", params.noise_tr, script);
                    script = process_optional_double("SIGMA", params.sigma, script);
                    script = process_optional_bool("CHROMA_NOISE", params.chroma_noise, script);
                    script = process_optional_double("SHOW_NOISE", params.show_noise, script);
                    script = process_optional_double("GRAIN_RESTORE", params.grain_restore, script);
                    script = process_optional_double("NOISE_RESTORE", params.noise_restore, script);
                    script = process_optional_string("NOISE_DEINT", params.noise_deint.as_deref(), script);
                    script = process_optional_bool("STABILIZE_NOISE", params.stabilize_noise, script);

                    // Source matching
                    script = process_optional_int("SOURCE_MATCH", params.source_match, script);
                    script = process_optional_string("MATCH_PRESET", params.match_preset.as_deref(), script);
                    script = process_optional_string("MATCH_EDI", params.match_edi.as_deref(), script);
                    script = process_optional_string("MATCH_PRESET2", params.match_preset2.as_deref(), script);
                    script = process_optional_string("MATCH_EDI2", params.match_edi2.as_deref(), script);
                    script = process_optional_int("MATCH_TR2", params.match_tr2, script);
                    script = process_optional_double("MATCH_ENHANCE", params.match_enhance, script);
                    script = process_optional_int("LOSSLESS", params.lossless, script);

                    // Advanced
                    script = process_optional_bool("BORDER", params.border, script);
                    script = process_optional_bool("PRECISE", params.precise, script);
                    script = process_optional_int("FORCE_TR", params.force_tr, script);
                    script = process_optional_double("STR", params.str, script);
                    script = process_optional_double("AMP", params.amp, script);
                    script = process_optional_bool("FAST_MA", params.fast_ma, script);
                    script = process_optional_bool("E_SEARCH_P", params.e_search_p, script);
                    script = process_optional_bool("REFINE_MOTION", params.refine_motion, script);

                    // GPU — default to OpenCL on macOS where ZNEDI3/NNEDI3
                    // lack NEON optimisations and run pure scalar C.
                    // Only auto-enable when EdiMode is compatible (unset or "nnedi3")
                    // because our eedi3m plugin lacks EEDI3CL.
                    let desired_opencl;
                    #[cfg(target_os = "macos")]
                    {
                        let edi_ok = match params.edi_mode.as_deref() {
                            None | Some("nnedi3") => true,
                            _ => false,
                        };
                        // Treat Some(false) as unset — the Dart UI serializes null
                        // as false, so only explicit Some(true) means user opted in.
                        let user_set = params.opencl.unwrap_or(false);
                        desired_opencl = if user_set {
                            Some(true)
                        } else if edi_ok {
                            Some(true)
                        } else {
                            params.opencl
                        };
                    }
                    #[cfg(not(target_os = "macos"))]
                    {
                        desired_opencl = params.opencl;
                    }
                    // Gate auto-enabled OpenCL on detected availability: if we'd
                    // enable the GPU NNEDI3CL path but no usable OpenCL device
                    // exists (headless CI, VM, remote desktop), fall back to CPU
                    // NNEDI3 so the script doesn't fail with "NNEDI3CL: Invalid
                    // Value". A user who *explicitly* enabled OpenCL overrides the
                    // probe — their choice wins (it will error if no device, by
                    // design). The Dart UI serializes an unset toggle as false, so
                    // only Some(true) counts as an explicit opt-in.
                    let user_forced_opencl = params.opencl == Some(true);
                    let opencl =
                        gate_opencl(desired_opencl, self.opencl_available, user_forced_opencl);
                    if !user_forced_opencl && desired_opencl == Some(true) && opencl == Some(false) {
                        eprintln!(
                            "OpenCL auto-enabled but no usable device detected — \
                             falling back to CPU NNEDI3 (set the OpenCL option to \
                             force it)"
                        );
                    }
                    script = process_optional_bool("OPENCL", opencl, script);
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
                        None => params.ivtc_order.unwrap_or(1),
                    };
                    script = script.replace("{{IVTC_ORDER}}", &order.to_string());

                    // VFM parameters
                    script = process_optional_int("IVTC_MODE", params.ivtc_mode, script);
                    script = process_optional_int("IVTC_CTHRESH", params.ivtc_cthresh, script);
                    script = process_optional_int("IVTC_MI", params.ivtc_mi, script);
                    script = process_optional_int("IVTC_BLOCK_X", params.ivtc_block_x, script);
                    script = process_optional_int("IVTC_BLOCK_Y", params.ivtc_block_y, script);

                    // VDecimate parameters
                    script = process_optional_int("IVTC_CYCLE", params.ivtc_cycle, script);
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
        // DESCRATCH PASS
        // ====================================================================
        let descratch = &pipeline.descratch;
        if descratch.enabled {
            script = script.replace("{{#DESCRATCH}}", "");
            script = script.replace("{{/DESCRATCH}}", "");

            script = process_optional_int("DESCRATCH_MINDIF", Some(descratch.mindif), script);
            script = process_optional_int("DESCRATCH_ASYM", Some(descratch.asym), script);
            script = process_optional_int("DESCRATCH_MAXGAP", Some(descratch.maxgap), script);
            script = process_optional_int("DESCRATCH_MAXWIDTH", Some(descratch.maxwidth), script);
            script = process_optional_int("DESCRATCH_MINWIDTH", Some(descratch.minwidth), script);
            script = process_optional_int("DESCRATCH_MINLEN", Some(descratch.minlen), script);
            script = process_optional_int("DESCRATCH_MAXLEN", Some(descratch.maxlen), script);
            script = process_optional_int("DESCRATCH_MAXANGLE", Some(descratch.maxangle), script);
            script = process_optional_int("DESCRATCH_BLURLEN", Some(descratch.blurlen), script);
            script = process_optional_int("DESCRATCH_KEEP", Some(descratch.keep), script);
            script = process_optional_int("DESCRATCH_BORDER", Some(descratch.border), script);
            script = process_optional_int("DESCRATCH_MODEY", Some(descratch.mode_y), script);
            script = process_optional_int("DESCRATCH_MODEU", Some(descratch.mode_u), script);
            script = process_optional_int("DESCRATCH_MODEV", Some(descratch.mode_v), script);
            script = process_optional_int("DESCRATCH_MINDIFUV", Some(descratch.mindif_uv), script);
        } else {
            script = remove_block("{{#DESCRATCH}}", "{{/DESCRATCH}}", script);
        }

        // ====================================================================
        // SPOTLESS PASS
        // ====================================================================
        let spotless = &pipeline.spotless;
        if spotless.enabled {
            script = script.replace("{{#SPOTLESS}}", "");
            script = script.replace("{{/SPOTLESS}}", "");

            script = process_optional_bool("SPOTLESS_CHROMA", Some(spotless.chroma), script);
            script = process_optional_bool("SPOTLESS_REC", Some(spotless.rec), script);
            script = process_optional_int("SPOTLESS_BLKSIZE", Some(spotless.blksize), script);
            script = process_optional_int("SPOTLESS_OVERLAP", Some(spotless.overlap), script);
            script = process_optional_int("SPOTLESS_PEL", Some(spotless.pel), script);
        } else {
            script = remove_block("{{#SPOTLESS}}", "{{/SPOTLESS}}", script);
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
                    script = remove_block("{{#NR_MCDEGRAINSHARP}}", "{{/NR_MCDEGRAINSHARP}}", script);
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);
                    script = remove_block("{{#NR_DFTTEST}}", "{{/NR_DFTTEST}}", script);
                    script = remove_block("{{#NR_FFT3D}}", "{{/NR_FFT3D}}", script);
                    script = remove_block("{{#NR_TTEMPSMOOTH}}", "{{/NR_TTEMPSMOOTH}}", script);

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
                    script = remove_block("{{#NR_MCDEGRAINSHARP}}", "{{/NR_MCDEGRAINSHARP}}", script);
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);
                    script = remove_block("{{#NR_DFTTEST}}", "{{/NR_DFTTEST}}", script);
                    script = remove_block("{{#NR_FFT3D}}", "{{/NR_FFT3D}}", script);
                    script = remove_block("{{#NR_TTEMPSMOOTH}}", "{{/NR_TTEMPSMOOTH}}", script);

                    script = process_optional_string("NR_SETTINGS", Some(&nr.mc_temporal_profile), script);
                    script = process_optional_double("NR_SIGMA", Some(nr.mc_temporal_sigma), script);
                    script = process_optional_int("NR_RADIUS", Some(nr.mc_temporal_radius), script);
                }
                NoiseReductionMethod::McDegrainSharp => {
                    script = remove_block("{{#NR_SMDEGRAIN}}", "{{/NR_SMDEGRAIN}}", script);
                    script = remove_block("{{#NR_MCTD}}", "{{/NR_MCTD}}", script);
                    script = script.replace("{{#NR_MCDEGRAINSHARP}}", "");
                    script = script.replace("{{/NR_MCDEGRAINSHARP}}", "");
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);
                    script = remove_block("{{#NR_DFTTEST}}", "{{/NR_DFTTEST}}", script);
                    script = remove_block("{{#NR_FFT3D}}", "{{/NR_FFT3D}}", script);
                    script = remove_block("{{#NR_TTEMPSMOOTH}}", "{{/NR_TTEMPSMOOTH}}", script);

                    // The blur/sharpen references must cover the same planes the
                    // degrain does, so both derive from one selector.
                    script = script.replace("{{NR_MCDS_PLANES}}", &nr.mcds_planes_literal());
                    script = script.replace("{{NR_MCDS_PLANE}}", &nr.mcds_plane.to_string());
                    script = script.replace(
                        "{{NR_MCDS_BLUR_SIGMA}}",
                        &format_double(nr.mcds_blur_sigma()),
                    );
                    script = script.replace(
                        "{{NR_MCDS_SHARP_SIGMA}}",
                        &format_double(nr.mcds_sharp_sigma()),
                    );
                    script = script.replace("{{NR_MCDS_TH_SAD}}", &nr.mcds_th_sad.to_string());
                    script = script.replace(
                        "{{NR_MCDS_SEARCH_CLIP}}",
                        if nr.mcds_blur_search { "_mcds_blurred" } else { "clip" },
                    );

                    // mvtools has a separate function per frame count.
                    for n in 1..=3 {
                        let block = format!("NR_MCDS_DEGRAIN{}", n);
                        let open = format!("{{{{#{}}}}}", block);
                        let close = format!("{{{{/{}}}}}", block);
                        if n == nr.mcds_effective_frames() {
                            script = script.replace(&open, "");
                            script = script.replace(&close, "");
                        } else {
                            script = remove_block(&open, &close, script);
                        }
                    }
                }
                NoiseReductionMethod::DfTtest => {
                    script = remove_block("{{#NR_SMDEGRAIN}}", "{{/NR_SMDEGRAIN}}", script);
                    script = remove_block("{{#NR_MCTD}}", "{{/NR_MCTD}}", script);
                    script = remove_block("{{#NR_MCDEGRAINSHARP}}", "{{/NR_MCDEGRAINSHARP}}", script);
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);
                    script = remove_block("{{#NR_FFT3D}}", "{{/NR_FFT3D}}", script);
                    script = remove_block("{{#NR_TTEMPSMOOTH}}", "{{/NR_TTEMPSMOOTH}}", script);
                    script = script.replace("{{#NR_DFTTEST}}", "");
                    script = script.replace("{{/NR_DFTTEST}}", "");

                    script = script.replace(
                        "{{NR_DFTTEST_SIGMA}}",
                        &format_double(nr.dfttest_sigma),
                    );
                    // Forced odd, so the temporal window stays centred on the
                    // current frame.
                    script = script.replace(
                        "{{NR_DFTTEST_TBSIZE}}",
                        &nr.dfttest_effective_tbsize().to_string(),
                    );
                    script = script.replace(
                        "{{NR_DFTTEST_SBSIZE}}",
                        &nr.dfttest_sbsize.to_string(),
                    );
                }
                NoiseReductionMethod::Fft3dFilter => {
                    script = remove_block("{{#NR_SMDEGRAIN}}", "{{/NR_SMDEGRAIN}}", script);
                    script = remove_block("{{#NR_MCTD}}", "{{/NR_MCTD}}", script);
                    script = remove_block("{{#NR_MCDEGRAINSHARP}}", "{{/NR_MCDEGRAINSHARP}}", script);
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);
                    script = remove_block("{{#NR_DFTTEST}}", "{{/NR_DFTTEST}}", script);
                    script = remove_block("{{#NR_TTEMPSMOOTH}}", "{{/NR_TTEMPSMOOTH}}", script);
                    script = script.replace("{{#NR_FFT3D}}", "");
                    script = script.replace("{{/NR_FFT3D}}", "");

                    script = script.replace(
                        "{{NR_FFT3D_SIGMA}}",
                        &format_double(nr.fft3d_sigma),
                    );
                    script = script.replace(
                        "{{NR_FFT3D_BT}}",
                        &nr.fft3d_effective_bt().to_string(),
                    );
                    // Omitted at 0 so the plugin's own default applies rather
                    // than an explicit no-op argument.
                    script = process_optional_double(
                        "NR_FFT3D_SHARPEN",
                        if nr.fft3d_sharpen > 0.0 { Some(nr.fft3d_sharpen) } else { None },
                        script,
                    );
                }
                NoiseReductionMethod::TTempSmooth => {
                    script = remove_block("{{#NR_SMDEGRAIN}}", "{{/NR_SMDEGRAIN}}", script);
                    script = remove_block("{{#NR_MCTD}}", "{{/NR_MCTD}}", script);
                    script = remove_block("{{#NR_MCDEGRAINSHARP}}", "{{/NR_MCDEGRAINSHARP}}", script);
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);
                    script = remove_block("{{#NR_DFTTEST}}", "{{/NR_DFTTEST}}", script);
                    script = remove_block("{{#NR_FFT3D}}", "{{/NR_FFT3D}}", script);
                    script = script.replace("{{#NR_TTEMPSMOOTH}}", "");
                    script = script.replace("{{/NR_TTEMPSMOOTH}}", "");

                    script = script.replace(
                        "{{NR_TTEMP_MAXR}}",
                        &nr.ttemp_effective_maxr().to_string(),
                    );
                    script = script.replace(
                        "{{NR_TTEMP_THRESH}}",
                        &nr.ttemp_effective_thresh().to_string(),
                    );
                    // Held below thresh: equal or greater is accepted by the
                    // plugin but silently disables its motion protection.
                    script = script.replace(
                        "{{NR_TTEMP_MDIFF}}",
                        &nr.ttemp_effective_mdiff().to_string(),
                    );
                    script = script.replace(
                        "{{NR_TTEMP_STRENGTH}}",
                        &nr.ttemp_strength.to_string(),
                    );
                }
                NoiseReductionMethod::QtgmcBuiltin => {
                    // QTGMC built-in denoising is handled in the QTGMC pass itself
                    script = remove_block("{{#NR_SMDEGRAIN}}", "{{/NR_SMDEGRAIN}}", script);
                    script = remove_block("{{#NR_MCTD}}", "{{/NR_MCTD}}", script);
                    script = remove_block("{{#NR_MCDEGRAINSHARP}}", "{{/NR_MCDEGRAINSHARP}}", script);
                    script = remove_block("{{#NR_BM3D}}", "{{/NR_BM3D}}", script);
                    script = remove_block("{{#NR_DFTTEST}}", "{{/NR_DFTTEST}}", script);
                    script = remove_block("{{#NR_FFT3D}}", "{{/NR_FFT3D}}", script);
                    script = remove_block("{{#NR_TTEMPSMOOTH}}", "{{/NR_TTEMPSMOOTH}}", script);
                }
            }
        } else {
            script = remove_block("{{#NOISE_REDUCTION}}", "{{/NOISE_REDUCTION}}", script);
        }

        // ====================================================================
        // CHROMA DENOISE PASS (CCD)
        // ====================================================================
        let chroma_denoise = &pipeline.chroma_denoise;
        if chroma_denoise.enabled {
            script = script.replace("{{#CHROMA_DENOISE}}", "");
            script = script.replace("{{/CHROMA_DENOISE}}", "");
            script = script.replace("{{CCD_THRESHOLD}}", &format_double(chroma_denoise.threshold));
            script = script.replace(
                "{{CCD_TEMPORAL_RADIUS}}",
                &chroma_denoise.temporal_radius.to_string(),
            );
            script = script.replace("{{CCD_POINTS}}", &chroma_denoise.points_literal());

            // An explicit scale wins; otherwise derive it from the frame height
            // at runtime, which is the only place the height is known.
            if let Some(scale) = chroma_denoise.scale {
                script = remove_block("{{#CCD_SCALE_AUTO}}", "{{/CCD_SCALE_AUTO}}", script);
                script = script.replace("{{#CCD_SCALE_EXPLICIT}}", "");
                script = script.replace("{{/CCD_SCALE_EXPLICIT}}", "");
                script = script.replace("{{CCD_SCALE}}", &format_double(scale));
            } else {
                script = script.replace("{{#CCD_SCALE_AUTO}}", "");
                script = script.replace("{{/CCD_SCALE_AUTO}}", "");
                script = remove_block("{{#CCD_SCALE_EXPLICIT}}", "{{/CCD_SCALE_EXPLICIT}}", script);
                script = script.replace(
                    "{{CCD_REFERENCE_HEIGHT}}",
                    &CCD_REFERENCE_HEIGHT.to_string(),
                );
            }
        } else {
            script = remove_block("{{#CHROMA_DENOISE}}", "{{/CHROMA_DENOISE}}", script);
        }

        // ====================================================================
        // DEHALO PASS
        // ====================================================================
        let dehalo = &pipeline.dehalo;
        if dehalo.enabled {
            script = script.replace("{{#DEHALO}}", "");
            script = script.replace("{{/DEHALO}}", "");

            // Exactly one method block survives; the rest are removed. Listing
            // every block per arm is what the other passes do, but with seven
            // methods it stops being readable — so keep the block the method
            // selects and drop the others by difference.
            const DEHALO_BLOCKS: [&str; 7] = [
                "DEHALO_DEHALO_ALPHA",
                "DEHALO_FINE_DEHALO",
                "DEHALO_FINE_DEHALO2",
                "DEHALO_YAHR",
                "DEHALO_EDGE_CLEANER",
                "DEHALO_VINVERSE",
                "DEHALO_HQDERING",
            ];

            let selected = match dehalo.method {
                DehaloMethod::DehaloAlpha => "DEHALO_DEHALO_ALPHA",
                DehaloMethod::FineDehalo => "DEHALO_FINE_DEHALO",
                DehaloMethod::FineDehalo2 => "DEHALO_FINE_DEHALO2",
                DehaloMethod::Yahr => "DEHALO_YAHR",
                DehaloMethod::EdgeCleaner => "DEHALO_EDGE_CLEANER",
                // Both Vinverse variants share one block; only the function
                // name differs.
                DehaloMethod::Vinverse | DehaloMethod::Vinverse2 => "DEHALO_VINVERSE",
                DehaloMethod::HqDeringmod => "DEHALO_HQDERING",
            };

            for block in DEHALO_BLOCKS {
                let open = format!("{{{{#{}}}}}", block);
                let close = format!("{{{{/{}}}}}", block);
                if block == selected {
                    script = script.replace(&open, "");
                    script = script.replace(&close, "");
                } else {
                    script = remove_block(&open, &close, script);
                }
            }

            match dehalo.method {
                DehaloMethod::DehaloAlpha => {
                    script = process_optional_int("DEHALO_LOWSENS", dehalo.low_sens, script);
                    script = process_optional_int("DEHALO_HIGHSENS", dehalo.high_sens, script);
                    script = process_optional_double("DEHALO_SS", dehalo.super_sample, script);
                }
                DehaloMethod::FineDehalo => {
                    script = process_optional_int("DEHALO_LOW_THRESHOLD", Some(dehalo.low_threshold), script);
                    script = process_optional_int("DEHALO_HIGH_THRESHOLD", Some(dehalo.high_threshold), script);
                    script = process_optional_int("DEHALO_THLIMI", dehalo.limit_low, script);
                    script = process_optional_int("DEHALO_THLIMA", dehalo.limit_high, script);
                    script = process_optional_double("DEHALO_CONTRA", dehalo.contra, script);
                    script = process_optional_bool("DEHALO_EXCL", dehalo.exclude_close_edges, script);
                    script = process_optional_double("DEHALO_EDGEPROC", dehalo.edge_proc, script);
                }
                DehaloMethod::FineDehalo2 => {}
                DehaloMethod::Yahr => {
                    script = process_optional_int("DEHALO_YAHR_BLUR", Some(dehalo.yahr_blur), script);
                    script = process_optional_int("DEHALO_YAHR_DEPTH", Some(dehalo.yahr_depth), script);
                }
                DehaloMethod::EdgeCleaner => {
                    script = process_optional_int("DEHALO_EDGE_STRENGTH", dehalo.edge_strength, script);
                    script = process_optional_bool("DEHALO_EDGE_REPAIR", dehalo.edge_repair, script);
                    script = process_optional_int("DEHALO_EDGE_RMODE", dehalo.edge_repair_mode, script);
                    script = process_optional_int("DEHALO_EDGE_SMODE", dehalo.edge_small_mode, script);
                    script = process_optional_bool("DEHALO_EDGE_HOT", dehalo.edge_hot_pixels, script);
                }
                DehaloMethod::Vinverse | DehaloMethod::Vinverse2 => {
                    script = script.replace("{{DEHALO_VINVERSE_FN}}", dehalo.method.as_str());
                    script = process_optional_double("DEHALO_VINVERSE_SSTR", dehalo.vinverse_strength, script);
                    script = process_optional_int("DEHALO_VINVERSE_AMNT", dehalo.vinverse_amount, script);
                    script = process_optional_bool("DEHALO_VINVERSE_CHROMA", dehalo.vinverse_chroma, script);
                }
                DehaloMethod::HqDeringmod => {
                    script = process_optional_int("DEHALO_DERING_MRAD", dehalo.dering_mrad, script);
                    script = process_optional_int("DEHALO_DERING_MSMOOTH", dehalo.dering_msmooth, script);
                    script = process_optional_int("DEHALO_DERING_MTHR", dehalo.dering_mthr, script);
                    script = process_optional_double("DEHALO_DERING_THR", dehalo.dering_thr, script);
                    script = process_optional_double("DEHALO_DERING_DARKTHR", dehalo.dering_darkthr, script);
                }
            }

            // Radius and strength are shared by DeHalo_alpha and FineDehalo only.
            if dehalo.method.uses_halo_radius() {
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
                    script = remove_block("{{#SHARPEN_AWARPSHARP2}}", "{{/SHARPEN_AWARPSHARP2}}", script);

                    script = process_optional_int("SHARPEN_STRENGTH", Some(sharpen.strength), script);
                    script = process_optional_int("SHARPEN_OVERSHOOT", Some(sharpen.overshoot), script);
                    script = process_optional_int("SHARPEN_UNDERSHOOT", Some(sharpen.undershoot), script);
                    script = process_optional_int("SHARPEN_SOFT_EDGE", Some(sharpen.soft_edge), script);
                }
                SharpenMethod::CAS => {
                    script = remove_block("{{#SHARPEN_LSFMOD}}", "{{/SHARPEN_LSFMOD}}", script);
                    script = script.replace("{{#SHARPEN_CAS}}", "");
                    script = script.replace("{{/SHARPEN_CAS}}", "");
                    script = remove_block("{{#SHARPEN_AWARPSHARP2}}", "{{/SHARPEN_AWARPSHARP2}}", script);

                    script = process_optional_double("SHARPEN_CAS_SHARPNESS", Some(sharpen.cas_sharpness), script);
                }
                SharpenMethod::AWarpSharp2 => {
                    script = remove_block("{{#SHARPEN_LSFMOD}}", "{{/SHARPEN_LSFMOD}}", script);
                    script = remove_block("{{#SHARPEN_CAS}}", "{{/SHARPEN_CAS}}", script);
                    script = script.replace("{{#SHARPEN_AWARPSHARP2}}", "");
                    script = script.replace("{{/SHARPEN_AWARPSHARP2}}", "");

                    script = script.replace("{{SHARPEN_WARP_THRESH}}", &sharpen.warp_thresh.to_string());
                    script = script.replace(
                        "{{SHARPEN_WARP_BLUR}}",
                        &sharpen.warp_effective_blur().to_string(),
                    );
                    script = script.replace("{{SHARPEN_WARP_TYPE}}", &sharpen.warp_type.to_string());
                    script = script.replace("{{SHARPEN_WARP_DEPTH}}", &sharpen.warp_depth.to_string());
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

            // Chroma Shift (Y/C Delay)
            if chroma.apply_chroma_shift && (chroma.chroma_shift_h != 0.0 || chroma.chroma_shift_v != 0.0) {
                script = script.replace("{{#CHROMA_SHIFT}}", "");
                script = script.replace("{{/CHROMA_SHIFT}}", "");
                script = process_optional_double("CHROMA_SHIFT_H", Some(chroma.chroma_shift_h), script);
                script = process_optional_double("CHROMA_SHIFT_V", Some(chroma.chroma_shift_v), script);
            } else {
                script = remove_block("{{#CHROMA_SHIFT}}", "{{/CHROMA_SHIFT}}", script);
            }

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

            // White balance (temperature / tint)
            if color.has_white_balance() {
                script = script.replace("{{#COLOR_WHITE_BALANCE}}", "");
                script = script.replace("{{/COLOR_WHITE_BALANCE}}", "");
                let (u, v) = color.chroma_offsets();
                script = script.replace("{{COLOR_WB_U}}", &format_double(u));
                script = script.replace("{{COLOR_WB_V}}", &format_double(v));
            } else {
                script = remove_block("{{#COLOR_WHITE_BALANCE}}", "{{/COLOR_WHITE_BALANCE}}", script);
            }
        } else {
            script = remove_block("{{#COLOR_CORRECTION}}", "{{/COLOR_CORRECTION}}", script);
        }

        // ====================================================================
        // RESIZE PASS
        // ====================================================================
        let resize = &pipeline.crop_resize;
        // Squaring the pixels resamples the grid, so it needs the resize pass
        // even with no target size — "make this anamorphic source square" is a
        // resize in its own right.
        let squares_pixels = resize.squares_pixels();
        if resize.enabled
            && (resize.resize_enabled || resize.use_integer_upscale || squares_pixels)
        {
            script = script.replace("{{#RESIZE}}", "");
            script = script.replace("{{/RESIZE}}", "");

            // Integer upscale
            if resize.use_integer_upscale {
                script = script.replace("{{#RESIZE_INTEGER_UPSCALE}}", "");
                script = script.replace("{{/RESIZE_INTEGER_UPSCALE}}", "");
                script = script.replace("{{UPSCALE_FACTOR}}", &resize.upscale_factor.to_string());

                // Two of the three methods are edge-directed and share the
                // doubling loop and shift correction; Spline36 is plain
                // resampling and skips all of it.
                let edge_directed = !matches!(resize.upscale_method, UpscaleMethod::Spline36);
                if edge_directed {
                    script = script.replace("{{#UPSCALE_EDGE_DIRECTED}}", "");
                    script = script.replace("{{/UPSCALE_EDGE_DIRECTED}}", "");
                    script = remove_block("{{#UPSCALE_SPLINE36}}", "{{/UPSCALE_SPLINE36}}", script);
                } else {
                    script = remove_block("{{#UPSCALE_EDGE_DIRECTED}}", "{{/UPSCALE_EDGE_DIRECTED}}", script);
                    script = script.replace("{{#UPSCALE_SPLINE36}}", "");
                    script = script.replace("{{/UPSCALE_SPLINE36}}", "");
                }

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
                        // EEDI3's own controls only exist on this path.
                        script = process_optional_double("UPSCALE_ALPHA", resize.upscale_alpha, script);
                        script = process_optional_double("UPSCALE_BETA", resize.upscale_beta, script);
                        script = process_optional_double("UPSCALE_GAMMA", resize.upscale_gamma, script);
                        script = process_optional_int("UPSCALE_NRAD", resize.upscale_nrad, script);
                        script = process_optional_int("UPSCALE_MDIS", resize.upscale_mdis, script);
                    }
                    UpscaleMethod::Spline36 => {
                        script = remove_block("{{#UPSCALE_NNEDI3}}", "{{/UPSCALE_NNEDI3}}", script);
                        script = remove_block("{{#UPSCALE_EEDI3}}", "{{/UPSCALE_EEDI3}}", script);
                    }
                }

                // The nnedi3 controls apply to both edge-directed methods: on
                // the EEDI3 path they shape the sclip that guides it.
                if edge_directed {
                    script = process_optional_int("UPSCALE_NSIZE", resize.upscale_nsize, script);
                    script = process_optional_int("UPSCALE_NNS", resize.upscale_neurons, script);
                    script = process_optional_int("UPSCALE_QUAL", resize.upscale_qual, script);
                    script = process_optional_int("UPSCALE_ETYPE", resize.upscale_etype, script);
                    script = process_optional_int("UPSCALE_PSCRN", resize.upscale_pscrn, script);
                }
            } else {
                script = remove_block("{{#RESIZE_INTEGER_UPSCALE}}", "{{/RESIZE_INTEGER_UPSCALE}}", script);
            }

            // Standard resize, which also covers a pixel-aspect squaring with no
            // target size of its own.
            if resize.resize_enabled || squares_pixels {
                script = script.replace("{{#RESIZE_STANDARD}}", "");
                script = script.replace("{{/RESIZE_STANDARD}}", "");

                // Use -1 for unspecified dimensions (maintain aspect will calculate)
                let width = if resize.resize_enabled { resize.target_width.unwrap_or(-1) } else { -1 };
                let height = if resize.resize_enabled { resize.target_height.unwrap_or(-1) } else { -1 };
                script = script.replace("{{TARGET_WIDTH}}", &width.to_string());
                script = script.replace("{{TARGET_HEIGHT}}", &height.to_string());

                // Squaring with no target size has nothing to fit, so the
                // aspect logic has to run regardless of the user's choice.
                if resize.maintain_aspect || (squares_pixels && width <= 0 && height <= 0) {
                    script = script.replace("{{#MAINTAIN_ASPECT}}", "");
                    script = script.replace("{{/MAINTAIN_ASPECT}}", "");
                } else {
                    script = remove_block("{{#MAINTAIN_ASPECT}}", "{{/MAINTAIN_ASPECT}}", script);
                }

                // Display aspect: an explicit override, else derived from the
                // source's dimensions and SAR inside the script.
                if let Some(dar) = resize.display_aspect_ratio() {
                    script = script.replace("{{#ASPECT_DAR_OVERRIDE}}", "");
                    script = script.replace("{{/ASPECT_DAR_OVERRIDE}}", "");
                    script = script.replace("{{ASPECT_DAR}}", &format_double(dar));
                    script = remove_block(
                        "{{#ASPECT_DAR_FROM_SOURCE}}",
                        "{{/ASPECT_DAR_FROM_SOURCE}}",
                        script,
                    );
                } else {
                    script = remove_block(
                        "{{#ASPECT_DAR_OVERRIDE}}",
                        "{{/ASPECT_DAR_OVERRIDE}}",
                        script,
                    );
                    script = script.replace("{{#ASPECT_DAR_FROM_SOURCE}}", "");
                    script = script.replace("{{/ASPECT_DAR_FROM_SOURCE}}", "");
                    let source_sar = job
                        .input_sar
                        .as_deref()
                        .and_then(parse_ratio)
                        .unwrap_or(1.0);
                    script = script.replace("{{SOURCE_SAR}}", &format_double(source_sar));
                }

                // Fit by display aspect when squaring the grid, by storage
                // aspect when leaving it alone.
                if squares_pixels {
                    script = script.replace("{{#ASPECT_SQUARE_PIXELS}}", "");
                    script = script.replace("{{/ASPECT_SQUARE_PIXELS}}", "");
                    script = remove_block("{{#ASPECT_KEEP_PIXELS}}", "{{/ASPECT_KEEP_PIXELS}}", script);
                } else {
                    script = remove_block("{{#ASPECT_SQUARE_PIXELS}}", "{{/ASPECT_SQUARE_PIXELS}}", script);
                    script = script.replace("{{#ASPECT_KEEP_PIXELS}}", "");
                    script = script.replace("{{/ASPECT_KEEP_PIXELS}}", "");
                }

                // Padding only means anything when there is a box to pad out to.
                if resize.pad_to_aspect && resize.resize_enabled {
                    script = script.replace("{{#ASPECT_PAD}}", "");
                    script = script.replace("{{/ASPECT_PAD}}", "");
                } else {
                    script = remove_block("{{#ASPECT_PAD}}", "{{/ASPECT_PAD}}", script);
                }

                // One call, with the kernel substituted in — the alternative is
                // one template block per kernel, which does not scale past a
                // handful.
                script = script.replace("{{RESIZE_KERNEL}}", resize.kernel.resize_function());

                // filter_param_a/b mean different things per kernel, so only
                // emit them for the kernel that reads them. Passing Bicubic's b
                // to Lanczos would silently change the tap count.
                let (filter_a, filter_b) = if resize.kernel.takes_bicubic_params() {
                    (resize.bicubic_b, resize.bicubic_c)
                } else if resize.kernel.takes_taps() {
                    (resize.lanczos_taps.map(f64::from), None)
                } else {
                    (None, None)
                };
                script = process_optional_double("RESIZE_FILTER_A", filter_a, script);
                script = process_optional_double("RESIZE_FILTER_B", filter_b, script);
            } else {
                script = remove_block("{{#RESIZE_STANDARD}}", "{{/RESIZE_STANDARD}}", script);
            }
        } else {
            script = remove_block("{{#RESIZE}}", "{{/RESIZE}}", script);
        }

        // ====================================================================
        // OUTPUT CHROMA SUBSAMPLING CONVERSION
        // ====================================================================
        // The target format is the enum's own business (ChromaSubsampling::
        // vapoursynth_format), so adding an output format is one line there
        // rather than another arm here. `None` means "keep the source format",
        // bit depth included.
        match job.encoding_settings.chroma_subsampling.vapoursynth_format() {
            None => {
                script = remove_block("{{#CHROMA_CONVERT}}", "{{/CHROMA_CONVERT}}", script);
            }
            Some(format) => {
                script = script.replace("{{#CHROMA_CONVERT}}", "");
                script = script.replace("{{/CHROMA_CONVERT}}", "");
                script = script.replace("{{CHROMA_FORMAT}}", format);
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
/// Render a float for the script: minimal precision, but always with a decimal
/// point so it stays a Python float.
fn format_double(val: f64) -> String {
    if val.fract() == 0.0 {
        format!("{:.1}", val)
    } else {
        format!("{:.4}", val).trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

fn process_optional_double(name: &str, value: Option<f64>, mut script: String) -> String {
    let start_tag = format!("{{{{#{}}}}}", name);
    let end_tag = format!("{{{{/{}}}}}", name);
    let placeholder = format!("{{{{{}}}}}", name);

    if let Some(val) = value {
        script = script.replace(&start_tag, "");
        script = script.replace(&end_tag, "");
        script = script.replace(&placeholder, &format_double(val));
    } else {
        script = remove_block(&start_tag, &end_tag, script);
    }
    script
}

/// Process an optional boolean parameter.
/// Resolve the final OpenCL setting.
///
/// `desired` is what we'd otherwise use (macOS auto-enable or the user's choice).
/// When `user_forced` is true the user explicitly opted in, so we honor `desired`
/// as-is (their choice overrides the probe — it errors if no device, by design).
/// Otherwise, if OpenCL would be on (`Some(true)`) but no usable device is
/// detected, we downgrade to `Some(false)` (CPU NNEDI3). All other cases pass
/// through unchanged.
fn gate_opencl(desired: Option<bool>, opencl_available: bool, user_forced: bool) -> Option<bool> {
    if user_forced {
        return desired;
    }
    match desired {
        Some(true) if !opencl_available => Some(false),
        other => other,
    }
}

/// Resolve the final QTGMC denoiser, downgrading the OpenCL-only `knlmeanscl`
/// to `dfttest` when KNLMeansCL can't run here. Every other value (including
/// `None` ⇒ QTGMC's own default, and the empty string) passes through unchanged.
/// Returned as an owned `Option<String>` because the fallback replaces the
/// borrowed input with a new literal.
fn gate_knlm_denoiser(desired: Option<&str>, knlm_available: bool) -> Option<String> {
    match desired {
        Some("knlmeanscl") if !knlm_available => Some("dfttest".to_string()),
        other => other.map(|s| s.to_string()),
    }
}

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

    #[test]
    fn test_gate_opencl_disables_auto_when_unavailable() {
        // Auto-enabled OpenCL with no device → CPU fallback.
        assert_eq!(gate_opencl(Some(true), false, false), Some(false));
    }

    #[test]
    fn test_gate_opencl_user_forced_overrides_probe() {
        // User explicitly enabled OpenCL → honored even if the probe found nothing.
        assert_eq!(gate_opencl(Some(true), false, true), Some(true));
        assert_eq!(gate_opencl(Some(true), true, true), Some(true));
    }

    #[test]
    fn test_gate_opencl_passthrough() {
        assert_eq!(gate_opencl(Some(true), true, false), Some(true));
        assert_eq!(gate_opencl(Some(false), false, false), Some(false));
        assert_eq!(gate_opencl(None, false, false), None);
        assert_eq!(gate_opencl(None, true, false), None);
    }

    #[test]
    fn test_gate_knlm_denoiser_falls_back_when_unavailable() {
        // knlmeanscl selected but unusable → dfttest.
        assert_eq!(
            gate_knlm_denoiser(Some("knlmeanscl"), false),
            Some("dfttest".to_string())
        );
    }

    #[test]
    fn test_gate_knlm_denoiser_passthrough() {
        // knlmeanscl kept when usable.
        assert_eq!(
            gate_knlm_denoiser(Some("knlmeanscl"), true),
            Some("knlmeanscl".to_string())
        );
        // Other denoisers untouched regardless of knlm availability.
        assert_eq!(
            gate_knlm_denoiser(Some("dfttest"), false),
            Some("dfttest".to_string())
        );
        assert_eq!(
            gate_knlm_denoiser(Some("fft3dfilter"), false),
            Some("fft3dfilter".to_string())
        );
        // Unset → QTGMC's own default (no override).
        assert_eq!(gate_knlm_denoiser(None, false), None);
    }
}
