"""Live end-to-end check of a RUNNING Agni-Pulse server (local, tunnel or cloud).

    python scripts/smoke_remote.py https://agni-pulse-api.onrender.com [registration_key]

Creates a throw-away account, runs the whole product flow over HTTP (sign-up, onboarding profile, baseline
scans, meal + post-meal scan, intervention scan, history, analytics, second-device login, logout, recovery,
export) and DELETES the account at the end. Signals are synthetic: this proves the server, network, database
and data isolation - not the phone camera.
"""
from __future__ import annotations

import pathlib
import secrets
import sys
import time

import httpx

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "backend"))
from tests.helpers import scan_payload  # noqa: E402

OK, FAIL = "PASS", "FAIL"
results: list[tuple[str, str, str]] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    results.append((OK if cond else FAIL, name, detail))
    print(f"[{OK if cond else FAIL}] {name}" + (f"  - {detail}" if detail else ""))
    if not cond:
        summary()
        sys.exit(1)


def summary() -> None:
    n_ok = sum(1 for r in results if r[0] == OK)
    print(f"\n{n_ok}/{len(results)} checks passed")


def main(argv: list[str]) -> None:
    base = (argv[1] if len(argv) > 1 else "http://127.0.0.1:8000").rstrip("/")
    rk = argv[2] if len(argv) > 2 else None
    cx = httpx.Client(base_url=base, timeout=90)       # cloud free tiers can take ~60 s to wake up

    t0 = time.perf_counter()
    h = cx.get("/health")
    check("server reachable /health", h.status_code == 200, f"{h.json()} in {time.perf_counter() - t0:.1f}s")
    rd = cx.get("/ready")
    check("database + migrations /ready", rd.status_code == 200, str(rd.json()))
    opts = cx.get("/api/v1/auth/options").json()
    check("auth options", opts.get("auth_mode") == "token", str(opts))

    email = f"smoke+{secrets.token_hex(4)}@example.com"
    pw = "smoke test " + secrets.token_hex(4)
    r = cx.post("/api/v1/auth/signup", json={"email": email, "password": pw, "display_name": "Smoke Test",
                                             "device_name": "smoke-1"},
                headers={"X-Registration-Key": rk} if rk else {})
    check("sign up", r.status_code == 200, r.text[:200] if r.status_code != 200 else email)
    j = r.json()
    H1 = {"Authorization": f"Bearer {j['token']}"}
    recovery = j["recovery_code"]

    r = cx.patch("/api/v1/me", headers=H1, json={
        "prakriti_type": "Pitta", "prakriti_scores": {"vata": 3, "pitta": 7, "kapha": 2},
        "profile": {"birth_year": 2002, "diet": "vegetarian", "goals": ["digestion"]}, "onboarding_complete": True})
    check("onboarding profile saved", r.status_code == 200 and r.json()["onboarding_completed_at"] is not None)

    for seed in (11, 12, 13):
        r = cx.post("/api/v1/scan/process", headers=H1, json=scan_payload("Baseline", seed=seed, bpm=66, rr_sd_ms=40))
        check(f"baseline scan {seed - 10}", r.status_code == 200 and r.json()["sqi"]["passed"],
              f"b/a {r.json().get('ba_ratio')} RMSSD {r.json().get('rmssd_ms')} {r.json().get('processing_ms')} ms")
    meal = cx.post("/api/v1/meals", headers=H1, json={"name": "Rajma chawal", "meal_type": "lunch",
                                                      "descriptors": ["heavy"]}).json()
    r = cx.post("/api/v1/scan/process", headers=H1,
                json={**scan_payload("Post-Meal", seed=14, bpm=80, rr_sd_ms=18), "meal_id": meal["meal_id"]})
    check("post-meal scan + auto comparison", r.status_code == 200 and r.json()["comparison"] is not None,
          f"compatibility {r.json().get('comparison', {}).get('compatibility_pct')}%")
    r = cx.post("/api/v1/scan/process", headers=H1,
                json={**scan_payload("Post-Intervention", seed=15, bpm=70, rr_sd_ms=34), "intervention": "Vajrasana"})
    check("post-intervention scan", r.status_code == 200 and r.json()["intervention"] == "Vajrasana")

    hist = cx.get("/api/v1/scans", headers=H1).json()
    check("history", len(hist) == 5 and hist[1]["meal_name"] == "Rajma chawal")
    a = cx.get("/api/v1/analytics", headers=H1, params={"days": 30, "tz_offset_min": 330}).json()
    check("analytics", a["baseline"]["n"] == 3 and a["meals"] and a["interventions"] and a["insights"],
          f"{len(a['insights'])} insights, baseline RMSSD {a['baseline']['metrics']['rmssd']['mean']} ms")

    r = cx.post("/api/v1/auth/login", json={"email": email, "password": pw, "device_name": "smoke-2"})
    check("login from a second device", r.status_code == 200 and r.json()["user_id"] == j["user_id"])
    H2 = {"Authorization": f"Bearer {r.json()['token']}"}
    check("same data on second device", len(cx.get("/api/v1/scans", headers=H2).json()) == 5)

    other = cx.post("/api/v1/auth/signup", json={"email": "x" + email, "password": pw},
                    headers={"X-Registration-Key": rk} if rk else {}).json()
    HO = {"Authorization": f"Bearer {other['token']}"}
    check("other users cannot see this data", cx.get("/api/v1/scans", headers=HO).json() == [] and
          cx.get(f"/api/v1/scans/{hist[0]['scan_id']}", headers=HO).status_code == 404)
    cx.post("/api/v1/me/delete", headers=HO, json={"password": pw})

    check("logout", cx.post("/api/v1/auth/logout", headers=H1).status_code == 200 and
          cx.get("/api/v1/me", headers=H1).status_code == 401)
    r = cx.post("/api/v1/auth/recover", json={"email": email, "recovery_code": recovery, "new_password": pw + "!"})
    check("account recovery with recovery code", r.status_code == 200)
    H3 = {"Authorization": f"Bearer {r.json()['token']}"}
    check("recovery signed out other devices", cx.get("/api/v1/me", headers=H2).status_code == 401)
    exp = cx.get("/api/v1/export", headers=H3).json()
    check("export", len(exp["scans"]) == 5 and len(exp["meals"]) == 1)
    r = cx.post("/api/v1/me/delete", headers=H3, json={"password": pw + "!"})
    check("delete test account", r.status_code == 200 and
          cx.post("/api/v1/auth/login", json={"email": email, "password": pw + "!"}).status_code == 401)
    summary()


if __name__ == "__main__":
    main(sys.argv)
