import Vision
import CoreVideo
import Foundation

protocol FaceDetectorDelegate: AnyObject {
    func updateMenuIcon(safe: Bool)
    func sendStrangerNotification()
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

class FaceDetector: NSObject, CameraManagerDelegate {
    private let shieldManager: ShieldManager
    let faceRecognizer: FaceRecognizer
    private weak var delegate: FaceDetectorDelegate?

    // Anti-glitch debounce, now used ONLY by the legacy owner-absent blur
    // path: the unknown-face trigger that used to share these counters was
    // replaced by per-track time-based filters (M2-T04). Logic unchanged
    // from M1; it now runs on the video queue like the rest of the pipeline.
    private var consecutiveStranger = 0
    private var consecutiveSafe = 0
    private let strangerThreshold = 3     // Frames before SHOWING legacy blur
    private let safeThreshold = 8         // Frames before HIDING legacy blur (higher = more stable)
    private var isLegacyShieldActive = false
    /// Combined shield state: legacy owner-absent blur OR attention alert.
    private var isShieldActive = false

    private var isProcessing = false
    private var frameCounter = 0
    private let frameSkip = 3
    private var hasNotifiedStranger = false

    // MARK: - Per-track attention pipeline (M2-T03/T04)

    private let headPoseEstimator = HeadPoseEstimator()
    private let attentionClassifier = AttentionClassifier()

    /// Owns track lifecycle and per-track identity/attention state (M2-T01).
    /// Thread-confined to the video output queue alongside every other
    /// mutable member of this class; `FaceDetector` no longer keeps any
    /// per-face pipeline state outside the tracker.
    private let faceTracker = FaceTracker()

    /// Identity-cache policy (M2-T05 config, applied by M2-T06).
    private let recognitionPolicy = RecognitionCachePolicy()

    /// Shared TIMING CONFIG for all per-track filters (M2-T04): trigger 0.9 s
    /// / release 0.6 s / grace 0.35 s, the M1 prototype values. Only the
    /// configuration is shared — every track gets its OWN
    /// `TemporalAttentionFilter` instance, so accumulation state is never
    /// shared (stranger A's 0.5 s + stranger B's 0.5 s can never become 1.0 s).
    private let attentionTimingConfig = AttentionTimingConfig()

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
        super.init()
    }

    func didOutput(pixelBuffer: CVPixelBuffer) {
        frameCounter += 1
        guard frameCounter % frameSkip == 0 else { return }
        guard !isProcessing else { return }
        isProcessing = true

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

            // Legacy global safe logic condition (replaced in M2/M4):
            // owner-absent blur (no face at all → user walked away) plus the
            // not-enrolled multi-face rule, preserved exactly as before.
            let legacyStranger = (count == 0) || (!faceRecognizer.isEnrolled && nearbyCount > 1)

            // Everything below runs ON the video queue (didOutput's queue) —
            // the tracker, per-track filters, recognition cache and shield
            // decisions are all video-queue confined; only the imperative UI
            // calls hop to the main queue. The frame timestamp is captured
            // here so every temporal update uses the same per-frame instant.
            let frameDate = Date()
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

            for track in liveTracks {
                let previous = previousTracks[track.id]
                let isNewTrack = association.newTracks.contains(track.id)
                let isMatchedThisFrame = observationByTrack[track.id] != nil

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
                let attention = attentionClassifier.classify(pose)

                // --- Per-track temporal state machine (M2-T04). Each track
                // feeds ONLY its own filter; filters are updated exclusively
                // here on the video queue with the frame timestamp.
                let filter = attentionFilter(for: track.id)
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
                    now: frameDate,
                    latencyMS: latencyMS
                )

                observations.append(ShoulderSurfAggregator.TrackObservation(
                    trackID: track.id,
                    identity: identity,
                    isAlerting: isTrackAlerting
                ))
            }

            // Global aggregation (M2-T04): any qualifying track alerting
            // raises the shoulder-surf alert; it hides only when none does.
            let attentionAlert = ShoulderSurfAggregator.isAnyQualifyingTrackAlerting(observations)

            recordFrameMetrics(latencyMS: latencyMS, faceCount: count)

            // MARK: Legacy global safe logic (replaced in M2/M4)
            // Owner-absent blur debounce, preserved exactly; the counters now
            // live on the video queue with the rest of the pipeline.
            let legacyActive = updateLegacyShieldState(strangerCondition: legacyStranger)

            // Combine both paths with OR: the shield stays up while either
            // the legacy owner-absent blur or any qualifying track's alert
            // demands it. Edge-driven only (no per-frame icon refresh) so the
            // two paths can never fight over the icon. UI calls hop to main.
            let shieldNeeded = legacyActive || attentionAlert
            if shieldNeeded != isShieldActive {
                isShieldActive = shieldNeeded
                let show = shieldNeeded
                let shouldNotify = shieldNeeded && !hasNotifiedStranger
                if shieldNeeded {
                    hasNotifiedStranger = true
                } else {
                    hasNotifiedStranger = false
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if show {
                        self.shieldManager.showShield()
                        self.delegate?.updateMenuIcon(safe: false)
                        if shouldNotify {
                            self.delegate?.sendStrangerNotification()
                        }
                    } else {
                        self.shieldManager.hideShield()
                        self.delegate?.updateMenuIcon(safe: true)
                    }
                }
            }

            isProcessing = false
        } catch {
            print("Face detection failed: \(error)")
            isProcessing = false
        }
    }

    // MARK: - Per-track pipeline helpers (M2-T03/T04/T06)

    /// Returns the temporal filter for a track, creating it on first use with
    /// the shared timing config (each filter keeps its OWN accumulation
    /// state — M2-T04: per-track durations are identical values, never shared
    /// state).
    private func attentionFilter(for trackID: UUID) -> TemporalAttentionFilter {
        if let existing = attentionFilters[trackID] { return existing }
        let created = TemporalAttentionFilter(config: attentionTimingConfig)
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

    // MARK: Legacy global safe logic (replaced in M2/M4)

    /// Owner-absent blur (no face at all → the user walked away → protect
    /// the screen) plus the not-enrolled multi-face rule, preserved exactly
    /// as before the attention pipeline existed. The counters below are the
    /// original anti-glitch debounce; they now see ONLY the legacy condition
    /// because the unknown-face trigger moved to the per-track filters.
    private func updateLegacyShieldState(strangerCondition: Bool) -> Bool {
        if strangerCondition {
            consecutiveStranger += 1
            consecutiveSafe = 0  // Reset safe counter

            // Only SHOW the legacy blur after sustained absence
            if !isLegacyShieldActive && consecutiveStranger >= strangerThreshold {
                isLegacyShieldActive = true
                DiagnosticsLog.transition("legacy_shield_on", detail: "owner_absent_or_unenrolled_multi_face")
            }
        } else {
            consecutiveSafe += 1
            consecutiveStranger = 0  // Reset stranger counter

            // Only HIDE the legacy blur after sustained presence (prevents flickering)
            if isLegacyShieldActive && consecutiveSafe >= safeThreshold {
                isLegacyShieldActive = false
                DiagnosticsLog.transition("legacy_shield_off", detail: "presence_restored")
            }
        }
        return isLegacyShieldActive
    }

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
            DiagnosticsLog.metrics(
                visionFPS: Double(metricsFrameCount) / max(elapsed, 1e-9),
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
