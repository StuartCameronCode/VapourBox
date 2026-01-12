//! VapourSynth script generator.
//!
//! Generates .vpy scripts from templates by substituting QTGMC parameters.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::models::VideoJob;

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
        let script = self.substitute_parameters(job);

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
            // Next to executable
            exe_dir.join("templates").join("qtgmc_template.vpy"),
            exe_dir.join("Templates").join("qtgmc_template.vpy"),
            // In parent (for development: worker/target/release -> worker/templates)
            exe_dir.join("..").join("..").join("templates").join("qtgmc_template.vpy"),
            exe_dir.join("..").join("..").join("..").join("templates").join("qtgmc_template.vpy"),
            // Relative to current dir
            PathBuf::from("templates").join("qtgmc_template.vpy"),
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
    fn substitute_parameters(&self, job: &VideoJob) -> String {
        let mut script = self.template.clone();
        let params = &job.qtgmc_parameters;

        // Input path (escape backslashes for Python)
        let escaped_input = job.input_path.replace('\\', "\\\\");
        script = script.replace("{{INPUT_PATH}}", &escaped_input);

        // Preset (required)
        script = script.replace("{{PRESET}}", params.preset.as_str());

        // Process optional parameters using mustache-like syntax
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

        // GPU - always include opencl parameter to ensure havsfunc uses correct code path
        script = process_optional_bool("OPENCL", Some(params.opencl), script);
        script = process_optional_int("DEVICE", params.device, script);

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
