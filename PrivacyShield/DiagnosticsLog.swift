import CoreGraphics
import Foundation

/// Structured, one-line debug logging for the attention pipeline (M1-T06).
///
/// Every event prints as a single pipe-separated `key=value` line that can be
/// copied straight into evaluation notes, e.g.:
///
///     ts=2026-10-13T10:12:33.412Z | event=face | track_id=0 | identity=unknown | face_width=0.312 | yaw=+12.4 | pitch=-3.1 | roll=+0.5 | attention_score=0.83 | attention_state=looking | latency_ms=14.2
///
/// Emitted events:
/// - `face`                 — one per processed (nearby, pipeline-eligible) face
/// - `alert_on` / `alert_off`           — attention-path temporal-filter transitions
/// - `legacy_shield_on` / `legacy_shield_off` — legacy owner-absent blur transitions
/// - `metrics`              — periodic throughput/latency summary (~every 2 s)
///
/// Field notes (plan sections 9/11, M1-T06):
/// - `track_id`: M1 uses the per-frame face index; M2 switches to tracker UUIDs.
/// - `yaw`/`pitch`/`roll`: degrees; `na` when Vision supplied no complete pose
///   or when the head-pose path was skipped (owner/trusted face).
/// - `attention_score`/`attention_state`: `na` for owner faces.
/// - `latency_ms`: detection + recognition + classification time of the frame
///   the face came from.
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

    /// One event per processed face. `pose`/`attention` are nil when the
    /// head-pose path was skipped (owner/trusted face) — those fields log
    /// as `na`.
    static func face(
        trackID: Int,
        identity: String,
        faceWidth: CGFloat,
        pose: HeadPoseResult?,
        attention: AttentionResult?,
        latencyMS: Double
    ) {
        guard isDebugLoggingEnabled else { return }

        var parts: [String] = [
            "event=face",
            "track_id=\(trackID)",
            "identity=\(identity)",
            "face_width=\(String(format: "%.3f", faceWidth))"
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

        parts.append("latency_ms=\(String(format: "%.1f", latencyMS))")
        emit(parts)
    }

    /// One event per state transition: `alert_on`, `alert_off`,
    /// `legacy_shield_on`, `legacy_shield_off`.
    static func transition(_ event: String, trackID: Int? = nil, detail: String? = nil) {
        guard isDebugLoggingEnabled else { return }

        var parts = ["event=\(event)"]
        if let trackID { parts.append("track_id=\(trackID)") }
        if let detail { parts.append("detail=\(detail)") }
        emit(parts)
    }

    /// Periodic processing summary. `visionFPS` counts frames that went
    /// through the full recognition pipeline per wall-clock second; the
    /// caller drives the ~2 s cadence.
    static func metrics(visionFPS: Double, latencyMS: Double, faceCount: Int) {
        guard isDebugLoggingEnabled else { return }

        emit([
            "event=metrics",
            "vision_fps=\(String(format: "%.1f", visionFPS))",
            "latency_ms=\(String(format: "%.1f", latencyMS))",
            "faces=\(faceCount)"
        ])
    }

    // MARK: - Field helpers

    /// Stable textual name for an `AttentionState` (log-facing; also used by
    /// FaceDetector when building transition details).
    static func name(of state: AttentionState) -> String {
        switch state {
        case .looking: return "looking"
        case .notLooking: return "notLooking"
        case .uncertain: return "uncertain"
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
