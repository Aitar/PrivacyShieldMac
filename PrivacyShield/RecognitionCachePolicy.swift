import Foundation
import CoreGraphics

/// All identity-cache tunables in one place (M2-T05): revalidation cadence per
/// identity state plus the early-revalidation and hysteresis thresholds.
///
/// The policy is pure config + decision logic — no Vision, no camera, no
/// `FaceRecognizer` dependency — so the recognition-caching integration
/// (M2-T06) reads every threshold from here instead of scattering magic
/// numbers through `FaceDetector`.
struct RecognitionCachePolicyConfig {

    // MARK: - Revalidation cadence (seconds) per identity state

    /// Revalidate owner this often. Spec: every 2–3 s.
    var ownerRevalidationInterval: TimeInterval = 2.5
    /// Trusted faces revalidate on the owner cadence (same trust level).
    var trustedRevalidationInterval: TimeInterval = 2.5
    /// Revalidate strangers this often (spec: every 1–2 s) — their identity is
    /// cheaper to get wrong, so they are checked more frequently.
    var otherRevalidationInterval: TimeInterval = 1.5
    /// `.unknown` (failed initial recognition) revalidates on the stranger
    /// cadence until a recognition succeeds.

    // MARK: - Early revalidation triggers

    /// Recheck early when the face center moved more than this fraction of the
    /// frame width (Euclidean displacement) since the previous bounding box.
    var bboxJumpRelativeThreshold: CGFloat = 0.35
    /// Recheck early when the face size changed substantially:
    /// |log(newWidth / oldWidth)| above this means the face is far closer to,
    /// or farther from, the cached recognition sample's distance.
    var faceSizeChangeRatio: CGFloat = 0.4
    /// A track that reappears after being unseen for at least this long is
    /// rechecked immediately instead of trusting the cached identity.
    var resumeAfterGapThreshold: TimeInterval = 1.0

    /// Reserved for M2-T06 (recognition caching): when the integrator can
    /// measure crop quality, a current crop whose quality improves on the
    /// cached recognition sample by more than this threshold should trigger
    /// early revalidation. `nil` until M2-T06 defines the quality metric —
    /// this module deliberately contains NO image-quality logic (that belongs
    /// to the Vision layer); the field only reserves the tunable.
    var cropQualityImprovementThreshold: Float? = nil

    // MARK: - Hysteresis

    /// A stable owner/trusted track needs this many consecutive failed
    /// revalidations before its identity may be demoted, so one bad frame
    /// (motion blur, partial occlusion) cannot instantly flip the owner to
    /// stranger. See `RecognitionCachePolicy.allowsOwnerDowngrade(_:)`.
    var ownerDowngradeConsecutiveMisses: Int = 2

    /// The single source of truth for policy defaults.
    static let `default` = RecognitionCachePolicyConfig()
}

/// Why a recognition decision was made — exposed for debug logging so M2-T07
/// can show, per track, exactly when and why identity was (re)checked.
enum RecognitionReason: Equatable, CustomStringConvertible {

    /// Track was just created and has never been recognized.
    case newTrack
    /// Not a new track, but there is no cached identity to trust yet
    /// (defensive: recognition never ran to completion on this track).
    case noCachedIdentity
    /// Track reappeared after a gap of at least the resume threshold.
    case resumedAfterGap(unseen: TimeInterval, threshold: TimeInterval)
    /// Face center jumped more than the configured fraction of frame width.
    case boundingBoxJump(centerShiftFraction: CGFloat, threshold: CGFloat)
    /// Face size changed more than the configured log-ratio.
    case faceSizeChange(logSizeRatio: CGFloat, threshold: CGFloat)
    /// The per-identity revalidation cadence has elapsed.
    case cadenceElapsed(elapsed: TimeInterval, interval: TimeInterval)
    /// The cached identity is still fresh within its cadence.
    case withinCadence(elapsed: TimeInterval, interval: TimeInterval)

    var description: String {
        switch self {
        case .newTrack:
            return "new track (never recognized)"
        case .noCachedIdentity:
            return "no cached identity"
        case .resumedAfterGap(let unseen, let threshold):
            return String(format: "resumed after %.2fs gap (≥ %.2fs)", unseen, threshold)
        case .boundingBoxJump(let shift, let threshold):
            return String(format: "bbox center jumped %.0f%% of frame width (threshold %.0f%%)",
                          shift * 100, threshold * 100)
        case .faceSizeChange(let ratio, let threshold):
            return String(format: "face size changed |log ratio| %.2f (threshold %.2f)", ratio, threshold)
        case .cadenceElapsed(let elapsed, let interval):
            return String(format: "cadence elapsed: %.2fs ≥ %.2fs", elapsed, interval)
        case .withinCadence(let elapsed, let interval):
            return String(format: "within cadence: %.2fs < %.2fs", elapsed, interval)
        }
    }
}

/// Whether recognition should run for a track right now, plus the reason.
enum RecognitionDecision: Equatable {

    /// Run `FaceRecognizer` on the current frame and update the cached identity.
    case recognizeNow(reason: RecognitionReason)
    /// Trust the cached identity for this frame.
    case cached(IdentityState, reason: RecognitionReason)
}

