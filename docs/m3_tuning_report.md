# M3 Tuning Report — 1–4 m Threshold Tuning Pass (M3-T06)

> Milestone: M3 — 1–4 m Calibration & Tuning
> Branch: `feature/head-pose-attention`
> Task: `docs/implement_todolist.md` M3-T06 ("Execute 1–4 m tuning pass")
> Recorded: 2026-10-13 (baseline + procedure; **execution and revisions PENDING(manual)**)
> Related: `docs/evaluation_protocol_1_4m.md` (harness, scenario matrix, pass
> criteria), `docs/DEVELOPMENT_PLAN_with_fork.md` Section 18 (V1 acceptance
> targets), `docs/evaluation_results.csv` (raw trial rows),
> `docs/implement_todolist.md` M3-T07 (CPU target).

This document is the M3-T06 output. It fixes the **pre-tuning baseline**
(Section 1) every threshold revision is measured against, the **targets**
(Section 2), the **tuning procedure** per knob (Section 3), and the
**threshold revision log** (Section 4) that records every committed change.
The physical execution of the 1/2/3/4 m matrix, the face-width measurement
that finalizes the band boundaries, and the iterative tuning itself all
require a human at the primary development Mac (Section 5).

---

## 1. Initial (pre-tuning) values

Baseline = the values currently in the tree on `feature/head-pose-attention`
**before any M3-T06 revision**. Every row in the revision log (Section 4) is
measured against this table. All values live in the struct fields cited — no
scattered magic numbers (X-T01).

### 1.1 Per-band attention profiles (`PrivacyShield/AdaptiveAttentionPolicy.swift`, `DistanceAttentionProfiles.standard`)

| Knob | Near (≈1–2 m) | Mid (≈2–3 m) | Far (≈3–4 m) | Unit |
|---|---|---|---|---|
| Yaw tolerance | 18.0 | 22.0 | 27.0 | ± degrees |
| Pitch tolerance | 15.0 | 18.0 | 22.0 | ± degrees |
| Roll tolerance (shared) | 30.0 | 30.0 | 30.0 | ± degrees |
| Yaw weight | 0.60 | 0.60 | 0.60 | — |
| Pitch weight | 0.35 | 0.35 | 0.35 | — |
| Roll weight | 0.05 | 0.05 | 0.05 | — |
| Looking threshold | 0.70 | 0.70 | 0.70 | score ≥ |
| Not-looking threshold | 0.45 | 0.45 | 0.45 | score ≤ |
| Trigger duration | 0.7 | 0.9 | 1.2 | s |
| Release duration | 0.6 | 0.6 | 0.6 | s |
| Uncertain grace | 0.35 | 0.35 | 0.35 | s |
| Screen center yaw/pitch | 0.0 / 0.0 (placeholder) | 0.0 / 0.0 (placeholder) | 0.0 / 0.0 (placeholder) | degrees |

Notes:

- The screen center 0/0 in `DistanceAttentionProfiles.standard` is a
  placeholder; `AdaptiveAttentionPolicy.classifierConfig` overlays the
  **calibrated** center (`ScreenCenterStore.load()`, M3-T01/T02) on every
  classification. The calibrated center is a *measured input*, not a tuning
  knob — re-calibrate per session and after every lighting change (protocol
  Section 2), never tune it to make a cell pass.
- `PrivacyShield/AttentionClassifier.swift` `.balanced` (yaw ±22, pitch ±18,
  roll ±30, weights 0.60/0.35/0.05, thresholds 0.70/0.45) is the base
  default and is numerically identical to the **mid** profile above.
- `.tooFarOrUnreliable` tracks get **no** classifier and no timing config —
  they stay uncertain and can never alert. Not tunable; it is a posture, not
  a threshold.

### 1.2 Temporal timing defaults (`PrivacyShield/AttentionTiming.swift`, `AttentionTimingConfig`)

| Knob | Value | Unit | Note |
|---|---|---|---|
| Trigger duration (M1 prototype default) | 0.9 | s | Matches the mid-band value |
| Release duration | 0.6 | s | |
| Uncertain grace | 0.35 | s | |
| Max single-update delta (safety clamp) | 0.5 | s | Not a tuning knob. Invariant: must stay < triggerDuration of every band profile so one stalled frame can never trigger alone |

