import CoreGraphics
import Foundation

/// Structured, one-line debug logging for the attention pipeline (M1-T06,
/// reworked for per-track state in M2-T07).
///
/// Every event prints as a single pipe-separated `key=value` line that can be
/// copied straight into evaluation notes, e.g.:
///
///     ts=2026-10-13T10:12:33.412Z | event=track | track_id=A1B2C3D4 | identity=other | face_width=0.312 | bbox=0.20,0.30,0.20x0.25 | yaw=+12.4 | pitch=-3.1 | roll=+0.5 | attention_score=0.83 | attention_state=looking | looking_duration_ms=540 | last_seen_age_ms=0 | identity_check_age_ms=1250 | latency_ms=14.2
///     ts=2026-10-13T10:12:33.412Z | event=recognition | track_id=A1B2C3D4 | decision=recognize_now | reason=cadence elapsed: 2.51s ≥ 2.50s | identity=owner
///
/// Emitted events:
/// - `track`                — one per processed track per frame (M2-T07; replaces the M1 per-frame `face` event); gains `distance_band` in M3-T04
/// - `recognition`          — one per recognition-caching decision (recognize_now / cached)
/// - `alert_on` / `alert_off`           — per-track temporal-filter transitions (with track_id)
/// - `band_change`          — one per per-track distance-band change (M3-T04)
/// - `screen_calibration_on` / `screen_calibration_off` — screen-direction calibration session boundaries (M3-T04)
/// - `legacy_shield_on` / `legacy_shield_off` — legacy owner-absent blur transitions
/// - `metrics`              — periodic throughput/latency summary (~every 2 s)
/// - `capture_metrics`      — periodic camera capture summary (~every 5 s)
///
/// Field notes (plan sections 9/11, M1-T06 + M2-T07):
/// - `track_id`: the tracker UUID in short form — the FIRST 8 CHARACTERS of
///   the canonical (uppercase) UUID string (see `shortTrackID(_:)`), long
///   enough to disambiguate the handful of concurrent tracks while keeping
///   lines compact; collisions remain theoretically possible and acceptable
///   for human-readable logs.
/// - `yaw`/`pitch`/`roll`: degrees; `na` when Vision supplied no complete
///   pose (or none was evaluated for the track this frame).
/// - `attention_score`/`attention_state`: per-track classifier output.
/// - `looking_duration_ms`: time since the track's current looking episode
///   began; 0.0 when the track is not in one.
/// - `last_seen_age_ms`: age of the track's last matched detection.
/// - `identity_check_age_ms`: age of the last recognition pass; `na` before
///   the first check.
/// - `latency_ms`: detection + recognition + classification time of the frame
///   the track came from.
///
/// All output is gated by the persisted debug flag (UserDefaults key
/// "debugLoggingEnabled", default false). When disabled, every call returns
/// before any string is built, so normal mode pays no logging overhead and
/// stays completely silent.
enum DiagnosticsLog {

    /// Debug gate, persisted across launches. Default: false (silent).
    static var isDebugLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "debugLoggingEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "debugLoggingEnabled") }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Events

    /// One event per processed track per frame (M2-T07). Carries the track's
    /// full per-frame state plus the timing fields needed to debug
    /// multi-person sessions from logs alone.
    static func track(
        trackID: UUID,
        identity: IdentityState,
        boundingBox: CGRect,
        pose: HeadPoseResult?,
        attention: AttentionResult?,
        lookingSince: Date?,
        lastSeen: Date,
        lastIdentityCheck: Date?,
        distanceBand: DistanceBand? = nil,
        now: Date,
        latencyMS: Double
    ) {
        guard isDebugLoggingEnabled else { return }

        var parts: [String] = [
            "event=track",
            "track_id=\(shortTrackID(trackID))",
            "identity=\(name(of: identity))",
            "face_width=\(String(format: "%.3f", boundingBox.width))",
            "bbox=\(String(format: "%.2f,%.2f,%.2fx%.2f", boundingBox.origin.x, boundingBox.origin.y, boundingBox.width, boundingBox.height))"
        ]

        if case .valid(let headPose)? = pose {
            parts.append("yaw=\(signedDegrees(headPose.yaw))")
            parts.append("pitch=\(signedDegrees(headPose.pitch))")
            parts.append("roll=\(signedDegrees(headPose.roll))")
        } else {
            parts.append(contentsOf: ["yaw=na", "pitch=na", "roll=na"])
        }

        if let attention {
            parts.append("attention_score=\(String(format: "%.2f", attention.score))")
            parts.append("attention_state=\(name(of: attention.state))")
        } else {
            parts.append(contentsOf: ["attention_score=na", "attention_state=na"])
        }

        // Distance band (M3-T04); `na` before the first band classification.
        parts.append("distance_band=\(distanceBand.map { name(of: $0) } ?? "na")")

        // looking_duration_ms is 0.0 when the track is not in an active
        // looking episode (explicit zero, per M2-T07).
        let lookingDuration = lookingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
        parts.append("looking_duration_ms=\(String(format: "%.0f", lookingDuration * 1000))")

        let seenAge = max(0, now.timeIntervalSince(lastSeen))
        parts.append("last_seen_age_ms=\(String(format: "%.0f", seenAge * 1000))")

        if let lastIdentityCheck {
            let checkAge = max(0, now.timeIntervalSince(lastIdentityCheck))
            parts.append("identity_check_age_ms=\(String(format: "%.0f", checkAge * 1000))")
        } else {
            parts.append("identity_check_age_ms=na")
        }

        parts.append("latency_ms=\(String(format: "%.1f", latencyMS))")
        emit(parts)
    }

