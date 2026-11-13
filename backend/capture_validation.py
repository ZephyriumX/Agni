"""Timestamp-based capture validation (FPS tolerance) for Agni-Pulse.

Design rules (see docs/CAPTURE_VALIDATION.md):
  * Validate the REAL sensor timestamps, never the advertised frame rate.
  * Several independent measurements are evaluated together: mean fps, median fps, interval
    variability, dropped-frame ratio, longest gap, short-window fps (fluctuation) and duration.
    No single number (in particular the average fps) can by itself make a capture pass.
  * Result is PASS / WARNING / FAIL. This is a statement about the TIMING of the capture only.
    Signal quality (SQI) is evaluated separately in dsp_engine and can still fail a scan whose
    timing is PASS. `combine_status()` is the only place the two are merged, and FAIL always wins.
  * Nothing here changes any SQI or physiological threshold.
  * All numbers below are initial engineering parameters, NOT clinically validated limits.
    Every one is configurable (CaptureConfig / AGNI_CAPTURE_* environment variables).
"""
from __future__ import annotations

import math
import os
from dataclasses import asdict, dataclass, fields
from typing import Optional

import numpy as np

PASS, WARNING, FAIL = "PASS", "WARNING", "FAIL"


class SignalError(ValueError):
    """Capture or signal cannot support PPG/APG analysis (mapped to HTTP 422 by the API)."""


class CaptureRejected(SignalError):
    """Timing validation FAILED. Carries the full diagnostic report for the client."""

    def __init__(self, message: str, report: dict):
        super().__init__(message)
        self.report = report


@dataclass(frozen=True)
class CaptureConfig:
    # --- frame rate -------------------------------------------------------------------------
    target_fps: float = 60.0            # what we ask the camera for
    preferred_min_fps: float = 58.0     # PASS needs both mean and median fps >= this
    hard_min_fps: float = 55.0          # FAIL below this (mean or median)
    fps_tolerance: float = 0.25         # measurement resolution: the median interval is noisy by ~0.1-0.3 fps
                                        # at 0.5-1.5 ms timestamp jitter; thresholds are met within this slack
    # --- dropped frames (fraction of frames that should exist but are missing) ----------------
    pass_max_drop_ratio: float = 0.03
    hard_max_drop_ratio: float = 0.05   # unchanged from v0.3.0
    # --- longest single gap between consecutive frames (seconds) --------------------------------
    pass_max_gap_s: float = 0.10
    hard_max_gap_s: float = 0.15        # unchanged from v0.3.0
    # --- interval variability: robust CV = 1.4826*MAD(dt)/median(dt) --------------------------
    pass_max_jitter_cv: float = 0.10
    hard_max_jitter_cv: float = 0.20
    # --- short-window fps (catches fps that wanders even when the mean looks fine) -------------
    window_s: float = 2.0
    pass_max_low_window_fraction: float = 0.02   # share of windows below hard_min_fps
    hard_max_low_window_fraction: float = 0.10
    # --- duration of the timestamped capture (the app scans for 35 s) -----------------------------
    min_duration_s: float = 15.0                 # unchanged from v0.3.0
    recommended_duration_s: float = 30.0
    # --- timestamp sanity -----------------------------------------------------------------------
    max_plausible_fps: float = 1000.0            # beyond this the timestamps are not seconds

    def validate(self) -> "CaptureConfig":
        pos = ("target_fps", "preferred_min_fps", "hard_min_fps", "window_s", "min_duration_s",
               "recommended_duration_s", "hard_max_gap_s", "pass_max_gap_s", "max_plausible_fps")
        if not (isinstance(self.fps_tolerance, (int, float)) and 0 <= self.fps_tolerance <= 1.0):
            raise ValueError("capture config: fps_tolerance must be within [0, 1] fps")
        for n in pos:
            v = getattr(self, n)
            if not (isinstance(v, (int, float)) and math.isfinite(v) and v > 0):
                raise ValueError(f"capture config: {n} must be a positive number, got {v!r}")
        if not (self.hard_min_fps <= self.preferred_min_fps <= self.target_fps):
            raise ValueError("capture config: need hard_min_fps <= preferred_min_fps <= target_fps")
        if not (0 <= self.pass_max_drop_ratio <= self.hard_max_drop_ratio < 1):
            raise ValueError("capture config: need 0 <= pass_max_drop_ratio <= hard_max_drop_ratio < 1")
        if not (0 < self.pass_max_gap_s <= self.hard_max_gap_s):
            raise ValueError("capture config: need pass_max_gap_s <= hard_max_gap_s")
        if not (0 <= self.pass_max_jitter_cv <= self.hard_max_jitter_cv):
            raise ValueError("capture config: need pass_max_jitter_cv <= hard_max_jitter_cv")
        if not (0 <= self.pass_max_low_window_fraction <= self.hard_max_low_window_fraction <= 1):
            raise ValueError("capture config: need pass/hard low-window fractions ordered within [0,1]")
        if self.min_duration_s > self.recommended_duration_s:
            raise ValueError("capture config: min_duration_s must be <= recommended_duration_s")
        return self

    @staticmethod
    def from_env(env=os.environ) -> "CaptureConfig":
        """AGNI_CAPTURE_<FIELD_NAME_UPPERCASE> overrides, e.g. AGNI_CAPTURE_HARD_MIN_FPS=55."""
        kw = {}
        for f in fields(CaptureConfig):
            raw = env.get("AGNI_CAPTURE_" + f.name.upper())
            if raw not in (None, ""):
                try:
                    kw[f.name] = float(raw)
                except ValueError:
                    raise ValueError(f"AGNI_CAPTURE_{f.name.upper()}={raw!r} is not a number") from None
        return CaptureConfig(**kw).validate()

    def public(self) -> dict:
        """Safe to expose to clients (GET /api/v1/capture-config): thresholds only, no secrets."""
        return asdict(self)


