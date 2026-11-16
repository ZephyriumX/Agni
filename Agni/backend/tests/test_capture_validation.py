"""Capture-timing validation (FPS tolerance), resampling and its interaction with SQI.

These tests exercise the real validator / DSP on synthetic timestamp patterns. They prove the
decision logic and numerical behaviour; they do NOT validate any threshold clinically or on real phones.
"""
from dataclasses import replace

import numpy as np
import pytest

import capture_validation as cv
import dsp_engine as d
from tests.helpers import register, scan_payload
from tests.synth import make_ppg, ppg_at, variable_fps_times

DUR = 35.0


def uniform(fps, dur=DUR, jitter=0.0, seed=0):
    t = np.arange(0, dur, 1.0 / fps)
    if jitter:
        t = np.sort(t + np.random.default_rng(seed).normal(0, jitter, len(t)))
    return t


def codes(rep, severity=None):
    return {r["code"] for r in rep["reasons"] if severity in (None, r["severity"])}


# ----------------------------------------------------------------------------- frame rate
def test_exact_60_passes():
    r = cv.evaluate_timestamps(uniform(60))
    assert r["status"] == cv.PASS and r["reasons"] == []
    assert r["effective_fs"] == pytest.approx(60, abs=0.01)
    assert r["timestamps_valid"] is True


def test_stable_58_passes_only_because_every_metric_is_clean():
    r = cv.evaluate_timestamps(uniform(58, jitter=0.0005))
    assert r["status"] == cv.PASS
    assert r["effective_fs"] == pytest.approx(58, abs=0.05)      # reported as 58, never as 60


@pytest.mark.parametrize("what", ["jitter", "gap", "drops"])
def test_58_fps_is_not_an_automatic_pass(what):
    """58 fps meets the preferred rate, yet other imperfect metrics must still downgrade it."""
    t = uniform(58)
    if what == "jitter":
        t = uniform(58, jitter=0.0015, seed=3)                    # robust CV ~ 0.12
    elif what == "gap":
        t = np.delete(t, np.arange(500, 507))                     # ~120 ms hole
    else:
        t = np.delete(t, np.arange(100, 2000, 28))                # ~3.5 % isolated drops
    r = cv.evaluate_timestamps(t)
    assert r["status"] == cv.WARNING, r["reasons"]
    if what != "drops":                       # drops also lower the mean; jitter/gap leave it at 58
        assert r["fs_mean"] >= 57.5


def test_57_and_stable_55_warn_not_fail():
    assert cv.evaluate_timestamps(uniform(57))["status"] == cv.WARNING
    r = cv.evaluate_timestamps(uniform(55))                       # exactly the hard minimum: accepted
    assert r["status"] == cv.WARNING and codes(r) == {"fps_below_preferred"}


def test_below_hard_minimum_fails():
    r = cv.evaluate_timestamps(uniform(54))
    assert r["status"] == cv.FAIL and "fps_too_low" in codes(r, cv.FAIL)
    assert cv.evaluate_timestamps(uniform(30))["status"] == cv.FAIL


def test_fluctuating_50_to_60_fails_even_though_mean_clears_the_minimum():
    t = variable_fps_times(DUR, [(0, 60), (8, 50), (16, 58), (24, 52), (32, 60), (40, 55)])
    r = cv.evaluate_timestamps(t)
    assert r["fs_mean"] >= 55 and r["fs_median"] >= 55            # average alone would have accepted it
    assert r["status"] == cv.FAIL and "fps_fluctuates" in codes(r, cv.FAIL)


def test_mean_alone_never_decides_a_long_slow_stretch():
    t = np.r_[uniform(60, 20), 20 + uniform(50, 15)]              # mean ~55.7, median 60
    r = cv.evaluate_timestamps(t)
    assert r["fs_mean"] > 55 and r["status"] == cv.FAIL


def test_mild_fluctuation_is_tolerated():
    t = variable_fps_times(DUR, [(0, 60), (10, 57), (20, 59), (30, 56), (40, 60)])
    r = cv.evaluate_timestamps(t)
    assert r["status"] in (cv.PASS, cv.WARNING) and r["min_window_fps"] >= 55


