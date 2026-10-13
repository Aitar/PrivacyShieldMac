import Vision
import CoreVideo
import Foundation

protocol FaceDetectorDelegate: AnyObject {
    func updateMenuIcon(safe: Bool)
    // Notifications and the menu status line flow through the reason-aware
    // `PrivacyDisplayReporting.privacyStateChanged(to:)` contract (M4-T06) —
    // the undifferentiated `sendStrangerNotification` entry point was
    // removed so exactly ONE notification path stays active.
}

// MARK: - Global alert aggregation (M2-T04)

/// Pure aggregation rule (M2-T04): turns per-track attention-alert state into
/// the single global shoulder-surf signal.
///
/// Qualifying observer: any track whose identity is NOT trusted-level — i.e.
/// `.other` (recognized stranger) or `.unknown` (recognized yet). `.owner`
/// and `.trusted` faces are the user and trusted company; their own looking
/// behavior never raises the alert (plan §9). `.unknown` counts as
/// qualifying so a freshly created, not-yet-recognized track is treated as a
/// potential observer until its first recognition pass says otherwise.
///
/// Persistence rule: the shield shows while ANY qualifying track is alerting
/// and hides only when none is — a track that stops alerting cannot drop the
/// global alert while another qualifying track still holds its own.
struct ShoulderSurfAggregator {

    /// One track's contribution to the global decision.
    struct TrackObservation {
        let trackID: UUID
        let identity: IdentityState
        let isAlerting: Bool
    }

    /// `.other` and `.unknown` are non-trusted observers; `.owner`/`.trusted`
    /// are trusted-level and never qualify.
    static func isQualifyingObserver(_ identity: IdentityState) -> Bool {
        switch identity {
        case .owner, .trusted: return false
        case .other, .unknown: return true
        }
    }

    /// True while at least one qualifying track's temporal filter is
    /// alerting. Each track's filter holds its own alert until its own
    /// release window elapses, so several strangers never share accumulation
    /// time and the global alert persists until the last qualifying
    /// alerting track clears (or its track expires).
    static func isAnyQualifyingTrackAlerting(_ observations: [TrackObservation]) -> Bool {
        observations.contains { $0.isAlerting && isQualifyingObserver($0.identity) }
    }
}

// MARK: - Settings → policy mappings (M4-T06)

/// Pure M4-T06 mappings between the persisted `AttentionSettings` (M4-T01)
/// and the runtime policy objects, extracted from `FaceDetector` so they are
/// unit-testable without instantiating the detector (which needs a
/// `ShieldManager` and a camera). No state, no clock, no singletons.
enum PrivacySettingsMapping {

    /// Maps a shield reason onto the aggregate display state reported to the
    /// app delegate (M4-T04 contract). The three blur reasons map 1:1;
    /// `.none` reports `.monitoringSafe`. The device states
    /// (`.calibrating` / `.cameraUnavailable`) are never produced here —
    /// the detector reports `.calibrating` directly around its calibration
    /// sessions, and `.cameraUnavailable` is reported by the app delegate at
    /// launch (the detector has no signal for it).
    static func displayState(for reason: PrivacyShieldReason) -> PrivacyDisplayState {
        switch reason {
        case .none:            return .monitoringSafe
        case .ownerAbsent:     return .ownerAbsent
        case .shoulderSurfer:  return .shoulderSurferDetected
        case .both:            return .bothPoliciesActive
        }
    }

    /// Builds the privacy state machine config from the user settings: the
    /// two blur toggles ("Blur When I Leave" / "Blur When Someone Watches")
    /// map 1:1 onto the M4-T03 policy toggles. The owner-presence window
    /// keeps its default — there is no user-facing knob for it yet.
    static func privacyConfig(from settings: AttentionSettings) -> PrivacyStateMachineConfig {
        PrivacyStateMachineConfig(
            blurWhenOwnerAbsent: settings.blurWhenOwnerAbsent,
            blurWhenShoulderSurferDetected: settings.blurWhenShoulderSurferDetected)
    }

    /// Builds the distance-band config from the settings' band boundary
    /// fields (`nearMaxFaceWidth` / `midMaxFaceWidth` / `farMaxFaceWidth`,
    /// M4-T01). Defaults equal `DistanceBandConfig.default`, so first-launch
    /// behavior is unchanged; the fields become tuning inputs the moment a
    /// future settings surface writes them.
    static func bandConfig(from settings: AttentionSettings) -> DistanceBandConfig {
        var config = DistanceBandConfig()
        config.nearMaxWidth = settings.nearMaxFaceWidth
        config.midMaxWidth = settings.midMaxFaceWidth
        config.farMaxWidth = settings.farMaxFaceWidth
        return config
    }
}

class FaceDetector: NSObject, CameraManagerDelegate {
    private let shieldManager: ShieldManager
    let faceRecognizer: FaceRecognizer
    private weak var delegate: FaceDetectorDelegate?

    // MARK: - Privacy policy (M4-T06)

    /// Pure decision core for the two independent privacy policies (M4-T03).
    /// Replaces the legacy owner-absent debounce + OR combination: the
    /// shield now shows exactly when the evaluated `PrivacyShieldReason` is
    /// shown (`isShieldShown`). Its config is rebuilt from the user settings
    /// whenever they change (see `rebuildDerivedState`); var because the
    /// struct's config is swapped in place there.
    private var privacyStateMachine = PrivacyStateMachine()

    /// The reason currently applied to the shield/icon paths (video-queue
    /// confined). Edge tracker: only reason CHANGES drive UI calls, so the
    /// paths can never fight over the icon. Starts `.none` (shield hidden),
    /// matching the pre-frame world and keeping the first safe frame
    /// free of redundant UI calls.
    private var lastAppliedReason: PrivacyShieldReason = .none

