import XCTest
@testable import PrivacyShieldCore

/// Deterministic tests for the independent privacy policies (M4-T03).
///
/// Pure logic only: no camera, no Vision, no wall clock — `now` is a fixed
/// constant and every track snapshot is hand-built from an explicit age. The
/// temporal behavior that PRODUCES the inputs (per-track alert filters,
/// `ShoulderSurfAggregator`, recognition) is covered elsewhere; here raw
/// booleans and `(identity, lastSeen)` snapshots are the inputs.
final class PrivacyStateMachineTests: XCTestCase {

    /// Fixed reference instant; nothing in this suite reads the real clock.
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private let defaultWindow: TimeInterval = 1.5

    /// A track snapshot last seen `age` seconds before `now`.
    private func track(_ identity: IdentityState, age: TimeInterval) -> (identity: IdentityState, lastSeen: Date) {
        return (identity, now.addingTimeInterval(-age))
    }

    private func makeMachine(blurWhenOwnerAbsent: Bool = true,
                             blurWhenShoulderSurferDetected: Bool = true) -> PrivacyStateMachine {
        var config = PrivacyStateMachineConfig.default
        config.blurWhenOwnerAbsent = blurWhenOwnerAbsent
        config.blurWhenShoulderSurferDetected = blurWhenShoulderSurferDetected
        return PrivacyStateMachine(config: config)
    }

    // MARK: - Default config (X-T01: knobs in one place)

    func testDefaultConfigValues() {
        let config = PrivacyStateMachineConfig.default
        XCTAssertTrue(config.blurWhenOwnerAbsent)
        XCTAssertTrue(config.blurWhenShoulderSurferDetected)
        XCTAssertEqual(config.ownerPresenceWindow, 1.5)
        // A default-constructed machine uses the default config.
        XCTAssertTrue(PrivacyStateMachine().config.blurWhenOwnerAbsent)
        XCTAssertTrue(PrivacyStateMachine().config.blurWhenShoulderSurferDetected)
    }

    // MARK: - Shield decision: neither policy active

    func testOwnerPresentNoSurferShowsNothing() {
        // The owner sitting at the screen never blurs, regardless of config.
        XCTAssertEqual(makeMachine().evaluate(ownerPresent: true, shoulderSurferDetected: false), .none)
        XCTAssertEqual(makeMachine(blurWhenOwnerAbsent: false).evaluate(ownerPresent: true, shoulderSurferDetected: false), .none)
        XCTAssertEqual(makeMachine(blurWhenShoulderSurferDetected: false).evaluate(ownerPresent: true, shoulderSurferDetected: false), .none)
        XCTAssertEqual(makeMachine(blurWhenOwnerAbsent: false, blurWhenShoulderSurferDetected: false).evaluate(ownerPresent: true, shoulderSurferDetected: false), .none)
    }

    func testOwnerAbsentBlursByDefault() {
        let reason = makeMachine().evaluate(ownerPresent: false, shoulderSurferDetected: false)
        XCTAssertEqual(reason, .ownerAbsent)
        XCTAssertTrue(reason.isShieldShown)
    }

    func testOwnerAbsentWithoutOwnerBlurToggleShowsNothing() {
        // Owner-away blur disabled and no surfer → nothing justifies a blur.
        let reason = makeMachine(blurWhenOwnerAbsent: false).evaluate(ownerPresent: false, shoulderSurferDetected: false)
        XCTAssertEqual(reason, .none)
        XCTAssertFalse(reason.isShieldShown)
    }

    // MARK: - Shield decision: shoulder-surf policy only

    func testSurferBlursEvenWhenOwnerPresent() {
        // Plan §14: an unknown person LOOKING blurs the screen even while the
        // owner is present.
        let reason = makeMachine().evaluate(ownerPresent: true, shoulderSurferDetected: true)
        XCTAssertEqual(reason, .shoulderSurfer)
        XCTAssertTrue(reason.isShieldShown)
    }

    func testSurferWithoutSurfBlurToggleShowsNothingWhenOwnerPresent() {
        let reason = makeMachine(blurWhenShoulderSurferDetected: false).evaluate(ownerPresent: true, shoulderSurferDetected: true)
        XCTAssertEqual(reason, .none)
        XCTAssertFalse(reason.isShieldShown)
    }

