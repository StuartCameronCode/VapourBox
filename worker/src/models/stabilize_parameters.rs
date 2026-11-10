//! Image stabilisation parameters: gate weave / shake, and vertical pitch
//! ("frame height breathing", issue #150).
//!
//! Two independent corrections, applied in this order:
//!
//! 1. **Weave** — havsfunc's `Stab` measures global motion with MVTools'
//!    Depan family and cancels it, so a shaky capture holds still while
//!    intended camera movement survives. Aimed at telecine weave, jittery film
//!    scans and handheld camcorder footage. On by default when the pass is on.
//! 2. **Pitch** — pull-through film scanners let the film slip in the gate, so
//!    the picture is stretched or squashed vertically by a fraction of a
//!    percent from frame to frame, which a translation stabiliser cannot
//!    remove. Each frame is resampled vertically about its centre by a factor
//!    measured from the video (`auto`) or read from a per-video file (`file`).
//!    Off by default, so a pipeline saved before pitch correction existed
//!    produces exactly the script it always did.
//!
//! The pitch logic lives in `templates/stabilize.py`; see its module docstring
//! for the algorithms and the factor convention.
//!
//! The pass does not change the frame count, which is why it is an ordinary
//! pass and not one of the frame-rate-changing filters that would touch
//! `FrameMap`. It does read neighbouring frames, which [`StabilizeParameters::radius`]
//! declares so a windowed preview decodes enough context.
//!
//! No bit-depth limit — `Stab` verified against the bundle at 8/10/12/16-bit and
//! 4:2:2; the pitch resample is plain zimg.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};

/// How the per-frame vertical pitch factor is obtained.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum PitchMode {
    /// No pitch correction (the default: weave only, as before issue #150).
    #[default]
    Off,
    /// Measured from the video itself (relative to the surrounding frames).
    Auto,
    /// Read from a per-video factor file (`VideoJob::pitch_factors_path`).
    File,
}

impl PitchMode {
    /// The value the template passes to `stabilize.correct_pitch(mode=…)`.
    pub fn script_value(&self) -> &'static str {
        match self {
            PitchMode::Off => "off",
            PitchMode::Auto => "auto",
            PitchMode::File => "file",
        }
    }
}

/// What fills the rows a pitch correction moves in from outside the frame.
/// (The weave correction's edges are `mirror`'s business.)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum EdgeFill {
    /// Repeat the nearest picture rows (invisible on most footage).
    #[default]
    Extend,
    /// Black, computed from the clip's format (so it is black at any depth).
    Black,
}

/// Parameters for the stabilisation pass.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StabilizeParameters {
    /// Whether this pass is enabled.
    #[serde(default)]
    pub enabled: bool,

    /// Remove weave / shake with havsfunc `Stab`. Defaults on, so a pipeline
    /// saved before this switch existed keeps doing what it did.
    #[serde(default = "default_weave")]
    pub weave: bool,

    /// Maximum horizontal correction in pixels.
    #[serde(default = "default_dxmax")]
    pub dxmax: i32,

    /// Maximum vertical correction in pixels.
    #[serde(default = "default_dymax")]
    pub dymax: i32,

    /// How to fill the edges the shift exposes: 0 none (left black), 1 top and
    /// bottom, 2 left and right, 3 all four. Mirroring saves the user having to
    /// crop afterwards.
    #[serde(default)]
    pub mirror: i32,

    /// Vertical pitch correction source.
    #[serde(default)]
    pub pitch_mode: PitchMode,

    /// Largest pitch correction, in percent of the frame height. Also clamps
    /// factors read from a file, so one bad value can't distort a frame.
    #[serde(default = "default_max_pitch_deviation")]
    pub max_pitch_deviation: f64,

    /// Auto pitch: frames each side a frame is compared with. Larger follows
    /// slow intentional zooms less closely but averages out more jitter.
    #[serde(default = "default_smoothing_radius")]
    pub smoothing_radius: i32,

    /// File pitch: the file holds the stretch to *apply* rather than the
    /// measured height ratio.
    #[serde(default)]
    pub invert_factors: bool,

    /// What fills rows exposed by the pitch correction.
    #[serde(default)]
    pub pitch_edge_fill: EdgeFill,
}

fn default_weave() -> bool { true }
fn default_dxmax() -> i32 { 4 }
fn default_dymax() -> i32 { 4 }
fn default_max_pitch_deviation() -> f64 { 1.0 }
fn default_smoothing_radius() -> i32 { 10 }

impl Default for StabilizeParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            weave: default_weave(),
            dxmax: default_dxmax(),
            dymax: default_dymax(),
            mirror: 0,
            pitch_mode: PitchMode::default(),
            max_pitch_deviation: default_max_pitch_deviation(),
            smoothing_radius: default_smoothing_radius(),
            invert_factors: false,
            pitch_edge_fill: EdgeFill::default(),
        }
    }
}

