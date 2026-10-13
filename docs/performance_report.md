# Performance Report (M3-T07)

> Milestone: M3 — 1–4 m Calibration & Tuning
> Branch: `feature/head-pose-attention`
> Recorded: 2026-10-13
> **Overall runtime status: PENDING(manual)** — every measured cell below is
> TODO(manual) until the protocol in Section 6 is executed. Static
> (code-derived) expectations are filled from Section 3.
> Related: `docs/baseline_metrics.md` (M0 baseline + measurement protocol),
> `docs/DEVELOPMENT_PLAN_with_fork.md` §18 (acceptance targets),
> `docs/implement_todolist.md` M3-T07.

---

## 1. Instrumentation inventory

### 1.1 Already measured at runtime (debug-gated, silent in normal mode)

| What | Where it is emitted | Cadence / notes |
|---|---|---|
| **Capture FPS + throttled flag + format** | `PS \| event=capture_metrics \| capture_fps=… \| throttled=… \| format=…` — `CameraManager.emitCaptureMetricsLog` (`CameraManager.swift:207-219`) | ~every 5 s (`metricsLogIntervalNanos`, `CameraManager.swift:222`); FPS measured over ~1 s windows of `didOutput` callbacks (`recordCaptureSample`, `CameraManager.swift:160-190`); `throttled=true` when measured FPS < 90 % of the configured format FPS (`CameraManager.swift:213-217`). Late frames are *dropped* (`alwaysDiscardsLateVideoFrames = true`, `CameraManager.swift:125`), so throttling has no callback of its own — it only shows up here (`CameraManager.swift:21-25`). |
| **Vision processed FPS, per-frame latency, face count, recognition count** | `event=metrics \| vision_fps=… \| latency_ms=… \| faces=… \| recognitions=…` — `DiagnosticsLog.metrics` (`DiagnosticsLog.swift:172-182`), driven by `FaceDetector.recordFrameMetrics` (`FaceDetector.swift:615-636`) | ~every 2 s (`metricsInterval`, `FaceDetector.swift:162`). `vision_fps` counts frames through the full pipeline per wall-clock second; `recognitions` counts `FaceRecognizer.identify` runs *within that ~2 s window* (counter reset at `FaceDetector.swift:634`). |
| **Per-track state** | `event=track` — one per track per processed frame (`DiagnosticsLog.track`, `DiagnosticsLog.swift:62-120`; emitted at `FaceDetector.swift:477-489`) | identity, bbox/face width, distance band, yaw/pitch/roll, attention score/state, looking duration, last-seen/identity-check ages. |
| **Recognition decisions** | `event=recognition` — `recognize_now` / `cached` with the policy's reason (`DiagnosticsLog.recognition`, `DiagnosticsLog.swift:143-154`; emitted at `FaceDetector.swift:459-471`) | The direct probe for the "recognition frequency" row of Section 4. |
| **Edge events** | `alert_on` / `alert_off` per track (`DiagnosticsLog.swift:158-165`, emitted `FaceDetector.swift:383-390`); `band_change` per track band transition (`DiagnosticsLog.bandChange`, `DiagnosticsLog.swift:127-137`, emitted `FaceDetector.swift:344`); `legacy_shield_on/off`, `screen_calibration_on/off` | Transition-only, so steady-state frames add no lines. |

All of the above are gated on the persisted `debugLoggingEnabled` flag **before**
any string is built (`DiagnosticsLog.swift:46-49,75,231-234`;
`CameraManager.swift:208`), so normal (non-debug) operation pays nothing.

### 1.2 NOT yet measured (and how to add each later)

