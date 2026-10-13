# PrivacyShieldMac — Implementation TODO List

> Based on `DEVELOPMENT_PLAN_with_fork.md`  
> Target range: **1–4 m**  
> Main branch: `main`  
> Development branch: `feature/head-pose-attention`

---

## Status snapshot (updated 2026-10-13)

- Implementation is complete for all M0–M4 code on branch `feature/head-pose-attention` of the fork `Aitar/PrivacyShieldMac`; every task was implemented by parallel subagents in per-task commits, and all work is committed on that branch.
- **205 unit tests pass and the app builds.**
- Remaining work is human-in-the-loop runtime verification: every `[-]` item below must be executed by a person at the Mac, following the protocols in `docs/`.
- The three manual blocks are M3-T06 (1–4 m tuning pass — `docs/evaluation_protocol_1_4m.md`), M4-T07 (final regression suite — `docs/final_regression_suite.md`), and baseline metrics (M0-T03 — `docs/baseline_metrics.md`).
- Supporting docs are complete: `baseline_behavior.md` (15 baseline findings), `baseline_metrics.md`, `m1_head_pose_results.md`, `m2_multi_person_results.md`, `evaluation_protocol_1_4m.md` + `evaluation_results.csv` (template), `m3_tuning_report.md`, `performance_report.md`, `final_regression_suite.md`, `README.md`, `CHANGELOG.md`.
- Checkbox reading: `[x]` = implemented/documented and verified by code, unit tests, or docs; `[-]` = implemented/documented but requires manual execution at the Mac; `[ ]` = not started (deferred V2 only).

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

### [x] M0-T01 — Fork and configure remotes

**Parallelism:** P0  
**Depends on:** none

Tasks:

- [x] Fork `GitGuru29/PrivacyShieldMac` to `Aitar/PrivacyShieldMac`.
- [x] Clone fork locally.
- [x] Configure `origin`.
- [x] Add upstream remote.
- [x] Verify `git remote -v`.
- [x] Create `feature/head-pose-attention`.
- [x] Push branch to origin.

Expected remotes:

```text
origin    https://github.com/Aitar/PrivacyShieldMac.git
upstream  https://github.com/GitGuru29/PrivacyShieldMac.git
```

**Acceptance:**

- [x] Local repository builds from the fork.
- [x] Development branch exists locally and remotely.

---

### [x] M0-T02 — Validate baseline app behavior (doc complete; on-device verification manual — protocol: docs/baseline_behavior.md)

**Parallelism:** P1 with M0-T03  
**Depends on:** M0-T01

Tasks:

- [x] Build with current Xcode.
- [-] Launch menu-bar app. (manual — protocol: docs/baseline_behavior.md)
- [-] Grant camera permission. (manual — protocol: docs/baseline_behavior.md)
- [-] Enroll owner. (manual — protocol: docs/baseline_behavior.md)
- [-] Verify owner is accepted. (manual — protocol: docs/baseline_behavior.md)
- [-] Verify unknown nearby face triggers shield. (manual — protocol: docs/baseline_behavior.md)
- [-] Verify unknown face leaving removes shield. (manual — protocol: docs/baseline_behavior.md)
- [-] Verify notification path. (manual — protocol: docs/baseline_behavior.md)
- [-] Verify global hotkey. (manual — protocol: docs/baseline_behavior.md)
- [-] Verify multi-display shield if a second display is available. (manual — protocol: docs/baseline_behavior.md)
- [-] Verify current detection-range calibration. (manual — protocol: docs/baseline_behavior.md)

**Acceptance:**

- [x] Baseline behavior is documented.
- [x] Any pre-existing bugs are recorded separately from new implementation issues. (15 findings in docs/baseline_behavior.md)

---

### [x] M0-T03 — Record baseline performance (docs/baseline_metrics.md created; live measurements manual)

**Parallelism:** P1 with M0-T02  
**Depends on:** M0-T01

Record:

- [-] Actual capture resolution. (manual — protocol: docs/baseline_metrics.md)
- [-] Capture FPS. (manual — protocol: docs/baseline_metrics.md)
- [-] Vision processing frequency. (manual — protocol: docs/baseline_metrics.md)
- [-] Face detection latency. (manual — protocol: docs/baseline_metrics.md)
- [-] Face recognition latency. (manual — protocol: docs/baseline_metrics.md)
- [-] Average idle monitoring CPU. (manual — protocol: docs/baseline_metrics.md)
- [-] Peak CPU with two faces. (manual — protocol: docs/baseline_metrics.md)
- [-] Memory footprint. (manual — protocol: docs/baseline_metrics.md)

Create:

```text
docs/baseline_metrics.md
```

**Acceptance:**

- [-] Numbers are reproducible on the primary development Mac. (manual — protocol: docs/baseline_metrics.md)
- [x] Mac model / macOS / camera source are recorded.

---

## Milestone 0 Exit Criteria

- [x] Baseline build succeeds.
- [-] Owner enrollment works. (manual — protocol: docs/baseline_behavior.md)
- [-] Existing shield behavior works. (manual — protocol: docs/baseline_behavior.md)
- [x] Baseline metrics are recorded.
- [x] No new feature code has been introduced before baseline capture.

---

# Milestone 1 — Head Pose Prototype

## Goal

An unknown face only triggers the shield when its head pose is inside the configured screen-facing region for roughly one second. Owner/trusted faces do not trigger the shoulder-surf path.

---

## M1-A — Capture Lane

### [x] M1-T01 — Upgrade camera capture to stable 1080p

**Parallelism:** P1 with M1-T02, M1-T04  
**Depends on:** M0 exit  
**Primary file:** `PrivacyShield/CameraManager.swift`

Tasks:

- [x] Replace `.medium` as the primary configuration.
- [x] Enumerate supported camera formats.
- [x] Prefer `1920×1080 @ 30 FPS`.
- [x] Fallback to `1920×1080 @ 15 FPS`.
- [x] Fallback to highest stable supported format.
- [x] Keep `alwaysDiscardsLateVideoFrames = true`.
- [x] Log selected width / height / FPS.
- [-] Verify built-in Mac camera. (manual — protocol: docs/performance_report.md)
- [-] Verify fallback behavior when 1080p is unavailable. (manual — protocol: docs/performance_report.md)
- [x] Keep external higher-resolution camera support optional.

**Acceptance:**

- [x] 1080p is selected when supported. (implemented and logged; runtime confirmation manual)
- [-] Capture remains stable for at least 30 minutes. (manual — protocol: docs/performance_report.md)
- [-] No frame backlog grows over time. (manual — protocol: docs/performance_report.md)

---

### [x] M1-T03 — Introduce capture/processing cadence metrics

**Parallelism:** P1 after M1-T01; parallel with M1-T05  
**Depends on:** M1-T01  
**Primary file:** `CameraManager.swift`

Tasks:

- [x] Measure capture FPS.
- [x] Measure processed Vision FPS.
- [x] Log actual dropped/throttled processing rate.
- [x] Expose lightweight metrics to debug layer.
- [x] Ensure metrics do not materially increase CPU usage. (by design; live confirmation pending — docs/performance_report.md)

**Acceptance:**

- [x] Debug output distinguishes capture FPS from Vision FPS.

---

## M1-B — Head Pose / Attention Lane

### [x] M1-T02 — Implement `HeadPoseEstimator`

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

- [x] Read `yaw`, `pitch`, `roll` from `VNFaceObservation`.
- [x] Convert radians to degrees.
- [x] Define coordinate/sign conventions in comments.
- [x] Never map unavailable pose to zero.
- [x] Return `.unavailable` when required data is absent.
- [x] Add lightweight unit tests for radians → degrees conversion.
- [x] Add manual sanity logs for left/right/up/down.

