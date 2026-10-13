# M1 Head-Pose Regression Matrix (M1-T08)

> Milestone: M1 — Head Pose Prototype
> Branch: `feature/head-pose-attention`
> Recorded: 2026-10-13 (protocol + template; results pending)
> **Manual execution at the Mac is required.** This document is the regression
> *protocol plus results template*: every row below must be executed by a human
> in front of the primary development Mac and filled in. Nothing here is
> verifiable by build or unit tests alone.

Related: `docs/implement_todolist.md` (task definitions, M1-T05/T06/T07/T08),
`docs/baseline_metrics.md` (M0 baseline), `docs/baseline_behavior.md` (M0 manual protocol),
`PrivacyShield/CameraManager.swift` (capture metrics, M1-T03),
`PrivacyShield/HeadPoseEstimator.swift` (pose extraction + sanity logs, M1-T02).

---

## 1. Preconditions (every session)

1. Build from `PrivacyShield.xcodeproj` with current Xcode and run the app
   locally (menu-bar app, camera permission granted).
2. Confirm from the launch log that the **built-in FaceTime HD Camera** was
   selected (`Found camera: …` / `Camera format selected: …`) — disconnect the
   iPhone / disable Continuity Camera if the system default picks it
   (see the caveat in `docs/baseline_metrics.md` Section 1).
3. Enable debug logging **before** launching the app so the structured events
   are emitted (key read by both the camera metrics and the per-face
   diagnostics paths):

   ```bash
   defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool true
   # … run the app, collect logs, then restore silence:
   # defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool false
   ```

4. Enroll the owner first (M0 protocol) so the owner-recognition path is
   exercised; keep seating distance and lighting consistent between scenarios.
5. Capture the console output for every scenario (Xcode console or
   `Console.app`); each "Actual result" cell must cite the log lines observed.

### Log sources used for verification

| Source | Emitted by | Line shape |
|---|---|---|
| Capture cadence metrics (~every 5 s, debug mode only) | `CameraManager` (M1-T03) | `PS \| event=capture_metrics \| capture_fps=29.8 \| throttled=false \| format=1920x1080@30` |
| Head-pose sanity one-liner (manual checks) | `HeadPoseEstimator.sanityDescription` (M1-T02) | `yaw: +12.3° (right) · pitch: -5.0° (down) · roll: +3.2° (ccw) · confidence: 0.87` |
| Per-face diagnostics event (identity, yaw/pitch/roll, attention score/state, timers) | `DiagnosticsLog` events from the M1-T05/M1-T06 integration | `PS \| event=…` pipe-separated `key=value` fields per processed face (exact event name per the DiagnosticsLog implementation) |

Note: the per-face diagnostics events require the M1-T05/T06 integration to be
merged; scenarios marked with that dependency are blocked until it lands. The
capture-metrics lines are available from M1-T03 alone and double as a health
check for every scenario: `capture_fps` should sit near the configured format
FPS and `throttled=false` in normal room lighting; a persistent
`throttled=true` invalidates the timing expectations below (frames are being
dropped, see `CameraManager.swift` M1-T03 comment).

---

## 2. Regression matrix

Columns "Actual result" and "Pass/Fail" are **filled in during the manual
session**. Expected behaviors follow M1 defaults: attention `looking >= 0.70`,
`notLooking <= 0.45` (else `uncertain`); trigger duration 0.9 s, release 0.6 s
(M1-T07); pose unavailable is treated as `uncertain` (M1-T05).

