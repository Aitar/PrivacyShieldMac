import XCTest
import CoreGraphics
@testable import PrivacyShieldCore

/// Deterministic identity-cache policy tests (M2-T05): no camera, no Vision,
/// no wall clock — every call injects an explicit `now` built from a fixed
/// base date, and tracks are constructed directly from the M2-T01 contract.
///
/// Uses the default `RecognitionCachePolicyConfig` unless a test says
/// otherwise: owner/trusted cadence 2.5 s, other/unknown cadence 1.5 s,
/// bbox-jump threshold 0.35 (fraction of frame width), face-size log-ratio
/// 0.4, resume-after-gap threshold 1.0 s, owner downgrade after 2 misses.
final class RecognitionCachePolicyTests: XCTestCase {

    private let base = Date(timeIntervalSinceReferenceDate: 100.0)
    private lazy var policy = RecognitionCachePolicy()

    private func date(_ offsetSeconds: TimeInterval) -> Date {
        return base.addingTimeInterval(offsetSeconds)
    }

    // MARK: - Fixtures

    /// FaceTrack fixture per the M2-T01 contract.
    private func makeTrack(identity: IdentityState,
                           boundingBox: CGRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           lastIdentityCheck: Date?) -> FaceTrack {
        return FaceTrack(
            id: UUID(),
            boundingBox: boundingBox,
            identity: identity,
            attentionScore: 0.0,
            attentionState: .notLooking,
            lookingSince: nil,
            lastSeen: base,
            lastIdentityCheck: lastIdentityCheck,
            lastPositiveAt: nil,
            lastNegativeAt: nil,
            createdAt: base,
            hitCount: 1,
            consecutiveMisses: 0
        )
    }

    /// A freshly checked owner track: identity cached 0.2 s ago (well inside
    /// every cadence) unless the test overrides the check time.
    private func checkedOwnerTrack(lastIdentityCheck: Date?) -> FaceTrack {
        return makeTrack(identity: .owner, lastIdentityCheck: lastIdentityCheck)
    }

    // MARK: - Extraction helpers

    private func reason(of decision: RecognitionDecision) -> RecognitionReason {
        switch decision {
        case .recognizeNow(let reason): return reason
        case .cached(_, let reason): return reason
        }
    }

    private func assertRecognizeNow(_ decision: RecognitionDecision,
                                    _ expectedReason: RecognitionReason,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard case .recognizeNow(let actualReason) = decision else {
            XCTFail("expected .recognizeNow, got \(decision)", file: file, line: line)
            return
        }
        XCTAssertEqual(actualReason, expectedReason, file: file, line: line)
    }

