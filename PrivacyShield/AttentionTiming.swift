import Foundation

/// Tuning parameters for `TemporalAttentionFilter` (M1-T07 / plan section 11).
///
/// All durations are wall-clock seconds, never frame counts, so behavior is
/// independent of camera frame rate and processing speed.
///
/// Invariant: keep `maxDelta` below `triggerDuration` so a single update can
/// never raise the alert by itself.
struct AttentionTimingConfig {
    /// Sustained looking needed to raise the alert (M1 default: 0.9 s).
    var triggerDuration: TimeInterval = 0.9
    /// Clear time (no `.looking`) needed to release an active alert (M1 default: 0.6 s).
    var releaseDuration: TimeInterval = 0.6
    /// Brief uncertain gaps hold pending accumulation instead of resetting;
    /// gaps longer than this are treated like `.notLooking` (M1 default: 0.35 s).
    var uncertainGrace: TimeInterval = 0.35
    /// Upper bound credited to a single update delta, so a processing stall
    /// (app suspension, slow frame) can neither trigger nor inflate the
    /// accumulated looking time in one step.
    var maxDelta: TimeInterval = 0.5

    /// Default M1 prototype profile (plan section 11: 0.8–1.0 s trigger,
    /// 0.5–0.8 s release).
    static let prototype = AttentionTimingConfig()
}

/// Reusable, pure-logic temporal filter that turns a stream of per-frame
/// `AttentionState` classifications into a single debounced alert signal
/// (M1-T07, plan section 11).
///
/// State machine:
///
///     SAFE ──(looking sustained for triggerDuration)──▶ ALERT
///       ▲                                                 │
///       └─────(no .looking for releaseDuration)───────────┘
///
/// Semantics (elapsed time only — a single positive frame can never trigger):
/// - `.looking` accumulates the elapsed time since the previous update (each
///   delta clamped to `maxDelta`); the alert fires once the accumulation
///   reaches `triggerDuration`.
/// - `.notLooking`: while alerting, the alert is held until the time since
///   the last `.looking` exceeds `releaseDuration`, then the alert clears and
///   the accumulation resets. While only pending (not alerting), any
///   `.notLooking` resets the accumulation immediately (a cleared notLooking
///   resets pending state).
/// - `.uncertain`: pauses accumulation (holds) for up to `uncertainGrace`;
///   beyond that it is treated like `.notLooking`. While alerting, uncertain
///   counts toward the release window exactly like `.notLooking` — the
///   release timer runs, and only an exceeded release clears the alert.
///
/// M1 uses a single instance fed with the aggregate state of all unknown
/// nearby faces (documented limitation). M2 will instantiate one filter per
/// face track so different people never accumulate each other's attention
/// time.
///
/// Not internally synchronized: drive it from a single queue (FaceDetector
/// handles results on the main queue).
final class TemporalAttentionFilter {

    private var config: AttentionTimingConfig

    /// Whether the sustained-attention alert is currently latched.
    private(set) var isAlerting = false

    /// Looking time accumulated toward the next trigger (diagnostics aid);
    /// reset on release, on a cleared notLooking, and by `reset()`.
    private(set) var accumulatedLookingTime: TimeInterval = 0

    private var lastUpdateDate: Date?
    private var lastLookingDate: Date?
    private var uncertainSince: Date?

    init(config: AttentionTimingConfig = .init()) {
        self.config = config
    }

    /// Feed the latest classification at the given timestamp. Returns `isAlerting`.
    @discardableResult
    func update(_ state: AttentionState, at date: Date) -> Bool {
        // Elapsed time since the previous update of ANY state, clamped so a
        // single stalled interval can never trigger by itself.
        let delta: TimeInterval
        if let last = lastUpdateDate {
            delta = min(max(date.timeIntervalSince(last), 0), config.maxDelta)
        } else {
            delta = 0  // first observation: nothing to accumulate yet
        }
        lastUpdateDate = date

        switch state {
        case .looking:
            uncertainSince = nil
            lastLookingDate = date
            accumulatedLookingTime += delta
            if !isAlerting && accumulatedLookingTime >= config.triggerDuration {
                isAlerting = true
            }

        case .notLooking:
            uncertainSince = nil
            if isAlerting {
                releaseIfElapsed(date)
            } else {
                // Pending: a cleared notLooking resets the accumulation.
                accumulatedLookingTime = 0
            }

        case .uncertain:
            if isAlerting {
                // Release window runs during uncertain exactly like during
                // notLooking; only an exceeded release clears the alert.
                releaseIfElapsed(date)
            } else {
                // Pending: hold the accumulation for up to the grace period,
                // then treat the gap like notLooking (reset).
                if uncertainSince == nil { uncertainSince = date }
                if let start = uncertainSince,
                   date.timeIntervalSince(start) > config.uncertainGrace {
                    accumulatedLookingTime = 0
                }
            }
        }
        return isAlerting
    }

    /// Swaps the timing configuration WITHOUT touching accumulated state
    /// (M3-T04): a distance-band profile change must not reset a track's
    /// pending accumulation or release an active alert — only the
    /// configuration changes, applying from the next `update` onwards
    /// (trigger/release/grace thresholds and the maxDelta clamp all read the
    /// current config per update).
    func updateConfig(_ config: AttentionTimingConfig) {
        self.config = config
    }

    /// Clears all state: alert, accumulation and timers.
    func reset() {
        isAlerting = false
        accumulatedLookingTime = 0
        lastUpdateDate = nil
        lastLookingDate = nil
        uncertainSince = nil
    }

    /// ALERT → SAFE once the time since the last `.looking` strictly exceeds
    /// the release duration. Shared by `.notLooking` and `.uncertain` while
    /// alerting.
    private func releaseIfElapsed(_ date: Date) {
        if let lastLook = lastLookingDate,
           date.timeIntervalSince(lastLook) > config.releaseDuration {
            isAlerting = false
            accumulatedLookingTime = 0
        }
    }
}
