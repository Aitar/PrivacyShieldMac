# Baseline Behavior (M0-T02)

> Milestone: M0 — Repository & Baseline
> Branch: `feature/head-pose-attention`
> Recorded: 2026-10-13, before any M1+ implementation work
> Sources: read directly from the code at the baseline state (`PrivacyShield/*.swift`)
>
> **The baseline BUILD has been verified by the orchestrator**: `xcodebuild` succeeded on
> this machine against `PrivacyShield.xcodeproj`. No behavior verification has been
> performed yet — every item in Section 8 requires a human at the Mac.
>
> Note: `swift build` does **not** work at baseline (see observation P-11); the Xcode
> project is the only working build path.

Related: `docs/baseline_metrics.md` (M0-T03), `docs/implement_todolist.md` (task definitions),
`docs/DEVELOPMENT_PLAN_with_fork.md` §2 "Existing Baseline" and §4 "Phase 0".

---

## 1. High-level pipeline (as implemented)

```text
AVCaptureSession (.medium preset)          CameraManager.swift
    ↓  CVPixelBuffer (32BGRA), every camera frame, on a userInitiated queue
FaceDetector.didOutput                     FaceDetector.swift
    ↓  process only every 3rd frame (frameSkip = 3), skip if previous frame still processing
VNDetectFaceRectanglesRequest              FaceDetector.swift:103-108
    ↓  all face bounding boxes (normalized)
Face-size filter (nearby vs far)           FaceDetector.swift:114-115
    ↓  keep faces with width >= 0.8 × minFaceSize
Identity recognition per nearby face       FaceDetector.swift:127-135 → FaceRecognizer.swift
    ↓  VNGenerateImageFeaturePrint on face crop, distance < 0.75 → owner
Decision (stranger / safe)                 FaceDetector.swift:118-136
    ↓
Global frame hysteresis                    FaceDetector.swift:148-179
    ↓  3 consecutive stranger frames → show; 8 consecutive safe frames → hide
ShieldManager                              ShieldManager.swift
    ↓  one blur window per NSScreen
Screen blurred + menu icon + notification  AppDelegate.swift
```

This matches the "Existing Baseline" diagram in `docs/DEVELOPMENT_PLAN_with_fork.md` §2.

### 1.1 Capture — `PrivacyShield/CameraManager.swift`

- Permission: `AVCaptureDevice.authorizationStatus(for: .video)`; `.notDetermined` prompts
  (line 26), `.authorized` starts immediately, `.denied/.restricted` only prints to the
  console — there is no user-visible fallback (lines 36-37).
- Session: `sessionPreset = .medium` (line 48); device is
  `AVCaptureDevice.default(for: .video)` — i.e. whatever the system default camera is
  (line 50) — on this machine that is normally the built-in FaceTime HD Camera.
- Output: `AVCaptureVideoDataOutput`, pixel format `32BGRA` (lines 71-73),
  `alwaysDiscardsLateVideoFrames = true` (line 70), delivered on a dedicated
  `userInitiated` serial queue (line 11).
- Session is started on a background queue ~1 s after app launch (CameraManager.swift:86-90;
  the 1 s delay is in `AppDelegate.swift:28-30`).

### 1.2 Detection cadence — `PrivacyShield/FaceDetector.swift`

- `frameSkip = 3` (line 24): `didOutput` increments `frameCounter` and returns unless
  `frameCounter % 3 == 0` (lines 57-59). At a nominal 30 FPS capture this is ≤ 10
  Vision-processed frames per second.
- `isProcessing` guard (lines 22, 60-61): while one frame is being processed, later frames
  are dropped (back-pressure). So the effective processed rate is
  `min(captureFPS / 3, 1 / inferenceTime)`.
- Three mutually exclusive modes per processed frame: enrollment (lines 63-75),
  calibration (lines 77-100), recognition (lines 102-146).

### 1.3 Face-size filter — `PrivacyShield/FaceDetector.swift`

- `minFaceSize` is persisted in `UserDefaults` under key `"minFaceSize"`, default `0.25`
  when unset (lines 29-35). It expresses "minimum normalized face width to be considered
  nearby".
- `faceBufferRatio = 0.8` (line 38): a face is nearby when
  `boundingBox.width >= minFaceSize × 0.8` (lines 114-115). Note there is only ONE
  threshold — the "buffer zone" does not create per-face hysteresis (see P-7); stability
  comes from the global frame counters instead.
