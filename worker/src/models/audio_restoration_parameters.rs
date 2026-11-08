//! Audio restoration — the one pass that works on the soundtrack.
//!
//! Everything here is applied by ffmpeg (and, for speech, the DeepFilterNet
//! add-on) in `audio_restoration.rs`, which renders the output's audio track
//! before the video encode; nothing reaches the VapourSynth script. See that
//! module for the order of the steps and why each sits where it does.

use serde::{Deserialize, Serialize};

/// What to do about the two channels of a stereo source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ChannelFix {
    /// Leave the channels alone.
    #[default]
    Off,
    /// Measure both channels; if one is silent, copy the other into it.
    /// Otherwise leave them alone.
    Auto,
    /// Both outputs from the left channel.
    LeftOnly,
    /// Both outputs from the right channel.
    RightOnly,
    /// Both outputs from the average of the two.
    Mix,
}

/// Which mains frequency to notch out.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum HumFrequency {
    /// Measure the audio for a 50 or 60 Hz hum and notch whichever is there;
    /// nothing when neither is.
    #[default]
    #[serde(rename = "auto")]
    Auto,
    #[serde(rename = "50")]
    Hz50,
    #[serde(rename = "60")]
    Hz60,
}

/// Parameters for the audio restoration pass. Off by default, and every step
/// inside it is off by default too: switching the pass on changes nothing until
/// a step is chosen.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AudioRestorationParameters {
    #[serde(default)]
    pub enabled: bool,

    /// Which of the source's audio streams to restore, counted among its audio
    /// streams from 0. The others are kept as they are.
    #[serde(default)]
    pub stream_index: u32,

    #[serde(default)]
    pub channel_fix: ChannelFix,

    /// Move the sound against the picture, in milliseconds. Positive delays
    /// the sound (it plays later), negative advances it.
    #[serde(default)]
    pub offset_ms: i32,

    /// Stretch or squeeze the sound to the picture's length when the two were
    /// recorded on clocks that disagreed.
    #[serde(default)]
    pub drift_correction: bool,

    /// The largest drift corrected, as a percentage of the length. A bigger
    /// mismatch is a different problem (the wrong track, a missing stretch of
    /// audio), which a stretch would only disguise.
    #[serde(default = "default_drift_max_percent")]
    pub drift_max_percent: f64,

    /// Rebuild waveform peaks the recording flattened (`adeclip`).
    #[serde(default)]
    pub declip: bool,

    /// Remove clicks and crackle (`adeclick`).
    #[serde(default)]
    pub declick: bool,

    /// `adeclick`'s threshold: lower removes more (and risks transients).
    #[serde(default = "default_declick_threshold")]
    pub declick_threshold: f64,

    /// Notch out mains hum and its first two harmonics.
    #[serde(default)]
    pub hum_removal: bool,

    #[serde(default)]
    pub hum_frequency: HumFrequency,

    /// High-pass out rumble (turntable, handling and wind noise).
    #[serde(default)]
    pub rumble_filter: bool,

    #[serde(default = "default_rumble_cutoff_hz")]
    pub rumble_cutoff_hz: u32,

    /// Broadband noise reduction (`afftdn`): tape hiss, fan noise.
    #[serde(default)]
    pub denoise: bool,

    /// How much noise to remove, in dB.
    #[serde(default = "default_denoise_strength")]
    pub denoise_strength: f64,

    /// Speech enhancement with DeepFilterNet (an add-on).
    #[serde(default)]
    pub deep_filter: bool,

    /// DeepFilterNet's attenuation limit in dB: how far it may turn noise
    /// down. 100 is no limit; lower keeps a little of the room.
    #[serde(default = "default_deep_filter_attenuation")]
    pub deep_filter_attenuation: u32,

    /// Normalise loudness to a target (EBU R128, two passes).
    #[serde(default)]
    pub loudness_normalize: bool,

    /// Integrated loudness target in LUFS.
    #[serde(default = "default_loudness_target")]
    pub loudness_target: f64,

    /// Keep peaks under a ceiling (`alimiter`).
    #[serde(default)]
    pub limiter: bool,

    /// The ceiling in dBFS.
    #[serde(default = "default_limiter_ceiling_db")]
    pub limiter_ceiling_db: f64,
}