### 1.3 Distance-band boundaries (`PrivacyShield/DistanceBands.swift`, `DistanceBandConfig.default`)

| Knob | Value | Unit | Note |
|---|---|---|---|
| `nearMaxWidth` (width > → near) | 0.28 | normalized bbox width | **PLACEHOLDER** — camera-dependent; to be finalized from the measured 1/2/3/4 m width distributions (protocol Section 6) |
| `midMaxWidth` (mid/far boundary) | 0.16 | normalized bbox width | **PLACEHOLDER** |
| `farMaxWidth` (too-far floor) | 0.09 | normalized bbox width | **PLACEHOLDER** |
| `hysteresisMargin` | 0.015 | normalized bbox width | Band-switch hysteresis; must stay < half the smallest gap between adjacent boundaries |

Interval convention: a width exactly ON a boundary belongs to the farther
band; the hysteresis margin must be exceeded strictly to switch bands.

### 1.4 Recognition cadences and identity hysteresis (`PrivacyShield/RecognitionCachePolicy.swift`, `RecognitionCachePolicyConfig.default`)

| Knob | Value | Unit | Note |
|---|---|---|---|
| `ownerRevalidationInterval` | 2.5 | s | Spec: every 2–3 s |
| `trustedRevalidationInterval` | 2.5 | s | Same trust level as owner |
| `otherRevalidationInterval` | 1.5 | s | Strangers and `.unknown` tracks; spec: every 1–2 s |
| `bboxJumpRelativeThreshold` | 0.35 | fraction of frame width | Early revalidation trigger |
| `faceSizeChangeRatio` | 0.4 | \|log width ratio\| | Early revalidation trigger |
| `resumeAfterGapThreshold` | 1.0 | s | Reappearing track rechecked immediately |
| `ownerDowngradeConsecutiveMisses` | 2 | consecutive failed revalidations | One bad frame cannot demote owner → stranger |
| `cropQualityImprovementThreshold` | nil (reserved) | — | Untouched since M2-T05; only tunable if M2-T06's quality metric lands |

### 1.5 Screen-center calibration config (`PrivacyShield/ScreenDirectionCalibration.swift`, `ScreenCalibrationConfig.default`)

| Knob | Value | Unit | Note |
|---|---|---|---|
| `requiredValidSamples` | 15 | samples | ≈2–3 s at the Vision cadence |
| `collectionWindow` | 3.0 | s | |
| `outlierSigmaMultiplier` | 2.5 | σ (via 1.4826·MAD) | |
| `minimumValidityRate` | 0.5 | fraction | |

Context only: these gate the calibration *session*, not the attention
decision. They are listed for completeness; the M3-T06 pass tunes the
Sections 1.1–1.4 knobs, not these.

---

## 2. Targets

Exactly the plan's M3-T06 initial targets (`docs/implement_todolist.md`
M3-T06, `docs/DEVELOPMENT_PLAN_with_fork.md` Section 18), with the
measurement definitions from `docs/evaluation_protocol_1_4m.md` Section 5.5:

| Metric | Target | Computed from (protocol Section 5.5) |
|---|---|---|
| Owner false-trigger rate | < 0.5% | S09 rows + any owner-attributed `alert_on` anywhere: owner-triggered trials / owner trials |
| Passer-by false-trigger rate | < 2% | S05, S06, S07 rows (+ S02–S04, S10 non-looking trials): triggered / total passer-by trials |
| 1–3 m frontal recall | > 95% | S01 + S08 (+ S11/S12 looking-stranger) rows at 1/2/3 m: triggered / total frontal trials |
| 4 m frontal recall | > 85% | same rows at 4 m |
| Trigger latency | ~0.8–1.3 s | median + range over all triggered rows (Section 5.2 definition) |
| Release latency | ~0.5–0.8 s | median + range over all `release_ms` notes (Section 5.3 definition) |

