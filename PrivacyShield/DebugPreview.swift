import AppKit
import Foundation

// MARK: - Debug preview data model (M4-T05)
//
// Phase 11 of the development plan ("Debug View") mandates a camera preview
// overlay for tuning the 1–4 m range: per-face state (track ID, identity,
// face width / distance band, yaw/pitch/roll, attention score/state,
// looking duration) plus global diagnostics (capture FPS, Vision FPS,
// latency, active track count, camera format, screen-center calibration).
//
// Hard requirements from the plan (implement_todolist.md M4-T05):
// - The preview can be toggled off completely (`hide()`); nothing in this
//   file ever shows it on its own — normal menu-bar-only operation never
//   constructs/calls `show()`.
// - The preview NEVER alters detection decisions: it is a pure sink. It only
//   renders the snapshots handed to it and holds no state the pipeline reads
//   back; no module consults it before classifying, tracking or shielding.
// - Data-driven: a LATER integration task (M4-T06) wires `FaceDetector` to
//   `DebugPreviewModel.update`; this file owns no pipeline references.
//
// Threading contract: `update`/`render` may be called from the detector's
// background queue; both hop their observable effects to the main thread
// internally. No locking: the model is last-write-wins by design (a debug
// view that occasionally shows the previous frame's snapshot is harmless;
// blocking the detection queue behind a UI lock would not be).

/// Per-face row of the debug overlay: everything the plan's Phase 11 mockup
/// shows for one person, as plain values (no `FaceTrack` reference, so the
/// detector can build this off its snapshot without exposing tracker state).
struct DebugFaceInfo: Equatable {
    /// Stable track identity (the `FaceTrack.id` UUID).
    let trackID: UUID
    /// Recognition label (non-optional, matching the `FaceTrack` field: new
    /// tracks start at `.unknown`, so a "never recognized" track renders as
    /// UNKNOWN, not as "—").
    let identity: IdentityState
    /// Latest detection box, normalized Vision coordinates (origin
    /// bottom-left, each axis 0...1 of the frame).
    let boundingBox: CGRect
    /// Normalized face width (bounding-box width as fraction of frame width),
    /// the input of the distance-band classifier.
    let faceWidth: Double
    /// Hysteresis-refined distance band; `nil` before the first
    /// classification.
    let distanceBand: DistanceBand?
    /// Head pose in degrees; `nil` when Vision supplied no complete pose.
    let yaw: Double?
    let pitch: Double?
    let roll: Double?
    /// Continuous attention score in [0, 1]; `nil` before the first
    /// evaluation.
    let attentionScore: Double?
    let attentionState: AttentionState?
    /// Seconds in the current sustained-looking episode (0 when not in one).
    let lookingDuration: TimeInterval
}

/// Calibrated screen-facing center (the pair `ScreenCenterStore.load`
/// returns) as its own `Equatable` struct: tuples are not `Equatable`, so
/// `DebugPreviewState` cannot embed the store's `(yaw:pitch:)` tuple.
struct DebugScreenCenter: Equatable {
    let yaw: Double
    let pitch: Double
}

/// One immutable snapshot of everything the overlay shows. The detector (or
/// any future integration code) builds one per processed frame and hands it
/// to `DebugPreviewModel.update`.
struct DebugPreviewState: Equatable {
    var faces: [DebugFaceInfo] = []
    /// Camera capture throughput (fps); `nil` while unknown.
    var captureFPS: Double? = nil
    /// Vision pipeline throughput (fps); `nil` while unknown.
    var visionFPS: Double? = nil
    /// Detection + recognition + classification latency of the frame (ms);
    /// `nil` while unknown.
    var latencyMs: Double? = nil
    /// Number of live tracks after the most recent association pass.
    var activeTrackCount: Int = 0
    /// Selected camera format, e.g. "1920x1080@30"; `nil` while unknown.
    var cameraFormat: String? = nil
    /// Calibrated screen center; `nil` while not calibrated (rendered as
    /// "not calibrated", never as zeros — missing calibration must stay
    /// distinguishable from a frontal pose, mirroring `ScreenCenterStore`).
    var screenCenter: DebugScreenCenter? = nil
}

// MARK: - Model

/// Holds the latest `DebugPreviewState` and forwards it (on the main thread)
/// to a single consumer — the window controller's `render`.
///
/// This is the ONLY surface the future `FaceDetector` integration (M4-T06)
/// touches:
///
///     let model = DebugPreviewModel()
///     model.onStateChanged = { previewWindow.render($0) }
///     // from the detector's processing queue:
///     model.update(someDebugPreviewState)
///
/// It never reads back into the pipeline: the preview does not alter
/// detection decisions, it only renders the data it is given (plan M4-T05).
final class DebugPreviewModel {

