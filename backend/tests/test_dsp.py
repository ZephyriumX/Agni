import numpy as np
import pytest

import dsp_engine as d
from tests.synth import make_ppg


def test_bandpass_passband_and_stopband():
    fs = 60; t = np.arange(0, 30, 1 / fs)
    x = lambda f: np.sin(2 * np.pi * f * t)
    rms = lambda y: np.sqrt(np.mean(y[300:-300] ** 2))
    assert rms(d.bandpass(x(1.5), fs)) > 0.65          # passband (~0.707 RMS)
    assert rms(d.bandpass(x(0.05), fs)) < 0.02          # baseline wander removed
    assert rms(d.bandpass(x(15), fs)) < 0.02            # high-freq removed


def test_derivatives_of_sine():
    fs = 100; t = np.arange(0, 5, 1 / fs); w = 2 * np.pi
    v, a = d.derivatives(np.sin(w * t), fs)
    assert np.allclose(v[5:-5], w * np.cos(w * t)[5:-5], atol=0.05)
    assert np.allclose(a[5:-5], -w ** 2 * np.sin(w * t)[5:-5], atol=0.3)


def test_rmssd_formula():
    rr = np.tile(np.array([800., 810., 790., 800.]), 3)
    assert d.rmssd(rr) == pytest.approx(np.sqrt(np.mean(np.diff(rr) ** 2)))


@pytest.mark.parametrize("kw", [dict(bpm=60), dict(bpm=80, rr_sd_ms=20), dict(bpm=100, rr_sd_ms=15), dict(bpm=55, rr_sd_ms=50)])
def test_metrics_accuracy(kw):
    raw, fs, true_rmssd = make_ppg(**kw)
    m = d.process_scan(raw, fs)
    assert m.sqi.passed, m.sqi.reasons
    assert m.avg_bpm == pytest.approx(kw["bpm"], abs=2.5)
    assert m.rmssd_ms == pytest.approx(true_rmssd, rel=0.2, abs=5)
    assert -3 < m.ba_ratio < 0


def test_ba_ratio_stable_across_noise_seeds():
    vals = [d.process_scan(*make_ppg(seed=s, noise=0.05)[:2]).ba_ratio for s in range(5)]
    assert np.std(vals) < 0.15


def test_flatline_and_noise_rejected():
    raw, fs, _ = make_ppg()
    assert not d.process_scan(np.full(len(raw), 200.0), fs).sqi.passed
    assert not d.process_scan(np.random.default_rng(1).normal(200, 1, len(raw)), fs).sqi.passed


def test_fs_and_length_validation():
    raw, _, _ = make_ppg()
    with pytest.raises(d.SignalError):
        d.process_scan(raw, 30)
    with pytest.raises(d.SignalError):
        d.process_scan(raw[:300], 60)


def test_percent_change_sign_convention():
    assert d.percent_change_vascular_tone(-0.5, -1.0) == pytest.approx(50.0)   # toward stiffer
    assert d.percent_change_vascular_tone(-1.2, -1.0) == pytest.approx(-20.0)
    assert d.hrv_ratio(30, 60) == 0.5


def test_acquisition_check_rejects_slow_and_dropped():
    with pytest.raises(d.SignalError, match="NOT"):
        d.acquisition_check(np.arange(0, 35, 1 / 30))
    t = np.arange(0, 35, 1 / 60)
    with pytest.raises(d.SignalError, match="dropped"):
        d.acquisition_check(np.delete(t, np.arange(100, 900, 2)))       # ~19% dropped
    with pytest.raises(d.SignalError, match="dropped"):
        d.acquisition_check(np.delete(t, np.arange(500, 520)))          # 330 ms hole
    with pytest.raises(d.SignalError):
        d.acquisition_check(np.r_[t[:50], t[49:60], t[60:]])            # duplicate timestamp
    assert d.acquisition_check(t)["fs_mean"] == pytest.approx(60, abs=0.1)


def test_timestamp_jitter_tolerated():
    raw, fs, _ = make_ppg(seed=4)
    t = np.sort(np.arange(len(raw)) / fs + np.random.default_rng(1).normal(0, 0.001, len(raw)))
    m = d.process_scan(raw, timestamps=t)
    assert m.sqi.passed and m.avg_bpm == pytest.approx(70, abs=2.5)


def test_cde_features_resolved():
    raw, fs, _ = make_ppg(seed=3)
    m = d.process_scan(raw, fs)
    assert m.da_ratio is not None and m.aging_index is not None
    assert set(m.template["marks_s"]) >= {"a", "b"} and len(m.template["ppg"]) == len(m.template["apg"])


def _bandlimited(rng, n, fs, lo=0.4, hi=4.0):
    from scipy import signal as sps
    sos = sps.butter(2, [lo / (fs / 2), hi / (fs / 2)], btype="band", output="sos")
    x = sps.sosfilt(sos, rng.normal(size=n))
    return x / np.std(x)


def _artifact(kind, seed):
    raw, fs, _ = make_ppg(seed=seed, noise=0.02)
    rng = np.random.default_rng(seed)
    raw = raw.copy()
    n = len(raw)
    pulse = np.ptp(raw)
    if kind == "motion":        # in-band motion (finger moving), continuous, ~pulse amplitude
        raw += pulse * rng.uniform(0.6, 1.5) * _bandlimited(rng, n, fs)
    elif kind == "bursts":      # intermittent large in-band bursts
        m = _bandlimited(rng, n, fs)
        env = np.zeros(n)
        for s in range(int(rng.integers(100, 250)), n - 150, int(rng.integers(300, 500))):
            env[s:s + int(rng.integers(60, 150))] = 1
        raw += pulse * rng.uniform(1.5, 4) * m * env
    elif kind == "noise":       # very poor contact: noise dominates
        raw = 200 + rng.normal(0, 1.0, n) + 0.05 * (raw - 200)
    elif kind == "steps":       # pressure changes -> abrupt DC steps with clipping
        for s in range(300, n - 100, 500):
            raw[s:] += rng.choice([-6, 6])
        raw = np.clip(raw, 190, 205)
    elif kind == "flat":
        raw = np.full(n, 200.0) + rng.normal(0, 1e-5, n)
    return raw, fs


@pytest.mark.parametrize("kind", ["motion", "bursts", "noise", "steps", "flat"])
def test_sqi_rejects_artifacts(kind):
    """PRD success metric: reject >90% of scans with motion artifacts (synthetic proxy only)."""
    rejected = sum(not d.process_scan(*_artifact(kind, s)).sqi.passed for s in range(20))
    assert rejected / 20 > 0.9, f"{kind}: only {rejected}/20 rejected"


def test_clean_scans_mostly_accepted():
    ok = sum(d.process_scan(*make_ppg(seed=s, bpm=60 + 3 * s, noise=0.03)[:2]).sqi.passed for s in range(20))
    assert ok >= 18