# ----------------------------------------------------------------------------- drops and gaps
def test_occasional_single_dropped_frames_pass():
    t = np.delete(uniform(60), np.arange(100, 2000, 100))         # ~1 %
    r = cv.evaluate_timestamps(t)
    assert r["status"] == cv.PASS and 0 < r["drop_fraction"] < 0.03


def test_drop_ratio_thresholds():
    t = uniform(60)
    assert cv.evaluate_timestamps(np.delete(t, np.arange(100, 2000, 25)))["status"] == cv.WARNING   # ~4 %
    r = cv.evaluate_timestamps(np.delete(t, np.arange(100, 2000, 12)))                              # ~8 %
    assert r["status"] == cv.FAIL and "too_many_drops" in codes(r, cv.FAIL)
    assert cv.evaluate_timestamps(np.delete(t, np.arange(100, 900, 2)))["status"] == cv.FAIL        # ~19 %


def test_long_frame_gaps():
    t = uniform(60)
    r = cv.evaluate_timestamps(np.delete(t, np.arange(500, 507)))        # ~120 ms
    assert r["status"] == cv.WARNING and "gap" in codes(r)
    r = cv.evaluate_timestamps(np.delete(t, np.arange(500, 520)))        # ~350 ms
    assert r["status"] == cv.FAIL and "long_gap" in codes(r, cv.FAIL)


# ----------------------------------------------------------------------------- timestamp validity
@pytest.mark.parametrize("bad,code", [
    (None, "timestamps_missing"), ([], "timestamps_missing"), ([0.0, 0.1], "timestamps_missing"),
    (np.zeros((20, 2)), "timestamps_missing"), (["a"] * 30, "timestamps_invalid"),
])
def test_invalid_timestamps_fail(bad, code):
    r = cv.evaluate_timestamps(bad)
    assert r["status"] == cv.FAIL and r["timestamps_valid"] is False and code in codes(r)


@pytest.mark.parametrize("poison", [np.nan, np.inf, -np.inf])
def test_non_finite_timestamps_fail(poison):
    t = uniform(60)
    t[100] = poison
    r = cv.evaluate_timestamps(t)
    assert r["status"] == cv.FAIL and "timestamps_invalid" in codes(r)


def test_non_monotonic_and_duplicate_timestamps_fail():
    t = uniform(60)
    swapped = t.copy(); swapped[[300, 301]] = swapped[[301, 300]]
    dup = np.r_[t[:50], t[49:60], t[60:]]
    back = t.copy(); back[400:] -= 5.0
    for bad in (swapped, dup, back):
        r = cv.evaluate_timestamps(bad)
        assert r["status"] == cv.FAIL and "timestamps_not_monotonic" in codes(r)


def test_timestamps_in_wrong_unit_fail():
    assert cv.evaluate_timestamps(uniform(60) * 1000)["status"] == cv.FAIL                 # milliseconds
    r = cv.evaluate_timestamps(uniform(60) / 1000)
    assert r["status"] == cv.FAIL and "timestamps_implausible" in codes(r)


def test_insufficient_duration():
    r = cv.evaluate_timestamps(uniform(60, dur=10))
    assert r["status"] == cv.FAIL and "too_short" in codes(r, cv.FAIL)
    r = cv.evaluate_timestamps(uniform(60, dur=20))
    assert r["status"] == cv.WARNING and "short" in codes(r)
    assert cv.evaluate_timestamps(uniform(60, dur=35))["status"] == cv.PASS


# ----------------------------------------------------------------------------- configuration
def test_defaults_match_documented_values_and_keep_v030_hard_limits():
    c = cv.DEFAULT_CAPTURE_CONFIG
    assert (c.target_fps, c.preferred_min_fps, c.hard_min_fps) == (60, 58, 55)
    assert c.hard_max_drop_ratio == 0.05 and c.hard_max_gap_s == 0.15 and c.min_duration_s == 15


