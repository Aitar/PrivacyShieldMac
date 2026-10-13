import AVFoundation
import AppKit

protocol CameraManagerDelegate: AnyObject {
    func didOutput(pixelBuffer: CVPixelBuffer)
}

class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private weak var delegate: CameraManagerDelegate?
    private let videoDataOutputQueue = DispatchQueue(label: "com.privacyshield.videoqueue", qos: .userInitiated)
    
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        delegate?.didOutput(pixelBuffer: pixelBuffer)
    }

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