    private func assertWithinCadence(_ decision: RecognitionDecision,
                                     identity expectedIdentity: IdentityState,
                                     elapsed expectedElapsed: TimeInterval,
                                     interval expectedInterval: TimeInterval,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard case .cached(let identity, let reason) = decision else {
            XCTFail("expected .cached, got \(decision)", file: file, line: line)
            return
        }
        XCTAssertEqual(identity, expectedIdentity, file: file, line: line)
        guard case .withinCadence(let elapsed, let interval) = reason else {
            XCTFail("expected .withinCadence, got \(reason)", file: file, line: line)
            return
        }
        XCTAssertEqual(elapsed, expectedElapsed, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(interval, expectedInterval, accuracy: 1e-12, file: file, line: line)
    }

    private func assertCadenceElapsed(_ decision: RecognitionDecision,
                                      elapsed expectedElapsed: TimeInterval,
                                      interval expectedInterval: TimeInterval,
                                      file: StaticString = #filePath, line: UInt = #line) {
        guard case .recognizeNow(.cadenceElapsed(let elapsed, let interval)) = decision else {
            XCTFail("expected .recognizeNow(.cadenceElapsed), got \(decision)", file: file, line: line)
            return
        }
        // Accuracy compare, not Equatable: the elapsed double comes out of
        // Date arithmetic and may differ from the literal by an ulp.
        XCTAssertEqual(elapsed, expectedElapsed, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(interval, expectedInterval, accuracy: 1e-12, file: file, line: line)
    }

    // MARK: - Config invariants

    func testDefaultConfigMatchesSpec() {
        let config = RecognitionCachePolicyConfig.default
        XCTAssertEqual(config.ownerRevalidationInterval, 2.5, accuracy: 1e-12)   // spec: every 2–3 s
        XCTAssertEqual(config.trustedRevalidationInterval, 2.5, accuracy: 1e-12)
        XCTAssertEqual(config.otherRevalidationInterval, 1.5, accuracy: 1e-12)   // spec: every 1–2 s
        XCTAssertEqual(config.bboxJumpRelativeThreshold, 0.35, accuracy: 1e-12)
        XCTAssertEqual(config.faceSizeChangeRatio, 0.4, accuracy: 1e-12)
        XCTAssertEqual(config.resumeAfterGapThreshold, 1.0, accuracy: 1e-12)
        XCTAssertEqual(config.ownerDowngradeConsecutiveMisses, 2)
        // Quality metric is reserved for M2-T06 and off by default.
        XCTAssertNil(config.cropQualityImprovementThreshold)
    }

    // MARK: - New track

    func testNewTrackRecognizesImmediately() {
        let track = makeTrack(identity: .other, lastIdentityCheck: nil)
        assertRecognizeNow(
            policy.decision(track: track, isNewTrack: true, now: date(0)),
            .newTrack
        )
        // Even a "fresh" identity on a brand-new track must not be trusted:
        // nothing was ever recognized for this track.
        let freshOwner = checkedOwnerTrack(lastIdentityCheck: date(-0.1))
        assertRecognizeNow(
            policy.decision(track: freshOwner, isNewTrack: true, now: date(0)),
            .newTrack
        )
    }

    func testNotNewTrackWithoutAnyCheckRecognizesNow() {
        // Defensive path: the integrator says this is not a brand-new track,
        // but recognition never completed, so there is nothing to cache-trust.
        let track = makeTrack(identity: .unknown, lastIdentityCheck: nil)
        assertRecognizeNow(
            policy.decision(track: track, isNewTrack: false, now: date(0)),
            .noCachedIdentity
        )
    }

    // MARK: - Cadence per identity state

    func testOwnerCadenceBoundary() {
        // 2.4 s < 2.5 s → still cached.
        let fresh = checkedOwnerTrack(lastIdentityCheck: date(0))
        assertWithinCadence(
            policy.decision(track: fresh, isNewTrack: false, now: date(2.4)),
            identity: .owner, elapsed: 2.4, interval: 2.5
        )
        // 2.6 s ≥ 2.5 s → revalidate.
        let stale = checkedOwnerTrack(lastIdentityCheck: date(0))
        guard case .recognizeNow(.cadenceElapsed(let elapsed, let interval)) =
            policy.decision(track: stale, isNewTrack: false, now: date(2.6)) else {
            XCTFail("owner past cadence must revalidate")
            return
        }
        XCTAssertEqual(elapsed, 2.6, accuracy: 1e-9)
        XCTAssertEqual(interval, 2.5, accuracy: 1e-12)
    }

    func testTrustedUsesOwnerCadence() {
        let fresh = makeTrack(identity: .trusted, lastIdentityCheck: date(0))
        assertWithinCadence(
            policy.decision(track: fresh, isNewTrack: false, now: date(2.4)),
            identity: .trusted, elapsed: 2.4, interval: 2.5
        )
        let stale = makeTrack(identity: .trusted, lastIdentityCheck: date(0))
        assertCadenceElapsed(
            policy.decision(track: stale, isNewTrack: false, now: date(2.6)),
            elapsed: 2.6, interval: 2.5
        )
    }

    func testOtherCadenceBoundary() {
        // 1.0 s < 1.5 s → cached.
        let fresh = makeTrack(identity: .other, lastIdentityCheck: date(0))
        assertWithinCadence(
            policy.decision(track: fresh, isNewTrack: false, now: date(1.0)),
            identity: .other, elapsed: 1.0, interval: 1.5
        )
        // 1.6 s ≥ 1.5 s → revalidate.
        let stale = makeTrack(identity: .other, lastIdentityCheck: date(0))
        assertCadenceElapsed(
            policy.decision(track: stale, isNewTrack: false, now: date(1.6)),
            elapsed: 1.6, interval: 1.5
        )
    }

    func testUnknownUsesOtherCadence() {
        // Failed initial recognition revalidates on the stranger cadence.
        let fresh = makeTrack(identity: .unknown, lastIdentityCheck: date(0))
        assertWithinCadence(
            policy.decision(track: fresh, isNewTrack: false, now: date(1.0)),
            identity: .unknown, elapsed: 1.0, interval: 1.5
        )
        let stale = makeTrack(identity: .unknown, lastIdentityCheck: date(0))
        assertCadenceElapsed(
            policy.decision(track: stale, isNewTrack: false, now: date(1.6)),
            elapsed: 1.6, interval: 1.5
        )
    }

    // MARK: - Early trigger: bounding box jump

    func testBoundingBoxJumpTriggersEarlyRevalidationWithinCadence() {
        // Owner identity cached 0.2 s ago; the face center then moved from
        // 0.2 to 0.8 of the (unit-width) frame — 0.6 > 0.35 threshold.
        let previous = CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2)
        let jumped = CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2)
        let track = makeTrack(identity: .owner,
                              boundingBox: jumped,
                              lastIdentityCheck: date(-0.2))
        guard case .recognizeNow(.boundingBoxJump(let shift, let threshold)) =
            policy.decision(track: track,
                            isNewTrack: false,
                            previousBoundingBox: previous,
                            frameWidth: 1.0,
                            now: date(0)) else {
            XCTFail("bbox jump must trigger early revalidation")
            return
        }
        XCTAssertEqual(shift, 0.6, accuracy: 1e-9)
        XCTAssertEqual(threshold, 0.35, accuracy: 1e-12)
    }

