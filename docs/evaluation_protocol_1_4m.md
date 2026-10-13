# 1–4 m Evaluation Protocol & Harness (M3-T05)

> Milestone: M3 — 1–4 m Calibration & Tuning
> Branch: `feature/head-pose-attention`
> Recorded: 2026-10-13 (protocol + harness template; results pending)
> **PENDING(manual).** Nothing in this protocol is executable by build or unit
> tests alone: the width distributions (Section 6) and the full scenario
> matrix (Section 4) must be executed by a human in front of the primary
> development Mac and recorded into `docs/evaluation_results.csv`.

Related: `docs/implement_todolist.md` (M3-T05 definition, M3-T06 targets,
M3-T03 width data), `docs/DEVELOPMENT_PLAN_with_fork.md` Section 17 (cases
A–J) and Section 18 (acceptance targets), `docs/m1_head_pose_results.md` and
`docs/m2_multi_person_results.md` (scenario semantics at desk distance),
`docs/baseline_metrics.md` (machine + camera caveats),
`PrivacyShield/DiagnosticsLog.swift` (event/field definitions),
`PrivacyShield/HeadPoseEstimator.swift` (pose sign convention),
`PrivacyShield/ScreenDirectionCalibration.swift` + `AppDelegate.swift`
(M3-T01/T02 screen-center calibration menu action).

---

## 1. Purpose

Provide a repeatable harness for the 1–4 m tuning pass (M3-T06):

1. Fix **what** is recorded for every trial and **where each value comes
   from** (Sections 3–4), so any two sessions are comparable.
2. Fix **how** latency is measured and **what "pass" means** (Section 5),
   per the M3-T06 targets.
3. Produce the **raw face-width distributions** at 1/2/3/4 m that M3-T03
   needs to set the near/mid/far band boundaries (Section 6).

Primary development Mac (see `docs/baseline_metrics.md` Section 1):
`Mac15,12` (14-inch MacBook Pro, Apple M3, 24 GiB, macOS 27.0.1), built-in
**FaceTime HD Camera**; an iPhone **Continuity Camera** is also registered on
this machine — see the camera caveat in Section 2.

---

## 2. Session metadata (record once per session, repeat per lighting/camera change)

Every session starts by filling this fixed metadata block (top of the session
notes; it is the join key for all CSV rows of that session):

| Field | Allowed values / format | How to obtain |
|---|---|---|
| `date` | `YYYY-MM-DD` | Session date |
| `build/commit` | branch + short commit hash | `git rev-parse --short HEAD` on the built tree; the app run must be built from exactly this commit |
| `camera` | `FaceTime HD` or `Continuity` | Launch log line `Found camera: …` — the app grabs the *system default* camera and an iPhone Continuity Camera is also registered on this Mac, so **disconnect the iPhone** unless Continuity is explicitly the device under test; never trust the assumption |
| `distance` | `1` / `2` / `3` / `4` (meters) | Tape measure, **camera lens to face plane**; mark the floor positions with tape once per session |
| `lighting` | `indoor-day` / `indoor-evening` / `low-light` / `backlit` (or a short free-text note) | Record window/lamp state; hold constant within a distance sweep |
| `num_faces` | integer | People actually in frame; cross-check `event=metrics … faces=N` lines |
| `identity` | `owner` / `stranger` / `owner+stranger` / `stranger+stranger` | Owner = enrolled via the M0 protocol; stranger(s) = helper(s) **not** enrolled; cross-check `event=track … identity=` |
| `screen-center calibration` | calibrated yaw/pitch values + time | Re-run *Calibrate Screen Direction…* (M3-T02) at session start and after every lighting change; record the persisted center shown in debug mode |
| `app settings snapshot` | sensitivity preset, trigger/release durations, debug flag | Note the active preset/durations so threshold revisions during M3-T06 are attributable |

Log capture setup (every session, before launching the app):