DEFAULT_CAPTURE_CONFIG = CaptureConfig().validate()


def _reason(code: str, severity: str, message: str) -> dict:
    return {"code": code, "severity": severity, "message": message}


def measure_timing(t: np.ndarray, cfg: CaptureConfig) -> dict:
    """Raw timing measurements from strictly increasing timestamps (seconds). No judgement here."""
    dt = np.diff(t)
    med = float(np.median(dt))
    duration = float(t[-1] - t[0])
    fs_mean = (len(t) - 1) / duration
    fs_median = 1.0 / med
    mad = float(np.median(np.abs(dt - med)))
    jitter_cv = 1.4826 * mad / med
    # Missing frames: an interval much longer than the typical one means frames were not delivered.
    # Counting the missing frames per interval (instead of comparing n to duration/median) stays
    # meaningful when the rate wanders.
    long = dt > 1.5 * med
    missing = int(np.sum(np.maximum(np.round(dt[long] / med) - 1, 0)))
    drop_ratio = missing / (len(t) + missing)
    # Short-window fps: frames per second inside sliding windows (stride = window/2).
    win = cfg.window_s
    n_win, low = 0, 0
    min_win_fps = fs_mean
    if duration >= win:
        starts = np.arange(t[0], t[-1] - win + 1e-9, win / 2.0)
        idx0 = np.searchsorted(t, starts, side="left")
        idx1 = np.searchsorted(t, starts + win, side="left")
        wfps = (idx1 - idx0) / win
        n_win = len(wfps)
        # a window holds a whole number of frames, so its fps resolves only to 1/window_s: allow that one frame
        low = int(np.sum(wfps + max(cfg.fps_tolerance, 1.0 / win) < cfg.hard_min_fps))
        min_win_fps = float(np.min(wfps))
    return {
        "fs_mean": float(fs_mean), "fs_median": float(fs_median),
        "effective_fs": float(fs_mean),                 # the rate used for ALL downstream DSP
        "jitter_cv": float(jitter_cv), "drop_ratio": float(drop_ratio), "missing_frames": missing,
        "max_gap_s": float(dt.max()), "n_samples": int(len(t)), "duration_s": duration,
        "min_window_fps": float(min_win_fps), "n_windows": int(n_win),
        "low_window_fraction": (low / n_win) if n_win else 0.0,
    }