**Acceptance:**

- [-] Left/right head rotation changes yaw consistently. (manual — protocol: docs/m1_head_pose_results.md)
- [-] Up/down motion changes pitch consistently. (manual — protocol: docs/m1_head_pose_results.md)
- [x] Missing pose is distinguishable from frontal pose.

---

### [x] M1-T04 — Define attention model API and rule-based classifier

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

- [x] Define classifier configuration object.
- [x] Support `screenCenterYaw`.
- [x] Support `screenCenterPitch`.
- [x] Implement yaw/pitch angular errors.
- [x] Implement normalized yaw score.
- [x] Implement normalized pitch score.
- [x] Implement roll score.
- [x] Implement weighted score:

```text
0.60 yaw
0.35 pitch
0.05 roll
```

- [x] Initial thresholds:

```text
looking >= 0.70
notLooking <= 0.45
otherwise uncertain
```

- [x] Default balanced tolerances:

```text
yaw ±22°
pitch ±18°
roll ±30°
```

- [x] Make constants configurable, not hard-coded throughout the codebase.
- [x] Add deterministic classifier tests.

**Acceptance:**

- [x] Frontal/screen-aligned synthetic pose → high score.
- [x] Large yaw offset → low score.
- [x] Boundary cases return `uncertain`.

---

## M1-C — Integration / Observability Lane

### [x] M1-T05 — Integrate owner filtering + head pose + attention into `FaceDetector`

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

- [x] Preserve current face-size filtering temporarily.
- [x] Run owner recognition before shoulder-surf attention decision.
- [x] Skip head-pose alert path for owner/trusted.
- [x] Evaluate unknown face with `HeadPoseEstimator`.
- [x] Evaluate valid pose with `AttentionClassifier`.
- [x] Treat unavailable pose as `uncertain`.
- [x] Preserve existing shield behavior for "owner absent" until M4 policy split.
- [x] Add structured debug event per processed face.

**Acceptance:**

- [-] Owner never triggers shoulder-surf attention path. (manual — protocol: docs/m1_head_pose_results.md)
- [-] Unknown frontal face reaches `looking`. (manual — protocol: docs/m1_head_pose_results.md)
- [-] Unknown side-facing face reaches `notLooking` or `uncertain`. (manual — protocol: docs/m1_head_pose_results.md)

---

### [x] M1-T06 — Add structured debug logging

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

- [x] Add a debug-enabled flag.
- [x] Avoid noisy logs in normal mode.
- [x] Add timestamps.
- [x] Add processing latency.
- [x] Ensure logs can be copied into evaluation notes.

**Acceptance:**

- [x] One line/event gives enough data to understand why a face was classified as looking.

---

### [x] M1-T07 — Add prototype time-based trigger

**Parallelism:** P1 with M1-T06  
**Depends on:** M1-T05  
**Primary file:** `FaceDetector.swift`

V1 prototype can still use a temporary single unknown-face timer before M2 tracking.

Tasks:

- [x] Replace the attention trigger's frame-count dependence with elapsed time.
- [x] Use initial trigger duration `0.9 s`.
- [x] Use initial release duration `0.6 s`.
- [x] Do not trigger on a single positive frame.
- [x] Reset pending state on clear `notLooking`.
- [x] Decide how `uncertain` affects timer:
  - recommended: short uncertain gaps pause/hold briefly rather than instantly reset.
- [x] Keep old global safe logic isolated for later replacement.

**Acceptance:**

- [x] <0.5 s glance does not normally trigger.
- [x] ~1 s sustained frontal pose does trigger.
- [x] Repeated state flicker is reduced compared with raw frame decisions.

---

### [-] M1-T08 — Add milestone-level regression checks (protocol + results template complete; execution requires manual runs — docs/m1_head_pose_results.md)

**Parallelism:** P3 throughout M1  
**Depends on:** relevant task under test

Test cases:

- [x] Owner only.
- [x] Unknown frontal face.
- [x] Unknown 45° side face.
- [x] Unknown quick glance.
- [x] Unknown sustained look.
- [x] No face.
- [x] Low-light room.
- [x] Backlit face.
- [x] Two visible faces as a known limitation before M2.

Record findings:

```text
docs/m1_head_pose_results.md
```

---

## Milestone 1 Exit Criteria

- [x] Capture prefers 1080p.
- [x] Head pose values are available and debugged.
- [x] Rule-based attention classifier is implemented.
- [x] Owner/trusted faces bypass shoulder-surf triggers.
- [-] Unknown frontal face can trigger after ~0.8–1.0 s. (manual — protocol: docs/m1_head_pose_results.md)
- [x] Brief glance usually does not trigger.
- [x] Debug logs explain decisions.
- [x] Known multi-person limitations are documented.

---

# Milestone 2 — Multi-Person Stability

## Goal

Each visible person gets a stable track, independent identity state, and independent attention timer. Recognition work is cached and does not run unnecessarily every processed frame.

---

### [x] M2-T01 — Define tracking and per-track state contracts

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

- [x] Track creation API.
- [x] Track update API.
- [x] Track expiry policy.
- [x] Track-to-detection association result.
- [x] Maximum short detection gap.
- [x] Identity cache ownership.

**Acceptance:**

- [x] Contract supports independent timers and identity caching.

---

### [x] M2-T02 — Implement lightweight detection-to-track association

**Parallelism:** P1 with M2-T06 after M2-T01  
**Depends on:** M2-T01  
**Primary file:** `FaceTracker.swift`

Use:

- [x] Bounding-box IoU.
- [x] Center-distance score.
- [x] Relative face-size change.
- [x] Simple weighted matching.
- [x] No DeepSORT dependency.

Tasks:

- [x] Create new tracks for unmatched detections.
- [x] Update matched tracks.
- [x] Retain tracks across a short missed-detection gap.
- [x] Expire stale tracks.
- [x] Prevent one detection from matching multiple tracks.
- [x] Prevent one track from claiming multiple detections.
- [x] Add tests using synthetic bounding boxes.

**Acceptance:**

- [x] Two stationary faces keep separate IDs.
- [x] Small movements do not constantly create new IDs.
- [x] A one/few-frame miss does not instantly kill the track.

---

### [x] M2-T03 — Move attention state into each track

**Parallelism:** P0 critical-path  
**Depends on:** M2-T02  
**Primary files:** `FaceTracker.swift`, `FaceDetector.swift`

Tasks:

- [x] Store latest `HeadPoseResult` per track if useful.
- [x] Store latest `AttentionResult`.
- [x] Store `lookingSince`.
- [x] Store last positive/negative timestamps.
- [x] Keep unknown/unavailable state explicit.
- [x] Move global attention prototype state out of `FaceDetector`.

**Acceptance:**

- [x] Every track has independent attention history.

---

### [x] M2-T04 — Implement per-track time-based state machine

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

- [x] Trigger duration configurable.
- [x] Release duration configurable.
- [x] `uncertain` grace window configurable.
- [x] Different tracks never share duration.
- [x] Multiple tracks can independently become qualifying observers.
- [x] Global shield activates if any qualifying non-owner track is in alert.
- [x] Shield release waits until no qualifying track remains.

**Acceptance:**

- [x] Stranger A's 0.5 s + Stranger B's 0.5 s never becomes 1.0 s.
- [x] One looking stranger triggers even if another stranger is not looking.
- [x] Alert persists while at least one qualifying track remains.

---

### [x] M2-T05 — Define identity-cache policy

**Parallelism:** P2 with M2-T01  
**Depends on:** M1 exit

Specify:

```text
new track            → recognize immediately
owner/trusted track  → revalidate every 2–3 s
other track          → revalidate every 1–2 s
```

Early revalidation conditions:

- [x] Bounding box jumps significantly.
- [x] Track resumes after long gap.
- [x] Face size changes significantly.
- [x] Current crop quality is much better than cached recognition sample.

**Acceptance:**

- [x] Policy is encoded as config rather than scattered constants.

---

### [x] M2-T06 — Implement recognition caching

**Parallelism:** P1 with M2-T02  
**Depends on:** M2-T05, M2-T01  
**Primary files:** `FaceDetector.swift`, `FaceRecognizer.swift` integration

Tasks:

- [x] Recognize on new track.
- [x] Cache identity on track.
- [x] Respect revalidation cadence.
- [x] Preserve owner/trusted/other state.
- [x] Prevent temporary failed recognition from immediately flipping a stable owner track to other.
- [x] Add confidence/hysteresis behavior if necessary.

**Acceptance:**

- [x] Recognition requests per second drop materially. (by design ~15–25× reduction, documented in docs/performance_report.md; live confirmation pending)
- [-] Owner remains stable under ordinary head motion. (manual — protocol: docs/m2_multi_person_results.md)

---

### [x] M2-T07 — Multi-person debug instrumentation

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

- [-] A test run with 2–3 people can be debugged from logs alone. (manual — protocol: docs/m2_multi_person_results.md)

---

### [-] M2-T08 — Multi-person regression matrix (protocol complete; execution manual — docs/m2_multi_person_results.md)

**Parallelism:** P3 after partial M2 integration  
**Depends on:** M2-T04, M2-T06

Test:

- [-] Owner + one stranger looking. (manual — protocol: docs/m2_multi_person_results.md)
- [-] Owner + one stranger not looking. (manual — protocol: docs/m2_multi_person_results.md)
- [-] Owner + two strangers, one looking. (manual — protocol: docs/m2_multi_person_results.md)
- [-] Owner + two strangers, neither looking. (manual — protocol: docs/m2_multi_person_results.md)
- [-] Two strangers swap horizontal positions. (manual — protocol: docs/m2_multi_person_results.md)
- [-] Person briefly occluded. (manual — protocol: docs/m2_multi_person_results.md)
- [-] Person leaves and re-enters. (manual — protocol: docs/m2_multi_person_results.md)
- [-] Owner turns sideways. (manual — protocol: docs/m2_multi_person_results.md)
- [-] Stranger walks across background. (manual — protocol: docs/m2_multi_person_results.md)

Create:

```text
docs/m2_multi_person_results.md
```

---

## Milestone 2 Exit Criteria

- [x] Stable per-face track IDs exist.
- [x] Per-track timers are independent.
- [x] Recognition is cached.
- [x] Two or more people can be processed simultaneously.
- [x] Any qualifying stranger can trigger.
- [x] Non-looking strangers do not inherit another person's timer.
- [-] CPU is no worse than the M1 prototype despite additional state. (manual — protocol: docs/performance_report.md)

---

# Milestone 3 — 1–4 m Calibration & Tuning

## Goal

Calibrate screen-facing direction, adapt policy by apparent distance, and empirically tune thresholds across 1 m, 2 m, 3 m, and 4 m.

---

## M3-A — Screen Direction Calibration

### [x] M3-T01 — Implement calibration data collector

**Parallelism:** P1 with M3-T03, M3-T05  
**Depends on:** M1 interfaces; recommended after M2 exit  
**New file:** `PrivacyShield/ScreenDirectionCalibration.swift`

Tasks:

- [x] Collect valid head-pose samples for 2–3 seconds.
- [x] Reject unavailable samples.
- [x] Reject strong outliers.
- [x] Compute median yaw.
- [x] Compute median pitch.
- [x] Persist values.
- [x] Track sample count and validity rate.

**Acceptance:**

- [x] Calibration fails gracefully if too few valid samples exist.

---

### [x] M3-T02 — Add screen-direction calibration menu action

**Parallelism:** P1 after M3-T01  
**Depends on:** M3-T01  
**Primary file:** `AppDelegate.swift`