```bash
defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool true
# … run the app, capture the console (Xcode console or Console.app), then restore:
# defaults write com.siluna.PrivacyShield debugLoggingEnabled -bool false
```

Debug logging must be enabled **before** launch (`DiagnosticsLog` reads the
`debugLoggingEnabled` UserDefaults key and every emitter is gated on it).
Confirm a few `event=track` lines appear before starting any timed trial.

---

## 3. Captured fields per trial and how each is obtained

One CSV row per trial (= one scenario repetition, Section 5.4). The CSV header
in `docs/evaluation_results.csv` is:

```text
distance_m,lighting,camera,num_faces,identity,yaw_deg,pitch_deg,roll_deg,face_width,attention_score,attention_state,triggered,trigger_latency_ms,expected,actual,notes
```

All per-track values come from the structured debug log (M1-T06, reworked
per-track in M2-T07). Line shapes (from `PrivacyShield/DiagnosticsLog.swift`):

```text
ts=2026-10-13T10:12:33.412Z | event=track | track_id=A1B2C3D4 | identity=other | face_width=0.312 | bbox=0.20,0.30,0.20x0.25 | yaw=+12.4 | pitch=-3.1 | roll=+0.5 | attention_score=0.83 | attention_state=looking | looking_duration_ms=540 | last_seen_age_ms=0 | identity_check_age_ms=1250 | latency_ms=14.2
ts=… | event=alert_on  | track_id=A1B2C3D4 | detail=…
ts=… | event=alert_off | track_id=A1B2C3D4 | detail=…
ts=… | event=metrics | vision_fps=14.8 | latency_ms=15.1 | faces=2 | recognitions=3
```

| CSV field | Meaning | Exactly how it is obtained |
|---|---|---|
| `distance_m` | Nominal test distance | Session metadata (tape-measured, Section 2) |
| `lighting` | Lighting condition | Session metadata |
| `camera` | Camera under test | Session metadata (launch log confirmed) |
| `num_faces` | People in frame for this trial | Scenario definition; cross-check `event=metrics faces=N` |
| `identity` | Role mix of the trial | Session metadata (owner enrolled / strangers not) |
| `yaw_deg`, `pitch_deg`, `roll_deg` | Head pose of the qualifying track, degrees | From the `event=track` lines of the relevant `track_id`: copy the representative (mid-hold) values, e.g. `yaw=+2.1 pitch=-1.0 roll=+0.4`. `na` when Vision supplied no pose — record `na` and treat the trial as degraded, never as 0 |
| `face_width` | Normalized face bbox width of the qualifying track | `event=track … face_width=0.312` (mid-hold value). Camera-specific normalization — do not compare across cameras |
| `attention_score` | Classifier score of the qualifying track | `event=track … attention_score=0.91`. `na` for owner/trusted tracks (pose path skipped) |
| `attention_state` | `looking` / `notLooking` / `uncertain` | `event=track … attention_state=looking` (representative state during the hold; `na` for owner/trusted) |
| `triggered` | Did the shield fire from a qualifying (non-owner) track? | `yes` iff an `event=alert_on` line appears during the trial window carrying a non-owner `track_id`; otherwise `no` |
| `trigger_latency_ms` | Scenario start → alert | `ts=` of `event=alert_on` **minus scenario-start timestamp** (Section 5.2). Empty when `triggered=no` |
| `expected` | Protocol expectation for this cell | `trigger` / `no_trigger` / `may_trigger` (V1 limitation) — from the matrix in Section 4 |
| `actual` | What actually happened | `trigger` / `no_trigger` / `degraded` (pose `na`/`uncertain` so the cell could not fairly test) |
| `notes` | Free text | Release latency (`release_ms=NNN`), which `track_id` triggered, anomalies, EXAMPLE marker |

Multi-face trials: quote the short `track_id` UUIDs observed (e.g.
`A=3F2A…, B=91C4…`) in `notes` and attribute the trigger to the exact track
whose `alert_on` fired — owner `track_id`s must never appear on an `alert_on`.