| Gap | Why it matters | How to add (when needed) |
|---|---|---|
| **Face-detection-only latency split** | `latency_ms` is captured *before* the per-track loop (`FaceDetector.swift:247→314`), so despite the stale field note in `DiagnosticsLog.swift:36-37` ("detection + recognition + classification") it currently measures **detection + size gate + association only** — i.e. it already approximates the face-detection latency row. What is genuinely missing is the split *within* it (request perform vs tracker) and the recognition share. | Take a second `CFAbsoluteTimeGetCurrent()` immediately after `try requestHandler.perform([request])` (`FaceDetector.swift:248`) and emit `detection_ms` + `tracking_ms` fields in the periodic `metrics` event; time the `faceRecognizer.identify` call (`FaceDetector.swift:450-454`) and add `recognition_ms` to the `recognition` event. |
| **Tracking overhead** | Association is O(detections × tracks) in-process (`FaceTracker.swift:235-262`); expected microseconds, but unverified. | Same second-timestamp approach around `faceTracker.process(...)` (`FaceDetector.swift:297`), accumulated into the metrics window like `metricsLatencySum`. |
| **Recognition latency per run** | `identify` cost (crop + `VNGenerateImageFeaturePrintRequest` + ≤ prints × `computeDistance`, `FaceRecognizer.swift:94-123,157-165`) is inferred from Instruments sampling only. | Wrap the call site (`FaceDetector.swift:450-454`) with a timer; log `recognition_ms` in the existing `recognition` event (no new event type needed). |
| **Memory footprint** | Nothing logs memory; the baseline protocol reads Activity Monitor manually. | Cheapest: keep using Activity Monitor per `docs/baseline_metrics.md` §4 step 5. If automated later, read `task_vm_info.resident_size` on the existing 5 s capture-metrics cadence in `CameraManager.emitCaptureMetricsLog` and append `rss_kb=` to that line. |
| **Per-request Vision signposts** | Sampling-based latency estimates are approximate (`docs/baseline_metrics.md` §4 step 4 caveat). | `os_signpost` intervals around the two Vision request performs; view in Instruments' os_signpost lane. Deferred until a tuning pass actually needs exact per-request timings. |

---

## 2. Static cost analysis (code-derived)

Cadence skeleton: capture is pinned to **1920×1080 @ 30 FPS** (tier 1,
`CameraManager.swift:271-273`, min/max frame duration both pinned,
`CameraManager.swift:251-253`); every delivered frame hits `didOutput`
(`CameraManager.swift:148-152`), but Vision runs only on every 3rd frame with a
back-pressure guard (`frameSkip = 3`, `FaceDetector.swift:83` — previously
`:72` before the M3-T07 doc-comment insertion; gate at
`FaceDetector.swift:199-200`, logic unchanged):

```text
processed FPS ≈ min(capture FPS / frameSkip, 1 / single-frame inference time)
            ≈ min(30 / 3, …) = 10 processed FPS (upper bound)
```

### Per processed frame

| Cost | Frequency | Code basis | Relative weight |
|---|---|---|---|
| `VNDetectFaceRectanglesRequest` over the full 1080p frame | 1× per processed frame (≤ 10 Hz) | `FaceDetector.swift:243-249` (handler + request + `perform`) | **Dominant** — everything else is arithmetic around it |
| Size gate (hysteresis threshold + filter) | 1× | `softThreshold = minFaceSize × 0.8` (`FaceDetector.swift:256-257`; `minFaceSize` default 0.25, `FaceDetector.swift:166-172`; `faceBufferRatio = 0.8`, `FaceDetector.swift:175`) | Negligible (one multiply + one filter pass over ≤ handful of faces) |
| Legacy owner-absent condition + debounce counters | 1× | `FaceDetector.swift:263`, `590-611` | Negligible (two integer counters) |
| Tracker association O(d × t) + greedy sort | 1× | pairwise scoring loops `FaceTracker.swift:235-252`; sort `:257-262`; score = IoU + center + size terms (`:470-519`) | Negligible: d + t ≤ ~5 (faces below 0.20 of frame width never become detections, see gate above) → ≤ ~25 pair scores of a few flops + 1 `log` each |
| Pre-frame track snapshot + observation map | 1× | `previousTracks` dictionary `FaceDetector.swift:294`; `observationByTrack` `:309-312` | Negligible (n ≤ ~5 entries) |

### Per track per processed frame (n ≤ ~3 realistic)

| Cost | Frequency | Code basis | Relative weight |
|---|---|---|---|
| Distance-band classification + hysteresis | every frame | 3 comparisons (`DistanceBands.swift:99-104`) + ordinal comparison `refined` (`:132-159`); config `:62-81` | Negligible |
| Head-pose read | every frame — **no extra Vision call** | reads `yaw`/`pitch`/`roll` off the *existing* `VNFaceObservation` + ×180/π (`HeadPoseEstimator.swift:75-91`) | Negligible (3 `NSNumber.doubleValue` + 3 multiplies) |
| Attention classifier | every frame | value-struct config + weighted 3-axis score, ~10 flops (`AttentionClassifier.swift:45-75`; instantiated per evaluation at `FaceDetector.swift:364-370`) | Negligible |
| Temporal filter update | every track, every frame | O(1) date math + 3-field state machine (`AttentionTiming.swift:80-125`) | Negligible |
| **Recognition (crop + feature print)** | **only when `RecognitionCachePolicy` says so** | decision `RecognitionCachePolicy.swift:135-195`; execution `FaceDetector.swift:417-472`; cost = face crop + **new `CIContext` per run** + `VNGenerateImageFeaturePrintRequest` + ≤ enrolled prints × `computeDistance` (`FaceRecognizer.swift:94-123,157-165,168-184`) | Second-largest after detection, but see cadence below |
| Debug `track` event | every track, every frame — **debug builds only** | gated before formatting (`DiagnosticsLog.swift:75,231-234`) | 0 in normal mode; measurable string-building in debug sessions |

