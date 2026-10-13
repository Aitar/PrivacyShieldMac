import XCTest
@testable import PrivacyShieldCore

/// Deterministic tests for the global shoulder-surf aggregation rule (M2-T04).
///
/// Pure logic only: no camera, no Vision, no wall clock. The aggregator maps
/// per-track `(trackID, identity, isAlerting)` observations to the single
/// global alert. The per-track temporal behavior that PRODUCES the
/// `isAlerting` flags is covered by `TemporalAttentionFilterTests`; here the
/// flags are inputs, so the acceptance "stranger A's 0.5 s + stranger B's
/// 0.5 s never becomes 1.0 s" reduces to independent per-track flags
/// combined with OR over qualifying observers only.
final class ShoulderSurfAggregatorTests: XCTestCase {

    private let idA = UUID()
    private let idB = UUID()
    private let idOwner = UUID()

    private func obs(_ id: UUID, _ identity: IdentityState, _ alerting: Bool) -> ShoulderSurfAggregator.TrackObservation {
        return ShoulderSurfAggregator.TrackObservation(trackID: id, identity: identity, isAlerting: alerting)
    }

    // MARK: - Qualifying-observer rules

    func testQualifyingObserverRules() {
        // Trusted-level identities never qualify as observers.
        XCTAssertFalse(ShoulderSurfAggregator.isQualifyingObserver(.owner))
        XCTAssertFalse(ShoulderSurfAggregator.isQualifyingObserver(.trusted))
        // Non-trusted identities qualify: recognized strangers AND tracks
        // not yet recognized.
        XCTAssertTrue(ShoulderSurfAggregator.isQualifyingObserver(.other))
        XCTAssertTrue(ShoulderSurfAggregator.isQualifyingObserver(.unknown))
    }

    // MARK: - Single-track decisions

    func testEmptyObservationsNeverAlert() {
        XCTAssertFalse(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([]))
    }

    func testSingleOtherTrackAlertingRaisesAlert() {
        XCTAssertTrue(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([
            obs(idA, .other, true)
        ]))
    }

    func testUnknownTrackAlertingRaisesAlert() {
        // A brand-new track (identity .unknown until its first recognition
        // pass) must already count as a potential observer.
        XCTAssertTrue(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([
            obs(idA, .unknown, true)
        ]))
    }

    func testNonAlertingQualifyingTrackDoesNotRaiseAlert() {
        XCTAssertFalse(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([
            obs(idA, .other, false),
            obs(idB, .unknown, false)
        ]))
    }

    // MARK: - Trusted identities are ignored

    func testOnlyOwnerAlertingDoesNotRaiseAlert() {
        XCTAssertFalse(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([
            obs(idOwner, .owner, true)
        ]))
    }

    func testOnlyTrustedAlertingDoesNotRaiseAlert() {
        XCTAssertFalse(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([
            obs(idA, .trusted, true)
        ]))
    }

    func testOwnerAlertingAlongsideOtherAlertingStillRaises() {
        // The owner's own filter state is irrelevant; the stranger decides.
        XCTAssertTrue(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([
            obs(idOwner, .owner, true),
            obs(idA, .other, true)
        ]))
    }

    func testOwnerAlertingAlongsideQuietOtherDoesNotRaise() {
        XCTAssertFalse(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([
            obs(idOwner, .owner, true),
            obs(idA, .other, false)
        ]))
    }

    // MARK: - Multi-person persistence (M2-T04 acceptance)

    func testAlertHoldsUntilLastQualifyingTrackClears() {
        // Frame t1: stranger A alerting, stranger B not yet → shield on.
        var frame = [obs(idA, .other, true), obs(idB, .other, false)]
        XCTAssertTrue(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting(frame))

        // Frame t2: A's own filter releases while B's rises → the global
        // alert MUST persist (A's 0.5 s + B's 0.5 s never merge into one
        // timer, and one clearing never hides the shield while the other
        // still qualifies).
        frame = [obs(idA, .other, false), obs(idB, .other, true)]
        XCTAssertTrue(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting(frame))

        // Frame t3: every qualifying track cleared → shield hides.
        frame = [obs(idA, .other, false), obs(idB, .other, false)]
        XCTAssertFalse(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting(frame))
    }

    func testExpiredTrackDroppingOutKeepsAlertWhileAnotherQualifies() {
        // Two qualifying alerting tracks.
        XCTAssertTrue(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([
            obs(idA, .other, true),
            obs(idB, .unknown, true)
        ]))

        // A's track expires and simply disappears from the observation list;
        // B alone still holds the alert.
        XCTAssertTrue(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([
            obs(idB, .unknown, true)
        ]))

        // B expires too → no qualifying track remains → release.
        XCTAssertFalse(ShoulderSurfAggregator.isAnyQualifyingTrackAlerting([]))
    }
}
