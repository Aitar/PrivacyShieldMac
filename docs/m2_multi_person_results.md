# M2 Multi-Person Regression Matrix (M2-T08)

> Milestone: M2 — Multi-Person Stability
> Branch: `feature/head-pose-attention`
> Recorded: 2026-10-13 (protocol + template; results pending)
> **Manual execution at the Mac is required.** This document is the regression
> *protocol plus results template*: every row below must be executed by a human
> with one or two helper "strangers" in front of the primary development Mac
> and filled in. Nothing here is verifiable by build or unit tests alone.

Related: `docs/implement_todolist.md` (task definitions, M2-T01–T08, M2 exit
criteria), `docs/m1_head_pose_results.md` (M1 single-face protocol and
defaults), `docs/DEVELOPMENT_PLAN_with_fork.md` Section 17 (1–4 m evaluation
matrix, cases C/G/H/I/J) and Section 10 (Phase 6 tracking),
`PrivacyShield/FaceTracker.swift` (tracks + per-track state, M2-T01–T04),
`PrivacyShield/FaceDetector.swift` (DiagnosticsLog emission, cache integration),
`PrivacyShield/DiagnosticsLog.swift` (event/field definitions, M1-T06),
`PrivacyShield/AttentionTiming.swift` (M1-T07 durations reused per track).

---

## 1. Preconditions (every session)

1. Build from `PrivacyShield.xcodeproj` and run the app locally (menu-bar app,
   camera permission granted). Confirm from the launch log that the **built-in
   FaceTime HD Camera** was selected (see the caveat in
   `docs/baseline_metrics.md` Section 1).
2. Enable debug logging **before** launching the app:

   ```bash
   defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool true
   # … run the app, collect logs, then restore silence:
   # defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool false
   ```

3. Enroll the owner first (M0 protocol) so the owner-recognition + cache paths
   are exercised. Keep seating distance and lighting consistent between rows.
4. Recruit one or two helpers who are **not** enrolled ("stranger A",
   "stranger B"). Canonical positions used by the rows below:
   - **LEFT** / **RIGHT**: chairs ~0.5–1 m to the owner's left/right, both
     inside frame, both clearly visible.
   - **BACKGROUND**: standing 1–2 m behind the owner, smaller in frame.
5. Capture the console output for every scenario (Xcode console or
   `Console.app`); each "Actual result" cell must cite the observed log lines
   (timestamps + `track_id` values), not a bare "worked".
6. **Dependency note:** these rows exercise the M2 integration — tracker
   (M2-T01/T02), per-track attention state (M2-T03), per-track time filter
   (M2-T04), recognition caching (M2-T05/T06) and the per-track debug lines
   (M2-T07). Until those land, the rows are blocked, exactly as the M1 doc
   treated its pre-integration rows. The M1 capture/face events alone cannot
   verify any row of this matrix (per-frame `track_id` indices are not stable
   identities — that limitation is what M2 fixes).

### Log sources used for verification

| Source | Emitted by | Line shape |
|---|---|---|
| Per-face event, one per processed face | `DiagnosticsLog.face` | `ts=… \| event=face \| track_id=<UUID> \| identity=owner\|trusted\|other\|unknown \| face_width=0.312 \| yaw=+12.4 \| pitch=-3.1 \| roll=+0.5 \| attention_score=0.83 \| attention_state=looking \| latency_ms=14.2` (`yaw/pitch/roll/attention_*` = `na` when pose/attention was skipped for an owner/trusted face) |
| Per-track debug line (M2-T07) | M2 debug instrumentation | pipe-separated line per track with: track UUID short form, identity, bbox, `lastSeen` age, attention score/state, looking duration, last identity check age (exact event name/field spellings per the M2-T07 implementation) |
| Transition events | `DiagnosticsLog.transition` | `ts=… \| event=alert_on \| track_id=<UUID> \| detail=…` (per-track filter transitions); `event=alert_off`; `event=legacy_shield_on/off` (owner-absent path) |
| Throughput summary (~every 2 s, debug only) | `DiagnosticsLog.metrics` | `ts=… \| event=metrics \| vision_fps=14.8 \| latency_ms=15.1 \| faces=3` |

