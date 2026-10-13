# Privacy Shield for macOS

A macOS menu-bar application that protects your screen automatically. It uses your Mac's camera and Apple's Vision framework to watch for privacy risks and **blurs all displays when needed** — and it now understands *attention*, not just presence:

- **Shoulder-surfing detection** — a person who is *not* you (and not enrolled as trusted) who looks **toward the screen** for a sustained period triggers the shield, even while you are sitting there. A person merely present in the room does not.
- **Owner/trusted faces never trigger the shoulder-surf path** — enrolled faces (owner + trusted) are exempt from the "someone is watching" rule; only strangers can raise it.
- **Multiple people tracked independently** — every visible person gets their own stable track with their own attention timer, so two bystanders never share or dilute each other's looking time and the shield stays up until the *last* watcher looks away.
- **Owner-away protection** — when you leave, the screen blurs (roughly 1–1.5 s later), regardless of whether anyone else is in frame.

All processing is **local on-device**. No images or video ever leave the Mac. See [Privacy Statement](#privacy-statement).

## Features

| Feature | Description |
|---------|-------------|
| 🔍 **Face Detection** | Continuous monitoring via the webcam using Apple's `Vision` framework (`VNDetectFaceRectanglesRequest`) |
| 🎥 **1080p Capture** | Prefers a 1920×1080 @ 30 FPS camera format; falls back to 1080p @ 15 FPS or the highest stable supported format (capped at 30 FPS) |
| 🧭 **Head Pose** | Yaw/pitch/roll extracted per face from Vision observations (degrees, with an explicit "unavailable" state — missing pose is never faked as frontal) |
| 👤 **Face Enrollment** | Register your face (and trusted faces) so only strangers trigger the shoulder-surf blur |
| 🗂️ **Recognition Caching** | Identities are re-checked on a per-state cadence (owner/trusted ≈ every 2.5 s, strangers ≈ every 1.5 s) plus early triggers (big position jump, large size change, reappearance after a gap) — not on every frame |
| 📏 **Distance Bands** | Normalized face width maps each person to near / mid / far (≈1–2 m / 2–3 m / 3–4 m) with hysteresis, so tolerances and trigger durations adapt to distance |
| 🎯 **Attention Classifier** | Rule-based weighted yaw/pitch/roll score against your **calibrated screen center**, with a hysteresis band between "looking" and "not looking" |
| ⏱️ **Per-Person Temporal Filters** | Wall-clock sustained-looking trigger (~0.9 s) and release (~0.6 s) at the Balanced preset, adapted per distance band; a single frame can never trigger the shield |
| 🔒 **Two Independent Policies** | "Owner away" and "someone is watching" are decided independently — you can enable either, both, or neither |
| 💻 **Multi-Display Blur** | Fullscreen blur overlay across all connected displays |
| 🔔 **Reason-Aware Notifications** | The notification tells you *why*: observer detected, owner away, or both — at most one per shield episode |
| ⌨️ **Global Hotkey** | Press `⌘⇧L` anywhere to manually toggle the blur |
| 🚀 **Launch at Login** | Optional auto-start via `SMAppService` |
| 🎛️ **Settings UI** | Sensitivity presets, per-look-duration override, blur toggles, calibration — all persisted and live-applied |
| 🛠️ **Debug Tooling** | Optional on-screen debug preview (per-face pose/attention overlay) and structured pipe-separated debug logs |
| 📊 **Status Indicator** | Menu-bar icon flips between `eye` (safe) and `eye.slash.fill` (shield active); the menu status line names the state and reason |

## How It Works

```
Camera (1080p preferred, every 3rd frame processed)
  → Vision face detection (VNDetectFaceRectanglesRequest)
  → face-size / distance bands (near / mid / far from normalized face width, with hysteresis)
  → recognition, cached per person (owner / trusted / other / unknown)
  → head pose (yaw / pitch / roll in degrees)
  → attention classifier (weighted pose score vs. calibrated screen center)
  → per-person temporal filters (~0.9 s trigger, ~0.6 s release at Balanced, band-adaptive)
  → independent policies: owner-away vs. shoulder-surf
  → blur shield + reason-aware notification + status line
```

Key behaviors:

- Every person in frame keeps a **stable track** (UUID) with their own identity, pose, attention score and timer. Faces too small to judge reliably (beyond ~4 m or spurious detections) stay `uncertain` and **can never trigger** the shoulder-surf shield.
- The shield shows while any qualifying (non-owner/trusted) person's filter is alerting, or while no owner/trusted face has been seen recently — the two rules are evaluated independently.
- Recognition runs on a cache policy, not per frame: owner/trusted revalidate every ~2.5 s, strangers every ~1.5 s, with immediate re-checks after large position/size changes or a reappearance.

## Requirements

- macOS 13 Ventura or newer (required for Launch-at-Login via `SMAppService`; all behavior targets macOS 13+)
- A Mac with a built-in or external webcam (Apple Silicon recommended; performance targets assume a modern Apple Silicon Mac)
- Xcode 15+ (for building from source)

## Build and Run

1. **Clone the repository**
   ```bash
   git clone https://github.com/GitGuru29/PrivacyShieldMac.git
   cd PrivacyShieldMac
   ```

2. **Open in Xcode**
   ```bash
   open PrivacyShield.xcodeproj
   ```

3. **Build & Run** — press `⌘R` (the app installs itself as a menu-bar item; there is no dock window).

4. **Grant camera access** — click OK when macOS prompts, or enable it later in **System Settings > Privacy & Security > Camera**.

5. **Enroll yourself** — click the eye icon in the menu bar → **Enroll My Face** and look at the camera for a couple of seconds (the app captures 8 samples). Enrollment is required: without it the app cannot tell you from a stranger.

### Unit tests

The pure-logic modules (classifier, temporal filters, tracker, cache policy, bands, presets, state machine, calibration, debug formatting) are also compiled as a Swift package library so they can be tested without a camera or UI:

```bash
swift test     # runs 205+ unit tests
```

The GUI app itself builds from the Xcode project (`PrivacyShield.xcodeproj`); the SPM package (`Package.swift`, target `PrivacyShieldCore`) exists for the test harness only.

## Operating Range

The system is designed and evaluated for the **1–4 m** range in front of the display.

Each face's normalized bounding-box width (a practical distance proxy for a fixed camera) is classified into a distance band with hysteresis so bands do not flicker:

| Band | Approx. distance | Default width range | Attention tolerances (Balanced) | Trigger duration |
|------|------------------|---------------------|--------------------------------|------------------|
| near | ~1–2 m | width > 0.28 | yaw ±18°, pitch ±15° | 0.7 s |
| mid  | ~2–3 m | 0.16 < width ≤ 0.28 | yaw ±22°, pitch ±18° | 0.9 s |
| far  | ~3–4 m | 0.09 < width ≤ 0.16 | yaw ±27°, pitch ±22° | 1.2 s |
| too far / unreliable | beyond ~4 m | width ≤ 0.09 | — (stays uncertain) | never triggers |

Farther faces get looser angular tolerances (pose readings are noisier at distance and a distant observer must turn further to read a screen) and longer trigger durations (more evidence demanded). Release duration (0.6 s), roll tolerance (±30°), axis weights and thresholds are shared across bands.

Boundaries are **camera-dependent** (focal length, sensor crop and resolution all shift the width at a given distance) — see [Known Limitations](#known-limitations). Use **Calibrate Detection Range…** to set the minimum face size for the *presence* gate at your actual seating distance.

## Calibration

Both calibrations live in the menu-bar menu and persist across launches.

### Calibrate Screen Direction…

Teaches the app where your screen is in head-pose space, so "looking at the screen" is measured relative to *your* normal posture and camera placement instead of a hard-coded frontal pose.

1. Click **Calibrate Screen Direction…**
2. Sit in your normal working position and look at the **center of the screen**.
3. Keep still for **~3 seconds** while samples are collected (a short lead-in lets you settle first).

The calibrated center (median yaw/pitch after outlier rejection) is saved to UserDefaults (`screenCenterYaw` / `screenCenterPitch`) and applied to every subsequent attention evaluation. Recalibrate whenever you move the camera or change your seating position. Until calibrated, a 0°/0° frontal assumption is used.

### Calibrate Detection Range…

Sets the minimum face size (as a % of frame width) that counts as "close enough to matter" for the presence-side gate:

1. Click **Calibrate Detection Range…**
2. Stand or sit at the distance you want to protect and look at the camera for ~3 seconds.

The measured size becomes the threshold; anyone closer than your calibrated position will trigger the shield. The current threshold is shown in the menu ("Current threshold: N%").

## Settings & Sensitivity Presets

Open the menu-bar menu to configure everything. Changes apply immediately and persist.

### Sensitivity presets

Presets re-map the classifier tolerances and trigger durations coherently across all three distance bands (the table shows each preset's mid-band headline values — the same values the menu logic uses). Roll tolerance (±30°), axis weights (yaw 0.60 / pitch 0.35 / roll 0.05), looking thresholds and the calibrated screen center are never touched by a preset.

| Preset | Yaw tolerance | Pitch tolerance | Trigger duration | Release | Behavior |
|--------|--------------|-----------------|------------------|---------|----------|
| **Conservative** | ±15° | ±12° | 1.5 s | 0.8 s | Fewer false triggers: only clearly screen-facing heads count, and they must hold longer |
| **Balanced** (default) | ±22° | ±18° | 0.9 s | 0.6 s | The M3-tuned defaults |
| **Sensitive** | ±30° | ±25° | 0.6 s | 0.6 s | Triggers more readily: wider angles accepted, shorter hold required |

Per-band adaptation stays intact under every preset (near stays strictest/fastest, far loosest/slowest):

| Preset | near (yaw / pitch / trigger) | mid | far |
|--------|------------------------------|-----|-----|
| Conservative | 11° / 9° / 1.3 s | 15° / 12° / 1.5 s | 20° / 16° / 1.8 s |
| Balanced | 18° / 15° / 0.7 s | 22° / 18° / 0.9 s | 27° / 22° / 1.2 s |
| Sensitive | 26° / 22° / 0.55 s | 30° / 25° / 0.6 s | 35° / 29° / 0.9 s |

### User overrides

- **Looking Duration** — override the trigger duration (`Band Default`, 0.5 s, 0.8 s, 1.0 s, 1.5 s). A non-nil override wins over both the preset and the band adaptation.
- **Blur toggles** — `Shoulder Surf Detection` (master switch), `Blur When I Leave`, `Blur When Someone Watches`.

### Full menu structure

```
Status: ✅ Monitoring safe            (or 👀 Observer detected / 🚪 Owner away /
                                       ⚠️ Owner away + observer / 🎯 Calibrating… /
                                       📷 Camera unavailable)
─────────────────────────────
Shoulder Surf Detection              ✓ toggle
Blur When I Leave                    ✓ toggle
Blur When Someone Watches            ✓ toggle
─────────────────────────────
Attention Sensitivity            ▸   Conservative / Balanced / Sensitive
Looking Duration                 ▸   Band Default / 0.5 s / 0.8 s / 1.0 s / 1.5 s
─────────────────────────────
Calibrate Screen Direction…
Calibrate Detection Range…
Current threshold: N%                 (informational)
[Screen center: yaw …, pitch …]       (only while debug logging is enabled)
Debug Preview…                        ✓ toggle
─────────────────────────────
Enroll My Face                    ⌘E
Add Trusted Face
Reset All Enrollments             ⌘R
─────────────────────────────
Toggle Shield (⌘⇧L)
─────────────────────────────
Launch at Login                       ✓ toggle
─────────────────────────────
Quit Privacy Shield               ⌘Q
```

Notifications are episode-gated: the first blur of an episode notifies with the reason ("Someone appears to be looking at your screen…", "You stepped away…", or both); a reason change within the same episode notifies at most every 10 s, and returning to safe resets the cycle.

## Privacy Statement

**All processing is local, on your Mac.**

- Face detection, head-pose extraction and face recognition run through Apple's **Vision framework on-device**. There is no cloud inference, no network call, and no telemetry.
- **No images or video ever leave the Mac.** Camera frames are held in memory only for processing; nothing is recorded, saved or transmitted.
- Enrolled **face prints** (Vision feature-print observations, up to 8 samples per person — not images) are stored **locally** in `~/Library/Application Support/PrivacyShield/enrolled_faces.dat`.
- Settings, calibration values (screen center, detection-range threshold) and toggles are stored locally in **UserDefaults** (the `attention.*` keys, `minFaceSize`, `matchThreshold`, `screenCenterYaw`/`screenCenterPitch`, `launchAtLogin`, plus the debug flags).
- The camera is used continuously only while the app runs; App Nap is deliberately disabled so monitoring survives in the background. Remove the menu-bar app (Quit) to stop all camera use.

## Known Limitations

- **Head pose is not eye-gaze estimation.** The attention signal comes from head yaw/pitch/roll only. A person with a **frontal head but sideways eyes** (reading over your shoulder without turning their head) can be missed. This is an accepted V1 limitation; an optional eye-gaze refinement for ~1–2 m is sketched as V2 in the development plan (Section 22) and deliberately not included, so a gaze-model failure can never disable privacy protection.
- **Band boundaries are camera-dependent.** The normalized face-width thresholds (near/mid/far) are calibrated against one camera's field of view; a Continuity Camera and a built-in FaceTime HD camera do not produce identical widths at the same distance. Expect to recalibrate when switching cameras.
- **Physical performance targets are pending manual validation.** The V1 acceptance targets (owner false-trigger < 0.5 %, passer-by false-trigger < 2 %, 1–3 m recall > 95 %, 4 m recall > 85 %, trigger latency ~0.8–1.3 s, release ~0.5–0.8 s, background CPU < 15 % on Apple Silicon) are engineering goals, not guarantees, until the full manual evaluation matrix is executed — see `docs/performance_report.md` and the regression protocols below.
- **Multi-person edge cases** (two strangers, person in the background, tracks crossing, identity flips after occlusion) are documented as a manual regression protocol in `docs/m2_multi_person_results.md`; results are pending human execution at the Mac.
- Head-pose sign conventions follow the Vision SDK and are validated via the M1 sanity protocol; a systematic inversion on any axis would require a documented flip, never a silent one (see `docs/m1_head_pose_results.md`).
- The debug preview shows the **main screen** only and is a diagnostic aid; it never influences detection decisions.

## Troubleshooting

| Symptom | What to do |
|---------|------------|
| **Camera never starts / "📷 Camera unavailable"** | Check **System Settings > Privacy & Security > Camera** — the app must be allowed. Quit and relaunch after changing the permission. |
| **Stranger looking at the screen does not trigger** | 1) **Enroll first** — the shoulder-surf path needs recognition to separate owner/trusted from others. 2) Check the distance/band (enable the Debug Preview; a face shown as `too_far` never triggers — move closer or widen the band boundaries to your camera). 3) **Recalibrate Screen Direction…** — if the stored center is off, "looking" scores stay low. 4) Make sure `Shoulder Surf Detection` and `Blur When Someone Watches` are both checked. 5) Try the **Sensitive** preset or a shorter **Looking Duration**. |
| **False triggers while you work** | Switch to the **Conservative** preset and/or increase **Looking Duration** (e.g. 1.5 s). Recalibrate Screen Direction in your true working posture; recalibrate after moving the camera. Remember enrolled owner/trusted faces never trigger the shoulder-surf path — re-enroll if recognition is failing. |
| **Nothing happens at all** | Open the menu: the status line tells you the state (`Calibrating…`, `Camera unavailable`, …). Verify the camera works in another app. Check that at least one blur toggle is enabled. |
| **Debug preview** | Toggle **Debug Preview…** in the menu. The overlay shows per-face track ID, identity, face width + band, yaw/pitch/roll, attention score/state and looking duration, plus global FPS/latency/tracks/format and the calibrated screen center. It never steals keyboard focus and clicks pass through. |
| **Want to see what the pipeline sees (logs)** | Enable debug logging from Terminal (see below), then read the log events. |
| **Hotkey `⌘⇧L` not working** | Another app may have claimed the same global hotkey (registration then fails at launch). Quit suspected apps and relaunch Privacy Shield, or use **Toggle Shield (⌘⇧L)** directly in the menu. |
| **Screen blurred when you are present** | That is the owner-away rule firing because no owner/trusted face was seen within the presence window — re-enroll (**Enroll My Face**) or lower the detection-range threshold (**Calibrate Detection Range…** at your real distance). |
| **Reset everything** | **Reset All Enrollments** wipes all saved face data (owner + trusted). Calibration values and settings persist in UserDefaults until recalibrated/changed. |