- With the default 0.25 threshold, a face is nearby when its box is ≥ 0.20 of the frame
  width (≈ 128 px at 640×360).

### 1.4 Decision matrix — `PrivacyShield/FaceDetector.swift:118-136`

Evaluated in order:

| Condition | Result |
|---|---|
| No faces at all (`count == 0`) | **stranger** → blur (user walked away) — lines 118-120 |
| Faces present but none nearby (all too small/far) | **safe** — lines 121-123 |
| Not enrolled, exactly 1 nearby face | **safe** — lines 124-126 |
| Not enrolled, ≥ 2 nearby faces | **stranger** — line 126 |
| Enrolled, every nearby face matches an enrolled print | **safe** — lines 129-135 |
| Enrolled, any nearby face fails to match | **stranger** — lines 129-135 |

The "owner absent → blur" behavior (first row) is intentional baseline behavior and is
preserved until the M4 policy split (see development plan Phase 10).

### 1.5 Recognition — `PrivacyShield/FaceRecognizer.swift`

- Enrollment: 8 samples (`maxEnrollmentSamples = 8`, line 8); each sample is a
  `VNGenerateImageFeaturePrintObservation` of the face crop (first detected face in the
  frame, line 125). Prints are persisted via `NSKeyedArchiver` to
  `~/Library/Application Support/PrivacyShield/enrolled_faces.dat` (lines 11-20, 166-184)
  and reloaded at app start (`loadPrints`, lines 186-207).
- Matching: `isOwner(pixelBuffer:faceRect:)` crops the face (padding 0.15 around the box,
  lines 146-161), generates a feature print, and computes the distance against **all**
  stored prints of **all** enrolled users; match if best distance < `matchThreshold = 0.75`
  (hardcoded, line 9; lines 89-108).
- No caching or tracking exists: recognition runs on every processed frame for every
  nearby face, and each call creates a fresh `CIContext` (line 160).

### 1.6 Global frame hysteresis — `PrivacyShield/FaceDetector.swift:148-179`

- Two counters, `consecutiveStranger` / `consecutiveSafe`, with
  `strangerThreshold = 3` (line 18) and `safeThreshold = 8` (line 19). Counters count
  *processed* frames, not time.
- Shield SHOWS after 3 consecutive stranger processed frames (lines 154-163):
  `shieldManager.showShield()`, menu icon → `eye.slash.fill`, and — once per shield
  episode — a macOS notification via `hasNotifiedStranger` (lines 159-162).
- Shield HIDES after 8 consecutive safe processed frames (lines 169-173): blur removed,
  icon → `eye`, `hasNotifiedStranger` reset (line 171).
- At the nominal 10 processed FPS this means show latency ≥ ~0.3 s and hide latency
  ≥ ~0.8 s of sustained state (actual values depend on real processed rate — see
  `docs/baseline_metrics.md`).
- While safe and not shielded, the menu icon/status is refreshed on *every* safe processed
  frame (lines 174-177).

---

## 2. Menu bar UI and actions — `PrivacyShield/AppDelegate.swift`

App entry `PrivacyShield/PrivacyShieldApp.swift` uses a `Settings` scene with `EmptyView`
(lines 17-19) and `Info.plist` sets `LSUIElement` — the app is menu-bar only, with no dock
icon or window.

Status item icon: `eye` (safe) / `eye.slash.fill` (shield active)
(`AppDelegate.swift:120-133`). The status line inside the menu (tag 100) shows
`Status: ✅ Owner detected` or `Status: ⚠️ Shield active`, and is set to the "safe" text
immediately at startup, before any detection has run (`AppDelegate.swift:44`).

Menu items (`rebuildMenu`, `AppDelegate.swift:62-118`):