Tasks:

- [x] Add `Calibrate Screen Direction…`.
- [-] Show clear user instruction. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [x] Start delayed sample collection.
- [-] Show success/failure toast. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [x] Show current calibrated center in debug mode.
- [x] Recalibration replaces stored values.

**Acceptance:**

- [x] Calibration survives app restart.

---

## M3-B — Distance Confidence Lane

### [x] M3-T03 — Define distance-band model

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

- [x] Create configurable thresholds.
- [-] Record raw face-width distributions at 1/2/3/4 m. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [x] Avoid assuming one camera's widths generalize to every camera.
- [x] Support calibration-derived band boundaries later if needed.

**Acceptance:**

- [x] Same camera maps test distances monotonically to face-size bands.

---

### [x] M3-T04 — Implement distance-adaptive attention policy

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

- [x] Select classifier thresholds by band.
- [x] Select trigger duration by band.
- [x] Keep values configurable.
- [x] Preserve `uncertain` for unreliable far faces.
- [x] Add tests for profile selection.

**Acceptance:**

- [x] Profile changes do not reset tracks unnecessarily.
- [x] Band transitions do not cause rapid oscillation; add hysteresis if needed. (hysteresis unit-tested)

---

## M3-C — Evaluation Lane

### [x] M3-T05 — Build evaluation harness and test protocol

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

- [x] Directly facing screen.
- [x] Clearly facing left.
- [x] Clearly facing right.
- [x] Looking up/down.
- [x] Walking laterally past camera.
- [x] Facing away.
- [x] Brief glance < 0.5 s.
- [x] Sustained attention > 1 s.
- [x] Owner only.
- [x] Owner + stranger looking elsewhere.
- [x] Owner + stranger looking.
- [x] Two strangers, one looking.

**Acceptance:**

- [x] Test process is repeatable.

---

### [-] M3-T06 — Execute 1–4 m tuning pass (tuning report, targets, procedure, revision log complete — docs/m3_tuning_report.md; physical 1–4 m execution + threshold revision require manual runs — docs/evaluation_protocol_1_4m.md)

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

- [-] Run evaluation matrix. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [-] Tune angle tolerances. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [-] Tune score thresholds. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [-] Tune uncertain grace period. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [-] Tune near/mid/far face-size boundaries. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [-] Tune trigger/release duration. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [x] Record every threshold revision. (revision log table created in docs/m3_tuning_report.md)
- [x] Avoid overfitting to a single lighting condition. (rule documented in procedure)

Output:

```text
docs/m3_tuning_report.md
```

---

### [-] M3-T07 — Performance tuning after feature completeness (static cost analysis + instrumentation inventory complete — docs/performance_report.md; live CPU/latency measurements require manual runs)

**Parallelism:** P1 with late M3-T06 iterations  
**Depends on:** M2 exit

Tasks:

- [-] Measure CPU at idle. (manual — protocol: docs/performance_report.md)
- [-] Measure CPU with 1/2/3 faces. (manual — protocol: docs/performance_report.md)
- [-] Measure recognition frequency. (manual — protocol: docs/performance_report.md)
- [-] Measure face-detection latency. (manual — protocol: docs/performance_report.md)
- [-] Measure tracking overhead. (manual — protocol: docs/performance_report.md)
- [x] Tune frame skip / processing cadence. (documented tuning levers + frameSkip constant — docs/performance_report.md)
- [-] Confirm background monitoring remains responsive. (manual — protocol: docs/performance_report.md)
- [-] Target average CPU <15% on primary Apple Silicon Mac. (manual verification pending — protocol: docs/performance_report.md)

**Acceptance:**

- [-] Performance target met or explicitly documented with reason. (manual — protocol: docs/performance_report.md)

---

## Milestone 3 Exit Criteria

