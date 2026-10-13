import Foundation

// MARK: - Independent policy inputs (M4-T03, plan §14 Phase 10)

/// The two independent policy inputs (M4-T03): whether the owner is currently
/// at the screen and whether any qualifying non-owner track is alerting.
///
/// M4-T03's whole point is that these are computed and reasoned about
/// INDEPENDENTLY — owner presence no longer piggybacks on the legacy
/// "no face at all" rule, and shoulder-surf state no longer implies anything
/// about who else is in frame. `OwnerPresencePolicy` produces the first
/// field from track snapshots; `ShoulderSurfAggregator` (M2-T04) produces the
/// second from per-track alert flags.
struct PrivacyState {
    /// An owner/trusted track was seen within the configured presence window
    /// (see `OwnerPresencePolicy`).
    var ownerPresent: Bool
    /// At least one qualifying non-owner track's temporal filter is alerting
    /// (`ShoulderSurfAggregator.isAnyQualifyingTrackAlerting`).
    var shoulderSurferDetected: Bool
}

// MARK: - Shield reason (M4-T03; consumed by M4-T04)

/// Why the shield is currently shown — the single source of truth for the
/// displayed shield state. From M4-T04, notifications and menu status text
/// are derived from this reason so the user is told WHY the screen is
/// protected instead of receiving one undifferentiated "stranger" signal.
///
/// Behavior mapping: `.none` = shield hidden; every other case = shield
/// shown (see `isShieldShown`).
enum PrivacyShieldReason: Equatable, CustomStringConvertible {
    /// Only the owner-absent policy is actively demanding a blur.
    case ownerAbsent
    /// Only the shoulder-surf policy is actively demanding a blur.
    case shoulderSurfer
    /// Both policies are actively demanding a blur (precedence case: the
    /// shield is shown either way, the reason reports both).
    case both
    /// No policy demands a blur — shield hidden.
    case none

    /// Whether the shield should be displayed for this reason (M4-T03
    /// behavior mapping: the enum is the single source of truth).
    var isShieldShown: Bool { self != .none }

    /// Stable snake_case names for structured debug/diagnostic output,
    /// matching the `DiagnosticsLog` event style.
    var description: String {
        switch self {
        case .ownerAbsent: return "owner_absent"
        case .shoulderSurfer: return "shoulder_surfer"
        case .both: return "owner_absent+shoulder_surfer"
        case .none: return "none"
        }
    }
}

// MARK: - Owner presence (M4-T03)

/// Owner-presence decision, split out of FaceDetector's legacy rule (M4-T03).
///
/// The legacy path treated "no face at all" as the owner-away signal, which
/// conflated two different situations: the user leaving, and a stranger
/// remaining in frame while the user left. This policy is precise: owner
/// presence is established ONLY by a trusted-level track (`.owner` or
/// `.trusted`) seen recently enough. Strangers — including not-yet-recognized
/// `.unknown` tracks — never keep the screen "safe".
///
/// Pure function: no wall clock, no tracker dependency. The caller (the
/// FaceDetector integration, M4-T06) maps its live `FaceTrack`s into
/// `(identity, lastSeen)` snapshots and supplies `now` and the window
/// (typically `PrivacyStateMachineConfig.ownerPresenceWindow`). The caller
/// also decides WHICH tracks are candidates (e.g. only the detector's
/// size-filtered in-range tracks matter).
enum OwnerPresencePolicy {

    /// Owner present = an owner/trusted track seen within `presenceWindow` of
    /// `now`. A single fresh owner track is enough; stale and non-owner
    /// snapshots are ignored.
    ///
    /// Window semantics (documented + tested): INCLUSIVE at the edge — a
    /// track aged exactly `presenceWindow` still counts as present, mirroring
    /// `FaceTracker`'s expiry comparison which also keeps a track at exactly
    /// its expiry boundary. A `lastSeen` in the future (negative age) counts
    /// as present. Empty input → absent.
    static func ownerPresent(
        in tracks: [(identity: IdentityState, lastSeen: Date)],
        now: Date,
        presenceWindow: TimeInterval
    ) -> Bool {
        tracks.contains { snapshot in
            isOwnerLevel(snapshot.identity)
                && now.timeIntervalSince(snapshot.lastSeen) <= presenceWindow
        }
    }

