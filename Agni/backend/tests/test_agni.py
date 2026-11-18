import numpy as np
import pytest
from fastapi.testclient import TestClient

import dsp_engine as d
import main
from storage import MemoryStore
from tests.synth import make_ppg


@pytest.fixture()
def client():
    main._store = MemoryStore()
    return TestClient(main.app)


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
    rr = np.array([800., 810., 790., 800.])
    assert d.rmssd(np.tile(rr, 3)) == pytest.approx(np.sqrt(np.mean(np.diff(np.tile(rr, 3)) ** 2)))


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
    flat = d.process_scan(np.full(len(raw), 200.0), fs)
    assert not flat.sqi.passed
    noise = d.process_scan(np.random.default_rng(1).normal(200, 1, len(raw)), fs)
    assert not noise.sqi.passed


def test_motion_artifact_rejected():
    raw, fs, _ = make_ppg()
    raw = raw.copy()
    rng = np.random.default_rng(3)
    for s in range(300, len(raw) - 120, 300):            # large bursts every 5 s
        raw[s:s + 90] += rng.normal(0, 4, 90).cumsum() * 0.5
    assert not d.process_scan(raw, fs).sqi.passed


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


def _post(client, tag, uid="u1", **kw):
    raw, fs, _ = make_ppg(**kw)
    return client.post("/api/v1/scan/process", json={"user_id": uid, "tag": tag, "fs": fs, "red": raw.tolist()})


def test_api_flow(client):
    r = _post(client, "Baseline", seed=1, bpm=65, rr_sd_ms=40)
    assert r.status_code == 200, r.text
    base = r.json(); assert base["sqi"]["passed"]
    r = _post(client, "Post-Meal", seed=2, bpm=82, rr_sd_ms=15, dicrotic=0.2)
    test = r.json(); assert test["sqi"]["passed"]
    c = client.post("/api/v1/scan/compare", json={
        "baseline_scan_id": base["scan_id"], "test_scan_id": test["scan_id"],
        "intervention_type": "Sitali Pranayama"})
    assert c.status_code == 200, c.text
    body = c.json()
    assert body["hrv_ratio"] < 1 and body["intervention_id"]
    assert body["interpretation"]["recommendations"]
    rep = client.get("/api/v1/reports/u1").json()
    assert len(rep["scans"]) == 2 and "raw_signal" not in rep["scans"][0]
    assert len(rep["comparisons"]) == 1 and len(rep["interventions"]) == 1
    assert main._store.users["u1"]["baseline_rmssd"] is not None


def test_api_errors(client):
    assert client.post("/api/v1/scan/process", json={"user_id": "u", "tag": "Nope", "fs": 60, "red": [1.0]}).status_code == 422
    assert client.post("/api/v1/scan/process", json={"user_id": "u", "tag": "Baseline", "fs": 30, "red": [1.0] * 2000}).status_code == 400
    assert client.post("/api/v1/scan/compare", json={"baseline_scan_id": "x", "test_scan_id": "y"}).status_code == 404
    assert client.get("/api/v1/reports/ghost").status_code == 404
    bad = _post(client, "Baseline", uid="u2", noise=0.0).json()
    flat = client.post("/api/v1/scan/process", json={"user_id": "u2", "tag": "Post-Meal", "fs": 60, "red": [200.0] * 2400}).json()
    assert not flat["sqi"]["passed"]
    assert client.post("/api/v1/scan/compare", json={"baseline_scan_id": bad["scan_id"], "test_scan_id": flat["scan_id"]}).status_code == 422


def test_api_key_enforced(client, monkeypatch):
    monkeypatch.setenv("AGNI_API_KEY", "secret")
    assert client.get("/health").status_code == 200
    assert client.get("/api/v1/reports/x").status_code == 401
    assert client.get("/api/v1/reports/x", headers={"X-API-Key": "secret"}).status_code == 404
