# PrivacyShieldMac — Implementation TODO List

> Based on `DEVELOPMENT_PLAN_with_fork.md`  
> Target range: **1–4 m**  
> Main branch: `main`  
> Development branch: `feature/head-pose-attention`

---

## 0. How to Use This TODO

Task IDs are stable and should be used in branch names, commits, PRs, issue titles, and agent assignments.

Recommended branch naming:

```text
task/M1-T01-camera-1080p
task/M1-T02-head-pose
task/M2-T03-face-tracker
```

Recommended commit format:

```text
feat(M1-T02): add Vision head pose extraction
fix(M2-T04): preserve track identity across short detection gaps
test(M3-T05): add 1-4m evaluation fixtures
```

### Task status

Use the following checklist convention:

```text
[ ] not started
[x] complete
[-] blocked
[~] in progress
```

### Parallelism labels

- **P0 — Serial / critical-path:** should not start before its dependencies are complete.
- **P1 — Fully parallel:** safe to implement independently after listed dependencies.
- **P2 — Parallel with interface contract:** can be implemented in parallel if the referenced API/data contract is agreed first.
- **P3 — Validation parallel:** can run in parallel with feature work and should continuously feed findings back into implementation.

---

# 1. High-Level Dependency Graph

```text
M0-T01 Fork / clone / baseline
        |
        +---------------------+
        |                     |
        v                     v
M1-T01 Camera 1080p      M1-T02 HeadPoseEstimator
        |                     |
        |                     +----------+
        |                                |
        v                                v
M1-T03 Capture metrics             M1-T04 Attention model contract
        |                                |
        +---------------+----------------+
                        |
                        v
                  M1-T05 FaceDetector integration
                        |
              +---------+---------+
              |                   |
              v                   v
        M1-T06 Debug logs    M1-T07 Temporal prototype
              |                   |
              +---------+---------+
                        |
                        v
                  M1 Milestone exit
                        |
          +-------------+--------------+
          |                            |
          v                            v
    M2-T01 Tracker contract      M2-T05 Identity caching contract
          |                            |
          v                            v
    M2-T02 Track association      M2-T06 Recognition cache
          |                            |
          +-------------+--------------+
                        |
                        v
                  M2-T03 Per-track state
                        |
                        v
                  M2-T04 Time filter
                        |
                        v
                  M2 Milestone exit
                        |
       +----------------+----------------+
       |                |                |
       v                v                v
 M3-T01 Screen calib M3-T03 Range bands M3-T05 Eval harness
       |                |                |
       +--------+-------+                |
                |                        |
                v                        |
          M3-T04 Adaptive policy         |
                |                        |
                +-----------+------------+
                            |
                            v
                      M3-T06 1–4m tuning
                            |
                            v
                      M3 Milestone exit
                            |
       +--------------------+--------------------+
       |                    |                    |
       v                    v                    v
 M4-T01 Settings UI   M4-T03 Privacy policy   M4-T05 Debug preview
       |                    |                    |
       +----------+---------+----------+---------+
                  |                    |
                  v                    v
            M4-T06 UX integration   M4-T07 Final regression
                  |                    |
                  +---------+----------+
                            |
                            v
                      V1 release candidate
```

---

# 2. Parallel Development Lanes

These lanes are designed so multiple developers/agents can work concurrently.

| Lane | Scope | Main files | Starts after |
|---|---|---|---|
| **Lane A — Capture** | Camera format, FPS, capture diagnostics | `CameraManager.swift` | M0 baseline |
| **Lane B — Pose/Attention** | Head pose, score model, thresholds | `HeadPoseEstimator.swift`, `Attention*.swift` | M0 baseline |
| **Lane C — Observability** | Logs, metrics, debug preview | debug-related files, `FaceDetector.swift` hooks | API contracts from A/B |
| **Lane D — Tracking/Identity** | Track IDs, recognition cache, per-track state | `FaceTracker.swift`, `FaceRecognizer.swift` integration | M1 |
| **Lane E — Calibration/Evaluation** | Screen calibration, distance bands, test matrix | calibration/eval files | M1 interfaces; full tuning after M2 |
| **Lane F — UX/Policy** | Settings, owner-away behavior, notifications | `AppDelegate.swift`, settings/policy files | contracts can start early; integration after M2/M3 |

### Recommended parallel staffing

For 3 concurrent developers/agents:

```text
Agent A → Lane A + C
Agent B → Lane B + E
Agent C → Lane D + F
```

For 4 concurrent developers/agents:

```text
Agent A → Capture
Agent B → Pose / Attention
Agent C → Tracking / Identity
Agent D → Debug / Calibration / Evaluation
```

Avoid assigning two agents to `FaceDetector.swift` at the same time unless one owns only interface hooks and the other owns final integration.

---

# Milestone 0 — Repository & Baseline

## Goal

Establish a reproducible build and record baseline behavior before changing the detection logic.

---

### [ ] M0-T01 — Fork and configure remotes