---

## 4. Scenario matrix — 12 scenarios at each of 1 / 2 / 3 / 4 m

Every scenario below is executed **at each distance** (1, 2, 3, 4 m). The
acting stranger stands/sits at that distance ring facing the screen; in
multi-person scenarios the second person is placed at the same ring where
feasible (record the actual arrangement in `notes`). Plan Section 17 case
letters are given per row.

### 4.1 Scenario definitions and expected results

| # | Scenario (plan case) | Setup | Expected result |
|---|---|---|---|
| S01 | Directly facing screen (Case A) | Stranger faces the screen, sustained frontal gaze > 3 s | **trigger** (frontal-recall cell) |
| S02 | Clearly facing left | Stranger holds head turned ~30–45° toward their own left > 3 s | **no_trigger** (\|yaw\| beyond band tolerance) |
| S03 | Clearly facing right | Mirror of S02 | **no_trigger** |
| S04 | Looking up / down | Chin raised ~20° held > 2 s; then chin tucked held > 2 s | **no_trigger** (pitch beyond tolerance) — record both halves |
| S05 | Walking laterally past camera (Case C) | Stranger crosses the frame left→right at that distance, transit 2–4 s, not approaching the screen; repeat both directions | **no_trigger** (passer-by false-trigger cell) |
| S06 | Facing away (Case D) | Stranger back or full profile to the camera, held | **no_trigger** |
| S07 | Brief glance < 0.5 s (Case E) | Stranger side-on, glances at the screen < 0.5 s, returns; 5 glances | **no_trigger** on every glance |
| S08 | Sustained attention > 1 s (Case F) | Stranger side-on, turns frontal, holds ~2 s | **trigger** (frontal-recall cell) |
| S09 | Owner only (Case G) | Owner alone, seated normally, may stare straight into the camera | **no_trigger — never** (owner false-trigger cell) |
| S10 | Owner + stranger looking elsewhere (Case H) | Owner at desk; stranger turned away from the screen indefinitely | **no_trigger** |
| S11 | Owner + stranger looking at screen (Case I) | Owner at desk; stranger frontal gaze > 3 s | **trigger** — from the stranger's track only |
| S12 | Two strangers, one looking (Case J) | Strangers A and B visible; A looks at the screen, B turned away; hold > 3 s | **trigger** — from A's track only; B's looking duration stays ~0 |
| S13 | *Limitation probe:* head frontal, eyes sideways (plan Case B) | Head deliberately kept frontal (yaw within tolerance) while looking sideways at something off-screen | **may_trigger** — known V1 limitation (head pose is not eye gaze). Record actual; not a hard fail, but the rate feeds the V2-T01 decision |

### 4.2 Distance × scenario matrix

Expected results are distance-independent in kind; what changes with distance
is the applicable band profile (M3-T04: near yaw ±18° / pitch ±15° / trigger
0.7 s; mid ±22° / ±18° / 0.9 s; far ±27° / ±22° / 1.2 s) and the recall bar
(1–3 m > 95%, 4 m > 85% — Section 5.5). Codes: **T** = trigger, **NT** =
no_trigger, **MAY** = may_trigger (V1 limitation).

| Scenario | 1 m | 2 m | 3 m | 4 m |
|---|---|---|---|---|
| S01 facing screen | T | T | T | T (recall bar 85%) |
| S02 facing left | NT | NT | NT | NT |
| S03 facing right | NT | NT | NT | NT |
| S04 up / down | NT | NT | NT | NT |
| S05 walking past | NT | NT | NT | NT |
| S06 facing away | NT | NT | NT | NT |
| S07 brief glance | NT | NT | NT | NT |
| S08 sustained > 1 s | T | T | T | T (recall bar 85%) |
| S09 owner only | NT | NT | NT | NT |
| S10 owner + stranger away | NT | NT | NT | NT |
| S11 owner + stranger looking | T | T | T | T (recall bar 85%) |
| S12 two strangers, one looking | T | T | T | T (recall bar 85%) |
| S13 frontal head / side eyes | MAY | MAY | MAY | MAY |

