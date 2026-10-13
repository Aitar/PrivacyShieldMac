import XCTest
@testable import PrivacyShieldCore

/// M4-T04: pure display-state formatting and the notification anti-spam gate.
///
/// No AppKit, no UNUserNotificationCenter, no wall clock — the gate's `now`
/// is an injected, explicitly aged instant. The live menu/notification paths
/// in `AppDelegate` are thin wrappers around these pure pieces.
final class StatusTextTests: XCTestCase {

    /// Fixed reference instant; nothing in this suite reads the real clock.
    /// `t(seconds)` returns instants `seconds` after it.
    private let reference = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func t(_ seconds: TimeInterval) -> Date {
        reference.addingTimeInterval(seconds)
    }

    private let allStates: [PrivacyDisplayState] = [
        .monitoringSafe, .ownerAbsent, .shoulderSurferDetected,
        .bothPoliciesActive, .calibrating, .cameraUnavailable
    ]

    // MARK: - Status text: full coverage of the display states

    func testStatusTextCoversAllStates() {
        XCTAssertEqual(PrivacyDisplayState.monitoringSafe.statusText, "Status: ✅ Monitoring safe")
        XCTAssertEqual(PrivacyDisplayState.ownerAbsent.statusText, "Status: 🚪 Owner away — blurred")
        XCTAssertEqual(PrivacyDisplayState.shoulderSurferDetected.statusText, "Status: 👀 Observer detected — blurred")
        XCTAssertEqual(PrivacyDisplayState.bothPoliciesActive.statusText, "Status: ⚠️ Owner away + observer — blurred")
        XCTAssertEqual(PrivacyDisplayState.calibrating.statusText, "Status: 🎯 Calibrating…")
        XCTAssertEqual(PrivacyDisplayState.cameraUnavailable.statusText, "Status: 📷 Camera unavailable")
    }

    func testStatusTextsAreDistinctPerState() {
        let texts = Set(allStates.map(\.statusText))
        XCTAssertEqual(texts.count, allStates.count)
    }

    func testShieldShownExactlyForBlurStates() {
        XCTAssertFalse(PrivacyDisplayState.monitoringSafe.isShieldShown)
        XCTAssertFalse(PrivacyDisplayState.calibrating.isShieldShown)
        XCTAssertFalse(PrivacyDisplayState.cameraUnavailable.isShieldShown)
        XCTAssertTrue(PrivacyDisplayState.ownerAbsent.isShieldShown)
        XCTAssertTrue(PrivacyDisplayState.shoulderSurferDetected.isShieldShown)
        XCTAssertTrue(PrivacyDisplayState.bothPoliciesActive.isShieldShown)
    }

    // MARK: - Notification content per reason

    func testNotificationBodiesPerReason() {
        XCTAssertEqual(PrivacyShieldReason.shoulderSurfer.notificationBody,
                       "Someone appears to be looking at your screen. Screen has been blurred.")
        XCTAssertEqual(PrivacyShieldReason.ownerAbsent.notificationBody,
                       "You stepped away — screen has been blurred.")
        XCTAssertEqual(PrivacyShieldReason.both.notificationBody,
                       "Owner away and someone is looking at your screen. Screen has been blurred.")
        // The hidden state never notifies.
        XCTAssertNil(PrivacyShieldReason.none.notificationBody)
    }

    // MARK: - Display state → notification reason

    func testDisplayStateToNotificationReason() {
        // Safe / detector-side states never notify.
        XCTAssertNil(PrivacyDisplayState.monitoringSafe.notificationReason)
        XCTAssertNil(PrivacyDisplayState.calibrating.notificationReason)
        XCTAssertNil(PrivacyDisplayState.cameraUnavailable.notificationReason)
        // Blur states map 1:1 onto the reason cases.
        XCTAssertEqual(PrivacyDisplayState.ownerAbsent.notificationReason, .ownerAbsent)
        XCTAssertEqual(PrivacyDisplayState.shoulderSurferDetected.notificationReason, .shoulderSurfer)
        XCTAssertEqual(PrivacyDisplayState.bothPoliciesActive.notificationReason, .both)
    }

    // MARK: - NotificationGate: episode lifecycle

    func testGateDefaultInterval() {
        XCTAssertEqual(NotificationGate().minUpdateInterval, 10)
    }