Performance target (cross-reference **M3-T07**, `docs/implement_todolist.md`
M3-T07 — measured after feature completeness, not by this tuning pass):

| Metric | Target | Note |
|---|---|---|
| Average background CPU | < 15% | On the primary Apple Silicon Mac (`Mac15,12`, Apple M3 — `docs/baseline_metrics.md` Section 1); measured at idle and with 1/2/3 faces per M3-T07 |

These are tuning goals, not hard guarantees before empirical testing
(plan Section 18). A target missed after a documented tuning effort is
recorded in the revision log's "result vs targets" column and, per M3-T07's
acceptance rule, either fixed or explicitly documented with a reason.

---

## 3. Tuning procedure

General rules for every revision:

- Change **one knob family at a time**; re-run the affected cells after each
  revision (protocol Section 5.5); record every revision in Section 4.
- Step sizes below are **starting conventions** for the first pass — halve
  them when a cell is close to target and double the evidence check when a
  revision moves a cell the wrong way.
- Cells are identified as `Sxx @ Dm` (scenario, distance) from
  `docs/evaluation_protocol_1_4m.md` Section 4; each cell = 3 repetitions
  (5 on a 2–1 split).
- **Anti-overfitting rule (plan M3-T06, protocol Section 5.5): never tune to
  a single lighting condition.** A revision is only committed when the
  affected cells pass consistently across lighting conditions — at minimum
  the full matrix under `indoor-day` **plus** one other condition
  (`indoor-evening` / `low-light` / `backlit`). A "fix" that only holds in
  one lighting cell is not a fix; re-measure instead of committing.
- Re-run *Calibrate Screen Direction…* after every lighting change before
  judging any pose-dependent cell (protocol Section 2).

### 3.1 Angle tolerances (yaw/pitch, per band: near 18/15, mid 22/18, far 27/22)

- **Symptom → direction:**
  - Frontal recall miss — S01/S08 (or the looking stranger in S11/S12) ends
    `no_trigger` with `attention_state` hovering at `uncertain` and a score
    just under 0.70 at that band → tolerances too tight → **widen**.
  - False trigger — S02/S03 (30–45° turn) or S04 (chin ~20°) fires →
    tolerances too loose → **tighten**.
- **Step size:** 2–3° per revision, per axis, per band.
- **Deciding cells:** recall = S01, S08, S11/S12 looking-stranger at the
  band's distance ring (1 m → near, 2–3 m → mid, 4 m → far); false-trigger =
  S02, S03, S04, S06 at the same ring. Move a band's tolerance only for
  evidence at (or clearly spanning) that band's ring.
- **Constraints:** keep yaw tolerance ≥ pitch tolerance per band and keep the
  far ≥ mid ≥ near ordering (pose noise grows with distance — M3-T04
  rationale). Roll (±30°, shared) is left alone unless S02–S04 show roll-axis
  contamination specifically; then ±2–3° steps, same cells, checking the
  `roll_deg` column for separation.

### 3.2 Score thresholds (looking ≥ 0.70, not-looking ≤ 0.45; shared across bands)

- **Symptom → direction:**
  - Borderline holds stall — recall cells show long `uncertain` stretches and
    scores clustered just below 0.70 that never accumulate →
    **lower `lookingThreshold`** (0.03–0.05 steps).
  - Glances/off-axis postures read as looking — S07 brief glances trigger, or
    S10 (stranger looking elsewhere) fires → **raise `lookingThreshold`**
    (0.03–0.05 steps).
  - Score sits mid-band so state flaps between `looking`/`notLooking` through
    the hold → widen the hysteresis gap by lowering `notLookingThreshold`
    (0.03–0.05 steps); conversely, if everything collapses into `uncertain`
    and latency balloons, narrow the gap by raising `notLookingThreshold`.
- **Deciding cells:** S01/S08 recall + S07, S02–S04, S10 false-trigger, judged
  on the `attention_score` distributions logged per track
  (`event=track … attention_score=`), not just the verdict.
- **Constraints:** keep `notLookingThreshold` < `lookingThreshold` with a
  meaningful gap (the gap IS the hysteresis band); thresholds are shared
  across bands, so weigh evidence from all rings before committing.