    /// Called on the MAIN thread with every snapshot (updates arriving from a
    /// background queue are hopped to main internally). Intended assignment:
    /// `model.onStateChanged = { windowController.render($0) }`.
    var onStateChanged: ((DebugPreviewState) -> Void)?

    /// Most recent snapshot (last write wins). Empty state before the first
    /// `update`.
    private(set) var currentState = DebugPreviewState()

    /// Stores `state` and notifies `onStateChanged`. Callable from any queue
    /// (the detector's background queue included); the callback always fires
    /// on the main thread. Note: `currentState` is written synchronously so a
    /// caller reading it right after `update` sees this snapshot.
    func update(_ state: DebugPreviewState) {
        currentState = state
        guard let onChanged = onStateChanged else { return }
        if Thread.isMainThread {
            onChanged(state)
        } else {
            DispatchQueue.main.async { onChanged(state) }
        }
    }
}

// MARK: - Formatting (pure, unit-tested)

/// Pure text formatters for the overlay labels (M4-T05). Kept separate from
/// the view so the exact strings are unit-testable without AppKit windows.
/// Field conventions mirror `DiagnosticsLog` where one exists (short track
/// ID, band/identity/state names) so logs and overlay always agree.
enum DebugPreviewFormatting {

    /// Placeholder for a missing value ("—" U+2014 EM DASH), matching the
    /// plan's "—" convention for unknown metrics.
    static let unknownValue = "—"

    /// Short track identifier: first 8 characters of the canonical uppercase
    /// UUID — the same convention as `DiagnosticsLog.shortTrackID` (M2-T07);
    /// reused verbatim so logs and the overlay agree.
    static func shortTrackID(_ id: UUID) -> String {
        DiagnosticsLog.shortTrackID(id)
    }

    /// Uppercase identity name for the label block (plan mockup: "OTHER"),
    /// "—" when the identity is unknown/unset.
    static func identityName(_ identity: IdentityState?) -> String {
        guard let identity else { return unknownValue }
        switch identity {
        case .owner: return "OWNER"
        case .trusted: return "TRUSTED"
        case .other: return "OTHER"
        case .unknown: return "UNKNOWN"
        }
    }

    /// Distance-band name ("near"/"mid"/"far"/"too_far" — the
    /// `DiagnosticsLog` names), "—" before the first classification.
    static func bandName(_ band: DistanceBand?) -> String {
        guard let band else { return unknownValue }
        return DiagnosticsLog.name(of: band)
    }

    /// Attention-state name ("looking"/"notLooking"/"uncertain"), "—" when
    /// the track has not been evaluated yet.
    static func attentionStateName(_ state: AttentionState?) -> String {
        guard let state else { return unknownValue }
        return DiagnosticsLog.name(of: state)
    }

    /// Signed degrees ("%+.1f°", same format as `DiagnosticsLog`'s pose
    /// fields), "—" when Vision supplied no complete pose.
    static func degrees(_ angle: Double?) -> String {
        guard let angle else { return unknownValue }
        return String(format: "%+.1f°", angle)
    }

    /// Attention score ("%.2f"), "—" before the first evaluation.
    static func score(_ value: Double?) -> String {
        guard let value else { return unknownValue }
        return String(format: "%.2f", value)
    }

    /// Sustained-looking duration ("%.2f s").
    static func duration(_ seconds: TimeInterval) -> String {
        String(format: "%.2f s", seconds)
    }

    /// Throughput ("%.1f"), "—" while unknown.
    static func fps(_ value: Double?) -> String {
        guard let value else { return unknownValue }
        return String(format: "%.1f", value)
    }

    /// Latency in milliseconds ("%.1f"), "—" while unknown.
    static func latencyMs(_ value: Double?) -> String {
        guard let value else { return unknownValue }
        return String(format: "%.1f", value)
    }

    /// Formatted screen center ("yaw %+.1f°  pitch %+.1f°"), or
    /// "not calibrated" when `nil` — never zeros.
    static func screenCenterText(_ center: DebugScreenCenter?) -> String {
        guard let center else { return "not calibrated" }
        return String(format: "yaw %+.1f°  pitch %+.1f°", center.yaw, center.pitch)
    }

