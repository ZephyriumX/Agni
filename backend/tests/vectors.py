"""Deterministic timestamp specs shared by the Python and Dart validators (golden vectors).

Spec: {"segments": [[duration_s, fps], ...], "delete": [[start, stop, step], ...]}
Timestamps are built with integer arithmetic only (no RNG) so Dart can rebuild them identically.
"""
import json
import pathlib

import numpy as np

VECTOR_FILE = pathlib.Path(__file__).resolve().parents[2] / "docs" / "capture_validation_vectors.json"

SPECS = {
    "exact_60": {"segments": [[35, 60]]},
    "stable_58": {"segments": [[35, 58]]},
    "stable_57": {"segments": [[35, 57]]},
    "stable_55": {"segments": [[35, 55]]},
    "stable_54": {"segments": [[35, 54]]},
    "stable_30": {"segments": [[35, 30]]},
    "wander_50_60": {"segments": [[7, 60], [7, 50], [7, 58], [7, 52], [7, 60]]},
    "long_slow_stretch": {"segments": [[20, 60], [15, 50]]},
    "mild_fluctuation": {"segments": [[9, 60], [9, 57], [9, 59], [8, 56]]},
    "drops_1pct": {"segments": [[35, 60]], "delete": [[100, 2000, 100]]},
    "drops_4pct": {"segments": [[35, 60]], "delete": [[100, 2000, 25]]},
    "drops_8pct": {"segments": [[35, 60]], "delete": [[100, 2000, 12]]},
    "gap_120ms": {"segments": [[35, 60]], "delete": [[500, 507, 1]]},
    "gap_350ms": {"segments": [[35, 60]], "delete": [[500, 520, 1]]},
    "short_10s": {"segments": [[10, 60]]},
    "short_20s": {"segments": [[20, 60]]},
    "58_with_gap_120ms": {"segments": [[35, 58]], "delete": [[500, 507, 1]]},
}


def build(spec):
    pts, t0 = [], 0.0
    for dur, fps in spec["segments"]:
        n = int(round(dur * fps))
        pts.extend(t0 + k / fps for k in range(n))
        t0 += n / fps
    t = np.array(pts)
    for a, b, c in spec.get("delete", []):
        t = np.delete(t, np.arange(a, b, c))
    return t


def generate():
    import capture_validation as cv
    out = []
    for name, spec in SPECS.items():
        rep = cv.evaluate_timestamps(build(spec))
        out.append({"name": name, **spec, "expect": {"status": rep["status"],
                                                      "codes": sorted(r["code"] for r in rep["reasons"])}})
    return {"note": "Golden vectors for capture timing validation. Regenerate with: python -m tests.vectors",
            "config": "defaults", "vectors": out}


if __name__ == "__main__":
    VECTOR_FILE.parent.mkdir(exist_ok=True)
    VECTOR_FILE.write_text(json.dumps(generate(), indent=1) + "\n")
    print("wrote", VECTOR_FILE)
