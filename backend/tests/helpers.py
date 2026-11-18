import numpy as np
from tests.synth import make_ppg


def register(client, **kw):
    r = client.post("/api/v1/auth/register", json=kw)
    assert r.status_code == 200, r.text
    d = r.json()
    return d["user_id"], {"Authorization": f"Bearer {d['token']}"}


def scan_payload(tag="Baseline", fs_hz=60, jitter=0.0005, seed=0, **kw):
    raw, fs, _ = make_ppg(fs=fs_hz, seed=seed, **kw)
    t = np.arange(len(raw)) / fs
    if jitter:
        t = np.sort(t + np.random.default_rng(seed).normal(0, jitter, len(t)))
    return {"tag": tag, "timestamps": [round(float(x), 5) for x in t],
            "red": [round(float(x), 4) for x in raw]}
