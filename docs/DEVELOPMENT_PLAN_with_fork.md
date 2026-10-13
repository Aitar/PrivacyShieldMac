# PrivacyShieldMac 1–4 m Head-Pose Attention Detection Development Plan


# 0. Fork 仓库与本地开发准备

本项目以原始仓库：

```text
https://github.com/GitGuru29/PrivacyShieldMac
```

为上游（upstream）。

建议先将其 Fork 到自己的 GitHub 账号：

```text
Aitar/PrivacyShieldMac
```

## 0.1 在 GitHub 上 Fork

打开原始仓库：

```text
https://github.com/GitGuru29/PrivacyShieldMac
```

点击右上角 **Fork**，目标账号选择：

```text
Aitar
```

Fork 完成后，你自己的仓库地址应为：

```text
https://github.com/Aitar/PrivacyShieldMac
```

## 0.2 Clone 自己的 Fork

```bash
git clone https://github.com/Aitar/PrivacyShieldMac.git
cd PrivacyShieldMac
```

确认当前 remote：

```bash
git remote -v
```

预期：

```text
origin  https://github.com/Aitar/PrivacyShieldMac.git
```

## 0.3 添加原始仓库为 upstream

为了后续同步原项目更新：

```bash
git remote add upstream https://github.com/GitGuru29/PrivacyShieldMac.git
```

确认：

```bash
git remote -v
```

应同时看到：

```text
origin    https://github.com/Aitar/PrivacyShieldMac.git
upstream  https://github.com/GitGuru29/PrivacyShieldMac.git
```

## 0.4 创建开发分支

Head Pose / Attention 功能统一在独立分支开发：

```bash
git checkout -b feature/head-pose-attention
```

推送并建立远端 tracking：

```bash
git push -u origin feature/head-pose-attention
```

后续开发默认都在：

```text
feature/head-pose-attention
```

进行。

## 0.5 同步 upstream 的推荐方式

原仓库后续有更新时：

```bash
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```

然后把更新同步到开发分支：

```bash
git checkout feature/head-pose-attention
git rebase main
```

如果希望避免 rebase，也可以：

```bash
git merge main
```

## 0.6 首次本地验证

Fork 后先不要改代码，先确认原项目可以正常运行：

```bash
open PrivacyShield.xcodeproj
```

在 Xcode 中：

1. 选择本机作为运行目标。
2. `⌘R` Build & Run。
3. 授予摄像头权限。
4. 完成 `Enroll My Face`。
5. 验证本人不会触发 Shield。
6. 验证陌生人进入画面时会触发 Shield。
7. 验证菜单栏、通知和 Blur Overlay 正常。

只有 baseline 正常后，再开始 Head Pose / Attention 功能开发。

---

## 1. Goal

Extend `PrivacyShieldMac` from a simple “unknown nearby face” detector into a shoulder-surfing detector that triggers only when a **non-owner / non-trusted person** appears to be looking toward the user’s screen for a sustained period.

Target operating range: **1–4 meters**.

Primary V1 goals:

- Native macOS implementation.
- Keep the existing owner/trusted-face enrollment workflow.
- Ignore the enrolled owner completely as a shoulder-surfer trigger source.
- Support multiple visible people.
- Use Apple Vision head pose (`yaw`, `pitch`, `roll`) as the primary attention signal.
- Add per-person temporal filtering to reduce false alarms from passers-by and brief glances.
- Prefer 1080p capture; allow higher-resolution external cameras as an optional enhancement.
- Keep all processing local.
- Do **not** require eye-gaze estimation for V1.

Non-goals for V1:

- Exact gaze-point estimation.
- Iris/pupil tracking.
- L2CS / PyTorch / ONNX dependencies.
- DeepSORT-style tracking.
- Cloud inference.

---

## 2. Existing Baseline

Current high-level pipeline:

```text
AVCaptureSession
    ↓
CameraManager
    ↓
CVPixelBuffer
    ↓
FaceDetector
    ↓
VNDetectFaceRectanglesRequest
    ↓
Face-size filtering
    ↓
FaceRecognizer
    ↓
Owner / Stranger
    ↓
Global frame hysteresis
    ↓
ShieldManager
```

