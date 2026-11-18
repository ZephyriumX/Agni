"""Demo without a phone: posts synthetic Baseline + Post-Meal scans, then prints the report.
Usage: python scripts/simulate_scan.py [http://localhost:8000] [api_key]"""
import sys, uuid, json, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent / "backend"))
import httpx
from tests.synth import make_ppg

base = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000"
hdr = {"X-API-Key": sys.argv[2]} if len(sys.argv) > 2 else {}
uid = str(uuid.uuid4())
for tag, kw in [("Baseline", dict(bpm=65, rr_sd_ms=40, seed=1)),
                ("Post-Meal", dict(bpm=82, rr_sd_ms=15, seed=2, dicrotic=0.2))]:
    raw, fs, _ = make_ppg(**kw)
    r = httpx.post(f"{base}/api/v1/scan/process", headers=hdr, timeout=60,
                   json={"user_id": uid, "tag": tag, "fs": fs, "red": raw.tolist()})
    print(tag, r.status_code, {k: r.json().get(k) for k in ("ba_ratio", "rmssd_ms", "avg_bpm")})
print(json.dumps(httpx.get(f"{base}/api/v1/reports/{uid}", headers=hdr).json()["comparisons"], indent=2))
