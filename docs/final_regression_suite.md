# Final Regression Suite (M4-T07)

> Milestone: M4 — UX Integration & Release Prep
> Branch: `feature/head-pose-attention`
> Recorded: 2026-10-13 (protocol + results template; results pending)
> **Manual execution at the Mac is required.** This document is the regression
> *protocol plus results template*: every row below must be executed by a human
> in front of the primary development Mac (with helper "strangers" for the
> multi-person rows) and filled in. Nothing here is verifiable by build or
> unit tests alone.

Related: `docs/implement_todolist.md` (task definitions M4-T01–T07, Milestone 4
Exit Criteria), `docs/m1_head_pose_results.md` (M1 single-face protocol),
`docs/m2_multi_person_results.md` (M2 multi-person semantics),
`docs/evaluation_protocol_1_4m.md` (1–4 m range protocol),
`PrivacyShield/AppDelegate.swift` (menu, settings, notifications,
launch-at-login), `PrivacyShield/PrivacyStateMachine.swift` (independent
policies, display states), `PrivacyShield/AttentionSettings.swift`
(`attention.*` persistence), `PrivacyShield/ScreenDirectionCalibration.swift`
(`screenCenter*` persistence), `PrivacyShield/DebugPreview.swift` (overlay),
`PrivacyShield/CameraManager.swift` (capture metrics),
`PrivacyShield/FaceDetector.swift` (M4-T06 integration, structured log events),
`PrivacyShield/ShieldManager.swift` (per-display overlays).

---

## 1. Preconditions (every session)

1. Build from `PrivacyShield.xcodeproj` with current Xcode and run the app
   locally (menu-bar app). Confirm from the launch log that the **built-in
   FaceTime HD Camera** was selected (`Found camera: …` /
   `Camera format selected: …`) — disconnect the iPhone / disable Continuity
   Camera if the system default picks it (see `docs/baseline_metrics.md`
   Section 1).
2. Enable debug logging **before** launching the app so the structured events
   are emitted:

   ```bash
   defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool true
   # … run the app, collect logs, then restore silence:
   # defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool false
   ```

   The `debugLoggingEnabled` flag also reveals the debug-only menu line
   "Screen center: yaw …, pitch …" (tag 400) — useful for row 6.
3. Capture the console output for every row (Xcode console or `Console.app`);
   each "Actual" cell must cite the observed log lines / menu titles / keys,
   not a bare "worked".
4. Enroll the owner before the behavioral rows (row 3) so owner recognition
   is exercised; recruit one or two helpers who are **not** enrolled
   ("stranger A", "stranger B"). Keep seating distance and lighting
   consistent; re-run *Calibrate Screen Direction…* at session start (row 6).
5. UserDefaults keys can be inspected/reset between rows with
   `defaults read/write/delete com.siluna.PrivacyShield <key>`; the bundle of
   persisted settings lives under the `attention.*` prefix
   (`AttentionSettingsStore`), the calibrated center under
   `screenCenterYaw` / `screenCenterPitch` / `screenCenterCalibratedAt`
   (`ScreenCenterStore`), `launchAtLogin`, and `minFaceSize` (range
   calibration). Enrollment prints are a **file**, not defaults:
   `~/Library/Application Support/PrivacyShield/enrolled_faces.dat`
   (`FaceRecognizer.storageURL`).

### Log sources used for verification

