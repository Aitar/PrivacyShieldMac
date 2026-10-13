import AppKit
import AVFoundation
import Foundation
import Carbon.HIToolbox
import UserNotifications

// MARK: - Display-state → UI mappings (M4-T04)

/// Menu-bar status line for each display state. Pure mapping so the
/// differentiated texts — including calibration and camera-unavailable — are
/// testable now and M4-T06 can drive them from `privacyStateChanged(to:)`.
/// The legacy `updateMenuIcon(safe:)` path renders the same texts whenever a
/// state has been reported (see `AppDelegate.statusLineText`).
extension PrivacyDisplayState {
    var statusText: String {
        switch self {
        case .monitoringSafe: return "Status: ✅ Monitoring safe"
        case .ownerAbsent: return "Status: 🚪 Owner away — blurred"
        case .shoulderSurferDetected: return "Status: 👀 Observer detected — blurred"
        case .bothPoliciesActive: return "Status: ⚠️ Owner away + observer — blurred"
        case .calibrating: return "Status: 🎯 Calibrating…"
        case .cameraUnavailable: return "Status: 📷 Camera unavailable"
        }
    }

    /// The shield reason this state should notify about, or nil when the
    /// state carries no blur demand: safe, calibrating and camera-unavailable
    /// never notify.
    var notificationReason: PrivacyShieldReason? {
        switch self {
        case .monitoringSafe, .calibrating, .cameraUnavailable: return nil
        case .ownerAbsent: return .ownerAbsent
        case .shoulderSurferDetected: return .shoulderSurfer
        case .bothPoliciesActive: return .both
        }
    }
}

/// Reason-aware notification body (M4-T04): the user is told WHY the screen
/// is protected instead of receiving one undifferentiated "stranger" signal.
/// The title is the constant "⚠️ Privacy Shield" for every reason; `.none`
/// never notifies.
extension PrivacyShieldReason {
    var notificationBody: String? {
        switch self {
        case .shoulderSurfer:
            return "Someone appears to be looking at your screen. Screen has been blurred."
        case .ownerAbsent:
            return "You stepped away — screen has been blurred."
        case .both:
            return "Owner away and someone is looking at your screen. Screen has been blurred."
        case .none:
            return nil
        }
    }
}

/// Anti-spam gate for shield notifications (M4-T04): at most one notification
/// per shield EPISODE, never twice for the same reason within an episode, and
/// a configurable minimum interval between two sends inside one episode
/// (reason-change updates). Pure logic — the caller injects `now`.
///
/// Episode lifecycle: the first blur reason opens an episode; `.none` (shield
/// hidden) closes it and resets everything, so the next blur starts a fresh
/// episode and notifies again. Blocked (interval-skipped) attempts consume
/// nothing: only successful sends are remembered, so a dropped reason-change
/// update may still fire once the interval has elapsed.
struct NotificationGate {
    /// Minimum seconds between two sends within one episode. A reason-change
    /// update arriving sooner is dropped (not queued); the episode's first
    /// send is never interval-checked (`lastSendDate` resets with the
    /// episode).
    var minUpdateInterval: TimeInterval = 10

    /// True from the first send of an episode until it is closed.
    private(set) var isEpisodeActive = false
    /// Reasons already sent in the current episode (never re-notified).
    private(set) var notifiedReasons: [PrivacyShieldReason] = []
    /// When the current episode last actually sent (interval anchor).
    private(set) var lastSendDate: Date?

    /// Applies the anti-spam rules to one notification attempt for `reason`
    /// at `date`. `.none` never sends and closes the current episode (shield
    /// hidden → episode over).
    mutating func shouldSend(for reason: PrivacyShieldReason, at date: Date) -> Bool {
        guard reason != .none else {
            endEpisode()
            return false
        }
        if isEpisodeActive {
            // Never re-notify for the same reason within an episode.
            if notifiedReasons.contains(reason) { return false }
            // A different-reason update waits out the min interval, measured
            // from the last actual send (a blocked attempt is not an anchor).
            if let last = lastSendDate,
               date.timeIntervalSince(last) < minUpdateInterval {
                return false
            }
        }
        isEpisodeActive = true
        notifiedReasons.append(reason)
        lastSendDate = date
        return true
    }