Target pipeline:

```text
Camera
  ↓
Face Detection
  ↓
Per-face filtering
  ├── Distance / face-size eligibility
  ├── Identity recognition
  │     ├── SELF / TRUSTED → ignore
  │     └── OTHER
  │          ↓
  │       Head Pose
  │          ↓
  │       Attention Score
  │          ↓
  │       Per-face Track
  │          ↓
  │       Temporal Filter
  │          ↓
  └── sustained shoulder-surfing?
             ↓
         ShieldManager
```

---

## 3. Recommended Branch

Create a development branch:

```text
feature/head-pose-attention
```

Suggested first commit:

```text
docs: add 1-4m head-pose attention detection plan
```

---

## 4. Phase 0 — Baseline Validation

Before changing behavior, verify the current project works unchanged.

Checklist:

- [ ] Project builds with current Xcode.
- [ ] Camera permission flow works.
- [ ] Menu-bar app launches correctly.
- [ ] `Enroll My Face` works.
- [ ] Owner is recognized reliably at normal desk distance.
- [ ] Unknown nearby face triggers shield.
- [ ] Calibration flow works.
- [ ] Multi-display shield works.
- [ ] Notifications work.

Record baseline metrics:

- Camera capture resolution.
- Capture FPS.
- Vision processing FPS.
- Average CPU usage.
- Face-detection latency.
- Face-recognition latency.

---

## 5. Phase 1 — Upgrade Camera Capture for 1–4 m

### Problem

The current implementation uses:

```swift
session.sessionPreset = .medium
```

This is unnecessarily restrictive for 1–4 m head-pose detection.

### Target

Prefer:

```text
1920×1080 @ 30 FPS
```

If a compatible external camera supports higher resolution, allow it as an optional mode.

Priority:

```text
1080p @ 30 FPS
    ↓ fallback
1080p @ 15 FPS
    ↓ fallback
highest stable supported format
```

Do not require 4K for V1.

### Processing cadence

Capture can remain at 30 FPS while Vision inference is throttled:

```text
Capture:       30 FPS
Face detect:    8–12 FPS
Recognition:    1–3 FPS per track
```

### Files

Modify:

```text
PrivacyShield/CameraManager.swift
```

### Acceptance criteria

- [ ] App captures at 1080p when the built-in camera supports it.
- [ ] Capture remains stable in background operation.
- [ ] Vision processing does not attempt to process all 30 frames/sec.

---

## 6. Phase 2 — Add Head Pose Extraction

Add:

```text
PrivacyShield/HeadPoseEstimator.swift
```

Suggested model:

```swift
struct HeadPose {
    let yaw: Double
    let pitch: Double
    let roll: Double
    let confidence: Double
}
```

Use `VNFaceObservation` head-pose data.

Normalize all values to degrees:

```swift
let degrees = radians * 180.0 / .pi
```

Do not coerce unavailable pose data into `0°`.

Use an explicit invalid / uncertain result when pose is unavailable or unreliable.

Suggested API:

```swift
enum HeadPoseResult {
    case valid(HeadPose)
    case unavailable
}
```

### Acceptance criteria

- [ ] Debug logs show yaw / pitch / roll for every usable face.
- [ ] Turning left/right changes yaw in the expected direction.
- [ ] Looking up/down changes pitch consistently.
- [ ] Missing pose data is represented as unavailable, not zero.

---

## 7. Phase 3 — Add Attention Classifier

Add:

```text
PrivacyShield/AttentionClassifier.swift
PrivacyShield/AttentionState.swift
```

Suggested state:

```swift
enum AttentionState {
    case looking
    case notLooking
    case uncertain
}
```

Suggested output:

```swift
struct AttentionResult {
    let state: AttentionState
    let score: Double
}
```

### Initial rule-based V1

Use calibrated screen-center orientation:

```text
screenCenterYaw
screenCenterPitch
```

Compute angular error:

```text
yawError   = abs(yaw   - screenCenterYaw)
pitchError = abs(pitch - screenCenterPitch)
```

Initial balanced thresholds:

```text
yaw tolerance:   ±22°
pitch tolerance: ±18°
roll tolerance:  ±30°
```

These are starting values only and must be tuned using 1–4 m tests.