### Recognition cadence — the big CPU win vs per-frame recognition

M0/M1 baseline ran recognition on **every processed frame for every nearby
face** (recorded in `docs/baseline_metrics.md` §2, baseline
`FaceDetector.swift:127-135`): ≈ **10 runs/s per face** at 10 processed FPS.

With the M2-T05/T06 cache policy (`RecognitionCachePolicy.swift:16-21,135-195`):

```text
new track            → 1 immediate run                      (isNewTrack short-circuit)
owner / trusted      → revalidate every 2.5 s  = 0.4 Hz     (ownerRevalidationInterval)
other / unknown      → revalidate every 1.5 s  = ≈0.67 Hz   (otherRevalidationInterval)
early triggers       → bbox center jump > 0.35 frame width  (bboxJumpRelativeThreshold :29)
                       size change |ln(w/w₀)| > 0.4 (≈ ×1.5) (faceSizeChangeRatio :33)
                       reappearance after ≥ 1 s gap          (resumeAfterGapThreshold :36)
```

**Steady-state reduction: ~10 Hz → 0.4–0.67 Hz per track, i.e. ≈ 15× fewer
recognition runs for a stranger and ≈ 25× for the owner — conservatively an
order of magnitude (≥ ~10×) vs M1.** Early triggers can burst above the cadence
under fast motion but are bounded by one run per processed frame per track and
are exactly what the runtime `recognitions` counter (per ~2 s window) measures.
Owner demotion additionally needs 2 consecutive failed revalidations
(`ownerDowngradeConsecutiveMisses`, `RecognitionCachePolicy.swift:52`,
applied at `FaceDetector.swift:562-581`), so hysteresis does not multiply the
recognition load.

### UI / capture side

- **UI is edge-driven**: `applyCombinedShield` guards on state change and hops
  to the main queue only on transitions — no per-frame icon refresh
  (`FaceDetector.swift:645-669`, guard at `:647`).
- **No frame backlog**: `alwaysDiscardsLateVideoFrames = true`
  (`CameraManager.swift:125`) drops late frames instead of queueing them.
- **Logging is free in normal mode** (§1.1).
- Known non-detector costs, out of M3-T07 scope: a transient `CIContext` per
  recognition run (`FaceRecognizer.swift:182-183`) and per-frame
  `VNImageRequestHandler`/request allocations (`FaceDetector.swift:243-244`) —
  both are standard usage and negligible next to the Vision inference itself.

---

## 3. Measured performance

All "Measured" cells are **TODO(manual)**; run Section 6 and fill them in.
"Static expectation" is derived from Section 2.

| Metric | Baseline (M0) | After head-pose implementation | Static expectation (code-derived) |
|---|---|---|---|
| Idle average CPU (owner seated, 10 min) | TODO(manual) — `docs/baseline_metrics.md` §2 | **TODO(manual)** | ≈ baseline: per-frame delta is the tracker pass + one track's band/pose/classifier/filter arithmetic (tens of flops at ≤ 10 Hz); recognition cut ≥ ~10× vs M1 → expected flat-to-lower than M1 baseline |
| CPU, 1 face (owner) | TODO(manual) | **TODO(manual)** | ≈ idle + ≤ 1 recognition per 2.5 s (0.4 Hz) + per-frame arithmetic — well under the 15 % target |
| CPU, 2 faces | TODO(manual) — baseline expectation was "roughly 2× recognition load" (`docs/baseline_metrics.md` §2) | **TODO(manual)** | Recognition no longer scales per-frame with face count: 2 tracks ≈ 0.4 + 0.67 ≈ ~1–2 runs per 2 s window; per-frame arithmetic is O(n) trivial → expected ≈ 1-face CPU + small recognition share |
| CPU, 3 faces | TODO(manual) | **TODO(manual)** | Same scaling argument: 3 tracks ≈ ≤ 2 recognition runs per 2 s window steady state; expected still far below target |
| Recognition frequency | ≈ 10 runs/s per nearby face (every processed frame; `docs/baseline_metrics.md` §2) | **TODO(manual)** — read `recognitions=` from `metrics` events (per ~2 s window) or count `event=recognition` lines; steady-state expectation n_strangers × 0.67 Hz + n_owner/trusted × 0.4 Hz | ≈ 15× (stranger) / 25× (owner) below baseline; bursts only on early triggers (fast motion / gap resume) |
| Face-detection latency | TODO(manual) (expected low tens of ms on 640×360 input) | **TODO(manual)** — read `latency_ms=` from `metrics` events (per-frame average); note input is now 1080p and latency_ms ≈ detection + gate + association only (§1.2) | Expected tens of ms per 1080p frame on Apple Silicon at ≤ 10 processed FPS; `isProcessing` guard keeps effective rate = min(10, 1/latency) |
| Tracking overhead | n/a (no tracker at baseline) | **TODO(manual)** — not yet separately instrumented (§1.2); estimate via Instruments sampling of `FaceTracker.process` | O(d×t) with d+t ≤ ~5 → microseconds per processed frame; expected invisible in profiles |
| Memory footprint | TODO(manual) | **TODO(manual)** — Activity Monitor at idle / after 10-min idle / after multi-face run | 1080p BGRA frame ≈ 8.3 MB in flight (late frames dropped, no backlog) + Vision contexts; transient `CIContext` per recognition run (`FaceRecognizer.swift:182-183`); no known growth path — watch the 10-min run for drift |

