# Baseline Metrics (M0-T03)

> Milestone: M0 — Repository & Baseline
> Branch: `feature/head-pose-attention`
> Recorded: 2026-10-13
> Machine info below was captured by running read-only commands on this machine.
> **All measured values are TODO(manual) — execution is pending** (Section 4).
> The baseline **build** was verified by the orchestrator (`xcodebuild` succeeded on this
> machine) against `PrivacyShield.xcodeproj`.

Related: `docs/baseline_behavior.md` (M0-T02), `docs/implement_todolist.md` (task definitions).

---

## 1. Machine info (recorded 2026-10-13)

Commands used (all read-only):

```bash
sysctl -n machdep.cpu.brand_string
sw_vers
system_profiler SPCameraDataType 2>/dev/null | head -40
sysctl hw.memsize
sysctl -n hw.model
```

Results:

| Property | Value |
|---|---|
| Mac model (`hw.model`) | `Mac15,12` (14-inch MacBook Pro) |
| CPU (`machdep.cpu.brand_string`) | Apple M3 |
| Memory (`hw.memsize`) | 25769803776 bytes (24 GiB) |
| macOS (`sw_vers`) | macOS 27.0.1, Build `26A434` |
| Camera (system-reported) | FaceTime HD Camera (built-in), Unique ID `3642F2CD-E322-42E7-9360-19815B003AA6` |
| Other cameras present | Continuity Camera "Tal的iPhone" (`iPhone18,1`) — also visible to the system |
| Camera source used by the app | `AVCaptureDevice.default(for: .video)` — the system default camera (`CameraManager.swift:50`) |
| Build | `PrivacyShield.xcodeproj`, verified by orchestrator via `xcodebuild` |

**Measurement caveat:** because the app grabs the *system default* camera, and an iPhone
Continuity Camera is also registered on this machine, every measurement session must first
confirm from the launch log (`Found camera: …`, `CameraManager.swift:54`) that the built-in
**FaceTime HD Camera** was selected. Prefer measuring with the iPhone disconnected.

---

## 2. Code-derived (static) expected metrics

These are derived from the source, not measured. Citations refer to the baseline code.

Capture configuration (`PrivacyShield/CameraManager.swift`):
`session.sessionPreset = .medium` (line 48), pixel format 32BGRA (lines 71-73),
`alwaysDiscardsLateVideoFrames = true` (line 70).

Processing cadence (`PrivacyShield/FaceDetector.swift`):
`frameSkip = 3` (line 24) with an `isProcessing` back-pressure guard (lines 60-61), so

```text
Vision processed FPS <= capture FPS / 3
actual processed FPS = min(capture FPS / 3, 1 / single-frame inference time)
```

Recognition load (`PrivacyShield/FaceDetector.swift:127-135`, `FaceRecognizer.swift:81-109`):
recognition runs on **every processed frame for every nearby face** — there is no tracking
or identity cache (that arrives with M2-T05/M2-T06). Per processed frame with N nearby faces
and one enrolled user with 8 stored prints:

```text
recognition work per processed frame =
    N × (face crop + new CIContext + VNGenerateImageFeaturePrintRequest)
        + up to N × 8 × computeDistance
```

Note the hysteresis counters count *processed frames*, not seconds
(`FaceDetector.swift:18-19`), so trigger/release timings scale with the actual processed
FPS — another reason the measured cadence matters.

### Metrics table

| Metric | Expected (code-derived) | Basis | Measured |
|---|---|---|---|
| Actual capture resolution | **640×360** | `sessionPreset = .medium` → `AVCaptureSessionPresetMedium` = 640×360 on FaceTime HD cameras (`CameraManager.swift:48`) | **TODO(manual)** |
| Capture FPS | **~30 FPS** | Preset default for .medium on built-in FaceTime HD; late frames discarded, no frame backlog handling (`CameraManager.swift:70`) | **TODO(manual)** |
| Vision processing frequency | **≤ 10 FPS** (captureFPS / frameSkip 3; lower if inference is slower than ~0.1 s) | `frameSkip = 3` + `isProcessing` guard (`FaceDetector.swift:24,60-61`) | **TODO(manual)** |
| Face detection latency | Statically unknown; expected low tens of ms per 640×360 frame on M3 | `VNDetectFaceRectanglesRequest` on every processed frame (`FaceDetector.swift:103-108`) | **TODO(manual)** |
| Face recognition latency | Statically unknown; scales with nearby-face count and enrolled prints (formula above) | Crop + `VNGenerateImageFeaturePrintRequest` + `computeDistance` per nearby face per processed frame (`FaceRecognizer.swift:81-161`) | **TODO(manual)** |
| Idle average CPU | Expected low single-digit % of one P-core (Vision at ≤ 10 FPS on 640×360 input) | Cadence above; Vision runs on Apple Silicon accelerated path | **TODO(manual)** |
| Peak CPU with two faces | Expected roughly 2× the single-nearby-face recognition load (two uncached recognitions per processed frame) | Recognition loop over all nearby faces (`FaceDetector.swift:129-135`) | **TODO(manual)** |
| Memory footprint | Statically unknown; expected small (two Vision model contexts + one 640×360 BGRA buffer in flight, `alwaysDiscardsLateVideoFrames`) | `CameraManager.swift:70-73` | **TODO(manual)** |