| Source | Emitted by | Line shape |
|---|---|---|
| Per-face event, one per processed face | `DiagnosticsLog.track` | `ts=… \| event=track \| track_id=A1B2C3D4 \| identity=owner\|trusted\|other\|unknown \| face_width=0.312 \| yaw=+12.4 \| pitch=-3.1 \| roll=+0.5 \| attention_score=0.83 \| attention_state=looking \| looking_duration_ms=540 \| last_seen_age_ms=0 \| identity_check_age_ms=1250 \| latency_ms=14.2` (`attention_*` = `na` for owner/trusted faces) |
| Recognition decisions (cache cadence) | `DiagnosticsLog.recognition` | `ts=… \| event=recognition \| track_id=… \| decision=recognize_now \| reason=… \| identity=owner` |
| Per-track alert transitions | `DiagnosticsLog.transition` | `ts=… \| event=alert_on \| track_id=… \| detail=…` / `event=alert_off` (per-track temporal filter) |
| Privacy decision transitions (aggregate) | `FaceDetector.applyPrivacyDecision` (M4-T06) | `ts=… \| event=shield_on \| detail=reason=shoulder_surfer\|owner_absent\|owner_absent+shoulder_surfer` / `event=shield_off \| detail=reason=none` — the reason string is `PrivacyShieldReason.description` |
| Screen-direction calibration | `FaceDetector` calibration session | `ts=… \| event=screen_calibration_on \| detail=lead_in=2.0s`; `event=screen_calibration_off \| detail=center_yaw=+2.10 center_pitch=-1.00 samples=15 validity=0.94` (failure: `failed_too_few_valid_samples`) |
| Throughput summary (~every 2 s) | `DiagnosticsLog.metrics` | `ts=… \| event=metrics \| vision_fps=14.8 \| latency_ms=15.1 \| faces=2 \| recognitions=3` |
| Capture cadence (~every 5 s) | `CameraManager` (M1-T03) | `PS \| event=capture_metrics \| capture_fps=29.8 \| throttled=false \| format=1920x1080@30` |
| Plain prints (not gated) | `CameraManager` / `AppDelegate` / `FaceRecognizer` | `Camera auth status: …`, `Camera permission result: …`, `Found camera: …`, `Global hotkey ⌘⇧L registered`, `Notification permission: …`, `Enrollment started for 'owner' …`, `Enrollment complete for 'owner'! …`, `All enrollments reset`, `Login item error: …` |

Defaults used in expected results: settings defaults are
`AttentionSettings()` (shoulder-surf on, both blur toggles on, preset
`.balanced`, no duration override, debug preview off); balanced mid-band
trigger 0.9 s / release 0.6 s; owner-presence window 1.5 s with track expiry
1.0 s → owner-absent blur engages ~1.0–1.5 s after the owner leaves;
notification anti-spam gate: one send per reason per episode, ≥ 10 s between
in-episode reason-change updates (`NotificationGate`).

---

## 2. Functional regression matrix (16 cases)

Columns "Actual" and "Pass/Fail" are **filled in during the manual session**.