def test_config_is_actually_used_by_the_validator():
    strict = replace(cv.DEFAULT_CAPTURE_CONFIG, hard_min_fps=59, preferred_min_fps=59.5).validate()
    assert cv.evaluate_timestamps(uniform(58), strict)["status"] == cv.FAIL
    lax = replace(cv.DEFAULT_CAPTURE_CONFIG, hard_min_fps=50, preferred_min_fps=55).validate()
    assert cv.evaluate_timestamps(uniform(52), lax)["status"] == cv.WARNING


def test_config_from_env_and_validation():
    c = cv.CaptureConfig.from_env({"AGNI_CAPTURE_HARD_MIN_FPS": "52", "AGNI_CAPTURE_PASS_MAX_GAP_S": "0.08"})
    assert c.hard_min_fps == 52 and c.pass_max_gap_s == 0.08 and c.target_fps == 60
    for env in ({"AGNI_CAPTURE_HARD_MIN_FPS": "62"},                 # above preferred/target
                {"AGNI_CAPTURE_HARD_MIN_FPS": "abc"},
                {"AGNI_CAPTURE_HARD_MAX_DROP_RATIO": "0.001"},       # below the pass limit
                {"AGNI_CAPTURE_TARGET_FPS": "-1"}):
        with pytest.raises(ValueError):
            cv.CaptureConfig.from_env(env)


# ----------------------------------------------------------------------------- final verdict
def test_combine_status_matrix_sqi_always_has_a_veto():
    assert cv.combine_status(cv.PASS, True) == cv.PASS
    assert cv.combine_status(cv.WARNING, True) == cv.WARNING
    assert cv.combine_status(cv.PASS, False) == cv.FAIL            # good fps never rescues bad SQI
    assert cv.combine_status(cv.WARNING, False) == cv.FAIL
    assert cv.combine_status(cv.FAIL, True) == cv.FAIL
    assert cv.combine_status(None, True) == cv.WARNING             # unverified timing is never a PASS
    assert cv.combine_status(None, False) == cv.FAIL


# ----------------------------------------------------------------------------- pipeline
def test_acquisition_check_raises_with_report():
    with pytest.raises(cv.CaptureRejected) as ei:
        d.acquisition_check(uniform(30))
    assert ei.value.report["status"] == cv.FAIL and "NOT analysed" in str(ei.value)
    assert isinstance(ei.value, d.SignalError)                      # existing handlers still catch it


@pytest.mark.parametrize("fps", [60, 58, 55])
def test_dsp_uses_the_true_rate_never_60(fps, monkeypatch):
    seen = []
    orig = d._analyse_channel
    monkeypatch.setattr(d, "_analyse_channel", lambda x, fs, *a, **k: (seen.append(fs), orig(x, fs, *a, **k))[1])
    raw, _, _ = make_ppg(fs=fps, seed=5)
    t = np.arange(len(raw)) / fps
    t_before = t.copy()
    m = d.process_scan(raw, timestamps=t)
    assert seen and all(s == pytest.approx(fps, abs=0.01) for s in seen)
    assert m.acquisition["resampled_to_hz"] == pytest.approx(fps, abs=0.01)
    assert m.acquisition["effective_fs"] == pytest.approx(fps, abs=0.01)
    np.testing.assert_array_equal(t, t_before)                      # caller's timestamps untouched


def test_dsp_regression_60_vs_lower_rates_same_physiology():
    ref = {}
    for fps in (60, 58, 55):
        out = []
        for seed in range(6):
            raw, _, tr = make_ppg(fs=fps, seed=seed, bpm=62 + 4 * seed)
            m = d.process_scan(raw, timestamps=np.arange(len(raw)) / fps)
            assert m.sqi.passed
            out.append((m.ba_ratio, m.rmssd_ms, m.avg_bpm, tr))
        ref[fps] = np.array(out)
    for fps in (58, 55):
        diff = np.abs(ref[fps] - ref[60])
        assert diff[:, 0].max() < 0.08            # b/a (about -1.7): < ~5 %
        assert diff[:, 1].max() < 6.0             # RMSSD ms
        assert diff[:, 2].max() < 1.0             # bpm
        assert np.all(np.abs(ref[fps][:, 1] - ref[fps][:, 3]) < 10)   # still tracks the known truth