fn default_drift_max_percent() -> f64 { 0.5 }
fn default_declick_threshold() -> f64 { 2.0 }
fn default_rumble_cutoff_hz() -> u32 { 40 }
fn default_denoise_strength() -> f64 { 12.0 }
fn default_deep_filter_attenuation() -> u32 { 100 }
fn default_loudness_target() -> f64 { -16.0 }
fn default_limiter_ceiling_db() -> f64 { -1.0 }

impl Default for AudioRestorationParameters {
    fn default() -> Self {
        Self {
            enabled: false,
            stream_index: 0,
            channel_fix: ChannelFix::Off,
            offset_ms: 0,
            drift_correction: false,
            drift_max_percent: default_drift_max_percent(),
            declip: false,
            declick: false,
            declick_threshold: default_declick_threshold(),
            hum_removal: false,
            hum_frequency: HumFrequency::Auto,
            rumble_filter: false,
            rumble_cutoff_hz: default_rumble_cutoff_hz(),
            denoise: false,
            denoise_strength: default_denoise_strength(),
            deep_filter: false,
            deep_filter_attenuation: default_deep_filter_attenuation(),
            loudness_normalize: false,
            loudness_target: default_loudness_target(),
            limiter: false,
            limiter_ceiling_db: default_limiter_ceiling_db(),
        }
    }
}

impl AudioRestorationParameters {
    /// Whether the pass changes anything: on, with at least one step chosen.
    /// A pass switched on with nothing in it leaves the audio exactly as
    /// before — copied or converted by the encoder, not rendered.
    pub fn has_effect(&self) -> bool {
        self.enabled
            && (self.channel_fix != ChannelFix::Off
                || self.offset_ms != 0
                || self.drift_correction
                || self.declip
                || self.declick
                || self.hum_removal
                || self.rumble_filter
                || self.denoise
                || self.deep_filter
                || self.loudness_normalize
                || self.limiter)
    }

    /// Whether the job needs the DeepFilterNet add-on.
    pub fn uses_deep_filter(&self) -> bool {
        self.enabled && self.deep_filter
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_names_match_the_app() {
        let json = r#"{"enabled":true,"streamIndex":1,"channelFix":"leftOnly","offsetMs":-120,
            "driftCorrection":true,"driftMaxPercent":0.3,"declip":true,"declick":true,
            "declickThreshold":3,"humRemoval":true,"humFrequency":"60","rumbleFilter":true,
            "rumbleCutoffHz":60,"denoise":true,"denoiseStrength":18,"deepFilter":true,
            "deepFilterAttenuation":30,"loudnessNormalize":true,"loudnessTarget":-23,
            "limiter":true,"limiterCeilingDb":-2}"#;
        let p: AudioRestorationParameters = serde_json::from_str(json).unwrap();
        assert_eq!(p.stream_index, 1);
        assert_eq!(p.channel_fix, ChannelFix::LeftOnly);
        assert_eq!(p.offset_ms, -120);
        assert_eq!(p.hum_frequency, HumFrequency::Hz60);
        assert_eq!(p.deep_filter_attenuation, 30);
        assert_eq!(p.loudness_target, -23.0);
        let back = serde_json::to_value(&p).unwrap();
        assert_eq!(back["channelFix"], "leftOnly");
        assert_eq!(back["humFrequency"], "60");
        for fix in ["off", "auto", "leftOnly", "rightOnly", "mix"] {
            let v: ChannelFix = serde_json::from_str(&format!("\"{fix}\"")).unwrap();
            assert_eq!(serde_json::to_value(v).unwrap(), fix);
        }
    }

    #[test]
    fn an_empty_object_is_the_default_and_does_nothing() {
        let p: AudioRestorationParameters = serde_json::from_str("{}").unwrap();
        assert_eq!(p, AudioRestorationParameters::default());
        assert!(!p.has_effect());
        // On, with nothing chosen, still does nothing.
        let on = AudioRestorationParameters { enabled: true, ..Default::default() };
        assert!(!on.has_effect());
        assert!(AudioRestorationParameters { enabled: true, offset_ms: 10, ..Default::default() }.has_effect());
        assert!(!AudioRestorationParameters { enabled: false, denoise: true, ..Default::default() }.has_effect());
    }
}