| # | Case | Setup | Steps | Expected result | How to verify (menu item / key / log line) | Actual | Pass/Fail |
|---|---|---|---|---|---|---|---|
| 1 | First launch | Fresh install: `defaults delete com.siluna.PrivacyShield 2>/dev/null` (no stored keys), no `enrolled_faces.dat` | Launch the app from Xcode (or the built .app); open the status-item menu after the detector starts | Valid defaults with NO registration step: menu shows the full M4-T06 layout; "Shoulder Surf Detection", "Blur When I Leave", "Blur When Someone Watches" checked; "Attention Sensitivity → Balanced" checked; "Looking Duration → Band Default" checked; "Debug Preview…" unchecked; "Status: ✅ Monitoring safe" once the detector reports | Menu titles above; keys: `attention.*` all ABSENT (struct defaults apply); launch log: `Global hotkey ⌘⇧L registered`, `Found camera: …`, `Camera format selected: …`, `Capture session running: true`, `Notification permission: true`; `event=metrics` lines flowing | PENDING(manual) | |
| 2 | Camera permission denied, then enabled | System Settings → Privacy & Security → Camera: set the app to NOT allowed (deny first-time request: log `Camera permission result: false`) | (a) Relaunch the app with permission denied; observe menu + behavior. (b) Grant permission in System Settings, relaunch the app | (a) Status line shows "Status: 📷 Camera unavailable", no frames processed, no shield, no crash. (b) After the grant + relaunch the camera starts and the status returns to "Status: ✅ Monitoring safe" (granting mid-run is not picked up live — the app must be relaunched; record what actually happens) | (a) Menu status line; log `Camera auth status: 2` + `Camera permission denied or restricted…` (AppDelegate reports `.cameraUnavailable` at launch for denied/restricted). (b) Log `Camera auth status: 3` → `Setting up capture session…` → `Found camera: …` → `Capture session running: true`; `event=capture_metrics` resumes | PENDING(manual) | |
| 3 | Owner enrollment | App running, camera granted, nobody enrolled yet | Menu "Enroll My Face" (⌘E); owner looks at the camera until the success toast | Toast "Look at the camera… Enrolling your face" → after 8 samples "✅ Face enrolled successfully!"; from then on the owner's track never triggers (see row 7) | Toasts; log `Enrollment started for 'owner' — look at the camera...`, `Enrollment [owner]: Captured sample N/8`, `Enrollment complete for 'owner'! Total enrolled users: 1`; persistence: `enrolled_faces.dat` exists in `~/Library/Application Support/PrivacyShield/`; `event=track … identity=owner` with `attention_*` = `na` | PENDING(manual) | |
| 4 | Trusted face enrollment | Owner enrolled; helper present | Menu "Add Trusted Face"; the trusted person looks at the camera until the success toast | Toast "Ask the trusted person to look at the camera…" → after 8 samples "✅ Trusted face added!"; the trusted person is treated exactly like the owner (pose path skipped, never triggers, counts as owner-present for row 11) | Toasts; log `Enrollment started for 'trusted_NNNN' …` + `Enrollment complete for 'trusted_NNNN'!` (label is random 1000–9999); `event=track … identity=trusted`; debug preview (row 13) shows TRUSTED with a blue box | PENDING(manual) | |
| 5 | Enrollment reset | At least owner enrolled (row 3) | Menu "Reset All Enrollments" (⌘R); then sit in front of the camera (single person) | Toast "All enrollments reset"; enrollment file removed. While unenrolled, the M1-parity fallback applies: a single face never triggers; MULTIPLE in-range faces count as potential observers (legacy `!isEnrolled && nearbyCount > 1` rule) | Toast; log `All enrollments reset`; `enrolled_faces.dat` gone; `event=track … identity=other/unknown` (no more `identity=owner`); single face: no `event=shield_on`; two faces: `event=shield_on \| detail=reason=shoulder_surfer` | PENDING(manual) | |
| 6 | Screen-direction calibration | Owner seated in normal position; debug logging on | Menu "Calibrate Screen Direction…"; sit still looking at the screen center through the toast + 2 s lead-in + ~3 s collection. Then repeat once covering the camera with a hand to exercise the failure path | Success: toast "✅ Screen direction calibrated — center yaw %+.1f°, pitch %+.1f°". Failure: toast "❌ Calibration failed — not enough valid samples; make sure your face is visible and well lit" and the previously stored center is unchanged | Success log `event=screen_calibration_on \| detail=lead_in=2.0s` then `event=screen_calibration_off \| detail=center_yaw=… center_pitch=… samples=N validity=…`; failure log `screen_calibration_off \| detail=failed_too_few_valid_samples`. Keys: `screenCenterYaw`, `screenCenterPitch`, `screenCenterCalibratedAt` overwritten (read via `defaults read`). Debug menu line (tag 400) "Screen center: yaw …, pitch …" refreshes; toast text matches the stored values | PENDING(manual) | |
| 7 | Owner-only operation | Owner enrolled (row 3), calibrated (row 6), alone at the desk | Owner sits normally, then deliberately stares straight into the camera for > 3 s; repeat at a slight angle | **No trigger ever** — owner/trusted faces bypass the attention classifier entirely (M1/M2 semantics preserved through M4); status stays "Status: ✅ Monitoring safe" | `event=track … identity=owner` with `attention_score=na attention_state=na` in all poses; **no** `event=alert_on` and no `event=shield_on` for the whole session; `event=metrics` continues | PENDING(manual) | |
| 8 | Shoulder surfer | Owner seated (enrolled); stranger A sits down beside/behind facing the screen, sustained frontal gaze > 3 s | Let A hold the gaze until the shield fires, then turn away and hold | Shield blurs after the band trigger (~0.9 s balanced mid) **even though the owner is present**; notification title "⚠️ Privacy Shield" with body "Someone appears to be looking at your screen. Screen has been blurred."; status line "Status: 👀 Observer detected — blurred"; icon eye → eye.slash.fill; releases ~0.6 s after A clears; a second identical episode notifies again (new episode), but no re-notify within one episode for the same reason | A's `event=track … attention_state=looking`, looking_duration_ms climbing past the trigger; `event=alert_on` carries A's `track_id`; `event=shield_on \| detail=reason=shoulder_surfer`; on clear `event=alert_off` + `event=shield_off \| detail=reason=none`; status line back to "Status: ✅ Monitoring safe". Key under test: `attention.blurWhenShoulderSurferDetected` (toggle "Blur When Someone Watches") and master switch `attention.shoulderSurfDetectionEnabled` ("Shoulder Surf Detection") | PENDING(manual) | |
| 9 | Passer-by (lateral walk, no trigger) | Owner seated looking at the screen; stranger B crosses the frame laterally ~1–2 m behind the owner, transit 2–4 s, NOT approaching the screen | Walk B left→right, then right→left; 5 repetitions (plan Case C / S05) | **No trigger** on any repetition — incidental `looking` bursts stay far below the 0.9 s trigger | B's track UUID appears, bbox sweeps across, then expires; any `looking` bursts < trigger duration; **no** `alert_on` for B's `track_id`, **no** `event=shield_on` across all repetitions | PENDING(manual) | |
| 10 | Two strangers (independent timers) | Owner absent from frame OR seated out of gaze; strangers A and B both in frame | (a) A looks at the screen sustained > 3 s while B stays turned away. (b) Then A and B alternate brief < 0.5 s glances, 5 rounds | (a) Shield fires from A's track only; B's looking duration stays ~0. (b) No trigger — A's 0.5 s + B's 0.5 s must **never** sum into a 1.0 s alert (per-track `TemporalAttentionFilter`, M2-T04 semantics must survive the M4 rewrite) | Two distinct `track_id`s throughout. (a) `alert_on` carries A's UUID; B's lines `attention_state=notLooking`, duration ~0. (b) Each track's duration individually stays below the trigger; no `alert_on`/`shield_on` across the alternation | PENDING(manual) | |
| 11 | Owner absent ("Blur When I Leave" on/off) | Owner enrolled; helper stranger C seated facing AWAY from the screen (so shoulder-surf is NOT active) | (a) Toggle ON: menu "Blur When I Leave" checked. Owner leaves the frame for > 5 s while C remains. (b) Owner returns, waits for safe, then unchecks "Blur When I Leave" and leaves again. (c) Re-check the toggle | (a) Shield blurs ~1.0–1.5 s after the owner's track expires — **despite C still being in frame** (a stranger no longer keeps the screen "safe", M4-T03); notification body "You stepped away — screen has been blurred."; status "Status: 🚪 Owner away — blurred". (b) No owner-absent blur for the whole absence (reason stays `.none`; C not looking). (c) Toggle re-checked, checkmark reflects the store | (a) `event=shield_on \| detail=reason=owner_absent` timed ~1.0–1.5 s after the owner's `event=track` lines stop; on return `event=shield_off \| detail=reason=none`. (b) No `shield_on` with `owner_absent`. Key: `attention.blurWhenOwnerAbsent` (read via `defaults read com.siluna.PrivacyShield attention.blurWhenOwnerAbsent`); menu item "Blur When I Leave" checkmark | PENDING(manual) | |
| 12 | User settings persist (toggle + preset + duration + restart) | App running with valid defaults | Set: uncheck "Blur When Someone Watches"; "Attention Sensitivity → Sensitive"; "Looking Duration → 1.5 s". Note the menu checkmarks. Quit the app (⌘Q) and relaunch | After relaunch every checkmark reflects the stored settings (menu rebuilt from the store), and the detector runs with them (applySettings at init): 1.5 s trigger override wins over the preset/band value; sensitive tolerances active. Changing a preset must NOT corrupt the calibrated center (row 6's keys unchanged) | Keys after step 1: `attention.blurWhenShoulderSurferDetected=0`, `attention.sensitivityPreset=sensitive`, `attention.triggerDurationOverride=1.5` (`defaults read`). Relaunch: menu checkmarks; select "Looking Duration → Band Default" → key `attention.triggerDurationOverride` REMOVED (nil override); `screenCenterYaw`/`screenCenterPitch` identical before/after preset change | PENDING(manual) | |
| 13 | Debug preview on/off | App running, debug logging on, owner or stranger in frame | (a) Menu "Debug Preview…" → on. Observe overlay. (b) Toggle off. (c) With overlay ON, quit and relaunch. (d) Confirm normal operation never shows it | (a) Full-screen non-interactive overlay (never takes key focus, clicks pass through): per-face box + label (id, identity, width/band, yaw/pitch/roll, attention score/state, looking duration) + global block (vision fps, latency, tracks, format "—", center yaw/pitch or "not calibrated"). (b) Overlay disappears; per-frame push skipped (render is a no-op while hidden). (c) Overlay auto-restores on launch. (d) Fresh launch with the setting off shows nothing | Menu item "Debug Preview…" checkmark; key `attention.debugPreviewEnabled` (`defaults read`); overlay contents match `event=track` values for the same moment (id/identity/band/pose/score). Global block note: capture FPS + format render "—" (CameraManager metrics are not wired into the preview — record as observed limitation) | PENDING(manual) | |
| 14 | Launch at login | App running | (a) Menu "Launch at Login" → on. (b) Log out/in (or reboot). (c) Toggle off and log out/in again | (a) Checkmark on; app registered as a login item. (b) App launches automatically at login and starts monitoring (status reaches "Status: ✅ Monitoring safe"). (c) Checkmark off; app does NOT auto-launch | Menu item "Launch at Login" (tag 200) state; key `launchAtLogin` (`defaults read`); System Settings → General → Login Items lists the app while on; failure only via log `Login item error: …` (SMAppService); on (b) the same launch log lines as row 1 | PENDING(manual) | |
| 15 | Multi-display shield | Second display connected (or a display-arrangement change available); stranger A present, or use the manual toggle | (a) Trigger the shield (A's sustained gaze, or "Toggle Shield (⌘⇧L)" / menu "Toggle Shield (⌘⇧L)" for the manual path). (b) While the shield is visible, unplug/rearrange the display | (a) Blur overlay covers EVERY connected screen. (b) Shield windows are rebuilt for the new arrangement and the shield stays shown (re-shown after the rebuild). Note: the manual toggle shows the generic fallback status "Status: ⚠️ Shield active" (icon-only signal); record which path was used | Visual: one hud-material overlay per `NSScreen.screens` (ShieldManager rebuilds on `didChangeScreenParametersNotification`). Log: state path via `event=shield_on \| detail=reason=…` (policy path) — the manual toggle bypasses the reason path, status line shows the generic fallback. Known limitation to record if seen: the debug preview overlay covers only `NSScreen.main` | PENDING(manual) | |
| 16 | Long-running background session (30+ min) | Owner at the desk doing normal work; app in BACKGROUND (other apps frontmost); debug logging on | Leave the app monitoring ≥ 30 min (target 60) with occasional owner leave/return and stranger walk-throughs; keep the console captured | App never terminates, never naps (App Nap disabled via `beginActivity`), shield keeps working identically at minute 30+: owner-only stays safe, stranger gaze still triggers, owner-away still blurs; no log flood | Log continuity: `event=capture_metrics` + `event=metrics` lines present at start AND at minute 30+ with steady values; transition events (`shield_on/off`) still firing on late provocations; Activity Monitor shows the app alive with "Prevent App Nap" behavior. This row doubles as the harness for all 5 performance checks (Section 3) | PENDING(manual) | |

Pass rule: all 16 rows must match "Expected result" to pass. Degraded
detection under low light/backlight follows the M1 doc rule (record the
actual behavior; an unexpected trigger is a finding to file). Any row that
fails blocks the release candidate — file the finding against the M4 task
that owns the behavior.

---

## 3. Performance checks (manual measurement)

All five checks run against the row 16 long-running session (≥ 30 min,
background app, debug logging on, console captured). Status of every check:
**PENDING(manual)**.

| # | Check | Measurement method | Expected criteria | Actual | Pass/Fail |
|---|---|---|---|---|---|
| P1 | 30+ minute monitoring stability | The row 16 session itself: app stays in background ≥ 30 min; console timestamps prove continuous event flow from launch to end | No crash, no termination, no App Nap suspension: `event=capture_metrics` (~5 s cadence) and `event=metrics` (~2 s cadence) lines present at minute 0, 15, and 30+; shield transitions still fire on late provocations | PENDING(manual) | |
| P2 | No obvious memory growth | Activity Monitor → Memory column of the app at minute 0 / 15 / 30 (record all three); optionally Instruments → Allocations for growth attribution across track churn (repeated walk-throughs exercise track creation/expiry) | Footprint rises briefly then PLATEAUS; no steady monotonic climb across the session. Record: start / mid / end MB. A consistent climb correlated with track count is a finding (suspect the tracker/filter dictionaries) | PENDING(manual) | |
| P3 | CPU within target (< 15% average) | Activity Monitor → % CPU, sampled over the session (or Instruments → Time Profiler on the `com.privacyshield.videoqueue` + Vision activity for attribution); compare 1-face vs 2-3-face segments | Average % CPU < 15% over the sustained session with 1–3 faces; no sustained upward drift as tracks/filters accumulate. Record: average and peak per segment | PENDING(manual) | |
| P4 | No capture queue backlog | Audit `event=capture_metrics` lines: `capture_fps` vs `format=1920x1080@30`, `throttled` flag; audit `event=metrics` `latency_ms` / `vision_fps`. Because `alwaysDiscardsLateVideoFrames=true` silently drops late frames, a backlog manifests exactly as measured FPS < 90% of configured → `throttled=true` | `throttled=false` throughout under normal lighting; `capture_fps` stable near 30; `latency_ms` steady (no upward creep); brief `throttled=true` under low light is a recorded caveat, not a fail (per the M1 doc) | PENDING(manual) | |
| P5 | No repeated notification storm | Audit the captured console + notification center during episodes with rapid state churn (owner leaving/returning repeatedly; stranger toggling gaze across the release threshold): count posted notifications ("⚠️ Privacy Shield") vs `event=shield_on/off` transitions | Anti-spam gate holds: ≤ 1 notification per reason per episode; ≥ 10 s between two in-episode reason-change updates; episode close (safe) resets cleanly so the NEXT episode notifies again. Fail signal: two notifications for the same reason without an intervening `shield_off`, or one notification per `shield_on` burst | PENDING(manual) | |

---

## 4. Milestone 4 exit criteria mapping

Each M4 exit criterion (see `docs/implement_todolist.md`, "Milestone 4 Exit
Criteria") and the suite row(s) that evidence it:

| M4 exit criterion | Evidenced by | What the row(s) must show |
|---|---|---|
| Shoulder-surf and owner-away policies are independent | Rows 8, 11 (+ 10) | Surfer blurs while the owner is present (8); owner-away blurs while a non-looking stranger remains (11a); the two toggles gate their own policy only — with "Blur When I Leave" off the owner absence never blurs, with "Blur When Someone Watches" off the surfer never blurs, and the reason strings on `shield_on` stay single-cause (`owner_absent` / `shoulder_surfer`) unless both demand a blur simultaneously |
| User can calibrate and configure behavior | Rows 6, 12 (+ 3, 4, 5, 14) | Screen-direction calibration persists `screenCenterYaw`/`screenCenterPitch` and survives a failed attempt (6); toggles + preset + duration round-trip a restart through the `attention.*` keys and reach the runtime (12); enrollment/reset and launch-at-login are user-operable (3, 4, 5, 14) |
| Debug view is available but optional | Row 13 (+ 1) | Overlay shows per-face + global diagnostics on demand (13a), auto-restores only when enabled (13c), is absent in normal menu-bar-only operation (13d / row 1 default off) and never alters detection decisions |
| Notifications explain why shield activated | Rows 8, 11 (+ 2, 7) | Reason-specific bodies ("Someone appears to be looking…" / "You stepped away…") match the `reason=` payload of the triggering `shield_on` and the menu status line; safe/calibrating/camera-unavailable states never notify (2, 7); anti-spam gate holds (P5) |
| Regression suite passes | All of Section 2 (16 rows) + Section 3 (5 checks) | Every row's Pass/Fail column filled with pass; findings filed back into implementation tasks otherwise |
| README documents expected operating range and limitations | M4-T08 (documentation task, outside this suite) — evidence supplied by rows 9, 15, 16 and P1–P4 | The suite supplies the verified facts the README must restate: 1–4 m band behavior (rows 7–10; full matrix in `docs/evaluation_protocol_1_4m.md`), degraded pose under low light/backlight, head pose ≠ eye gaze (S13 limitation probe), debug-preview capture-FPS "—" and single-screen overlay limitations (13, 15), and the measured CPU/memory numbers (P2, P3) |

---

## Status

- [x] Regression protocol + template written (this document).
- [ ] All 16 functional rows executed at the Mac with log/menu/key evidence —
      **pending manual execution**.
- [ ] All 5 performance checks measured during the row 16 session —
      **pending manual execution**.
- [ ] Milestone 4 exit criteria signed off against the filled matrix
      (Section 4).
- [ ] Findings filed back into implementation tasks; README claims cross-read
      against the verified results (M4-T08).