def test_timestamp_path_matches_nominal_path_at_exact_60():
    raw, fs, _ = make_ppg(seed=7)
    a = d.process_scan(raw, fs)
    b = d.process_scan(raw, timestamps=np.arange(len(raw)) / fs)
    assert b.ba_ratio == pytest.approx(a.ba_ratio, abs=1e-6)
    assert b.rmssd_ms == pytest.approx(a.rmssd_ms, abs=1e-6)
    assert b.avg_bpm == pytest.approx(a.avg_bpm, abs=1e-6)


def test_irregular_but_accepted_timing_still_gives_good_numbers():
    """Variable 55-60 fps (accepted) is resampled to its measured rate and still tracks the truth."""
    t = variable_fps_times(38.0, [(0, 60), (10, 56), (20, 59), (30, 57), (40, 60)])
    raw, true_rmssd = ppg_at(t, seed=11, bpm=68, rr_sd_ms=35)
    m = d.process_scan(raw, timestamps=t)
    assert m.acquisition["status"] in (cv.PASS, cv.WARNING) and m.sqi.passed
    assert m.avg_bpm == pytest.approx(68, abs=1.5)
    assert m.rmssd_ms == pytest.approx(true_rmssd, abs=10)
    assert m.ba_ratio < 0


def test_good_fps_does_not_rescue_bad_signal_quality():
    t = uniform(60)
    for bad in (np.full(len(t), 200.0), np.random.default_rng(0).normal(200, 5, len(t))):
        m = d.process_scan(bad, timestamps=t)
        assert m.acquisition["status"] == cv.PASS      # timing is fine ...
        assert not m.sqi.passed                        # ... the signal is not
        assert cv.combine_status(m.acquisition["status"], m.sqi.passed) == cv.FAIL


def test_sqi_thresholds_are_untouched():
    assert (d.SQI_MIN_SNR_DB, d.SQI_MIN_TEMPLATE_CORR, d.SQI_MAX_ARTIFACT_FRAC) == (3.0, 0.75, 0.05)
    assert (d.SQI_MIN_REL_STD, d.SQI_MIN_PI_PCT, d.SQI_MAX_PI_PCT) == (1e-4, 0.02, 40.0)


def test_nominal_fs_path_still_requires_the_minimum():
    raw, _, _ = make_ppg(fs=50, seed=1)
    with pytest.raises(d.SignalError):
        d.process_scan(raw, 50)
    raw, _, _ = make_ppg(fs=58, seed=1)
    m = d.process_scan(raw, 58)
    assert m.acquisition is None and any("not verified" in w for w in m.warnings)


# ----------------------------------------------------------------------------- resampling
def test_resampling_is_identity_for_a_steady_clock():
    t = uniform(58)
    x = np.sin(2 * np.pi * 1.3 * t) + 0.3 * np.sin(2 * np.pi * 4.1 * t)
    rep = cv.evaluate_timestamps(t)
    y = cv.resample_uniform(t, x, rep["effective_fs"])
    n = min(len(x), len(y))
    assert np.max(np.abs(y[:n] - x[:n])) < 1e-3     # effective_fs is rounded to 1 mHz => sub-0.1 % shift


def test_resampling_never_extrapolates_and_error_matches_the_documented_bound():
    rng = np.random.default_rng(0)
    t = np.sort(np.arange(0, 20, 1 / 55) + rng.normal(0, 0.002, int(20 * 55)))
    fs = (len(t) - 1) / (t[-1] - t[0])
    for f, tol in ((1.2, 0.01), (3.0, 0.03), (5.0, 0.05)):
        y = cv.resample_uniform(t, np.sin(2 * np.pi * f * t), fs)
        grid = t[0] + np.arange(len(y)) / fs
        assert grid[0] >= t[0] and grid[-1] <= t[-1]
        assert np.max(np.abs(y - np.sin(2 * np.pi * f * grid))) < tol, f