/// Frames each side `Stab` reads. Its average is ±7, but the scene-change
/// detection inside it looks one frame further out and DepanEstimate reads the
/// next interleaved pair, so the reach measured under vspipe is n-8..n+9
/// (issue #150 review). Too small a value here makes a windowed preview — and
/// `pipe_source`'s cache — silently hand back the wrong frame.
const WEAVE_RADIUS: u32 = 9;

impl StabilizeParameters {
    /// Edge-fill mode, clamped to the 0-3 DePanStabilise implements.
    pub fn effective_mirror(&self) -> i32 {
        self.mirror.clamp(0, 3)
    }

    /// Maximum horizontal correction, clamped non-negative. A negative value is
    /// accepted by DepanStabilise and disables correction on that axis, which
    /// looks like the filter doing nothing.
    pub fn effective_dxmax(&self) -> i32 {
        self.dxmax.max(0)
    }

    /// See [`Self::effective_dxmax`].
    pub fn effective_dymax(&self) -> i32 {
        self.dymax.max(0)
    }

    /// Whether the weave correction runs.
    pub fn weave_active(&self) -> bool {
        self.enabled && self.weave
    }

    /// Whether the pitch correction runs.
    pub fn pitch_active(&self) -> bool {
        self.enabled && self.pitch_mode != PitchMode::Off
    }

    /// Whether the pass does anything at all.
    pub fn is_active(&self) -> bool {
        self.weave_active() || self.pitch_active()
    }

    /// Auto pitch smoothing radius as the script uses it (1-50).
    pub fn effective_smoothing_radius(&self) -> u32 {
        self.smoothing_radius.clamp(1, 50) as u32
    }

    /// Maximum pitch deviation in percent, clamped to something sane.
    pub fn effective_max_deviation(&self) -> f64 {
        if self.max_pitch_deviation.is_finite() {
            self.max_pitch_deviation.clamp(0.05, 5.0)
        } else {
            default_max_pitch_deviation()
        }
    }

    /// Temporal neighbours (each side) the pass reads for one output frame.
    pub fn radius(&self) -> u32 {
        let weave = if self.weave_active() { WEAVE_RADIUS } else { 0 };
        let pitch = if self.pitch_active() && self.pitch_mode == PitchMode::Auto {
            // Pairs n-R..n+R-1, each reading one frame ahead.
            self.effective_smoothing_radius() + 1
        } else {
            0
        };
        weave + pitch
    }
}