Defaults used in the expected results (M1-T07 profile, instantiated **per
track** by M2-T04): trigger 0.9 s, release 0.6 s, uncertain grace 0.35 s;
classifier bands (M1): `looking` >= 0.70, `notLooking` <= 0.45, else
`uncertain`. Cache cadence (M2-T05): new track → recognize immediately;
owner/trusted revalidate ~2–3 s; other ~1–2 s.

---

## 2. Regression matrix

Columns "Actual result" and "Pass/Fail" are **filled in during the manual
session**. In every row, "track" means a stable per-person UUID — quote the
short UUIDs you observed (e.g. "A=3F2A…, B=91C4…").

| # | Scenario | Setup | Expected result | How to verify (debug log lines) | Actual result | Pass/Fail |
|---|---|---|---|---|---|---|
| 1 | Owner + one stranger **looking** | Owner seated at the desk (enrolled). Stranger A sits at LEFT, facing the screen, sustained frontal gaze > 3 s | Shield triggers after ~0.8–1.0 s, driven **only** by A's track. Owner never contributes time even though they also look at the screen | Two distinct `track_id` UUIDs throughout. Owner lines: `identity=owner`, `attention_score=na`, `attention_state=na` (pose path skipped). A's lines: `attention_state=looking`, looking duration climbing; `event=alert_on` carries **A's** `track_id` ~0.9 s after A first looks; timestamp first A-looking line vs. alert_on | PENDING(manual) | |
| 2 | Owner + one stranger **not looking** | Same, but A keeps head turned away from the screen (toward their own left/right, \|yaw\| well above tolerance) indefinitely | **No trigger ever.** A's non-looking pose must never fire, and the owner's gaze must not fire either | A's lines: `attention_state=notLooking` (or `uncertain`), looking duration stays ~0; owner lines `attention_*` = `na`; **no** `event=alert_on` for any `track_id` for the whole hold; `event=metrics` continues | PENDING(manual) | |
| 3 | Owner + two strangers, **one looking** | Owner at desk; A at LEFT looking at the screen; B at RIGHT turned away. Hold > 3 s | **Triggers from A's track only** (M2-T04: any qualifying non-owner track alerts; B contributes nothing). Shield releases ~0.6 s after A clears | Three distinct UUIDs. A: `looking` + duration growth → `alert_on` with A's `track_id`; B: `notLooking`, duration ~0 for the entire window; owner: `attention_*`=`na`. On `alert_off`, detail identifies A's track clearing after the release window; B's duration stayed 0 throughout | PENDING(manual) | |
| 4 | Owner + two strangers, **neither looking** | Owner at desk; A and B both turned away. Then optionally let each take one brief < 0.5 s glance, alternating | **No trigger at all** — and decisively: A's 0.5 s + B's 0.5 s must **never** sum into a 1.0 s alert (the M1 shared-timer misbehavior, M1 doc row 9, must be gone) | Per-track lines: each track's looking duration individually stays below the 0.9 s trigger; no `alert_on` for any `track_id` across the alternating glances; B's duration never moves when A glances and vice versa | PENDING(manual) | |
| 5 | Two strangers **swap horizontal positions** | A at LEFT, B at RIGHT, both visible ~5 s; then they physically swap seats (standing/crossing slowly), settle, and remain visible ~5 s | **IDs must not swap**: each person keeps their UUID across the crossing. (If the crossing momentarily occludes one face, row 6's short-gap retention should carry the track through; a genuinely new UUID born at the crossing is an association failure — record it as a finding) | From per-track lines: follow each UUID's bbox x over time — A's UUID should sweep left→right **continuously**, B's right→left; the two UUIDs never exchange identities or jump. Count distinct UUIDs before/during/after: expected 2 throughout (3 at any moment = a spurious re-track) | PENDING(manual) | |
| 6 | Person **briefly occluded** (short gap) | A at LEFT looking at the screen; after ~1 s hold, slide a folder/paper in front of A's face for < ~1 s (within the tracker's max short detection gap), then remove it; A resumes the same gaze | **Same UUID before and after the gap** (M2-T02 retains tracks across short missed-detection gaps). The attention timer must not spuriously fire or fully reset purely because of the gap; record whether it held (uncertain-grace semantics) or reset | During the gap: no `event=face` lines for A's UUID, while the per-track line shows `lastSeen` age climbing (~0.3 s, 0.6 s, …); on reappearance the **same** UUID resumes — compare looking duration / `lookingSince` before vs. after and record which. A **new** UUID appearing = fail for this row | PENDING(manual) | |
| 7 | Person **leaves and re-enters** (long absence) | A walks fully out of frame for > 5 s (well past the expiry policy), then walks back and sits again | A **new track ID on return is acceptable/expected** (stale track expired). Identity must resolve immediately on return (M2-T05: new track → recognize immediately); any alert state tied to the old track cleared while A was gone | Old UUID's lines stop after expiry (per-track line shows `lastSeen` age growing until the track disappears); on return a **different** UUID appears whose first line already carries the correct identity and `last identity check age ≈ 0`. If an `alert_on` fired while A was absent with A's old track_id, record as finding | PENDING(manual) | |
| 8 | **Owner turns sideways** | Owner alone (or with strangers seated out of gaze) rotates head through: 45°, full profile, and facing away from the camera; holds each ~2 s | **Owner never triggers shoulder-surf in any pose** — the owner path bypasses the attention classifier entirely, so even a "looking-at-camera-frontally-equivalent" sideways pose must not alert | Every owner line: `identity=owner`, `yaw/pitch/roll` may be `na` (pose skipped), `attention_score=na`, `attention_state=na` in all head positions; **no** `alert_on` ever carries the owner's `track_id` | PENDING(manual) | |
| 9 | Stranger **walks across background laterally** | Owner seated looking at screen; stranger B crosses the frame left→right through the BACKGROUND (~1–2 m behind owner), transit ~2–4 s, not approaching the screen | **No trigger** (plan Section 17 Case C). B's face may incidentally read `looking` for a moment, but transit time is far below the 0.9 s trigger | B's UUID appears, bbox x sweeps across the frame over a few seconds, then expires after exit. Any `looking` bursts on B's track stay shorter than the trigger; looking duration never approaches 0.9 s; **no** `alert_on` for B's `track_id` | PENDING(manual) | |