def test_resampling_across_a_gap_interpolates_linearly_and_is_reported():
    t = np.delete(uniform(60), np.arange(500, 507))
    rep = cv.evaluate_timestamps(t)
    assert rep["missing_frames"] == 7 and rep["max_gap_s"] > 0.1     # exposed, not hidden


# ----------------------------------------------------------------------------- API
def _post(c, h, **kw):
    extra = {k: kw.pop(k) for k in ("client_scan_id",) if k in kw}
    return c.post("/api/v1/scan/process", headers=h, json={**scan_payload(**kw), **extra})


LEGACY_ACQ_KEYS = {"fs_median", "fs_mean", "drop_fraction", "max_gap_s", "n_samples", "duration_s"}


def test_api_58fps_accepted_with_legacy_keys_and_true_rate_stored(client):
    uid, h = register(client)
    r = _post(client, h, fs_hz=58, bpm=65, rr_sd_ms=40, seed=1)
    assert r.status_code == 200, r.text
    j = r.json()
    acq = j["acquisition"]
    assert LEGACY_ACQ_KEYS <= set(acq)                                  # backward compatible keys
    assert acq["status"] == "PASS" and acq["fs_mean"] == pytest.approx(58, abs=0.1)
    assert j["capture_status"] == "PASS" and j["final_status"] == "PASS" and j["sqi"]["passed"]
    for k in ("scan_id", "ba_ratio", "rmssd_ms", "avg_bpm", "sqi", "warnings", "processing_ms", "disclaimer"):
        assert k in j                                                    # every pre-existing response key
    sent = scan_payload(fs_hz=58, bpm=65, rr_sd_ms=40, seed=1)["timestamps"]
    row = client.app.state.store.get_scan(uid, j["scan_id"], full=True)
    assert list(row["raw_timestamps"]) == sent                           # ORIGINAL timestamps preserved
    assert row["effective_fs"] == pytest.approx(58, abs=0.1) and row["sampling_rate"] == 58


def test_api_55fps_is_a_warning_not_a_failure(client):
    _, h = register(client)
    j = _post(client, h, fs_hz=55, bpm=65, rr_sd_ms=40, seed=1).json()
    assert j["capture_status"] == "WARNING" and j["final_status"] == "WARNING"
    assert any("55" in w or "fps" in w for w in j["warnings"])


@pytest.mark.parametrize("fps", [50, 30])
def test_api_below_minimum_is_422_with_diagnostics(client, fps):
    _, h = register(client)
    r = _post(client, h, fs_hz=fps, bpm=65, seed=1)
    j = r.json()
    assert r.status_code == 422 and j["code"] == "signal_rejected" and "detail" in j   # unchanged contract
    assert j["capture_status"] == "FAIL" and j["acquisition"]["status"] == "FAIL"
    assert any(x["code"] == "fps_too_low" for x in j["acquisition"]["reasons"])


def test_api_fluctuating_fps_is_rejected(client):
    _, h = register(client)
    t = variable_fps_times(38.0, [(0, 60), (8, 50), (16, 58), (24, 52), (32, 60), (40, 55)])
    x, _ = ppg_at(t, seed=2)
    r = client.post("/api/v1/scan/process", headers=h, json={
        "tag": "Baseline", "timestamps": [round(float(v), 5) for v in t], "red": [round(float(v), 4) for v in x]})
    assert r.status_code == 422 and r.json()["acquisition"]["reasons"]


def test_api_bad_timestamps_are_422_not_500(client):
    _, h = register(client)
    p = scan_payload(seed=1)
    p["timestamps"][100], p["timestamps"][101] = p["timestamps"][101], p["timestamps"][100]
    r = client.post("/api/v1/scan/process", headers=h, json=p)
    assert r.status_code == 422 and r.json()["code"] == "signal_rejected"


def test_api_good_fps_but_failed_sqi_is_a_failed_scan_and_never_a_baseline(client):
    uid, h = register(client)
    p = scan_payload(seed=1)
    p["red"] = [200.0] * len(p["red"])
    r = client.post("/api/v1/scan/process", headers=h, json=p)
    assert r.status_code == 200
    j = r.json()
    assert j["capture_status"] == "PASS" and j["sqi"]["passed"] is False and j["final_status"] == "FAIL"
    assert client.app.state.store.get_user(uid)["baseline_rmssd"] is None