    func testGateSendsFirstReasonOfFreshEpisode() {
        var gate = NotificationGate()
        XCTAssertTrue(gate.shouldSend(for: .ownerAbsent, at: t(0)))
        XCTAssertTrue(gate.isEpisodeActive)
    }

    func testGateDedupsSameReasonWithinEpisode() {
        var gate = NotificationGate()
        XCTAssertTrue(gate.shouldSend(for: .ownerAbsent, at: t(0)))
        // Same reason again, long after the interval: still deduped.
        XCTAssertFalse(gate.shouldSend(for: .ownerAbsent, at: t(60)))
        XCTAssertFalse(gate.shouldSend(for: .ownerAbsent, at: t(600)))
    }

    func testGateAllowsOneUpdatePerNewReasonThenDedups() {
        var gate = NotificationGate()
        XCTAssertTrue(gate.shouldSend(for: .ownerAbsent, at: t(0)))
        // Reason change after the min interval: exactly one update…
        XCTAssertTrue(gate.shouldSend(for: .shoulderSurfer, at: t(11)))
        // …the new reason is then deduped like any other…
        XCTAssertFalse(gate.shouldSend(for: .shoulderSurfer, at: t(30)))
        // …and a reason already sent this episode is never re-notified.
        XCTAssertFalse(gate.shouldSend(for: .ownerAbsent, at: t(40)))
    }

    func testGateBlocksReasonChangeInsideMinInterval() {
        var gate = NotificationGate(minUpdateInterval: 10)
        XCTAssertTrue(gate.shouldSend(for: .ownerAbsent, at: t(0)))
        // Different reason but too soon: dropped, and it consumes nothing.
        XCTAssertFalse(gate.shouldSend(for: .shoulderSurfer, at: t(5)))
        // Once the interval from the last actual send has elapsed, the new
        // reason may still fire its single update.
        XCTAssertTrue(gate.shouldSend(for: .shoulderSurfer, at: t(10)))
        XCTAssertFalse(gate.shouldSend(for: .shoulderSurfer, at: t(20)))
    }

    func testGateNoneNeverSendsAndClosesEpisode() {
        var gate = NotificationGate()
        XCTAssertTrue(gate.shouldSend(for: .both, at: t(0)))
        XCTAssertFalse(gate.shouldSend(for: .none, at: t(1)))
        XCTAssertFalse(gate.isEpisodeActive)
        // New episode after the shield hid: the same reason notifies again.
        XCTAssertTrue(gate.shouldSend(for: .both, at: t(2)))
    }

    func testGateNewEpisodeIgnoresPreviousEpisodeInterval() {
        var gate = NotificationGate()
        XCTAssertTrue(gate.shouldSend(for: .ownerAbsent, at: t(0)))
        gate.endEpisode()
        // Episode's first send is never interval-checked, even right after
        // the previous episode's last send.
        XCTAssertTrue(gate.shouldSend(for: .ownerAbsent, at: t(0.5)))
    }

    func testGateExplicitEndEpisodeResetsState() {
        var gate = NotificationGate()
        XCTAssertTrue(gate.shouldSend(for: .shoulderSurfer, at: t(0)))
        gate.endEpisode()
        XCTAssertFalse(gate.isEpisodeActive)
        XCTAssertTrue(gate.notifiedReasons.isEmpty)
        XCTAssertNil(gate.lastSendDate)
    }

    func testGateTracksMixedReasonSequenceInOneEpisode() {
        var gate = NotificationGate()
        // ownerAbsent → shoulderSurfer → both, each new reason exactly once.
        XCTAssertTrue(gate.shouldSend(for: .ownerAbsent, at: t(0)))
        XCTAssertFalse(gate.shouldSend(for: .shoulderSurfer, at: t(3)))   // too soon
        XCTAssertTrue(gate.shouldSend(for: .shoulderSurfer, at: t(12)))
        XCTAssertFalse(gate.shouldSend(for: .both, at: t(15)))            // too soon
        XCTAssertTrue(gate.shouldSend(for: .both, at: t(25)))
        // Every blur reason has now been sent this episode.
        XCTAssertFalse(gate.shouldSend(for: .ownerAbsent, at: t(100)))
        XCTAssertFalse(gate.shouldSend(for: .shoulderSurfer, at: t(100)))
        XCTAssertFalse(gate.shouldSend(for: .both, at: t(100)))
    }
}
