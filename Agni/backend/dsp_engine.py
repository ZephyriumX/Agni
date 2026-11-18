"""Agni-Pulse DSP & bio-signal engine.

Pipeline: raw camera intensity -> (invert) -> 4th-order zero-phase Butterworth band-pass
(0.5-5 Hz) -> VPG / APG derivatives -> beat detection -> a/b waves (b/a ratio) ->
RR intervals -> RMSSD, plus a Signal Quality Index (SQI).

Conventions
-----------
* Camera intensity FALLS when blood volume rises (more absorption), so the raw signal is
  inverted by default so that systolic peaks point upward.
* b/a is reported SIGNED, as in the APG literature: the b-wave is a negative deflection,
  so b/a is normally negative (about -1.0 young/compliant ... towards -0.3 stiffer).
  A rise (less negative / toward zero) is the stiffening direction.
* Only the standard library, numpy and scipy are used (no I/O) so this module is easy to
  unit-test and reuse on-device later.

Wellness use only - this is not a medical device.
"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Optional

import numpy as np
from scipy import signal as sps

from capture_validation import (DEFAULT_CAPTURE_CONFIG, FAIL, PASS, WARNING, CaptureConfig,  # noqa: F401
                                CaptureRejected, SignalError, combine_status, evaluate_timestamps,
                                reject_message, resample_uniform)

# --------------------------------------------------------------------------- config
F_LOW_HZ = 0.5
F_HIGH_HZ = 5.0
FILTER_ORDER = 4          # design order per PRD; sosfiltfilt makes it zero-phase
# Frame-rate / timing policy now lives in capture_validation.CaptureConfig (configurable, documented).
# Kept for backward compatibility: the hard minimum used when only a nominal fs (no timestamps) is given.
MIN_FS_HZ = DEFAULT_CAPTURE_CONFIG.hard_min_fps
ALGO_VERSION = "0.4.0"
MIN_DURATION_S = 15.0
RECOMMENDED_DURATION_S = 30.0   # ultra-short HRV is unreliable below ~30 s
SETTLE_TRIM_S = 2.0       # drop finger-placement / filter transient at the start
MIN_BEATS = 12
RR_MIN_MS, RR_MAX_MS = 300.0, 2000.0   # 30-200 bpm
RR_LOCAL_TOL = 0.30       # reject RR deviating >30% from local median (ectopic / missed beat)

# SQI thresholds
SQI_MIN_REL_STD = 1e-4    # AC std / DC below this => flatline / no finger
SQI_MIN_PI_PCT = 0.02     # perfusion index (AC/DC %) floor
SQI_MAX_PI_PCT = 40.0     # above => saturation / pressure artifact
SQI_MIN_SNR_DB = 3.0
SQI_MIN_TEMPLATE_CORR = 0.75
SQI_MAX_ARTIFACT_FRAC = 0.05


# --------------------------------------------------------------------------- results
@dataclass
class SQIResult:
    passed: bool
    status: str                       # "good" | "poor"
    reasons: list = field(default_factory=list)
    variance: float = 0.0             # variance of the filtered signal (normalised to DC)
    snr_db: float = float("nan")
    perfusion_index_pct: float = 0.0
    template_correlation: float = float("nan")
    artifact_fraction: float = 0.0
    n_beats: int = 0
    duration_s: float = 0.0


@dataclass
class ScanMetrics:
    ba_ratio: Optional[float]
    rmssd_ms: Optional[float]
    avg_bpm: Optional[float]
    n_beats: int
    n_rr: int
    sqi: SQIResult
    warnings: list = field(default_factory=list)
    channel: str = "red"
    da_ratio: Optional[float] = None
    aging_index: Optional[float] = None
    template: Optional[dict] = None
    acquisition: Optional[dict] = None

    def to_dict(self) -> dict:
        return asdict(self)


# --------------------------------------------------------------------------- stages
def preprocess(x: np.ndarray, fs: float, invert: bool = True) -> np.ndarray:
    """Remove non-finite samples by interpolation, cast to float, optionally invert."""
    x = np.asarray(x, dtype=float)
    if x.ndim != 1:
        raise SignalError("signal must be a 1-D array")
    bad = ~np.isfinite(x)
    if bad.mean() > 0.02:
        raise SignalError("more than 2% of samples are NaN/inf")
    if bad.any():
        idx = np.arange(len(x))
        x = np.interp(idx, idx[~bad], x[~bad])
    return -x if invert else x


def bandpass(x: np.ndarray, fs: float, low: float = F_LOW_HZ, high: float = F_HIGH_HZ,
             order: int = FILTER_ORDER) -> np.ndarray:
    """Zero-phase Butterworth band-pass (SOS form for numerical stability at 0.5 Hz)."""
    nyq = fs / 2.0
    if high >= nyq:
        raise SignalError(f"fs={fs} Hz too low for a {high} Hz cutoff")
    sos = sps.butter(order, [low / nyq, high / nyq], btype="bandpass", output="sos")
    return sps.sosfiltfilt(sos, x - np.mean(x))


def derivatives(x: np.ndarray, fs: float) -> tuple[np.ndarray, np.ndarray]:
    """Central-difference VPG and APG (same length as x; edges are zero-padded).

    v[n] = (x[n+1]-x[n-1]) / (2 dt);  a[n] = (x[n+1]-2x[n]+x[n-1]) / dt^2
    """
    dt = 1.0 / fs
    v = np.zeros_like(x)
    a = np.zeros_like(x)
    v[1:-1] = (x[2:] - x[:-2]) / (2 * dt)
    a[1:-1] = (x[2:] - 2 * x[1:-1] + x[:-2]) / dt**2
    return v, a


def _refine_peak(x: np.ndarray, i: int) -> float:
    """Parabolic interpolation -> sub-sample peak position (beats 16.7 ms quantisation at 60 Hz)."""
    if i <= 0 or i >= len(x) - 1:
        return float(i)
    y0, y1, y2 = x[i - 1], x[i], x[i + 1]
    d = y0 - 2 * y1 + y2
    return float(i) if d == 0 else float(i + 0.5 * (y0 - y2) / d)


def detect_systolic_peaks(ppg: np.ndarray, fs: float) -> np.ndarray:
    """Systolic peaks of the filtered PPG."""
    min_dist = int(0.33 * fs)                    # <= ~180 bpm
    prom = 0.3 * np.std(ppg)
    peaks, _ = sps.find_peaks(ppg, distance=min_dist, prominence=prom)
    return peaks


def _rr_from_peaks(peaks: np.ndarray, ppg: np.ndarray, fs: float) -> np.ndarray:
    """RR intervals in ms from sub-sample peak times, physiologically & locally filtered.

    Successive differences are only meaningful between ADJACENT valid intervals, so
    invalid intervals are returned as NaN (keeps position) and RMSSD skips NaN pairs.
    """
    t = np.array([_refine_peak(ppg, int(p)) for p in peaks]) / fs * 1000.0
    rr = np.diff(t)
    valid = (rr >= RR_MIN_MS) & (rr <= RR_MAX_MS)
    if valid.sum() >= 3:
        med = np.array([np.median(rr[max(0, i - 4): i + 5][valid[max(0, i - 4): i + 5]])
                        if valid[max(0, i - 4): i + 5].any() else np.nan
                        for i in range(len(rr))])
        valid &= np.abs(rr - med) <= RR_LOCAL_TOL * med
    return np.where(valid, rr, np.nan)


def rmssd(rr_ms: np.ndarray) -> Optional[float]:
    """RMSSD = sqrt( 1/(N-1) * sum (RR[i+1]-RR[i])^2 ) over adjacent valid pairs."""
    d = np.diff(rr_ms)
    d = d[np.isfinite(d)]
    if len(d) < 5:
        return None
    return float(np.sqrt(np.mean(d ** 2)))


def extract_apg_features(ppg: np.ndarray, apg: np.ndarray, peaks: np.ndarray, fs: float) -> dict:
    """Per-beat APG waves a,b (+ c,d,e when resolvable) -> robust (median) indices.

    For each systolic peak p: foot f = PPG minimum between previous peak and p;
    a = APG maximum in [f, p]; b = first APG local minimum after a (within 0.25 s);
    c = next local maximum, d = next local minimum, e = next local maximum (within ~0.45 s of b).
    Returns dict(ba, da, aging_index, n_ba, n_cde, template) - values None when unresolved.
    Aging index follows Takazawa: (b - c - d - e) / a.
    """
    ba, da, agi = [], [], []
    wins = []
    marks = {k: [] for k in "abcde"}
    for k, p in enumerate(peaks):
        prev = peaks[k - 1] if k > 0 else max(0, p - int(1.2 * fs))
        if p - prev < int(0.25 * fs):
            continue
        foot = prev + int(np.argmin(ppg[prev:p + 1]))
        seg = apg[foot:p + 1]
        if len(seg) < 3:
            continue
        a_i = foot + int(np.argmax(seg))
        a_val = apg[a_i]
        if a_val <= 0:
            continue
        end = min(len(apg) - 1, a_i + int(0.25 * fs))
        win = apg[a_i:end + 1]
        mins, _ = sps.find_peaks(-win)
        if len(mins) == 0:
            continue
        b_i = a_i + int(mins[0])
        b_val = apg[b_i]
        if b_val >= 0:                      # b must be a genuine negative deflection
            continue
        r = b_val / a_val
        if not (-3.0 < r < 1.0):            # discard implausible beats
            continue
        ba.append(r)
        wins.append(int(p))
        marks["a"].append((a_i - p) / fs); marks["b"].append((b_i - p) / fs)
        end2 = min(len(apg) - 2, b_i + int(0.45 * fs))
        tail = apg[b_i:end2 + 1]
        mx, _ = sps.find_peaks(tail)
        mn, _ = sps.find_peaks(-tail)
        if len(mx) >= 2 and len(mn) >= 1:
            c_i = b_i + int(mx[0])
            d_c = [m for m in mn if b_i + m > c_i]
            e_c = [m for m in mx if d_c and m > d_c[0]]
            if d_c and e_c:
                d_i, e_i = b_i + int(d_c[0]), b_i + int(e_c[0])
                c_v, d_v, e_v = apg[c_i], apg[d_i], apg[e_i]
                if c_v > 0 > d_v and e_v > 0:
                    da.append(d_v / a_val)
                    agi.append((b_val - c_v - d_v - e_v) / a_val)
                    marks["c"].append((c_i - p) / fs); marks["d"].append((d_i - p) / fs)
                    marks["e"].append((e_i - p) / fs)
    need = max(5, MIN_BEATS // 2)
    out = {"ba": float(np.median(ba)) if len(ba) >= need else None, "n_ba": len(ba),
           "da": float(np.median(da)) if len(da) >= need else None,
           "aging_index": float(np.median(agi)) if len(agi) >= need else None,
           "n_cde": len(da), "template": None}
    if out["ba"] is not None:
        out["template"] = _beat_template(ppg, apg, wins, marks, fs)
    return out


def _beat_template(ppg, apg, peak_idx, marks, fs, pre=0.3, post=0.7):
    """Ensemble-average beat aligned on the systolic peak (for the before/after graph)."""
    n0, n1 = int(pre * fs), int(post * fs)
    P, A = [], []
    for p in peak_idx:
        if p - n0 >= 0 and p + n1 <= len(ppg):
            seg = ppg[p - n0:p + n1]
            P.append(seg - seg.min())
            A.append(apg[p - n0:p + n1])
    if len(P) < 4:
        return None
    P, A = np.median(P, axis=0), np.median(A, axis=0)
    P = P / (np.max(P) or 1.0)
    A = A / (np.max(np.abs(A)) or 1.0)
    return {"fs": float(fs), "t0_s": -pre, "ppg": [round(float(v), 4) for v in P],
            "apg": [round(float(v), 4) for v in A],
            "marks_s": {k: round(float(np.median(v)), 4) for k, v in marks.items() if len(v) >= 4}}


def extract_ba_ratio(ppg, apg, peaks, fs):
    f = extract_apg_features(ppg, apg, peaks, fs)
    return f["ba"], f["n_ba"]


# --------------------------------------------------------------------------- SQI
def _snr_db(ppg: np.ndarray, fs: float, hr_hz: Optional[float]) -> float:
    """Power around the cardiac fundamental + 2nd harmonic vs the rest of 0.5-5 Hz."""
    if hr_hz is None:
        return float("-inf")
    nper = min(len(ppg), int(fs * 10))
    f, pxx = sps.welch(ppg, fs=fs, nperseg=nper, noverlap=nper // 2)
    band = (f >= F_LOW_HZ) & (f <= F_HIGH_HZ)
    sig = np.zeros_like(f, dtype=bool)
    for h in (1, 2, 3):   # window widens with harmonic order so normal HRV isn't scored as noise
        if h * hr_hz <= F_HIGH_HZ:
            sig |= np.abs(f - h * hr_hz) <= 0.25 * h
    ps = pxx[band & sig].sum()
    pn = pxx[band & ~sig].sum()
    return float(10 * np.log10(ps / pn)) if pn > 0 and ps > 0 else float("-inf")


def _template_correlation(ppg: np.ndarray, peaks: np.ndarray, fs: float) -> float:
    """Mean correlation of each beat with the median beat template (motion / morphology check)."""
    if len(peaks) < 4:
        return float("nan")
    half = int(0.4 * np.median(np.diff(peaks)))
    beats = [ppg[p - half:p + half] for p in peaks if p - half >= 0 and p + half <= len(ppg)]
    if len(beats) < 4:
        return float("nan")
    B = np.vstack(beats)
    tmpl = np.median(B, axis=0)
    if np.std(tmpl) == 0:
        return 0.0
    c = [np.corrcoef(b, tmpl)[0, 1] for b in B if np.std(b) > 0]
    return float(np.mean(c)) if c else 0.0


def _artifact_fraction(ppg: np.ndarray, fs: float) -> float:
    """Fraction of 0.5 s windows whose amplitude is a gross outlier (motion bursts)."""
    w = int(0.5 * fs)
    n = len(ppg) // w
    if n < 4:
        return 0.0
    amp = np.array([np.ptp(ppg[i * w:(i + 1) * w]) for i in range(n)])
    med = np.median(amp)
    if med == 0:
        return 1.0
    return float(np.mean((amp > 4 * med)))


def assess_quality(raw: np.ndarray, ppg: np.ndarray, peaks: np.ndarray, fs: float,
                   n_rr_valid: int, n_rr_total: int) -> SQIResult:
    reasons = []
    dc = float(np.mean(np.abs(raw))) or 1e-12
    rel_std = float(np.std(ppg) / dc)
    pi = 100.0 * rel_std * 2 * np.sqrt(2)     # approx AC(p-p)/DC for a sinusoid-like pulse
    hr_hz = (fs / np.median(np.diff(peaks))) if len(peaks) >= 3 else None
    snr = _snr_db(ppg, fs, hr_hz)
    tc = _template_correlation(ppg, peaks, fs)
    art = _artifact_fraction(ppg, fs)
    dur = len(raw) / fs

    if rel_std < SQI_MIN_REL_STD or pi < SQI_MIN_PI_PCT:
        reasons.append("flatline: no pulsatile signal (finger not covering camera / too light)")
    if pi > SQI_MAX_PI_PCT:
        reasons.append("signal saturated or excessive pressure artifact")
    if len(peaks) < MIN_BEATS:
        reasons.append(f"too few beats detected ({len(peaks)} < {MIN_BEATS})")
    if not np.isfinite(snr) or snr < SQI_MIN_SNR_DB:
        reasons.append(f"low SNR ({snr:.1f} dB < {SQI_MIN_SNR_DB} dB)")
    if np.isfinite(tc) and tc < SQI_MIN_TEMPLATE_CORR:
        reasons.append(f"beat morphology inconsistent (corr {tc:.2f}) - likely motion")
    if art > SQI_MAX_ARTIFACT_FRAC:
        reasons.append(f"motion artifact bursts in {art:.0%} of the recording")
    if n_rr_total and n_rr_valid / n_rr_total < 0.7:
        reasons.append("more than 30% of beat intervals rejected as irregular")

    return SQIResult(passed=not reasons, status="good" if not reasons else "poor",
                     reasons=reasons, variance=float(np.var(ppg) / dc ** 2), snr_db=snr,
                     perfusion_index_pct=float(pi), template_correlation=tc,
                     artifact_fraction=art, n_beats=int(len(peaks)), duration_s=float(dur))


# --------------------------------------------------------------------------- orchestration
def _analyse_channel(raw: np.ndarray, fs: float, invert: bool, name: str) -> ScanMetrics:
    x = preprocess(raw, fs, invert)
    trim = int(SETTLE_TRIM_S * fs)
    x = x[trim:]
    raw_trim = np.asarray(raw, dtype=float)[trim:]
    if len(x) < int(MIN_DURATION_S * fs):
        raise SignalError(f"need at least {MIN_DURATION_S + SETTLE_TRIM_S:.0f} s of signal")

    ppg = bandpass(x, fs)
    _, apg = derivatives(ppg, fs)
    peaks = detect_systolic_peaks(ppg, fs)

    rr = _rr_from_peaks(peaks, ppg, fs) if len(peaks) >= 2 else np.array([])
    n_valid = int(np.isfinite(rr).sum())
    sqi = assess_quality(raw_trim, ppg, peaks, fs, n_valid, len(rr))

    warnings = []
    if sqi.duration_s < RECOMMENDED_DURATION_S:
        warnings.append(f"recording {sqi.duration_s:.0f}s < {RECOMMENDED_DURATION_S:.0f}s: RMSSD is less reliable")

    ba, n_ba = (None, 0)
    feats = {"da": None, "aging_index": None, "template": None}
    rm = None
    bpm = None
    if len(peaks) >= 3:
        bpm = float(60000.0 / np.nanmedian(rr)) if n_valid else None
        rm = rmssd(rr)
        feats = extract_apg_features(ppg, apg, peaks, fs)
        ba, n_ba = feats["ba"], feats["n_ba"]
    if ba is None and sqi.passed:
        sqi.passed, sqi.status = False, "poor"
        sqi.reasons.append("could not resolve a/b waves reliably")
    if rm is None and sqi.passed:
        sqi.passed, sqi.status = False, "poor"
        sqi.reasons.append("not enough valid consecutive beats for RMSSD")

    return ScanMetrics(ba_ratio=ba, rmssd_ms=rm, avg_bpm=bpm, n_beats=int(len(peaks)),
                       n_rr=n_valid, sqi=sqi, warnings=warnings, channel=name,
                       da_ratio=feats["da"], aging_index=feats["aging_index"],
                       template=feats["template"])


def acquisition_check(t: np.ndarray, min_fs: Optional[float] = None,
                      cfg: Optional[CaptureConfig] = None) -> dict:
    """Validate REAL sample timing (sensor timestamps in seconds). Never fabricates a rate.

    Returns the acquisition report (status PASS or WARNING) or raises CaptureRejected (a SignalError)
    when the timing is FAIL. `min_fs`, if given, overrides the configured hard minimum fps.
    """
    cfg = cfg or DEFAULT_CAPTURE_CONFIG
    if min_fs is not None:
        from dataclasses import replace
        cfg = replace(cfg, hard_min_fps=float(min_fs), preferred_min_fps=max(float(min_fs), cfg.preferred_min_fps),
                      target_fps=max(float(min_fs), cfg.target_fps)).validate()
    rep = evaluate_timestamps(t, cfg)
    if rep["status"] == FAIL:
        raise CaptureRejected(reject_message(rep), rep)
    return rep


def process_scan(red: list[float] | np.ndarray, fs: Optional[float] = None,
                 green: Optional[list[float] | np.ndarray] = None,
                 invert: bool = True, timestamps: Optional[list[float]] = None,
                 capture_cfg: Optional[CaptureConfig] = None) -> ScanMetrics:
    """Full pipeline. Analyses red (and green if given) and returns the better-quality result.

    With `timestamps` (preferred): timing is judged by evaluate_timestamps(); the signal is linearly
    resampled to a uniform grid at the MEASURED mean rate (never relabelled as 60 Hz) and every filter,
    derivative and window then uses that true rate. The caller keeps the original timestamps.
    Timing and SQI are separate gates: this function never lets good timing rescue a failed SQI.
    """
    cfg = capture_cfg or DEFAULT_CAPTURE_CONFIG
    acq = None
    red = np.asarray(red, dtype=float)
    if timestamps is not None:
        t = np.asarray(timestamps, dtype=float)
        if len(t) != len(red):
            raise SignalError("timestamps and red must be the same length")
        if green is not None and len(green) != len(t):
            raise SignalError("red and green arrays must be the same length")
        acq = acquisition_check(t, cfg=cfg)
        fs = float(acq["effective_fs"])
        red = resample_uniform(t, red, fs)
        if green is not None:
            green = resample_uniform(t, green, fs)
        acq = {**acq, "resampled": True, "resample_method": "linear", "resampled_to_hz": round(fs, 3),
               "n_resampled": int(len(red))}
    else:
        if fs is None:
            raise SignalError("either timestamps or fs is required")
        if not np.isfinite(fs) or fs < cfg.hard_min_fps:
            raise SignalError(f"sampling rate {fs} Hz below the {cfg.hard_min_fps:g} Hz minimum")
    results = [_analyse_channel(red, fs, invert, "red")]
    if green is not None:
        green = np.asarray(green, dtype=float)
        if len(green) != len(red):
            raise SignalError("red and green arrays must be the same length")
        results.append(_analyse_channel(green, fs, invert, "green"))

    def score(m: ScanMetrics):
        s = m.sqi
        return (s.passed, s.snr_db if np.isfinite(s.snr_db) else -99, s.template_correlation
                if np.isfinite(s.template_correlation) else -1)
    best = max(results, key=score)
    best.acquisition = acq
    if acq is None:
        best.warnings.append(f"sampling rate {fs:g} Hz is nominal: frame timing was not verified (no timestamps)")
    else:
        best.warnings += [r["message"] for r in acq["reasons"]]
    return best


def percent_change_vascular_tone(test_ba: float, base_ba: float) -> float:
    """Delta Vascular Tone % = (test - base) / |base| * 100.

    PRD writes the denominator as (b/a)_baseline. Because b/a is negative, |baseline| is used so
    that a POSITIVE result always means b/a moved upward (toward stiffer) regardless of sign.
    """
    if base_ba == 0:
        raise ZeroDivisionError("baseline b/a is zero")
    return (test_ba - base_ba) / abs(base_ba) * 100.0


def hrv_ratio(test_rmssd: float, base_rmssd: float) -> float:
    if base_rmssd <= 0:
        raise ZeroDivisionError("baseline RMSSD must be > 0")
    return test_rmssd / base_rmssd