| Menu item | Shortcut | Behavior | Code |
|---|---|---|---|
| Status (dynamic) | — | Safe / shield-active text | tag 100, updated in `updateMenuIcon` |
| Enroll My Face | ⌘E (menu-local) | Starts 8-sample enrollment with label `"owner"` | `AppDelegate.swift:137-147`, `FaceDetector.swift:181-186` |
| Add Trusted Face | — | Same, label `trusted_XXXX` (random 4 digits) | `AppDelegate.swift:149-159` |
| Reset All Enrollments | ⌘R (menu-local) | Clears in-memory prints and deletes `enrolled_faces.dat` | `AppDelegate.swift:161-164`, `FaceRecognizer.swift:72-77` |
| Calibrate Detection Range… | — | Range calibration flow (Section 4) | `AppDelegate.swift:170-190`, `FaceDetector.swift:188-193` |
| Current threshold label | — | `"Current threshold: N%"` or `"Current: default (2 ft)"` before first calibration | tag 300, `AppDelegate.swift:91-95` |
| Toggle Shield (⌘⇧L) | — | Manual shield toggle | `AppDelegate.swift:166-168` |
| Launch at Login | — | Checkmark toggle, `SMAppService` registration | `AppDelegate.swift:107-111, 222-248` |
| Quit Privacy Shield | ⌘Q | Standard terminate | `AppDelegate.swift:115` |

User feedback during these actions is a toast in the top-right of the main screen
(`PrivacyShield/Toast.swift`, window level `.statusBar`).

---

## 3. Global hotkey ⌘⇧L — `PrivacyShield/AppDelegate.swift:194-218`

- Registered via Carbon `RegisterEventHotKey` with signature `"PS_H"`,
  modifiers `cmdKey | shiftKey`, key code `kVK_ANSI_L` (lines 196-203).
- The handler calls `toggleShield()` → `ShieldManager.toggleShield()` directly
  (lines 212-217); it does **not** touch `FaceDetector`'s `isShieldActive` state.
- Interaction with the detector: manually hiding the shield while the detector believes the
  shield should be up will keep the screen clear until the detector sees 8 consecutive safe
  processed frames (see P-1).

---

## 4. Detection-range calibration flow

1. Menu → **Calibrate Detection Range…** shows a toast: "Stand at the distance you want to
   protect…", then waits 2 s so the user can position themselves
   (`AppDelegate.swift:170-190`).
2. `FaceDetector.startCalibration` clears samples and sets `isCalibrating`
   (`FaceDetector.swift:188-193`).
3. For every processed frame while calibrating, a `VNDetectFaceRectanglesRequest` runs and
   the first face's `boundingBox.width` is appended as a sample
   (`FaceDetector.swift:77-100`); the log line `Calibration sample N/10: face width = …`
   is printed per sample.
4. After 10 samples (`calibrationSampleCount = 10`, line 47) the **average** width is
   written to `UserDefaults` as `minFaceSize` (lines 87-95) and a success toast shows the
   new threshold percentage; the menu label (tag 300) is updated
   (`AppDelegate.swift:177-189`).
5. The 10 samples are collected back-to-back at processed-frame cadence (~10/s), i.e.
   effectively within ~1 s — there is no temporal spread, dedup, or outlier rejection
   (see P-3).

---

## 5. Notifications — `PrivacyShield/AppDelegate.swift:250-266`

- Permission is requested once at launch for `[.alert, .sound]` (lines 252-256).
- `sendStrangerNotification()` posts a `UNNotificationRequest`:
  title `⚠️ Privacy Shield`, body `"An unrecognized face was detected. Screen has been
  blurred."`, default sound (lines 258-266).
- Sent at most once per shield episode, gated by `hasNotifiedStranger`
  (`FaceDetector.swift:159-162`), which is only reset when the detector hides the shield
  (`FaceDetector.swift:171`).

---

## 6. Multi-display shield — `PrivacyShield/ShieldManager.swift`

- One borderless `NSWindow` per `NSScreen`, created lazily on first `showShield()`
  (lines 61-71; `rebuildWindows` lines 28-59).
- Window properties: level = screen-saver window level (line 43), transparent background
  with an `NSVisualEffectView` using the `.hudWindow` material / `.behindWindow` blending —
  a full-screen blur (lines 49-55); `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary]` so the overlay appears on every Space and over full-screen apps
  (line 47); the window **does** intercept mouse events (`ignoresMouseEvents = false`,
  line 46).
- Display configuration changes (connect/disconnect/resolution) rebuild all windows via
  `NSApplication.didChangeScreenParametersNotification` and re-show them if the shield is
  currently visible (lines 21-26).
- `hideShield` orders out all windows; `toggleShield` flips visibility (lines 73-88).

---

## 7. Lifecycle, persistence, and launch-at-login

- On launch (`AppDelegate.swift:19-31`): App Nap / automatic termination disabled and a
  `ProcessInfo.beginActivity` assertion with `.idleSystemSleepDisabled` is taken (so the
  Mac will not idle-sleep while the app runs); menu, hotkey, and notification permission
  are set up; the pipeline starts after a 1 s delay.