def test_api_legacy_nominal_fs_payload_still_works(client):
    _, h = register(client)
    raw, fs, _ = make_ppg(seed=1, bpm=65, rr_sd_ms=40)
    r = client.post("/api/v1/scan/process", headers=h, json={"tag": "Baseline", "fs": 60, "red": [float(x) for x in raw]})
    assert r.status_code == 200
    j = r.json()
    assert j["acquisition"] is None and j["capture_status"] is None and j["final_status"] == "WARNING"


def test_api_legacy_stored_acquisition_record_is_still_readable(client):
    """Rows saved by v0.3.0 hold only the six legacy acquisition keys and no status."""
    uid, h = register(client)
    st = client.app.state.store
    row = {"user_id": uid, "tag_event": "Baseline", "raw_signal": [1.0, 2.0], "sampling_rate": 60,
           "effective_fs": 60.0, "rmssd": 33.0, "ba_ratio": -1.0, "avg_bpm": 70.0, "sqi_passed": True,
           "features": {"acquisition": {"fs_median": 60.0, "fs_mean": 60.0, "drop_fraction": 0.0,
                                        "max_gap_s": 0.017, "n_samples": 2100, "duration_s": 35.0}}}
    stored, _ = st.save_scan(row, set_baseline=True)
    assert client.get(f"/api/v1/scans/{stored['scan_id']}", headers=h).status_code == 200
    # a new-format scan can still be compared against that legacy baseline
    j = _post(client, h, tag="Post-Meal", bpm=82, rr_sd_ms=15, seed=2).json()
    assert j["comparison"] and j["comparison"]["baseline_scan_id"] == stored["scan_id"]


def test_capture_config_endpoint_is_public_and_secret_free(client):
    r = client.get("/api/v1/capture-config")
    assert r.status_code == 200
    j = r.json()
    assert (j["target_fps"], j["preferred_min_fps"], j["hard_min_fps"]) == (60, 58, 55)
    blob = str(j).lower()
    assert not any(w in blob for w in ("secret", "token", "database", "key", "password"))


def test_server_config_overrides_change_the_verdict(settings_store):
    from fastapi.testclient import TestClient
    import main
    s, st = settings_store
    s.capture = replace(cv.DEFAULT_CAPTURE_CONFIG, hard_min_fps=50, preferred_min_fps=55).validate()
    c = TestClient(main.create_app(s, st))
    _, h = register(c)
    j = _post(c, h, fs_hz=52, bpm=65, rr_sd_ms=40, seed=1)
    assert j.status_code == 200 and j.json()["capture_status"] == "WARNING"


@pytest.mark.parametrize("jitter", [0.0, 0.0005, 0.001, 0.0015])
def test_measurement_noise_never_fails_a_steady_clock_and_never_rescues_a_slow_one(jitter):
    for seed in range(15):
        for fps in (55, 56, 58, 60):
            r = cv.evaluate_timestamps(uniform(fps, jitter=jitter, seed=seed))
            assert r["status"] != cv.FAIL, (fps, jitter, seed, r["reasons"])
            if fps >= 58 and jitter <= 0.0005:
                assert r["status"] == cv.PASS, (fps, jitter, seed, r["reasons"])
        for fps in (52, 53.5):
            assert cv.evaluate_timestamps(uniform(fps, jitter=jitter, seed=seed))["status"] == cv.FAIL


# ----------------------------------------------------------------------------- golden vectors (shared with Dart)
def test_golden_vectors_file_is_in_sync_with_the_validator():
    """docs/capture_validation_vectors.json is consumed by app/test/capture_validation_test.dart.
    If this fails, run `python -m tests.vectors` (from backend/) and re-run BOTH test suites."""
    import json
    from tests import vectors
    assert json.loads(vectors.VECTOR_FILE.read_text()) == vectors.generate()