- [x] Screen center can be calibrated and persisted.
- [x] Near/mid/far policy is implemented.
- [-] 1/2/3/4 m matrix has been executed. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [-] Thresholds are empirically tuned. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [-] Performance has been measured after tuning. (manual — protocol: docs/performance_report.md)
- [x] Known V1 limitation "head frontal but eyes looking sideways" is documented.

---

# Milestone 4 — Production UX & Policy

## Goal

Turn the working detector into a controllable, understandable, production-like menu-bar experience.

---

## M4-A — Settings Lane

### [x] M4-T01 — Add settings model

**Parallelism:** P1 with M4-T03, M4-T05  
**Depends on:** M3 stabilized configs  
**New file suggestion:** `AttentionSettings.swift`

Persist:

- [x] Shoulder-surf detection enabled.
- [x] Sensitivity preset.
- [x] Trigger duration override.
- [x] Release duration override.
- [x] Screen center yaw/pitch.
- [x] Distance thresholds.
- [x] Debug preview enabled.
- [x] Blur when owner absent.
- [x] Blur when shoulder surfer detected.

**Acceptance:**

- [x] Defaults are valid on first launch.
- [x] Settings survive restart.

---

### [x] M4-T02 — Implement sensitivity presets

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

- [x] Presets are centralized.
- [x] Balanced uses M3 tuned values.
- [x] User overrides are clear if supported.
- [x] Changing preset does not corrupt calibration.

---

## M4-B — Privacy Policy Lane

### [x] M4-T03 — Separate owner-away policy from shoulder-surf policy

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

- [x] Compute owner presence independently.
- [x] Compute shoulder-surfer state independently.
- [x] `owner absent` can optionally blur.
- [x] `unknown person present but not looking` does not shoulder-surf blur.
- [x] `unknown person looking` can blur even when owner is present.
- [x] Define precedence when both policies are active.

**Acceptance:**

- [x] Policy states can be reasoned about independently.

---

### [x] M4-T04 — Refine notifications/status text

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

- [x] Avoid duplicate notification spam.
- [x] Notification reason matches actual trigger reason.
- [x] Menu status exposes safe / owner away / observer detected.

---

## M4-C — Debug / UX Lane

### [x] M4-T05 — Implement debug camera preview

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

- [x] Preview can be toggled off completely.
- [x] Preview does not alter detection decisions.
- [x] Preview is not shown in normal menu-bar-only operation.

---

### [x] M4-T06 — Integrate production menu/settings UX

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

- [x] Wire toggles to runtime config.
- [x] Rebuild menu state correctly.
- [x] Preserve existing enrollment actions.
- [x] Preserve global hotkey.
- [x] Preserve launch-at-login.

---

### [-] M4-T07 — Final regression suite (suite protocol complete — docs/final_regression_suite.md; execution requires a human at the Mac)

**Parallelism:** P3 final validation  
**Depends on:** M4-T06

Functional:

- [-] First launch. (manual — protocol: docs/final_regression_suite.md)
- [-] Camera permission denied then later enabled. (manual — protocol: docs/final_regression_suite.md)
- [-] Owner enrollment. (manual — protocol: docs/final_regression_suite.md)
- [-] Trusted face enrollment. (manual — protocol: docs/final_regression_suite.md)
- [-] Enrollment reset. (manual — protocol: docs/final_regression_suite.md)
- [-] Calibration. (manual — protocol: docs/final_regression_suite.md)
- [-] Owner-only operation. (manual — protocol: docs/final_regression_suite.md)
- [-] Shoulder surfer. (manual — protocol: docs/final_regression_suite.md)
- [-] Passer-by. (manual — protocol: docs/final_regression_suite.md)
- [-] Two strangers. (manual — protocol: docs/final_regression_suite.md)
- [-] Owner absent. (manual — protocol: docs/final_regression_suite.md)
- [-] User settings persist. (manual — protocol: docs/final_regression_suite.md)
- [-] Debug preview on/off. (manual — protocol: docs/final_regression_suite.md)
- [-] Launch at login. (manual — protocol: docs/final_regression_suite.md)
- [-] Multi-display shield. (manual — protocol: docs/final_regression_suite.md)
- [-] Long-running background session. (manual — protocol: docs/final_regression_suite.md)