---

## 4. Tuning levers (in the order they should be tried)

1. **`frameSkip` — processing cadence** (`FaceDetector.swift:83`, documented
   constant, M3-T07). At the pinned 30 FPS capture this yields ~10 processed
   FPS. Raising it to **4** → 7.5 processed FPS: a **25 % Vision-load cut, not
   half** (halving means 6 → 5 processed FPS requires frameSkip = 6).
   Tradeoff: every frame-count-derived timing coarsens proportionally — the
   0.7/0.9/1.2 s per-band trigger durations (`AdaptiveAttentionPolicy.swift:80-94`)
   quantize to whole samples (sample period 100 ms → 133 ms at frameSkip = 4),
   still comfortably inside the plan's 0.8–1.3 s trigger-latency target
   (`DEVELOPMENT_PLAN_with_fork.md` §18), and the frame-counted legacy debounce
   (3/8 frames, `FaceDetector.swift:62-66`) stretches from ~0.3/0.8 s to
   ~0.4/1.07 s. Enrollment (8 samples) and range calibration (10 samples) also
   take proportionally longer. **Use when** measured CPU exceeds target and
   Time Profiler shows `VNDetectFaceRectanglesRequest` dominating. The
   `isProcessing` guard already caps the effective rate at 1/latency, so this
   lever only matters when inference is faster than the skip budget.
2. **Recognition cadence knobs** (`RecognitionCachePolicy.swift:16-36`). Raise
   `otherRevalidationInterval` 1.5 → 2.0 s (−~25 % steady-state recognition) or
   `ownerRevalidationInterval` 2.5 → 3.0 s; widen `bboxJumpRelativeThreshold`
   (0.35) / `faceSizeChangeRatio` (0.4) to suppress early-trigger bursts during
   motion. **Use when** Instruments shows `VNGenerateImageFeaturePrintRequest`
   dominating instead of detection. Tradeoff: identity changes (owner swap,
   different stranger) are noticed later; bounded by
   `resumeAfterGapThreshold` (1 s) which still rechecks after any real absence.
3. **Camera FPS cap** (`CameraManager.swift:251-253`; tier-2 1080p@15 format
   selection `:275-277`). Halves delivery, sensor and ISP cost — helps *energy*
   more than CPU (Vision already sees only every 3rd frame). With frameSkip = 3
   it drops processed FPS to 5, which quantizes the 0.7 s near-band trigger to
   3–4 samples — coarse. **Use when** the concern is battery/thermal rather
   than the CPU percentage; prefer raising `frameSkip` first for pure CPU.
4. **Debug logging state during measurement.** Keep `debugLoggingEnabled` OFF
   for CPU/memory numbers (§1.1 shows disabled mode is free) and use short
   debug-enabled sessions only to read cadence/latency/recognition events —
   per-track `track` events at 10 FPS × n tracks would otherwise inflate the
   very numbers being measured.
5. **Size gate / `minFaceSize`** (`FaceDetector.swift:166-172`) — primarily a
   detection-range behavior knob (set by Calibrate Detection Range), but note
   it also bounds d and t in the association and removes far faces from all
   per-track work; it is *not* the right knob for a CPU problem.

---

## 5. Targets & acceptance