- Enrollment data persists in `~/Library/Application Support/PrivacyShield/enrolled_faces.dat`
  (`FaceRecognizer.swift:11-20`). `minFaceSize` and the `launchAtLogin` checkmark live in
  `UserDefaults.standard`.
- Launch at Login uses `SMAppService.mainApp.register()/unregister()` on macOS 13+
  (`AppDelegate.swift:234-248`); the menu checkmark reflects the app's own
  `UserDefaults` flag.

---

## 8. Manual Verification Protocol (M0-T02 checklist)

> **These checks require a human physically at the Mac** (with its camera, a second person,
> and a second display for several items). **An agent cannot automate them** — launching the
> app, granting camera permission, and appearing on camera are all manual, GUI-bound actions.
> Run them on the primary development Mac (see `docs/baseline_metrics.md` for machine info).
>
> Item V1 (build) was **verified by the orchestrator** — `xcodebuild` succeeded on this
> machine. All other items are pending manual execution.

### V1. Build with current Xcode
- [x] **Expected:** `PrivacyShield.xcodeproj` builds and links without errors.
- **How to verify:** `xcodebuild -project PrivacyShield.xcodeproj -scheme PrivacyShield build` (or ⌘R in Xcode). Do not use `swift build` — `Package.swift` is not wired to the sources (P-11).
- **Actual result:** VERIFIED — build performed by the orchestrator via `xcodebuild` on this machine (baseline green build).

### V2. Launch menu-bar app
- [ ] **Expected:** No dock icon and no window (menu-bar only). An `eye` icon appears in the menu bar; opening the menu shows `Status: ✅ Owner detected` (initial value, before any detection). Console logs `Camera auth status: …`, `Found camera: …`, `Capture session running: true` about 1 s after launch.
- **How to verify:** Launch from Xcode (⌘R) and watch the console; click the icon.
- **Actual result:** _(pending manual)_

### V3. Grant camera permission
- [ ] **Expected:** On first launch macOS shows the camera permission prompt with the text from `NSCameraUsageDescription`; after allowing, `Capture session running: true` is logged.
- **How to verify:** Fresh install / reset permission via `tccutil` or System Settings → Privacy & Security → Camera; relaunch and observe.
- **Actual result:** _(pending manual)_

### V4. Enroll owner
- [ ] **Expected:** Menu → Enroll My Face → toast "Look at the camera… Enrolling your face". With a face visible, logs `Enrollment [owner]: Captured sample 1/8 … 8/8` complete quickly (8 processed frames ≈ under a second at ~10 processed FPS), followed by the success toast and `Enrollment complete for 'owner'` / `Saved 1 enrolled users to disk`.
- **How to verify:** Watch Xcode console while enrolling; confirm `enrolled_faces.dat` exists in `~/Library/Application Support/PrivacyShield/`.
- **Actual result:** _(pending manual)_

### V5. Owner is accepted
- [ ] **Expected:** Owner alone at normal desk distance → screen never blurs, menu icon stays `eye`, status stays `Status: ✅ Owner detected`.
- **How to verify:** Sit at the desk for 1–2 minutes with the app monitoring.
- **Actual result:** _(pending manual)_

### V6. Unknown nearby face triggers shield
- [ ] **Expected:** A second person approaching close enough (normalized face width ≥ 0.8 × minFaceSize; ≥ 0.20 of frame width with defaults) for ≥ 3 consecutive processed frames (~0.3 s nominal) triggers: screen blurs on all displays, icon becomes `eye.slash.fill`, one notification fires.
- **How to verify:** Have a second person step up behind/next to the owner; observe blur and icon.
- **Actual result:** _(pending manual)_

### V7. Unknown face leaving removes shield
- [ ] **Expected:** After the stranger leaves the frame, ≥ 8 consecutive safe processed frames (~0.8 s nominal) remove the blur, icon returns to `eye`.
- **How to verify:** Second person walks away; time the release; confirm it is not instantaneous.
- **Note:** The owner walking away entirely also blurs the screen (`count == 0 → stranger`, `FaceDetector.swift:118-120`). This is by-design "owner absent" baseline behavior — record it as expected, not as a bug.
- **Actual result:** _(pending manual)_