**Parallelism:** P0  
**Depends on:** none

Tasks:

- [ ] Fork `GitGuru29/PrivacyShieldMac` to `Aitar/PrivacyShieldMac`.
- [ ] Clone fork locally.
- [ ] Configure `origin`.
- [ ] Add upstream remote.
- [ ] Verify `git remote -v`.
- [ ] Create `feature/head-pose-attention`.
- [ ] Push branch to origin.

Expected remotes:

```text
origin    https://github.com/Aitar/PrivacyShieldMac.git
upstream  https://github.com/GitGuru29/PrivacyShieldMac.git
```

**Acceptance:**

- [ ] Local repository builds from the fork.
- [ ] Development branch exists locally and remotely.

---

### [ ] M0-T02 — Validate baseline app behavior

**Parallelism:** P1 with M0-T03  
**Depends on:** M0-T01

Tasks:

- [ ] Build with current Xcode.
- [ ] Launch menu-bar app.
- [ ] Grant camera permission.
- [ ] Enroll owner.
- [ ] Verify owner is accepted.
- [ ] Verify unknown nearby face triggers shield.
- [ ] Verify unknown face leaving removes shield.
- [ ] Verify notification path.
- [ ] Verify global hotkey.
- [ ] Verify multi-display shield if a second display is available.
- [ ] Verify current detection-range calibration.

**Acceptance:**

- [ ] Baseline behavior is documented.
- [ ] Any pre-existing bugs are recorded separately from new implementation issues.

---

### [ ] M0-T03 — Record baseline performance

**Parallelism:** P1 with M0-T02  
**Depends on:** M0-T01

Record:

- [ ] Actual capture resolution.
- [ ] Capture FPS.
- [ ] Vision processing frequency.
- [ ] Face detection latency.
- [ ] Face recognition latency.
- [ ] Average idle monitoring CPU.
- [ ] Peak CPU with two faces.
- [ ] Memory footprint.

Create:

```text
docs/baseline_metrics.md
```

**Acceptance:**

- [ ] Numbers are reproducible on the primary development Mac.
- [ ] Mac model / macOS / camera source are recorded.

---

## Milestone 0 Exit Criteria

- [ ] Baseline build succeeds.
- [ ] Owner enrollment works.
- [ ] Existing shield behavior works.
- [ ] Baseline metrics are recorded.
- [ ] No new feature code has been introduced before baseline capture.

---

# Milestone 1 — Head Pose Prototype

## Goal

An unknown face only triggers the shield when its head pose is inside the configured screen-facing region for roughly one second. Owner/trusted faces do not trigger the shoulder-surf path.

---

## M1-A — Capture Lane

### [ ] M1-T01 — Upgrade camera capture to stable 1080p

**Parallelism:** P1 with M1-T02, M1-T04  
**Depends on:** M0 exit  
**Primary file:** `PrivacyShield/CameraManager.swift`

Tasks:

- [ ] Replace `.medium` as the primary configuration.
- [ ] Enumerate supported camera formats.
- [ ] Prefer `1920×1080 @ 30 FPS`.
- [ ] Fallback to `1920×1080 @ 15 FPS`.
- [ ] Fallback to highest stable supported format.
- [ ] Keep `alwaysDiscardsLateVideoFrames = true`.
- [ ] Log selected width / height / FPS.
- [ ] Verify built-in Mac camera.
- [ ] Verify fallback behavior when 1080p is unavailable.
- [ ] Keep external higher-resolution camera support optional.

**Acceptance:**

- [ ] 1080p is selected when supported.
- [ ] Capture remains stable for at least 30 minutes.
- [ ] No frame backlog grows over time.

---

### [ ] M1-T03 — Introduce capture/processing cadence metrics

**Parallelism:** P1 after M1-T01; parallel with M1-T05  
**Depends on:** M1-T01  
**Primary file:** `CameraManager.swift`

Tasks:

- [ ] Measure capture FPS.
- [ ] Measure processed Vision FPS.
- [ ] Log actual dropped/throttled processing rate.
- [ ] Expose lightweight metrics to debug layer.
- [ ] Ensure metrics do not materially increase CPU usage.

**Acceptance:**

- [ ] Debug output distinguishes capture FPS from Vision FPS.

---

## M1-B — Head Pose / Attention Lane

### [ ] M1-T02 — Implement `HeadPoseEstimator`

**Parallelism:** P1 with M1-T01, M1-T04  
**Depends on:** M0 exit  
**New file:** `PrivacyShield/HeadPoseEstimator.swift`

Define:

```swift
struct HeadPose {
    let yaw: Double
    let pitch: Double
    let roll: Double
    let confidence: Double
}

enum HeadPoseResult {
    case valid(HeadPose)
    case unavailable
}
```

Tasks:

- [ ] Read `yaw`, `pitch`, `roll` from `VNFaceObservation`.
- [ ] Convert radians to degrees.
- [ ] Define coordinate/sign conventions in comments.
- [ ] Never map unavailable pose to zero.
- [ ] Return `.unavailable` when required data is absent.
- [ ] Add lightweight unit tests for radians → degrees conversion.
- [ ] Add manual sanity logs for left/right/up/down.

**Acceptance:**

- [ ] Left/right head rotation changes yaw consistently.
- [ ] Up/down motion changes pitch consistently.
- [ ] Missing pose is distinguishable from frontal pose.

---

### [ ] M1-T04 — Define attention model API and rule-based classifier

**Parallelism:** P1 with M1-T01, M1-T02  
**Depends on:** M0 exit  
**New files:**

```text
PrivacyShield/AttentionState.swift
PrivacyShield/AttentionClassifier.swift
```

Define:

```swift
enum AttentionState {
    case looking
    case notLooking
    case uncertain
}

struct AttentionResult {
    let state: AttentionState
    let score: Double
}
```

Tasks:

- [ ] Define classifier configuration object.
- [ ] Support `screenCenterYaw`.
- [ ] Support `screenCenterPitch`.
- [ ] Implement yaw/pitch angular errors.
- [ ] Implement normalized yaw score.
- [ ] Implement normalized pitch score.
- [ ] Implement roll score.
- [ ] Implement weighted score:

```text
0.60 yaw
0.35 pitch
0.05 roll
```

- [ ] Initial thresholds:

```text
looking >= 0.70
notLooking <= 0.45
otherwise uncertain
```

- [ ] Default balanced tolerances:

```text
yaw ±22°
pitch ±18°
roll ±30°
```

- [ ] Make constants configurable, not hard-coded throughout the codebase.
- [ ] Add deterministic classifier tests.

**Acceptance:**

- [ ] Frontal/screen-aligned synthetic pose → high score.
- [ ] Large yaw offset → low score.
- [ ] Boundary cases return `uncertain`.

---

## M1-C — Integration / Observability Lane

### [ ] M1-T05 — Integrate owner filtering + head pose + attention into `FaceDetector`

**Parallelism:** P0 critical-path  
**Depends on:** M1-T02, M1-T04  
**Primary file:** `PrivacyShield/FaceDetector.swift`

Implement per face:

```text
eligible face
    ↓
is owner/trusted?
  YES → shoulder-surf ignored
  NO
    ↓
HeadPoseEstimator
    ↓
AttentionClassifier
```

Tasks:

- [ ] Preserve current face-size filtering temporarily.
- [ ] Run owner recognition before shoulder-surf attention decision.
- [ ] Skip head-pose alert path for owner/trusted.
- [ ] Evaluate unknown face with `HeadPoseEstimator`.
- [ ] Evaluate valid pose with `AttentionClassifier`.
- [ ] Treat unavailable pose as `uncertain`.
- [ ] Preserve existing shield behavior for "owner absent" until M4 policy split.
- [ ] Add structured debug event per processed face.

**Acceptance:**

- [ ] Owner never triggers shoulder-surf attention path.
- [ ] Unknown frontal face reaches `looking`.
- [ ] Unknown side-facing face reaches `notLooking` or `uncertain`.

---

### [ ] M1-T06 — Add structured debug logging

**Parallelism:** P1 with M1-T07 after M1-T05  
**Depends on:** M1-T05  
**Primary files:** `FaceDetector.swift` + optional helper

For every usable face log:

```text
face index
bbox
normalized face width
identity state
yaw
pitch
roll
attention score
attention state
```

Tasks:

- [ ] Add a debug-enabled flag.
- [ ] Avoid noisy logs in normal mode.
- [ ] Add timestamps.
- [ ] Add processing latency.
- [ ] Ensure logs can be copied into evaluation notes.

**Acceptance:**

- [ ] One line/event gives enough data to understand why a face was classified as looking.

---

### [ ] M1-T07 — Add prototype time-based trigger

**Parallelism:** P1 with M1-T06  
**Depends on:** M1-T05  
**Primary file:** `FaceDetector.swift`

V1 prototype can still use a temporary single unknown-face timer before M2 tracking.

Tasks:

- [ ] Replace the attention trigger's frame-count dependence with elapsed time.
- [ ] Use initial trigger duration `0.9 s`.
- [ ] Use initial release duration `0.6 s`.
- [ ] Do not trigger on a single positive frame.
- [ ] Reset pending state on clear `notLooking`.
- [ ] Decide how `uncertain` affects timer:
  - recommended: short uncertain gaps pause/hold briefly rather than instantly reset.
- [ ] Keep old global safe logic isolated for later replacement.

**Acceptance:**

- [ ] <0.5 s glance does not normally trigger.
- [ ] ~1 s sustained frontal pose does trigger.
- [ ] Repeated state flicker is reduced compared with raw frame decisions.

---

### [ ] M1-T08 — Add milestone-level regression checks

**Parallelism:** P3 throughout M1  
**Depends on:** relevant task under test

Test cases:

