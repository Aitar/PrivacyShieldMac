import XCTest
@testable import PrivacyShieldCore

/// Deterministic tests for the distance-adaptive attention policy (M3-T04):
/// pure logic, no camera, no Vision, no wall clock (dates are fixed offsets
/// from a base instant).
///
/// Plan profile values under test (exact):
/// - Near: yaw ±18°, pitch ±15°, trigger 0.7 s
/// - Mid:  yaw ±22°, pitch ±18°, trigger 0.9 s
/// - Far:  yaw ±27°, pitch ±22°, trigger 1.2 s
/// - Shared across profiles: roll ±30°, weights 0.60/0.35/0.05, thresholds
///   0.70/0.45, release 0.6 s, grace 0.35 s.
/// - `.tooFarOrUnreliable` → NO classifier config and NO timing config
///   (unreliable far faces must remain uncertain, never alert).
final class AdaptiveAttentionPolicyTests: XCTestCase {

    private let policy = AdaptiveAttentionPolicy()

    // MARK: - Exact per-band profiles (plan M3-T04 values)

    func testNearProfileExactTolerancesAndTrigger() {
        let config = policy.classifierConfig(for: .near, screenCenter: nil)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.yawTolerance, 18.0)
        XCTAssertEqual(config?.pitchTolerance, 15.0)
        XCTAssertEqual(policy.timingConfig(for: .near)?.triggerDuration, 0.7)
    }

    func testMidProfileExactTolerancesAndTrigger() {
        let config = policy.classifierConfig(for: .mid, screenCenter: nil)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.yawTolerance, 22.0)
        XCTAssertEqual(config?.pitchTolerance, 18.0)
        XCTAssertEqual(policy.timingConfig(for: .mid)?.triggerDuration, 0.9)
    }

    func testFarProfileExactTolerancesAndTrigger() {
        let config = policy.classifierConfig(for: .far, screenCenter: nil)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.yawTolerance, 27.0)
        XCTAssertEqual(config?.pitchTolerance, 22.0)
        XCTAssertEqual(policy.timingConfig(for: .far)?.triggerDuration, 1.2)
    }

    /// Roll tolerance, axis weights, thresholds, release and grace are
    /// IDENTICAL across all three profiles (only yaw/pitch tolerances and the
    /// trigger duration move with distance).
    func testSharedParametersUnchangedAcrossProfiles() {
        for band in [DistanceBand.near, .mid, .far] {
            let config = policy.classifierConfig(for: band, screenCenter: nil)
            let timing = policy.timingConfig(for: band)
            XCTAssertEqual(config?.rollTolerance, 30.0, "\(band)")
            XCTAssertEqual(config?.yawWeight, 0.60, "\(band)")
            XCTAssertEqual(config?.pitchWeight, 0.35, "\(band)")
            XCTAssertEqual(config?.rollWeight, 0.05, "\(band)")
            XCTAssertEqual(config?.lookingThreshold, 0.70, "\(band)")
            XCTAssertEqual(config?.notLookingThreshold, 0.45, "\(band)")
            XCTAssertEqual(timing?.releaseDuration, 0.6, "\(band)")
            XCTAssertEqual(timing?.uncertainGrace, 0.35, "\(band)")
        }
    }

    // MARK: - Unreliable far faces: never classified, never timed

    func testTooFarOrUnreliableReturnsNilConfigs() {
        XCTAssertNil(policy.classifierConfig(for: .tooFarOrUnreliable, screenCenter: nil))
        XCTAssertNil(policy.classifierConfig(for: .tooFarOrUnreliable, screenCenter: (5, -3)))
        XCTAssertNil(policy.timingConfig(for: .tooFarOrUnreliable))
    }

    /// End-to-end posture for an unreliable far face: whatever pose arrives,
    /// the track can never reach `.looking` with the nil-config fallback the
    /// detector uses (`.uncertain`), so its temporal filter can never alert.
    func testTooFarOrUnreliableTrackCanNeverAlert() {
        let base = Date(timeIntervalSince1970: 0)
        let filter = TemporalAttentionFilter(config: AttentionTimingConfig())  // fallback shared config

        // Long frontal staring with a pose fed through the same path the
        // detector uses for too-far tracks: no classifier config → .uncertain.
        var date = base
        for _ in 0..<100 {
            date += 0.1
            let attention = policy.classifierConfig(for: .tooFarOrUnreliable, screenCenter: nil)
                .map { AttentionClassifier(config: $0).classify(HeadPose(yaw: 0, pitch: 0, roll: 0, confidence: 1)) }
                ?? AttentionResult(state: .uncertain, score: 0.0)
            XCTAssertEqual(attention.state, .uncertain)
            XCTAssertFalse(filter.update(attention.state, at: date))
        }
        XCTAssertFalse(filter.isAlerting)
        XCTAssertEqual(filter.accumulatedLookingTime, 0)
    }

    // MARK: - Screen center application

    func testNilScreenCenterFallsBackToZeroDefaults() {
        let config = policy.classifierConfig(for: .mid, screenCenter: nil)
        XCTAssertEqual(config?.screenCenterYaw, 0.0)
        XCTAssertEqual(config?.screenCenterPitch, 0.0)
    }

    /// A calibrated center (5, −3) shifts the error origin: the physical pose
    /// (5°, −3°) reads as perfectly frontal (score 1.0 → looking), while the
    /// same pose against the uncalibrated 0/0 center keeps residual errors
    /// (score < 1.0). Error math: uncalibrated score
    /// = 0.60·(1 − 5/22) + 0.35·(1 − 3/18) + 0.05·1 ≈ 0.8053.
    func testScreenCenterShiftsErrorsCorrectly() {
        let calibrated = policy.classifierConfig(for: .mid, screenCenter: (5, -3))
        XCTAssertNotNil(calibrated)
        XCTAssertEqual(calibrated?.screenCenterYaw, 5.0)
        XCTAssertEqual(calibrated?.screenCenterPitch, -3.0)

        let pose = HeadPose(yaw: 5, pitch: -3, roll: 0, confidence: 1)

        let calibratedResult = AttentionClassifier(config: calibrated!).classify(pose)
        XCTAssertEqual(calibratedResult.score, 1.0, accuracy: 1e-12)
        XCTAssertEqual(calibratedResult.state, .looking)

        let uncalibrated = policy.classifierConfig(for: .mid, screenCenter: nil)!
        let uncalibratedResult = AttentionClassifier(config: uncalibrated).classify(pose)
        let expected = 0.60 * (1 - 5.0 / 22.0) + 0.35 * (1 - 3.0 / 18.0) + 0.05 * 1.0
        XCTAssertEqual(uncalibratedResult.score, expected, accuracy: 1e-9)
        XCTAssertLessThan(uncalibratedResult.score, 1.0)
    }

    /// Direction of the shift matters, and it can flip the discrete state:
    /// pose (10°, −3°, 0°) against calibrated center (5, −3) scores
    /// 0.60·(1 − 5/22) + 0.35·1 + 0.05·1 ≈ 0.8636 → looking, while the same
    /// physical pose against the uncalibrated 0/0 center scores
    /// 0.60·(1 − 10/22) + 0.35·(1 − 3/18) + 0.05 ≈ 0.6689 → uncertain.
    /// Also checks the tolerance edge: 22° past the calibrated yaw loses the
    /// whole yaw score (0.35 + 0.05 = 0.40 ≤ 0.45 → notLooking).
    func testScreenCenterShiftAppliesSignedErrors() {
        let calibrated = policy.classifierConfig(for: .mid, screenCenter: (5, -3))!

        let frontal = HeadPose(yaw: 10, pitch: -3, roll: 0, confidence: 1)
        let calibratedResult = AttentionClassifier(config: calibrated).classify(frontal)
        XCTAssertEqual(calibratedResult.score, 0.60 * (1 - 5.0 / 22.0) + 0.40, accuracy: 1e-9)
        XCTAssertEqual(calibratedResult.state, .looking)

        let uncalibrated = policy.classifierConfig(for: .mid, screenCenter: nil)!
        let uncalibratedResult = AttentionClassifier(config: uncalibrated).classify(frontal)
        let expected = 0.60 * (1 - 10.0 / 22.0) + 0.35 * (1 - 3.0 / 18.0) + 0.05
        XCTAssertEqual(uncalibratedResult.score, expected, accuracy: 1e-9)
        XCTAssertEqual(uncalibratedResult.state, .uncertain)

        let atYawEdge = HeadPose(yaw: 5 + 22, pitch: -3, roll: 0, confidence: 1)
        let edgeResult = AttentionClassifier(config: calibrated).classify(atYawEdge)
        XCTAssertEqual(edgeResult.score, 0.35 + 0.05, accuracy: 1e-9)
        XCTAssertEqual(edgeResult.state, .notLooking)
    }

    // MARK: - Configurability (X-T01: no scattered magic numbers)

    /// Every profile value is a plain struct field: swapping a field on the
    /// policy's profiles changes what the policy hands out.
    func testProfilesAreConfigurable() {
        var custom = AdaptiveAttentionPolicy()
        custom.profiles.near.yawTolerance = 10.0
        custom.profiles.nearTiming.triggerDuration = 0.5
        custom.profiles.far = AttentionClassifierConfig(yawTolerance: 40.0, pitchTolerance: 33.0)

        XCTAssertEqual(custom.classifierConfig(for: .near, screenCenter: nil)?.yawTolerance, 10.0)
        XCTAssertEqual(custom.timingConfig(for: .near)?.triggerDuration, 0.5)
        XCTAssertEqual(custom.classifierConfig(for: .far, screenCenter: nil)?.yawTolerance, 40.0)
        XCTAssertEqual(custom.classifierConfig(for: .far, screenCenter: nil)?.pitchTolerance, 33.0)
        // Standard policy untouched (value semantics).
        XCTAssertEqual(policy.classifierConfig(for: .near, screenCenter: nil)?.yawTolerance, 18.0)
    }

    // MARK: - Band change must NOT reset filter accumulation (M3-T04)

    /// A filter accumulating toward the mid trigger (0.9 s) holds 0.4 s when
    /// its band changes to near (trigger 0.7 s): `updateConfig` swaps ONLY
    /// the configuration. Continuing to look, the alert fires at 0.8 s wall
    /// time = 0.8 s total accumulation ≥ 0.7 s — it would NOT fire if the
    /// accumulation had been reset by the profile change (0.4 s < 0.7 s), and
    /// it would not fire either if the new config had not taken effect
    /// (0.8 s < 0.9 s mid trigger). Both acceptance criteria in one sequence.
    func testBandChangeDoesNotResetAccumulation() {
        // Base at the reference date keeps timestamp magnitudes tiny, so the
        // 0.2 s deltas stay exact to double precision.
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let filter = TemporalAttentionFilter(config: policy.timingConfig(for: .mid)!)

        // 0.4 s of sustained looking (deltas 0.2 s, all under maxDelta).
        XCTAssertFalse(filter.update(.looking, at: base))
        XCTAssertFalse(filter.update(.looking, at: base.addingTimeInterval(0.2)))
        XCTAssertFalse(filter.update(.looking, at: base.addingTimeInterval(0.4)))
        XCTAssertEqual(filter.accumulatedLookingTime, 0.4, accuracy: 1e-9)

        // Band changes far → near: profile swap, no reset.
        filter.updateConfig(policy.timingConfig(for: .near)!)
        XCTAssertFalse(filter.isAlerting)
        XCTAssertEqual(filter.accumulatedLookingTime, 0.4, accuracy: 1e-9,
                       "profile change must not reset a track's accumulation")

        // Continue looking: 0.6 s total — still under the near trigger.
        XCTAssertFalse(filter.update(.looking, at: base.addingTimeInterval(0.6)))
        // 0.8 s total ≥ 0.7 s near trigger → alert.
        XCTAssertTrue(filter.update(.looking, at: base.addingTimeInterval(0.8)))
        XCTAssertTrue(filter.isAlerting)
        XCTAssertEqual(filter.accumulatedLookingTime, 0.8, accuracy: 1e-9)
    }

    /// Counter-check that the swap really applied: a filter that KEEPS the
    /// mid config does not alert at 0.8 s of accumulation.
    func testUnchangedMidConfigDoesNotAlertAt08s() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let filter = TemporalAttentionFilter(config: policy.timingConfig(for: .mid)!)
        XCTAssertFalse(filter.update(.looking, at: base))
        XCTAssertFalse(filter.update(.looking, at: base.addingTimeInterval(0.2)))
        XCTAssertFalse(filter.update(.looking, at: base.addingTimeInterval(0.4)))
        XCTAssertFalse(filter.update(.looking, at: base.addingTimeInterval(0.6)))
        XCTAssertFalse(filter.update(.looking, at: base.addingTimeInterval(0.8)))
        XCTAssertFalse(filter.isAlerting, "mid trigger is 0.9 s — 0.8 s must not alert")
    }

    /// Release semantics survive the swap: after the alert, switching to a
    /// profile with the same release keeps holding until release elapses.
    /// (Note the filter API: `update` returns the CURRENT `isAlerting`, so a
    /// held-but-not-yet-released alert still reports `true`.)
    func testReleaseWindowStillAppliesAfterConfigSwap() {
        // Base at the reference date keeps timestamp magnitudes tiny.
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let filter = TemporalAttentionFilter(config: policy.timingConfig(for: .near)!)

        // 0.75 s of sustained looking (deltas 0.25 s) ≥ 0.7 s near trigger.
        XCTAssertFalse(filter.update(.looking, at: base))
        XCTAssertFalse(filter.update(.looking, at: base.addingTimeInterval(0.25)))
        XCTAssertFalse(filter.update(.looking, at: base.addingTimeInterval(0.5)))
        XCTAssertTrue(filter.update(.looking, at: base.addingTimeInterval(0.75)))
        XCTAssertTrue(filter.isAlerting)

        // Profile changes to far (same 0.6 s release) — alert must hold.
        filter.updateConfig(policy.timingConfig(for: .far)!)
        XCTAssertTrue(filter.update(.notLooking, at: base.addingTimeInterval(1.1)),
                      "0.35 s < 0.6 s release — alert must still be latched")
        XCTAssertFalse(filter.update(.notLooking, at: base.addingTimeInterval(1.4)),
                       "0.65 s > 0.6 s release — alert must have cleared")
        XCTAssertFalse(filter.isAlerting)
        XCTAssertEqual(filter.accumulatedLookingTime, 0)
    }

    // MARK: - Hysteresis wiring through the policy (integration-style)

    /// Mirrors the detector's per-frame wiring: width → classifier →
    /// hysteresis (previous band from the track) → policy configs. A track
    /// seen at width 0.15 (.far) whose width drifts to 0.165 stays .far
    /// (crossed the 0.16 boundary by less than the 0.015 margin), keeping the
    /// FAR profile; at 0.18 (crossed by 0.02 > margin) it becomes .mid and
    /// the policy hands out the mid profile (0.9 s trigger) instead.
    func testBandHysteresisSelectsStableProfiles() {
        let classifier = DistanceBandClassifier()
        var previousBand: DistanceBand?

        // Frame 1: width 0.15 → far (new track: raw classification).
        var width = 0.15
        var raw = classifier.band(forNormalizedFaceWidth: width)
        var band = DistanceBandHysteresis.refined(previous: previousBand, current: raw,
                                                  width: width, config: .default)
        previousBand = band
        XCTAssertEqual(band, .far)
        XCTAssertEqual(policy.timingConfig(for: band)?.triggerDuration, 1.2)
        XCTAssertEqual(policy.classifierConfig(for: band, screenCenter: nil)?.yawTolerance, 27.0)

        // Frame 2: width 0.165 — raw says .mid, but the crossing (0.005) is
        // under the margin → stays .far, profile unchanged.
        width = 0.165
        raw = classifier.band(forNormalizedFaceWidth: width)
        band = DistanceBandHysteresis.refined(previous: previousBand, current: raw,
                                              width: width, config: .default)
        previousBand = band
        XCTAssertEqual(raw, .mid)
        XCTAssertEqual(band, .far)
        XCTAssertEqual(policy.timingConfig(for: band)?.triggerDuration, 1.2)

        // Frame 3: width 0.18 — crossed by 0.02 > margin → .mid confirmed.
        width = 0.18
        raw = classifier.band(forNormalizedFaceWidth: width)
        band = DistanceBandHysteresis.refined(previous: previousBand, current: raw,
                                              width: width, config: .default)
        previousBand = band
        XCTAssertEqual(band, .mid)
        XCTAssertEqual(policy.timingConfig(for: band)?.triggerDuration, 0.9)
        XCTAssertEqual(policy.classifierConfig(for: band, screenCenter: nil)?.yawTolerance, 22.0)

        // Frame 4: width collapses to 0.05 → tooFarOrUnreliable → the policy
        // hands out NO configs: the track must run uncertain from here on.
        width = 0.05
        raw = classifier.band(forNormalizedFaceWidth: width)
        band = DistanceBandHysteresis.refined(previous: previousBand, current: raw,
                                              width: width, config: .default)
        XCTAssertEqual(band, .tooFarOrUnreliable)
        XCTAssertNil(policy.classifierConfig(for: band, screenCenter: nil))
        XCTAssertNil(policy.timingConfig(for: band))
    }
}
