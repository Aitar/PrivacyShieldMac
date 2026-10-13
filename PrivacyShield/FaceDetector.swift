import Vision
import CoreVideo
import Foundation

protocol FaceDetectorDelegate: AnyObject {
    func updateMenuIcon(safe: Bool)
    func sendStrangerNotification()
}

class FaceDetector: NSObject, CameraManagerDelegate {
    private let shieldManager: ShieldManager
    let faceRecognizer: FaceRecognizer
    private weak var delegate: FaceDetectorDelegate?
    
    // Anti-glitch debounce, now used ONLY by the legacy owner-absent blur
    // path: the unknown-face trigger that used to share these counters was
    // replaced by the time-based TemporalAttentionFilter (M1-T07).
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

    // MARK: - Attention pipeline (M1-T05 + M1-T07)

    private let headPoseEstimator = HeadPoseEstimator()
    private let attentionClassifier = AttentionClassifier()

    /// V1 prototype: ONE shared temporal filter fed with the aggregate state
    /// of all unknown nearby faces. Known limitation: attention time is
    /// shared across unknown faces until M2 adds per-track state (and the
    /// track_id logged for a face is the per-frame index until then).
    private let attentionFilter = TemporalAttentionFilter()

    /// Per-face evaluation snapshot handed from the capture queue to the
    /// main queue for state handling and debug logging.
    private struct FaceEvaluation {
        let trackID: Int         // M1: per-frame face index; M2: tracker UUID
        let isOwner: Bool
        let faceWidth: CGFloat
        /// nil when the head-pose path was skipped (owner/trusted face).
        let pose: HeadPoseResult?
        /// nil when the head-pose path was skipped (owner/trusted face).
        let attention: AttentionResult?
    }

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
            
            // Filter faces by size with buffer zone to prevent glitching at the boundary
            let softThreshold = minFaceSize * faceBufferRatio  // Inner threshold (hysteresis)
            let nearbyFaces = faces.filter { $0.boundingBox.width >= softThreshold }
            let nearbyCount = nearbyFaces.count
            
            // Per-face pipeline (M1-T05): owner recognition FIRST; only
            // unknown faces continue into head pose → attention.
            var evaluations: [FaceEvaluation] = []
            var anyLooking = false
            var anyUncertain = false
            for (index, face) in nearbyFaces.enumerated() {
                let isOwnerFace = faceRecognizer.isOwner(pixelBuffer: pixelBuffer, faceRect: face.boundingBox)
                if isOwnerFace {
                    // Owner/trusted: shoulder surfing by this face is ignored
                    // — the head-pose alert path is skipped entirely (plan §9).
                    evaluations.append(FaceEvaluation(
                        trackID: index,
                        isOwner: true,
                        faceWidth: face.boundingBox.width,
                        pose: nil,
                        attention: nil
                    ))
                    continue
                }
                let poseResult = headPoseEstimator.pose(from: face)
                // Unavailable pose maps to .uncertain (never to a fake frontal).
                let attention = attentionClassifier.classify(poseResult)
                switch attention.state {
                case .looking:
                    anyLooking = true
                case .uncertain:
                    anyUncertain = true
                case .notLooking:
                    break
                }
                evaluations.append(FaceEvaluation(
                    trackID: index,
                    isOwner: false,
                    faceWidth: face.boundingBox.width,
                    pose: poseResult,
                    attention: attention
                ))
            }
            
            // Aggregate across faces for the V1 single-timer prototype:
            // looking beats uncertain beats notLooking. Known limitation: a
            // single shared timer for all unknown faces until M2 per-track
            // state (several simultaneous strangers share one alert clock).
            let aggregateState: AttentionState
            if anyLooking {
                aggregateState = .looking
            } else if anyUncertain {
                aggregateState = .uncertain
            } else {
                aggregateState = .notLooking
            }
            
            // MARK: Legacy global safe logic (replaced in M2/M4)
            // Owner-absent blur (no face at all → user walked away) plus the
            // not-enrolled multi-face rule, preserved exactly as before. The
            // unknown-face trigger that used to share this decision now flows
            // through the attention pipeline + temporal filter instead.
            let legacyStranger = (count == 0) || (!faceRecognizer.isEnrolled && nearbyCount > 1)
            
            let latencyMS = (CFAbsoluteTimeGetCurrent() - processingStart) * 1000.0
            recordFrameMetrics(latencyMS: latencyMS, faceCount: count)
            
            DispatchQueue.main.async { [weak self] in
                self?.handleResult(
                    legacyStranger: legacyStranger,
                    evaluations: evaluations,
                    aggregateState: aggregateState,
                    latencyMS: latencyMS
                )
                self?.isProcessing = false
            }
        } catch {
            print("Face detection failed: \(error)")
            isProcessing = false
        }
    }
    
    private func handleResult(
        legacyStranger: Bool,
        evaluations: [FaceEvaluation],
        aggregateState: AttentionState,
        latencyMS: Double
    ) {
        // M1-T06: one structured line per processed face.
        for evaluation in evaluations {
            DiagnosticsLog.face(
                trackID: evaluation.trackID,
                identity: evaluation.isOwner ? "owner" : "unknown",
                faceWidth: evaluation.faceWidth,
                pose: evaluation.pose,
                attention: evaluation.attention,
                latencyMS: latencyMS
            )
        }

        // Legacy path: owner-absent blur with its original frame-counter
        // debounce, untouched.
        let legacyActive = updateLegacyShieldState(strangerCondition: legacyStranger)

        // Attention path: the aggregated unknown-face state drives the shared
        // temporal filter — the alert rises only after ~0.9 s of sustained
        // looking and releases only after a clear 0.6 s gap.
        let attentionWasAlerting = attentionFilter.isAlerting
        let attentionActive = attentionFilter.update(aggregateState, at: Date())
        if attentionActive != attentionWasAlerting {
            var detail = "aggregate=\(DiagnosticsLog.name(of: aggregateState))"
            if attentionActive {
                detail += String(format: " accum=%.2f", attentionFilter.accumulatedLookingTime)
            }
            DiagnosticsLog.transition(attentionActive ? "alert_on" : "alert_off", detail: detail)
        }

        // Combine both paths with OR: the shield stays up while either the
        // legacy owner-absent blur or the attention alert demands it. Edge-
        // driven only (no per-frame icon refresh) so the two paths can never
        // fight over the icon.
        let shieldNeeded = legacyActive || attentionActive
        if shieldNeeded != isShieldActive {
            isShieldActive = shieldNeeded
            if shieldNeeded {
                shieldManager.showShield()
                delegate?.updateMenuIcon(safe: false)

                if !hasNotifiedStranger {
                    hasNotifiedStranger = true
                    delegate?.sendStrangerNotification()
                }
            } else {
                hasNotifiedStranger = false
                shieldManager.hideShield()
                delegate?.updateMenuIcon(safe: true)
            }
        }
    }

    // MARK: Legacy global safe logic (replaced in M2/M4)

    /// Owner-absent blur (no face at all → the user walked away → protect
    /// the screen) plus the not-enrolled multi-face rule, preserved exactly
    /// as before the attention pipeline existed. The counters below are the
    /// original anti-glitch debounce; they now see ONLY the legacy condition
    /// because the unknown-face trigger moved to the temporal filter.
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
                faceCount: faceCount
            )
            metricsFrameCount = 0
            metricsLatencySum = 0
            metricsWindowStart = now
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