- [ ] Owner only.
- [ ] Unknown frontal face.
- [ ] Unknown 45° side face.
- [ ] Unknown quick glance.
- [ ] Unknown sustained look.
- [ ] No face.
- [ ] Low-light room.
- [ ] Backlit face.
- [ ] Two visible faces as a known limitation before M2.

Record findings:

```text
docs/m1_head_pose_results.md
```

---

## Milestone 1 Exit Criteria

- [ ] Capture prefers 1080p.
- [ ] Head pose values are available and debugged.
- [ ] Rule-based attention classifier is implemented.
- [ ] Owner/trusted faces bypass shoulder-surf triggers.
- [ ] Unknown frontal face can trigger after ~0.8–1.0 s.
- [ ] Brief glance usually does not trigger.
- [ ] Debug logs explain decisions.
- [ ] Known multi-person limitations are documented.

---

# Milestone 2 — Multi-Person Stability

## Goal

Each visible person gets a stable track, independent identity state, and independent attention timer. Recognition work is cached and does not run unnecessarily every processed frame.

---

### [ ] M2-T01 — Define tracking and per-track state contracts

**Parallelism:** P2 with M2-T05 after contract agreement  
**Depends on:** M1 exit  
**New file:** `PrivacyShield/FaceTracker.swift`

Define:

```swift
enum IdentityState {
    case owner
    case trusted
    case other
    case unknown
}

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

Also define:

- [ ] Track creation API.
- [ ] Track update API.
- [ ] Track expiry policy.
- [ ] Track-to-detection association result.
- [ ] Maximum short detection gap.
- [ ] Identity cache ownership.

**Acceptance:**

- [ ] Contract supports independent timers and identity caching.

---

### [ ] M2-T02 — Implement lightweight detection-to-track association

**Parallelism:** P1 with M2-T06 after M2-T01  
**Depends on:** M2-T01  
**Primary file:** `FaceTracker.swift`

Use:

- [ ] Bounding-box IoU.
- [ ] Center-distance score.
- [ ] Relative face-size change.
- [ ] Simple weighted matching.
- [ ] No DeepSORT dependency.

Tasks:

- [ ] Create new tracks for unmatched detections.
- [ ] Update matched tracks.
- [ ] Retain tracks across a short missed-detection gap.
- [ ] Expire stale tracks.
- [ ] Prevent one detection from matching multiple tracks.
- [ ] Prevent one track from claiming multiple detections.
- [ ] Add tests using synthetic bounding boxes.

**Acceptance:**

- [ ] Two stationary faces keep separate IDs.
- [ ] Small movements do not constantly create new IDs.
- [ ] A one/few-frame miss does not instantly kill the track.

---

### [ ] M2-T03 — Move attention state into each track

**Parallelism:** P0 critical-path  
**Depends on:** M2-T02  
**Primary files:** `FaceTracker.swift`, `FaceDetector.swift`

Tasks:

- [ ] Store latest `HeadPoseResult` per track if useful.
- [ ] Store latest `AttentionResult`.
- [ ] Store `lookingSince`.
- [ ] Store last positive/negative timestamps.
- [ ] Keep unknown/unavailable state explicit.
- [ ] Move global attention prototype state out of `FaceDetector`.

**Acceptance:**

- [ ] Every track has independent attention history.

---

### [ ] M2-T04 — Implement per-track time-based state machine

**Parallelism:** P0 critical-path  
**Depends on:** M2-T03

State:

```text
SAFE / IDLE
  ↓
PENDING_LOOK
  ↓ sustained
LOOKING_ALERT
  ↓ sustained clear
