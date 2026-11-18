"""Analytics engine: unit tests on hand-built histories (known answers) + an API integration test."""
from datetime import datetime, timedelta, timezone

import pytest

import analytics as an
from tests.helpers import scan_payload

NOW = datetime(2026, 11, 18, 12, 0, tzinfo=timezone.utc)
_n = 0


def sc(tag, ba, rmssd, bpm, days_ago=0.0, ok=True, **kw):
    global _n
    _n += 1
    return {"scan_id": f"s{_n}", "timestamp": (NOW - timedelta(days=days_ago)).isoformat(), "tag_event": tag,
            "ba_ratio": ba, "rmssd": rmssd, "avg_bpm": bpm, "sqi_passed": ok, "context_tags": [],
            "meal_id": None, "intervention": None, "features": {"acquisition": {"fs_mean": 59.8, "status": "PASS"}},
            "sqi_report": {"reasons": [] if ok else ["low perfusion: finger pressure"]}, **kw}


USER = {"user_id": "u", "prakriti_type": "Pitta", "prakriti_scores": {"vata": 2, "pitta": 6, "kapha": 2}}


def baselines(n=5, start=20):
    return [sc("Baseline", -1.70 + 0.02 * (i % 2), 40 + (i % 3), 70 + (i % 2), days_ago=start - i * 3) for i in range(n)]


def test_empty_history_gives_a_first_step_and_no_crash():
    a = an.build(USER, [], [], [], now=NOW)
    assert a["overview"]["all_time_scans"] == 0 and a["baseline"]["n"] == 0
    assert a["insights"][0]["title"] == "Record your first baseline"


def test_baseline_stats_and_normal_range():
    b = an.baseline_stats(baselines(5))
    rm = b["metrics"]["rmssd"]
    assert b["n"] == 5 and b["reliability"] == "established"
    assert rm["mean"] == pytest.approx(40.8) and rm["sd"] == pytest.approx(0.837, abs=0.01)
    assert rm["normal_range"][0] < rm["mean"] < rm["normal_range"][1]
    assert an.baseline_stats(baselines(2))["metrics"]["rmssd"]["normal_range"] is None     # n<3: not estimated
    assert an.baseline_stats([sc("Baseline", -1.7, 40, 70, ok=False)])["n"] == 0            # failed SQI ignored


def test_significance_uses_personal_sd_then_fixed_threshold():
    assert an.significance("rmssd", 30, 40, 4)["level"] == "clear"         # 2.5 SD
    assert an.significance("rmssd", 36, 40, 4)["level"] == "possible"
    assert an.significance("rmssd", 39, 40, 4)["level"] == "normal"
    f = an.significance("rmssd", 25, 40, None)
    assert f["method"] == "fixed_threshold" and f["level"] == "clear"     # 0.625 < 0.7 PRD threshold