    /// Trusted-level identities, i.e. the exact complement of
    /// `ShoulderSurfAggregator.isQualifyingObserver`: `.owner`/`.trusted` are
    /// the user and trusted company, `.other`/`.unknown` are not. Stated
    /// explicitly here (rather than derived from the aggregator) so a future
    /// change to observer eligibility cannot silently change owner-presence
    /// semantics; both sides are covered by tests.
    private static func isOwnerLevel(_ identity: IdentityState) -> Bool {
        switch identity {
        case .owner, .trusted: return true
        case .other, .unknown: return false
        }
    }
}

// MARK: - Config (M4-T03; X-T01: knobs in one place)

/// All privacy-policy tunables. M4-T01's settings ("Blur when I leave" /
/// "Blur when someone watches my screen") map 1:1 onto the two blur toggles.
struct PrivacyStateMachineConfig {
    /// Owner-absent policy: blur when no owner/trusted track has been seen
    /// within `ownerPresenceWindow` — regardless of any stranger still in
    /// frame. `false` = owner absence alone never blurs.
    var blurWhenOwnerAbsent: Bool = true
    /// Shoulder-surf policy: blur while any qualifying non-owner track is
    /// alerting, EVEN when the owner is present. `false` = looking strangers
    /// alone never blur.
    var blurWhenShoulderSurferDetected: Bool = true
    /// How recently an owner/trusted track must have been seen to count as
    /// present, in seconds. Consumed by the CALLER: `OwnerPresencePolicy` is
    /// a pure function and takes the window explicitly; the M4-T06
    /// integration passes this value through.
    var ownerPresenceWindow: TimeInterval = 1.5

    /// The single source of truth for policy defaults.
    static let `default` = PrivacyStateMachineConfig()
}

// MARK: - State machine (M4-T03)

/// Pure decision core for the two independent privacy policies (M4-T03,
/// plan §14). No AppKit, no Vision, no `FaceDetector` dependency: the caller
/// supplies per-frame snapshots (`PrivacyState`) and applies the returned
/// reason to the shield/menu/notification paths.
///
/// Intended replacement of FaceDetector's legacy path (integration is
/// M4-T06): today `FaceDetector` combines a debounced legacy owner-absent
/// blur (`updateLegacyShieldState`, the old "no face at all → stranger"
/// rule) with the M2 attention alert via a plain OR in
/// `applyCombinedShield`. That combination is replaced by feeding
/// `OwnerPresencePolicy` + `ShoulderSurfAggregator` outputs into
/// `evaluate` and driving the shield from the returned `PrivacyShieldReason`
/// (plus its config toggles, wired to the M4-T01/M4-T06 settings). Until that
/// integration lands, `FaceDetector` is deliberately untouched and nothing
/// else references this type.
struct PrivacyStateMachine {
    var config: PrivacyStateMachineConfig = .default

    /// Pure decision: given owner presence and whether any qualifying
    /// non-owner track is alerting, return the shield reason. Rules (plan
    /// §14):
    ///   - owner absent → optional blur (only if `blurWhenOwnerAbsent`);
    ///   - unknown person present but NOT looking → NO shoulder-surf blur
    ///     (`shoulderSurferDetected` is false — the looking/alerting decision
    ///     belongs to the per-track temporal filters and
    ///     `ShoulderSurfAggregator`, not here);
    ///   - unknown person looking (alerting) → blur even when the owner is
    ///     present (only if `blurWhenShoulderSurferDetected`);
    ///   - both policies active → shield shown, reason `.both`;
    ///   - neither → shield hidden, `.none`.
    ///
    /// A reason only ever reports policies that are ACTIVELY demanding a
    /// blur: with a toggle off, that condition alone never produces a blur
    /// and never contributes to `.both` (owner absent + alerting surfer with
    /// `blurWhenShoulderSurferDetected == false` reads `.ownerAbsent`).
    func evaluate(ownerPresent: Bool, shoulderSurferDetected: Bool) -> PrivacyShieldReason {
        let absentBlurActive = !ownerPresent && config.blurWhenOwnerAbsent
        let surferBlurActive = shoulderSurferDetected && config.blurWhenShoulderSurferDetected
        switch (absentBlurActive, surferBlurActive) {
        case (false, false): return .none
        case (true, false):  return .ownerAbsent
        case (false, true):  return .shoulderSurfer
        case (true, true):   return .both
        }
    }

