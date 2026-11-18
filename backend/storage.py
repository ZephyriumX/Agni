"""Persistence. PostgresStore (Supabase/any PostgreSQL) is the real implementation;
MemoryStore exists ONLY for unit tests / throw-away demos (AGNI_STORAGE=memory) and logs a warning.

All multi-row writes happen in one transaction. Every read/write is scoped by user_id, so a caller
can never reach another user's rows by guessing IDs.
"""
from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from typing import Any, Optional

log = logging.getLogger("agni.storage")


class StorageUnavailable(RuntimeError):
    """Database cannot be reached / write failed (-> HTTP 503)."""


class EmailTaken(ValueError):
    """An account with this e-mail already exists."""


USER_COLS = ("user_id,created_at,prakriti_type,baseline_rmssd,baseline_ba_ratio,email,display_name,profile,"
             "prakriti_scores,onboarding_completed_at,(password_hash IS NOT NULL) AS has_password")
AUTH_COLS = ("user_id,email,password_hash,recovery_hash,failed_logins,locked_until")
PROFILE_FIELDS = ("display_name", "prakriti_type", "prakriti_scores", "profile")


SCAN_SUMMARY_COLS = ("scan_id,user_id,timestamp,tag_event,context_tags,meal_id,sampling_rate,effective_fs,"
                     "duration_s,channel,avg_bpm,rmssd,ba_ratio,sqi_passed,features,sqi_report,"
                     "processing_ms,algo_version,intervention,notes")


def _norm(row: Optional[dict]) -> Optional[dict]:
    if row is None:
        return None
    out = {}
    for k, v in row.items():
        if isinstance(v, uuid.UUID):
            v = str(v)
        elif isinstance(v, datetime):
            v = v.isoformat()
        out[k] = v
    return out


