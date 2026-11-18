"""Accounts: sign-up, login, logout, multi-device sessions, recovery, e-mail reset, upgrade of legacy
device profiles, profile/personalisation, deletion and per-user isolation. Runs on memory AND real PostgreSQL."""
import pytest
from fastapi.testclient import TestClient

import auth
import main
from config import Settings
from storage import MemoryStore
from tests.helpers import register, scan_payload

PW = "correct horse 42"


def signup(c, email="asha@example.com", pw=PW, name="Asha", **kw):
    r = c.post("/api/v1/auth/signup", json={"email": email, "password": pw, "display_name": name, **kw})
    assert r.status_code == 200, r.text
    j = r.json()
    return j, {"Authorization": f"Bearer {j['token']}"}


def test_signup_login_logout_and_sessions_per_device(client):
    j, h1 = signup(client, device_name="Pixel")
    assert j["token"].startswith("ags_") and j["recovery_code"].count("-") == 3
    assert j["user"]["email"] == "asha@example.com" and j["user"]["display_name"] == "Asha"
    assert j["user"]["has_password"] is True and "password_hash" not in j["user"]

    r = client.post("/api/v1/auth/login", json={"email": "ASHA@example.com ", "password": PW, "device_name": "Tablet"})
    assert r.status_code == 200, r.text
    h2 = {"Authorization": f"Bearer {r.json()['token']}"}
    assert r.json()["user_id"] == j["user_id"]                                  # same account from a 2nd device

    sess = client.get("/api/v1/auth/sessions", headers=h1).json()
    assert {s["device_name"] for s in sess} == {"Pixel", "Tablet"}
    assert sum(s["current"] for s in sess) == 1

    assert client.post("/api/v1/auth/logout", headers=h1).status_code == 200
    assert client.get("/api/v1/me", headers=h1).status_code == 401              # this device signed out
    assert client.get("/api/v1/me", headers=h2).status_code == 200              # the other is not
    client.post("/api/v1/auth/logout-all", headers=h2)
    assert client.get("/api/v1/me", headers=h2).status_code == 401


def test_data_follows_the_account_across_devices(client):
    j, h1 = signup(client)
    assert client.post("/api/v1/scan/process", headers=h1, json=scan_payload(seed=1)).status_code == 200
    r = client.post("/api/v1/auth/login", json={"email": "asha@example.com", "password": PW})
    h2 = {"Authorization": f"Bearer {r.json()['token']}"}
    scans = client.get("/api/v1/scans", headers=h2).json()
    assert len(scans) == 1 and scans[0]["tag_event"] == "Baseline"


def test_wrong_password_duplicate_email_and_password_policy(client):
    signup(client)
    assert client.post("/api/v1/auth/login", json={"email": "asha@example.com", "password": "nope-nope"}).status_code == 401
    assert client.post("/api/v1/auth/login", json={"email": "nobody@example.com", "password": PW}).status_code == 401
    r = client.post("/api/v1/auth/signup", json={"email": "Asha@Example.com", "password": PW})
    assert r.status_code == 409
    for bad in ("short", "12345678901", "password"):
        assert client.post("/api/v1/auth/signup", json={"email": f"x{len(bad)}@e.com", "password": bad}).status_code == 422
    assert client.post("/api/v1/auth/signup", json={"email": "not-an-email", "password": PW}).status_code == 422


def test_account_lockout_after_repeated_failures(settings_store):
    s, st = settings_store
    s.max_failed_logins = 3
    c = TestClient(main.create_app(s, st))
    signup(c)
    for _ in range(3):
        assert c.post("/api/v1/auth/login", json={"email": "asha@example.com", "password": "wrong-pass"}).status_code == 401
    r = c.post("/api/v1/auth/login", json={"email": "asha@example.com", "password": PW})
    assert r.status_code == 429                                                 # locked even with the right password


def test_recovery_code_resets_password_rotates_code_and_signs_out_everywhere(client):
    j, h = signup(client)
    code = j["recovery_code"]
    r = client.post("/api/v1/auth/recover", json={"email": "asha@example.com", "recovery_code": "AAAA-BBBB-CCCC-DDDD",
                                                  "new_password": "brand new pass 1"})
    assert r.status_code == 401
    r = client.post("/api/v1/auth/recover", json={"email": "asha@example.com", "recovery_code": code.lower().replace("-", " "),
                                                  "new_password": "brand new pass 1"})
    assert r.status_code == 200, r.text
    assert r.json()["recovery_code"] != code and r.json()["user_id"] == j["user_id"]
    assert client.get("/api/v1/me", headers=h).status_code == 401              # old sessions revoked
    assert client.post("/api/v1/auth/login", json={"email": "asha@example.com", "password": PW}).status_code == 401
    assert client.post("/api/v1/auth/login", json={"email": "asha@example.com", "password": "brand new pass 1"}).status_code == 200
    # an old code is single-use
    r = client.post("/api/v1/auth/recover", json={"email": "asha@example.com", "recovery_code": code,
                                                  "new_password": "another pass 2"})
    assert r.status_code == 401


