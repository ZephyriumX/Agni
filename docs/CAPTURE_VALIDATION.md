# Capture timing validation (FPS tolerance)

Status of this document: describes **Phase 2** (backend + Android/Dart). iOS is a later phase.

> Every number below is an initial **engineering parameter**, not a clinically validated limit.
> They are configurable; nothing here has been validated against real phones or against a reference device.

## What changed and why

v0.3.0 rejected any capture below 59.5 fps in two places: the Android capability gate
(`CameraCaps.pick`, `fps - 0.5`) and the server (`acquisition_check`). A phone that really delivers
~58 fps was refused although the DSP is sampling-rate parameterised (every filter/derivative/window
takes `fs`). The rule is now a **timing quality evaluation** on the real sensor timestamps.

## Where the policy lives (single source)

| Layer | Role |
|---|---|
| `backend/capture_validation.py` → `CaptureConfig` | The thresholds. Environment overrides `AGNI_CAPTURE_*` (see `.env.example`). Invalid or inconsistent values stop startup. |
| `GET /api/v1/capture-config` | Public, secret-free copy for the app. |
| `app/lib/capture_validation.dart` | Port of the evaluator for immediate on-device diagnostics. Falls back to bundled defaults (same values) when the server is unreachable. |
| Kotlin / native | Holds **no** thresholds. Receives `targetFps` and `minFps` from Dart. Hardware pre-check only; if `minFps` is not passed it behaves like v0.3.0 (strict). |

The server is authoritative. Both evaluators are checked against the same golden vectors
(`docs/capture_validation_vectors.json`, regenerate with `cd backend && python -m tests.vectors`).

## Metrics (all computed from monotonic sensor timestamps)

mean fps · median-interval fps · interval variability (robust CV = 1.4826·MAD/median) · dropped-frame ratio
(missing frames inferred from intervals > 1.5× median) · longest gap · short-window fps (2 s windows, stride 1 s)
· duration · timestamp validity (finite, strictly increasing, plausible unit).

## Verdict (timing only)

Defaults: target 60 · preferred ≥ 58 · hard minimum 55 (the weaker of mean/median fps is used, `fps_tolerance` 0.25).

| | PASS | WARNING | FAIL |
|---|---|---|---|
| fps | ≥ 58 | 55 – 58 | < 55 |
| dropped frames | ≤ 3 % | ≤ 5 % | > 5 % (unchanged from v0.3.0) |
| longest gap | ≤ 100 ms | ≤ 150 ms | > 150 ms (unchanged) |
| interval variability | ≤ 0.10 | ≤ 0.20 | > 0.20 |
| share of 2 s windows below 55 fps | ≤ 2 % | ≤ 10 % | > 10 % |
| duration | ≥ 30 s | 15 – 30 s | < 15 s (unchanged) |
| timestamps | valid | – | NaN/inf, duplicate or backwards, implausible unit, < 10 samples |

The overall timing status is the **worst** of the rows. Meeting 58 fps is therefore *not* an automatic PASS:
a 58 fps capture with a 120 ms gap, 3.5 % drops or irregular intervals is a WARNING; a 55 fps average that hides
long stretches at 50 fps is a FAIL. The average alone never decides.

`fps_tolerance` (0.25 fps) exists because the median interval is noisy by ~0.1–0.3 fps at 0.5–1.5 ms timestamp
jitter, and window counts resolve only to one frame (1/window_s); without it a steady 58 or 55 fps clock was
mis-judged in testing. Reports always show the raw measured values.

## Timing and signal quality are separate gates

`combine_status(timing, sqi_passed)`: a failed SQI is FAIL whatever the fps; a timing FAIL is FAIL whatever the SQI
(the API refuses to analyse it, HTTP 422 `signal_rejected`, with the full report in `acquisition`). A timing PASS never
rescues a poor signal. **No SQI, perfusion, RR, or physiological threshold was changed.**

API (additive only): `acquisition` gains `status`, `reasons[]`, `effective_fs`, `jitter_cv`, `missing_frames`,
`min_window_fps`, `low_window_fraction`, `resampled_to_hz`, `resample_method`, …; the response gains `capture_status`
and `final_status`. All v0.3.0 keys are unchanged. No DB migration: new data lives inside the existing
`features.acquisition` JSON; old rows (six legacy keys, no status) remain readable.

## Sampling-rate handling

* The original timestamps are stored verbatim (`raw_timestamps`) with the measured `effective_fs`.
* The signal is linearly interpolated onto a uniform grid at the **measured mean rate** (not floored, not 60) and every
  filter/derivative/window then uses that true rate. A 58 fps recording is never relabelled 60 fps.
* Steady clock → grid coincides with the samples (identity). Jittery clock → linear interpolation acts as a mild
  low-pass: worst-case amplitude error `1-cos(π f/fs)` ≈ 4 % at the 5 Hz band edge, 0.4 % at 1.5 Hz (fs = 55).
* Across missing frames it draws straight lines, i.e. it synthesises samples. That is why drops and gaps are limited
  and reported (`drop_fraction`, `missing_frames`, `max_gap_s`). Higher-order/spline resampling was not adopted: it
  would invent more structure inside gaps, not less.
* Without timestamps (legacy `fs`-only payload) timing is unverified: it still needs `fs ≥ hard_min_fps`, the scan carries
  a warning and its final status can never be a plain PASS.

## What the tests show (and do not)

`backend/tests/test_capture_validation.py` (68 test cases): exact 60, stable 58 / 57 / 55 / 54, 50–60 fluctuation, mean-hides-dips,
isolated drops, long gaps, NaN / inf / non-monotonic / duplicate / wrong-unit timestamps, short captures, SQI failure with
good fps, config overrides and validation, resampling error bound, steady-clock identity, DSP regression (60 vs 58 vs 55 fps
on identical synthetic physiology), API compatibility, legacy records, golden vectors. They use **synthetic** signals.
They prove the logic and numerical stability; they do **not** validate the thresholds clinically or on real phones.