### Suggested score

```text
yawScore   = angle score in [0, 1]
pitchScore = angle score in [0, 1]
rollScore  = angle score in [0, 1]

attentionScore =
    0.60 × yawScore +
    0.35 × pitchScore +
    0.05 × rollScore
```

Suggested hysteresis:

```text
score >= 0.70 → looking
score <= 0.45 → notLooking
otherwise     → uncertain
```

### Acceptance criteria

- [ ] A frontal head pose produces high attention score.
- [ ] Clearly side-facing poses produce low attention score.
- [ ] Borderline poses remain uncertain rather than flickering between states.

---

## 8. Phase 4 — Screen Direction Calibration

Add a dedicated menu action:

```text
Calibrate Screen Direction…
```

This is different from the existing face-size / range calibration.

### Calibration flow

```text
User starts calibration
    ↓
User sits in normal working position
    ↓
Looks at screen center for ~2–3 seconds
    ↓
Collect N valid yaw/pitch samples
    ↓
Reject outliers
    ↓
Use median yaw and pitch
    ↓
Persist values in UserDefaults
```

Persist:

```text
screenCenterYaw
screenCenterPitch
```

Use median instead of mean to reduce sensitivity to transient pose errors.

### Acceptance criteria

- [ ] Calibration completes only with enough valid samples.
- [ ] Saved center survives app restart.
- [ ] Recalibration replaces old values.

---

## 9. Phase 5 — Owner / Stranger Split

Modify:

```text
PrivacyShield/FaceDetector.swift
```

Existing behavior conceptually does:

```text
nearby face
    ↓
recognized owner?
  yes → safe
  no  → stranger detected
```

Replace with:

```text
face
  ↓
within usable range?
  ↓
recognized owner/trusted?
  ├── YES → ignore for shoulder-surf detection
  └── NO
       ↓
     head pose
       ↓
     attention
       ↓
     temporal tracking
```

### Owner rule

An enrolled owner/trusted user must never trigger shoulder-surf detection regardless of head pose.

### Acceptance criteria

- [ ] Owner looking at screen does not trigger.
- [ ] Owner looking at camera does not trigger.
- [ ] Owner looking away does not trigger shoulder-surf logic.
- [ ] Unknown user is evaluated by head pose.

---

## 10. Phase 6 — Add Lightweight Multi-Face Tracking

Add:

```text
PrivacyShield/FaceTracker.swift
```

V1 does not need DeepSORT.

Associate detections across nearby frames using:

- bounding-box IoU;
- center distance;
- face-size similarity.

Suggested track state:

```swift
struct FaceTrack {
    let id: UUID
    var boundingBox: CGRect
    var identity: IdentityState
    var attentionScore: Double
    var attentionState: AttentionState
    var lookingSince: Date?
    var lastSeen: Date
    var lastIdentityCheck: Date?
}
```

Suggested identity state:

```swift
enum IdentityState {
    case owner
    case trusted
    case other
    case unknown
}
```

### Acceptance criteria

- [ ] Two people receive separate track IDs.
- [ ] Track IDs remain stable under small movement.
- [ ] Each person has an independent looking duration.
- [ ] A brief missed detection does not immediately destroy a track.

---

## 11. Phase 7 — Replace Frame Counters with Time-Based Filtering

Current global frame hysteresis is useful, but the new detector should use real elapsed time per person.

Recommended initial thresholds:

```text
Trigger duration: 0.8–1.0 s
Release duration: 0.5–0.8 s
```

State machine:

```text
SAFE
 │
 │ non-owner begins looking
 ▼
PENDING
 │
 │ sustained for triggerDuration
 ▼
ALERT
 │
 │ no qualifying observer for releaseDuration
 ▼
SAFE
```

Do not trigger from one frame.

Do not use a global timer shared by multiple people.

### Acceptance criteria

- [ ] < 0.5 s glance normally does not trigger.
- [ ] Sustained ~1 s attention triggers.
- [ ] Different people do not accumulate each other’s attention time.

---

## 12. Phase 8 — Distance / Face-Size Confidence Bands

The 1–4 m target allows a simpler and more reliable confidence model than 3–5 m.