IDLE
```

Tasks:

- [ ] Trigger duration configurable.
- [ ] Release duration configurable.
- [ ] `uncertain` grace window configurable.
- [ ] Different tracks never share duration.
- [ ] Multiple tracks can independently become qualifying observers.
- [ ] Global shield activates if any qualifying non-owner track is in alert.
- [ ] Shield release waits until no qualifying track remains.

**Acceptance:**

- [ ] Stranger A's 0.5 s + Stranger B's 0.5 s never becomes 1.0 s.
- [ ] One looking stranger triggers even if another stranger is not looking.
- [ ] Alert persists while at least one qualifying track remains.

---

### [ ] M2-T05 — Define identity-cache policy

**Parallelism:** P2 with M2-T01  
**Depends on:** M1 exit

Specify:

```text
new track            → recognize immediately
owner/trusted track  → revalidate every 2–3 s
other track          → revalidate every 1–2 s
```

Early revalidation conditions:

- [ ] Bounding box jumps significantly.
- [ ] Track resumes after long gap.
- [ ] Face size changes significantly.
- [ ] Current crop quality is much better than cached recognition sample.

**Acceptance:**

- [ ] Policy is encoded as config rather than scattered constants.

---

### [ ] M2-T06 — Implement recognition caching

**Parallelism:** P1 with M2-T02  
**Depends on:** M2-T05, M2-T01  
**Primary files:** `FaceDetector.swift`, `FaceRecognizer.swift` integration

Tasks:

- [ ] Recognize on new track.
- [ ] Cache identity on track.
- [ ] Respect revalidation cadence.
- [ ] Preserve owner/trusted/other state.
- [ ] Prevent temporary failed recognition from immediately flipping a stable owner track to other.
- [ ] Add confidence/hysteresis behavior if necessary.

**Acceptance:**

- [ ] Recognition requests per second drop materially.
- [ ] Owner remains stable under ordinary head motion.

---

### [ ] M2-T07 — Multi-person debug instrumentation

**Parallelism:** P3 with M2-T02–T06  
**Depends on:** M2-T01

Log/display:

```text
Track UUID short form
identity
bbox
lastSeen
attention score/state
looking duration
last identity check age
```

**Acceptance:**

- [ ] A test run with 2–3 people can be debugged from logs alone.

---

### [ ] M2-T08 — Multi-person regression matrix

**Parallelism:** P3 after partial M2 integration  
**Depends on:** M2-T04, M2-T06

Test:

- [ ] Owner + one stranger looking.
- [ ] Owner + one stranger not looking.
- [ ] Owner + two strangers, one looking.
- [ ] Owner + two strangers, neither looking.
- [ ] Two strangers swap horizontal positions.
- [ ] Person briefly occluded.
- [ ] Person leaves and re-enters.
- [ ] Owner turns sideways.
- [ ] Stranger walks across background.

Create:

```text
docs/m2_multi_person_results.md
```

---

## Milestone 2 Exit Criteria

- [ ] Stable per-face track IDs exist.
- [ ] Per-track timers are independent.
- [ ] Recognition is cached.
- [ ] Two or more people can be processed simultaneously.
- [ ] Any qualifying stranger can trigger.
- [ ] Non-looking strangers do not inherit another person's timer.
- [ ] CPU is no worse than the M1 prototype despite additional state.

---

# Milestone 3 — 1–4 m Calibration & Tuning

## Goal

Calibrate screen-facing direction, adapt policy by apparent distance, and empirically tune thresholds across 1 m, 2 m, 3 m, and 4 m.

---

## M3-A — Screen Direction Calibration

### [ ] M3-T01 — Implement calibration data collector

**Parallelism:** P1 with M3-T03, M3-T05  
**Depends on:** M1 interfaces; recommended after M2 exit  
**New file:** `PrivacyShield/ScreenDirectionCalibration.swift`

Tasks:

- [ ] Collect valid head-pose samples for 2–3 seconds.
- [ ] Reject unavailable samples.
- [ ] Reject strong outliers.
- [ ] Compute median yaw.
- [ ] Compute median pitch.
- [ ] Persist values.
- [ ] Track sample count and validity rate.

**Acceptance:**

- [ ] Calibration fails gracefully if too few valid samples exist.

---

### [ ] M3-T02 — Add screen-direction calibration menu action

**Parallelism:** P1 after M3-T01  
**Depends on:** M3-T01  
**Primary file:** `AppDelegate.swift`

Tasks:

- [ ] Add `Calibrate Screen Direction…`.
- [ ] Show clear user instruction.
- [ ] Start delayed sample collection.
- [ ] Show success/failure toast.
- [ ] Show current calibrated center in debug mode.
- [ ] Recalibration replaces stored values.

**Acceptance:**

- [ ] Calibration survives app restart.

---

## M3-B — Distance Confidence Lane

### [ ] M3-T03 — Define distance-band model

**Parallelism:** P1 with M3-T01, M3-T05  
**Depends on:** M2 exit or stable bbox tracking

Define:

```swift
enum DistanceBand {
    case near
    case mid
    case far
    case tooFarOrUnreliable
}
```

Use normalized face width initially.

Tasks:

- [ ] Create configurable thresholds.
- [ ] Record raw face-width distributions at 1/2/3/4 m.
- [ ] Avoid assuming one camera's widths generalize to every camera.
- [ ] Support calibration-derived band boundaries later if needed.

**Acceptance:**

- [ ] Same camera maps test distances monotonically to face-size bands.

---

### [ ] M3-T04 — Implement distance-adaptive attention policy

**Parallelism:** P2 with M3-T02 after model API agreement  
**Depends on:** M3-T03, M1-T04

Initial profiles:

```text
Near:
  yaw ±18°
  pitch ±15°
  trigger 0.7 s

Mid:
  yaw ±22°
  pitch ±18°
  trigger 0.9 s

Far:
  yaw ±27°
  pitch ±22°
  trigger 1.2 s