    /// The multi-line label block drawn next to one face box: short track ID,
    /// identity, face width + distance band, yaw/pitch/roll, attention score
    /// + state, looking duration (plan section 15). Unknown values render
    /// as "—".
    static func faceLabel(_ face: DebugFaceInfo) -> String {
        return [
            "id: \(shortTrackID(face.trackID))",
            "identity: \(identityName(face.identity))",
            "width: \(String(format: "%.3f", face.faceWidth))  band: \(bandName(face.distanceBand))",
            "yaw: \(degrees(face.yaw))  pitch: \(degrees(face.pitch))  roll: \(degrees(face.roll))",
            "attention: \(score(face.attentionScore)) \(attentionStateName(face.attentionState))",
            "looking: \(duration(face.lookingDuration))"
        ].joined(separator: "\n")
    }

    /// The global diagnostics block: capture FPS, Vision FPS, latency,
    /// active track count, camera format and the calibrated screen center
    /// ("not calibrated" when none).
    static func globalSummary(_ state: DebugPreviewState) -> String {
        return [
            "capture: \(fps(state.captureFPS)) fps",
            "vision: \(fps(state.visionFPS)) fps",
            "latency: \(latencyMs(state.latencyMs)) ms",
            "tracks: \(state.activeTrackCount)",
            "format: \(state.cameraFormat ?? unknownValue)",
            "center: \(screenCenterText(state.screenCenter))"
        ].joined(separator: "\n")
    }
}

// MARK: - Overlay view

/// Draws the debug overlay for one `DebugPreviewState`: a dark translucent
/// backdrop, one rounded-rect box per face (scaled from normalized Vision
/// coordinates) with its label block, and the global summary block.
///
/// Coordinate mapping: this view is NOT flipped, so like Vision's normalized
/// boxes its origin is the bottom-left corner with y growing upward — the
/// normalized box maps linearly onto the stage rect with no axis flips.
final class DebugPreviewView: NSView {

    private static let backdropColor = NSColor(white: 0.0, alpha: 0.72)
    private static let labelBackgroundColor = NSColor(white: 0.0, alpha: 0.65)
    private static let textColor = NSColor.white
    private static let stageInset: CGFloat = 16
    private static let boxInset: CGFloat = 6
    private static let labelPadding: CGFloat = 5
    private static let labelGap: CGFloat = 4

    /// Most recent snapshot to draw; `nil` shows just the backdrop.
    private var state: DebugPreviewState?

    /// Replaces the drawn snapshot (main thread only — `render` hops here).
    func update(state: DebugPreviewState) {
        self.state = state
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.backdropColor.setFill()
        bounds.fill()

        guard let state else { return }
        let stage = bounds.insetBy(dx: Self.stageInset, dy: Self.stageInset)
        drawGlobalSummary(state, in: stage)
        for face in state.faces {
            drawFace(face, in: stage)
        }
    }

    // MARK: Per-face drawing

    private func drawFace(_ face: DebugFaceInfo, in stage: NSRect) {
        let box = mappedBox(face.boundingBox, in: stage)
        let color = Self.identityColor(face.identity)

        let path = NSBezierPath(roundedRect: box.insetBy(dx: Self.boxInset, dy: Self.boxInset),
                                xRadius: 6, yRadius: 6)
        color.setStroke()
        path.lineWidth = 2
        path.stroke()

        drawLabel(DebugPreviewFormatting.faceLabel(face),
                  color: color,
                  anchoredTo: box,
                  in: stage)
    }

    /// Draws `text` in a filled block anchored above `box`'s top edge,
    /// clamped to stay inside `stage` (inside the box near the top of the
    /// screen, shifted left near the right edge).
    private func drawLabel(_ text: String, color: NSColor, anchoredTo box: NSRect, in stage: NSRect) {
        let attributed = attributedText(text, fontSize: 12)
        let textSize = attributed.size()

        var origin = NSPoint(x: box.minX + Self.boxInset,
                             y: box.maxY + Self.labelGap)
        if origin.y + textSize.height > stage.maxY {
            origin.y = max(stage.minY, box.maxY - textSize.height - Self.labelGap)
        }
        if origin.x + textSize.width > stage.maxX {
            origin.x = max(stage.minX, stage.maxX - textSize.width)
        }

        let labelRect = NSRect(origin: origin,
                               size: NSSize(width: textSize.width, height: textSize.height))
            .insetBy(dx: -Self.labelPadding, dy: -Self.labelPadding)
        let background = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        Self.labelBackgroundColor.setFill()
        background.fill()

        color.setStroke()
        background.lineWidth = 1
        background.stroke()

        attributed.draw(at: origin)
    }

