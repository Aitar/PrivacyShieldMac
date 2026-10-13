import Foundation

// MARK: - Types

/// Result of a successful screen-direction calibration session (M3-T01).
///
/// The stored pair (`centerYaw`, `centerPitch`) is the head pose the user's
/// face carries while sitting in the normal working position looking at the
/// screen center. The attention classifier subtracts this per-user offset
/// instead of assuming a hard-coded frontal pose, because camera placement
/// and seating posture vary per installation.
///
/// Medians (not means) are used deliberately per plan section 8: a handful
/// of transient pose errors (motion blur, a half-detected face mid-turn)
/// must not drag the estimated center toward them.
struct ScreenCalibrationResult: Equatable {
    /// Median yaw across the samples accepted after outlier rejection (degrees).
    let centerYaw: Double
    /// Median pitch across the samples accepted after outlier rejection (degrees).
    let centerPitch: Double
    /// Number of valid samples actually used to compute the medians (i.e.
    /// after outlier rejection). May be lower than the number of valid
    /// samples observed when outliers were dropped.
    let sampleCount: Int
    /// Fraction of observed samples that carried a valid pose,
    /// `valid / totalObserved`, in [0, 1].
    let validityRate: Double
}

/// Tunable parameters for `ScreenDirectionCalibrationCollector`.
struct ScreenCalibrationConfig {
    /// Valid samples required for calibration to succeed. 15 ≈ 2–3 s of
    /// "look at the screen center" at the Vision face-observation cadence
    /// (~8–10 fps with recognition in the loop).
    var requiredValidSamples: Int = 15

    /// Duration cap for one collection session, measured from the FIRST
    /// sample. Samples arriving after the window are ignored entirely (they
    /// count neither as valid nor as observed), so a caller that keeps
    /// feeding past the window does not distort the session's statistics.
    var collectionWindow: TimeInterval = 3.0

    /// Strong-outlier gate: a sample is dropped when its distance from the
    /// axis median exceeds `outlierSigmaMultiplier × (1.4826 × MAD + ε)`
    /// on either axis. 2.5 corresponds to a generous ~2.5σ cut, so only
    /// clearly broken readings (e.g. one frame at yaw 60°) are removed.
    var outlierSigmaMultiplier: Double = 2.5

    /// Calibration fails when fewer than this fraction of the observed
    /// samples carried a valid pose (face not detected / pose unavailable
    /// most of the time).
    var minimumValidityRate: Double = 0.5

    static let `default` = ScreenCalibrationConfig()
}

// MARK: - Collector

/// Collects head-pose observations for the "Calibrate Screen Direction…"
/// flow (M3-T01) and distills them into a robust screen-facing center.
///
/// Usage (driven by the future menu action, M3-T02):
///
///     let collector = ScreenDirectionCalibrationCollector()
///     // while Vision frames arrive:
///     collector.add(headPoseResult, at: frameDate)
///     if collector.isComplete, let result = collector.finish() {
///         ScreenCenterStore.save(result)
///     } // else: caller shows a failure toast and asks the user to retry.
///
/// Design decisions
/// ----------------
/// - `.unavailable` samples are rejected as data but COUNTED as observed,
///   so a session where the face keeps dropping out fails via
///   `validityRate < minimumValidityRate` instead of silently succeeding on
///   a few lucky frames. Unavailable pose must stay distinguishable from
///   frontal pose (same rule as `HeadPoseEstimator`).
/// - Samples arriving more than `collectionWindow` seconds after the first
///   sample are ignored ENTIRELY — they count neither as valid nor as
///   observed — so feeding the collector past the window cannot drag the
///   validity statistics of the in-window session.
/// - Outlier rejection happens once, at `finish()` time, over the whole
///   collected set (per-axis median + MAD). This is deterministic and
///   order-independent, and simpler than incremental gating; transient
///   strong outliers (e.g. one frame at yaw 60°) cannot poison the center.
/// - `finish()` is non-mutating and idempotent: it never consumes the
///   collected samples, so it can be called repeatedly (e.g. once per timer
///   tick once `isComplete` flips) and always returns the same result.
///   Call `reset()` to start a new session.
///
/// Failure contract: `finish()` returns nil when fewer than
/// `requiredValidSamples` valid samples were collected, when
/// `validityRate < minimumValidityRate`, or when outlier rejection
/// (defensively) leaves no usable samples. The caller is expected to show a
/// failure toast and let the user retry (M3-T02).
///
/// Not thread-safe: feed it from a single queue (the Vision processing
/// queue the menu action already uses).
final class ScreenDirectionCalibrationCollector {

    /// One accepted head-pose observation. Only the two calibrated axes are
    /// kept; roll and confidence play no role in screen direction.
    private struct Sample {
        let yaw: Double
        let pitch: Double
    }

    private let config: ScreenCalibrationConfig

    /// Valid samples collected so far (before outlier rejection).
    private var samples: [Sample] = []

    /// Every in-window observation seen, valid or not; denominator of
    /// `validityRate`.
    private var totalObserved = 0

    /// Timestamp of the first in-window sample; anchors `collectionWindow`.
    private var windowAnchor: Date?

    init(config: ScreenCalibrationConfig = .init()) {
        self.config = config
    }