### 3.3 Uncertain grace (0.35 s, shared)

- **Symptom → direction:**
  - Recall misses with pose flickering to `uncertain` mid-hold (accumulation
    resets, latency inflates or the trigger dies) → **raise** grace.
  - S07 brief glances (< 0.5 s) start triggering — the grace window held the
    pending accumulation across the glance → **lower** grace.
- **Step size:** 0.05–0.10 s per revision.
- **Deciding cells:** S07 (every glance must stay `no_trigger`) vs S01/S08
  latency and recall at 1–3 m; S13 (frontal head / side eyes) — its
  `may_trigger` rate is a probe, not a hard fail, but a grace change that
  inflates it is evidence against the revision.
- **Constraints:** keep grace < release duration, and keep it well under half
  the shortest (near, 0.7 s) trigger duration so a sub-0.5 s glance can never
  ride the grace window to an alert.

### 3.4 Near/mid/far face-size boundaries (0.28 / 0.16 / 0.09) and hysteresis margin (0.015)

- **These are derived, not iterated:** measure the raw face-width
  distributions at 1/2/3/4 m first (protocol Section 6, per camera), then set
  each boundary between the adjacent distributions — start at the midpoint of
  the two medians, move it inside the wider gap if the distributions overlap
  (protocol Section 6, "Deriving the band boundaries"). Replace the three
  placeholders with the derived values as the *first* recorded revision.
- **Symptom of a wrong boundary:** a ring's faces land in the wrong band —
  e.g. a 2 m face classified `near` (trigger fires too eagerly for its ring's
  recall bar), or a 4 m face classified `tooFarOrUnreliable` (can never alert;
  shows up as `actual=degraded` rows at 4 m) → **move the offending boundary
  into the gap between the measured distributions**.
- **Symptom of a wrong hysteresis margin:** band oscillation frame-to-frame
  (band flapping in `event=track` while width is stable) → margin too small →
  **raise** it toward 10–15% of the boundary value; a band that never switches
  despite the width clearly crossing → margin too large relative to the
  boundary gap → **lower** it.
- **Step size:** boundaries — to the measured distribution gap (no arbitrary
  steps); margin — 0.005 normalized-width steps.
- **Deciding cells:** the Section 6 width table (min/median/max per distance,
  per camera, frontal + the optional ~30°-yaw hold) plus the `face_width`
  values logged in S01 rows at each ring — each ring must predominantly map
  to its intended band. Sanity-check monotonicity (1 m > 2 m > 3 m > 4 m
  medians); an inversion means re-measure, not re-tune (protocol Section 6).
- **Constraints:** keep `nearMaxWidth > midMaxWidth > farMaxWidth > 0` and
  `hysteresisMargin` < half the smallest adjacent gap; boundaries are
  camera-specific (`face_width` normalization) — never port a boundary across
  cameras.

### 3.5 Trigger durations (near 0.7, mid 0.9, far 1.2 s)

- **Symptom → direction (judge per band):**
  - Band's median trigger latency > 1.3 s (or > target at that ring's recall
    cells even when they pass) → **shorten** that band's trigger.
  - Median latency < 0.8 s, or S07 glances/S05 walk-bys start triggering →
    **lengthen** that band's trigger.
  - Note the built-in tension: near's 0.7 s trigger sits *below* the 0.8 s
    latency-floor target, and far's 1.2 s sits near the 1.3 s ceiling
    (protocol Section 5.2 flags this). Expect the first revision to lift
    near toward ~0.8–0.9 s and/or pull far down if 4 m medians overrun.
- **Step size:** 0.1 s per revision, per band.
- **Deciding cells:** S01, S08, S11/S12 looking-stranger triggered rows at the
  band's ring — median + range of `trigger_latency_ms` (Section 5.2);
  S07 and S05 at the same ring for the floor side.
- **Constraints:** keep near ≤ mid ≤ far (more evidence demanded at distance —
  M3-T04 rationale); respect the `maxDelta` (0.5 s) < trigger invariant; a
  trigger change invalidates the timing expectations of every latency cell —
  re-run them all for that ring.