### V8. Notification appears
- [ ] **Expected:** One macOS notification ("⚠️ Privacy Shield / An unrecognized face was detected. Screen has been blurred.") per shield episode — it must not repeat continuously while the shield stays up, and re-arms after the shield hides and triggers again.
- **How to verify:** Trigger the shield, keep the stranger present for ~30 s (expect exactly one notification), leave, re-trigger (expect a second notification). Requires notification permission granted (V3 path).
- **Actual result:** _(pending manual)_

### V9. Global hotkey ⌘⇧L toggles
- [ ] **Expected:** Pressing ⌘⇧L anywhere (any app, any Space) toggles the blur on/off; console logs `Global hotkey ⌘⇧L registered` at launch.
- **How to verify:** Focus another app, press ⌘⇧L twice; confirm blur appears then disappears.
- **Note:** Manually hiding while a stranger is still present disables auto re-blur until the detector completes a safe episode (P-1) — this is baseline behavior to be aware of, not a failure.
- **Actual result:** _(pending manual)_

### V10. Multi-display shield with a second display
- [ ] **Expected:** With a second display connected, the blur overlay covers **all** screens when the shield activates; connecting/disconnecting a display while the shield is visible rebuilds the windows and keeps the shield shown on the remaining/new set.
- **How to verify:** Connect a second display, trigger the shield, verify both screens blur; then unplug the second display while blurred and verify the state remains consistent.
- **Actual result:** _(pending manual)_ (requires a second display)

### V11. Detection-range calibration flow
- [ ] **Expected:** Menu shows `Current: default (2 ft)` before any calibration. Menu → Calibrate Detection Range… → instruction toast → after the 2 s positioning delay, logs `Calibration sample 1/10 … 10/10` (collected in ~1 s), success toast `✅ Calibrated! Threshold set to N%`, and the menu label changes to `Current threshold: N%`. The value persists across app restart.
- **How to verify:** Run calibration at a chosen distance; quit and relaunch; confirm the menu label shows the calibrated percentage.
- **Note:** A face must be visible during the ~1 s sampling window; if not, calibration silently never completes (P-3).
- **Actual result:** _(pending manual)_

### Acceptance cross-check (from `implement_todolist.md` M0-T02)
- [x] Baseline behavior is documented (this file).
- [x] Pre-existing bugs are recorded separately from new implementation issues (Section 9).

---

## 9. Pre-existing bugs / observations (from static code reading)

These exist at baseline and are recorded here so they are not later misattributed to new
implementation work. None of them have been fixed; none of them block the baseline.

**P-1 — Notification latch is only released by the detector's own hide path.**
`hasNotifiedStranger` is set when the shield first shows (`FaceDetector.swift:159-162`) and
reset only inside the safe-hide branch (`FaceDetector.swift:171`). Because the global hotkey
toggles `ShieldManager` directly without touching detector state (`AppDelegate.swift:212-217`,
`FaceDetector.swift:154` keeps `isShieldActive = true`), manually hiding the shield with ⌘⇧L
while a stranger is still present leaves the detector believing the shield is up: no re-blur
and no re-notification occur until the stranger leaves and 8 consecutive safe processed
frames complete.

**P-2 — Un-enrolled state silently treats a single nearby face as safe, and `isOwner`
defaults to "owner".**
With no enrollment, the detector blurs only when ≥ 2 nearby faces are seen
(`FaceDetector.swift:124-126`). Additionally `FaceRecognizer.isOwner` starts with
`guard isEnrolled else { return true }` (`FaceRecognizer.swift:82`), so any direct caller
treats every face as the owner when nothing is enrolled. If `enrolled_faces.dat` fails to
load (corrupt file → `loadPrints` catch, `FaceRecognizer.swift:204-206`), the app silently
degrades to this "one face is never a stranger" mode with no UI indication. Relevant again
in M1-T05, where `isOwner` will be called from a new integration path.

**P-3 — Calibration collects every processed frame with no dedup, spread, or failure path.**
All 10 calibration samples are appended back-to-back at processed-frame cadence
(`FaceDetector.swift:78-95`), i.e. within ~1 s — the "average" is effectively a single
instant measurement. There is no outlier rejection, and if no face is detected during
calibration the completion handler is never called (errors are swallowed at
`FaceDetector.swift:97`), so calibration can hang silently; the "❌ Calibration failed"
toast (`AppDelegate.swift:186`) is unreachable code.

