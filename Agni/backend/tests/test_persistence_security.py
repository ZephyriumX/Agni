"""Real-PostgreSQL tests: restart survival, outage handling, migrations, auth modes, config guards."""
import time

import jwt
import psycopg
import pytest
from fastapi.testclient import TestClient

import main
from config import Settings
from storage import MemoryStore, PostgresStore
from tests.conftest import truncate
from tests.helpers import register, scan_payload


def _app(dsn):
    st = PostgresStore(dsn)
    return TestClient(main.create_app(Settings(env="test", storage="postgres", database_url=dsn), st)), st


def test_data_survives_api_restart(pg_dsn):
    truncate(pg_dsn)
    c1, st1 = _app(pg_dsn)
    uid, h = register(c1, prakriti_type="Kapha")
    b = c1.post("/api/v1/scan/process", headers=h, json=scan_payload("Baseline", bpm=65, rr_sd_ms=40, seed=1)).json()
    t = c1.post("/api/v1/scan/process", headers=h, json=scan_payload("Post-Meal", bpm=82, rr_sd_ms=15, seed=2)).json()
    before = c1.get(f"/api/v1/reports/{uid}", headers=h).json()
    st1.close(); del c1                                      # "kill" the API process
    c2, st2 = _app(pg_dsn)                                   # brand-new app + pool
    after = c2.get(f"/api/v1/reports/{uid}", headers=h).json()   # same token still works
    assert after == before
    assert [s["scan_id"] for s in after["scans"]] == [b["scan_id"], t["scan_id"]]
    assert after["comparisons"][0]["verdict"] == t["comparison"]["verdict"]
    assert after["user"]["prakriti_type"] == "Kapha"
    with psycopg.connect(pg_dsn) as c:
        n, ts = c.execute("SELECT jsonb_array_length(raw_signal), jsonb_array_length(raw_timestamps) FROM scans "
                          "WHERE scan_id=%s", (b["scan_id"],)).fetchone()
    assert n == ts == 2400
    st2.close()


def test_db_outage_returns_503_not_500():
    st = PostgresStore("postgresql://nobody:x@127.0.0.1:1/none?connect_timeout=1")
    c = TestClient(main.create_app(Settings(env="test", storage="postgres", database_url="x"), st))
    r = c.post("/api/v1/auth/register", json={})
    assert r.status_code == 503 and r.json()["code"] == "storage_unavailable" and "nobody" not in r.text
    assert c.get("/ready").status_code == 503
    assert c.get("/health").status_code == 200
    st.close()


def test_transaction_rolls_back_on_failure(pg_dsn):
    """A scan insert that violates a constraint must not leave a baseline update behind."""
    truncate(pg_dsn)
    c, st = _app(pg_dsn)
    uid, h = register(c)
    row = {"user_id": uid, "tag_event": "NOT-A-TAG", "raw_signal": [1.0], "sampling_rate": 60,
           "rmssd": 33.0, "ba_ratio": -0.5, "sqi_passed": True}
    with pytest.raises(psycopg.errors.CheckViolation):
        st.save_scan(row, set_baseline=True)
    assert st.get_user(uid)["baseline_rmssd"] is None
    assert st.list_scans(uid) == []
    st.close()


def test_migrations_idempotent_and_checksummed(pg_dsn, tmp_path, monkeypatch):
    import migrate
    assert migrate.migrate(pg_dsn, quiet=True) == []
    d = tmp_path / "m"; d.mkdir()
    (d / "001_x.sql").write_text("CREATE TABLE IF NOT EXISTS mig_probe(i int);")
    monkeypatch.setattr(migrate, "MIG_DIR", d)
    assert migrate.migrate(pg_dsn, quiet=True) == ["001_x.sql"]
    (d / "001_x.sql").write_text("-- edited")
    with pytest.raises(RuntimeError, match="modified"):
        migrate.migrate(pg_dsn, quiet=True)
    with psycopg.connect(pg_dsn, autocommit=True) as c:
        c.execute("DROP TABLE mig_probe; DELETE FROM schema_migrations WHERE name='001_x.sql'")


def test_rls_enabled_on_all_tables(pg_dsn):
    with psycopg.connect(pg_dsn) as c:
        rows = c.execute("SELECT relname, relrowsecurity FROM pg_class WHERE relname IN "
                         "('users','scans','interventions','comparisons','meals')").fetchall()
    assert len(rows) == 5 and all(r[1] for r in rows)


def test_token_is_stored_hashed(pg_dsn):
    truncate(pg_dsn)
    c, st = _app(pg_dsn)
    uid, h = register(c)
    tok = h["Authorization"].split()[1]
    with psycopg.connect(pg_dsn) as cx:
        (stored,) = cx.execute("SELECT token_hash FROM users WHERE user_id=%s", (uid,)).fetchone()
    assert stored != tok and tok not in stored and len(stored) == 64
    st.close()


def test_supabase_jwt_mode_hs256():
    secret = "x" * 40
    c = TestClient(main.create_app(Settings(env="test", storage="memory", auth_mode="supabase",
                                            supabase_jwt_secret=secret), MemoryStore()))
    uid = "11111111-1111-4111-8111-111111111111"
    mk = lambda key, exp=60, aud="authenticated": jwt.encode(
        {"sub": uid, "aud": aud, "exp": int(time.time()) + exp}, key, "HS256")
    assert c.get("/api/v1/me", headers={"Authorization": f"Bearer {mk(secret)}"}).json()["user_id"] == uid
    for bad in (mk("y" * 40), mk(secret, exp=-5), mk(secret, aud="other")):
        assert c.get("/api/v1/me", headers={"Authorization": f"Bearer {bad}"}).status_code == 401
    assert c.post("/api/v1/auth/register", json={}).status_code == 404


def test_registration_key_and_rate_limit():
    c = TestClient(main.create_app(Settings(env="test", storage="memory", registration_key="rk", register_per_hour=3),
                                   MemoryStore()))
    assert c.post("/api/v1/auth/register", json={}).status_code == 401
    ok = [c.post("/api/v1/auth/register", json={}, headers={"X-Registration-Key": "rk"}).status_code for _ in range(4)]
    assert ok == [200, 200, 200, 429]


def test_config_guards():
    with pytest.raises(RuntimeError, match="production"):
        Settings(env="production", storage="memory").validate()
    with pytest.raises(RuntimeError, match="DATABASE_URL"):
        Settings(env="development", storage="postgres", database_url="").validate()
    with pytest.raises(RuntimeError, match="production"):
        Settings(env="production", storage="postgres", database_url="x", auth_mode="none").validate()


def test_unhandled_errors_do_not_leak_details(settings_store):
    s, st = settings_store
    app = main.create_app(s, st)

    @app.get("/boom")
    def boom():
        raise ValueError("secret-db-password-123")
    r = TestClient(app, raise_server_exceptions=False).get("/boom")
    assert r.status_code == 500 and "secret" not in r.text and "request_id" in r.json()