The `Measured` column is intentionally empty and marked `TODO(manual)`: the app currently
logs nothing about its capture stream (no resolution/FPS logging exists before M1-T03 adds
capture metrics), so these numbers require the manual protocol in Section 4.

---

## 3. What can be derived from existing logs (no code changes)

Two of the pending numbers can be estimated with existing `print` logging, before any
instrumentation lands:

- **Vision processed cadence:** run the calibration flow — it prints
  `Calibration sample N/10: face width = …` once per processed frame with a face visible
  (`FaceDetector.swift:85`). The timestamps of 10 consecutive lines give the processed-frame
  rate directly. The enrollment flow (`Enrollment [owner]: Captured sample N/8`,
  `FaceRecognizer.swift:52`) works the same way.
- **Trigger/release timing sanity:** show ≥ 3 processed frames, release ≥ 8 processed frames
  (`FaceDetector.swift:18-19`) — combined with the cadence above this predicts the expected
  ~0.3 s / ~0.8 s latencies to compare against manual stopwatch observations in
  `baseline_behavior.md` V6/V7.

Capture resolution and capture FPS cannot be observed through existing logs at baseline;
they are TODO(manual) below, with preset-derived expectations (640×360 @ ~30 FPS) recorded
in Section 2.

---

## 4. Measurement protocol (manual execution pending)

All measurements must be **reproducible on the primary development Mac** — the machine
recorded in Section 1 (Mac15,12, macOS 27.0.1 Build 26A434, built-in FaceTime HD Camera).
Repeat runs should land in the same ballpark; record the run date and any deviations.

### Preconditions

1. Build from `PrivacyShield.xcodeproj` with current Xcode (orchestrator-verified build).
2. Grant camera permission when prompted (or pre-grant in System Settings → Privacy &
   Security → Camera).
3. Confirm the launch log shows the built-in camera (`Found camera: FaceTime HD相机…` /
   FaceTime HD Camera) — disconnect the iPhone / disable Continuity Camera if it is picked
   instead (`CameraManager.swift:50` selects the system default).
4. Enroll the owner first (`baseline_behavior.md` V4) so the enrolled-path recognition cost
   is exercised.
5. Run on AC power; keep lighting and seating distance constant between runs; note the room
   condition in the results.
6. No debugger attached (attach only when sampling with Instruments).

### Tools

- **Xcode console / Console.app** — the app's `print` output (session logs, calibration and
  enrollment sample lines).
- **Activity Monitor** — `% CPU` and `Memory` columns for the `PrivacyShield` process.
- **Instruments → Time Profiler** — CPU averages and per-request latency breakdown.
- Optional CLI alternative to Instruments: `sample PrivacyShield 10 -file out.txt`.

### Steps

1. **Vision processing frequency (existing-log method, Section 3):** run Calibrate Detection
   Range twice with the face visible; note timestamps of the 10 `Calibration sample N/10`
   lines per run; derive processed FPS.
2. **Idle average CPU (10 min):** leave the owner seated alone at normal distance (or step
   away — choose one configuration and record it; note that an empty room keeps the shield
   blurred, which adds overlay-render cost, so owner-seated is the cleaner idle baseline).
   Record Activity Monitor `% CPU` every minute for 10 minutes; report average and max.
3. **Peak CPU with two faces (2 min):** have two people inside nearby range (normalized face
   width ≥ 0.8 × minFaceSize, i.e. ≥ 0.20 of frame width at defaults — this triggers the
   shield; if measuring the *unblurred* cost is preferred, enroll both people as trusted
   first and record that choice). Record Activity Monitor `% CPU` every 15 s for 2 minutes;
   report average and peak.
4. **Face detection / recognition latency (Instruments):** record a 30–60 s Time Profiler
   trace during step 3; inspect the time under
   `VNDetectFaceRectanglesRequest` and `VNGenerateImageFeaturePrintRequest` call subtrees to
   estimate per-request latency. Caveat: without per-frame signposts (arriving with M1-T06
   debug logging) these are best-effort estimates from sampling, not exact per-request
   timings — mark them as such in the results.
5. **Memory footprint:** read the `Memory` column in Activity Monitor at idle and again
   after the 10-minute idle run; also note it after the two-face run. Watch for growth
   between start and end (baseline has no known leak handling; `CIContext` is created per
   recognition call, `FaceRecognizer.swift:160`).
6. **Capture resolution / FPS (optional, post-baseline):** these require temporary
   instrumentation of `CameraManager` (log `CMVideoFormatDescription` dimensions and a
   frame counter) — defer to M1-T01/M1-T03, which add exactly this logging. Until then the
   preset-derived 640×360 @ ~30 FPS values in Section 2 stand as expectations only, and the
   Measured column stays `TODO(manual)`.

### Suggested sample durations

- Idle: **10 minutes**.
- Two faces: **2 minutes**.

### Reporting

Fill the `Measured` column of the Section 2 table (one row per metric, with date and
configuration notes), and keep this file as the canonical baseline reference for the M3-T07
performance comparison.

### Status

- [x] Mac model / macOS / camera source recorded (Section 1).
- [ ] All eight measured values recorded — **pending manual execution**.
- [ ] Numbers confirmed reproducible on the primary development Mac — pending.
