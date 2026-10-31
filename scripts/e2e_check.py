"""End-to-end API check against a RUNNING server (synthetic signals - proves the server, NOT the camera).

    python scripts/e2e_check.py http://localhost:8000 [registration_key]
It prints a --verify command; run that after restarting the server to prove data survived:
    python scripts/e2e_check.py http://localhost:8000 --verify <user_id> <token>
"""
import json
import pathlib
import sys

import httpx

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "backend"))
from tests.helpers import scan_payload  # noqa: E402


def main(argv):
    base = argv[1] if len(argv) > 1 else "http://localhost:8000"
    cx = httpx.Client(base_url=base, timeout=60)
    h = cx.get("/health"); print("health", h.status_code, h.json())
    rd = cx.get("/ready"); print("ready ", rd.status_code, rd.json())
    if rd.status_code != 200:
        sys.exit("server not ready (database/migrations?)")
    if "--verify" in argv:
        uid, tok = argv[argv.index("--verify") + 1:][:2]
        rep = cx.get(f"/api/v1/reports/{uid}", headers={"Authorization": f"Bearer {tok}"})
        ok = rep.status_code == 200 and rep.json()["scans"]
        print("report after restart:", rep.status_code, "scans:", len(rep.json().get("scans", [])),
              "comparisons:", len(rep.json().get("comparisons", [])))
        sys.exit(0 if ok else 1)
    rk = argv[2] if len(argv) > 2 else None
    r = cx.post("/api/v1/auth/register", json={}, headers={"X-Registration-Key": rk} if rk else {})
    r.raise_for_status(); u = r.json(); hdr = {"Authorization": f"Bearer {u['token']}"}
    print("registered", u["user_id"])
    j = {}
    for tag, kw in [("Baseline", dict(bpm=65, rr_sd_ms=40, seed=1)),
                    ("Post-Meal", dict(bpm=82, rr_sd_ms=15, seed=2, dicrotic=0.2))]:
        r = cx.post("/api/v1/scan/process", headers=hdr, json=scan_payload(tag, **kw))
        j = r.json(); print(tag, r.status_code, {k: j.get(k) for k in ("ba_ratio", "rmssd_ms", "avg_bpm", "processing_ms")},
                            "sqi", j.get("sqi", {}).get("passed"))
        r.raise_for_status()
    print("comparison:", json.dumps({k: j["comparison"][k] for k in ("delta_vascular_tone_pct", "hrv_ratio", "compatibility_pct", "verdict")}))
    rep = cx.get(f"/api/v1/reports/{u['user_id']}", headers=hdr).json()
    print("report: scans", len(rep["scans"]), "comparisons", len(rep["comparisons"]))
    print(f"\nRe-run after restarting the server:\n  python scripts/e2e_check.py {base} --verify {u['user_id']} {u['token']}")


if __name__ == "__main__":
    main(sys.argv)