Use normalized face width as a practical distance proxy.

Define three bands after empirical calibration:

```text
Near:   approximately 1–2 m
Mid:    approximately 2–3 m
Far:    approximately 3–4 m
```

The exact normalized widths must be measured per camera.

Suggested behavior:

```text
Near
  → tighter angle threshold
  → shorter temporal threshold

Mid
  → balanced defaults

Far
  → slightly wider angle threshold
  → longer temporal threshold
```

Initial test profile:

```text
Near:
  yaw ±18°
  pitch ±15°
  duration 0.7 s

Mid:
  yaw ±22°
  pitch ±18°
  duration 0.9 s

Far:
  yaw ±27°
  pitch ±22°
  duration 1.2 s
```

These numbers are starting points, not final constants.

### Important

Do not keep the existing default `minFaceSize = 0.25` as the final 1–4 m threshold without calibration; it is likely too restrictive for the new range.

---

## 13. Phase 9 — Recognition Caching

Do not run expensive face feature extraction on every processed frame.

Recommended strategy:

```text
new track
   ↓
recognize once
   ↓
cache identity
   ↓
periodic revalidation
```

Suggested revalidation cadence:

```text
owner/trusted: every 2–3 s
other:         every 1–2 s
```

Re-run sooner if:

- track geometry changes substantially;
- face disappears and reappears;
- face crop quality improves significantly.

### Acceptance criteria

- [ ] CPU usage drops relative to per-frame recognition.
- [ ] Owner identity remains reliable during normal head motion.

---

## 14. Phase 10 — Separate “Owner Absent” from “Shoulder Surfer”

Current logic treats no face as a stranger-like unsafe state.

Split this into two independent signals:

```swift
struct PrivacyState {
    var ownerPresent: Bool
    var shoulderSurferDetected: Bool
}
```

Expose separate settings:

```text
[x] Blur when I leave
[x] Blur when someone watches my screen
```

Recommended behavior:

```text
Owner absent
  → optional auto blur

Unknown person present but not looking
  → no shoulder-surf blur

Unknown person looking long enough
  → shoulder-surf blur
```

---

## 15. Phase 11 — Debug View

A debug mode is mandatory for tuning the 1–4 m range.

Add a camera preview overlay showing, per face:

```text
track ID
identity
face width
head yaw
head pitch
head roll
attention score
attention state
continuous looking duration
```

Example:

```text
┌─────────────────────────────────┐
│                                 │
│      ┌──────────────┐           │
│      │ Track #2     │           │
│      │ OTHER        │           │
│      │ yaw:   +6°   │           │
│      │ pitch: -5°   │           │
│      │ score: .88   │           │
│      │ LOOKING      │           │
│      │ t: 0.72 s    │           │
│      └──────────────┘           │
│                                 │
│ SELF #1 — ignored               │
│                                 │
└─────────────────────────────────┘
```

Also display global diagnostics:

```text
capture FPS
Vision FPS
average inference latency
active track count
```

---

## 16. Phase 12 — Settings UI

Add menu/settings controls:

```text
Shoulder Surf Detection
  ✓ Enabled

Attention Sensitivity
  Conservative
  Balanced
  Sensitive

Looking Duration
  0.5 s
  0.8 s
  1.0 s
  1.5 s

Calibrate Screen Direction…
Calibrate Detection Range…
Debug Preview…
```

Suggested presets:

### Conservative

```text
yaw ±15°
pitch ±12°
duration 1.5 s
```

### Balanced

```text
yaw ±22°
pitch ±18°
duration 0.9 s
```

### Sensitive

```text
yaw ±30°
pitch ±25°
duration 0.6 s
```

---

## 17. Phase 13 — 1–4 m Evaluation Matrix

Test at:

```text
1 m
2 m
3 m
4 m
```

For each distance, test at least:

### Case A — Stranger directly facing screen

Expected: trigger.

### Case B — Stranger facing generally forward but clearly looking toward the side

Expected: may remain a known V1 limitation if head pose stays frontal.

### Case C — Stranger walking past sideways

Expected: no trigger.

### Case D — Stranger facing away

Expected: no trigger.

### Case E — Brief glance < 0.5 s

Expected: no trigger.