    // MARK: Global summary drawing

    private func drawGlobalSummary(_ state: DebugPreviewState, in stage: NSRect) {
        let attributed = attributedText(DebugPreviewFormatting.globalSummary(state), fontSize: 12)
        let textSize = attributed.size()
        let origin = NSPoint(x: stage.minX, y: stage.minY)
        let blockRect = NSRect(origin: origin,
                               size: NSSize(width: textSize.width, height: textSize.height))
            .insetBy(dx: -Self.labelPadding, dy: -Self.labelPadding)
        let background = NSBezierPath(roundedRect: blockRect, xRadius: 4, yRadius: 4)
        Self.labelBackgroundColor.setFill()
        background.fill()

        attributed.draw(at: origin)
    }

    // MARK: Helpers

    /// Normalized Vision box (origin bottom-left, 0...1 per axis) → view
    /// coordinates within `stage`. No y flip needed: both coordinate systems
    /// are bottom-left origin, y-up.
    private func mappedBox(_ box: CGRect, in stage: NSRect) -> NSRect {
        return NSRect(
            x: stage.minX + box.minX * stage.width,
            y: stage.minY + box.minY * stage.height,
            width: box.width * stage.width,
            height: box.height * stage.height
        )
    }

    private func attributedText(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: Self.textColor
            ]
        )
    }

    /// Box/label accent per identity — quick visual identity at a glance.
    private static func identityColor(_ identity: IdentityState?) -> NSColor {
        switch identity {
        case .owner: return .systemGreen
        case .trusted: return .systemBlue
        case .other: return .systemRed
        case .unknown: return .systemYellow
        case nil: return .systemGray
        }
    }
}

// MARK: - Window controller

/// Borderless window subclass that can never become key or main, so showing
/// the debug preview never steals keyboard focus from the user's work.
final class DebugPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the full-screen debug overlay window (M4-T05).
///
/// Lifecycle contract (plan M4-T05):
/// - Nothing here shows itself: the window is only created inside `show()`,
///   which a future menu/debug integration calls explicitly. Normal
///   menu-bar-only operation never constructs this controller or calls
///   `show()`, so the preview is absent from normal operation.
/// - `hide()` is the complete toggle-off: the window is ordered out and
///   subsequent `render` calls are no-ops until the next `show()`.
/// - The preview does not alter detection decisions: it renders the states
///   handed to `render` and exposes nothing the pipeline reads back.
///
/// Threading: `render` is safe from any queue (drawing hops to main);
/// `show`/`hide` are cheap main-thread hops as well. Like `ShieldManager`,
/// the window is built lazily on first `show()` and floats at the same
/// screen-saver window level.
final class DebugPreviewWindowController {

    /// Same stacking level `ShieldManager` uses for the blur overlay, so the
    /// preview floats above regular app windows.
    private static let windowLevel = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))

    private var window: DebugPreviewWindow?
    private let overlayView = DebugPreviewView(frame: .zero)
    /// Last snapshot received (kept even while hidden so `show()` can draw
    /// the current state immediately instead of waiting for the next frame).
    private var lastState: DebugPreviewState?

    /// True while the overlay is on screen. `hide()` → false, `show()` → true.
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func show() {
        runOnMain { [weak self] in self?.performShow() }
    }

    func hide() {
        runOnMain { [weak self] in self?.performHide() }
    }

    /// Renders one state snapshot. No-op while hidden (per plan: toggling the
    /// preview off must cost nothing). Safe from any queue.
    func render(_ state: DebugPreviewState) {
        runOnMain { [weak self] in
            guard let self else { return }
            self.lastState = state
            guard self.isVisible, let overlayView = self.window?.contentView as? DebugPreviewView else { return }
            overlayView.update(state: state)
        }
    }

    // MARK: Internals (main thread)

    private func performShow() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        if let lastState {
            overlayView.update(state: lastState)
        }
        // Frontmost without stealing key focus (the window subclass refuses
        // key/main status).
        window.orderFrontRegardless()
    }

    private func performHide() {
        window?.orderOut(nil)
    }

    private func buildWindow() {
        guard let screen = NSScreen.main else { return }
        let window = DebugPreviewWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = Self.windowLevel
        window.backgroundColor = .clear
        window.isOpaque = false
        // Fully non-interactive: clicks pass through; the only way to dismiss
        // the preview is the programmatic `hide()`.
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        overlayView.frame = NSRect(origin: .zero, size: screen.frame.size)
        overlayView.autoresizingMask = [.width, .height]
        window.contentView = overlayView

        self.window = window
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