    /// Feeds one head-pose observation.
    ///
    /// - `.unavailable`: counted as observed, not stored.
    /// - `.valid` within the collection window: counted and stored.
    /// - `.valid` after the window: ignored entirely (see class docs).
    func add(_ result: HeadPoseResult, at date: Date) {
        if let anchor = windowAnchor {
            // Timestamps are expected to be non-decreasing; an out-of-order
            // sample dated before the anchor has elapsed ≤ 0 and is accepted.
            guard date.timeIntervalSince(anchor) <= config.collectionWindow else { return }
        } else {
            windowAnchor = date
        }

        totalObserved += 1
        guard case .valid(let pose) = result else { return }
        samples.append(Sample(yaw: pose.yaw, pitch: pose.pitch))
    }

    /// Valid samples collected so far (before outlier rejection).
    var sampleCount: Int {
        return samples.count
    }

    /// True when enough valid samples have been collected for `finish()`
    /// to have a chance to succeed.
    var isComplete: Bool {
        return samples.count >= config.requiredValidSamples
    }

    /// Computes the calibrated center from the collected samples, or nil
    /// when the session failed (see the failure contract in the class docs).
    ///
    /// Pipeline: gate on count and validity rate → per-axis median + MAD
    /// over ALL collected valid samples → drop strong outliers → recompute
    /// the medians over the accepted samples (they are the result).
    func finish() -> ScreenCalibrationResult? {
        let validCount = samples.count

        guard validCount >= config.requiredValidSamples else { return nil }
        guard totalObserved > 0 else { return nil }

        let validityRate = Double(validCount) / Double(totalObserved)
        guard validityRate >= config.minimumValidityRate else { return nil }

        // Robust per-axis statistics over the whole collected set.
        let yaws = samples.map { $0.yaw }
        let pitches = samples.map { $0.pitch }
        guard
            let medianYaw = Self.median(of: yaws),
            let medianPitch = Self.median(of: pitches),
            let madYaw = Self.medianAbsoluteDeviation(of: yaws, around: medianYaw),
            let madPitch = Self.medianAbsoluteDeviation(of: pitches, around: medianPitch)
        else { return nil }

        // 1.4826 ≈ 1/0.6745 rescales MAD to a standard-deviation estimate
        // for normal data. The tiny epsilon keeps the acceptance band
        // strictly positive when MAD = 0 (e.g. all samples identical), so a
        // degenerate set is kept as-is instead of being whittled away by
        // float noise.
        let epsilon = 1e-6
        let yawLimit = config.outlierSigmaMultiplier * (1.4826 * madYaw + epsilon)
        let pitchLimit = config.outlierSigmaMultiplier * (1.4826 * madPitch + epsilon)

        // A sample is rejected when it is a strong outlier on EITHER axis.
        let accepted = samples.filter { sample in
            abs(sample.yaw - medianYaw) <= yawLimit
                && abs(sample.pitch - medianPitch) <= pitchLimit
        }
        guard !accepted.isEmpty else { return nil }

        // The medians of the accepted samples ARE the calibrated center.
        guard
            let centerYaw = Self.median(of: accepted.map { $0.yaw }),
            let centerPitch = Self.median(of: accepted.map { $0.pitch })
        else { return nil }

        return ScreenCalibrationResult(
            centerYaw: centerYaw,
            centerPitch: centerPitch,
            sampleCount: accepted.count,
            validityRate: validityRate
        )
    }

    /// Discards all collected state so the collector can be reused for a
    /// fresh session (e.g. a retry after a failed calibration).
    func reset() {
        samples = []
        totalObserved = 0
        windowAnchor = nil
    }

    // MARK: - Robust statistics

    /// Median of an array: middle value for odd counts, mean of the two
    /// middle values for even counts. nil only for an empty array.
    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Median absolute deviation: the median of |value − center|. Robust
    /// spread estimate that — unlike standard deviation — is itself
    /// insensitive to the outliers it is meant to expose.
    private static func medianAbsoluteDeviation(of values: [Double], around center: Double) -> Double? {
        return median(of: values.map { abs($0 - center) })
    }
}

// MARK: - Persistence

/// Persists the calibrated screen-facing center in UserDefaults (plan
/// section 8: keys `screenCenterYaw` / `screenCenterPitch`, plus
/// `screenCenterCalibratedAt` for debugging / display in debug mode).
///
/// The future menu action (M3-T02) saves on success and recalibration
/// simply overwrites the previous values; the classifier config wiring
/// reads the center back via `load()`.
///
/// `defaults` is injectable so unit tests can run against an isolated
/// suite; production call sites use the `.standard` default.
enum ScreenCenterStore {

    static let yawKey = "screenCenterYaw"
    static let pitchKey = "screenCenterPitch"
    static let calibratedAtKey = "screenCenterCalibratedAt"

    /// Overwrites any previously stored center with the new calibration.
    static func save(_ result: ScreenCalibrationResult, defaults: UserDefaults = .standard) {
        defaults.set(result.centerYaw, forKey: yawKey)
        defaults.set(result.centerPitch, forKey: pitchKey)
        defaults.set(Date(), forKey: calibratedAtKey)
    }

    /// Returns the stored center, or nil when no complete calibration is
    /// persisted (either key missing). A missing center is never substituted
    /// with zero — mirroring the `HeadPoseEstimator` rule that missing data
    /// must not be indistinguishable from a frontal pose.
    static func load(from defaults: UserDefaults = .standard) -> (yaw: Double, pitch: Double)? {
        guard defaults.object(forKey: yawKey) != nil,
              defaults.object(forKey: pitchKey) != nil else { return nil }
        return (defaults.double(forKey: yawKey), defaults.double(forKey: pitchKey))
    }

    /// Removes the stored center (used by tests and by any future
    /// "reset calibration" affordance).
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: yawKey)
        defaults.removeObject(forKey: pitchKey)
        defaults.removeObject(forKey: calibratedAtKey)
    }
}