def test_email_reset_code_flow(settings_store, monkeypatch):
    s, st = settings_store
    s.smtp_host = "smtp.test"
    sent = []
    monkeypatch.setattr(auth, "send_email", lambda settings, to, subj, body: sent.append((to, body)))
    c = TestClient(main.create_app(s, st))
    assert c.get("/api/v1/auth/options").json()["email_reset"] is True
    signup(c)
    assert c.post("/api/v1/auth/forgot", json={"email": "nobody@example.com"}).status_code == 200   # no enumeration
    assert sent == []
    assert c.post("/api/v1/auth/forgot", json={"email": "asha@example.com"}).status_code == 200
    code = sent[-1][1].split("code is ")[1][:6]
    assert c.post("/api/v1/auth/reset", json={"email": "asha@example.com", "code": "000000" if code != "000000" else "111111",
                                              "new_password": "reset pass 99"}).status_code == 401
    r = c.post("/api/v1/auth/reset", json={"email": "asha@example.com", "code": code, "new_password": "reset pass 99"})
    assert r.status_code == 200, r.text
    assert c.post("/api/v1/auth/reset", json={"email": "asha@example.com", "code": code,
                                              "new_password": "reset pass 98"}).status_code == 401   # single use


def test_email_reset_disabled_without_smtp(client):
    assert client.get("/api/v1/auth/options").json()["email_reset"] is False
    assert client.post("/api/v1/auth/forgot", json={"email": "a@b.com"}).status_code == 501


def test_change_password_and_new_recovery_code(client):
    j, h = signup(client)
    r2 = client.post("/api/v1/auth/login", json={"email": "asha@example.com", "password": PW})
    h2 = {"Authorization": f"Bearer {r2.json()['token']}"}
    assert client.post("/api/v1/auth/change-password", headers=h,
                       json={"current_password": "wrong", "new_password": "x new pass 1"}).status_code == 401
    r = client.post("/api/v1/auth/change-password", headers=h,
                    json={"current_password": PW, "new_password": "x new pass 1"})
    assert r.status_code == 200 and r.json()["other_sessions_signed_out"] == 1
    assert client.get("/api/v1/me", headers=h).status_code == 200              # this device stays signed in
    assert client.get("/api/v1/me", headers=h2).status_code == 401
    rc = client.post("/api/v1/auth/recovery-code", headers=h, json={"password": "x new pass 1"})
    assert rc.status_code == 200 and rc.json()["recovery_code"] != j["recovery_code"]


def test_legacy_device_profile_upgrades_without_losing_data(client):
    uid, h = register(client, prakriti_type="Kapha")
    assert client.post("/api/v1/scan/process", headers=h, json=scan_payload(seed=2)).status_code == 200
    assert client.get("/api/v1/me", headers=h).json()["has_password"] is False
    r = client.post("/api/v1/auth/upgrade", headers=h, json={"email": "old@example.com", "password": PW,
                                                            "display_name": "Old user"})
    assert r.status_code == 200, r.text
    assert r.json()["user_id"] == uid
    r = client.post("/api/v1/auth/login", json={"email": "old@example.com", "password": PW})
    h2 = {"Authorization": f"Bearer {r.json()['token']}"}
    me = client.get("/api/v1/me", headers=h2).json()
    assert me["user_id"] == uid and me["prakriti_type"] == "Kapha" and me["display_name"] == "Old user"
    assert len(client.get("/api/v1/scans", headers=h2).json()) == 1
    assert client.post("/api/v1/auth/upgrade", headers=h2, json={"email": "z@example.com", "password": PW}).status_code == 409