def test_meal_ranking_contexts_and_insights():
    meals = [{"meal_id": "m1", "name": "Poha", "eaten_at": (NOW - timedelta(days=2, minutes=40)).isoformat(),
              "descriptors": ["light"], "meal_type": "breakfast"},
             {"meal_id": "m2", "name": "Chole bhature", "eaten_at": (NOW - timedelta(days=1, minutes=35)).isoformat(),
              "descriptors": ["fried", "heavy"], "meal_type": "lunch"},
             {"meal_id": "m3", "name": "chole BHATURE ", "eaten_at": (NOW - timedelta(hours=1)).isoformat(),
              "descriptors": ["fried", "heavy"], "meal_type": "lunch"}]
    scans = baselines(5) + [
        sc("Post-Meal", -1.68, 39, 74, days_ago=2, meal_id="m1"),
        sc("Post-Meal", -1.40, 24, 86, days_ago=1, meal_id="m2"),
        sc("Post-Meal", -1.45, 26, 84, days_ago=1 / 48, meal_id="m3", context_tags=["Caffeine"]),
    ]
    a = an.build(USER, scans, meals, [], now=NOW)
    names = [m["name"] for m in a["meals"]]
    assert names[0] == "Poha" and len(a["meals"]) == 2                     # same meal name grouped (case/space)
    chole = a["meals"][1]
    assert chole["n"] == 2 and chole["hrv_ratio_mean"] < 0.7 and chole["effect"] == "strong stress response"
    assert chole["minutes_after_meal_median"] == pytest.approx(32.5, abs=1)   # 35 and 30 min
    fried = next(d for d in a["meal_descriptors"] if d["descriptor"] == "fried")
    assert fried["n"] == 2
    titles = " | ".join(i["title"] for i in a["insights"])
    assert "'Poha' suits you better than 'Chole bhature'" in titles
    assert "Fried meals lower your HRV" in titles
    assert "For your Pitta constitution" in titles
    resp = a["responses"][-1]
    assert resp["rmssd"]["level"] == "clear" and resp["rmssd"]["direction"] == "worse"
    assert resp["tone_pct"] > 10                                           # b/a moved toward zero = stiffer
    caf = next(c for c in a["contexts"] if c["context"] == "Caffeine")
    assert caf["with"]["n"] == 1 and caf["without"]["n"] == 2


def test_intervention_pairs_with_the_scan_just_before():
    pre = sc("Post-Meal", -1.40, 25, 85, days_ago=1.0)
    post = sc("Post-Intervention", -1.60, 33, 78, days_ago=1.0 - 15 / 1440, intervention="Vajrasana")
    lone = sc("Post-Vajrasana", -1.75, 42, 70, days_ago=5)                   # no pre scan -> vs baseline
    a = an.build(USER, baselines(5) + [pre, post, lone], [], [], now=NOW)
    iv = a["interventions"][0]
    assert iv["type"] == "Vajrasana" and iv["n"] == 2 and iv["paired"] == 1 and iv["improved_count"] == 2
    paired = next(x for x in iv["sessions"] if x["paired"])
    assert paired["pre_scan_id"] == pre["scan_id"] and paired["tone_pct"] == pytest.approx(-14.3, abs=0.1)
    assert any(i["title"].startswith("Vajrasana: helps") for i in a["insights"])


def test_trend_detects_real_improvement_and_ignores_noise():
    improving = [sc("Baseline", -1.5 - 0.02 * i, 30 + 1.5 * i, 72, days_ago=30 - 2 * i) for i in range(12)]
    t = an.build(USER, improving, [], [], now=NOW)["series"]["rmssd"]["trend"]
    assert t["status"] == "ok" and t["meaningful"] and t["direction"] == "better" and t["per_week"] > 0
    flat = [sc("Baseline", -1.7, 40 + (1 if i % 2 else -1), 72, days_ago=30 - 2 * i) for i in range(12)]
    t2 = an.build(USER, flat, [], [], now=NOW)["series"]["rmssd"]["trend"]
    assert t2["meaningful"] is False and t2["direction"] == "stable"
    few = an.build(USER, baselines(3), [], [], now=NOW)["series"]["rmssd"]["trend"]
    assert few["status"] == "insufficient"


def test_window_filter_quality_streak_and_time_of_day():
    scans = baselines(5, start=12) + [sc("Baseline", -1.7, 40, 70, days_ago=200)]
    scans += [sc("Baseline", 0, 0, 0, days_ago=d, ok=False) for d in (0, 1)]
    a = an.build(USER, scans, [], [], days=30, now=NOW, tz_offset_min=330)
    assert a["overview"]["total_scans"] == 7 and a["overview"]["all_time_scans"] == 8
    assert a["quality"]["failed"] == 2 and a["quality"]["top_reasons"][0]["count"] == 2
    assert a["quality"]["mean_fps"] == pytest.approx(59.8)
    assert all(x["part"] in ("morning", "afternoon", "evening", "night") for x in a["time_of_day"])
    streak = an.build(USER, [sc("Baseline", -1.7, 40, 70, days_ago=d) for d in (0, 1, 2, 4)], [], [], now=NOW)
    assert streak["overview"]["streak_days"] == 3


