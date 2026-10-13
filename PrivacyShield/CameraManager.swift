import AVFoundation
import AppKit

protocol CameraManagerDelegate: AnyObject {
    func didOutput(pixelBuffer: CVPixelBuffer)
}

class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private weak var delegate: CameraManagerDelegate?
    private let videoDataOutputQueue = DispatchQueue(label: "com.privacyshield.videoqueue", qos: .userInitiated)

    // MARK: - Capture cadence metrics (M1-T03)

    // Capture FPS is measured over consecutive ~1 s windows of didOutput
    // callbacks (O(1) per frame: one clock read, one counter increment; the
    // FPS figure is only recomputed when a window closes). All metric state
    // is guarded by metricsLock because the video output queue writes it
    // while other threads (debug layer, UI) read it.
    //
    // Dropped/throttled frames: with alwaysDiscardsLateVideoFrames = true a
    // late frame is dropped instead of queued, so drops are NOT observable as
    // a drop callback — they manifest as the measured capture FPS falling
    // below the configured format FPS. "Throttled" is therefore defined as
    // measured FPS < 90% of the configured FPS (see emitCaptureMetricsLog).
    private let metricsLock = NSLock()
    private var metricsFrameCount = 0
    private var metricsWindowStartNanos: UInt64 = 0
    private var metricsHasWindow = false
    private var measuredCaptureFPS: Double = 0.0
    private var nextMetricsLogNanos: UInt64?
    private var configuredWidth: Int32?
    private var configuredHeight: Int32?
    private var configuredFPS: Int?

    /// Capture FPS measured over the most recently completed ~1 s window of
    /// didOutput callbacks. 0.0 until the first window completes. Written on
    /// the video output queue, readable from any thread (thread-safe).
    /// Vision-side processed FPS is a downstream concern (FaceDetector) and is
    /// deliberately not measured here.
    private(set) var captureFPS: Double {
        get {
            metricsLock.lock()
            defer { metricsLock.unlock() }
            return measuredCaptureFPS
        }
        set {
            metricsLock.lock()
            measuredCaptureFPS = newValue
            metricsLock.unlock()
        }
    }

    /// Human-readable configured capture format, e.g. "1920x1080@30"; nil
    /// while no format has been pinned (device kept its default). Thread-safe.
    var configuredFormatSummary: String? {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        guard let width = configuredWidth, let height = configuredHeight, let fps = configuredFPS else { return nil }
        return "\(width)x\(height)@\(fps)"
    }

    init(delegate: CameraManagerDelegate) {
        self.delegate = delegate
        super.init()
    }
    
    func checkPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("Camera auth status: \(status.rawValue)")
        
        switch status {
        case .authorized:
            setupAndStartSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                print("Camera permission result: \(granted)")
                if granted {
                    DispatchQueue.main.async {
                        self?.setupAndStartSession()
                    }
                } else {
                    print("User denied camera access")
                }
            }
        case .denied, .restricted:
            print("Camera permission denied or restricted. Please enable in System Settings > Privacy & Security > Camera")
        @unknown default:
            print("Unknown camera auth status")
        }
    }
    
    private func setupAndStartSession() {
        print("Setting up capture session…")
        
        let session = AVCaptureSession()
        session.beginConfiguration()
        // NOTE: `.inputPriority` (the iOS way to pin a session to the device's
        // activeFormat) is unavailable on macOS, so we use `.high` — high quality
        // without a hard resolution cap — and pin the exact format on the device
        // itself in applySelectedCameraFormat(to:) below, replacing `.medium`.
        session.sessionPreset = .high
        
        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            print("ERROR: No camera device found")
            return
        }
        print("Found camera: \(videoDevice.localizedName)")
        
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            guard session.canAddInput(videoDeviceInput) else {
                print("ERROR: Cannot add camera input")
                return
            }
            session.addInput(videoDeviceInput)
            applySelectedCameraFormat(to: videoDevice)
        } catch {
            print("ERROR: Failed to create camera input: \(error)")
            return
        }
        
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        
        guard session.canAddOutput(videoDataOutput) else {
            print("ERROR: Cannot add video output")
            return
        }
        session.addOutput(videoDataOutput)
        print("Video output added successfully")
        
        session.commitConfiguration()
        self.captureSession = session
        
        // Start on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
            let running = self?.captureSession?.isRunning ?? false
            print("Capture session running: \(running)")
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recordCaptureSample()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        delegate?.didOutput(pixelBuffer: pixelBuffer)
    }

    // MARK: - Capture cadence metrics (M1-T03)

    /// Counts a delivered frame and closes the ~1 s FPS window when due.
    /// Called on the video output queue only. O(1) per frame: a monotonic
    /// clock read and a counter increment; allocations only in the rare
    /// window-close/log branch (about once per second at most).
    private func recordCaptureSample() {
        let now = DispatchTime.now().uptimeNanoseconds
        var completedFPS: Double?
        var metricsDue = false
        metricsLock.lock()
        if !metricsHasWindow {
            metricsHasWindow = true
            metricsWindowStartNanos = now
            metricsFrameCount = 0
            nextMetricsLogNanos = now + Self.metricsLogIntervalNanos
        }
        metricsFrameCount += 1
        let elapsedNanos = now - metricsWindowStartNanos
        if elapsedNanos >= Self.metricsWindowNanos {
            completedFPS = Double(metricsFrameCount) * 1_000_000_000 / Double(elapsedNanos)
            metricsFrameCount = 0
            metricsWindowStartNanos = now
        }
        if let deadline = nextMetricsLogNanos, now >= deadline {
            metricsDue = true
            nextMetricsLogNanos = now + Self.metricsLogIntervalNanos
        }
        metricsLock.unlock()

        if let fps = completedFPS {
            captureFPS = fps
        }
        if metricsDue {
            emitCaptureMetricsLog()
        }
    }

    /// One-line metrics event, roughly every 5 s, ONLY when debug logging is
    /// enabled. Gating (and the standard `ts=` timestamp prefix) live in
    /// `DiagnosticsLog.captureMetrics`, so the UserDefaults flag is still
    /// read on this 5 s cadence (not per frame); normal (non-debug) operation
    /// prints nothing, and toggling debug mode takes effect within ~5 s.
    ///
    /// Format (matches the project's pipe-separated structured logging):
    ///   ts=2026-10-13T10:12:33.412Z | event=capture_metrics | capture_fps=29.8 | throttled=false | format=1920x1080@30
    ///
    /// "throttled" is true when the measured capture FPS is meaningfully below
    /// the configured format FPS (< 90%). Because
    /// alwaysDiscardsLateVideoFrames = true silently drops late frames, a drop
    /// has no callback of its own — it only shows up as capture FPS below the
    /// configured FPS, which is exactly what this flag reports. When no format
    /// was pinned (device default kept), the reference FPS is unknown and
    /// throttled is reported as false (cannot be judged).
    private func emitCaptureMetricsLog() {
        let fps = captureFPS
        let formatSummary = configuredFormatSummary
        let throttled: Bool
        if let reference = configuredFPS {
            throttled = fps < 0.9 * Double(reference)
        } else {
            throttled = false
        }
        DiagnosticsLog.captureMetrics(captureFPS: fps, throttled: throttled, format: formatSummary)
    }

    private static let metricsWindowNanos: UInt64 = 1_000_000_000      // ~1 s FPS window
    private static let metricsLogIntervalNanos: UInt64 = 5_000_000_000 // log every ~5 s

    // MARK: - Camera format selection

    // A device format plus the frame rate to pin it to. Selection priority (first
    // match wins): tier 1 = 1920x1080 @ 30 FPS, tier 2 = 1920x1080 @ 15 FPS,
    // tier 3 = highest stable supported format (largest width*height whose max
    // frame rate >= 15; ties prefer the higher max frame rate, and the configured
    // cadence is capped at 30 FPS). 4K is not required for V1, but external
    // higher-resolution cameras work naturally because every reported format is
    // enumerated. If the device cannot be locked, we keep its default format.
    private struct CameraFormatSelection {
        let format: AVCaptureDevice.Format
        let width: Int32
        let height: Int32
        let fps: Int
        let tier: String
    }

    private func applySelectedCameraFormat(to device: AVCaptureDevice) {
        guard let selection = selectCameraFormat(for: device) else {
            print("WARNING: No suitable camera format found; keeping device default format")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = selection.format
            // Pin both bounds to the same duration so the frame cadence stays stable.
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(selection.fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
            // Record the actually-applied cadence only after the lock succeeded:
            // it is the reference the throttled flag compares measured FPS against.
            metricsLock.lock()
            configuredWidth = selection.width
            configuredHeight = selection.height
            configuredFPS = selection.fps
            metricsLock.unlock()
            let fpsText = String(format: "%.1f", Double(selection.fps))
            print("Camera format selected: \(selection.width)x\(selection.height) @ \(fpsText) FPS (\(device.localizedName)) [matched \(selection.tier)]")
        } catch {
            print("WARNING: Could not lock camera for configuration (\(error)); keeping device default format")
        }
    }

    private func selectCameraFormat(for device: AVCaptureDevice) -> CameraFormatSelection? {
        // Tier 1: 1920x1080 @ 30 FPS
        if let format = device.formats.first(where: { formatMatches($0, width: 1920, height: 1080, fps: 30) }) {
            return CameraFormatSelection(format: format, width: 1920, height: 1080, fps: 30, tier: "tier 1: 1920x1080 @ 30 FPS")
        }
        // Tier 2: 1920x1080 @ 15 FPS
        if let format = device.formats.first(where: { formatMatches($0, width: 1920, height: 1080, fps: 15) }) {
            return CameraFormatSelection(format: format, width: 1920, height: 1080, fps: 15, tier: "tier 2: 1920x1080 @ 15 FPS")
        }
        // Tier 3: highest stable supported format (largest width*height with max frame rate >= 15).
        var bestFormat: AVCaptureDevice.Format?
        var bestWidth: Int32 = 0
        var bestHeight: Int32 = 0
        var bestPixels = 0
        var bestMaxFPS: Double = 0
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Int(dimensions.width) * Int(dimensions.height)
            let maxFPS = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            guard maxFPS >= 15 else { continue }
            if pixels > bestPixels || (pixels == bestPixels && maxFPS > bestMaxFPS) {
                bestFormat = format
                bestWidth = dimensions.width
                bestHeight = dimensions.height
                bestPixels = pixels
                bestMaxFPS = maxFPS
            }
        }
        if let format = bestFormat {
            // Cap the configured rate at 30 FPS even if the sensor supports more.
            let fps = max(min(Int(bestMaxFPS.rounded(.down)), 30), 15)
            return CameraFormatSelection(format: format, width: bestWidth, height: bestHeight, fps: fps, tier: "tier 3: highest stable format")
        }
        return nil
    }

    private func formatMatches(_ format: AVCaptureDevice.Format, width: Int32, height: Int32, fps: Double) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.width == width && dimensions.height == height else { return false }
        return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
    }
}