    /// The display state last reported via
    /// `PrivacyDisplayReporting.privacyStateChanged(to:)` (video-queue
    /// confined). Separate from `lastAppliedReason` because calibration
    /// wraps the REPORTED state as `.calibrating` while the shield keeps
    /// following the reason underneath.
    private var lastReportedState: PrivacyDisplayState?

    // MARK: - User settings (M4-T01/T06)

    /// The user's attention/shield settings, loaded once at init and
    /// refreshed by `applySettings` whenever the menu changes anything.
    ///
    /// Threading: written from the main thread (menu actions) and read on
    /// the video output queue (once per processed frame), so the value is
    /// guarded by a small lock (the same pattern as `CameraManager`'s
    /// metrics). The DERIVED runtime state — privacy config, per-band
    /// profiles, band classifier boundaries, per-track filter timing
    /// configs — is rebuilt exclusively on the video queue (see
    /// `rebuildDerivedState`), so the pipeline's mutable state stays
    /// queue-confined exactly as before.
    private var settingsStorage: AttentionSettings
    private let settingsLock = NSLock()
    private var settings: AttentionSettings {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return settingsStorage }
        set { settingsLock.lock(); settingsStorage = newValue; settingsLock.unlock() }
    }

    /// The settings snapshot the derived pipeline state was last built from
    /// (video-queue confined). A mismatch with the locked `settings` value
    /// triggers a rebuild at the top of the next processed frame.
    private var appliedSettings: AttentionSettings?

    private var isProcessing = false
    private var frameCounter = 0
    /// Process every Nth delivered frame — the primary CPU tuning lever
    /// (M3-T07). At the pinned 30 FPS capture cadence (`CameraManager` tier 1,
    /// 1920x1080 @ 30) this yields ~10 processed FPS; Vision face detection is
    /// the dominant per-frame cost, so the processed rate scales ~1/N with this
    /// constant (N = 4 → 7.5 processed FPS, a 25% Vision-load cut, NOT half —
    /// halving means N = 6). Tradeoff: every frame-count-derived timing gets
    /// coarser proportionally — the 0.7–1.2 s per-band trigger durations
    /// quantize to whole samples (sample period 100 ms → 133 ms at N = 4).
    /// The M1 frame-counted owner-absent debounce this comment used to
    /// describe is gone since M4-T06: owner absence is now time-based
    /// (`ownerPresenceWindow`), so no frame counter participates in any
    /// shield decision. See docs/performance_report.md, "Tuning levers".
    private let frameSkip = 3

    // MARK: - Per-track attention pipeline (M2-T03/T04)

    private let headPoseEstimator = HeadPoseEstimator()
    // M3-T04 note: the single shared `AttentionClassifier` instance is gone —
    // each track now classifies with its own band-adaptive config (see
    // `AdaptiveAttentionPolicy`), instantiated per evaluation (a cheap value
    // struct).

    /// Owns track lifecycle and per-track identity/attention state (M2-T01).
    /// Thread-confined to the video output queue alongside every other
    /// mutable member of this class; `FaceDetector` no longer keeps any
    /// per-face pipeline state outside the tracker.
    private let faceTracker = FaceTracker()

    /// Identity-cache policy (M2-T05 config, applied by M2-T06).
    private let recognitionPolicy = RecognitionCachePolicy()

    /// Shared TIMING CONFIG fallback for all per-track filters (M2-T04):
    /// used only by `.tooFarOrUnreliable` tracks, whose filters never
    /// accumulate anything (they are only ever fed `.uncertain`). Only the
    /// configuration is shared — every track gets its OWN
    /// `TemporalAttentionFilter` instance, so accumulation state is never
    /// shared (stranger A's 0.5 s + stranger B's 0.5 s can never become 1.0 s).
    /// Rebuilt from the user's trigger/release overrides whenever settings
    /// change (M4-T06); var for that reason.
    private var attentionTimingConfig = AttentionTimingConfig()

    /// Distance-adaptive policy (M3-T04): per-band classifier/timing profiles.
    /// The profile SET is rebuilt from the user settings (preset + overrides
    /// via `AttentionSettings.effectiveProfiles`, M4-T06); var for that
    /// reason. Rebuilds happen on the video queue only.
    private var adaptivePolicy = AdaptiveAttentionPolicy()

    /// Stateless width → band classifier (M3-T03/T04). Recreated whenever
    /// the settings' band boundaries change (M4-T06, `PrivacySettingsMapping.
    /// bandConfig`); var for that reason.
    private var distanceBandClassifier = DistanceBandClassifier()

    /// Band boundaries + hysteresis margin currently in effect (M4-T06):
    /// derived from the settings' band boundary fields and shared by the
    /// classifier AND the per-track hysteresis refinement, so the two can
    /// never disagree about where a band ends. Video-queue confined.
    private var distanceBandConfig = DistanceBandConfig()

    /// Calibrated screen center (M3-T04), loaded once at init and refreshed
    /// after each successful screen-direction calibration. `nil` = not
    /// calibrated yet → per-band profiles fall back to the 0/0 frontal
    /// assumption. Thread-confined to the video queue like every other
    /// mutable member.
    private var cachedScreenCenter: (yaw: Double, pitch: Double)?

    // MARK: - Screen-direction calibration (M3-T04)

    /// Active screen-direction calibration session state. `nil` when idle.
    private var isScreenCalibrationActive = false
    private var screenCalibrationStartedAt: Date?
    private var screenCalibrationLeadIn: TimeInterval = 2.0
    /// Timestamp of the first post-lead-in sample — anchors the collection
    /// deadline exactly like the collector's own window anchor.
    private var screenCalibrationFirstSampleAt: Date?
    private let screenCalibrationCollector = ScreenDirectionCalibrationCollector()
    private let screenCalibrationConfig = ScreenCalibrationConfig()
    /// Small grace beyond the collection window so the last in-window frames
    /// land before the session is declared failed.
    private let screenCalibrationWindowGrace: TimeInterval = 0.25
    private var screenCalibrationCompletion: ((Bool, ScreenCalibrationResult?) -> Void)?

    /// One temporal filter per live track, keyed by track UUID (M2-T04).
    /// Created when a track is created (lazily, on its first evaluation) and
    /// removed when the tracker reports the track expired.
    private var attentionFilters: [UUID: TemporalAttentionFilter] = [:]

    /// Owner hysteresis side-table (M2-T06): consecutive failed
    /// revalidations per stable owner/trusted track. One bad crop must never
    /// flip a stable owner to stranger; demotion waits for
    /// `recognitionPolicy.allowsOwnerDowngrade(count)`.
    private var consecutiveFailedRecognitions: [UUID: Int] = [:]

    /// `FaceRecognizer` runs within the current metrics window (M2-T06
    /// acceptance: the caching policy drives this number down).
    private var recognitionCount = 0

    // MARK: - Frame metrics (M1-T06)

    private var metricsFrameCount = 0
    private var metricsLatencySum = 0.0
    private var metricsWindowStart: Date?
    private let metricsInterval: TimeInterval = 2.0
    /// Vision throughput of the most recently closed metrics window (M4-T06):
    /// surfaces in the debug preview while no window is open. `nil` before
    /// the first window closes.
    private var lastVisionFPS: Double?

    // MARK: - Debug preview (M4-T05/T06)

    /// Pure state sink for the debug overlay (M4-T05). Created eagerly (a
    /// value holder with no side effects); the overlay WINDOW is only
    /// created by `setDebugPreviewVisible(true)`, so normal menu-bar-only
    /// operation never builds one. Pushes are a pure sink — nothing in the
    /// pipeline reads the model back.
    private let debugPreviewModel = DebugPreviewModel()
    /// The overlay window controller; created lazily on the main thread by
    /// `setDebugPreviewVisible(true)`. `nil` while the preview was never
    /// shown.
    private var debugPreviewWindowController: DebugPreviewWindowController?

    /// Minimum face size (0.0–1.0 of frame width) to trigger detection.
    /// Faces smaller than this are too far away to read the screen.
    var minFaceSize: CGFloat {
        get {
            let val = CGFloat(UserDefaults.standard.float(forKey: "minFaceSize"))
            return val > 0 ? val : 0.25
        }
        set { UserDefaults.standard.set(Float(newValue), forKey: "minFaceSize") }
    }

    // Use a buffer zone: faces within 80% of the threshold are "borderline" and don't trigger changes
    private var faceBufferRatio: CGFloat = 0.8

    /// Enrollment mode
    var isEnrolling = false
    var enrollmentCompletion: ((Bool) -> Void)?

    /// Calibration mode
    var isCalibrating = false
    private var calibrationSamples: [CGFloat] = []
    private let calibrationSampleCount = 10
    var calibrationCompletion: ((Bool, CGFloat) -> Void)?

    init(shieldManager: ShieldManager, delegate: FaceDetectorDelegate) {
        self.shieldManager = shieldManager
        self.faceRecognizer = FaceRecognizer()
        self.delegate = delegate
        // Load a previously calibrated screen center once (M3-T04); refreshed
        // after every successful screen-direction calibration.
        self.cachedScreenCenter = ScreenCenterStore.load()
        // M4-T06: load the persisted user settings once and record them as
        // the applied baseline. No frames have run yet, so the
        // tracker/filter tables are empty and the derived rebuild below is
        // queue-safe on the main thread.
        let loaded = AttentionSettingsStore.load()
        self.settingsStorage = loaded
        self.appliedSettings = loaded
        super.init()
        self.rebuildDerivedState(from: loaded)
    }

    /// Replaces the active settings (M4-T06). Called by the app delegate
    /// after it persists a change. Thread-safe: the value is stored under a
    /// lock and picked up on the video output queue at the top of the next
    /// processed frame, where the derived policy state is rebuilt — the
    /// pipeline's mutable state stays video-queue confined.
    func applySettings(_ s: AttentionSettings) {
        settings = s
    }

    /// Rebuilds every settings-derived piece of pipeline state (M4-T06).
    /// Called from init and from the video queue only (see `applySettings`):
    /// - the two blur toggles → `PrivacyStateMachineConfig`,
    /// - sensitivity preset + trigger/release overrides → per-band profiles
    ///   (`AttentionSettings.effectiveProfiles` — the single M4-T02 entry
    ///   point) and the shared `.tooFarOrUnreliable` fallback timing,
    /// - the band boundary fields → classifier + hysteresis config,
    /// - the resulting band timing → every LIVE per-track filter via
    ///   `updateConfig`, which swaps configuration WITHOUT touching
    ///   accumulation state (M3-T04 contract).
    private func rebuildDerivedState(from s: AttentionSettings) {
        privacyStateMachine.config = PrivacySettingsMapping.privacyConfig(from: s)
        adaptivePolicy.profiles = s.effectiveProfiles(base: .standard)
        distanceBandConfig = PrivacySettingsMapping.bandConfig(from: s)
        distanceBandClassifier = DistanceBandClassifier(config: distanceBandConfig)
        attentionTimingConfig = s.effectiveTimingConfig(base: AttentionTimingConfig())
        for (trackID, filter) in attentionFilters {
            guard let band = faceTracker.track(withID: trackID)?.distanceBand else { continue }
            if let timing = adaptivePolicy.timingConfig(for: band) {
                filter.updateConfig(timing)
            }
        }
    }

    func didOutput(pixelBuffer: CVPixelBuffer) {
        frameCounter += 1
        guard frameCounter % frameSkip == 0 else { return }
        guard !isProcessing else { return }
        isProcessing = true

        // M4-T06: pick up settings changes (written from the main thread by
        // `applySettings`) and rebuild the derived policy state here on the
        // video queue, keeping every pipeline mutation queue-confined.
        let currentSettings = settings
        if currentSettings != appliedSettings {
            appliedSettings = currentSettings
            rebuildDerivedState(from: currentSettings)
        }

        // Enrollment mode
        if isEnrolling {
            let _ = faceRecognizer.enrollFace(from: pixelBuffer)
            if faceRecognizer.enrollmentProgress >= faceRecognizer.enrollmentTarget {
                DispatchQueue.main.async { [weak self] in
                    self?.isEnrolling = false
                    self?.enrollmentCompletion?(true)
                    self?.enrollmentCompletion = nil
                }
            }
            isProcessing = false
            return
        }

        // Calibration mode
        if isCalibrating {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            let req = VNDetectFaceRectanglesRequest()
            do {
                try handler.perform([req])
                if let face = (req.results as? [VNFaceObservation])?.first {
                    calibrationSamples.append(face.boundingBox.width)
                    print("Calibration sample \(calibrationSamples.count)/\(calibrationSampleCount): face width = \(face.boundingBox.width)")

                    if calibrationSamples.count >= calibrationSampleCount {
                        let avgSize = calibrationSamples.reduce(0, +) / CGFloat(calibrationSamples.count)
                        DispatchQueue.main.async { [weak self] in
                            self?.isCalibrating = false
                            self?.minFaceSize = avgSize
                            self?.calibrationCompletion?(true, avgSize)
                            self?.calibrationCompletion = nil
                        }
                    }
                }
            } catch {}
            isProcessing = false
            return
        }

        // Recognition mode
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let request = VNDetectFaceRectanglesRequest()

        do {
            let processingStart = CFAbsoluteTimeGetCurrent()
            try requestHandler.perform([request])
            let faces = (request.results as? [VNFaceObservation]) ?? []
            let count = faces.count

            // Filter faces by size with buffer zone to prevent glitching at
            // the boundary. This size gate is what makes tracked faces
            // "qualifying observers" (M2-T04): only detections within range
            // ever become tracks.
            let softThreshold = minFaceSize * faceBufferRatio  // Inner threshold (hysteresis)
            let nearbyFaces = faces.filter { $0.boundingBox.width >= softThreshold }
            let nearbyCount = nearbyFaces.count

            // Everything below runs ON the video queue (didOutput's queue) —
            // the tracker, per-track filters, recognition cache and shield
            // decisions are all video-queue confined; only the imperative UI
            // calls hop to the main queue. The frame timestamp is captured
            // here so every temporal update uses the same per-frame instant.
            let frameDate = Date()

            // Screen-direction calibration mode (M3-T04): collect head-pose
            // samples from the largest in-range face while the privacy
            // policy keeps running on a reduced input (M4-T06): owner
            // presence is assumed whenever ANY face is in range — identity
            // is deliberately not consulted during calibration — and the
            // per-track attention/alert pipeline is skipped for the duration
            // (like enrollment mode). The reported display state is
            // `.calibrating` regardless of the shield reason underneath.
            if isScreenCalibrationActive {
                let latencyMS = (CFAbsoluteTimeGetCurrent() - processingStart) * 1000.0
                stepScreenCalibration(nearbyFaces: nearbyFaces, at: frameDate)
                recordFrameMetrics(latencyMS: latencyMS, faceCount: count)
                // Preserved unenrolled fallback (see the recognition path):
                // with no enrollment every face maps to .owner, so multiple
                // in-range faces are treated as potential observers.
                let surferDetected = currentSettings.shoulderSurfDetectionEnabled
                    && !faceRecognizer.isEnrolled
                    && nearbyCount > 1
                let reason = privacyStateMachine.evaluate(
                    ownerPresent: !nearbyFaces.isEmpty,
                    shoulderSurferDetected: surferDetected)
                applyPrivacyDecision(reason: reason, calibrating: true)
                isProcessing = false
                return
            }

            let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                   height: CVPixelBufferGetHeight(pixelBuffer))

            // Pre-process snapshot: bounding box + state each track had
            // BEFORE this frame's association pass. Used for the recognition
            // policy's unseenDuration/previousBoundingBox inputs (process()
            // refreshes lastSeen/boundingBox for matched tracks, so the
            // pre-frame values must be captured first).
            let previousTracks = Dictionary(uniqueKeysWithValues: faceTracker.tracks.map { ($0.id, $0) })

            let detections = nearbyFaces.map(\.boundingBox)
            let liveTracks = faceTracker.process(detections: detections, at: frameDate, frameSize: frameSize)
            let association = faceTracker.lastAssociationResult ?? TrackAssociationResult()

            // Track expiry tears down the per-track filter and the owner
            // hysteresis entry: an expired track immediately stops
            // contributing to the global alert (M2-T04 cleanup).
            for expiredID in association.expiredTrackIDs {
                attentionFilters[expiredID] = nil
                consecutiveFailedRecognitions[expiredID] = nil
            }

            // Matched detection index → observation, for per-track head pose.
            var observationByTrack: [UUID: VNFaceObservation] = [:]
            for match in association.matched where observationByTrack[match.trackID] == nil {
                observationByTrack[match.trackID] = nearbyFaces[match.detectionIndex]
            }

            let latencyMS = (CFAbsoluteTimeGetCurrent() - processingStart) * 1000.0

            var observations: [ShoulderSurfAggregator.TrackObservation] = []
            observations.reserveCapacity(liveTracks.count)

            // Owner-presence snapshots (M4-T06): (identity, lastSeen) with
            // THIS frame's post-recognition identity — fed to
            // `OwnerPresencePolicy.ownerPresent` after the loop.
            var presenceSnapshots: [(identity: IdentityState, lastSeen: Date)] = []
            presenceSnapshots.reserveCapacity(liveTracks.count)

            // Debug preview rows (M4-T05/T06): built only while the preview
            // is enabled; a pure sink, never read back by the pipeline.
            let debugPreviewEnabled = currentSettings.debugPreviewEnabled
            var debugFaces: [DebugFaceInfo] = []
            if debugPreviewEnabled { debugFaces.reserveCapacity(liveTracks.count) }

            for track in liveTracks {
                let previous = previousTracks[track.id]
                let isNewTrack = association.newTracks.contains(track.id)
                let isMatchedThisFrame = observationByTrack[track.id] != nil

                // --- Distance band (M3-T04): normalized width → band, with
                // per-track hysteresis across frames (the previous band lives
                // on the track). Band changes are persisted, logged and apply
                // the new timing profile WITHOUT resetting the filter.
                let faceWidth = Double(track.boundingBox.width)
                let rawBand = distanceBandClassifier.band(forNormalizedFaceWidth: faceWidth)
                let previousBand = track.distanceBand
                let band = DistanceBandHysteresis.refined(
                    previous: previousBand,
                    current: rawBand,
                    width: faceWidth,
                    config: distanceBandConfig
                )
                if band != previousBand {
                    faceTracker.updateDistanceBand(id: track.id, band: band)
                    if let timing = adaptivePolicy.timingConfig(for: band) {
                        // Profile change must NOT reset accumulation (M3-T04
                        // acceptance): updateConfig swaps configuration only.
                        attentionFilter(for: track.id, band: band).updateConfig(timing)
                    }
                    DiagnosticsLog.bandChange(trackID: track.id, band: band, previous: previousBand)
                }

                // --- Attention input (M2-T03): pose → classifier.
                // No fresh detection this frame (short miss / gray zone) is
                // an explicitly UNAVAILABLE pose → .uncertain: unknown
                // orientation is never conflated with a frontal reading.
                let pose: HeadPoseResult
                if let observation = observationByTrack[track.id] {
                    pose = headPoseEstimator.pose(from: observation)
                } else {
                    pose = .unavailable
                }
                faceTracker.updateHeadPose(id: track.id, headPose: pose)

                // Band-adaptive classification (M3-T04): each band scores
                // with its own tolerances around the calibrated screen
                // center. `.tooFarOrUnreliable` gets NO classifier config —
                // an unreliable far face is fed `.uncertain` directly and can
                // never accumulate looking time toward an alert.
                let attention: AttentionResult
                if let classifierConfig = adaptivePolicy.classifierConfig(for: band,
                                                                          screenCenter: cachedScreenCenter) {
                    attention = AttentionClassifier(config: classifierConfig).classify(pose)
                } else {
                    attention = AttentionResult(state: .uncertain, score: 0.0)
                }

                // --- Per-track temporal state machine (M2-T04). Each track
                // feeds ONLY its own filter; filters are updated exclusively
                // here on the video queue with the frame timestamp.
                let filter = attentionFilter(for: track.id, band: band)
                let wasTrackAlerting = filter.isAlerting
                let accumBefore = filter.accumulatedLookingTime
                let isTrackAlerting = filter.update(attention.state, at: frameDate)
                let accumAfter = filter.accumulatedLookingTime

                // Per-track alert transitions (M2-T07): alert_on / alert_off
                // with this track's UUID.
                if wasTrackAlerting != isTrackAlerting {
                    var detail = "state=\(DiagnosticsLog.name(of: attention.state))"
                    if isTrackAlerting {
                        detail += String(format: " accum=%.2f", filter.accumulatedLookingTime)
                    }
                    DiagnosticsLog.transition(isTrackAlerting ? "alert_on" : "alert_off",
                                              trackID: track.id, detail: detail)
                }

                // lookingSince = the instant accumulation went 0 → >0
                // (pending accumulation began); cleared when the filter's
                // accumulation resets (cleared notLooking, exceeded
                // uncertain grace, or alert release). Derived from the
                // filter's public state — its tested semantics are untouched.
                var lookingSince = track.lookingSince
                if accumBefore == 0, accumAfter > 0 {
                    lookingSince = frameDate
                } else if accumBefore > 0, accumAfter == 0 {
                    lookingSince = nil
                }

                faceTracker.updateAttention(
                    id: track.id,
                    result: attention,
                    lookingSince: lookingSince,
                    positiveAt: attention.state == .looking ? frameDate : nil,
                    negativeAt: attention.state == .notLooking ? frameDate : nil
                )

                // --- Recognition caching (M2-T06). Recognition needs a
                // fresh crop, so it runs only for tracks matched to a
                // detection this frame; missed tracks keep their cached
                // identity and their cadence clock keeps running.
                var identity = track.identity
                if isMatchedThisFrame {
                    let unseenDuration: TimeInterval
                    if isNewTrack {
                        unseenDuration = 0  // never seen before; policy short-circuits on isNewTrack
                    } else if let previous {
                        // Gap that just ended: now − lastSeen BEFORE this
                        // frame's update (pre-process snapshot). Continuous
                        // presence yields ~one processing period; a gray-zone
                        // reappearance yields the real unseen gap. (Longer
                        // absences never reach here: unseen beyond
                        // trackExpiryInterval expires the track, and its
                        // successor is a NEW track recognized immediately.)
                        unseenDuration = max(0, frameDate.timeIntervalSince(previous.lastSeen))
                    } else {
                        unseenDuration = 0
                    }
                    let decision = recognitionPolicy.decision(
                        track: track,
                        isNewTrack: isNewTrack,
                        unseenDuration: unseenDuration,
                        previousBoundingBox: previous?.boundingBox,
                        frameWidth: 1.0,  // bounding boxes are normalized Vision rects
                        now: frameDate
                    )
                    switch decision {
                    case .recognizeNow(let reason):
                        recognitionCount += 1
                        let fresh: IdentityState
                        if faceRecognizer.isEnrolled {
                            // M1 parity: identify() maps labels; when nobody
                            // is enrolled no face is a stranger by
                            // recognition (isOwner returned true) — every
                            // track is owner-trusted until enrollment exists.
                            fresh = Self.identityState(
                                forLabel: faceRecognizer.identify(
                                    pixelBuffer: pixelBuffer,
                                    faceRect: track.boundingBox)
                            )
                        } else {
                            fresh = .owner
                        }
                        identity = applyRecognition(fresh, onto: track, at: frameDate)
                        DiagnosticsLog.recognition(
                            trackID: track.id,
                            decision: "recognize_now",
                            reason: String(describing: reason),
                            identity: identity
                        )
                    case .cached(let cachedIdentity, let reason):
                        identity = cachedIdentity
                        DiagnosticsLog.recognition(
                            trackID: track.id,
                            decision: "cached",
                            reason: String(describing: reason)
                        )
                    }
                }

                // --- Per-track debug event (M2-T07): one per track per frame.
                let refreshed = faceTracker.track(withID: track.id)
                DiagnosticsLog.track(
                    trackID: track.id,
                    identity: identity,
                    boundingBox: track.boundingBox,
                    pose: refreshed?.latestHeadPose,
                    attention: attention,
                    lookingSince: lookingSince,
                    lastSeen: track.lastSeen,
                    lastIdentityCheck: refreshed?.lastIdentityCheck,
                    distanceBand: band,
                    now: frameDate,
                    latencyMS: latencyMS
                )

                observations.append(ShoulderSurfAggregator.TrackObservation(
                    trackID: track.id,
                    identity: identity,
                    isAlerting: isTrackAlerting
                ))
                presenceSnapshots.append((identity: identity, lastSeen: track.lastSeen))

                if debugPreviewEnabled {
                    let poseInfo: (yaw: Double, pitch: Double, roll: Double)?
                    if case .valid(let pose) = refreshed?.latestHeadPose {
                        poseInfo = (pose.yaw, pose.pitch, pose.roll)
                    } else {
                        poseInfo = nil
                    }
                    debugFaces.append(DebugFaceInfo(
                        trackID: track.id,
                        identity: identity,
                        boundingBox: track.boundingBox,
                        faceWidth: faceWidth,
                        distanceBand: band,
                        yaw: poseInfo?.yaw,
                        pitch: poseInfo?.pitch,
                        roll: poseInfo?.roll,
                        attentionScore: attention.score,
                        attentionState: attention.state,
                        lookingDuration: filter.accumulatedLookingTime
                    ))
                }
            }

            // Global aggregation (M2-T04): any qualifying track alerting
            // raises the shoulder-surf alert; it hides only when none does.
            let attentionAlert = ShoulderSurfAggregator.isAnyQualifyingTrackAlerting(observations)

            recordFrameMetrics(latencyMS: latencyMS, faceCount: count)

            // MARK: Privacy policy (M4-T06; replaces the legacy path)
            //
            // The two independent M4-T03 inputs:
            // - Owner presence: a trusted-level (owner/trusted) track seen
            //   within `ownerPresenceWindow` — evaluated from this frame's
            //   post-recognition snapshots. This replaces the legacy
            //   "no face at all" 3/8-frame debounce entirely: a stranger
            //   still in frame no longer keeps the screen "safe", and the
            //   blur engages once the owner's track has been unseen for the
            //   window (track expiry is 1.0 s, so ~1.0–1.5 s after leaving
            //   with the default window of 1.5 s). The per-track
            //   `TemporalAttentionFilter` trigger durations (M1-T07,
            //   settings-overridable) own ALL looking-time debouncing.
            // - Shoulder-surf input: the aggregator's result AND the master
            //   switch, plus the preserved unenrolled fallback — with no
            //   enrollment the recognition path maps every face to `.owner`
            //   (M1 parity, see the recognition block), so the aggregator
            //   could never qualify anyone; multiple in-range faces while
            //   unenrolled are therefore treated as potential observers,
            //   exactly the legacy `!isEnrolled && nearbyCount > 1` rule.
            let ownerPresent = OwnerPresencePolicy.ownerPresent(
                in: presenceSnapshots,
                now: frameDate,
                presenceWindow: privacyStateMachine.config.ownerPresenceWindow
            )
            let surferDetected = currentSettings.shoulderSurfDetectionEnabled
                && (attentionAlert
                    || (!faceRecognizer.isEnrolled && nearbyCount > 1))

            let reason = privacyStateMachine.evaluate(
                ownerPresent: ownerPresent,
                shoulderSurferDetected: surferDetected
            )
            // Edge-driven application: reason changes drive shield + icon;
            // display-state changes drive the status line + reason-aware
            // notifications (via AppDelegate.privacyStateChanged — the ONE
            // notification path since M4-T06).
            applyPrivacyDecision(reason: reason, calibrating: false)

            // Debug preview (M4-T05/T06): one snapshot per processed frame,
            // pushed to the pure state sink. Never alters decisions.
            if debugPreviewEnabled {
                publishDebugPreview(faces: debugFaces,
                                    latencyMS: latencyMS,
                                    activeTrackCount: liveTracks.count)
            }

            isProcessing = false
        } catch {
            print("Face detection failed: \(error)")
            isProcessing = false
        }
    }

    // MARK: - Per-track pipeline helpers (M2-T03/T04/T06)

    /// Returns the temporal filter for a track, creating it on first use with
    /// the band-adaptive timing config (M3-T04; falls back to the shared M1
    /// timing config for `.tooFarOrUnreliable`, whose filter never accumulates
    /// anything). Each filter keeps its OWN accumulation state — M2-T04:
    /// per-track durations are identical values, never shared state.
    private func attentionFilter(for trackID: UUID, band: DistanceBand) -> TemporalAttentionFilter {
        if let existing = attentionFilters[trackID] { return existing }
        let config = adaptivePolicy.timingConfig(for: band) ?? attentionTimingConfig
        let created = TemporalAttentionFilter(config: config)
        attentionFilters[trackID] = created
        return created
    }

    /// Maps a `FaceRecognizer` label to an identity (M2-T06 contract):
    /// "owner" → .owner, "trusted…" → .trusted, anything else (or nil) →
    /// .other. Callers short-circuit to .owner when nobody is enrolled (M1
    /// parity: `isOwner` returned true in that case).
    private static func identityState(forLabel label: String?) -> IdentityState {
        guard let label else { return .other }
        if label == "owner" { return .owner }
        if label.hasPrefix("trusted") { return .trusted }
        return .other
    }

    /// True for identities that must not be demoted by a single failed crop.
    private static func isTrustedLevel(_ identity: IdentityState) -> Bool {
        switch identity {
        case .owner, .trusted: return true
        case .other, .unknown: return false
        }
    }

    /// Writes a fresh recognition result onto the track with owner
    /// hysteresis (M2-T06): a stable owner/trusted track whose revalidation
    /// fails keeps its identity and counts the failure; demotion to .other
    /// happens only once `allowsOwnerDowngrade` says so. Any success (and any
    /// result on a non-trusted track) resets the counter. Returns the
    /// identity now in effect.
    private func applyRecognition(_ newIdentity: IdentityState, onto track: FaceTrack, at now: Date) -> IdentityState {
        let trackID = track.id
        if Self.isTrustedLevel(track.identity), newIdentity == .other {
            let failures = (consecutiveFailedRecognitions[trackID] ?? 0) + 1
            if recognitionPolicy.allowsOwnerDowngrade(failures) {
                consecutiveFailedRecognitions[trackID] = nil
                faceTracker.updateIdentity(id: trackID, identity: .other, checkedAt: now)
                return .other
            }
            // Hysteresis: keep the cached identity and stamp the check time
            // so the next revalidation waits out the cadence instead of
            // hammering recognition on every frame.
            consecutiveFailedRecognitions[trackID] = failures
            faceTracker.updateIdentity(id: trackID, identity: track.identity, checkedAt: now)
            return track.identity
        }
        consecutiveFailedRecognitions[trackID] = nil
        faceTracker.updateIdentity(id: trackID, identity: newIdentity, checkedAt: now)
        return newIdentity
    }

    // MARK: - Privacy decision application (M4-T06)

    /// Accumulates per-frame stats and emits a `metrics` event roughly every
    /// `metricsInterval` seconds (silent unless debug logging is enabled).
    private func recordFrameMetrics(latencyMS: Double, faceCount: Int) {
        let now = Date()
        let windowStart = metricsWindowStart ?? now
        if metricsWindowStart == nil { metricsWindowStart = now }

        metricsFrameCount += 1
        metricsLatencySum += latencyMS

        let elapsed = now.timeIntervalSince(windowStart)
        if elapsed >= metricsInterval {
            let visionFPS = Double(metricsFrameCount) / max(elapsed, 1e-9)
            // M4-T06: kept for the debug preview (Vision FPS line).
            lastVisionFPS = visionFPS
            DiagnosticsLog.metrics(
                visionFPS: visionFPS,
                latencyMS: metricsLatencySum / Double(metricsFrameCount),
                faceCount: faceCount,
                recognitions: recognitionCount
            )
            metricsFrameCount = 0
            metricsLatencySum = 0
            metricsWindowStart = now
            recognitionCount = 0
        }
    }

    /// Applies one privacy decision edge-driven (M4-T06; replaces
    /// `applyCombinedShield`): only reason CHANGES drive the shield and the
    /// menu icon, and only display-state CHANGES are reported to the app
    /// delegate — which derives the reason-aware notifications AND the menu
    /// status line from that single call, so exactly one notification path
    /// is active. Video-queue only; UI calls hop to main.
    ///
    /// `calibrating` wraps the REPORTED state as `.calibrating` (M4-T04
    /// device state) while the shield keeps following the reason underneath:
    /// during a calibration session the owner-presence input is the coarse
    /// "any face in range" signal, so a mid-calibration departure still
    /// blurs; its notification (if any) fires when the session ends and the
    /// mapped state becomes reportable again.
    private func applyPrivacyDecision(reason: PrivacyShieldReason, calibrating: Bool) {
        let displayState: PrivacyDisplayState = calibrating
            ? .calibrating
            : PrivacySettingsMapping.displayState(for: reason)

        if reason != lastAppliedReason {
            lastAppliedReason = reason
            let show = reason.isShieldShown
            DiagnosticsLog.transition(show ? "shield_on" : "shield_off",
                                      detail: "reason=\(reason.description)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if show {
                    self.shieldManager.showShield()
                } else {
                    self.shieldManager.hideShield()
                }
                self.delegate?.updateMenuIcon(safe: !show)
            }
        }

        if displayState != lastReportedState {
            lastReportedState = displayState
            (delegate as? PrivacyDisplayReporting)?.privacyStateChanged(to: displayState)
        }
    }

    // MARK: - Debug preview (M4-T05/T06)

    /// Builds one `DebugPreviewState` from the processed frame and pushes it
    /// into the pure state sink. Called from the video queue; the model
    /// hops its observable effects to the main thread internally.
    ///
    /// Not representable from here (left `nil` in the state): the camera
    /// capture FPS and the configured camera format — both live inside
    /// `CameraManager`, whose public surface does not expose them to the
    /// detector.
    private func publishDebugPreview(faces: [DebugFaceInfo],
                                     latencyMS: Double,
                                     activeTrackCount: Int) {
        var state = DebugPreviewState()
        state.faces = faces
        state.captureFPS = nil          // capture-side metrics live in CameraManager
        state.visionFPS = lastVisionFPS // nil until the first ~2 s window closes
        state.latencyMs = latencyMS
        state.activeTrackCount = activeTrackCount
        state.cameraFormat = nil        // CameraManager's format summary is not reachable here
        if let center = cachedScreenCenter {
            state.screenCenter = DebugScreenCenter(yaw: center.yaw, pitch: center.pitch)
        }
        debugPreviewModel.update(state)
    }

    /// Shows or hides the debug preview overlay (M4-T06 menu wiring). The
    /// window controller is created lazily on the first show, on the main
    /// thread; hiding only orders the window out and costs nothing per
    /// frame (the per-frame push is additionally gated on the persisted
    /// `debugPreviewEnabled` setting).
    func setDebugPreviewVisible(_ visible: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if visible {
                if self.debugPreviewWindowController == nil {
                    let controller = DebugPreviewWindowController()
                    self.debugPreviewModel.onStateChanged = { [weak controller] state in
                        controller?.render(state)
                    }
                    self.debugPreviewWindowController = controller
                }
                self.debugPreviewWindowController?.show()
            } else {
                self.debugPreviewWindowController?.hide()
            }
        }
    }

    // MARK: - Screen-direction calibration (M3-T04)

    /// Starts screen-direction calibration: after a short lead-in, feeds the largest in-range face's
    /// head-pose samples into a ScreenDirectionCalibrationCollector for ~3 s, saves the result via
    /// ScreenCenterStore.save, applies the new center to subsequent classifications, then calls the
    /// completion exactly once: success=true + result, or success=false + nil (too few valid samples).
    ///
    /// Frame-driven like the other calibration modes: samples arrive with
    /// processed frames, so the session only advances while the camera runs.
    /// While active, the per-track attention/alert path is skipped (the
    /// privacy policy keeps running on the reduced "any face in range =
    /// owner present" input, M4-T06); tracks simply go stale and expire on
    /// the first post-calibration frame.
    func startScreenDirectionCalibration(leadIn: TimeInterval = 2.0,
                                         completion: @escaping (_ success: Bool, _ result: ScreenCalibrationResult?) -> Void) {
        // A session is already running: fail the new request immediately
        // (the active session keeps its own exactly-once completion).
        guard !isScreenCalibrating else {
            completion(false, nil)
            return
        }
        screenCalibrationCollector.reset()
        screenCalibrationLeadIn = leadIn
        screenCalibrationStartedAt = Date()
        screenCalibrationFirstSampleAt = nil
        isScreenCalibrationActive = true
        screenCalibrationCompletion = completion
        DiagnosticsLog.transition("screen_calibration_on",
                                  detail: String(format: "lead_in=%.1fs", leadIn))
    }

    /// True while a screen-direction calibration session is collecting.
    var isScreenCalibrating: Bool {
        isScreenCalibrationActive
    }

    /// One calibration step per processed frame (video queue): after the
    /// lead-in, feed the largest in-range face's pose (or `.unavailable`,
    /// which counts toward the validity rate) into the collector; finish the
    /// session as soon as it succeeds or the ~3 s collection window is
    /// exhausted. Owner presence is assumed during calibration, so identity
    /// is deliberately NOT consulted.
    private func stepScreenCalibration(nearbyFaces: [VNFaceObservation], at now: Date) {
        guard let startedAt = screenCalibrationStartedAt else { return }

        // Lead-in: let the user settle into position before any sample counts.
        guard now.timeIntervalSince(startedAt) >= screenCalibrationLeadIn else { return }

        let pose: HeadPoseResult
        if let largest = nearbyFaces.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
            pose = headPoseEstimator.pose(from: largest)
        } else {
            pose = .unavailable
        }
        if screenCalibrationFirstSampleAt == nil {
            screenCalibrationFirstSampleAt = now
        }
        screenCalibrationCollector.add(pose, at: now)

        // Success as soon as enough valid samples are in and the robust
        // statistics accept them (`finish()` is idempotent and cheap here).
        if screenCalibrationCollector.isComplete,
           let result = screenCalibrationCollector.finish() {
            finishScreenCalibration(result: result)
            return
        }

        // Window exhausted without enough valid samples → failure. The
        // collector itself ignores post-window samples, so the deadline is
        // the first sample plus the collection window (+ small grace).
        if let first = screenCalibrationFirstSampleAt,
           now.timeIntervalSince(first) > screenCalibrationConfig.collectionWindow + screenCalibrationWindowGrace {
            finishScreenCalibration(result: nil)
        }
    }

    /// Ends the session exactly once: on success saves the center, refreshes
    /// the cached center used by subsequent classifications and logs; the
    /// completion is always dispatched to the main queue (mirroring the
    /// range-calibration completion pattern).
    private func finishScreenCalibration(result: ScreenCalibrationResult?) {
        guard isScreenCalibrationActive else { return }
        isScreenCalibrationActive = false
        screenCalibrationStartedAt = nil
        screenCalibrationFirstSampleAt = nil
        let completion = screenCalibrationCompletion
        screenCalibrationCompletion = nil

        if let result {
            ScreenCenterStore.save(result)
            cachedScreenCenter = (result.centerYaw, result.centerPitch)
            DiagnosticsLog.transition("screen_calibration_off", detail: String(
                format: "center_yaw=%+.2f center_pitch=%+.2f samples=%d validity=%.2f",
                result.centerYaw, result.centerPitch, result.sampleCount, result.validityRate
            ))
        } else {
            DiagnosticsLog.transition("screen_calibration_off", detail: "failed_too_few_valid_samples")
        }

        DispatchQueue.main.async { [weak self] in
            // Detached completion (detector gone before the hop): dropped —
            // exactly-once still holds because the caller observes no call.
            guard self != nil else { return }
            completion?(result != nil, result)
        }
    }

    func startEnrollment(userLabel: String, completion: @escaping (Bool) -> Void) {
        faceRecognizer.startNewEnrollment(label: userLabel)
        enrollmentCompletion = completion
        isEnrolling = true
        print("Enrollment started for '\(userLabel)' — look at the camera...")
    }

    func startCalibration(completion: @escaping (Bool, CGFloat) -> Void) {
        calibrationSamples.removeAll()
        calibrationCompletion = completion
        isCalibrating = true
        print("Calibration started — stand at your desired distance and look at the camera...")
    }
}