def evaluate_timestamps(t, cfg: Optional[CaptureConfig] = None) -> dict:
    """Judge a capture from its sensor timestamps. Never raises for a poor capture: it returns a
    report whose "status" is PASS / WARNING / FAIL and whose "reasons" explain the verdict.

    The report always carries every legacy key of acquisition_check() (fs_median, fs_mean,
    drop_fraction, max_gap_s, n_samples, duration_s) so existing clients and stored records stay valid.
    """
    cfg = cfg or DEFAULT_CAPTURE_CONFIG
    reasons: list[dict] = []
    base = {"target_fps": cfg.target_fps, "preferred_min_fps": cfg.preferred_min_fps,
            "hard_min_fps": cfg.hard_min_fps}

    def failed(code, msg, **extra):
        reasons.append(_reason(code, FAIL, msg))
        return {**base, "status": FAIL, "reasons": reasons, "timestamps_valid": False, **extra}

    try:
        t = np.asarray(t, dtype=float)
    except (TypeError, ValueError):
        return failed("timestamps_invalid", "Timestamps are missing or not numeric.")
    if t.ndim != 1 or len(t) < 10:
        return failed("timestamps_missing", "Timestamps are missing or too few to measure frame timing.")
    if not np.all(np.isfinite(t)):
        return failed("timestamps_invalid", "Timestamps contain invalid (NaN/infinite) values.")
    dt = np.diff(t)
    if np.any(dt <= 0):
        bad = int(np.sum(dt <= 0))
        return failed("timestamps_not_monotonic",
                      f"Timestamps are not strictly increasing ({bad} duplicate/out-of-order frames). "
                      "The camera clock cannot be trusted for this recording.", n_samples=int(len(t)))
    m = measure_timing(t, cfg)
    if m["fs_median"] > cfg.max_plausible_fps or m["fs_mean"] > cfg.max_plausible_fps:
        return failed("timestamps_implausible",
                      f"Timestamps imply {m['fs_mean']:.0f} fps, which is implausible; they are probably "
                      "not in seconds.", n_samples=m["n_samples"])

    # Both mean and median must clear the bar, so the weaker one counts. `fps_tolerance` absorbs
    # measurement noise (and float error such as 54.99999999999999 < 55); it is added, not hidden:
    # reports show the raw measured fps.
    eff = min(m["fs_mean"], m["fs_median"]) + cfg.fps_tolerance
    # --- frame rate ---
    if eff < cfg.hard_min_fps:
        reasons.append(_reason("fps_too_low", FAIL,
                               f"Camera delivered {eff:.1f} fps, below the {cfg.hard_min_fps:g} fps minimum."))
    elif eff < cfg.preferred_min_fps:
        reasons.append(_reason("fps_below_preferred", WARNING,
                               f"Camera delivered {eff:.1f} fps (preferred {cfg.preferred_min_fps:g}+, "
                               f"minimum {cfg.hard_min_fps:g})."))
    # --- dropped frames ---
    if m["drop_ratio"] > cfg.hard_max_drop_ratio:
        reasons.append(_reason("too_many_drops", FAIL,
                               f"{m['drop_ratio']:.1%} of frames were dropped (limit {cfg.hard_max_drop_ratio:.0%})."))
    elif m["drop_ratio"] > cfg.pass_max_drop_ratio:
        reasons.append(_reason("some_drops", WARNING, f"{m['drop_ratio']:.1%} of frames were dropped."))
    # --- gaps ---
    if m["max_gap_s"] > cfg.hard_max_gap_s:
        reasons.append(_reason("long_gap", FAIL,
                               f"Longest gap between frames was {m['max_gap_s'] * 1000:.0f} ms "
                               f"(limit {cfg.hard_max_gap_s * 1000:.0f} ms)."))
    elif m["max_gap_s"] > cfg.pass_max_gap_s:
        reasons.append(_reason("gap", WARNING, f"Longest gap between frames was {m['max_gap_s'] * 1000:.0f} ms."))
    # --- interval variability ---
    if m["jitter_cv"] > cfg.hard_max_jitter_cv:
        reasons.append(_reason("unstable_intervals", FAIL,
                               f"Frame intervals are too irregular (variability {m['jitter_cv']:.0%})."))
    elif m["jitter_cv"] > cfg.pass_max_jitter_cv:
        reasons.append(_reason("jittery_intervals", WARNING,
                               f"Frame intervals are somewhat irregular (variability {m['jitter_cv']:.0%})."))
    # --- fluctuating fps ---
    lw = m["low_window_fraction"]
    if lw > cfg.hard_max_low_window_fraction:
        reasons.append(_reason("fps_fluctuates", FAIL,
                               f"Frame rate dropped below {cfg.hard_min_fps:g} fps for {lw:.0%} of the recording "
                               f"(lowest {m['min_window_fps']:.0f} fps over {cfg.window_s:g} s)."))
    elif lw > cfg.pass_max_low_window_fraction:
        reasons.append(_reason("fps_dips", WARNING,
                               f"Frame rate briefly dipped below {cfg.hard_min_fps:g} fps "
                               f"(lowest {m['min_window_fps']:.0f} fps over {cfg.window_s:g} s)."))
    # --- duration ---
    if m["duration_s"] < cfg.min_duration_s:
        reasons.append(_reason("too_short", FAIL,
                               f"Capture lasted {m['duration_s']:.1f} s; at least {cfg.min_duration_s:g} s is required."))
    elif m["duration_s"] < cfg.recommended_duration_s:
        reasons.append(_reason("short", WARNING,
                               f"Capture lasted {m['duration_s']:.1f} s; {cfg.recommended_duration_s:g} s+ is recommended."))

    sev = {r["severity"] for r in reasons}
    status = FAIL if FAIL in sev else (WARNING if WARNING in sev else PASS)
    return {
        **base, "status": status, "reasons": reasons, "timestamps_valid": True,
        "fs_median": round(m["fs_median"], 2), "fs_mean": round(m["fs_mean"], 2),
        "effective_fs": round(m["effective_fs"], 3),
        "drop_fraction": round(m["drop_ratio"], 4), "missing_frames": m["missing_frames"],
        "max_gap_s": round(m["max_gap_s"], 4), "jitter_cv": round(m["jitter_cv"], 4),
        "min_window_fps": round(m["min_window_fps"], 1), "low_window_fraction": round(m["low_window_fraction"], 4),
        "n_samples": m["n_samples"], "duration_s": round(m["duration_s"], 2),
    }