Pass rule: rows 1–5, 8–9 must match "Expected result" to pass. Row 6 passes
when the same UUID survives the gap **and** the actual timer behavior
(hold vs. reset) is recorded accurately — a new UUID at reappearance is a
fail. Row 7 always records a new UUID (expected); it fails only if identity
does not resolve promptly or the expired track kept alerting.

---

## 3. How to debug from logs alone

With debug logging enabled (`debugLoggingEnabled`, Section 1), a multi-person
run should be fully explainable from the console without watching the screen:

- **Per-face events** (`event=face`): one line per processed face carrying
  `track_id` (tracker UUID, short form), `identity`
  (`owner`/`trusted`/`other`/`unknown`), bbox, `face_width`, `yaw`/`pitch`/
  `roll` (degrees; `na` when Vision supplied no pose or the pose path was
  skipped for an owner/trusted face), `attention_score`/`attention_state`,
  looking duration, and `latency_ms`.
- **Transition events**: `alert_on` / `alert_off` are logged per attention
  transition with the responsible `track_id` and a `detail=` payload (per-track
  filter state); `legacy_shield_on`/`legacy_shield_off` mark the separate
  owner-absent blur path; `metrics` reports `vision_fps`, `latency_ms`,
  `faces` every ~2 s.
- **M2 debug instrumentation (M2-T07)** adds per-track lines with the track
  UUID short form, identity, bbox, **`lastSeen` age**, attention score/state,
  **looking duration**, and **last identity check age**. The identity-check
  age is the window into the M2-T05/T06 cache: a new track should show ~0 s
  (recognized immediately), then settle into the policy cadence (owner/trusted
  ~2–3 s, other ~1–2 s; exact constants per config).

Example interpretations:

1. **Alert attribution.** You see `track A … looking` with looking duration
   1.2 s while `track B … notLooking 0.3 s`, followed by `event=alert_on`.
   The alert **must** be attributed to A: `alert_on` should carry A's
   `track_id`. If `alert_on` names B, or carries no `track_id`, per-track
   attribution is broken (M2-T04 regression — file it).
2. **Timer non-inheritance.** A looks 0.5 s then goes `notLooking`; B then
   looks 0.5 s. Neither per-track looking duration may reach 0.9 s and no
   `alert_on` may appear. If an `alert_on` fires at a combined ~1.0 s, the
   M1 shared-timer bug (M1 doc row 9) is back — the per-track filters are
   being fed from aggregate state instead of each track's own history.
3. **Gap vs. re-entry from field ages alone.** Track X's `event=face` lines
   stop, but its per-track line shows `lastSeen` age climbing to ~0.8 s and
   then the **same** UUID resumes → row 6's short-gap retention worked. If
   instead the `lastSeen` age exceeds the expiry threshold, the line
   disappears, and a **new** UUID appears later with `last identity check
   age ≈ 0` → that is the row 7 leave/re-enter pattern. The tell is the
   identity-check age: ~0 on the new track means the cache recognized the
   new track immediately (M2-T05 "new track → recognize immediately");
   a resumed UUID whose `last identity check age` is far beyond the policy
   window means revalidation-on-gap-resume did not run.

Sanity check for every row: `event=metrics` should keep `faces=` matching the
number of people actually in frame and `vision_fps`/`latency_ms` steady
(comparing against the M1 session's values doubles as the CPU-no-worse-than-M1
check in Section 4).

---

## 4. Milestone 2 acceptance mapping

Each M2 exit criterion (see `docs/implement_todolist.md`, "Milestone 2 Exit
Criteria") and the matrix row(s) that evidence it:

| M2 exit criterion | Evidenced by | What the row must show |
|---|---|---|
| Stable per-face track IDs exist | Rows 5, 6, 7 | UUIDs persist across position swap (5) and short occlusion (6); a deliberately new UUID only on true re-entry (7) |
| Per-track timers are independent | Rows 3, 4 | Alert fires from the looking track only (3); A's + B's glances never sum to a trigger (4) |
| Recognition is cached | Rows 6, 7 (+ all rows) | Identity survives short gaps without re-recognition; `last identity check age` follows the 2–3 s / 1–2 s cadence instead of per-frame checks; new track recognized immediately (7) |
| Two or more people can be processed simultaneously | Rows 1–4 | 2–3 simultaneous `track_id`s in `event=face` lines; `metrics faces=2/3` matches reality |
| Any qualifying stranger can trigger | Rows 1, 3 | The trigger follows whichever stranger's track qualifies (A's `track_id` on `alert_on`), not a fixed "first face" |
| Non-looking strangers do not inherit another person's timer | Rows 2, 3, 4 | B at `notLooking` shows looking duration ~0 while A alerts (3); no combined-duration trigger (4) |
| CPU no worse than the M1 prototype despite additional state | All rows | `event=metrics` `vision_fps` and `latency_ms` at 2–3 faces compare favorably with the values recorded in the M1 session (`docs/m1_head_pose_results.md`); no sustained degradation as tracks/caches grow |

Mapping to plan Section 17 cases (Phase 13 repeats these at 1–4 m; the rows
here fix the multi-person semantics at desk distance): Case C (walking past
sideways) ↔ row 9; Case G (owner only) ↔ M1 doc row 1, reinforced by row 8;
Case H (owner + stranger looking elsewhere) ↔ row 2; Case I (owner + stranger
looking) ↔ row 1; Case J (two strangers, one looking) ↔ row 3.

---

## Status

- [x] Regression protocol + template written (this document).
- [ ] M2 tracker / per-track filters / cache / debug instrumentation landed
      (M2-T01–T07) — rows blocked until then.
- [ ] All 9 matrix rows executed with log excerpts — **pending manual
      execution**.
- [ ] Findings (especially any UUID swap in row 5 or timer inheritance in
      row 4) filed back into implementation tasks.