At 4 m, pose may degrade to `unavailable` → `uncertain` → no trigger on some
trials; record `actual=degraded` rather than silently scoring a miss. A
persistent `throttled=true`-style cadence collapse or `vision_fps` drop in
`event=metrics` invalidates the timing expectations of the affected session.

Full cell count: 12 scenarios × 4 distances × 3 repetitions = **144 trials
per camera** (Section 5.4); S13 is an optional 13th probe (adds 12 cells).

---

## 5. Measurement procedure

### 5.1 Running one trial

1. Debug logging enabled before launch; log capture running (Section 2).
2. Note the **scenario start**: the wall-clock moment the actor enters the
   scenario pose. Practical log anchor: the first `event=track` line of the
   qualifying track that matches the scenario state (e.g. the first
   `attention_state=looking` with yaw inside tolerance for S01/S08/S11/S12).
   Record both the noted wall-clock time and the anchor line's `ts=`.
3. Hold / act for the scenario duration (≥ 3 s for holds; defined transit for
   S05; 5 glances for S07).
4. Keep logging ~2 s past any `alert_off` so the release is captured.
5. Extract the fields (Section 3) into one `docs/evaluation_results.csv` row.

### 5.2 Trigger latency

```text
trigger_latency_ms = ts(event=alert_on) − ts(scenario start)
```

Computed from the ISO8601 `ts=` prefixes (millisecond resolution). The
protocol definition is **alert-on transition timestamp minus scenario start**
per Section 5.1. A useful diagnostic sub-measurement, recorded in `notes`:
`alert_on ts − first attention_state=looking ts on the qualifying track`
(pure pipeline latency, excluding actor reaction time). Target: **0.8–1.3 s**
(Section 5.5); at 4 m the far-band trigger duration (1.2 s) sits near the top
of that window, so 4 m medians may legitimately run higher than 1 m medians.

### 5.3 Release latency

```text
release_latency_ms = ts(event=alert_off) − ts(first attention_state ≠ looking
                     on the last qualifying track after the alert)
```

The CSV has no dedicated column; record it in `notes` as `release_ms=NNN`.
Target: **0.5–0.8 s**.

### 5.4 Repetitions

**3 repetitions per scenario × distance cell**, each recorded as its own CSV
row. Between repetitions, wait for the shield to fully release and the
baseline state to return (no `alert_on` active, all tracks cleared or idle).
If the 3 repetitions of a cell disagree (2–1 split), run 2 more and record all
5 rows; the cell's verdict is the majority with the spread noted.

### 5.5 Pass criteria (M3-T06 targets)

| Metric | Target | Computed from |
|---|---|---|
| Owner false-trigger rate | **< 0.5%** | S09 rows (+ any owner-attributed `alert_on` anywhere): owner-triggered trials / owner trials |
| Passer-by false-trigger rate | **< 2%** | S05, S06, S07 rows (+ S02–S04, S10 non-looking trials): triggered / total passer-by trials |
| 1–3 m frontal recall | **> 95%** | S01 + S08 (+ S11/S12 looking-stranger) rows at 1/2/3 m: triggered / total frontal trials |
| 4 m frontal recall | **> 85%** | same rows at 4 m |
| Trigger latency | **0.8–1.3 s** | median + range over all triggered rows |
| Release latency | **0.5–0.8 s** | median + range over all `release_ms` notes |

A failed cell feeds M3-T06 tuning (angle tolerances, score thresholds,
uncertain grace, band boundaries, trigger/release durations); re-run the
affected cells after each revision and record every threshold revision in the
session notes. Avoid overfitting to a single lighting condition — at minimum
run the full matrix under `indoor-day` plus one other lighting condition.

---

## 6. Raw face-width distributions at 1/2/3/4 m (input for M3-T03)