### 3.6 Release duration (0.6 s, shared)

- **Symptom → direction:**
  - Median `release_ms` > 0.8 s (shield lingers after the observer looks
    away) → **shorten**.
  - Median `release_ms` < 0.5 s, or the shield flaps (alert_on/alert_off
    cycling) during a single observation with brief look-aways → **lengthen**.
- **Step size:** 0.1 s per revision.
- **Deciding cells:** `release_ms` recorded in `notes` on all triggered rows
  (Section 5.3); flap check on S08 (turn frontal ~2 s, then return) and S11
  (owner present throughout — release must not invite an immediate re-trigger
  from the same track).
- **Constraints:** shared across bands; must stay > the uncertain grace
  (Section 3.3) and coherent with the release-latency target 0.5–0.8 s.

---

## 4. Threshold revision log

Every committed M3-T06 revision gets one row, in order. "Evidence" names the
deciding cells and their numbers (e.g. `S01@1m 2/3 trigger → 3/3`,
`median latency 1.42 s → 1.21 s`); "Result vs targets" states the metric and
pass/fail after the revision. Re-run the affected cells under **both required
lighting conditions** before committing the row (Section 3 anti-overfitting
rule).

| Date | Commit | Knob(s) | Old value | New value | Evidence (eval cells + numbers) | Result vs targets |
|---|---|---|---|---|---|---|
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| | | | | | | |
| **EXAMPLE** | **2026-10-13 (example only — not a real revision)** | `nearTiming.triggerDuration` | 0.7 s | 0.8 s | EXAMPLE: S01@1m + S08@1m median trigger_latency_ms 0.74 (below 0.8 s floor) across indoor-day + indoor-evening → raised; re-run median 0.86, range 0.81–0.97 | EXAMPLE: trigger latency 0.8–1.3 s PASS at 1 m; owner/passer-by rates unchanged (S09/S05–S07 still no_trigger) |

The first real row of this log is expected to be the band-boundary
replacement from the measured width distributions (Section 3.4) — the
placeholders 0.28/0.16/0.09/0.015 are derived from data, then committed as a
revision like any other.

---

## 5. Physical execution status

**PENDING(manual).** Nothing below is executable by build or unit tests
alone; each step requires a human at the primary development Mac
(`Mac15,12`, Apple M3 — see `docs/baseline_metrics.md` Section 1).

| Step | Status | What it requires |
|---|---|---|
| Raw face-width distributions at 1/2/3/4 m (protocol Section 6, per camera: FaceTime HD, Continuity) | **PENDING(manual)** | A person standing at tape-measured 1/2/3/4 m rings for ~10 s holds; fills the protocol's width table; feeds the band-boundary revision (Section 3.4) |
| Scenario matrix execution — 12 scenarios × 4 distances × 3 repetitions (144 trials per camera; optional S13 probe adds 12 cells) | **PENDING(manual)** | Actor(s) per protocol Section 4; ≥ 2 lighting conditions (anti-overfitting rule, Section 3); screen-center calibration re-run per lighting change; rows appended to `docs/evaluation_results.csv` |
| Iterative tuning loop (Section 3) | **PENDING(manual)** | Judging each failed cell, applying one knob revision at a time, re-running affected cells under both lighting conditions, recording every revision in Section 4 |
| CPU verification (< 15% average) | **PENDING(manual)** — owned by **M3-T07** | Measured after feature completeness per M3-T07, on the same primary Mac |

The harness and its prerequisites live in `docs/evaluation_protocol_1_4m.md`
(session metadata, log capture setup, per-trial field extraction,
repeatability checklist); raw trial rows go to `docs/evaluation_results.csv`
which currently contains only clearly marked EXAMPLE placeholder rows — no
measured data has been recorded yet.

Interim status of the M3-T06 task list (`docs/implement_todolist.md`
M3-T06): baseline + procedure + revision log are in place (this document);
"Run evaluation matrix" and all "Tune …" items are blocked on the manual
execution above and remain unchecked until then.