    /// One event per per-track distance-band change (M3-T04): `band` is the
    /// hysteresis-refined band now in effect, `previous` the band the track
    /// carried before this frame (`nil` for a new track's first
    /// classification). Fires only on transitions, so band-stable frames add
    /// no log lines.
    static func bandChange(trackID: UUID, band: DistanceBand, previous: DistanceBand?) {
        guard isDebugLoggingEnabled else { return }

        var parts = [
            "event=band_change",
            "track_id=\(shortTrackID(trackID))",
            "distance_band=\(name(of: band))"
        ]
        if let previous { parts.append("previous_band=\(name(of: previous))") }
        emit(parts)
    }

    /// One event per recognition-caching decision (M2-T07): `decision` is
    /// `recognize_now` or `cached`; `reason` is the policy's
    /// `RecognitionReason` description; `identity` is present when a fresh
    /// recognition result was written.
    static func recognition(trackID: UUID, decision: String, reason: String, identity: IdentityState? = nil) {
        guard isDebugLoggingEnabled else { return }

        var parts = [
            "event=recognition",
            "track_id=\(shortTrackID(trackID))",
            "decision=\(decision)",
            "reason=\(reason)"
        ]
        if let identity { parts.append("identity=\(name(of: identity))") }
        emit(parts)
    }

    /// One event per state transition: per-track `alert_on` / `alert_off`
    /// (with `trackID`) and the legacy `legacy_shield_on` / `legacy_shield_off`.
    static func transition(_ event: String, trackID: UUID? = nil, detail: String? = nil) {
        guard isDebugLoggingEnabled else { return }

        var parts = ["event=\(event)"]
        if let trackID { parts.append("track_id=\(shortTrackID(trackID))") }
        if let detail { parts.append("detail=\(detail)") }
        emit(parts)
    }

    /// Periodic processing summary. `visionFPS` counts frames that went
    /// through the full recognition pipeline per wall-clock second;
    /// `recognitions` counts FaceRecognizer runs within the window (M2-T06:
    /// this is the number the caching policy drives down). The caller drives
    /// the ~2 s cadence.
    static func metrics(visionFPS: Double, latencyMS: Double, faceCount: Int, recognitions: Int) {
        guard isDebugLoggingEnabled else { return }

        emit([
            "event=metrics",
            "vision_fps=\(String(format: "%.1f", visionFPS))",
            "latency_ms=\(String(format: "%.1f", latencyMS))",
            "faces=\(faceCount)",
            "recognitions=\(recognitions)"
        ])
    }

    /// Periodic camera capture summary (M1-T03). The caller drives the ~5 s
    /// cadence; `captureFPS` is the measured capture-side FPS over the last
    /// ~1 s window, `throttled` flags capture running meaningfully below the
    /// pinned format's FPS, and `format` names the pinned format (`nil` when
    /// the device default was kept — reported as "unknown").
    static func captureMetrics(captureFPS: Double, throttled: Bool, format: String?) {
        guard isDebugLoggingEnabled else { return }

        emit([
            "event=capture_metrics",
            "capture_fps=\(String(format: "%.1f", captureFPS))",
            "throttled=\(throttled ? "true" : "false")",
            "format=\(format ?? "unknown")"
        ])
    }

    // MARK: - Field helpers

    /// Short, human-friendly track identifier for logs: the first 8
    /// characters of the canonical uppercase UUID string (M2-T07).
    static func shortTrackID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    /// Stable textual name for an `AttentionState` (log-facing; also used by
    /// FaceDetector when building transition details).
    static func name(of state: AttentionState) -> String {
        switch state {
        case .looking: return "looking"
        case .notLooking: return "notLooking"
        case .uncertain: return "uncertain"
        }
    }

    /// Stable textual name for an `IdentityState` (log-facing, M2-T07).
    static func name(of identity: IdentityState) -> String {
        switch identity {
        case .owner: return "owner"
        case .trusted: return "trusted"
        case .other: return "other"
        case .unknown: return "unknown"
        }
    }

    /// Stable textual name for a `DistanceBand` (log-facing, M3-T04).
    static func name(of band: DistanceBand) -> String {
        switch band {
        case .near: return "near"
        case .mid: return "mid"
        case .far: return "far"
        case .tooFarOrUnreliable: return "too_far"
        }
    }

    private static func signedDegrees(_ degrees: Double) -> String {
        return String(format: "%+.1f", degrees)
    }

    // MARK: - Emission

    /// Prepends the timestamp and prints the joined line. Callers (and this
    /// function) gate on the debug flag BEFORE building field strings so
    /// disabled mode stays free of formatting work.
    private static func emit(_ fields: [String]) {
        guard isDebugLoggingEnabled else { return }
        print("ts=\(timestampFormatter.string(from: Date())) | " + fields.joined(separator: " | "))
    }
}
