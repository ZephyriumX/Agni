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


SCAN_SUMMARY_COLS = ("scan_id,user_id,timestamp,tag_event,context_tags,meal_id,sampling_rate,effective_fs,"
                     "duration_s,channel,avg_bpm,rmssd,ba_ratio,sqi_passed,features,sqi_report,"
                     "processing_ms,algo_version")


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
                          "ON CONFLICT (user_id) DO UPDATE SET user_id = EXCLUDED.user_id RETURNING "
                          "user_id,created_at,prakriti_type,baseline_rmssd,baseline_ba_ratio",
                          (user_id, token_hash, prakriti)).fetchone()
            return _norm(r)
        return self._run(f)

    def get_user(self, user_id: str) -> Optional[dict]:
        return self._run(lambda c: _norm(c.execute(
            "SELECT user_id,created_at,prakriti_type,baseline_rmssd,baseline_ba_ratio FROM users "
            "WHERE user_id=%s", (user_id,)).fetchone()))

    def get_user_by_token_hash(self, h: str) -> Optional[dict]:
        return self._run(lambda c: _norm(c.execute(
            "SELECT user_id,prakriti_type FROM users WHERE token_hash=%s", (h,)).fetchone()))

    def update_user(self, user_id: str, prakriti: Optional[str]) -> dict:
        return self._run(lambda c: _norm(c.execute(
            "UPDATE users SET prakriti_type=%s, updated_at=NOW() WHERE user_id=%s "
            "RETURNING user_id,created_at,prakriti_type,baseline_rmssd,baseline_ba_ratio",
            (prakriti, user_id)).fetchone()))

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
                         ba_ratio, sqi_passed, features, sqi_report, processing_ms, algo_version, template)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
                    (row["user_id"], row.get("client_scan_id"), row["tag_event"],
                     Jsonb(row.get("context_tags") or []), row.get("meal_id"), Jsonb(row["raw_signal"]),
                     Jsonb(row.get("raw_timestamps")) if row.get("raw_timestamps") is not None else None,
                     row["sampling_rate"], row.get("effective_fs"), row.get("duration_s"), row.get("channel"),
                     row.get("avg_bpm"), row.get("rmssd"), row.get("ba_ratio"), row["sqi_passed"],
                     Jsonb(row.get("features")), Jsonb(row.get("sqi_report")), row.get("processing_ms"),
                     row.get("algo_version"), Jsonb(row.get("template")))).fetchone()
                if set_baseline:
                    c.execute("UPDATE users SET baseline_rmssd=%s, baseline_ba_ratio=%s, updated_at=NOW() "
                              "WHERE user_id=%s", (row["rmssd"], row["ba_ratio"], row["user_id"]))
                return _norm(r), True
        return self._run(f)

    def get_scan(self, user_id: str, scan_id: str, full: bool = False) -> Optional[dict]:
        cols = "*" if full else SCAN_SUMMARY_COLS + ",template"
        return self._run(lambda c: _norm(c.execute(
            f"SELECT {cols} FROM scans WHERE scan_id=%s AND user_id=%s", (scan_id, user_id)).fetchone()))

    def list_scans(self, user_id: str, limit: int = 200) -> list[dict]:
        return self._run(lambda c: [_norm(r) for r in c.execute(
            f"SELECT {SCAN_SUMMARY_COLS} FROM scans WHERE user_id=%s ORDER BY timestamp ASC LIMIT %s",
            (user_id, limit)).fetchall()])

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
    def create_meal(self, user_id: str, name: str, perceived_load: Optional[int]) -> dict:
        return self._run(lambda c: _norm(c.execute(
            "INSERT INTO meals (user_id,name,perceived_load) VALUES (%s,%s,%s) RETURNING *",
            (user_id, name, perceived_load)).fetchone()))

    def get_meal(self, user_id: str, meal_id: str) -> Optional[dict]:
        return self._run(lambda c: _norm(c.execute(
            "SELECT * FROM meals WHERE meal_id=%s AND user_id=%s", (meal_id, user_id)).fetchone()))

    def diary(self, user_id: str) -> list[dict]:
        def f(c):
            rows = c.execute(
                """SELECT m.meal_id, m.name, m.perceived_load, m.eaten_at, s.scan_id AS test_scan_id,
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

    def close(self): ...
    def ping(self): return True
    def schema_ok(self): return True

    def create_user(self, token_hash, prakriti=None, user_id=None):
        uid = user_id or str(uuid.uuid4())
        u = self.users.setdefault(uid, {"user_id": uid, "created_at": _now(), "prakriti_type": prakriti,
                                        "baseline_rmssd": None, "baseline_ba_ratio": None,
                                        "token_hash": token_hash})
        return {k: v for k, v in u.items() if k != "token_hash"}

    def get_user(self, user_id):
        u = self.users.get(user_id)
        return {k: v for k, v in u.items() if k != "token_hash"} if u else None

    def get_user_by_token_hash(self, h):
        for u in self.users.values():
            if u["token_hash"] == h:
                return {"user_id": u["user_id"], "prakriti_type": u["prakriti_type"]}
        return None

    def update_user(self, user_id, prakriti):
        self.users[user_id]["prakriti_type"] = prakriti
        return self.get_user(user_id)

    def save_scan(self, row, set_baseline):
        for s in self.scans.values():
            if row.get("client_scan_id") and s["user_id"] == row["user_id"] and \
                    s.get("client_scan_id") == row["client_scan_id"]:
                return dict(s), False
        r = {**row, "scan_id": str(uuid.uuid4()), "timestamp": _now()}
        self.scans[r["scan_id"]] = r
        if set_baseline:
            self.users[row["user_id"]].update(baseline_rmssd=row["rmssd"], baseline_ba_ratio=row["ba_ratio"])
        return dict(r), True

    def get_scan(self, user_id, scan_id, full=False):
        s = self.scans.get(scan_id)
        if not s or s["user_id"] != user_id:
            return None
        return dict(s) if full else {k: v for k, v in s.items() if k not in ("raw_signal", "raw_timestamps")}

    def list_scans(self, user_id, limit=200):
        return [self.get_scan(user_id, s["scan_id"]) for s in sorted(
            (s for s in self.scans.values() if s["user_id"] == user_id), key=lambda s: s["timestamp"])][:limit]

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

    def create_meal(self, user_id, name, perceived_load):
        m = {"meal_id": str(uuid.uuid4()), "user_id": user_id, "name": name,
             "perceived_load": perceived_load, "eaten_at": _now()}
        self.meals[m["meal_id"]] = m
        return m

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