# =============================================================================== Postgres
class PostgresStore:
    def __init__(self, dsn: str, min_size: int = 1, max_size: int = 8):
        from psycopg.rows import dict_row
        from psycopg_pool import ConnectionPool
        # prepare_threshold=None: required for Supabase's transaction-mode pooler (pgbouncer)
        self.pool = ConnectionPool(dsn, min_size=min_size, max_size=max_size, open=False, timeout=8,
                                   kwargs={"row_factory": dict_row, "prepare_threshold": None,
                                           "connect_timeout": 6})
        self.pool.open(wait=False)

    def close(self):
        self.pool.close()

    def _run(self, fn):
        import psycopg
        from psycopg_pool import PoolTimeout
        try:
            with self.pool.connection() as conn:
                return fn(conn)
        except PoolTimeout as e:
            raise StorageUnavailable("database connection pool timed out") from e
        except (psycopg.OperationalError, psycopg.errors.AdminShutdown) as e:
            log.error("database unavailable: %s", type(e).__name__)
            raise StorageUnavailable("database unavailable") from e

    def ping(self) -> bool:
        def f(c):
            c.execute("SELECT 1")
            return True
        return self._run(f)

    def schema_ok(self) -> bool:
        def f(c):
            r = c.execute("SELECT to_regclass('public.comparisons') AS c, "
                          "to_regclass('public.schema_migrations') AS m").fetchone()
            return bool(r["c"] and r["m"])
        return self._run(f)

    # -- users
    def create_user(self, token_hash: Optional[str], prakriti: Optional[str] = None,
                    user_id: Optional[str] = None) -> dict:
        def f(c):
            r = c.execute("INSERT INTO users (user_id, token_hash, prakriti_type) "
                          "VALUES (COALESCE(%s::uuid, gen_random_uuid()), %s, %s) "
                          "ON CONFLICT (user_id) DO UPDATE SET user_id = EXCLUDED.user_id RETURNING " + USER_COLS,
                          (user_id, token_hash, prakriti)).fetchone()
            return _norm(r)
        return self._run(f)

    def create_account(self, email: str, password_hash: str, recovery_hash: str,
                       display_name: Optional[str], prakriti: Optional[str] = None) -> dict:
        import psycopg

        def f(c):
            try:
                with c.transaction():
                    return _norm(c.execute(
                        "INSERT INTO users (email, password_hash, recovery_hash, display_name, prakriti_type) "
                        "VALUES (%s,%s,%s,%s,%s) RETURNING " + USER_COLS,
                        (email, password_hash, recovery_hash, display_name, prakriti)).fetchone())
            except psycopg.errors.UniqueViolation as e:
                raise EmailTaken(email) from e
        return self._run(f)

    def get_user(self, user_id: str) -> Optional[dict]:
        return self._run(lambda c: _norm(c.execute(
            "SELECT " + USER_COLS + " FROM users WHERE user_id=%s", (user_id,)).fetchone()))

    def get_user_by_token_hash(self, h: str) -> Optional[dict]:
        return self._run(lambda c: _norm(c.execute(
            "SELECT user_id,prakriti_type FROM users WHERE token_hash=%s", (h,)).fetchone()))

    def get_auth_by_email(self, email: str) -> Optional[dict]:
        return self._run(lambda c: _norm(c.execute(
            "SELECT " + AUTH_COLS + " FROM users WHERE lower(email)=lower(%s)", (email,)).fetchone()))

    def get_auth(self, user_id: str) -> Optional[dict]:
        return self._run(lambda c: _norm(c.execute(
            "SELECT " + AUTH_COLS + " FROM users WHERE user_id=%s", (user_id,)).fetchone()))

    def set_credentials(self, user_id: str, *, email: Optional[str] = None, password_hash: Optional[str] = None,
                        recovery_hash: Optional[str] = None) -> dict:
        import psycopg
        sets, vals = [], []
        for col, v in (("email", email), ("password_hash", password_hash), ("recovery_hash", recovery_hash)):
            if v is not None:
                sets.append(f"{col}=%s")
                vals.append(v)
        sets.append("failed_logins=0, locked_until=NULL, updated_at=NOW()")

        def f(c):
            try:
                with c.transaction():
                    return _norm(c.execute(f"UPDATE users SET {', '.join(sets)} WHERE user_id=%s RETURNING "
                                           + USER_COLS, (*vals, user_id)).fetchone())
            except psycopg.errors.UniqueViolation as e:
                raise EmailTaken(email or "") from e
        return self._run(f)

    def record_login_failure(self, user_id: str, max_failed: int, lockout_minutes: int) -> None:
        self._run(lambda c: c.execute(
            "UPDATE users SET failed_logins = failed_logins + 1, locked_until = CASE WHEN failed_logins + 1 >= %s "
            "THEN NOW() + make_interval(mins => %s) ELSE locked_until END WHERE user_id=%s",
            (max_failed, lockout_minutes, user_id)))

    def reset_login_failures(self, user_id: str) -> None:
        self._run(lambda c: c.execute(
            "UPDATE users SET failed_logins=0, locked_until=NULL WHERE user_id=%s", (user_id,)))

    def update_profile(self, user_id: str, fields: dict, complete_onboarding: bool = False) -> dict:
        from psycopg.types.json import Jsonb
        sets, vals = [], []
        for k in PROFILE_FIELDS:
            if k in fields:
                v = fields[k]
                sets.append(f"{k}=%s")
                vals.append(Jsonb(v) if k in ("profile", "prakriti_scores") and v is not None else v)
        if complete_onboarding:
            sets.append("onboarding_completed_at=COALESCE(onboarding_completed_at, NOW())")
        sets.append("updated_at=NOW()")
        return self._run(lambda c: _norm(c.execute(
            f"UPDATE users SET {', '.join(sets)} WHERE user_id=%s RETURNING " + USER_COLS,
            (*vals, user_id)).fetchone()))

    def update_user(self, user_id: str, prakriti: Optional[str]) -> dict:
        return self.update_profile(user_id, {"prakriti_type": prakriti})

    def delete_user(self, user_id: str) -> None:
        def f(c):
            with c.transaction():
                c.execute("DELETE FROM comparisons WHERE user_id=%s", (user_id,))
                c.execute("DELETE FROM interventions WHERE user_id=%s", (user_id,))
                c.execute("DELETE FROM scans WHERE user_id=%s", (user_id,))
                c.execute("DELETE FROM meals WHERE user_id=%s", (user_id,))
                c.execute("DELETE FROM users WHERE user_id=%s", (user_id,))
        self._run(f)

    # -- sessions
    def create_session(self, user_id: str, token_hash: str, device_name: Optional[str], days: int) -> dict:
        return self._run(lambda c: _norm(c.execute(
            "INSERT INTO sessions (user_id, token_hash, device_name, expires_at) "
            "VALUES (%s,%s,%s,NOW() + make_interval(days => %s)) "
            "RETURNING session_id,user_id,device_name,created_at,last_used_at,expires_at",
            (user_id, token_hash, device_name, days)).fetchone()))

    def get_session(self, token_hash: str) -> Optional[dict]:
        def f(c):
            r = c.execute("SELECT session_id,user_id,last_used_at FROM sessions WHERE token_hash=%s "
                          "AND revoked_at IS NULL AND expires_at > NOW()", (token_hash,)).fetchone()
            if r is None:
                return None
            # touch at most once per hour (avoids a write on every request)
            c.execute("UPDATE sessions SET last_used_at=NOW() WHERE session_id=%s "
                      "AND last_used_at < NOW() - INTERVAL '1 hour'", (r["session_id"],))
            return _norm(r)
        return self._run(f)

    def list_sessions(self, user_id: str) -> list[dict]:
        return self._run(lambda c: [_norm(r) for r in c.execute(
            "SELECT session_id,device_name,created_at,last_used_at,expires_at FROM sessions "
            "WHERE user_id=%s AND revoked_at IS NULL AND expires_at > NOW() ORDER BY last_used_at DESC",
            (user_id,)).fetchall()])

    def revoke_session(self, user_id: str, session_id: str) -> None:
        self._run(lambda c: c.execute("UPDATE sessions SET revoked_at=NOW() WHERE session_id=%s AND user_id=%s "
                                      "AND revoked_at IS NULL", (session_id, user_id)))

    def revoke_all_sessions(self, user_id: str, except_session: Optional[str] = None) -> int:
        return self._run(lambda c: c.execute(
            "UPDATE sessions SET revoked_at=NOW() WHERE user_id=%s AND revoked_at IS NULL "
            "AND (%s::uuid IS NULL OR session_id <> %s::uuid)", (user_id, except_session, except_session)).rowcount)

    # -- e-mailed reset codes
    def create_reset(self, user_id: str, code_hash: str, minutes: int) -> None:
        def f(c):
            with c.transaction():
                c.execute("UPDATE password_resets SET used_at=NOW() WHERE user_id=%s AND used_at IS NULL", (user_id,))
                c.execute("INSERT INTO password_resets (user_id, code_hash, expires_at) "
                          "VALUES (%s,%s,NOW() + make_interval(mins => %s))", (user_id, code_hash, minutes))
        self._run(f)

    def consume_reset(self, user_id: str, code_hash: str, max_attempts: int = 5) -> bool:
        def f(c):
            with c.transaction():
                r = c.execute("SELECT reset_id, code_hash, attempts FROM password_resets WHERE user_id=%s "
                              "AND used_at IS NULL AND expires_at > NOW() ORDER BY created_at DESC LIMIT 1 "
                              "FOR UPDATE", (user_id,)).fetchone()
                if r is None or r["attempts"] >= max_attempts:
                    return False
                if r["code_hash"] == code_hash:
                    c.execute("UPDATE password_resets SET used_at=NOW() WHERE reset_id=%s", (r["reset_id"],))
                    return True
                c.execute("UPDATE password_resets SET attempts=attempts+1 WHERE reset_id=%s", (r["reset_id"],))
                return False
        return self._run(f)

    # -- scans
    def save_scan(self, row: dict, set_baseline: bool) -> tuple[dict, bool]:
        """Insert scan (+ baseline update) atomically. Idempotent on (user_id, client_scan_id).
        Returns (stored_row, created)."""
        from psycopg.types.json import Jsonb

        def f(c):
            with c.transaction():
                if row.get("client_scan_id"):
                    ex = c.execute("SELECT * FROM scans WHERE user_id=%s AND client_scan_id=%s",
                                   (row["user_id"], row["client_scan_id"])).fetchone()
                    if ex:
                        return _norm(ex), False
                r = c.execute(
                    """INSERT INTO scans (user_id, client_scan_id, tag_event, context_tags, meal_id, raw_signal,
                         raw_timestamps, sampling_rate, effective_fs, duration_s, channel, avg_bpm, rmssd,
                         ba_ratio, sqi_passed, features, sqi_report, processing_ms, algo_version, template,
                         intervention, notes)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
                    (row["user_id"], row.get("client_scan_id"), row["tag_event"],
                     Jsonb(row.get("context_tags") or []), row.get("meal_id"), Jsonb(row["raw_signal"]),
                     Jsonb(row.get("raw_timestamps")) if row.get("raw_timestamps") is not None else None,
                     row["sampling_rate"], row.get("effective_fs"), row.get("duration_s"), row.get("channel"),
                     row.get("avg_bpm"), row.get("rmssd"), row.get("ba_ratio"), row["sqi_passed"],
                     Jsonb(row.get("features")), Jsonb(row.get("sqi_report")), row.get("processing_ms"),
                     row.get("algo_version"), Jsonb(row.get("template")), row.get("intervention"),
                     row.get("notes"))).fetchone()
                if set_baseline:
                    c.execute("UPDATE users SET baseline_rmssd=%s, baseline_ba_ratio=%s, updated_at=NOW() "
                              "WHERE user_id=%s", (row["rmssd"], row["ba_ratio"], row["user_id"]))
                return _norm(r), True
        return self._run(f)

    def get_scan(self, user_id: str, scan_id: str, full: bool = False) -> Optional[dict]:
        cols = "*" if full else SCAN_SUMMARY_COLS + ",template"
        return self._run(lambda c: _norm(c.execute(
            f"SELECT {cols} FROM scans WHERE scan_id=%s AND user_id=%s", (scan_id, user_id)).fetchone()))

    def list_scans(self, user_id: str, limit: int = 2000) -> list[dict]:
        """Oldest first; the most recent `limit` scans."""
        return self._run(lambda c: [_norm(r) for r in c.execute(
            f"SELECT * FROM (SELECT {SCAN_SUMMARY_COLS} FROM scans WHERE user_id=%s "
            f"ORDER BY timestamp DESC LIMIT %s) x ORDER BY timestamp ASC",
            (user_id, limit)).fetchall()])

    def delete_scan(self, user_id: str, scan_id: str) -> bool:
        """Delete one scan (its comparisons/interventions cascade) and recompute the stored baseline."""
        def f(c):
            with c.transaction():
                r = c.execute("DELETE FROM scans WHERE scan_id=%s AND user_id=%s RETURNING scan_id",
                              (scan_id, user_id)).fetchone()
                if r is None:
                    return False
                b = c.execute("SELECT rmssd, ba_ratio FROM scans WHERE user_id=%s AND tag_event='Baseline' "
                              "AND sqi_passed ORDER BY timestamp DESC LIMIT 1", (user_id,)).fetchone()
                c.execute("UPDATE users SET baseline_rmssd=%s, baseline_ba_ratio=%s, updated_at=NOW() "
                          "WHERE user_id=%s", (b["rmssd"] if b else None, b["ba_ratio"] if b else None, user_id))
                return True
        return self._run(f)

    # -- comparisons / interventions
    def save_comparison(self, user_id: str, comp: dict, intervention: Optional[dict]) -> tuple[dict, Optional[dict]]:
        from psycopg.types.json import Jsonb

        def f(c):
            with c.transaction():
                r = c.execute(
                    """INSERT INTO comparisons (user_id, baseline_scan_id, test_scan_id, delta_vascular_tone_pct,
                           hrv_ratio, compatibility_pct, verdict, interpretation)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
                       ON CONFLICT (baseline_scan_id, test_scan_id) DO UPDATE SET
                           delta_vascular_tone_pct=EXCLUDED.delta_vascular_tone_pct, hrv_ratio=EXCLUDED.hrv_ratio,
                           compatibility_pct=EXCLUDED.compatibility_pct, verdict=EXCLUDED.verdict,
                           interpretation=EXCLUDED.interpretation RETURNING *""",
                    (user_id, comp["baseline_scan_id"], comp["test_scan_id"], comp["delta_vascular_tone_pct"],
                     comp["hrv_ratio"], comp.get("compatibility_pct"), comp.get("verdict"),
                     Jsonb(comp.get("interpretation")))).fetchone()
                iv = None
                if intervention:
                    iv = c.execute(
                        """INSERT INTO interventions (user_id, pre_scan_id, post_scan_id, type, improvement_percentage)
                           VALUES (%s,%s,%s,%s,%s)
                           ON CONFLICT (pre_scan_id, post_scan_id, type) DO UPDATE SET
                               improvement_percentage=EXCLUDED.improvement_percentage RETURNING *""",
                        (user_id, comp["baseline_scan_id"], comp["test_scan_id"], intervention["type"],
                         intervention["improvement_percentage"])).fetchone()
                return _norm(r), _norm(iv)
        return self._run(f)

    def list_comparisons(self, user_id: str) -> list[dict]:
        return self._run(lambda c: [_norm(r) for r in c.execute(
            "SELECT * FROM comparisons WHERE user_id=%s ORDER BY created_at ASC", (user_id,)).fetchall()])

    def list_interventions(self, user_id: str) -> list[dict]:
        return self._run(lambda c: [_norm(r) for r in c.execute(
            "SELECT * FROM interventions WHERE user_id=%s ORDER BY created_at ASC", (user_id,)).fetchall()])

    # -- meals / diary
    def create_meal(self, user_id: str, name: str, perceived_load: Optional[int], meal_type: Optional[str] = None,
                    notes: Optional[str] = None, descriptors: Optional[list] = None) -> dict:
        from psycopg.types.json import Jsonb
        return self._run(lambda c: _norm(c.execute(
            "INSERT INTO meals (user_id,name,perceived_load,meal_type,notes,descriptors) "
            "VALUES (%s,%s,%s,%s,%s,%s) RETURNING *",
            (user_id, name, perceived_load, meal_type, notes, Jsonb(descriptors or []))).fetchone()))

    def list_meals(self, user_id: str) -> list[dict]:
        return self._run(lambda c: [_norm(r) for r in c.execute(
            "SELECT * FROM meals WHERE user_id=%s ORDER BY eaten_at ASC", (user_id,)).fetchall()])

    def delete_meal(self, user_id: str, meal_id: str) -> bool:
        return self._run(lambda c: c.execute(
            "DELETE FROM meals WHERE meal_id=%s AND user_id=%s", (meal_id, user_id)).rowcount > 0)

    def get_meal(self, user_id: str, meal_id: str) -> Optional[dict]:
        return self._run(lambda c: _norm(c.execute(
            "SELECT * FROM meals WHERE meal_id=%s AND user_id=%s", (meal_id, user_id)).fetchone()))

    def diary(self, user_id: str) -> list[dict]:
        def f(c):
            rows = c.execute(
                """SELECT m.meal_id, m.name, m.perceived_load, m.eaten_at, m.meal_type, m.descriptors,
                          s.scan_id AS test_scan_id,
                          k.compatibility_pct, k.verdict, k.hrv_ratio, k.delta_vascular_tone_pct
                     FROM meals m
                     LEFT JOIN LATERAL (SELECT scan_id FROM scans WHERE meal_id=m.meal_id AND sqi_passed
                                        ORDER BY timestamp DESC LIMIT 1) s ON TRUE
                     LEFT JOIN LATERAL (SELECT * FROM comparisons WHERE test_scan_id=s.scan_id
                                        ORDER BY created_at DESC LIMIT 1) k ON TRUE
                    WHERE m.user_id=%s ORDER BY m.eaten_at DESC""", (user_id,)).fetchall()
            return [_norm(r) for r in rows]
        return self._run(f)


# =============================================================================== Memory (tests only)
def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class MemoryStore:
    def __init__(self):
        log.warning("USING IN-MEMORY STORE: data is lost on restart (AGNI_STORAGE=memory)")
        self.users: dict[str, dict] = {}
        self.scans: dict[str, dict] = {}
        self.comparisons: dict[tuple, dict] = {}
        self.interventions: dict[tuple, dict] = {}
        self.meals: dict[str, dict] = {}
        self.sessions: dict[str, dict] = {}
        self.resets: list[dict] = []

    def close(self): ...
    def ping(self): return True
    def schema_ok(self): return True

    _PRIVATE = ("token_hash", "password_hash", "recovery_hash", "failed_logins", "locked_until")

    def _pub(self, u):
        if not u:
            return None
        out = {k: v for k, v in u.items() if k not in self._PRIVATE}
        out["has_password"] = u.get("password_hash") is not None
        return out

    def _new_user(self, uid, **kw):
        u = {"user_id": uid, "created_at": _now(), "prakriti_type": None, "baseline_rmssd": None,
             "baseline_ba_ratio": None, "token_hash": None, "email": None, "display_name": None, "profile": {},
             "prakriti_scores": None, "onboarding_completed_at": None, "password_hash": None,
             "recovery_hash": None, "failed_logins": 0, "locked_until": None}
        u.update(kw)
        return u

    def create_user(self, token_hash, prakriti=None, user_id=None):
        uid = user_id or str(uuid.uuid4())
        u = self.users.setdefault(uid, self._new_user(uid, token_hash=token_hash, prakriti_type=prakriti))
        return self._pub(u)

    def create_account(self, email, password_hash, recovery_hash, display_name, prakriti=None):
        if self.get_auth_by_email(email):
            raise EmailTaken(email)
        uid = str(uuid.uuid4())
        self.users[uid] = self._new_user(uid, email=email, password_hash=password_hash, recovery_hash=recovery_hash,
                                         display_name=display_name, prakriti_type=prakriti)
        return self._pub(self.users[uid])

    def get_user(self, user_id):
        return self._pub(self.users.get(user_id))

    def get_user_by_token_hash(self, h):
        for u in self.users.values():
            if u["token_hash"] == h:
                return {"user_id": u["user_id"], "prakriti_type": u["prakriti_type"]}
        return None

    def _auth(self, u):
        if not u:
            return None
        lu = u["locked_until"]
        return {k: u[k] for k in ("user_id", "email", "password_hash", "recovery_hash", "failed_logins")} | {
            "locked_until": lu.isoformat() if lu else None}

    def get_auth_by_email(self, email):
        for u in self.users.values():
            if u["email"] and u["email"].lower() == email.lower():
                return self._auth(u)
        return None

    def get_auth(self, user_id):
        return self._auth(self.users.get(user_id))

    def set_credentials(self, user_id, *, email=None, password_hash=None, recovery_hash=None):
        if email is not None:
            other = self.get_auth_by_email(email)
            if other and other["user_id"] != user_id:
                raise EmailTaken(email)
        u = self.users[user_id]
        for k, v in (("email", email), ("password_hash", password_hash), ("recovery_hash", recovery_hash)):
            if v is not None:
                u[k] = v
        u["failed_logins"], u["locked_until"] = 0, None
        return self._pub(u)

    def record_login_failure(self, user_id, max_failed, lockout_minutes):
        from datetime import timedelta
        u = self.users[user_id]
        u["failed_logins"] += 1
        if u["failed_logins"] >= max_failed:
            u["locked_until"] = datetime.now(timezone.utc) + timedelta(minutes=lockout_minutes)

    def reset_login_failures(self, user_id):
        self.users[user_id].update(failed_logins=0, locked_until=None)

    def update_profile(self, user_id, fields, complete_onboarding=False):
        u = self.users[user_id]
        for k in PROFILE_FIELDS:
            if k in fields:
                u[k] = fields[k]
        if complete_onboarding and not u["onboarding_completed_at"]:
            u["onboarding_completed_at"] = _now()
        return self._pub(u)

    def update_user(self, user_id, prakriti):
        return self.update_profile(user_id, {"prakriti_type": prakriti})

    def delete_user(self, user_id):
        self.scans = {k: v for k, v in self.scans.items() if v["user_id"] != user_id}
        self.comparisons = {k: v for k, v in self.comparisons.items() if v["user_id"] != user_id}
        self.interventions = {k: v for k, v in self.interventions.items() if v["user_id"] != user_id}
        self.meals = {k: v for k, v in self.meals.items() if v["user_id"] != user_id}
        self.sessions = {k: v for k, v in self.sessions.items() if v["user_id"] != user_id}
        self.users.pop(user_id, None)

    # -- sessions
    def create_session(self, user_id, token_hash, device_name, days):
        from datetime import timedelta
        now = datetime.now(timezone.utc)
        s = {"session_id": str(uuid.uuid4()), "user_id": user_id, "device_name": device_name,
             "created_at": now.isoformat(), "last_used_at": now.isoformat(),
             "expires_at": (now + timedelta(days=days)).isoformat(), "revoked_at": None, "token_hash": token_hash}
        self.sessions[s["session_id"]] = s
        return {k: v for k, v in s.items() if k not in ("token_hash", "revoked_at")}

    def get_session(self, token_hash):
        now = _now()
        for s in self.sessions.values():
            if s["token_hash"] == token_hash and s["revoked_at"] is None and s["expires_at"] > now:
                return {"session_id": s["session_id"], "user_id": s["user_id"], "last_used_at": s["last_used_at"]}
        return None

    def list_sessions(self, user_id):
        now = _now()
        return [{k: s[k] for k in ("session_id", "device_name", "created_at", "last_used_at", "expires_at")}
                for s in self.sessions.values()
                if s["user_id"] == user_id and s["revoked_at"] is None and s["expires_at"] > now]

    def revoke_session(self, user_id, session_id):
        s = self.sessions.get(session_id)
        if s and s["user_id"] == user_id and s["revoked_at"] is None:
            s["revoked_at"] = _now()

    def revoke_all_sessions(self, user_id, except_session=None):
        n = 0
        for s in self.sessions.values():
            if s["user_id"] == user_id and s["revoked_at"] is None and s["session_id"] != except_session:
                s["revoked_at"] = _now()
                n += 1
        return n

    # -- reset codes
    def create_reset(self, user_id, code_hash, minutes):
        from datetime import timedelta
        for r in self.resets:
            if r["user_id"] == user_id and r["used_at"] is None:
                r["used_at"] = _now()
        self.resets.append({"user_id": user_id, "code_hash": code_hash, "attempts": 0, "used_at": None,
                            "expires_at": (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()})

    def consume_reset(self, user_id, code_hash, max_attempts=5):
        live = [r for r in self.resets if r["user_id"] == user_id and r["used_at"] is None and r["expires_at"] > _now()]
        if not live or live[-1]["attempts"] >= max_attempts:
            return False
        r = live[-1]
        if r["code_hash"] == code_hash:
            r["used_at"] = _now()
            return True
        r["attempts"] += 1
        return False

    # -- scans
    def save_scan(self, row, set_baseline):
        for s in self.scans.values():
            if row.get("client_scan_id") and s["user_id"] == row["user_id"] and \
                    s.get("client_scan_id") == row["client_scan_id"]:
                return dict(s), False
        r = {"intervention": None, "notes": None, **row, "scan_id": str(uuid.uuid4()), "timestamp": _now()}
        self.scans[r["scan_id"]] = r
        if set_baseline:
            self.users[row["user_id"]].update(baseline_rmssd=row["rmssd"], baseline_ba_ratio=row["ba_ratio"])
        return dict(r), True

    def get_scan(self, user_id, scan_id, full=False):
        s = self.scans.get(scan_id)
        if not s or s["user_id"] != user_id:
            return None
        return dict(s) if full else {k: v for k, v in s.items() if k not in ("raw_signal", "raw_timestamps")}

    def list_scans(self, user_id, limit=2000):
        mine = sorted((s for s in self.scans.values() if s["user_id"] == user_id), key=lambda s: s["timestamp"])
        return [self.get_scan(user_id, s["scan_id"]) for s in mine[-limit:]]

    def delete_scan(self, user_id, scan_id):
        s = self.scans.get(scan_id)
        if not s or s["user_id"] != user_id:
            return False
        del self.scans[scan_id]
        self.comparisons = {k: v for k, v in self.comparisons.items() if scan_id not in k}
        self.interventions = {k: v for k, v in self.interventions.items() if scan_id not in k[:2]}
        base = [x for x in self.list_scans(user_id) if x["tag_event"] == "Baseline" and x["sqi_passed"]]
        self.users[user_id].update(baseline_rmssd=base[-1]["rmssd"] if base else None,
                                   baseline_ba_ratio=base[-1]["ba_ratio"] if base else None)
        return True

    def save_comparison(self, user_id, comp, intervention):
        k = (comp["baseline_scan_id"], comp["test_scan_id"])
        r = {**comp, "user_id": user_id, "comparison_id": self.comparisons.get(k, {}).get(
            "comparison_id", str(uuid.uuid4())), "created_at": _now()}
        self.comparisons[k] = r
        iv = None
        if intervention:
            ik = (*k, intervention["type"])
            iv = {**intervention, "user_id": user_id, "pre_scan_id": k[0], "post_scan_id": k[1],
                  "intervention_id": self.interventions.get(ik, {}).get("intervention_id", str(uuid.uuid4())),
                  "created_at": _now()}
            self.interventions[ik] = iv
        return r, iv

    def list_comparisons(self, user_id):
        return [c for c in self.comparisons.values() if c["user_id"] == user_id]

    def list_interventions(self, user_id):
        return [i for i in self.interventions.values() if i["user_id"] == user_id]

    def create_meal(self, user_id, name, perceived_load, meal_type=None, notes=None, descriptors=None):
        m = {"meal_id": str(uuid.uuid4()), "user_id": user_id, "name": name, "perceived_load": perceived_load,
             "eaten_at": _now(), "meal_type": meal_type, "notes": notes, "descriptors": list(descriptors or [])}
        self.meals[m["meal_id"]] = m
        return m

    def list_meals(self, user_id):
        return sorted((m for m in self.meals.values() if m["user_id"] == user_id), key=lambda m: m["eaten_at"])

    def delete_meal(self, user_id, meal_id):
        m = self.meals.get(meal_id)
        if not m or m["user_id"] != user_id:
            return False
        del self.meals[meal_id]
        for s in self.scans.values():
            if s.get("meal_id") == meal_id:
                s["meal_id"] = None
        return True

    def get_meal(self, user_id, meal_id):
        m = self.meals.get(meal_id)
        return m if m and m["user_id"] == user_id else None

    def diary(self, user_id):
        out = []
        for m in sorted((m for m in self.meals.values() if m["user_id"] == user_id),
                        key=lambda m: m["eaten_at"], reverse=True):
            scans = [s for s in self.scans.values() if s.get("meal_id") == m["meal_id"] and s["sqi_passed"]]
            row = {**m, "test_scan_id": None, "compatibility_pct": None, "verdict": None,
                   "hrv_ratio": None, "delta_vascular_tone_pct": None}
            if scans:
                s = max(scans, key=lambda s: s["timestamp"])
                row["test_scan_id"] = s["scan_id"]
                cs = [c for c in self.comparisons.values() if c["test_scan_id"] == s["scan_id"]]
                if cs:
                    c = cs[-1]
                    row.update({k: c.get(k) for k in ("compatibility_pct", "verdict", "hrv_ratio",
                                                     "delta_vascular_tone_pct")})
            out.append(row)
        return out


def make_store(settings) -> Any:
    if settings.storage == "memory":
        return MemoryStore()
    return PostgresStore(settings.database_url)
