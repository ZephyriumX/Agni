"""Self-contained proof of persistence: throw-away PostgreSQL + a real uvicorn process that is killed and restarted.
    python scripts/restart_proof.py     (needs backend/requirements-dev.txt and PostgreSQL server binaries)"""
import os, pathlib, re, subprocess, sys, time

import httpx

root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "backend"))
from migrate import migrate  # noqa: E402
from tests.pgtemp import TempPostgres  # noqa: E402

pg = TempPostgres()
migrate(pg.dsn)
env = {**os.environ, "AGNI_ENV": "development", "AGNI_STORAGE": "postgres", "DATABASE_URL": pg.dsn}
PORT, py = "8791", sys.executable
url = f"http://127.0.0.1:{PORT}"


def start():
    p = subprocess.Popen([py, "-m", "uvicorn", "main:app", "--port", PORT, "--log-level", "warning"],
                         cwd=root / "backend", env=env)
    for _ in range(80):
        try:
            if httpx.get(f"{url}/ready", timeout=1).status_code == 200:
                return p
        except Exception:
            time.sleep(0.25)
    p.kill(); pg.stop(); sys.exit("server did not start")


try:
    p = start()
    out = subprocess.run([py, "scripts/e2e_check.py", url], cwd=root, capture_output=True, text=True).stdout
    print(out)
    m = re.search(r"--verify (\S+) (\S+)", out)
    p.terminate(); p.wait(); print(">>> API process killed")
    p = start(); print(">>> API process restarted (new process, new connection pool)")
    r = subprocess.run([py, "scripts/e2e_check.py", url, "--verify", m.group(1), m.group(2)],
                       cwd=root, capture_output=True, text=True)
    print(r.stdout); p.terminate(); p.wait()
    sys.exit(r.returncode)
finally:
    pg.stop()