```

Tasks:

- [ ] Select classifier thresholds by band.
- [ ] Select trigger duration by band.
- [ ] Keep values configurable.
- [ ] Preserve `uncertain` for unreliable far faces.
- [ ] Add tests for profile selection.

**Acceptance:**

- [ ] Profile changes do not reset tracks unnecessarily.
- [ ] Band transitions do not cause rapid oscillation; add hysteresis if needed.

---

## M3-C — Evaluation Lane

### [ ] M3-T05 — Build evaluation harness and test protocol

**Parallelism:** P3 with M3-T01–T04  
**Depends on:** M1 debug data format; best after M2 tracking

Create:

```text
docs/evaluation_protocol_1_4m.md
docs/evaluation_results.csv
```

Protocol must capture:

```text
distance
lighting
camera
number of faces
identity
yaw/pitch/roll
face width
attention score
attention state
triggered?
trigger latency
expected result
```

Required scenarios at each of 1/2/3/4 m:

- [ ] Directly facing screen.
- [ ] Clearly facing left.
- [ ] Clearly facing right.
- [ ] Looking up/down.
- [ ] Walking laterally past camera.
- [ ] Facing away.
- [ ] Brief glance < 0.5 s.
- [ ] Sustained attention > 1 s.
- [ ] Owner only.
- [ ] Owner + stranger looking elsewhere.
- [ ] Owner + stranger looking.
- [ ] Two strangers, one looking.

**Acceptance:**

- [ ] Test process is repeatable.

---

### [ ] M3-T06 — Execute 1–4 m tuning pass

**Parallelism:** P3 but feeds back serially into thresholds  
**Depends on:** M3-T02, M3-T04, M3-T05

Initial targets:

```text
Owner false-trigger rate       < 0.5%
Passer-by false-trigger rate   < 2%
1–3m frontal recall            > 95%
4m frontal recall              > 85%
Trigger latency                ~0.8–1.3 s
Release latency                ~0.5–0.8 s
```

Tasks:

- [ ] Run evaluation matrix.
- [ ] Tune angle tolerances.
- [ ] Tune score thresholds.
- [ ] Tune uncertain grace period.
- [ ] Tune near/mid/far face-size boundaries.
- [ ] Tune trigger/release duration.
- [ ] Record every threshold revision.
- [ ] Avoid overfitting to a single lighting condition.

Output:

```text
docs/m3_tuning_report.md
```

---

### [ ] M3-T07 — Performance tuning after feature completeness

**Parallelism:** P1 with late M3-T06 iterations  
**Depends on:** M2 exit

Tasks:

- [ ] Measure CPU at idle.
- [ ] Measure CPU with 1/2/3 faces.
- [ ] Measure recognition frequency.
- [ ] Measure face-detection latency.
- [ ] Measure tracking overhead.
- [ ] Tune frame skip / processing cadence.
- [ ] Confirm background monitoring remains responsive.
- [ ] Target average CPU <15% on primary Apple Silicon Mac.

**Acceptance:**

- [ ] Performance target met or explicitly documented with reason.

---

## Milestone 3 Exit Criteria

- [ ] Screen center can be calibrated and persisted.
- [ ] Near/mid/far policy is implemented.
- [ ] 1/2/3/4 m matrix has been executed.
- [ ] Thresholds are empirically tuned.
- [ ] Performance has been measured after tuning.
- [ ] Known V1 limitation "head frontal but eyes looking sideways" is documented.

---

# Milestone 4 — Production UX & Policy

## Goal

Turn the working detector into a controllable, understandable, production-like menu-bar experience.

---

## M4-A — Settings Lane

### [ ] M4-T01 — Add settings model

**Parallelism:** P1 with M4-T03, M4-T05  
**Depends on:** M3 stabilized configs  
**New file suggestion:** `AttentionSettings.swift`

Persist:

- [ ] Shoulder-surf detection enabled.
- [ ] Sensitivity preset.
- [ ] Trigger duration override.
- [ ] Release duration override.
- [ ] Screen center yaw/pitch.
- [ ] Distance thresholds.
- [ ] Debug preview enabled.
- [ ] Blur when owner absent.
- [ ] Blur when shoulder surfer detected.

**Acceptance:**

- [ ] Defaults are valid on first launch.
- [ ] Settings survive restart.

---

### [ ] M4-T02 — Implement sensitivity presets

**Parallelism:** P1 after M4-T01  
**Depends on:** M4-T01

Presets:

```text
Conservative
  yaw ±15°
  pitch ±12°
  duration 1.5 s

Balanced
  tuned M3 defaults

Sensitive
  yaw ±30°
  pitch ±25°
  duration 0.6 s
