import XCTest
@testable import PrivacyShieldCore

/// Deterministic classifier tests over synthetic poses (no camera).
final class AttentionClassifierTests: XCTestCase {

    // MARK: - Helpers

    private func makePose(yaw: Double, pitch: Double = 0, roll: Double = 0, confidence: Double = 1.0) -> HeadPose {
        HeadPose(yaw: yaw, pitch: pitch, roll: roll, confidence: confidence)
    }

    private func makeClassifier(
        yawTolerance: Double? = nil,
        screenCenterYaw: Double = 0,
        screenCenterPitch: Double = 0
    ) -> AttentionClassifier {
        var config = AttentionClassifierConfig.balanced
        if let yawTolerance { config.yawTolerance = yawTolerance }
        config.screenCenterYaw = screenCenterYaw
        config.screenCenterPitch = screenCenterPitch
        return AttentionClassifier(config: config)
    }

    // MARK: - Config invariants (X-T01: everything configurable, nothing magic)

    func testBalancedWeightsSumToOne() {
        let config = AttentionClassifierConfig.balanced
        XCTAssertEqual(
            config.yawWeight + config.pitchWeight + config.rollWeight,
            1.0,
            accuracy: 1e-12,
            "Axis weights must sum to 1.0 so the score stays normalized in [0, 1]."
        )
        XCTAssertEqual(config.yawWeight, 0.60, accuracy: 1e-12)
        XCTAssertEqual(config.pitchWeight, 0.35, accuracy: 1e-12)
        XCTAssertEqual(config.rollWeight, 0.05, accuracy: 1e-12)
        XCTAssertEqual(config.yawTolerance, 22.0, accuracy: 1e-12)
        XCTAssertEqual(config.pitchTolerance, 18.0, accuracy: 1e-12)
        XCTAssertEqual(config.rollTolerance, 30.0, accuracy: 1e-12)
        XCTAssertEqual(config.lookingThreshold, 0.70, accuracy: 1e-12)
        XCTAssertEqual(config.notLookingThreshold, 0.45, accuracy: 1e-12)
    }

    // MARK: - Frontal / screen-aligned

    func testFrontalPoseScoresHighAndIsLooking() {
        let classifier = makeClassifier()
        let result = classifier.classify(makePose(yaw: 0, pitch: 0, roll: 0))

        XCTAssertGreaterThan(result.score, 0.9, "A perfectly screen-aligned pose should score near 1.0.")
        XCTAssertEqual(result.state, .looking)
        // The HeadPoseResult overload must agree with the direct pose overload.
        let viaResult = classifier.classify(.valid(makePose(yaw: 0, pitch: 0, roll: 0)))
        XCTAssertEqual(viaResult.state, result.state)
        XCTAssertEqual(viaResult.score, result.score, accuracy: 1e-12)
    }

    // MARK: - Clearly away

    func testLargeYawOffsetIsNotLooking() {
        let classifier = makeClassifier()
        let result = classifier.classify(makePose(yaw: 45))

        // yawScore clamps to 0 → score = 0.35*1 + 0.05*1 = 0.40
        let expected = 0.60 * 0.0 + 0.35 * 1.0 + 0.05 * 1.0
        XCTAssertEqual(result.score, expected, accuracy: 1e-12)
        XCTAssertLessThan(result.score, 0.45)
        XCTAssertEqual(result.state, .notLooking)
    }

    // MARK: - Boundary / hysteresis band

    func testScoreInsideGapIsUncertain() {
        let classifier = makeClassifier()
        // yaw 16.5 with tolerance 22 → yawScore = 0.25 → score = 0.6*0.25 + 0.4 = 0.55,
        // strictly between notLookingThreshold (0.45) and lookingThreshold (0.70).
        let result = classifier.classify(makePose(yaw: 16.5))

        let expectedYawScore = 1.0 - 16.5 / 22.0
        let expected = 0.60 * expectedYawScore + 0.35 * 1.0 + 0.05 * 1.0
        XCTAssertTrue(expected > 0.45 && expected < 0.70, "Test fixture must land inside the uncertain gap; got \(expected).")

        XCTAssertEqual(result.score, expected, accuracy: 1e-12)
        XCTAssertEqual(result.state, .uncertain)
    }

    // MARK: - Score normalization

    func testScoreStaysInUnitRangeForExtremePoses() {
        let classifier = makeClassifier()
        let extreme = makePose(yaw: 180, pitch: 90, roll: 180)
        let score = classifier.score(for: extreme)
        XCTAssertGreaterThanOrEqual(score, 0.0)
        XCTAssertLessThanOrEqual(score, 1.0)
        XCTAssertEqual(score, 0.0, accuracy: 1e-12, "Every axis is beyond tolerance, so all contributions clamp to zero.")

        // Same extremes against a shifted screen center must also stay normalized.
        let offCenter = makeClassifier(screenCenterYaw: 90, screenCenterPitch: 45)
        let offCenterScore = offCenter.score(for: extreme)
        XCTAssertGreaterThanOrEqual(offCenterScore, 0.0)
        XCTAssertLessThanOrEqual(offCenterScore, 1.0)

        // Very wide tolerances pull the same extreme pose to the middle of the range.
        var wideConfig = AttentionClassifierConfig.balanced
        wideConfig.yawTolerance = 360
        wideConfig.pitchTolerance = 180
        wideConfig.rollTolerance = 360
        let wideScore = AttentionClassifier(config: wideConfig).score(for: extreme)
        XCTAssertGreaterThanOrEqual(wideScore, 0.0)
        XCTAssertLessThanOrEqual(wideScore, 1.0)
        XCTAssertEqual(wideScore, 0.5, accuracy: 1e-12, "Each axis at exactly its tolerance distance scores 0.5.")
    }

    // MARK: - Screen-center calibration

    func testCustomScreenCenterIsLooking() {
        let classifier = makeClassifier(screenCenterYaw: 10)
        let result = classifier.classify(makePose(yaw: 10))

        XCTAssertEqual(result.score, 1.0, accuracy: 1e-12)
        XCTAssertEqual(result.state, .looking)

        let viaResult = classifier.classify(.valid(makePose(yaw: 10)))
        XCTAssertEqual(viaResult.state, .looking)
        XCTAssertEqual(viaResult.score, 1.0, accuracy: 1e-12)
    }

    // MARK: - Missing pose

    func testUnavailablePoseIsUncertainWithZeroScore() {
        let classifier = makeClassifier()
        let result = classifier.classify(HeadPoseResult.unavailable)

        XCTAssertEqual(result.state, .uncertain)
        XCTAssertEqual(result.score, 0.0, accuracy: 0.0)
    }

    // MARK: - Configurability

    func testWiderYawToleranceScoresHigherForSamePose() {
        let sharedPose = makePose(yaw: 20)
        let wide = makeClassifier(yawTolerance: 30).score(for: sharedPose)
        let narrow = makeClassifier(yawTolerance: 15).score(for: sharedPose)

        // Analytic check: wide yawScore = 1 - 20/30; narrow clamps to 0.
        XCTAssertEqual(wide, 0.60 * (1.0 - 20.0 / 30.0) + 0.40, accuracy: 1e-12)
        XCTAssertEqual(narrow, 0.40, accuracy: 1e-12)
        XCTAssertGreaterThan(wide, narrow)
    }
}