def reject_message(report: dict) -> str:
    fails = [r["message"] for r in report.get("reasons", []) if r["severity"] == FAIL]
    tail = " Close other apps, keep the phone cool, and rescan."
    return " ".join(fails) + (tail if report.get("timestamps_valid") else "") + \
        " The recording was NOT analysed; its true timestamps are kept and it is never relabelled as a different fps."


def combine_status(timing_status: Optional[str], sqi_passed: bool) -> str:
    """Final scan status. Timing and SQI are independent gates; FAIL on either is FAIL.

    A timing PASS never rescues a failed SQI, and (because the API rejects timing FAILs) a good SQI
    never rescues bad timing either.
    """
    if not sqi_passed or timing_status == FAIL:
        return FAIL
    if timing_status == PASS:
        return PASS
    return WARNING          # WARNING, or timing not verified (no timestamps): never a plain PASS


def resample_uniform(t: np.ndarray, x: np.ndarray, fs: float) -> np.ndarray:
    """Linear interpolation of x(t) onto a uniform grid at `fs` (the MEASURED effective rate).

    * The grid lies inside [t[0], t[-1]]; nothing is extrapolated.
    * When the camera clock is steady, fs equals the true frame rate and the grid coincides with the
      original sample times, so the operation is (numerically) the identity.
    * With timing jitter, linear interpolation acts as a mild low-pass filter. For frequency f the
      worst-case amplitude error (midway between two samples) is 1-cos(pi*f/fs): about 4 % at the 5 Hz
      band edge and 0.4 % at a typical 1.5 Hz pulse fundamental, for fs = 55 fps. It applies only to
      samples that actually have to move.
    * Across a missing-frame gap it draws a straight line, i.e. it synthesises samples. This is why
      drops and gaps are limited by the validator and why the report exposes `drop_fraction`.
    """
    t = np.asarray(t, dtype=float)
    n = int(np.floor((t[-1] - t[0]) * fs + 1e-6)) + 1      # includes the last sample; never past t[-1]
    grid = t[0] + np.arange(n) / fs
    grid = grid[grid <= t[-1]]
    return np.interp(grid, t, np.asarray(x, dtype=float))
