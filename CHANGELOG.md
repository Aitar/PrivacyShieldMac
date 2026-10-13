# Changelog

All notable changes to Privacy Shield for macOS are documented here.
The app is a macOS menu-bar utility; releases correspond to the milestone
branches of the development plan (`docs/DEVELOPMENT_PLAN_with_fork.md`).

## [1.1.0] — 2026-10-13 — feature/head-pose-attention (Milestones M1–M4)

Attention-aware privacy shielding: the app now distinguishes *who* is in
frame, *where* they sit and *whether they are looking at the screen* — and
blurs with an explanation.

### Added

- **Head-pose attention detection (M1):** Vision-based yaw/pitch/roll per face
  (degrees), a rule-based weighted attention classifier measured against the
  calibrated screen direction, and a wall-clock temporal filter — a non-owner
  looking toward the screen for a sustained period (default ~0.9 s) triggers
  the shield; owner and trusted faces never trigger the shoulder-surf path.
  Missing pose is kept explicitly "unavailable" and never faked as frontal.
- **Per-person tracking (M2):** a lightweight greedy tracker (IoU/center/size)
  gives every visible person a stable track with its own identity, attention
  score and timer — multiple people are tracked independently and never share
  accumulation time; the shield stays up until the last qualifying watcher
  clears.
- **Recognition caching (M2):** identities are revalidated per state (owner/
  trusted every ~2.5 s, strangers ~1.5 s) with early triggers for position
  jumps, size changes and reappearances, plus hysteresis so one bad frame
  cannot demote the owner — recognition no longer runs on every frame.
- **Screen-direction calibration (M3):** "Calibrate Screen Direction…" records
  your normal working posture (~3 s, median with MAD outlier rejection) and
  persists it; the classifier measures "looking at the screen" relative to
  that center instead of a hard-coded frontal pose.
- **Distance bands + adaptive policy (M3):** normalized face width maps each
  person to near/mid/far (≈1–2/2–3/3–4 m) with hysteresis; angular tolerances
  and trigger durations adapt per band (farther = looser + slower). Faces too
  far to judge reliably stay uncertain and can never trigger.
- **Settings UI (M4):** menu-bar settings — Shoulder Surf Detection, Blur When
  I Leave, Blur When Someone Watches, Attention Sensitivity presets
  (Conservative/Balanced/Sensitive), a Looking Duration override (0.5–1.5 s),
  Launch at Login — all persisted in UserDefaults and live-applied; settings
  survive restarts.
- **Debug preview (M4):** optional on-screen overlay (Debug Preview…) showing
  per-face track ID, identity, face width + distance band, head pose,
  attention score/state and looking duration, plus global FPS/latency/track/
  camera-format diagnostics; a pure sink that never alters detection and never
  steals keyboard focus.
- **Structured debug logs (M1/M2):** pipe-separated one-line events (`track`,
  `recognition`, `alert_on`/`alert_off`, `band_change`,
  `screen_calibration_on/off`, `metrics`) gated by the
  `debugLoggingEnabled` UserDefaults flag, default off and silent.

### Changed

- **Independent privacy policies (M4):** "owner absent" and "shoulder surfer"
  are decided separately (previously one conflated "no face at all" rule) —
  an unknown person present but not looking no longer blurs by itself, an
  owner present no longer masks a stranger who *is* looking, and either blur
  behavior can be toggled independently.
- **Reason-aware notifications (M4):** notifications now say why the shield
  engaged (observer detected / owner away / both) with anti-spam gating: at
  most one notification per shield episode, per-reason de-duplication and a
  minimum interval between reason-change updates; the menu status line shows
  the same state (plus dedicated Calibrating and Camera-unavailable states).
- **1080p capture (M1):** the camera now prefers 1920×1080 @ 30 FPS (fallbacks:
  1080p @ 15 FPS, then the highest stable format capped at 30 FPS) instead of
  the session default, for reliable head pose at 1–4 m.

### Performance

- Frame throttling (every 3rd frame processed) plus recognition caching keeps
  per-frame work bounded; recognition runs per track roughly every 1.5–2.5 s
  instead of every frame.
- Debug logging and the debug preview are fully inert when disabled (no string
  building, no window); capture metrics log at a ~5 s cadence only when
  enabled.
- V1 acceptance targets (owner false-trigger < 0.5 %, passer-by < 2 %, 1–3 m
  recall > 95 %, 4 m > 85 %, background CPU < 15 % on Apple Silicon) remain
  engineering goals pending the manual evaluation — see
  `docs/performance_report.md`.

### Known limitations

- Head pose is **not** eye-gaze estimation: a frontal head with sideways eyes
  can be missed (accepted V1 limitation; optional V2 refinement sketched in
  the development plan, §22).
- Distance-band width boundaries are camera-dependent (Continuity Camera vs.
  built-in); recalibrate after changing cameras.
- Physical performance targets and the multi-person edge-case matrix await
  manual validation at the Mac (`docs/m1_head_pose_results.md`,
  `docs/m2_multi_person_results.md`).

## [1.0.0] — baseline

Initial release: menu-bar app with camera monitoring, face enrollment (owner +
trusted faces), instant fullscreen blur across all displays on an unrecognized
face, global hotkey (⌘⇧L), notifications, Launch at Login, frame throttling
and a menu-bar status icon.

[1.1.0]: # "branch feature/head-pose-attention"
[1.0.0]: # "main baseline"