```

Tasks:

- [ ] Presets are centralized.
- [ ] Balanced uses M3 tuned values.
- [ ] User overrides are clear if supported.
- [ ] Changing preset does not corrupt calibration.

---

## M4-B — Privacy Policy Lane

### [ ] M4-T03 — Separate owner-away policy from shoulder-surf policy

**Parallelism:** P1 with M4-T01, M4-T05  
**Depends on:** M2 stable tracking  
**New file suggestion:** `PrivacyStateMachine.swift`

Define:

```swift
struct PrivacyState {
    var ownerPresent: Bool
    var shoulderSurferDetected: Bool
}
```

Tasks:

- [ ] Compute owner presence independently.
- [ ] Compute shoulder-surfer state independently.
- [ ] `owner absent` can optionally blur.
- [ ] `unknown person present but not looking` does not shoulder-surf blur.
- [ ] `unknown person looking` can blur even when owner is present.
- [ ] Define precedence when both policies are active.

**Acceptance:**

- [ ] Policy states can be reasoned about independently.

---

### [ ] M4-T04 — Refine notifications/status text

**Parallelism:** P1 after M4-T03  
**Depends on:** M4-T03  
**Primary file:** `AppDelegate.swift`

Differentiate:

```text
Owner absent
Shoulder surfer detected
Monitoring safe
Calibration active
Camera unavailable
```

Tasks:

- [ ] Avoid duplicate notification spam.
- [ ] Notification reason matches actual trigger reason.
- [ ] Menu status exposes safe / owner away / observer detected.

---

## M4-C — Debug / UX Lane

### [ ] M4-T05 — Implement debug camera preview

**Parallelism:** P1 with M4-T01, M4-T03  
**Depends on:** M2 debug data + M3 metrics

Display per face:

```text
track ID
identity
face width / distance band
yaw
pitch
roll
attention score
attention state
looking duration
```

Display global:

```text
capture FPS
Vision FPS
latency
active track count
selected camera format
screen center calibration
```

Tasks:

- [ ] Preview can be toggled off completely.
- [ ] Preview does not alter detection decisions.
- [ ] Preview is not shown in normal menu-bar-only operation.

---

### [ ] M4-T06 — Integrate production menu/settings UX

**Parallelism:** P0 integration  
**Depends on:** M4-T01, M4-T02, M4-T03, M4-T05  
**Primary file:** `AppDelegate.swift`

Menu:

```text
Shoulder Surf Detection      ✓
Blur When I Leave            ✓

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

Tasks:

- [ ] Wire toggles to runtime config.
- [ ] Rebuild menu state correctly.
- [ ] Preserve existing enrollment actions.
- [ ] Preserve global hotkey.
- [ ] Preserve launch-at-login.

---

### [ ] M4-T07 — Final regression suite

**Parallelism:** P3 final validation  
**Depends on:** M4-T06

Functional:

- [ ] First launch.
- [ ] Camera permission denied then later enabled.
- [ ] Owner enrollment.
- [ ] Trusted face enrollment.
- [ ] Enrollment reset.
- [ ] Calibration.
- [ ] Owner-only operation.
- [ ] Shoulder surfer.
- [ ] Passer-by.
- [ ] Two strangers.
- [ ] Owner absent.
- [ ] User settings persist.
- [ ] Debug preview on/off.
- [ ] Launch at login.
- [ ] Multi-display shield.
- [ ] Long-running background session.

Performance:

- [ ] 30+ minute monitoring stability.
- [ ] No obvious memory growth.
- [ ] CPU within target.
- [ ] No capture queue backlog.
- [ ] No repeated notification storm.

---

### [ ] M4-T08 — Documentation / release notes

**Parallelism:** P1 with M4-T07  
**Depends on:** M4-T06

Update:

- [ ] `README.md`
- [ ] Setup / build instructions.
- [ ] 1–4 m target-range limitations.
- [ ] Calibration instructions.
- [ ] Sensitivity presets.
- [ ] Privacy statement: all processing local.
- [ ] Known limitation: head pose is not true eye-gaze estimation.
- [ ] Troubleshooting.
- [ ] Change log / release notes.

---

## Milestone 4 Exit Criteria

- [ ] Shoulder-surf and owner-away policies are independent.
- [ ] User can calibrate and configure behavior.
- [ ] Debug view is available but optional.
- [ ] Notifications explain why shield activated.
- [ ] Regression suite passes.
- [ ] README documents expected operating range and limitations.

---

# 3. Cross-Milestone Tasks

These tasks can run continuously.

### [ ] X-T01 — Maintain configuration in one place

**Parallelism:** P1 continuously

Avoid duplicated constants for:

```text
yaw tolerance
pitch tolerance
roll tolerance
trigger duration
release duration
uncertain grace
face-size bands
recognition cadence
processing cadence
```

---

### [ ] X-T02 — Keep diagnostic logging structured

**Parallelism:** P1 continuously

Preferred event fields:

```text
timestamp
track_id
identity
face_width
distance_band
yaw
pitch
roll
attention_score
attention_state
looking_duration
event
latency_ms
```

---

### [ ] X-T03 — Add unit tests for pure logic

**Parallelism:** P3 continuously

Unit-testable modules:

- [ ] Angle conversion.
- [ ] Attention scoring.
- [ ] Attention state hysteresis.
- [ ] Track association scoring.
- [ ] Track expiry.
- [ ] Per-track temporal filter.
- [ ] Distance-band mapping.
- [ ] Settings/preset selection.

---

### [ ] X-T04 — Keep Vision/camera integration tests manual or fixture-based

**Parallelism:** P3 continuously

Do not force all camera behavior into unit tests. Maintain reproducible manual protocols and, where useful, recorded fixture metadata.

