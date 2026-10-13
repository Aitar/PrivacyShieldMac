import Vision
import AppKit
import CoreVideo

class FaceRecognizer {
    
    private var enrolledUsers: [String: [VNFeaturePrintObservation]] = [:]  // label → prints
    private let maxEnrollmentSamples = 8        // More samples = better accuracy across angles
    private let matchThreshold: Float = 0.75    // Relaxed from 0.6 — webcam quality varies
    
    private var storageDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PrivacyShield", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private var storageURL: URL {
        return storageDir.appendingPathComponent("enrolled_faces.dat")
    }
    
    var isEnrolled: Bool {
        return !enrolledUsers.isEmpty
    }
    
    var enrolledUserCount: Int {
        return enrolledUsers.count
    }
    
    // Track current enrollment session
    private var currentEnrollmentLabel: String = ""
    private var currentEnrollmentPrints: [VNFeaturePrintObservation] = []
    
    init() {
        loadPrints()
    }
    
    // MARK: - Enrollment
    
    func startNewEnrollment(label: String) {
        currentEnrollmentLabel = label
        currentEnrollmentPrints = []
    }
    
    func enrollFace(from pixelBuffer: CVPixelBuffer) -> Bool {
        guard let facePrint = generateFacePrint(from: pixelBuffer) else {
            print("Enrollment: No face found or feature print failed")
            return false
        }
        
        currentEnrollmentPrints.append(facePrint)
        print("Enrollment [\(currentEnrollmentLabel)]: Captured sample \(currentEnrollmentPrints.count)/\(maxEnrollmentSamples)")
        
        if currentEnrollmentPrints.count >= maxEnrollmentSamples {
            enrolledUsers[currentEnrollmentLabel] = currentEnrollmentPrints
            savePrints()
            print("Enrollment complete for '\(currentEnrollmentLabel)'! Total enrolled users: \(enrolledUsers.count)")
            return true
        }
        
        return true
    }
    
    var enrollmentProgress: Int {
        return currentEnrollmentPrints.count
    }
    
    var enrollmentTarget: Int {
        return maxEnrollmentSamples
    }
    
    func resetAllEnrollments() {
        enrolledUsers.removeAll()
        currentEnrollmentPrints.removeAll()
        try? FileManager.default.removeItem(at: storageURL)
        print("All enrollments reset")
    }
    
    // MARK: - Recognition

    /// Returns the enrolled label whose feature print best matches the face
    /// cropped from `faceRect`, or `nil` when nothing matches within
    /// `matchThreshold` (or no feature print could be generated for the crop).
    ///
    /// Pure label lookup with no owner special case: callers map the label to
    /// an `IdentityState` ("owner" → .owner, "trusted…" → .trusted, nil →
    /// .other). M2-T06's recognition caching calls this instead of `isOwner`
    /// so per-track identity can distinguish WHO matched, not just whether
    /// someone enrolled did.
    ///
    /// Not-enrolled behavior stays in the callers: this returns `nil` when no
    /// user is enrolled, while `isOwner` keeps returning `true` in that case
    /// (M1 semantics — nobody is a stranger until someone enrolls).
    func identify(pixelBuffer: CVPixelBuffer, faceRect: CGRect) -> String? {
        guard isEnrolled else { return nil }

        guard let facePrint = generateFacePrint(from: pixelBuffer, faceRect: faceRect) else {
            return nil
        }

        // Best (label, distance) across ALL enrolled users and their prints.
        var bestLabel: String?
        var bestDistance: Float = Float.greatestFiniteMagnitude
        for (label, prints) in enrolledUsers {
            for ownerPrint in prints {
                var distance: Float = 0
                do {
                    try facePrint.computeDistance(&distance, to: ownerPrint)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestLabel = label
                    }
                } catch {
                    continue
                }
            }
        }

        guard let label = bestLabel, bestDistance < matchThreshold else {
            return nil  // No match found → stranger
        }
        return label
    }

    func isOwner(pixelBuffer: CVPixelBuffer, faceRect: CGRect) -> Bool {
        guard isEnrolled else { return true }

        // Refactored onto identify() (M2-T06) with identical behavior: true
        // iff ANY enrolled label has a print within `matchThreshold`.
        return identify(pixelBuffer: pixelBuffer, faceRect: faceRect) != nil
    }
    
    // MARK: - Feature Print Generation
    
    private func generateFacePrint(from pixelBuffer: CVPixelBuffer, faceRect: CGRect? = nil) -> VNFeaturePrintObservation? {
        let detectedRect: CGRect
        if let rect = faceRect {
            detectedRect = rect
        } else {
            let faceRequest = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try handler.perform([faceRequest])
            } catch {
                return nil
            }
            guard let face = (faceRequest.results as? [VNFaceObservation])?.first else {
                return nil
            }
            detectedRect = face.boundingBox
        }
        
        guard let faceImage = cropFace(from: pixelBuffer, rect: detectedRect) else {
            return nil
        }
        
        let featurePrintRequest = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: faceImage, options: [:])
        do {
            try handler.perform([featurePrintRequest])
        } catch {
            return nil
        }
        
        return featurePrintRequest.results?.first as? VNFeaturePrintObservation
    }
    
    private func cropFace(from pixelBuffer: CVPixelBuffer, rect: CGRect) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = ciImage.extent.width
        let height = ciImage.extent.height
        
        let padding: CGFloat = 0.15
        let x = max(0, (rect.origin.x - padding) * width)
        let y = max(0, (rect.origin.y - padding) * height)
        let w = min(width - x, (rect.width + padding * 2) * width)
        let h = min(height - y, (rect.height + padding * 2) * height)
        
        let cropRect = CGRect(x: x, y: y, width: w, height: h)
        let croppedCI = ciImage.cropped(to: cropRect)
        
        let context = CIContext()
        return context.createCGImage(croppedCI, from: croppedCI.extent)
    }
    
    // MARK: - Persistence
    
    private func savePrints() {
        do {
            // Convert to serializable format: [String: [Data]]
            var archiveDict: [String: [Data]] = [:]
            for (label, prints) in enrolledUsers {
                var dataArray: [Data] = []
                for print in prints {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true)
                    dataArray.append(data)
                }
                archiveDict[label] = dataArray
            }
            let data = try NSKeyedArchiver.archivedData(withRootObject: archiveDict, requiringSecureCoding: false)
            try data.write(to: storageURL)
            print("Saved \(enrolledUsers.count) enrolled users to disk")
        } catch {
            print("Failed to save prints: \(error)")
        }
    }
    
    private func loadPrints() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            if let archiveDict = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? [String: [Data]] {
                for (label, dataArray) in archiveDict {
                    var prints: [VNFeaturePrintObservation] = []
                    for printData in dataArray {
                        if let observation = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: printData) {
                            prints.append(observation)
                        }
                    }
                    if !prints.isEmpty {
                        enrolledUsers[label] = prints
                    }
                }
                print("Loaded \(enrolledUsers.count) enrolled users from disk")
            }
        } catch {
            print("Failed to load prints: \(error)")
        }
    }
}