| # | Scenario | Setup | Expected result | How to verify (debug log lines) | Actual result | Pass/Fail |
|---|---|---|---|---|---|---|
| 1 | Owner only | Only the enrolled owner visible, seated normally; owner deliberately stares straight into the camera for > 3 s | **No trigger ever** — owner/trusted faces bypass the shoulder-surf attention path entirely (even at yaw ≈ 0 looking at the camera) | Per-face diagnostics: identity shows owner/trusted and no attention timer ever starts for that face; shield/blur never activates; `event=capture_metrics` lines continue normally | PENDING(manual) | |
| 2 | Unknown frontal face (sustained) | A second person (not enrolled) sits down facing the screen/head-on to the camera and keeps still, looking at the screen | **Triggers after ~0.8–1.0 s** of sustained frontal pose (attention = `looking`, 0.9 s trigger) | Per-face diagnostics: identity = unknown/other, `attention_state=looking`, yaw/pitch near 0; shield activates ~0.8–1.0 s after the face becomes frontal; timestamp the first `looking` line vs. the activation | PENDING(manual) | |
| 3 | Unknown 45° side face | Same stranger turns head ~45° away from the screen (toward their left or right) and holds it | Attention = `notLooking` **or** `uncertain`; **no trigger** while the pose is held indefinitely | Per-face diagnostics: `attention_state=notLooking` (or `uncertain`) with \|yaw\| well above the ±22° tolerance; no shield activation for the whole hold | PENDING(manual) | |
| 4 | Unknown quick glance | Stranger positioned side-on, then briefly glances at the screen for **< 0.5 s**, returns to side-on; repeat ~5 times | **No trigger** on any repetition (0.9 s trigger is never reached) | Per-face diagnostics: short bursts of `attention_state=looking` each shorter than the trigger duration, followed by `notLooking`; no shield activation across all repeats | PENDING(manual) | |
| 5 | Unknown sustained look (~1 s+) | Stranger side-on, then turns to the screen and holds a frontal gaze for ~1 s before turning away | **Triggers** during the hold; shield releases ~0.6 s after the face clears to `notLooking` | Per-face diagnostics: `looking` persists ≥ trigger duration → activation; then release after the sustained-clear window; compare logged hold duration vs. activation time | PENDING(manual) | |
| 6 | No face (owner absent) | Nobody in frame (owner leaves the desk); camera sees the empty room/scene | **Legacy blur path still triggers** (owner-absent behavior preserved until the M4 policy split) | Per-face diagnostics: zero faces reported (no per-face lines); shield/blur activates via the owner-absent path; note activation latency (baseline frame-count hysteresis, see `docs/baseline_metrics.md` Section 3) | PENDING(manual) | |
| 7 | Low-light room | Dim the room well below normal reading light; stranger sits frontal, looking at the screen | Expected: pose may be **unavailable** → treated as `uncertain` → **no trigger** (degraded detection is acceptable and must be recorded, not silently passes) | Per-face diagnostics / sanity lines: `head pose: unavailable` or `confidence` near low bound; `attention_state=uncertain`; record whether any trigger occurred; check `capture_metrics` for `throttled=true` (longer exposure can lower delivered FPS) | PENDING(manual) | |
| 8 | Backlit face | Bright lamp/window behind the stranger (face in shadow), stranger frontal looking at the screen | Expected: pose unavailable/low-confidence → `uncertain` → **no trigger**; record actual behavior (may still detect if Vision copes) | Same lines as #7: availability/confidence fields, `attention_state`, activation or not; note exposure/throttle state from `capture_metrics` | PENDING(manual) | |
| 9 | Two visible faces (known M1 limitation) | Owner absent; **two** strangers visible, one frontal-looking then the other, alternating | **Known limitation before M2**: the prototype uses a single shared unknown-face timer, so the *either stranger's* looking time feeds the same timer — e.g. A looks 0.5 s, turns away, B looks 0.5 s ≈ one person looking 1.0 s and **may trigger even though neither sustained a look**; conversely a non-looking stranger inherits timer state started by the other. Record which of the two misbehaviors actually occurs and the observed combined-latency | Per-face diagnostics: two faces with different identity/pose fields but a single shared timer — correlate each face's `attention_state=looking` bursts with the single activation timestamp; note that per-person attribution is impossible from these logs (that is the M2 per-track fix) | PENDING(manual) | |

Pass rule: scenarios 1–6 must match "Expected result" to pass; scenarios 7–8
pass when the *actual* behavior is recorded accurately (expected behavior is
"degraded / uncertain", so an unexpected trigger is a finding to file, not
necessarily a protocol failure); scenario 9 always ends as "documented
limitation" until M2-T04 replaces the shared timer.

---

## 3. Yaw / pitch / roll SIGN VALIDATION procedure (run once before trusting any classifier thresholds)

