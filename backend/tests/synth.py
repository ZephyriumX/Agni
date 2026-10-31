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