### Enabling debug logging

Debug logging is off by default and stored in the standard UserDefaults key `debugLoggingEnabled` of the app's bundle domain (`com.siluna.PrivacyShield`). Enable it from Terminal:

```bash
defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool true
# … run the app (or let it run: the flag is also read live per event, and the
#    capture-metrics line picks the change up within ~5 s), collect output …
defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool false
```

Structured, pipe-separated one-line events then appear on stdout — capture them via the Xcode console or Console.app:

- `track` — one per processed track per frame: identity, face width, bbox, yaw/pitch/roll, attention score/state, looking duration, band
- `recognition` — per recognition-caching decision (`recognize_now` / `cached`) with the reason
- `alert_on` / `alert_off` — per-track temporal-filter transitions
- `band_change` — per-track distance-band changes
- `screen_calibration_on` / `screen_calibration_off`, `legacy_shield_on` / `legacy_shield_off`
- `metrics` — periodic throughput/latency summary (~every 2 s)

With debug logging enabled, the menu additionally shows the currently stored screen center ("Screen center: yaw …, pitch …").

## Where to Find More

All under [`docs/`](docs/):

| Document | Contents |
|----------|----------|
| [`DEVELOPMENT_PLAN_with_fork.md`](docs/DEVELOPMENT_PLAN_with_fork.md) | Full development plan: phases, presets, 1–4 m evaluation matrix, V1 acceptance targets (§18), optional V2 eye-gaze refinement (§22) |
| [`implement_todolist.md`](docs/implement_todolist.md) | Task-by-task todolist and milestone exit criteria (M0–M4) |
| [`evaluation_protocol_1_4m.md`](docs/evaluation_protocol_1_4m.md) | 1–4 m evaluation protocol and harness (M3-T05) |
| [`m3_tuning_report.md`](docs/m3_tuning_report.md) | M3 threshold tuning pass: the values behind the presets and band profiles (M3-T06) |
| [`m1_head_pose_results.md`](docs/m1_head_pose_results.md) | M1 head-pose regression matrix and sign-convention sanity checks |
| [`m2_multi_person_results.md`](docs/m2_multi_person_results.md) | M2 multi-person regression matrix (protocol + results template) |
| [`performance_report.md`](docs/performance_report.md) | Measured throughput/latency and CPU numbers (M3-T07) |
| [`baseline_behavior.md`](docs/baseline_behavior.md) / [`baseline_metrics.md`](docs/baseline_metrics.md) | Pre-change baseline of the original app |
| [`evaluation_results.csv`](docs/evaluation_results.csv) | Raw evaluation data |

