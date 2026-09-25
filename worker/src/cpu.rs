//! Which x86 deps bundle this CPU can run (issue #92).
//!
//! The x86 bundles ship in two capability tiers. `v3` is built for the
//! x86-64-v3 psABI level (Haswell, 2013, and later); `v2` runs on anything
//! older. This is the single place that decides between them: the app asks
//! `vapourbox-worker --probe-cpu` which bundle to download, and the worker's own
//! CPU-dependent choices (`script_generator::ctmf_opt`) derive from the same
//! answer, so the two can never disagree about what this machine is.
//!
//! Detection is a runtime CPUID query that also checks the OS has enabled the
//! AVX register state, so it reports what the process can really execute —
//! including under Rosetta, which exposes AVX2 on macOS 15+ and nothing earlier.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CpuTier {
    V2,
    V3,
}

impl CpuTier {
    pub fn as_str(self) -> &'static str {
        match self {
            CpuTier::V2 => "v2",
            CpuTier::V3 => "v3",
        }
    }
}

/// The x86-64-v3 feature set, as compilers define `-march=x86-64-v3`.
///
/// All of it, not just AVX2: zsmooth's haswell build and the other v3 plugins
/// are compiled for the whole level, so a CPU with AVX2 but without (say) MOVBE
/// can still fault in them. Such CPUs are rare; the cost of sending one to v2
/// is throughput, while the cost of the reverse is a crash.
pub const V3_FEATURES: [&str; 8] = ["avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "lzcnt", "movbe"];

/// The tier for a CPU, given a feature test. Pure, so it is testable on any host.
pub fn tier_from_features(has: impl Fn(&str) -> bool) -> CpuTier {
    if V3_FEATURES.iter().all(|f| has(f)) {
        CpuTier::V3
    } else {
        CpuTier::V2
    }
}

/// This machine's tier, or `None` off x86 (ARM bundles are not tiered).
pub fn cpu_tier() -> Option<CpuTier> {
    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        Some(tier_from_features(has_feature))
    }
    #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
    {
        None
    }
}

/// Runtime feature test by name. `is_x86_feature_detected!` only takes
/// literals, hence the match; an unknown name is reported as absent.
#[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
pub fn has_feature(name: &str) -> bool {
    match name {
        "sse2" => std::is_x86_feature_detected!("sse2"),
        "sse4.1" => std::is_x86_feature_detected!("sse4.1"),
        "sse4.2" => std::is_x86_feature_detected!("sse4.2"),
        "avx" => std::is_x86_feature_detected!("avx"),
        "avx2" => std::is_x86_feature_detected!("avx2"),
        "bmi1" => std::is_x86_feature_detected!("bmi1"),
        "bmi2" => std::is_x86_feature_detected!("bmi2"),
        "f16c" => std::is_x86_feature_detected!("f16c"),
        "fma" => std::is_x86_feature_detected!("fma"),
        "lzcnt" => std::is_x86_feature_detected!("lzcnt"),
        "movbe" => std::is_x86_feature_detected!("movbe"),
        "avx512f" => std::is_x86_feature_detected!("avx512f"),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_v3_feature_is_required() {
        assert_eq!(tier_from_features(|_| true), CpuTier::V3);
        for missing in V3_FEATURES {
            assert_eq!(
                tier_from_features(|f| f != missing),
                CpuTier::V2,
                "a CPU without {missing} must not be offered the v3 bundle"
            );
        }
    }

    #[test]
    fn a_pre_avx_cpu_is_v2() {
        // Westmere, the Mac Pro 5,1 from issue #92: SSE4.2, no AVX at all.
        let westmere = ["sse2", "sse4.1", "sse4.2"];
        assert_eq!(tier_from_features(|f| westmere.contains(&f)), CpuTier::V2);
    }

    #[test]
    fn tier_is_reported_exactly_where_bundles_are_tiered() {
        let tier = cpu_tier();
        if cfg!(any(target_arch = "x86", target_arch = "x86_64")) {
            assert!(tier.is_some(), "x86 must always resolve to a tier");
        } else {
            assert_eq!(tier, None, "ARM bundles are not tiered");
        }
    }

    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    #[test]
    fn the_runtime_answer_agrees_with_the_feature_test() {
        assert_eq!(cpu_tier(), Some(tier_from_features(has_feature)));
        // Guard the literal match: a misspelt arm would silently read "absent"
        // and push every machine to v2.
        assert!(has_feature("sse2"), "sse2 is architectural on x86_64");
    }
}