/// Parse a pitch factor file into one factor per source frame.
///
/// Accepted, per line:
/// - blank lines and `#` comments (also trailing `# …`)
/// - a bare factor: `1.0012` — the line order is the frame order
/// - `frame,factor`, `frame factor` or `frame<TAB>factor` — explicit frame
///   numbers; frames not mentioned get 1.0 (no correction)
///
/// Every factor must be a finite number > 0; anything else is an error naming
/// the line, because a silently skipped line shifts every later frame.
pub fn parse_pitch_factors(text: &str) -> Result<Vec<f64>> {
    let mut sequential: Vec<f64> = Vec::new();
    let mut indexed: Vec<(usize, f64)> = Vec::new();

    for (i, raw) in text.lines().enumerate() {
        let line_no = i + 1;
        let line = raw.split('#').next().unwrap_or("").trim().trim_start_matches('\u{feff}');
        if line.is_empty() {
            continue;
        }
        let fields: Vec<&str> = line
            .split(|c: char| c == ',' || c == ';' || c.is_whitespace())
            .filter(|s| !s.is_empty())
            .collect();

        let parse_factor = |s: &str| -> Result<f64> {
            match s.parse::<f64>() {
                Ok(v) if v.is_finite() && v > 0.0 => Ok(v),
                _ => bail!("Pitch factor file, line {}: '{}' is not a positive number", line_no, s),
            }
        };

        match fields.as_slice() {
            [factor] => sequential.push(parse_factor(factor)?),
            [frame, factor] => {
                let frame: usize = frame.parse().map_err(|_| {
                    anyhow::anyhow!("Pitch factor file, line {}: '{}' is not a frame number", line_no, frame)
                })?;
                indexed.push((frame, parse_factor(factor)?));
            }
            _ => bail!(
                "Pitch factor file, line {}: expected a factor or 'frame,factor', found '{}'",
                line_no, line
            ),
        }
    }

    match (sequential.is_empty(), indexed.is_empty()) {
        (true, true) => bail!("Pitch factor file contains no factors"),
        (false, false) => bail!(
            "Pitch factor file mixes bare factors and 'frame,factor' lines; use one form throughout"
        ),
        (false, true) => Ok(sequential),
        (true, false) => {
            let len = indexed.iter().map(|(f, _)| f + 1).max().unwrap_or(0);
            if len > 10_000_000 {
                bail!("Pitch factor file: frame number {} is implausibly large", len - 1);
            }
            let mut out = vec![1.0; len];
            for (frame, factor) in indexed {
                out[frame] = factor;
            }
            Ok(out)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults() {
        let p = StabilizeParameters::default();
        assert!(!p.enabled);
        assert!(p.weave);
        assert_eq!(p.dxmax, 4);
        assert_eq!(p.dymax, 4);
        assert_eq!(p.mirror, 0);
        assert_eq!(p.pitch_mode, PitchMode::Off);
        assert_eq!(p.pitch_edge_fill, EdgeFill::Extend);
        assert_eq!(p.radius(), 0, "disabled pass reads no neighbours");
    }

    #[test]
    fn test_parameters_match_the_bundled_havsfunc_signature() {
        // Stab(clp, dxmax=4, dymax=4, mirror=0). There is no `range` argument —
        // an earlier version of this model invented one, and havsfunc rejected
        // it with a TypeError that only the end-to-end test caught. Introspect
        // the signature; do not assume it from another implementation.
        let json = serde_json::to_string(&StabilizeParameters::default()).unwrap();
        assert!(json.contains("\"dxmax\":4"));
        assert!(json.contains("\"dymax\":4"));
        assert!(json.contains("\"mirror\":0"));
        assert!(!json.contains("range"));
    }

    #[test]
    fn test_mirror_is_clamped() {
        let with = |m: i32| StabilizeParameters { mirror: m, ..Default::default() };
        assert_eq!(with(-1).effective_mirror(), 0);
        assert_eq!(with(3).effective_mirror(), 3);
        assert_eq!(with(9).effective_mirror(), 3);
    }

    #[test]
    fn test_negative_limits_would_silently_disable_an_axis() {
        let with = |d: i32| StabilizeParameters {
            dxmax: d,
            dymax: d,
            ..Default::default()
        };
        assert_eq!(with(-1).effective_dxmax(), 0);
        assert_eq!(with(-1).effective_dymax(), 0);
        assert_eq!(with(6).effective_dxmax(), 6);
    }

    #[test]
    fn test_serialization() {
        let json = serde_json::to_string(&StabilizeParameters::default()).unwrap();
        assert!(json.contains("\"enabled\":false"));
        assert!(json.contains("\"dxmax\":4"));
    }

    #[test]
    fn test_radius_follows_the_enabled_parts() {
        let mut p = StabilizeParameters { enabled: true, ..Default::default() };
        // Weave only (the default): Stab's measured reach.
        assert_eq!(p.radius(), 9);
        p.pitch_mode = PitchMode::Auto;
        assert_eq!(p.radius(), 9 + 11);
        p.pitch_mode = PitchMode::File;
        assert_eq!(p.radius(), 9);
        p.weave = false;
        assert_eq!(p.radius(), 0);
        assert!(p.is_active());
        p.pitch_mode = PitchMode::Off;
        assert!(!p.is_active());
    }

    #[test]
    fn test_pitch_serde_names_are_the_wire_format() {
        let p = StabilizeParameters {
            enabled: true,
            pitch_mode: PitchMode::File,
            pitch_edge_fill: EdgeFill::Black,
            ..Default::default()
        };
        let json = serde_json::to_string(&p).unwrap();
        for key in ["\"pitchMode\":\"file\"", "\"pitchEdgeFill\":\"black\"", "\"weave\":true",
                    "\"maxPitchDeviation\"", "\"smoothingRadius\"", "\"invertFactors\""] {
            assert!(json.contains(key), "{} missing from {}", key, json);
        }
    }

    #[test]
    fn test_old_pipelines_keep_weave_only() {
        // A pipeline saved before pitch correction existed: weave on, pitch off.
        let parsed: StabilizeParameters =
            serde_json::from_str("{\"enabled\":true,\"dxmax\":6,\"dymax\":2,\"mirror\":3}").unwrap();
        assert!(parsed.weave);
        assert_eq!(parsed.pitch_mode, PitchMode::Off);
        assert_eq!((parsed.dxmax, parsed.dymax, parsed.mirror), (6, 2, 3));
        assert_eq!(parsed.smoothing_radius, 10);
    }

    #[test]
    fn test_parses_bare_factors_with_comments_and_blank_lines() {
        let text = "# pitch log\n1.0012\n\n0.9990  # gate slip\r\n1\n";
        assert_eq!(parse_pitch_factors(text).unwrap(), vec![1.0012, 0.9990, 1.0]);
    }

    #[test]
    fn test_parses_indexed_factors_and_fills_gaps() {
        let text = "0,1.001\n2 0.998\n3\t1.002\n";
        assert_eq!(parse_pitch_factors(text).unwrap(), vec![1.001, 1.0, 0.998, 1.002]);
    }

    #[test]
    fn test_rejects_bad_values_with_the_line_number() {
        for (text, line) in [("1.0\nabc\n", "line 2"), ("1.0\n1.0\nnan\n", "line 3"),
                             ("-1.0\n", "line 1"), ("0\n", "line 1"), ("1 2 3\n", "line 1"),
                             ("x,1.0\n", "line 1")] {
            let err = parse_pitch_factors(text).unwrap_err().to_string();
            assert!(err.contains(line), "{:?} -> {}", text, err);
        }
    }

    #[test]
    fn test_rejects_empty_and_mixed_files() {
        assert!(parse_pitch_factors("# nothing\n\n").is_err());
        assert!(parse_pitch_factors("1.0\n3,1.0\n").is_err());
    }
}
