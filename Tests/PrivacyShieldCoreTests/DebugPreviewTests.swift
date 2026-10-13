import XCTest
@testable import PrivacyShieldCore

/// Debug-preview model + formatting tests (M4-T05): pure model logic only —
/// no AppKit windows or views are constructed (the overlay itself needs a
/// window server and stays untested here, matching the plan's unit-test
/// scope for this task).
///
/// Covered contracts:
/// - `DebugPreviewModel.update` stores the snapshot (last update wins) and
///   fires `onStateChanged` on the MAIN thread, even when `update` is called
///   from a background queue (the detector's processing queue in M4-T06).
/// - `DebugPreviewFormatting.faceLabel` / `globalSummary` render every plan
///   field with the documented conventions: signed degrees (%+.1f°),
///   score (%.2f), duration (%.2f s), and "—" for missing values.
/// - `DebugPreviewState` (and `DebugFaceInfo`) `Equatable` synthesis.
final class DebugPreviewTests: XCTestCase {

    // MARK: - Fixtures

    /// Fixed UUID whose canonical uppercase form starts with "A1B2C3D4", so
    /// `shortTrackID` is deterministic in assertions.
    private let fixedTrackID = UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-0123456789AB")!

    private func makeFace(
        identity: IdentityState = .other,
        faceWidth: Double = 0.312,
        distanceBand: DistanceBand? = .mid,
        yaw: Double? = 12.34,
        pitch: Double? = -4.56,
        roll: Double? = 1.2,
        attentionScore: Double? = 0.88,
        attentionState: AttentionState? = .looking,
        lookingDuration: TimeInterval = 1.25
    ) -> DebugFaceInfo {
        DebugFaceInfo(
            trackID: fixedTrackID,
            identity: identity,
            boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.312, height: 0.4),
            faceWidth: faceWidth,
            distanceBand: distanceBand,
            yaw: yaw,
            pitch: pitch,
            roll: roll,
            attentionScore: attentionScore,
            attentionState: attentionState,
            lookingDuration: lookingDuration
        )
    }

    private func makeState(
        faces: [DebugFaceInfo] = [],
        captureFPS: Double? = 30.0,
        visionFPS: Double? = 8.5,
        latencyMs: Double? = 14.2,
        activeTrackCount: Int = 2,
        cameraFormat: String? = "1920x1080@30",
        screenCenter: DebugScreenCenter? = DebugScreenCenter(yaw: -1.5, pitch: 2.5)
    ) -> DebugPreviewState {
        DebugPreviewState(
            faces: faces,
            captureFPS: captureFPS,
            visionFPS: visionFPS,
            latencyMs: latencyMs,
            activeTrackCount: activeTrackCount,
            cameraFormat: cameraFormat,
            screenCenter: screenCenter
        )
    }

    // MARK: - Model state storage

    func testInitialStateIsEmpty() {
        let model = DebugPreviewModel()
        XCTAssertEqual(model.currentState, DebugPreviewState())
    }

    func testUpdateStoresStateAndCurrentStateReflectsLastUpdate() {
        let model = DebugPreviewModel()

        let first = makeState(activeTrackCount: 1)
        model.update(first)
        XCTAssertEqual(model.currentState, first)

        // Last update wins, replacing the previous snapshot entirely.
        let second = makeState(
            faces: [makeFace()],
            activeTrackCount: 3,
            cameraFormat: "1280x720@60",
            screenCenter: nil
        )
        model.update(second)
        XCTAssertEqual(model.currentState, second)
        XCTAssertNotEqual(model.currentState, first)
        XCTAssertEqual(model.currentState.faces.count, 1)
    }

    func testUpdateCallsBackSynchronouslyOnMainThread() {
        let model = DebugPreviewModel()
        var received: DebugPreviewState?
        var callbackWasOnMain = false
        model.onStateChanged = { state in
            received = state
            callbackWasOnMain = Thread.isMainThread
        }

        let state = makeState()
        model.update(state)

        XCTAssertTrue(callbackWasOnMain)
        XCTAssertEqual(received, state)
    }

    func testUpdateFromBackgroundQueueHopsCallbackToMain() {
        let model = DebugPreviewModel()
        let callbackExpectation = expectation(description: "onStateChanged fired")
        var received: DebugPreviewState?
        var callbackWasOnMain = false
        model.onStateChanged = { state in
            received = state
            callbackWasOnMain = Thread.isMainThread
            callbackExpectation.fulfill()
        }

        let state = makeState(faces: [makeFace(identity: .owner)])
        let queue = DispatchQueue(label: "test.debugpreview.update")
        queue.async { model.update(state) }

        // wait(for:) pumps the main run loop, so the main-queue hop runs.
        wait(for: [callbackExpectation], timeout: 2.0)
        XCTAssertTrue(callbackWasOnMain)
        XCTAssertEqual(received, state)
    }

    // MARK: - Face label formatting

    func testFaceLabelContainsAllPopulatedFields() {
        let label = DebugPreviewFormatting.faceLabel(makeFace())

        // Short track ID: first 8 chars of the canonical uppercase UUID,
        // same convention as DiagnosticsLog.shortTrackID.
        XCTAssertTrue(label.contains("A1B2C3D4"))
        // Identity (uppercase, plan mockup convention).
        XCTAssertTrue(label.contains("OTHER"))
        // Face width + distance band.
        XCTAssertTrue(label.contains("0.312"))
        XCTAssertTrue(label.contains("mid"))
        // Signed degrees with the %+.1f format.
        XCTAssertTrue(label.contains("+12.3°"))
        XCTAssertTrue(label.contains("-4.6°"))
        XCTAssertTrue(label.contains("+1.2°"))
        // Attention score (%.2f) + state name.
        XCTAssertTrue(label.contains("0.88"))
        XCTAssertTrue(label.contains("looking"))
        // Looking duration (%.2f s).
        XCTAssertTrue(label.contains("1.25 s"))
    }

    func testFaceLabelNilsRenderAsEmDash() {
        let label = DebugPreviewFormatting.faceLabel(makeFace(
            identity: .other,
            distanceBand: nil,
            yaw: nil,
            pitch: nil,
            roll: nil,
            attentionScore: nil,
            attentionState: nil
        ))

        // Every missing value shows "—", and no stale numbers leak through.
        XCTAssertFalse(label.contains("+"), "no signed value expected when all pose/score fields are nil: \(label)")
        XCTAssertFalse(label.contains("0.88"))
        // Band, three pose angles, score and state = six dashes; identity is
        // non-optional on the struct, so it always renders a real name.
        XCTAssertEqual(label.filter { $0 == "—" }.count, 6)
        // The always-present fields still render.
        XCTAssertTrue(label.contains("A1B2C3D4"))
        XCTAssertTrue(label.contains("OTHER"))
        XCTAssertTrue(label.contains("1.25 s"))
    }

    func testFaceLabelUnknownIdentityRendersUNKNOWN() {
        let label = DebugPreviewFormatting.faceLabel(makeFace(
            identity: .unknown,
            yaw: nil, pitch: nil, roll: nil,
            attentionScore: nil, attentionState: nil,
            lookingDuration: 0
        ))
        // A not-yet-recognized track shows UNKNOWN (distinct from "—", which
        // is reserved for missing data at the formatter level).
        XCTAssertTrue(label.contains("identity: UNKNOWN"))
        XCTAssertTrue(label.contains("band: mid"))
        XCTAssertTrue(label.contains("looking: 0.00 s"))
        // The formatter still covers the defensive nil case for callers
        // without a struct value.
        XCTAssertEqual(DebugPreviewFormatting.identityName(nil), "—")
    }

    func testShortTrackIDMatchesDiagnosticsLogConvention() {
        XCTAssertEqual(
            DebugPreviewFormatting.shortTrackID(fixedTrackID),
            DiagnosticsLog.shortTrackID(fixedTrackID)
        )
        XCTAssertEqual(DebugPreviewFormatting.shortTrackID(fixedTrackID), "A1B2C3D4")
    }

    // MARK: - Identity / band / state names

    func testIdentityNameCoversAllCasesAndNil() {
        XCTAssertEqual(DebugPreviewFormatting.identityName(.owner), "OWNER")
        XCTAssertEqual(DebugPreviewFormatting.identityName(.trusted), "TRUSTED")
        XCTAssertEqual(DebugPreviewFormatting.identityName(.other), "OTHER")
        XCTAssertEqual(DebugPreviewFormatting.identityName(.unknown), "UNKNOWN")
        XCTAssertEqual(DebugPreviewFormatting.identityName(nil), "—")
    }

    func testBandAndAttentionStateNamesUseDiagnosticsLogNames() {
        XCTAssertEqual(DebugPreviewFormatting.bandName(.near), "near")
        XCTAssertEqual(DebugPreviewFormatting.bandName(.mid), "mid")
        XCTAssertEqual(DebugPreviewFormatting.bandName(.far), "far")
        XCTAssertEqual(DebugPreviewFormatting.bandName(.tooFarOrUnreliable), "too_far")
        XCTAssertEqual(DebugPreviewFormatting.bandName(nil), "—")

        XCTAssertEqual(DebugPreviewFormatting.attentionStateName(.looking), "looking")
        XCTAssertEqual(DebugPreviewFormatting.attentionStateName(.notLooking), "notLooking")
        XCTAssertEqual(DebugPreviewFormatting.attentionStateName(.uncertain), "uncertain")
        XCTAssertEqual(DebugPreviewFormatting.attentionStateName(nil), "—")
    }

    // MARK: - Global summary formatting

    func testGlobalSummaryContainsAllPopulatedFields() {
        let summary = DebugPreviewFormatting.globalSummary(makeState(
            faces: [makeFace(), makeFace()],
            captureFPS: 30.0,
            visionFPS: 8.5,
            latencyMs: 14.2,
            activeTrackCount: 2,
            cameraFormat: "1920x1080@30",
            screenCenter: DebugScreenCenter(yaw: -1.5, pitch: 2.5)
        ))

        XCTAssertTrue(summary.contains("30.0"))
        XCTAssertTrue(summary.contains("8.5"))
        XCTAssertTrue(summary.contains("14.2"))
        XCTAssertTrue(summary.contains("tracks: 2"))
        XCTAssertTrue(summary.contains("1920x1080@30"))
        // Calibrated screen center: signed degrees, never "not calibrated".
        XCTAssertTrue(summary.contains("yaw -1.5°"))
        XCTAssertTrue(summary.contains("pitch +2.5°"))
        XCTAssertFalse(summary.contains("not calibrated"))
    }

    func testGlobalSummaryNilsRenderAsPlaceholders() {
        let summary = DebugPreviewFormatting.globalSummary(makeState(
            faces: [],
            captureFPS: nil,
            visionFPS: nil,
            latencyMs: nil,
            activeTrackCount: 0,
            cameraFormat: nil,
            screenCenter: nil
        ))

        XCTAssertTrue(summary.contains("not calibrated"))
        XCTAssertFalse(summary.contains("yaw +"))
        XCTAssertTrue(summary.contains("tracks: 0"))
        // Missing fps (capture + vision), latency and format render as
        // "—", not as zeros.
        XCTAssertFalse(summary.contains("0.0 fps"))
        XCTAssertFalse(summary.contains("0.0 ms"))
        XCTAssertEqual(summary.filter { $0 == "—" }.count, 4)
    }

    // MARK: - Equatable synthesis

    func testEqualStatesCompareEqual() {
        let state = makeState(faces: [makeFace()])
        let copy = makeState(faces: [makeFace()])
        XCTAssertEqual(state, copy)

        var other = state
        other.activeTrackCount += 1
        XCTAssertNotEqual(state, other)

        other = state
        other.captureFPS = 29.9
        XCTAssertNotEqual(state, other)

        other = state
        other.screenCenter = DebugScreenCenter(yaw: -1.5, pitch: 2.5001)
        XCTAssertNotEqual(state, other)

        other = state
        other.cameraFormat = nil
        XCTAssertNotEqual(state, other)
    }

    func testEqualFaceInfosCompareEqualAcrossAllFields() {
        let face = makeFace()
        XCTAssertEqual(face, makeFace())

        var other = makeFace(identity: .owner)
        XCTAssertNotEqual(face, other)

        other = makeFace(distanceBand: nil)
        XCTAssertNotEqual(face, other)

        other = makeFace(yaw: nil)
        XCTAssertNotEqual(face, other)

        other = makeFace(attentionState: .notLooking)
        XCTAssertNotEqual(face, other)

        other = makeFace(lookingDuration: 2.5)
        XCTAssertNotEqual(face, other)
    }
}