## Architecture

```
PrivacyShieldApp.swift            →  SwiftUI entry point (menu bar only, no window)
AppDelegate.swift                 →  Menu, global hotkey, reason-aware notifications,
                                     launch-at-login, status line
CameraManager.swift               →  AVCaptureSession, 1080p format selection, capture metrics
FaceDetector.swift                →  Pipeline orchestration: detection → tracking → cached
                                     recognition → pose → attention → per-band policy →
                                     privacy state machine (+ ShoulderSurfAggregator)
FaceRecognizer.swift              →  VNGenerateImageFeaturePrintObservation enrollment + matching
FaceTracker.swift                 →  Greedy IoU/center/size multi-face tracker (stable UUIDs)
HeadPoseEstimator.swift           →  Vision yaw/pitch/roll → degrees (all-or-nothing validity)
AttentionState.swift              →  Attention state/result types
AttentionClassifier.swift         →  Rule-based weighted pose classifier with hysteresis band
AttentionTiming.swift             →  Per-person temporal filter (trigger/release/uncertain grace)
RecognitionCachePolicy.swift      →  When to re-run recognition (cadence + early triggers + owner hysteresis)
DistanceBands.swift               →  Face width → near/mid/far bands with hysteresis
ScreenDirectionCalibration.swift  →  Screen-center calibration collector (median/MAD) + persistence
AdaptiveAttentionPolicy.swift     →  Per-band classifier/timing profiles
PrivacyStateMachine.swift         →  Independent owner-away vs. shoulder-surf decision core,
                                     shield reason + display states
AttentionSettings.swift           →  Settings model, sensitivity presets, persistence (attention.* keys)
DebugPreview.swift                →  Optional debug overlay window (pure sink)
DiagnosticsLog.swift              →  Structured debug logging (gated by debugLoggingEnabled)
ShieldManager.swift               →  Fullscreen NSVisualEffectView blur across all displays
Toast.swift                       →  Lightweight toast notifications
```