All three angle sign mappings in `HeadPoseEstimator` are **provisional** until
this procedure is executed (the Vision SDK header text and the plan's
assumption disagree for pitch — see the sign-convention comment in
`PrivacyShield/HeadPoseEstimator.swift`).

Documented convention that the code is supposed to satisfy:

- **Positive yaw** = face turned toward **its own left** as seen by the camera.
- **Positive pitch** = **looking up**.
- Positive roll = counterclockwise tilt of the face in the image plane
  (per Vision SDK; confirm while at it).

This must be **empirically confirmed**; do not trust the labels printed next
to the values — they are rendered by `sanityDescription` using the same
provisional convention and will repeat a wrong sign back at you.

### Steps

1. Enable debug logging (Section 1) and run the app.
2. Sit frontal at normal distance, look straight at the camera for ~2 s →
   record the baseline line (expect all three angles near 0).
3. Turn your head clearly to **your own left** (~30–40°), hold ~2 s → record a
   sanity line mid-hold.
4. Turn clearly to **your own right**, hold → record.
5. Tilt your head **up** (chin raised, looking upward), hold → record.
6. Tilt your head **down** (chin tucked), hold → record.
7. Tilt your head ~20° counterclockwise in the image plane (top of head toward
   the camera's left), hold → record.
8. For each step also copy one per-face `DiagnosticsLog` line from the
   integration's per-face event (same moment) so the fields flowing into the
   classifier can be compared against `sanityDescription` output.

### Sign observation table (fill in during the manual session)

| Head action | Expected sign (documented convention) | Sanity log line (copy values) | Per-face DiagnosticsLog yaw/pitch/roll | Observed sign matches? |
|---|---|---|---|---|
| Frontal baseline | yaw ≈ 0, pitch ≈ 0, roll ≈ 0 | PENDING(manual) | PENDING(manual) | |
| Turn own **left** | yaw **positive** | PENDING(manual) | PENDING(manual) | |
| Turn own **right** | yaw **negative** | PENDING(manual) | PENDING(manual) | |
| Look **up** | pitch **positive** | PENDING(manual) | PENDING(manual) | |
| Look **down** | pitch **negative** | PENDING(manual) | PENDING(manual) | |
| Tilt **ccw** in image | roll **positive** | PENDING(manual) | PENDING(manual) | |

### If an observed sign mismatches the documented convention — what to flip in code

Flip **exactly one place per axis**, consistently, and never silently (record
the flip in this document's change notes and in the touched file's
sign-convention comment):

- **Yaw mismatch** (e.g. "turn own left" consistently yields *negative* yaw):
  negate the yaw value where it is converted from radians in
  `HeadPoseEstimator` (`degrees(fromRadians:)` call site), **and** swap the
  `left`/`right` labels in `HeadPoseEstimator.sanityDescription` so logs stay
  truthful. The `AttentionClassifier` then needs no change (its yaw error
  is relative to a calibrated center, so a globally negated axis cancels out),
  but the calibrated `screenCenterYaw` values persisted before the flip must
  be re-collected (M3 calibration) or negated once.
- **Pitch mismatch** (e.g. "looking up" consistently yields *negative* pitch —
  the most likely mismatch, since the SDK header text contradicts the plan's
  assumption): negate the pitch value in `HeadPoseEstimator`, swap the
  `up`/`down` labels in `sanityDescription`, and re-collect any persisted
  `screenCenterPitch` calibration. The M1-T04 working convention
  ("positive pitch = looking up") is what the classifier thresholds are tuned
  against, so the flip belongs in the estimator, not the classifier.
- **Roll mismatch**: negate the roll value in `HeadPoseEstimator` and swap the
  `cw`/`ccw` labels in `sanityDescription` (roll weight is only 0.05 in the
  score, but the labels must not mislead during M3 tuning).
- After flipping, **re-run this Section 3 procedure** and require every row of
  the observation table to match before any M1-T08 matrix run is considered
  valid.

### Status

- [x] Regression protocol + template written (this document).
- [ ] Sign validation executed and table filled — **pending manual execution**.
- [ ] All 9 matrix rows executed with log excerpts — **pending manual execution**.
- [ ] Findings (especially scenarios 7–9) filed back into implementation tasks.