    // MARK: - Shield decision: both policies active (precedence)

    func testOwnerAbsentAndSurferYieldsBoth() {
        let reason = makeMachine().evaluate(ownerPresent: false, shoulderSurferDetected: true)
        XCTAssertEqual(reason, .both)
        XCTAssertTrue(reason.isShieldShown)
    }

    func testBothTogglesOffShowsNothingEvenWithSurfer() {
        let reason = makeMachine(blurWhenOwnerAbsent: false, blurWhenShoulderSurferDetected: false)
            .evaluate(ownerPresent: false, shoulderSurferDetected: true)
        XCTAssertEqual(reason, .none)
        XCTAssertFalse(reason.isShieldShown)
    }

    func testReasonOnlyReportsActivelyDemandingPolicies() {
        // Owner absent + alerting surfer, but the surfer toggle is off: only
        // the owner-absent policy demands a blur, so the reason must say
        // .ownerAbsent — never .both (M4-T04 consumes the reason to explain
        // WHY the shield is up).
        XCTAssertEqual(makeMachine(blurWhenShoulderSurferDetected: false)
            .evaluate(ownerPresent: false, shoulderSurferDetected: true), .ownerAbsent)
        // Mirror image: surfer toggle on, owner-away toggle off, owner
        // absent + surfer → only the surfer policy demands the blur.
        XCTAssertEqual(makeMachine(blurWhenOwnerAbsent: false)
            .evaluate(ownerPresent: false, shoulderSurferDetected: true), .shoulderSurfer)
    }

    // MARK: - PrivacyState convenience + behavior mapping

    func testPrivacyStateConvenienceMatchesExplicitInputs() {
        let machine = makeMachine()
        XCTAssertEqual(machine.evaluate(PrivacyState(ownerPresent: true, shoulderSurferDetected: false)), .none)
        XCTAssertEqual(machine.evaluate(PrivacyState(ownerPresent: false, shoulderSurferDetected: false)), .ownerAbsent)
        XCTAssertEqual(machine.evaluate(PrivacyState(ownerPresent: true, shoulderSurferDetected: true)), .shoulderSurfer)
        XCTAssertEqual(machine.evaluate(PrivacyState(ownerPresent: false, shoulderSurferDetected: true)), .both)
    }

    func testShieldShownMapping() {
        // .none = hidden; everything else = shown (single source of truth).
        XCTAssertFalse(PrivacyShieldReason.none.isShieldShown)
        XCTAssertTrue(PrivacyShieldReason.ownerAbsent.isShieldShown)
        XCTAssertTrue(PrivacyShieldReason.shoulderSurfer.isShieldShown)
        XCTAssertTrue(PrivacyShieldReason.both.isShieldShown)
    }

    // MARK: - End-to-end scenario: unknown present but NOT looking (plan §14)

    func testUnknownPresentButNotLookingWithOwnerPresentShowsNothing() {
        // Owner at the screen, a stranger in frame who is NOT looking
        // (surfer=false): no shoulder-surf blur, no owner-absent blur.
        let tracks = [track(.owner, age: 0), track(.other, age: 0)]
        let ownerPresent = OwnerPresencePolicy.ownerPresent(
            in: tracks, now: now, presenceWindow: defaultWindow)
        XCTAssertTrue(ownerPresent)

        let reason = makeMachine().evaluate(
            PrivacyState(ownerPresent: ownerPresent, shoulderSurferDetected: false))
        XCTAssertEqual(reason, .none)
    }

    func testUnknownPresentButNotLookingWhileOwnerAwayBlursAsOwnerAbsent() {
        // The stranger's presence never keeps the screen "safe": with the
        // owner gone, the owner-absent policy blurs (default config). This is
        // the deliberate split from the legacy "no face at all" rule, which
        // could not express "stranger here, owner gone".
        let tracks = [track(.other, age: 0), track(.unknown, age: 0)]
        XCTAssertFalse(OwnerPresencePolicy.ownerPresent(
            in: tracks, now: now, presenceWindow: defaultWindow))

        XCTAssertEqual(makeMachine().evaluate(
            PrivacyState(ownerPresent: false, shoulderSurferDetected: false)), .ownerAbsent)
    }

    // MARK: - OwnerPresencePolicy: identity rules

