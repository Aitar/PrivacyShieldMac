import AppKit
import Foundation
import Carbon.HIToolbox
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var cameraManager: CameraManager?
    var faceDetector: FaceDetector?
    var shieldManager: ShieldManager?
    private var hotKeyRef: EventHotKeyRef?
    
    // Settings
    var sensitivityThreshold: Float {
        get { UserDefaults.standard.float(forKey: "matchThreshold").isZero ? 0.6 : UserDefaults.standard.float(forKey: "matchThreshold") }
        set { UserDefaults.standard.set(newValue, forKey: "matchThreshold") }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Disable App Nap so camera + detection stays active in background
        ProcessInfo.processInfo.disableAutomaticTermination("Privacy Shield active")
        let _ = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Monitoring camera for privacy")
        
        setupMenu()
        registerGlobalHotKey()
        requestNotificationPermission()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startPrivacyShield()
        }
    }
    
    private func startPrivacyShield() {
        let shield = ShieldManager()
        self.shieldManager = shield
        
        let detector = FaceDetector(shieldManager: shield, delegate: self)
        self.faceDetector = detector
        
        let camera = CameraManager(delegate: detector)
        self.cameraManager = camera
        
        camera.checkPermissionAndStart()
        updateMenuIcon(safe: true)
    }

    // MARK: - Menu Bar
    
    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Privacy Shield") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Shield"
            }
        }
        rebuildMenu()
    }
    
    private func rebuildMenu() {
        let menu = NSMenu()
        
        // Status
        let statusItem = NSMenuItem(title: "Status: Initializing…", action: nil, keyEquivalent: "")
        statusItem.tag = 100
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())
        
        // Enrollment
        let enrollItem = NSMenuItem(title: "Enroll My Face", action: #selector(enrollFace), keyEquivalent: "e")
        enrollItem.target = self
        menu.addItem(enrollItem)
        
        let addUserItem = NSMenuItem(title: "Add Trusted Face", action: #selector(addTrustedFace), keyEquivalent: "")
        addUserItem.target = self
        menu.addItem(addUserItem)
        
        let resetItem = NSMenuItem(title: "Reset All Enrollments", action: #selector(resetEnrollment), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Calibration
        let calibrateDirectionItem = NSMenuItem(title: "Calibrate Screen Direction…", action: #selector(calibrateScreenDirection), keyEquivalent: "")
        calibrateDirectionItem.target = self
        menu.addItem(calibrateDirectionItem)
        
        let calibrateItem = NSMenuItem(title: "Calibrate Detection Range…", action: #selector(calibrateRange), keyEquivalent: "")
        calibrateItem.target = self
        menu.addItem(calibrateItem)
        
        let currentThreshold = UserDefaults.standard.float(forKey: "minFaceSize")
        let thresholdLabel = currentThreshold > 0 ? String(format: "Current threshold: %.0f%%", currentThreshold * 100) : "Current: default (2 ft)"
        let thresholdItem = NSMenuItem(title: thresholdLabel, action: nil, keyEquivalent: "")
        thresholdItem.tag = 300
        menu.addItem(thresholdItem)
        
        // Debug-only: current calibrated screen center (updates via tag 400)
        if UserDefaults.standard.bool(forKey: "debugLoggingEnabled") {
            let centerItem = NSMenuItem(title: screenCenterMenuLine(), action: nil, keyEquivalent: "")
            centerItem.tag = 400
            menu.addItem(centerItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Toggle
        let toggleItem = NSMenuItem(title: "Toggle Shield (⌘⇧L)", action: #selector(toggleShield), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        launchItem.tag = 200
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit Privacy Shield", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        self.statusItem.menu = menu
    }
    
    func updateMenuIcon(safe: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem.button else { return }
            let symbolName = safe ? "eye" : "eye.slash.fill"
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Privacy Shield") {
                image.isTemplate = true
                button.image = image
            }
            // Update status text in menu
            if let menu = self?.statusItem.menu, let item = menu.item(withTag: 100) {
                item.title = safe ? "Status: ✅ Owner detected" : "Status: ⚠️ Shield active"
            }
        }
    }
    
    // MARK: - Actions
    
    @objc func enrollFace() {
        guard let detector = faceDetector else { return }
        Toast.show(message: "Look at the camera… Enrolling your face", duration: 3)
        detector.startEnrollment(userLabel: "owner") { success in
            if success {
                Toast.show(message: "✅ Face enrolled successfully!", duration: 2)
            } else {
                Toast.show(message: "❌ Enrollment failed — make sure your face is visible", duration: 2)
            }
        }
    }
    
    @objc func addTrustedFace() {
        guard let detector = faceDetector else { return }
        Toast.show(message: "Ask the trusted person to look at the camera…", duration: 3)
        detector.startEnrollment(userLabel: "trusted_\(Int.random(in: 1000...9999))") { success in
            if success {
                Toast.show(message: "✅ Trusted face added!", duration: 2)
            } else {
                Toast.show(message: "❌ Failed — make sure their face is visible", duration: 2)
            }
        }
    }
    
    @objc func resetEnrollment() {
        faceDetector?.faceRecognizer.resetAllEnrollments()
        Toast.show(message: "All enrollments reset", duration: 2)
    }
    
    @objc func toggleShield() {
        shieldManager?.toggleShield()
    }
    
    @objc func calibrateRange() {
        guard let detector = faceDetector else { return }
        
        Toast.show(message: "Stand at the distance you want to protect.\nLook at the camera for 3 seconds…", duration: 4)
        
        // Delay slightly so user can position themselves
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            detector.startCalibration { [weak self] success, measuredSize in
                if success {
                    let pct = Int(measuredSize * 100)
                    Toast.show(message: "✅ Calibrated! Threshold set to \(pct)%\nAnyone closer than your current position will trigger the shield.", duration: 3)
                    // Update the menu to show new threshold
                    if let menu = self?.statusItem.menu, let item = menu.item(withTag: 300) {
                        item.title = String(format: "Current threshold: %d%%", pct)
                    }
                } else {
                    Toast.show(message: "❌ Calibration failed — face not detected", duration: 2)
                }
            }
        }
    }
    
    @objc func calibrateScreenDirection() {
        guard let detector = faceDetector else { return }
        guard !detector.isScreenCalibrating else {
            Toast.show(message: "Calibration already running", duration: 2)
            return
        }
        
        Toast.show(message: "Sit in your normal position, look at the center of the screen…\nCalibration starts in a few seconds.", duration: 4)
        
        // Delay slightly so user can settle (the detector adds its own 2 s lead-in)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, let detector = self.faceDetector else { return }
            guard !detector.isScreenCalibrating else { return }
            detector.startScreenDirectionCalibration { success, result in
                if success, let result = result {
                    Toast.show(message: String(format: "✅ Screen direction calibrated — center yaw %+.1f°, pitch %+.1f°", result.centerYaw, result.centerPitch), duration: 3)
                } else {
                    Toast.show(message: "❌ Calibration failed — not enough valid samples; make sure your face is visible and well lit", duration: 3)
                }
                // Recalibration overwrote the store — refresh the debug line
                DispatchQueue.main.async { [weak self] in
                    self?.refreshScreenCenterMenuLine()
                }
            }
        }
    }
    
    /// Debug-mode menu line showing the currently stored screen center.
    private func screenCenterMenuLine() -> String {
        if let center = ScreenCenterStore.load() {
            return String(format: "Screen center: yaw %+.1f°, pitch %+.1f°", center.yaw, center.pitch)
        }
        return "Screen center: not calibrated"
    }
    
    /// Updates the debug-only screen center line (tag 400) in the live menu.
    private func refreshScreenCenterMenuLine() {
        guard UserDefaults.standard.bool(forKey: "debugLoggingEnabled"),
              let menu = statusItem.menu, let item = menu.item(withTag: 400) else { return }
        item.title = screenCenterMenuLine()
    }
    
    // MARK: - Global Hotkey (⌘⇧L)
    
    private func registerGlobalHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x50535F48) // "PS_H"
        hotKeyID.id = 1
        
        // ⌘⇧L: cmdKey + shiftKey + kVK_ANSI_L
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = UInt32(kVK_ANSI_L)
        
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            print("Global hotkey ⌘⇧L registered")
        } else {
            print("Failed to register global hotkey: \(status)")
        }
        
        // Install handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            appDelegate.toggleShield()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
    
    // MARK: - Launch at Login
    
    @objc func toggleLaunchAtLogin() {
        let enabled = isLaunchAtLoginEnabled()
        setLaunchAtLogin(!enabled)
        if let menu = statusItem.menu, let item = menu.item(withTag: 200) {
            item.state = !enabled ? .on : .off
        }
    }
    
    private func isLaunchAtLoginEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "launchAtLogin")
    }
    
    private func setLaunchAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        // For a proper implementation use SMAppService on macOS 13+ or SMLoginItemSetEnabled
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Login item error: \(error)")
            }
        }
    }
    
    // MARK: - Notifications
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            print("Notification permission: \(granted)")
        }
    }
    
    func sendStrangerNotification() {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Privacy Shield"
        content.body = "An unrecognized face was detected. Screen has been blurred."
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: "stranger_\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

import ServiceManagement

extension AppDelegate: FaceDetectorDelegate {}