**P-4 — Enrollment uses the first face in the frame and completes in under a second.**
`enrollFace(from:)` is invoked for every processed frame while enrolling
(`FaceDetector.swift:63-75`), and each sample crops the *first* detected face of the full
frame (`FaceRecognizer.swift:118-129`). With two people visible the wrong face can be
enrolled. The 8 samples complete in < 1 s at ~10 processed FPS despite the "look at the
camera" instruction, and there is no timeout: if no face is detected, enrollment never
completes and the "❌ Enrollment failed" toast (`AppDelegate.swift:144`) is unreachable.

**P-5 — Recognition runs uncached for every nearby face on every processed frame.**
The enrolled branch loops over all nearby faces and calls `isOwner` each time
(`FaceDetector.swift:127-135`); each call crops the face, creates a new `CIContext`
(`FaceRecognizer.swift:160`), runs `VNGenerateImageFeaturePrintRequest`, and computes
distances against all 8 prints of each enrolled user (`FaceRecognizer.swift:89-106`). With
two nearby faces this doubles Vision work per processed frame. (Baseline metric: see
`docs/baseline_metrics.md`; addressed by M2-T06.)

**P-6 — The `sensitivityThreshold` setting is dead code.**
`AppDelegate.sensitivityThreshold` reads/writes `UserDefaults` key `"matchThreshold"`
(`AppDelegate.swift:14-17`) but `FaceRecognizer.matchThreshold` is a hardcoded
`let = 0.75` (`FaceRecognizer.swift:9`); the setting has no effect anywhere.

**P-7 — The per-face "buffer zone" does not actually provide hysteresis.**
The same threshold `minFaceSize × 0.8` is applied on every frame regardless of prior state
(`FaceDetector.swift:114-115`); there is no separate enter/exit pair of thresholds, so a
face whose width oscillates around the boundary flips nearby/far frame-to-frame. Stability
comes solely from the global 3/8 frame counters.

**P-8 — Menu status claims "Owner detected" before any detection runs (and even when the
camera is denied).**
`updateMenuIcon(safe: true)` is called unconditionally at startup (`AppDelegate.swift:44`),
which sets the status text to `Status: ✅ Owner detected` (lines 129-131) even if camera
permission was denied (denied path only prints to console, `CameraManager.swift:36-37`) or
no camera exists.

**P-9 — `isProcessing` is accessed from two threads without synchronization.**
Set on the video queue (`FaceDetector.swift:61`) and cleared on the main queue
(`FaceDetector.swift:140`). Practically benign, but it is a data race; same applies to the
enrollment sample array appended on the video queue (lines 63-75).

**P-10 — Redundant icon/status updates on every safe processed frame.**
While safe and unshielded, `updateMenuIcon(safe: true)` runs at processed-frame rate
(~10/s), rebuilding `NSImage` lookups and menu text each time (`FaceDetector.swift:174-177`,
`AppDelegate.swift:120-133`).

**P-11 — `Package.swift` does not match the source layout.**
The SPM executable target points at `path: "Sources"` (`Package.swift:13`), but sources live
in `PrivacyShield/`; `swift build` fails at baseline. The Xcode project
(`PrivacyShield.xcodeproj`) is the working build.

**P-12 — Process activity assertion blocks system idle sleep and can never be released.**
`AppDelegate.swift:22` begins a `ProcessInfo` activity with `.idleSystemSleepDisabled` and
discards the returned token, so the Mac will not idle-sleep and the assertion cannot be
ended while the app runs. Intentional for monitoring, but a notable energy/battery behavior.

**P-13 — Shield overlay intercepts mouse events.**
Overlay windows set `ignoresMouseEvents = false` (`ShieldManager.swift:46`), so clicks land
on the blur window while the shield is up; the global hotkey still works. Possibly intended
(protection), recorded so it is not rediscovered.

**P-14 — Toasts are hidden behind the shield.**
Toast windows use level `.statusBar` (`Toast.swift:50`) while the shield uses the
screen-saver level (`ShieldManager.swift:43`); any toast shown while the shield is active is
obscured by the blur.

**P-15 — Launch-at-login checkmark can desync from the real login item.**
The checkmark reflects the app's own `UserDefaults` flag (`AppDelegate.swift:230-232`) while
the actual registration lives in `SMAppService`; toggling the login item from System
Settings leaves the menu state wrong.
