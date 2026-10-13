import XCTest
@testable import PrivacyShieldCore

/// Deterministic temporal-filter tests (M1-T07): no camera, no wall clock —
/// every update gets an injected `Date` built from a fixed base, so all
/// traces below are exact.
///
/// Traces use the default `AttentionTimingConfig`:
/// trigger 0.9 s, release 0.6 s, uncertain grace 0.35 s, delta clamp 0.5 s.
///
/// Timing assertions keep a ±0.1 s (one sample) margin around exact
/// thresholds: per-sample deltas are floating-point sums of 0.1 s intervals,
/// so an accumulation that lands exactly on a threshold may cross it on this
/// or the next sample. Margins stay far away from the behaviors under test
/// (e.g. a held 0.7 s accumulation alerts within ~0.2 s of resuming, while a
/// reset one needs a full 0.9 s).
final class TemporalAttentionFilterTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 100.0)

    private func date(_ offsetSeconds: TimeInterval) -> Date {
        return start.addingTimeInterval(offsetSeconds)
    }

    // MARK: - Config invariants

    func testDefaultConfigMatchesM1Prototype() {
        let config = AttentionTimingConfig()
        XCTAssertEqual(config.triggerDuration, 0.9, accuracy: 1e-12)
        XCTAssertEqual(config.releaseDuration, 0.6, accuracy: 1e-12)
        XCTAssertEqual(config.uncertainGrace, 0.35, accuracy: 1e-12)
        // The clamp must stay below the trigger so a single update can
        // never alert on its own.
        XCTAssertLessThan(config.maxDelta, config.triggerDuration)
    }

    // MARK: - Short glance never alerts

    func testShortGlanceNeverAlerts() {
        let filter = TemporalAttentionFilter()
        // 0.4 s glance, sampled every 0.1 s → accumulation peaks at 0.4 s,
        // far below the 0.9 s trigger.
        var t: TimeInterval = 0
        while t <= 0.4 {
            XCTAssertFalse(filter.update(.looking, at: date(t)))
            t += 0.1
        }
        // Glance ends: the pending accumulation resets immediately.
        XCTAssertFalse(filter.update(.notLooking, at: date(0.5)))
        XCTAssertFalse(filter.update(.notLooking, at: date(0.6)))
        XCTAssertFalse(filter.isAlerting)
        XCTAssertEqual(filter.accumulatedLookingTime, 0.0, accuracy: 1e-9)
    }

    // MARK: - Sustained looking triggers

    func testSustainedLookingAlertsAtTriggerDuration() {
        let filter = TemporalAttentionFilter()
        // 0.8 s of looking must NOT alert yet (margin: 0.8 << 0.9).
        for step in 0..<9 {
            XCTAssertFalse(filter.update(.looking, at: date(Double(step) * 0.1)))
        }
        // Reaching ~0.9 s alerts within one 0.1 s sample of the threshold;
        // it never takes longer than 1.0 s of sustained looking.
        var alertAt: TimeInterval?
        var t = 0.9
        while t <= 2.0 && alertAt == nil {
            if filter.update(.looking, at: date(t)) { alertAt = t }
            t += 0.1
        }
        let alertTime = alertAt ?? -1
        XCTAssertGreaterThanOrEqual(alertTime, 0.9)
        XCTAssertLessThanOrEqual(alertTime, 1.0)
        XCTAssertTrue(filter.isAlerting)
    }

    // MARK: - Short uncertain gap holds (pauses), does not reset

    func testShortUncertainGapHoldsAccumulationAndStillAlerts() {
        let filter = TemporalAttentionFilter()
        // 0.7 s of looking (updates every 0.1 s, first update credits 0).
        for step in 0..<8 {
            XCTAssertFalse(filter.update(.looking, at: date(Double(step) * 0.1)))
        }
        XCTAssertEqual(filter.accumulatedLookingTime, 0.7, accuracy: 1e-9)

        // 0.2 s of uncertain (inside the 0.35 s grace): accumulation pauses
        // but is not reset.
        filter.update(.uncertain, at: date(0.8))
        filter.update(.uncertain, at: date(0.9))
        XCTAssertFalse(filter.isAlerting)
        XCTAssertEqual(filter.accumulatedLookingTime, 0.7, accuracy: 1e-9)

        // Looking resumes: with the gap held, only ~0.2 s more is needed,
        // so the alert must arrive within 0.4 s of resuming. A reset would
        // require a full 0.9 s re-accumulation instead.
        var alertAt: TimeInterval?
        var t = 1.0
        while t <= 4.0 && alertAt == nil {
            if filter.update(.looking, at: date(t)) { alertAt = t }
            t += 0.1
        }
        let alertOffset = (alertAt ?? -1) - 1.0
        XCTAssertGreaterThanOrEqual(alertOffset, 0.1)
        XCTAssertLessThanOrEqual(alertOffset, 0.4, "accumulation must have been held, not reset")
    }

    // MARK: - Uncertain beyond the grace resets pending accumulation

    func testUncertainBeyondGraceResetsPendingAccumulation() {
        let filter = TemporalAttentionFilter()
        // 0.7 s of looking.
        for step in 0..<8 {
            _ = filter.update(.looking, at: date(Double(step) * 0.1))
        }

        // Uncertain run longer than the 0.35 s grace (samples every 0.1 s on
        // an index-based grid so no sample is skipped): elapsed since the
        // gap started is 0.1 / 0.2 / 0.3 → hold; 0.4 → treat as notLooking
        // and reset.
        for step in 8...14 {
            XCTAssertFalse(filter.update(.uncertain, at: date(Double(step) * 0.1)))
        }
        XCTAssertEqual(filter.accumulatedLookingTime, 0.0, accuracy: 1e-9)

        // From zero again, a full triggerDuration of looking is required:
        // the alert must arrive ~0.9 s after resuming (2.3–2.4 s), NOT on
        // the first resumed updates (~1.6 s) as it would if the old 0.7 s
        // accumulation had survived the gap.
        var reAlertedAt: TimeInterval?
        for step in 15...40 where reAlertedAt == nil {
            if filter.update(.looking, at: date(Double(step) * 0.1)) {
                reAlertedAt = Double(step) * 0.1
            }
        }
        let reAlertOffset = (reAlertedAt ?? -1) - 1.5
        XCTAssertGreaterThanOrEqual(reAlertOffset, 0.8, "the pending accumulation must have been reset by the long uncertain gap")
        XCTAssertLessThanOrEqual(reAlertOffset, 1.1)
    }

    // MARK: - Release needs a clear window

    func testAlertReleasesOnlyAfterReleaseDuration() {
        let filter = TemporalAttentionFilter()
        // 1.0 s of looking → alert reached, last .looking at 0.9 s.
        for step in 0..<10 {
            _ = filter.update(.looking, at: date(Double(step) * 0.1))
        }
        XCTAssertTrue(filter.isAlerting)

        // Inside the 0.6 s release window the alert stays latched.
        XCTAssertTrue(filter.update(.notLooking, at: date(1.0)))  // 0.1 s since last look
        XCTAssertTrue(filter.update(.notLooking, at: date(1.4)))  // 0.5 s — still inside
        // Beyond the window → released.
        XCTAssertFalse(filter.update(.notLooking, at: date(1.6))) // 0.7 s — clear gap
        XCTAssertFalse(filter.isAlerting)

        // After release, looking must accumulate from zero again.
        XCTAssertFalse(filter.update(.looking, at: date(1.7)))
        XCTAssertEqual(filter.accumulatedLookingTime, 0.1, accuracy: 1e-9)
    }

    // MARK: - Uncertain while alerting runs the release window

    func testUncertainWhileAlertingCountsTowardRelease() {
        let filter = TemporalAttentionFilter()
        for step in 0..<10 {
            _ = filter.update(.looking, at: date(Double(step) * 0.1))
        }
        XCTAssertTrue(filter.isAlerting)

        // Uncertain inside the release window keeps the alert latched.
        XCTAssertTrue(filter.update(.uncertain, at: date(1.0)))  // 0.1 s
        XCTAssertTrue(filter.update(.uncertain, at: date(1.4)))  // 0.5 s — still inside
        // Past the window, uncertain releases exactly like notLooking.
        XCTAssertFalse(filter.update(.uncertain, at: date(1.6))) // 0.7 s — clear gap
        XCTAssertFalse(filter.isAlerting)
    }

    // MARK: - Delta clamp survives processing stalls

    func testHugeDeltaIsClampedAndCannotInstantlyAlert() {
        let filter = TemporalAttentionFilter()
        XCTAssertFalse(filter.update(.looking, at: date(0.0)))

        // A single update after a 5 s stall credits at most maxDelta (0.5 s)
        // — the raw 5 s gap would have instantly alerted.
        XCTAssertFalse(filter.update(.looking, at: date(5.0)))
        XCTAssertEqual(filter.accumulatedLookingTime, 0.5, accuracy: 1e-9)

        // The clamp bounds each step; accumulation itself is real, so the
        // next (also clamped) step crosses the trigger.
        XCTAssertTrue(filter.update(.looking, at: date(10.0)))
        XCTAssertEqual(filter.accumulatedLookingTime, 1.0, accuracy: 1e-9)
    }

    // MARK: - Flicker never alerts

    func testRepeatedFlickerNeverAlerts() {
        let filter = TemporalAttentionFilter()
        var sawAlert = false
        // 5 s of alternating look / notLooking sampled every 0.1 s: every
        // cleared notLooking resets the pending accumulation, so it never
        // gets past 0.1 s.
        for step in 0..<50 {
            let state: AttentionState = step % 2 == 0 ? .looking : .notLooking
            if filter.update(state, at: date(Double(step) * 0.1)) {
                sawAlert = true
            }
        }
        XCTAssertFalse(sawAlert)
        XCTAssertFalse(filter.isAlerting)
    }

    // MARK: - reset()

    func testResetClearsAlertAndPendingState() {
        let filter = TemporalAttentionFilter()
        for step in 0..<10 {
            _ = filter.update(.looking, at: date(Double(step) * 0.1))
        }
        XCTAssertTrue(filter.isAlerting)

        filter.reset()
        XCTAssertFalse(filter.isAlerting)
        XCTAssertEqual(filter.accumulatedLookingTime, 0.0, accuracy: 1e-9)

        // Deltas across the reset are not credited: the first update after a
        // reset credits 0, and a fresh (clamp-bounded) run is required to
        // alert again.
        XCTAssertFalse(filter.update(.looking, at: date(20.0)))  // first update credits 0
        XCTAssertFalse(filter.update(.looking, at: date(20.5)))  // +0.5 (clamped) → 0.5
        XCTAssertTrue(filter.update(.looking, at: date(21.1)))   // +0.5 → 1.0 ≥ 0.9 → alert
    }
}