- **Target:** average background monitoring CPU **< 15 %** on a modern Apple
  Silicon Mac (`DEVELOPMENT_PLAN_with_fork.md` §18; M3-T07 task list in
  `docs/implement_todolist.md`).
- **Acceptance wording (M3-T07):** "Performance target met or explicitly
  documented with reason." This report supplies the instrumentation (§1), the
  static case that the head-pose additions are arithmetic-negligible and the
  recognition load dropped ≥ ~10× (§2), and the levers (§4). **The verdict
  itself is PENDING(manual)** until the protocol below is executed: if the
  measured average exceeds 15 %, record the number, the dominating component
  (detection vs recognition per §1.2 instrumentation), the lever applied, and
  the post-lever number in Section 3 — that record *is* the "explicitly
  documented with reason" acceptance.
- **Measurement instructions** (reuse the baseline protocol for comparability,
  `docs/baseline_metrics.md` §4 — same machine Mac15,12 / Apple M3, built-in
  FaceTime HD Camera confirmed via the `Found camera:` launch line, iPhone /
  Continuity Camera disconnected, AC power, no debugger, owner enrolled first):
  1. Idle CPU: Activity Monitor `% CPU` every minute for 10 minutes (owner
     seated configuration), report average and max → fill "After" column.
  2. Multi-face CPU: two / three people in range, every 15 s for 2 min each.
  3. Recognition frequency + latency: one short debug-enabled session per
     scenario; average `vision_fps`, `latency_ms` and `recognitions` from the
     ~2 s `metrics` events; cross-check with `capture_fps` / `throttled` from
     the ~5 s `capture_metrics` events.
  4. Per-request latency split (optional): Instruments Time Profiler, 30–60 s
     trace during the two-face run; inspect `VNDetectFaceRectanglesRequest` vs
     `VNGenerateImageFeaturePrintRequest` subtrees.
  5. Memory: Activity Monitor `Memory` column at start / after 10-min idle /
     after the multi-face run; flag any monotonic growth.
- **Status checklist (M3-T07 task mapping):**
  - [ ] CPU measured at idle — PENDING(manual) (§3)
  - [ ] CPU measured with 1/2/3 faces — PENDING(manual) (§3)
  - [ ] Recognition frequency measured — PENDING(manual); instrumented via `recognitions` counter (§1.1)
  - [ ] Face-detection latency measured — PENDING(manual); instrumented via `latency_ms` (§1.2)
  - [ ] Tracking overhead measured — PENDING(manual); not yet separately instrumented, static bound recorded (§1.2, §3)
  - [x] Frame skip / processing cadence tuned & documented — `frameSkip` is now a documented tuning constant (§4.1)
  - [x] Background monitoring responsiveness confirmed at code level (§7; runtime confirmation comes with the manual session)
  - [ ] Target < 15 % verified or reason documented — PENDING(manual) (this section)

---

## 6. Responsiveness (code-level confirmation)

Background monitoring stays responsive by construction:

- **App Nap / termination disabled** at launch:
  `ProcessInfo.processInfo.disableAutomaticTermination("Privacy Shield active")`
  and `beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], …)`
  (`AppDelegate.swift:20-22`) — camera + detection keep running while the app
  is backgrounded/occluded.
- **User-initiated QoS throughout the capture path**: the video output queue is
  `DispatchQueue(label: "com.privacyshield.videoqueue", qos: .userInitiated)`
  (`CameraManager.swift:11`) and the session starts on
  `DispatchQueue.global(qos: .userInitiated)` (`CameraManager.swift:141-145`).
- **No queue backlog**: `alwaysDiscardsLateVideoFrames = true`
  (`CameraManager.swift:125`) plus the `isProcessing` back-pressure guard
  (`FaceDetector.swift:199-200`) mean a slow frame is dropped, never queued —
  monitoring latency cannot grow over time.
- **Edge-driven UI**: shield/icon/notification calls fire only on shield-state
  *transitions*, on the main queue (`FaceDetector.swift:645-669`); the video
  queue never touches UI in steady state.
- **Thread confinement**: all detector/tracker/policy/filter state lives on the
  video output queue (`FaceDetector.swift:95-98` comment block; tracker
  documents the same contract, `FaceTracker.swift:165-168`), so no per-frame
  locking besides the O(1) capture-metrics lock (`CameraManager.swift:26-52`).

Runtime confirmation (menu stays snappy, hotkey works, no icon lag during a
30+ min background session) is part of the M4-T07 regression suite and of the
manual M3-T07 session; at code level nothing in the M3 pipeline blocks or
polls the main thread per frame.