    /// Closes the current episode (if any): the next blur reason notifies
    /// again immediately, regardless of interval.
    mutating func endEpisode() {
        isEpisodeActive = false
        notifiedReasons = []
        lastSendDate = nil
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var cameraManager: CameraManager?
    var faceDetector: FaceDetector?
    var shieldManager: ShieldManager?
    private var hotKeyRef: EventHotKeyRef?

    // M4-T04: reason-aware notifications + menu status line
    /// Anti-spam gate for the reason-aware shield notifications (one send per
    /// episode, per-reason dedup, min interval between reason-change updates).
    private var notificationGate = NotificationGate()
    /// Last display state reported via `privacyStateChanged(to:)`. nil until
    /// the detector reports its first state; the legacy
    /// `updateMenuIcon(safe:)` path then falls back to the generic
    /// safe/shield-active line because it cannot name the reason.
    private var lastDisplayState: PrivacyDisplayState?
    /// Last safe flag seen by `updateMenuIcon(safe:)` — together with
    /// `lastDisplayState` it decides the rendered status line, whichever
    /// path reported last.
    private var lastKnownSafe = true

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Disable App Nap so camera + detection stays active in background
        ProcessInfo.processInfo.disableAutomaticTermination("Privacy Shield active")
        let _ = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Monitoring camera for privacy")
        
        setupMenu()
        registerGlobalHotKey()
        requestNotificationPermission()

        // Camera-unavailable status (M4-T06): a denied/restricted camera
        // authorization at launch can never deliver frames, so surface it
        // through the existing display-state machinery ("📷 Camera
        // unavailable"). The detector cannot produce this state (it never
        // sees a frame in that case); once frames flow, its state reports
        // replace this line.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            privacyStateChanged(to: .cameraUnavailable)
        default:
            break
        }

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
        // Restore the debug preview when it was enabled (M4-T06): the
        // detector loads the persisted settings itself, but the overlay
        // window needs the explicit visibility call.
        detector.setDebugPreviewVisible(AttentionSettingsStore.load().debugPreviewEnabled)
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

        // M4-T06 settings toggles — every checkmark reflects the persisted
        // store, so a rebuild is always consistent with what the detector
        // was handed via `applySettings`.
        let settings = AttentionSettingsStore.load()

