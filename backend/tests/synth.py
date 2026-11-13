"""Synthetic finger-camera PPG generator for tests (known HR / RR variability)."""
import numpy as np


def make_ppg(duration=40, fs=60, bpm=70, rr_sd_ms=30, noise=0.02, seed=0, dc=200.0, amp=1.5,
             dicrotic=0.35):
    rng = np.random.default_rng(seed)
    n_beats = int(duration * bpm / 60) + 5
    rr = rng.normal(60000 / bpm, rr_sd_ms, n_beats).clip(400, 1500) / 1000.0
    onsets = np.cumsum(rr) - rr[0] + 0.3
    t = np.arange(int(duration * fs)) / fs
    ppg = np.zeros_like(t)
    for o, r in zip(onsets, rr):
        ppg += np.exp(-0.5 * ((t - (o + 0.14)) / 0.055) ** 2)            # systolic
        ppg += dicrotic * np.exp(-0.5 * ((t - (o + 0.14 + 0.28)) / 0.09) ** 2)  # diastolic
    ppg += noise * rng.standard_normal(len(t)) * ppg.max()
    raw = dc - amp * ppg / ppg.max()     # camera intensity falls as blood volume rises
    true_rr = rr[1:len(onsets)]
    true_rmssd = float(np.sqrt(np.mean(np.diff(true_rr * 1000) ** 2)))
    return raw, fs, true_rmssd


def ppg_at(t_s, seed=0, bpm=70, rr_sd_ms=30, noise=0.03, dicrotic=0.35):
    """The SAME physiological waveform sampled at arbitrary (e.g. irregular, 50-60 fps) times.

    Ground truth is generated densely (480 Hz) and linearly interpolated, so tests can exercise
    non-uniform timestamps without inventing a different signal. Returns (raw, true_rmssd_ms).
    """
    t_s = np.asarray(t_s, dtype=float)
    dur = float(t_s[-1]) + 2.0
    raw, _, rmssd = make_ppg(duration=dur, fs=480, bpm=bpm, rr_sd_ms=rr_sd_ms, noise=0.0, seed=seed,
                             dicrotic=dicrotic)
    x = np.interp(t_s, np.arange(len(raw)) / 480.0, raw)
    rng = np.random.default_rng(seed + 1000)
    x = x + noise * rng.standard_normal(len(x)) * np.ptp(raw) * 0.5
    return x, rmssd


def variable_fps_times(duration, knots):
    """Timestamps whose instantaneous frame rate follows `knots` = [(time_s, fps), ...]."""
    kt, kf = zip(*knots)
    t = [0.0]
    while t[-1] < duration:
        t.append(t[-1] + 1.0 / float(np.interp(t[-1], kt, kf)))
    return np.array(t)