M3-T03 must not guess band boundaries; this section produces the data. The
`face_width` logged by `event=track` is the normalized bbox width, so the
distributions are **per camera** — repeat the whole section for FaceTime HD
and (separately) for the Continuity Camera; do not assume one generalizes
(M3-T03 acceptance: same camera maps test distances monotonically to bands).

### Procedure

1. Enable debug logging (Section 2) and confirm the camera from the launch log.
2. One person (identity irrelevant), standing **exactly 1 m** from the camera
   (tape-measured lens-to-face-plane), still, frontal, face fully visible and
   unoccluded for ~10 s.
3. Copy every `face_width=` value from the `event=track` lines of that track
   during the hold (ignore lines during approach/settling).
4. Repeat at 2, 3, and 4 m. Do not move the camera between distances.
5. Optional but recommended: one extra ~10 s hold per distance with the head
   yawed ~30°, to check how much width shrinks with pose (band boundaries
   should tolerate normal pose, not only perfectly frontal).

### Width table (fill in during the manual session — PENDING(manual))

| Camera | 1 m min / median / max | 2 m min / median / max | 3 m min / median / max | 4 m min / median / max |
|---|---|---|---|---|
| FaceTime HD | PENDING(manual) | PENDING(manual) | PENDING(manual) | PENDING(manual) |
| Continuity | PENDING(manual) | PENDING(manual) | PENDING(manual) | PENDING(manual) |

### Deriving the band boundaries (M3-T03)

1. Set the **near/mid** boundary between the 1 m and 2 m distributions —
   start at the midpoint of the two medians, then move it inside the wider
   gap if the distributions overlap.
2. Set the **mid/far** boundary between the 2–3 m and 4 m distributions the
   same way.
3. Set the **too-far floor** just under the 4 m distribution, at the width
   below which pose becomes unreliable (`yaw=na` frequency rises) — faces
   under it map to `tooFarOrUnreliable`.
4. Add hysteresis margin (≈10–15% of the boundary value) on each side so band
   transitions do not oscillate (M3-T04 acceptance).
5. Sanity-check monotonicity: for the same camera, 1 m > 2 m > 3 m > 4 m must
   hold for the medians; any inversion means the measurement, not the model,
   is wrong — re-measure before tuning.

---

## 7. Repeatability checklist (every session)

- [ ] Floor marks taped for 1 / 2 / 3 / 4 m (camera-lens-to-face-plane).
- [ ] Same seat height and posture anchor across the sweep; note the chair.
- [ ] Camera angle unchanged: built-in camera means the lid/stand angle is
      fixed — do not move the Mac between cells; note the lid position.
- [ ] Camera selection confirmed from the launch log (`Found camera: …`);
      iPhone disconnected unless Continuity is the device under test.
- [ ] Lighting recorded and held constant within a distance sweep; note
      window/lamp state.
- [ ] **Screen-center calibration re-run** (M3-T02 *Calibrate Screen
      Direction…*) at session start and after every lighting change; record
      the calibrated center.
- [ ] Same "stranger" helper across a sweep where possible; record any swap.
- [ ] App build unchanged during a sweep; commit hash recorded.
- [ ] Debug logging enabled before launch; capture verified (`event=track`
      lines visible) before the first timed trial.
- [ ] Between repetitions: shield fully released, baseline state restored.
- [ ] No extra faces/motion in frame beyond the scenario actors.

---

## Status

- [x] Protocol + harness template written (this document +
      `docs/evaluation_results.csv`).
- [ ] Raw face-width distributions measured (Section 6) — **PENDING(manual)**;
      feeds M3-T03 band boundaries.
- [ ] Scenario matrix executed (12 scenarios × 4 distances × 3 reps per
      camera, Section 4) — **PENDING(manual)**; feeds M3-T06.
- [ ] Results recorded in `docs/evaluation_results.csv`; tuned thresholds and
      the per-revision log summarized into `docs/m3_tuning_report.md`
      (M3-T06 output).