    /// Convenience overload taking the bundled policy inputs.
    func evaluate(_ state: PrivacyState) -> PrivacyShieldReason {
        evaluate(ownerPresent: state.ownerPresent,
                 shoulderSurferDetected: state.shoulderSurferDetected)
    }
}

// MARK: - Display state (M4-T04; reported to the app delegate)

/// Aggregate display state the detector reports to the app delegate (M4-T06
/// implements the FaceDetector side; until then the protocol default keeps
/// the app compiling).
///
/// Coarser than `PrivacyShieldReason`: besides the three blur states (which
/// map 1:1 onto the reason cases) it names the device/app-level states the
/// user should see — calibration in progress and camera unavailable. The
/// app delegate derives the menu status line and the reason-aware
/// notification content from this state.
enum PrivacyDisplayState: Equatable {
    /// Shield hidden, owner present, nothing alerting.
    case monitoringSafe
    /// Only the owner-absent policy is blurring.
    case ownerAbsent
    /// Only the shoulder-surf policy is blurring.
    case shoulderSurferDetected
    /// Both policies are blurring.
    case bothPoliciesActive
    /// A calibration session is collecting samples.
    case calibrating
    /// The camera could not deliver frames (permission denied, device gone).
    case cameraUnavailable

    /// Whether this state itself demands the blur shield — exactly the three
    /// blur states, mirroring `PrivacyShieldReason.isShieldShown`. The
    /// calibration and camera-unavailable states describe the DETECTOR, not
    /// the shield: whether the shield stays shown during them is the
    /// caller's policy, so they report `false` here.
    var isShieldShown: Bool {
        switch self {
        case .monitoringSafe, .calibrating, .cameraUnavailable: return false
        case .ownerAbsent, .shoulderSurferDetected, .bothPoliciesActive: return true
        }
    }
}

// MARK: - Display-state reporting contract (M4-T04)

/// Delegate contract for display-state reporting (M4-T04): the detector
/// pushes every aggregated display-state change so the app delegate can
/// render the menu status line and send reason-aware notifications.
///
/// Design note — why a SEPARATE protocol instead of a default-implementation
/// extension on `FaceDetectorDelegate` (which lives in FaceDetector.swift and
/// stays untouched until M4-T06): both compile, but a protocol-extension
/// method that is not a protocol requirement dispatches STATICALLY through
/// the existential — an override in the conforming AppDelegate would never be
/// reached via a `FaceDetectorDelegate` reference. As a real requirement,
/// `privacyStateChanged(to:)` dispatches dynamically, and M4-T06 can reach it
/// with an optional cast
/// (`(delegate as? PrivacyDisplayReporting)?.privacyStateChanged(to:)`)
/// without modifying FaceDetector.swift.
protocol PrivacyDisplayReporting: AnyObject {
    /// The aggregated display state changed. Implementations hop to the main
    /// queue themselves; the detector calls this only on state TRANSITIONS
    /// (no per-frame spam), mirroring the edge-driven shield updates.
    func privacyStateChanged(to state: PrivacyDisplayState)
}

extension PrivacyDisplayReporting {
    /// Default no-op: conformers that do not care about display state keep
    /// compiling unchanged until the M4-T06 integration starts calling this.
    func privacyStateChanged(to state: PrivacyDisplayState) {}
}