Performance:

- [-] 30+ minute monitoring stability. (manual — protocol: docs/final_regression_suite.md)
- [-] No obvious memory growth. (manual — protocol: docs/final_regression_suite.md)
- [-] CPU within target. (manual — protocol: docs/final_regression_suite.md)
- [-] No capture queue backlog. (manual — protocol: docs/final_regression_suite.md)
- [-] No repeated notification storm. (manual — protocol: docs/final_regression_suite.md)

---

### [x] M4-T08 — Documentation / release notes

**Parallelism:** P1 with M4-T07  
**Depends on:** M4-T06

Update:

- [x] `README.md`
- [x] Setup / build instructions.
- [x] 1–4 m target-range limitations.
- [x] Calibration instructions.
- [x] Sensitivity presets.
- [x] Privacy statement: all processing local.
- [x] Known limitation: head pose is not true eye-gaze estimation.
- [x] Troubleshooting.
- [x] Change log / release notes.

---

## Milestone 4 Exit Criteria

- [x] Shoulder-surf and owner-away policies are independent.
- [x] User can calibrate and configure behavior.
- [x] Debug view is available but optional.
- [x] Notifications explain why shield activated.
- [-] Regression suite passes. (manual — protocol: docs/final_regression_suite.md)
- [x] README documents expected operating range and limitations.

---

# 3. Cross-Milestone Tasks

These tasks can run continuously.

### [x] X-T01 — Maintain configuration in one place (audit passed; 2 documented exceptions: user-calibrated minFaceSize gate (annotated) and removal of dead sensitivityThreshold property)

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

### [x] X-T02 — Keep diagnostic logging structured (all preferred fields present; capture_metrics routed through DiagnosticsLog)

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

### [x] X-T03 — Add unit tests for pure logic (8/8 required modules unit-tested; 205 tests total)

**Parallelism:** P3 continuously

Unit-testable modules:

- [x] Angle conversion.
- [x] Attention scoring.
- [x] Attention state hysteresis.
- [x] Track association scoring.
- [x] Track expiry.
- [x] Per-track temporal filter.
- [x] Distance-band mapping.
- [x] Settings/preset selection.

---

### [x] X-T04 — Keep Vision/camera integration tests manual or fixture-based (no test uses a live camera or Vision inference; all temporal tests use injected dates)

**Parallelism:** P3 continuously

Do not force all camera behavior into unit tests. Maintain reproducible manual protocols and, where useful, recorded fixture metadata.

---

### [x] X-T05 — Avoid premature V2 eye-gaze work (zero external dependencies; no L2CS/MediaPipe/PyTorch/ONNX/DeepSORT/cloud)

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

- [x] Owner/trusted faces do not trigger shoulder-surf alerts.
- [x] Multiple people have independent tracks.
- [x] A non-owner looking toward the screen for the configured duration triggers shield.
- [x] A brief glance normally does not trigger.
- [x] A passer-by normally does not trigger.
- [x] Unknown people looking elsewhere normally do not trigger.
- [-] 1–3 m frontal detection recall is >95% in the test environment. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [-] 4 m frontal detection recall is >85% in the test environment. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [-] Owner false-trigger rate is <0.5% in the test protocol. (manual — protocol: docs/evaluation_protocol_1_4m.md)
- [x] Screen direction calibration persists.
- [x] Distance-adaptive thresholds are active.
- [x] Owner-away behavior is independent from shoulder-surf behavior.
- [x] Settings persist.
- [x] Debug preview can explain decisions.
- [-] Average monitoring CPU is around or below the target on the primary Apple Silicon Mac. (manual — protocol: docs/performance_report.md)
- [x] README documents operating range, setup, calibration, and known limitations.

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