---

### [ ] X-T05 — Avoid premature V2 eye-gaze work

**Parallelism:** guardrail

Do not add:

```text
L2CS
MediaPipe Iris
PyTorch
ONNX
DeepSORT
cloud inference
```

until M3 proves head-pose false positives are materially limiting usefulness.

---

# 4. Suggested PR / Merge Strategy

To maximize parallel work and minimize conflicts:

## PR 1 — Capture foundation

```text
M1-T01
M1-T03
```

Touches mostly:

```text
CameraManager.swift
```

## PR 2 — Pose + attention core

```text
M1-T02
M1-T04
```

Adds mostly new files.

## PR 3 — M1 integration

```text
M1-T05
M1-T06
M1-T07
```

Touches:

```text
FaceDetector.swift
```

Merge PR 1 and PR 2 before finalizing PR 3.

## PR 4 — Tracking core

```text
M2-T01
M2-T02
M2-T03
M2-T04
```

## PR 5 — Recognition caching

```text
M2-T05
M2-T06
```

Can be developed in parallel with early PR 4 once the track contract is fixed.

## PR 6 — Calibration + distance model

```text
M3-T01
M3-T02
M3-T03
M3-T04
```

## PR 7 — Evaluation and tuning

```text
M3-T05
M3-T06
M3-T07
```

## PR 8 — Production settings + privacy policy

```text
M4-T01
M4-T02
M4-T03
M4-T04
```

## PR 9 — Debug preview + menu integration

```text
M4-T05
M4-T06
```

## PR 10 — Final validation/docs

```text
M4-T07
M4-T08
```

---

# 5. Critical Path

The shortest path to a functional V1 prototype is:

```text
M0-T01
  ↓
M0-T02
  ↓
M1-T02 HeadPoseEstimator
  ↓
M1-T04 AttentionClassifier
  ↓
M1-T05 FaceDetector integration
  ↓
M1-T07 Temporal trigger
  ↓
M2-T01 Track contract
  ↓
M2-T02 Tracking
  ↓
M2-T03 Per-track state
  ↓
M2-T04 Per-track temporal filter
  ↓
M3-T01 Screen calibration
  ↓
M3-T03 Distance bands
  ↓
M3-T04 Adaptive policy
  ↓
M3-T06 1–4m tuning
  ↓
M4-T03 Privacy state split
  ↓
M4-T06 Production integration
  ↓
M4-T07 Final regression
```

Tasks outside this path should be parallelized whenever possible.

---

# 6. Recommended First Parallel Sprint

After baseline validation, start these three tasks at the same time:

### Worker / Agent A

```text
M1-T01 — 1080p camera capture
M1-T03 — capture metrics
```

### Worker / Agent B

```text
M1-T02 — HeadPoseEstimator
```

### Worker / Agent C

```text
M1-T04 — AttentionClassifier + tests
```

Then merge their interfaces and assign:

### Integration worker

```text
M1-T05 — FaceDetector integration
```

while others continue with:

```text
M1-T06 — debug logging
M1-T08 — validation matrix preparation
```

This is the highest-value initial parallelization because the camera, head-pose extraction, and pure attention-classifier logic touch mostly separate files.

---

# 7. Definition of Done for V1

V1 is considered complete only when all of the following are true:

- [ ] Owner/trusted faces do not trigger shoulder-surf alerts.
- [ ] Multiple people have independent tracks.
- [ ] A non-owner looking toward the screen for the configured duration triggers shield.
- [ ] A brief glance normally does not trigger.
- [ ] A passer-by normally does not trigger.
- [ ] Unknown people looking elsewhere normally do not trigger.
- [ ] 1–3 m frontal detection recall is >95% in the test environment.
- [ ] 4 m frontal detection recall is >85% in the test environment.
- [ ] Owner false-trigger rate is <0.5% in the test protocol.
- [ ] Screen direction calibration persists.
- [ ] Distance-adaptive thresholds are active.
- [ ] Owner-away behavior is independent from shoulder-surf behavior.
- [ ] Settings persist.
- [ ] Debug preview can explain decisions.
- [ ] Average monitoring CPU is around or below the target on the primary Apple Silicon Mac.
- [ ] README documents operating range, setup, calibration, and known limitations.

---

# 8. Deferred V2 Tasks

Do **not** schedule these until V1 evaluation is complete.

### [ ] V2-T01 — Determine whether true gaze refinement is needed

Trigger for starting V2:

```text
frontal-head + side-eye false positives are frequent enough to harm usability
```

### [ ] V2-T02 — Evaluate gaze model only for large/near face crops

Target range:

```text
~1–2 m
```

### [ ] V2-T03 — Fuse head pose + gaze

Possible starting model:

```text
attentionScore =
  0.65 × headPoseScore +
  0.35 × gazeScore
```

### [ ] V2-T04 — Keep head-pose-only fallback

Gaze inference failure must never disable the privacy detector.