    func testEmptyTracksMeanOwnerAbsent() {
        XCTAssertFalse(OwnerPresencePolicy.ownerPresent(
            in: [], now: now, presenceWindow: defaultWindow))
    }

    func testFreshOwnerTrackEstablishesPresence() {
        XCTAssertTrue(OwnerPresencePolicy.ownerPresent(
            in: [track(.owner, age: 0)], now: now, presenceWindow: defaultWindow))
    }

    func testTrustedTrackEstablishesPresence() {
        // .trusted is a trusted-level identity, same split as the
        // shoulder-surf aggregator's non-observer set.
        XCTAssertTrue(OwnerPresencePolicy.ownerPresent(
            in: [track(.trusted, age: 0)], now: now, presenceWindow: defaultWindow))
    }

    func testStrangerAndUnrecognizedTracksNeverEstablishPresence() {
        // A recognized stranger, and a brand-new track that has not been
        // recognized yet (`.unknown`), must not suppress the owner-away blur.
        XCTAssertFalse(OwnerPresencePolicy.ownerPresent(
            in: [track(.other, age: 0)], now: now, presenceWindow: defaultWindow))
        XCTAssertFalse(OwnerPresencePolicy.ownerPresent(
            in: [track(.unknown, age: 0)], now: now, presenceWindow: defaultWindow))
    }

    func testFreshOwnerAmongStaleTracksKeepsPresence() {
        // Presence needs ONE fresh trusted snapshot; stale ones are ignored.
        XCTAssertTrue(OwnerPresencePolicy.ownerPresent(
            in: [track(.owner, age: 5.0), track(.owner, age: 0)],
            now: now, presenceWindow: defaultWindow))
    }

    // MARK: - OwnerPresencePolicy: window semantics

    func testLastSeenExactlyAtWindowEdgeCountsAsPresent() {
        // INCLUSIVE at the edge (documented in OwnerPresencePolicy): age ==
        // window still counts, mirroring FaceTracker's expiry comparison.
        XCTAssertTrue(OwnerPresencePolicy.ownerPresent(
            in: [track(.owner, age: defaultWindow)], now: now, presenceWindow: defaultWindow))
    }

    func testLastSeenBeyondWindowIsAbsent() {
        XCTAssertFalse(OwnerPresencePolicy.ownerPresent(
            in: [track(.owner, age: defaultWindow + 0.001)], now: now, presenceWindow: defaultWindow))
        // Far beyond the window, even with other content in frame.
        XCTAssertFalse(OwnerPresencePolicy.ownerPresent(
            in: [track(.owner, age: 60.0), track(.other, age: 0)],
            now: now, presenceWindow: defaultWindow))
    }

    func testFutureLastSeenCountsAsPresent() {
        // Negative age (a snapshot stamped after `now`) is trivially within
        // any non-negative window.
        let future = (identity: IdentityState.owner, lastSeen: now.addingTimeInterval(0.5))
        XCTAssertTrue(OwnerPresencePolicy.ownerPresent(
            in: [future], now: now, presenceWindow: defaultWindow))
    }

    func testZeroWindowOnlyAcceptsTracksSeenNowOrLater() {
        XCTAssertTrue(OwnerPresencePolicy.ownerPresent(
            in: [track(.owner, age: 0)], now: now, presenceWindow: 0))
        XCTAssertFalse(OwnerPresencePolicy.ownerPresent(
            in: [track(.owner, age: 0.001)], now: now, presenceWindow: 0))
    }

    func testStaleOwnerTrackDrivesOwnerAbsentDecisionEndToEnd() {
        // Beyond the window the owner counts as absent → default config
        // blurs with reason .ownerAbsent even though a stranger is around.
        let tracks = [track(.owner, age: defaultWindow + 0.001), track(.other, age: 0)]
        let ownerPresent = OwnerPresencePolicy.ownerPresent(
            in: tracks, now: now, presenceWindow: defaultWindow)
        XCTAssertFalse(ownerPresent)

        let machine = makeMachine()
        XCTAssertEqual(machine.evaluate(
            PrivacyState(ownerPresent: ownerPresent, shoulderSurferDetected: false)), .ownerAbsent)
        // ...and an alerting stranger on top of that composes to .both.
        XCTAssertEqual(machine.evaluate(
            PrivacyState(ownerPresent: ownerPresent, shoulderSurferDetected: true)), .both)
    }
}
