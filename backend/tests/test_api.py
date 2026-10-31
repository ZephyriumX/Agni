import time
import uuid

import pytest

from tests.helpers import register, scan_payload

BASE = dict(bpm=65, rr_sd_ms=40, seed=1)
MEAL = dict(bpm=82, rr_sd_ms=15, seed=2, dicrotic=0.2)


def post_scan(c, h, tag, **kw):
    extra = {k: kw.pop(k) for k in ("client_scan_id", "meal_id", "compare_to", "context") if k in kw}
    return c.post("/api/v1/scan/process", headers=h, json={**scan_payload(tag, **kw), **extra})


def test_full_flow(client):
    uid, h = register(client, prakriti_type="Pitta")
    r = post_scan(client, h, "Baseline", **BASE)
    assert r.status_code == 200, r.text
    base = r.json()
    assert base["sqi"]["passed"] and base["ba_ratio"] < 0 and base["comparison"] is None
    assert base["acquisition"]["fs_mean"] == pytest.approx(60, abs=0.5)

    meal = client.post("/api/v1/meals", headers=h, json={"name": "Jalebi", "perceived_load": 4}).json()
    test = post_scan(client, h, "Post-Meal", meal_id=meal["meal_id"], context=["Caffeine"], **MEAL).json()
    cmp_ = test["comparison"]
    assert cmp_ and cmp_["baseline_scan_id"] == base["scan_id"]
    assert cmp_["hrv_ratio"] < 0.7 and cmp_["verdict"] == "Incompatible"
    assert cmp_["interpretation"]["recommendations"] and cmp_["interpretation"]["dials"]["stability"]

    rep = client.get(f"/api/v1/reports/{uid}", headers=h).json()
    assert len(rep["scans"]) == 2 and len(rep["comparisons"]) == 1
    assert rep["baseline_scan_id"] == base["scan_id"]
    assert all("raw_signal" not in s and "raw_timestamps" not in s for s in rep["scans"])
    assert client.get("/api/v1/me", headers=h).json()["baseline_rmssd"] == pytest.approx(base["rmssd_ms"], abs=0.06)

    d = client.get("/api/v1/diary", headers=h).json()
    assert d["ranked"][0]["name"] == "Jalebi" and d["ranked"][0]["verdict"] == "Incompatible"

    c = client.post("/api/v1/scan/compare", headers=h, json={
        "baseline_scan_id": base["scan_id"], "test_scan_id": test["scan_id"],
        "intervention_type": "Sitali Pranayama"})
    assert c.status_code == 200 and c.json()["intervention"]["type"] == "Sitali Pranayama"
    rep = client.get(f"/api/v1/reports/{uid}", headers=h).json()
    assert len(rep["comparisons"]) == 1 and len(rep["interventions"]) == 1   # upsert, no duplicates


def test_vajrasana_before_after(client):
    _, h = register(client)
    post_scan(client, h, "Baseline", **BASE)
    pre = post_scan(client, h, "Post-Meal", **MEAL).json()
    post = post_scan(client, h, "Post-Vajrasana", compare_to=pre["scan_id"], bpm=70, rr_sd_ms=35, seed=5).json()
    comp = post["comparison"]
    assert comp["baseline_scan_id"] == pre["scan_id"]
    assert comp["intervention"]["type"] == "Vajrasana"
    assert comp["interpretation"]["directional_improvement"] in (True, False)
    assert post["template"]["ppg"] and pre["template"]["apg"]


def test_idempotent_upload(client):
    _, h = register(client)
    cid = str(uuid.uuid4())
    a = post_scan(client, h, "Baseline", client_scan_id=cid, **BASE).json()
    b = post_scan(client, h, "Baseline", client_scan_id=cid, **BASE).json()
    assert a["scan_id"] == b["scan_id"] and b["duplicate"] and not a["duplicate"]


def test_rejects_slow_camera_and_bad_input(client):
    _, h = register(client)
    r = client.post("/api/v1/scan/process", headers=h, json=scan_payload("Baseline", fs_hz=30, **BASE))
    assert r.status_code == 422 and r.json()["code"] == "signal_rejected" and "30" in r.json()["detail"]
    assert client.post("/api/v1/scan/process", headers=h, json={"tag": "Nope", "fs": 60, "red": [1.0] * 100}).status_code == 422
    assert client.post("/api/v1/scan/process", headers=h, json={"tag": "Baseline", "red": [1.0] * 100}).status_code == 422
    flat = {"tag": "Baseline", "fs": 60, "red": [200.0] * 2400}
    out = client.post("/api/v1/scan/process", headers=h, json=flat).json()
    assert out["sqi"]["passed"] is False and out["sqi"]["reasons"]
    assert client.post("/api/v1/scan/process", headers=h, json={**flat, "red": [200.0] * 99999}).status_code in (413, 422)


def test_failed_quality_scan_cannot_be_compared(client):
    _, h = register(client)
    good = post_scan(client, h, "Baseline", **BASE).json()
    bad = client.post("/api/v1/scan/process", headers=h, json={"tag": "Post-Meal", "fs": 60, "red": [200.0] * 2400}).json()
    assert bad["comparison"] is None
    r = client.post("/api/v1/scan/compare", headers=h, json={"baseline_scan_id": good["scan_id"], "test_scan_id": bad["scan_id"]})
    assert r.status_code == 422


def test_authorization_isolation(client):
    ua, ha = register(client)
    ub, hb = register(client)
    s = post_scan(client, ha, "Baseline", **BASE).json()
    t = post_scan(client, ha, "Post-Meal", **MEAL).json()
    assert client.get(f"/api/v1/scans/{s['scan_id']}", headers=hb).status_code == 404
    assert client.get(f"/api/v1/reports/{ua}", headers=hb).status_code == 403
    assert client.post("/api/v1/scan/compare", headers=hb, json={"baseline_scan_id": s["scan_id"], "test_scan_id": t["scan_id"]}).status_code == 404
    assert client.post("/api/v1/scan/process", headers=hb, json={**scan_payload("Post-Meal", **MEAL), "compare_to": s["scan_id"]}).json()["comparison"] is None
    r = client.post("/api/v1/scan/process", headers=hb, json={**scan_payload("Baseline", **BASE), "user_id": ua})   # body user_id ignored
    rep = client.get(f"/api/v1/reports/{ua}", headers=ha).json()
    assert all(x["scan_id"] != r.json()["scan_id"] for x in rep["scans"])


def test_auth_required(client):
    assert client.get("/health").status_code == 200
    assert client.get("/api/v1/me").status_code == 401
    assert client.get("/api/v1/me", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.post("/api/v1/scan/process", json={}).status_code == 401


def test_body_limit(client):
    _, h = register(client)
    assert client.post("/api/v1/scan/process", headers=h, json={"tag": "Baseline", "fs": 60, "red": [1.0] * 400_000}).status_code == 413


def test_latency_under_2s(client):
    _, h = register(client)
    t0 = time.perf_counter()
    r = post_scan(client, h, "Baseline", duration=35, **BASE)
    assert r.status_code == 200
    assert r.json()["processing_ms"] < 2000 and time.perf_counter() - t0 < 2.5


def test_ready(client):
    assert client.get("/ready").json()["ok"] is True