def test_baseline_falls_back_to_all_time_when_window_has_none():
    a = an.build(USER, baselines(4, start=200) + [sc("Post-Meal", -1.6, 35, 75, days_ago=1)], [], [], days=30, now=NOW)
    assert a["baseline"]["n"] == 4 and a["baseline"]["scope"] == "all time" and len(a["responses"]) == 1


# ----------------------------------------------------------------------------- through the API
def test_analytics_endpoint_end_to_end(client):
    r = client.post("/api/v1/auth/signup", json={"email": "an@example.com", "password": "analytics pass 1"})
    h = {"Authorization": f"Bearer {r.json()['token']}"}
    client.patch("/api/v1/me", headers=h, json={"prakriti_type": "Kapha"})
    for seed in (1, 2, 3):
        assert client.post("/api/v1/scan/process", headers=h, json=scan_payload(seed=seed, bpm=64, rr_sd_ms=40)).status_code == 200
    meal = client.post("/api/v1/meals", headers=h, json={"name": "Idli sambar", "meal_type": "breakfast",
                                                         "descriptors": ["light", "home-cooked"]}).json()
    assert meal["meal_type"] == "breakfast" and meal["descriptors"] == ["light", "home-cooked"]
    p = scan_payload("Post-Meal", seed=4, bpm=72, rr_sd_ms=25)
    j = client.post("/api/v1/scan/process", headers=h, json={**p, "meal_id": meal["meal_id"],
                                                            "context": ["Fasting"]}).json()
    assert j["comparison"] is not None
    p = scan_payload("Post-Intervention", seed=5, bpm=66, rr_sd_ms=38)
    j = client.post("/api/v1/scan/process", headers=h, json={**p, "intervention": "Deep Breathing",
                                                            "notes": "5 min box breathing"}).json()
    assert j["intervention"] == "Deep Breathing" and j["comparison"]["intervention"]["type"] == "Deep Breathing"

    a = client.get("/api/v1/analytics?days=30&tz_offset_min=330", headers=h).json()
    assert a["overview"]["good_scans"] == 5 and a["baseline"]["n"] == 3
    assert a["meals"][0]["name"] == "Idli sambar" and a["meals"][0]["n"] == 1
    assert a["interventions"][0]["type"] == "Deep Breathing"
    assert a["prakriti"]["type"] == "Kapha" and "Kapha" in a["prakriti"]["guidance"]
    assert len(a["series"]["rmssd"]["points"]) == 5 and a["insights"]

    hist = client.get("/api/v1/scans", headers=h).json()
    assert hist[0]["tag_event"] == "Post-Intervention" and hist[0]["notes"] == "5 min box breathing"
    assert hist[1]["meal_name"] == "Idli sambar"
    assert len(client.get("/api/v1/scans?tag=Baseline", headers=h).json()) == 3

    # deleting the newest baseline recomputes the stored baseline and removes dependent comparisons
    newest_base = client.get("/api/v1/scans?tag=Baseline", headers=h).json()[0]
    assert client.delete(f"/api/v1/scans/{newest_base['scan_id']}", headers=h).status_code == 200
    assert len(client.get("/api/v1/scans", headers=h).json()) == 4
    me = client.get("/api/v1/me", headers=h).json()
    assert me["baseline_rmssd"] is not None
    assert client.delete(f"/api/v1/meals/{meal['meal_id']}", headers=h).status_code == 200
    assert client.get("/api/v1/meals", headers=h).json() == []
    exp = client.get("/api/v1/export", headers=h).json()
    assert len(exp["scans"]) == 4 and "raw_signal" not in exp["scans"][0]