### Case F — Sustained observation > ~1 s

Expected: trigger.

### Case G — Owner only

Expected: never triggers shoulder-surf logic.

### Case H — Owner + stranger looking elsewhere

Expected: no shoulder-surf trigger.

### Case I — Owner + stranger looking at screen

Expected: trigger.

### Case J — Two strangers, only one looking

Expected: trigger from the relevant track only.

---

## 18. V1 Acceptance Targets

Initial engineering targets:

```text
Owner false-trigger rate:       < 0.5%
Passer-by false-trigger rate:   < 2%
1–3 m frontal detection recall: > 95%
4 m frontal detection recall:   > 85%
```

Latency targets:

```text
Trigger latency: ~0.8–1.3 s
Release latency: ~0.5–0.8 s
```

Performance target:

```text
Average background CPU: < 15% on a modern Apple Silicon Mac
```

Treat these as tuning goals, not hard guarantees before empirical testing.

---

## 19. Suggested File Layout

Initial V1 can remain mostly flat to minimize project-file churn:

```text
PrivacyShield/
├── AppDelegate.swift
├── CameraManager.swift
├── FaceDetector.swift
├── FaceRecognizer.swift
├── HeadPoseEstimator.swift          # new
├── AttentionState.swift             # new
├── AttentionClassifier.swift        # new
├── ScreenDirectionCalibration.swift # new
├── FaceTracker.swift                # new
├── PrivacyStateMachine.swift        # optional V1.5
├── ShieldManager.swift
└── Toast.swift
```

A larger directory reorganization can happen after functionality is stable.

---

## 20. Recommended Implementation Order

Implement in this order:

```text
1. Baseline build validation
2. 1080p camera capture
3. Vision yaw / pitch / roll extraction
4. Debug pose logging / preview
5. Owner filtering integration
6. Rule-based AttentionClassifier
7. Per-face tracking
8. Time-based attention filter
9. Screen-direction calibration
10. Distance confidence bands
11. Recognition caching
12. 1 m / 2 m / 3 m / 4 m evaluation
13. Threshold tuning
14. Production settings UI
```

Do not introduce gaze estimation before this sequence is validated.

---

## 21. Milestone Definitions

### Milestone 1 — Head Pose Prototype

Goal:

> An unknown face only triggers the shield if its head pose is inside a configurable screen-facing angular region for approximately one second. Enrolled owner faces never trigger this path.

Includes:

- 1080p capture.
- Vision head pose.
- owner/other split.
- simple attention thresholds.
- basic temporal filter.
- debug logging.

Does not require tracking quality to be production-ready.

### Milestone 2 — Multi-Person Stability

Includes:

- stable face tracks;
- per-track attention timers;
- recognition caching;
- multiple simultaneous people;
- no timer mixing between people.

### Milestone 3 — 1–4 m Calibration

Includes:

- screen-direction calibration;
- distance confidence bands;
- 1–4 m evaluation matrix;
- tuned presets.

### Milestone 4 — Production UX

Includes:

- settings UI;
- separate owner-away / shoulder-surf policies;
- debug preview toggle;
- refined notifications and status display.

---

## 22. V2 — Optional Eye-Gaze Refinement

Only add gaze estimation if V1 testing shows that frontal-head / side-eye false positives are materially harmful.

Recommended hybrid approach:

```text
OTHER
  ↓
head pose indicates screen
  ↓
face crop large enough?
  ├── NO → head-pose decision only
  └── YES
       ↓
   eye-gaze model
       ↓
   head + gaze fusion
```

Best use range for gaze refinement:

```text
approximately 1–2 m
```

For 2–4 m, head pose should remain the primary signal.

Possible fusion later:

```text
attentionScore =
    0.65 × headPoseScore +
    0.35 × gazeScore
```

V2 must remain optional so failure of the gaze model does not disable privacy protection.

---

## 23. First Development Task

The first code change after this document should be:

> Replace `.medium` camera capture with a stable 1080p format and add debug output for actual capture resolution/FPS.

Then immediately implement:

> `HeadPoseEstimator.swift` and log yaw/pitch/roll for each Vision face observation.

This gives the data required to tune every later step instead of guessing thresholds in advance.