/// Decides, per track, when identity recognition must (re)run. Pure logic:
/// the caller supplies all inputs (current `FaceTrack`, gap duration,
/// previous bounding box, frame width) and applies the returned decision.
struct RecognitionCachePolicy {

    var config: RecognitionCachePolicyConfig = .default

    // MARK: - Decision

    /// Decide for one track whether recognition should run at `now`.
    ///
    /// Inputs:
    /// - `track`: current track state (identity, bounding box, lastIdentityCheck).
    /// - `isNewTrack`: the track was just created and has never been recognized.
    /// - `unseenDuration`: how long the track was unseen before it resumed
    ///   (0 while the track is continuously visible).
    /// - `previousBoundingBox`: the bounding box the identity was cached
    ///   against, if any; used for the jump/size early triggers.
    /// - `frameWidth`: frame width **in the same units as the bounding
    ///   boxes** (pass 1.0 for Vision's normalized rects, or the pixel width).
    ///   Required for the bbox-jump trigger; when nil that trigger is skipped
    ///   (the size trigger still applies, being self-relative).
    /// - `now`: the evaluation time (injected, never `Date()`).
    ///
    /// Note on crop quality: the config reserves
    /// `cropQualityImprovementThreshold` for M2-T06; until a quality metric
    /// exists this decision contains no image-quality input or logic.
    func decision(track: FaceTrack,
                  isNewTrack: Bool,
                  unseenDuration: TimeInterval = 0,
                  previousBoundingBox: CGRect? = nil,
                  frameWidth: CGFloat? = nil,
                  now: Date) -> RecognitionDecision {

        // 1. A brand-new track is recognized immediately.
        if isNewTrack {
            return .recognizeNow(reason: .newTrack)
        }

        // 2. A track that resumed after a long gap is rechecked immediately —
        //    the person may have changed while the track was gone.
        if unseenDuration >= config.resumeAfterGapThreshold {
            return .recognizeNow(reason: .resumedAfterGap(unseen: unseenDuration,
                                                          threshold: config.resumeAfterGapThreshold))
        }

        // 3. Early trigger: the face jumped across the frame since the
        //    identity was cached (center displacement vs frame width). Needs
        //    the frame width to be meaningful, so it is skipped when the
        //    integrator cannot supply it.
        if let previous = previousBoundingBox,
           let frameWidth = frameWidth,
           frameWidth > 0 {
            let dx = track.boundingBox.midX - previous.midX
            let dy = track.boundingBox.midY - previous.midY
            let centerShiftFraction = (dx * dx + dy * dy).squareRoot() / frameWidth
            if centerShiftFraction > config.bboxJumpRelativeThreshold {
                return .recognizeNow(reason: .boundingBoxJump(centerShiftFraction: centerShiftFraction,
                                                              threshold: config.bboxJumpRelativeThreshold))
            }
        }

        // 4. Early trigger: the face size changed substantially (self-relative,
        //    so no frame geometry is needed). Distance to the camera is a big
        //    factor in recognition quality — a much closer/farther face should
        //    be rechecked even inside the cadence.
        if let previous = previousBoundingBox,
           previous.width > 0,
           track.boundingBox.width > 0 {
            let logSizeRatio = abs(log(track.boundingBox.width / previous.width))
            if logSizeRatio > config.faceSizeChangeRatio {
                return .recognizeNow(reason: .faceSizeChange(logSizeRatio: logSizeRatio,
                                                             threshold: config.faceSizeChangeRatio))
            }
        }

        // 5. Cadence: revalidate per the track's identity state.
        guard let lastCheck = track.lastIdentityCheck else {
            // Not flagged new, but nothing was ever cached — recognize now.
            return .recognizeNow(reason: .noCachedIdentity)
        }
        let interval = revalidationInterval(for: track.identity)
        let elapsed = now.timeIntervalSince(lastCheck)
        if elapsed >= interval {
            return .recognizeNow(reason: .cadenceElapsed(elapsed: elapsed, interval: interval))
        }
        return .cached(track.identity, reason: .withinCadence(elapsed: elapsed, interval: interval))
    }

    // MARK: - Cadence lookup

    /// Revalidation cadence for an identity state: owner/trusted share the
    /// owner interval; other and unknown (failed recognition) use the
    /// shorter stranger interval.
    func revalidationInterval(for identity: IdentityState) -> TimeInterval {
        switch identity {
        case .owner: return config.ownerRevalidationInterval
        case .trusted: return config.trustedRevalidationInterval
        case .other, .unknown: return config.otherRevalidationInterval
        }
    }

    // MARK: - Hysteresis

    /// Whether a stable owner/trusted identity may be demoted after
    /// `consecutiveMisses` consecutive failed revalidations. Fewer than
    /// `config.ownerDowngradeConsecutiveMisses` misses keeps the cached
    /// identity (a single bad frame cannot flip owner → stranger); once the
    /// miss count reaches the threshold the caller may demote.
    func allowsOwnerDowngrade(_ consecutiveMisses: Int) -> Bool {
        return consecutiveMisses >= config.ownerDowngradeConsecutiveMisses
    }
}
