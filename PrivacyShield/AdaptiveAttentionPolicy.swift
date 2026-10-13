import Foundation

// MARK: - Distance-adaptive attention profiles (M3-T04)
//
// Plan task M3-T04: attention tolerances and trigger durations adapt to the
// observer's distance band (M3-T03). Farther faces get LOOSER angular
// tolerances (head-angle readings are noisier at distance and a distant
// observer must turn further to read someone else's screen) and LONGER
// trigger durations (more evidence is demanded before a distant face raises
// the shield). Everything else — roll tolerance, axis weights, thresholds,
// release, grace — stays identical across profiles so only the intended
// knobs move with distance.
//
// Exact plan values:
//
//     Near: yaw ±18°, pitch ±15°, trigger 0.7 s
//     Mid:  yaw ±22°, pitch ±18°, trigger 0.9 s
//     Far:  yaw ±27°, pitch ±22°, trigger 1.2 s
//
// Shared across all profiles: roll ±30°, weights 0.60/0.35/0.05, thresholds
// 0.70/0.45, release 0.6 s, grace 0.35 s.
//
// All values live in these struct fields — no scattered magic numbers (X-T01).
// `.standard` holds the plan's initial numbers until M3-T06 tuning revisits
// them against the 1–4 m evaluation data.

/// Per-band attention profiles: one classifier config and one timing config
/// per distance band (near/mid/far). Plain value struct so a future tuning
/// or persistence flow can swap the whole set.
struct DistanceAttentionProfiles {

    var near: AttentionClassifierConfig
    var mid: AttentionClassifierConfig
    var far: AttentionClassifierConfig
    var nearTiming: AttentionTimingConfig
    var midTiming: AttentionTimingConfig
    var farTiming: AttentionTimingConfig

    /// Plan M3-T04 initial profiles. The stored screen center (0/0) is a
    /// placeholder — `AdaptiveAttentionPolicy.classifierConfig` overlays the
    /// calibrated center on a copy, so these base values are never used for
    /// classification directly.
    static let standard = DistanceAttentionProfiles(
        near: AttentionClassifierConfig(
            screenCenterYaw: 0.0,
            screenCenterPitch: 0.0,
            yawTolerance: 18.0,
            pitchTolerance: 15.0,
            rollTolerance: 30.0,
            yawWeight: 0.60,
            pitchWeight: 0.35,
            rollWeight: 0.05,
            lookingThreshold: 0.70,
            notLookingThreshold: 0.45
        ),
        mid: AttentionClassifierConfig(
            screenCenterYaw: 0.0,
            screenCenterPitch: 0.0,
            yawTolerance: 22.0,
            pitchTolerance: 18.0,
            rollTolerance: 30.0,
            yawWeight: 0.60,
            pitchWeight: 0.35,
            rollWeight: 0.05,
            lookingThreshold: 0.70,
            notLookingThreshold: 0.45
        ),
        far: AttentionClassifierConfig(
            screenCenterYaw: 0.0,
            screenCenterPitch: 0.0,
            yawTolerance: 27.0,
            pitchTolerance: 22.0,
            rollTolerance: 30.0,
            yawWeight: 0.60,
            pitchWeight: 0.35,
            rollWeight: 0.05,
            lookingThreshold: 0.70,
            notLookingThreshold: 0.45
        ),
        nearTiming: AttentionTimingConfig(
            triggerDuration: 0.7,
            releaseDuration: 0.6,
            uncertainGrace: 0.35
        ),
        midTiming: AttentionTimingConfig(
            triggerDuration: 0.9,
            releaseDuration: 0.6,
            uncertainGrace: 0.35
        ),
        farTiming: AttentionTimingConfig(
            triggerDuration: 1.2,
            releaseDuration: 0.6,
            uncertainGrace: 0.35
        )
    )
}

// MARK: - Policy

/// Distance-adaptive attention policy (M3-T04): maps a track's distance band
/// onto the classifier and timing configurations its pipeline stage uses.
///
/// Failure posture: `.tooFarOrUnreliable` faces get NO classifier and NO
/// timing config (`nil`) — a face too small to judge reliably must remain
/// uncertain, never alert. The detector feeds those tracks `.uncertain`
/// directly, so they stay tracked and logged but can never accumulate
/// looking time toward an alert.
///
/// Stateless and thread-safe: `screenCenter` is supplied per call so a
/// recalibration applies to every subsequent evaluation without rebuilding
/// the policy.
struct AdaptiveAttentionPolicy {

    /// The per-band profiles in effect. Swap to retune (M3-T06).
    var profiles = DistanceAttentionProfiles.standard

    /// Classifier config for a band with the calibrated screen center
    /// applied, or `nil` for `.tooFarOrUnreliable` (unreliable far faces
    /// must remain uncertain, never alert). A `nil` screen center means "not
    /// calibrated yet" and falls back to the 0/0 frontal assumption.
    func classifierConfig(for band: DistanceBand,
                          screenCenter: (yaw: Double, pitch: Double)?) -> AttentionClassifierConfig? {
        switch band {
        case .tooFarOrUnreliable:
            return nil
        case .near:
            return profiles.near.applyingScreenCenter(screenCenter)
        case .mid:
            return profiles.mid.applyingScreenCenter(screenCenter)
        case .far:
            return profiles.far.applyingScreenCenter(screenCenter)
        }
    }

    /// Timing config for a band, or `nil` for `.tooFarOrUnreliable`.
    func timingConfig(for band: DistanceBand) -> AttentionTimingConfig? {
        switch band {
        case .tooFarOrUnreliable:
            return nil
        case .near:
            return profiles.nearTiming
        case .mid:
            return profiles.midTiming
        case .far:
            return profiles.farTiming
        }
    }
}

private extension AttentionClassifierConfig {

    /// Value-semantics copy with the calibrated screen center applied.
    /// `nil` center (nothing calibrated yet) → the 0/0 defaults.
    func applyingScreenCenter(_ center: (yaw: Double, pitch: Double)?) -> AttentionClassifierConfig {
        var copy = self
        copy.screenCenterYaw = center?.yaw ?? 0.0
        copy.screenCenterPitch = center?.pitch ?? 0.0
        return copy
    }
}
