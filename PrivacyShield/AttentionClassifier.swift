import Foundation

/// Tuning parameters for `AttentionClassifier`.
///
/// Every tolerance, weight and threshold lives here — no magic numbers in the
/// scoring code (cross-cutting requirement X-T01). The weights must sum to 1.0
/// so `score` stays a normalized value in [0, 1].
///
/// M3 note: distance-band profiles (near/mid/far) will be introduced as
/// additional `AttentionClassifierConfig` presets (like `balanced`), selected
/// from the face-size/distance calibration rather than as new classifier types.
struct AttentionClassifierConfig {
    var screenCenterYaw: Double = 0.0      // degrees, from calibration (M3)
    var screenCenterPitch: Double = 0.0    // degrees
    var yawTolerance: Double = 22.0        // ± degrees (balanced default)
    var pitchTolerance: Double = 18.0
    var rollTolerance: Double = 30.0
    var yawWeight: Double = 0.60
    var pitchWeight: Double = 0.35
    var rollWeight: Double = 0.05
    var lookingThreshold: Double = 0.70    // score >= → looking
    var notLookingThreshold: Double = 0.45 // score <= → notLooking

    /// Default profile: tolerances chosen so a natural working posture reads
    /// as looking while a glance toward a second screen reads as not looking.
    static let balanced = AttentionClassifierConfig()
}

/// Rule-based attention classifier over head pose (M1-T04).
///
/// Pure logic, no camera/Vision dependency: takes a `HeadPose` in degrees and
/// produces a normalized attention score plus a discrete `AttentionState`.
///
/// Scoring: for each axis, `score = clamp(1 - error/tolerance, 0, 1)` where
/// error is the absolute angular distance from the calibrated screen center
/// (roll has no screen center). The total is the weighted sum of the three
/// axis scores using `config` weights, which must sum to 1.0.
struct AttentionClassifier {
    var config: AttentionClassifierConfig = .balanced

    /// Normalized weighted attention score in [0, 1].
    ///
    /// Head pose confidence is intentionally not folded into the score yet;
    /// M3 may weight by confidence/distance-band once calibration exists.
    func score(for pose: HeadPose) -> Double {
        let yawError = abs(pose.yaw - config.screenCenterYaw)
        let pitchError = abs(pose.pitch - config.screenCenterPitch)
        let rollError = abs(pose.roll)

        let yawScore = normalizedScore(error: yawError, tolerance: config.yawTolerance)
        let pitchScore = normalizedScore(error: pitchError, tolerance: config.pitchTolerance)
        let rollScore = normalizedScore(error: rollError, tolerance: config.rollTolerance)

        return config.yawWeight * yawScore
            + config.pitchWeight * pitchScore
            + config.rollWeight * rollScore
    }

    /// Classify a raw pose against the configured thresholds.
    ///
    /// The gap between `notLookingThreshold` and `lookingThreshold` is the
    /// hysteresis band: scores inside it map to `.uncertain` instead of
    /// flipping between the two stable states.
    func classify(_ pose: HeadPose) -> AttentionResult {
        let value = score(for: pose)
        let state: AttentionState
        if value >= config.lookingThreshold {
            state = .looking
        } else if value <= config.notLookingThreshold {
            state = .notLooking
        } else {
            state = .uncertain
        }
        return AttentionResult(state: state, score: value)
    }

    /// Classify a pose pipeline result. A missing pose is never mapped to a
    /// zero pose — it is `.uncertain` with the lowest score, leaving the
    /// shield decision to temporal smoothing (M1-T07) instead of guessing.
    func classify(_ result: HeadPoseResult) -> AttentionResult {
        switch result {
        case .valid(let pose):
            return classify(pose)
        case .unavailable:
            return AttentionResult(state: .uncertain, score: 0.0)
        }
    }

    /// Axis score: full marks at zero error, linearly decaying to zero at the
    /// tolerance, clamped so overshoot can't produce negative contributions.
    private func normalizedScore(error: Double, tolerance: Double) -> Double {
        guard tolerance > 0 else {
            // Degenerate zero tolerance: exact alignment is a perfect score,
            // any error contributes nothing.
            return error <= 0 ? 1.0 : 0.0
        }
        return min(max(1 - error / tolerance, 0), 1)
    }
}