    func testVerticalCenterJumpTriggersEarlyRevalidation() {
        // Displacement is Euclidean: |dx| = 0.1, |dy| = 0.5 → 0.51 > 0.35.
        let previous = CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.2)
        let jumped = CGRect(x: 0.5, y: 0.7, width: 0.2, height: 0.2)
        let track = makeTrack(identity: .owner,
                              boundingBox: jumped,
                              lastIdentityCheck: date(-0.2))
        guard case .recognizeNow(.boundingBoxJump(let shift, _)) =
            policy.decision(track: track,
                            isNewTrack: false,
                            previousBoundingBox: previous,
                            frameWidth: 1.0,
                            now: date(0)) else {
            XCTFail("vertical center jump must trigger early revalidation")
            return
        }
        // Expected: Euclidean center displacement from the two rects.
        let dx = jumped.midX - previous.midX
        let dy = jumped.midY - previous.midY
        XCTAssertEqual(shift, (dx * dx + dy * dy).squareRoot(), accuracy: 1e-9)
        XCTAssertGreaterThan(shift, 0.35)
    }

    func testSmallBboxShiftStaysCached() {
        // Center moved 0.15 < 0.35 → no early trigger, cadence applies.
        let previous = CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.2)
        let current = CGRect(x: 0.35, y: 0.4, width: 0.2, height: 0.2)
        let track = makeTrack(identity: .owner,
                              boundingBox: current,
                              lastIdentityCheck: date(-0.2))
        assertWithinCadence(
            policy.decision(track: track,
                            isNewTrack: false,
                            previousBoundingBox: previous,
                            frameWidth: 1.0,
                            now: date(0)),
            identity: .owner, elapsed: 0.2, interval: 2.5
        )
    }

    func testBboxJumpTriggerNeedsFrameWidth() {
        // Without a frame width the jump trigger is undefined, so it is
        // skipped (the size trigger, being self-relative, still applies).
        let previous = CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2)
        let jumped = CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2)
        let track = makeTrack(identity: .owner,
                              boundingBox: jumped,
                              lastIdentityCheck: date(-0.2))
        assertWithinCadence(
            policy.decision(track: track,
                            isNewTrack: false,
                            previousBoundingBox: previous,
                            frameWidth: nil,
                            now: date(0)),
            identity: .owner, elapsed: 0.2, interval: 2.5
        )
    }

    // MARK: - Early trigger: face size change

    func testFaceSizeGrowthTriggersEarlyRevalidation() {
        // Width 0.2 → 0.32: |log(1.6)| ≈ 0.47 > 0.4 → recheck.
        let previous = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let grown = CGRect(x: 0.34, y: 0.34, width: 0.32, height: 0.32)
        let track = makeTrack(identity: .owner,
                              boundingBox: grown,
                              lastIdentityCheck: date(-0.2))
        guard case .recognizeNow(.faceSizeChange(let ratio, let threshold)) =
            policy.decision(track: track,
                            isNewTrack: false,
                            previousBoundingBox: previous,
                            frameWidth: 1.0,
                            now: date(0)) else {
            XCTFail("face size growth must trigger early revalidation")
            return
        }
        XCTAssertEqual(ratio, abs(log(CGFloat(0.32) / CGFloat(0.2))), accuracy: 1e-9)
        XCTAssertEqual(threshold, 0.4, accuracy: 1e-12)
    }

    func testFaceSizeShrinkTriggersEarlyRevalidation() {
        // Width 0.2 → 0.1: |log(0.5)| ≈ 0.69 > 0.4 — shrinking counts too.
        let previous = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let shrunk = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        let track = makeTrack(identity: .owner,
                              boundingBox: shrunk,
                              lastIdentityCheck: date(-0.2))
        guard case .recognizeNow(.faceSizeChange(let ratio, _)) =
            policy.decision(track: track,
                            isNewTrack: false,
                            previousBoundingBox: previous,
                            now: date(0)) else {
            XCTFail("face size shrink must trigger early revalidation")
            return
        }
        XCTAssertEqual(ratio, abs(log(CGFloat(0.5))), accuracy: 1e-9)
    }

    func testSmallFaceSizeChangeStaysCached() {
        // Width 0.2 → 0.24: |log(1.2)| ≈ 0.18 < 0.4 → cadence applies.
        let previous = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let current = CGRect(x: 0.38, y: 0.38, width: 0.24, height: 0.24)
        let track = makeTrack(identity: .owner,
                              boundingBox: current,
                              lastIdentityCheck: date(-0.2))
        assertWithinCadence(
            policy.decision(track: track,
                            isNewTrack: false,
                            previousBoundingBox: previous,
                            frameWidth: 1.0,
                            now: date(0)),
            identity: .owner, elapsed: 0.2, interval: 2.5
        )
    }

    // MARK: - Early trigger: resume after gap

    func testResumeAfterGapTriggersImmediateRevalidation() {
        // Identity was checked 0.2 s before the track vanished; it resumed
        // 1.5 s later (≥ 1.0 s threshold) → recheck despite the fresh check.
        let track = checkedOwnerTrack(lastIdentityCheck: date(-0.2))
        assertRecognizeNow(
            policy.decision(track: track, isNewTrack: false, unseenDuration: 1.5, now: date(0)),
            .resumedAfterGap(unseen: 1.5, threshold: 1.0)
        )
    }

    func testShortGapStillUsesCadence() {
        // 0.5 s unseen is below the 1.0 s threshold → normal cadence path.
        let track = checkedOwnerTrack(lastIdentityCheck: date(-0.2))
        assertWithinCadence(
            policy.decision(track: track, isNewTrack: false, unseenDuration: 0.5, now: date(0)),
            identity: .owner, elapsed: 0.2, interval: 2.5
        )
    }

    // MARK: - Hysteresis (owner downgrade)

    func testOwnerDowngradeRequiresConsecutiveMisses() {
        // Default: a stable owner needs 2 consecutive failed revalidations
        // before demotion is allowed; a single miss must not flip identity.
        XCTAssertFalse(policy.allowsOwnerDowngrade(0))
        XCTAssertFalse(policy.allowsOwnerDowngrade(1))
        XCTAssertTrue(policy.allowsOwnerDowngrade(2))
        XCTAssertTrue(policy.allowsOwnerDowngrade(3))
    }

    func testOwnerDowngradeThresholdIsConfigurable() {
        var config = RecognitionCachePolicyConfig.default
        config.ownerDowngradeConsecutiveMisses = 3
        let stricter = RecognitionCachePolicy(config: config)
        XCTAssertFalse(stricter.allowsOwnerDowngrade(2))
        XCTAssertTrue(stricter.allowsOwnerDowngrade(3))
    }

    // MARK: - Debug logging

    func testReasonDescriptionsAreNonEmpty() {
        let reasons: [RecognitionReason] = [
            .newTrack,
            .noCachedIdentity,
            .resumedAfterGap(unseen: 1.5, threshold: 1.0),
            .boundingBoxJump(centerShiftFraction: 0.6, threshold: 0.35),
            .faceSizeChange(logSizeRatio: 0.47, threshold: 0.4),
            .cadenceElapsed(elapsed: 2.6, interval: 2.5),
            .withinCadence(elapsed: 0.2, interval: 2.5)
        ]
        for reason in reasons {
            XCTAssertFalse(reason.description.isEmpty, "\(reason) must describe itself")
        }
        // The description names the quantity that fired, for M2-T07 logs.
        XCTAssertTrue(RecognitionReason.boundingBoxJump(centerShiftFraction: 0.6, threshold: 0.35)
            .description.contains("bbox"))
        XCTAssertTrue(RecognitionReason.cadenceElapsed(elapsed: 2.6, interval: 2.5)
            .description.contains("cadence"))
    }
}