        let shoulderItem = NSMenuItem(title: "Shoulder Surf Detection",
                                      action: #selector(toggleShoulderSurfDetection), keyEquivalent: "")
        shoulderItem.target = self
        shoulderItem.state = settings.shoulderSurfDetectionEnabled ? .on : .off
        menu.addItem(shoulderItem)

        let blurAwayItem = NSMenuItem(title: "Blur When I Leave",
                                      action: #selector(toggleBlurWhenOwnerAbsent), keyEquivalent: "")
        blurAwayItem.target = self
        blurAwayItem.state = settings.blurWhenOwnerAbsent ? .on : .off
        menu.addItem(blurAwayItem)

        let blurWatchItem = NSMenuItem(title: "Blur When Someone Watches",
                                       action: #selector(toggleBlurWhenShoulderSurferDetected), keyEquivalent: "")
        blurWatchItem.target = self
        blurWatchItem.state = settings.blurWhenShoulderSurferDetected ? .on : .off
        menu.addItem(blurWatchItem)

        menu.addItem(NSMenuItem.separator())

        // Attention Sensitivity submenu (M4-T02 presets; radio state is the
        // persisted preset).
        let sensitivityItem = NSMenuItem(title: "Attention Sensitivity", action: nil, keyEquivalent: "")
        let sensitivityMenu = NSMenu()
        for preset in [SensitivityPreset.conservative, .balanced, .sensitive] {
            let item = NSMenuItem(title: sensitivityMenuTitle(preset),
                                  action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = settings.sensitivityPreset == preset ? .on : .off
            sensitivityMenu.addItem(item)
        }
        sensitivityItem.submenu = sensitivityMenu
        menu.addItem(sensitivityItem)

        // Looking Duration submenu (M4-T06): the user's trigger-duration
        // override. "Band Default" (first item, checked when no override is
        // stored) restores the preset/band value; the numeric items are
        // checked when the stored override equals them exactly.
        let durationItem = NSMenuItem(title: "Looking Duration", action: nil, keyEquivalent: "")
        let durationMenu = NSMenu()
        let bandDefaultItem = NSMenuItem(title: "Band Default",
                                         action: #selector(setLookingDuration(_:)), keyEquivalent: "")
        bandDefaultItem.target = self
        bandDefaultItem.state = settings.triggerDurationOverride == nil ? .on : .off
        durationMenu.addItem(bandDefaultItem)
        for seconds in [0.5, 0.8, 1.0, 1.5] {
            let item = NSMenuItem(title: String(format: "%.1f s", seconds),
                                  action: #selector(setLookingDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = settings.triggerDurationOverride == seconds ? .on : .off
            durationMenu.addItem(item)
        }
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)

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

        // Debug preview overlay (M4-T05/T06)
        let previewItem = NSMenuItem(title: "Debug Preview…",
                                     action: #selector(toggleDebugPreview), keyEquivalent: "")
        previewItem.target = self
        previewItem.state = settings.debugPreviewEnabled ? .on : .off
        menu.addItem(previewItem)

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

    /// Submenu title for a sensitivity preset (M4-T06): the plain preset
    /// name — the plan's per-preset headline values are what the preset
    /// maps to (`SensitivityPreset.classifierTolerances`), not part of the
    /// menu label.
    private func sensitivityMenuTitle(_ preset: SensitivityPreset) -> String {
        switch preset {
        case .conservative: return "Conservative"
        case .balanced: return "Balanced"
        case .sensitive: return "Sensitive"
        }
    }
    
    func updateMenuIcon(safe: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            let symbolName = safe ? "eye" : "eye.slash.fill"
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Privacy Shield") {
                image.isTemplate = true
                button.image = image
            }
            self.lastKnownSafe = safe
            if safe {
                // Shield hidden → the notification episode is over (the
                // M4-T06 reason path ends it too, via .monitoringSafe).
                self.notificationGate.endEpisode()
            }
            self.applyStatusLine()
        }
    }

    /// Renders the menu status line (tag 100) from the last known signals.
    /// Main queue only; called after either signal changes so both the
    /// legacy `updateMenuIcon(safe:)` path and the M4-T06
    /// `privacyStateChanged(to:)` path stay consistent.
    private func applyStatusLine() {
        guard let menu = statusItem.menu, let item = menu.item(withTag: 100) else { return }
        item.title = statusLineText()
    }

    /// The status line for the CURRENT signals: a reported display state wins
    /// when it agrees with the legacy safe flag; otherwise the generic
    /// fallback renders what the safe/unsafe icon signal alone can know.
    /// The fallback exists for the manual shield toggle (⌘⇧L) and any
    /// pre-report window at launch — the detector's M4-T06 state reports
    /// name the reason whenever they agree with the icon flag.
    private func statusLineText() -> String {
        if let state = lastDisplayState {
            switch (lastKnownSafe, state) {
            case (true, .calibrating), (true, .cameraUnavailable):
                // Detector-side device states stay visible while the camera
                // reports safe (no blur is demanded during them).
                return state.statusText
            case (false, let reported) where reported.isShieldShown:
                return reported.statusText
            default:
                break  // Stale/contradictory report → generic fallback below.
            }
        }
        return lastKnownSafe
            ? PrivacyDisplayState.monitoringSafe.statusText
            : "Status: ⚠️ Shield active"
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

    // MARK: - Settings actions (M4-T06)

    /// Persists one settings mutation, pushes the resulting settings into
    /// the detector (picked up on its video queue before the next frame)
    /// and rebuilds the menu so every checkmark reflects the store.
    private func updateSettings(_ mutate: (inout AttentionSettings) -> Void) {
        AttentionSettingsStore.update(defaults: .standard, mutate)
        faceDetector?.applySettings(AttentionSettingsStore.load())
        rebuildMenu()
    }

    @objc func toggleShoulderSurfDetection() {
        updateSettings { $0.shoulderSurfDetectionEnabled.toggle() }
    }

    @objc func toggleBlurWhenOwnerAbsent() {
        updateSettings { $0.blurWhenOwnerAbsent.toggle() }
    }

    @objc func toggleBlurWhenShoulderSurferDetected() {
        updateSettings { $0.blurWhenShoulderSurferDetected.toggle() }
    }

    /// Sensitivity preset radio item; the raw value rides in
    /// `representedObject`.
    @objc func setSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = SensitivityPreset(rawValue: raw) else { return }
        updateSettings { $0.sensitivityPreset = preset }
    }

    /// Looking-duration radio item: a numeric item stores the seconds as a
    /// `Double` override; "Band Default" has no representedObject and
    /// therefore stores `nil` (the override is removed and the preset/band
    /// value applies again).
    @objc func setLookingDuration(_ sender: NSMenuItem) {
        updateSettings { $0.triggerDurationOverride = sender.representedObject as? Double }
    }

    /// Debug preview toggle (M4-T05/T06): persists the flag, hands the new
    /// settings to the detector (gating its per-frame state pushes) and
    /// shows/hides the overlay window itself.
    @objc func toggleDebugPreview() {
        let enable = !AttentionSettingsStore.load().debugPreviewEnabled
        updateSettings { $0.debugPreviewEnabled = enable }
        faceDetector?.setDebugPreviewVisible(enable)
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

    // The legacy undifferentiated `sendStrangerNotification()` entry point
    // was removed in M4-T06: the detector now reports display states via
    // `privacyStateChanged(to:)`, and this app delegate derives BOTH the
    // notification (reason-aware, gated below) and the menu status line
    // from that single path — exactly one notification path is active.

    /// Sends the reason-aware shield notification (M4-T04), gated by
    /// `NotificationGate` anti-spam rules (one send per episode, never twice
    /// for the same reason, ≥ minUpdateInterval between in-episode
    /// reason-change updates). Safe to call from any queue: the gate and the
    /// post run on the main queue in FIFO order relative to the other UI
    /// mutations.
    func sendNotification(for reason: PrivacyShieldReason) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            guard self.notificationGate.shouldSend(for: reason, at: now) else { return }
            self.postShieldNotification(reason: reason, at: now)
        }
    }

    /// Builds and posts one notification with the reason-specific body.
    /// Main queue only.
    private func postShieldNotification(reason: PrivacyShieldReason, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Privacy Shield"
        content.body = reason.notificationBody ?? "Screen has been blurred."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "shield_\(reason.description)_\(date.timeIntervalSince1970)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Display-state reporting (PrivacyDisplayReporting, M4-T04): records the
    /// state, feeds the notification gate and re-renders the status line.
    /// The detector side (M4-T06) calls this on state transitions only. Safe
    /// to call from any queue; the whole body runs on the main queue.
    func privacyStateChanged(to state: PrivacyDisplayState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastDisplayState = state
            switch state.notificationReason {
            case .some(let reason):
                self.sendNotification(for: reason)
            case .none:
                // Back to safe → the episode is over. Calibration and camera
                // states never notify and never touch the episode.
                if state == .monitoringSafe {
                    self.notificationGate.endEpisode()
                }
            }
            self.applyStatusLine()
        }
    }
}

import ServiceManagement

extension AppDelegate: FaceDetectorDelegate {}
extension AppDelegate: PrivacyDisplayReporting {}