def test_profile_and_onboarding_personalisation(client):
    _, h = signup(client)
    me = client.get("/api/v1/me", headers=h).json()
    assert me["onboarding_completed_at"] is None and me["profile"] == {}
    body = {"display_name": "Asha K", "prakriti_type": "Pitta", "prakriti_scores": {"vata": 2, "pitta": 6, "kapha": 2},
            "profile": {"birth_year": 1999, "sex": "female", "diet": "vegetarian", "activity": "moderate",
                        "goals": ["digestion", "stress"]}, "onboarding_complete": True}
    r = client.patch("/api/v1/me", headers=h, json=body)
    assert r.status_code == 200, r.text
    me = r.json()
    assert me["prakriti_type"] == "Pitta" and me["prakriti_scores"]["pitta"] == 6
    assert me["profile"]["goals"] == ["digestion", "stress"] and me["onboarding_completed_at"]
    # partial update keeps the rest
    me = client.patch("/api/v1/me", headers=h, json={"display_name": "Asha"}).json()
    assert me["prakriti_type"] == "Pitta" and me["profile"]["diet"] == "vegetarian" and me["display_name"] == "Asha"
    assert client.patch("/api/v1/me", headers=h, json={"profile": {"birth_year": 1800}}).status_code == 422
    assert client.patch("/api/v1/me", headers=h, json={"prakriti_type": "Fire"}).status_code == 422
    # legacy body still works
    assert client.patch("/api/v1/me", headers=h, json={"prakriti_type": "Vata"}).json()["prakriti_type"] == "Vata"


def test_users_cannot_reach_each_others_data(client):
    _, ha = signup(client, email="a@example.com")
    _, hb = signup(client, email="b@example.com")
    sid = client.post("/api/v1/scan/process", headers=ha, json=scan_payload(seed=3)).json()["scan_id"]
    mid = client.post("/api/v1/meals", headers=ha, json={"name": "Dal rice"}).json()["meal_id"]
    assert client.get(f"/api/v1/scans/{sid}", headers=hb).status_code == 404
    assert client.delete(f"/api/v1/scans/{sid}", headers=hb).status_code == 404
    assert client.delete(f"/api/v1/meals/{mid}", headers=hb).status_code == 404
    assert client.get("/api/v1/scans", headers=hb).json() == []
    assert client.get("/api/v1/meals", headers=hb).json() == []
    assert client.get("/api/v1/analytics", headers=hb).json()["overview"]["all_time_scans"] == 0
    assert client.get("/api/v1/export", headers=hb).json()["scans"] == []
    assert len(client.get("/api/v1/scans", headers=ha).json()) == 1


def test_delete_account_removes_everything(client):
    j, h = signup(client)
    client.post("/api/v1/scan/process", headers=h, json=scan_payload(seed=4))
    client.post("/api/v1/meals", headers=h, json={"name": "Poha"})
    assert client.post("/api/v1/me/delete", headers=h, json={"password": "wrong"}).status_code == 401
    assert client.post("/api/v1/me/delete", headers=h, json={"password": PW}).status_code == 200
    assert client.get("/api/v1/me", headers=h).status_code == 401
    assert client.post("/api/v1/auth/login", json={"email": "asha@example.com", "password": PW}).status_code == 401
    signup(client)                                                             # e-mail is free again


def test_signup_closed_and_registration_key():
    s = Settings(env="test", storage="memory", registration_key="rk", signup_open=True)
    c = TestClient(main.create_app(s, MemoryStore()))
    assert c.post("/api/v1/auth/signup", json={"email": "a@b.com", "password": PW}).status_code == 401
    assert c.post("/api/v1/auth/signup", json={"email": "a@b.com", "password": PW},
                  headers={"X-Registration-Key": "rk"}).status_code == 200
    assert c.get("/api/v1/auth/options").json()["registration_key_required"] is True
    s2 = Settings(env="test", storage="memory", signup_open=False)
    c2 = TestClient(main.create_app(s2, MemoryStore()))
    assert c2.post("/api/v1/auth/signup", json={"email": "a@b.com", "password": PW}).status_code == 403


def test_passwords_and_codes_are_never_stored_in_clear(pg_dsn):
    import psycopg
    from storage import PostgresStore
    from tests.conftest import truncate
    truncate(pg_dsn)
    st = PostgresStore(pg_dsn)
    c = TestClient(main.create_app(Settings(env="test", storage="postgres", database_url=pg_dsn), st))
    j, _ = signup(c)
    with psycopg.connect(pg_dsn) as conn:
        row = conn.execute("SELECT password_hash, recovery_hash FROM users WHERE email='asha@example.com'").fetchone()
        sess = conn.execute("SELECT token_hash FROM sessions").fetchall()
    st.close()
    assert row[0].startswith("scrypt$") and PW not in row[0]
    assert j["recovery_code"] not in row[1] and len(row[1]) == 64
    assert all(j["token"] not in s[0] for s in sess)


@pytest.mark.parametrize("pw,ok", [("abcdefgh", True), ("1234567", False), ("asha@example.com", False)])
def test_password_policy_unit(pw, ok):
    assert (auth.password_problem(pw, "asha@example.com") is None) is ok


def test_password_hash_roundtrip():
    h = auth.hash_password("s3cret pass")
    assert auth.verify_password("s3cret pass", h) and not auth.verify_password("s3cret pas", h)
    assert not auth.verify_password("x", None) and not auth.verify_password("x", "garbage")
