"""Agni-Pulse FastAPI service.   Run:  uvicorn main:app --host 0.0.0.0 --port 8000"""
from __future__ import annotations

import logging
import time
import uuid
from typing import Literal, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

import auth
import dsp_engine as dsp
from biofeedback import DISCLAIMER, compatibility, interpret
from config import Settings
from storage import StorageUnavailable, make_store

log = logging.getLogger("agni.api")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

Tag = Literal["Baseline", "Post-Meal", "Post-Vajrasana", "Caffeine", "Stress", "Poor-Sleep", "Pre-Yoga"]
ContextTag = Literal["Caffeine", "Stress", "Poor-Sleep"]
InterventionType = Literal["Vajrasana", "Sitali Pranayama", "Ginger Water / Pawanmuktasana"]
Prakriti = Literal["Vata", "Pitta", "Kapha", "Vata-Pitta", "Pitta-Kapha", "Vata-Kapha", "Tridosha"]


# ------------------------------------------------------------------ models
class _Strict(BaseModel):
    model_config = ConfigDict(extra="ignore")


class RegisterRequest(_Strict):
    prakriti_type: Optional[Prakriti] = None


class RegisterResponse(BaseModel):
    user_id: str
    token: str = Field(description="Shown once. Store it in the device secure storage.")


class MeUpdate(_Strict):
    prakriti_type: Optional[Prakriti] = None


class ScanRequest(_Strict):
    tag: Tag
    context: list[ContextTag] = Field(default_factory=list, max_length=3)
    client_scan_id: Optional[uuid.UUID] = Field(None, description="Idempotency key: retrying the same upload never duplicates")
    meal_id: Optional[uuid.UUID] = None
    compare_to: Optional[uuid.UUID] = Field(None, description="Scan to compare against (default: latest valid Baseline)")
    fs: Optional[float] = Field(None, description="Used only when timestamps are absent (>= 60)")
    timestamps: Optional[list[float]] = Field(None, description="Sensor timestamps in seconds, same length as red")
    red: list[float] = Field(..., min_length=10)
    green: Optional[list[float]] = None
    invert: bool = True

    @field_validator("red", "green", "timestamps")
    @classmethod
    def _finite(cls, v):
        if v is not None and any(x != x or abs(x) == float("inf") for x in v):
            raise ValueError("non-finite values")
        return v

    @model_validator(mode="after")
    def _shape(self):
        if self.timestamps is None and self.fs is None:
            raise ValueError("either timestamps or fs is required")
        for name in ("green", "timestamps"):
            v = getattr(self, name)
            if v is not None and len(v) != len(self.red):
                raise ValueError(f"{name} and red must be the same length")
        return self


class CompareRequest(_Strict):
    baseline_scan_id: uuid.UUID
    test_scan_id: uuid.UUID
    intervention_type: Optional[InterventionType] = None


class MealRequest(_Strict):
    name: str = Field(..., min_length=1, max_length=120)
    perceived_load: Optional[int] = Field(None, ge=1, le=5)


def _finite(v):
    return None if v is None or v != v or abs(v) == float("inf") else float(v)


def _r(v, n):
    v = _finite(v)
    return None if v is None else round(v, n)


# ------------------------------------------------------------------ app factory
class BodyLimit:
    """ASGI middleware: reject oversized bodies early (also when Content-Length is absent/lies)."""

    def __init__(self, app, limit: int):
        self.app, self.limit = app, limit

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        cl = dict(scope["headers"]).get(b"content-length")
        if cl and cl.isdigit() and int(cl) > self.limit:
            return await JSONResponse({"detail": "request body too large"}, 413)(scope, receive, send)
        seen = 0

        async def limited():
            nonlocal seen
            msg = await receive()
            if msg["type"] == "http.request":
                seen += len(msg.get("body", b""))
                if seen > self.limit:
                    raise HTTPException(413, "request body too large")
            return msg
        await self.app(scope, limited, send)


def create_app(settings: Optional[Settings] = None, store=None) -> FastAPI:
    settings = settings or Settings.load()
    store = store or make_store(settings)
    app = FastAPI(title="Agni-Pulse API", version="0.4.0", description=DISCLAIMER)
    app.state.settings, app.state.store = settings, store
    current_user = auth.make_current_user(settings, lambda: store)
    reg_limiter = auth.RateLimiter(settings.register_per_hour, 3600)

    app.add_middleware(BodyLimit, limit=settings.max_body_bytes)
    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["GET", "POST", "PATCH"],
                           allow_headers=["Authorization", "Content-Type"])

    @app.middleware("http")
    async def access_log(request: Request, call_next):
        t0, rid = time.perf_counter(), uuid.uuid4().hex[:8]
        try:
            resp = await call_next(request)
        except Exception:
            log.exception("unhandled error rid=%s path=%s", rid, request.url.path)
            resp = JSONResponse({"detail": "internal server error", "request_id": rid}, 500)
        resp.headers["X-Request-ID"] = rid
        log.info("rid=%s %s %s -> %s %.0fms", rid, request.method, request.url.path, resp.status_code,
                 (time.perf_counter() - t0) * 1000)   # never log bodies, tokens or signals
        return resp

    @app.exception_handler(StorageUnavailable)
    async def _storage_down(request, exc):
        return JSONResponse({"detail": "storage temporarily unavailable, retry shortly", "code": "storage_unavailable"},
                            503, headers={"Retry-After": "5"})

    # ---------------------------------------------------------------- health
    @app.get("/health")
    def health():
        return {"ok": True, "version": app.version, "env": settings.env, "storage": settings.storage,
                "auth_mode": settings.auth_mode}

    @app.get("/api/v1/capture-config")
    def capture_config():
        """FPS / timing thresholds the server applies (engineering parameters, not clinical limits).
        Public and secret-free so the app can show the same numbers it will be judged by."""
        return settings.capture.public()

    @app.get("/ready")
    def ready():
        try:
            store.ping()
            if not store.schema_ok():
                return JSONResponse({"ok": False, "detail": "schema not migrated: run python migrate.py"}, 503)
        except StorageUnavailable:
            return JSONResponse({"ok": False, "detail": "database unreachable"}, 503)
        return {"ok": True, "database": True, "storage": settings.storage}

    # ---------------------------------------------------------------- auth / profile
    @app.post("/api/v1/auth/register", response_model=RegisterResponse)
    def register(req: RegisterRequest, request: Request, x_registration_key: Optional[str] = Header(None)):
        if settings.auth_mode != "token":
            raise HTTPException(404, "registration is only available in token auth mode")
        auth.check_registration_key(settings, x_registration_key)
        reg_limiter.check(request.client.host if request.client else "?")
        tok = auth.new_token()
        u = store.create_user(auth.hash_token(tok), req.prakriti_type)
        return RegisterResponse(user_id=u["user_id"], token=tok)

    @app.get("/api/v1/me")
    def me(uid: str = Depends(current_user)):
        return store.get_user(uid)

    @app.patch("/api/v1/me")
    def update_me(req: MeUpdate, uid: str = Depends(current_user)):
        return store.update_user(uid, req.prakriti_type)

    # ---------------------------------------------------------------- scans
    def _compare(uid: str, base: dict, test: dict, intervention_type: Optional[str]):
        for s in (base, test):
            if not s["sqi_passed"] or s["ba_ratio"] is None or s["rmssd"] is None:
                raise HTTPException(422, f"scan {s['scan_id']} failed signal quality; cannot compare")
        tone = dsp.percent_change_vascular_tone(test["ba_ratio"], base["ba_ratio"])
        ratio = dsp.hrv_ratio(test["rmssd"], base["rmssd"])
        pct, verdict = compatibility(ratio)
        interp = interpret(test["tag_event"], test.get("context_tags") or [], tone, ratio)
        comp = {"baseline_scan_id": base["scan_id"], "test_scan_id": test["scan_id"],
                "delta_vascular_tone_pct": round(tone, 2), "hrv_ratio": round(ratio, 3),
                "compatibility_pct": pct, "verdict": verdict, "interpretation": interp}
        itype = intervention_type or ("Vajrasana" if test["tag_event"] == "Post-Vajrasana" else None)
        # improvement_percentage = how much b/a moved toward more compliant (more negative); PRD F5
        iv = {"type": itype, "improvement_percentage": round(-tone, 2)} if itype else None
        return store.save_comparison(uid, comp, iv)

    @app.post("/api/v1/scan/process")
    def process_scan(req: ScanRequest, uid: str = Depends(current_user)):
        # sync endpoint => FastAPI runs it in a worker thread, so DSP never blocks the event loop
        if len(req.red) > settings.max_samples:
            raise HTTPException(413, f"recording too long (> {settings.max_samples} samples)")
        if req.meal_id and not store.get_meal(uid, str(req.meal_id)):
            raise HTTPException(404, "meal not found")
        t0 = time.perf_counter()
        try:
            m = dsp.process_scan(req.red, req.fs, req.green, req.invert, req.timestamps,
                                 capture_cfg=settings.capture)
        except dsp.CaptureRejected as e:
            # same status/code as before; the report is additive so the app can show diagnostics
            return JSONResponse({"detail": str(e), "code": "signal_rejected", "capture_status": dsp.FAIL,
                                 "acquisition": e.report}, 422)
        except dsp.SignalError as e:
            return JSONResponse({"detail": str(e), "code": "signal_rejected"}, 422)
        proc_ms = (time.perf_counter() - t0) * 1000
        s = m.sqi
        sig = req.red if m.channel == "red" else req.green
        eff_fs = (m.acquisition or {}).get("fs_mean") or req.fs
        row = {
            "user_id": uid, "client_scan_id": str(req.client_scan_id) if req.client_scan_id else None,
            "tag_event": req.tag, "context_tags": req.context, "meal_id": str(req.meal_id) if req.meal_id else None,
            "raw_signal": sig, "raw_timestamps": req.timestamps, "sampling_rate": int(round(eff_fs)),
            "effective_fs": _finite(eff_fs), "duration_s": _finite(s.duration_s), "channel": m.channel,
            "avg_bpm": _finite(m.avg_bpm), "rmssd": _finite(m.rmssd_ms), "ba_ratio": _finite(m.ba_ratio),
            "sqi_passed": s.passed,
            "features": {"da_ratio": _r(m.da_ratio, 4), "aging_index": _r(m.aging_index, 4), "n_beats": m.n_beats,
                         "n_rr": m.n_rr, "acquisition": m.acquisition, "warnings": m.warnings},
            "sqi_report": {k: (_r(v, 4) if isinstance(v, float) else v) for k, v in s.__dict__.items()},
            "processing_ms": round(proc_ms, 1), "algo_version": dsp.ALGO_VERSION, "template": m.template,
        }
        stored, created = store.save_scan(row, set_baseline=(req.tag == "Baseline" and s.passed))

        comparison = None
        if created and req.tag != "Baseline" and s.passed:
            try:
                if req.compare_to:
                    base = store.get_scan(uid, str(req.compare_to))
                else:
                    cands = [x for x in store.list_scans(uid) if x["tag_event"] == "Baseline" and x["sqi_passed"]]
                    base = cands[-1] if cands else None
                if base and base["scan_id"] != stored["scan_id"]:
                    comp, iv = _compare(uid, base, store.get_scan(uid, stored["scan_id"]), None)
                    comparison = {**comp, "intervention": iv}
            except (HTTPException, ZeroDivisionError) as e:
                log.warning("auto-comparison skipped: %s", getattr(e, "detail", e))

        return {
            "scan_id": stored["scan_id"], "duplicate": not created, "tag": req.tag,
            "ba_ratio": _r(m.ba_ratio, 3), "da_ratio": _r(m.da_ratio, 3), "aging_index": _r(m.aging_index, 3),
            "rmssd_ms": _r(m.rmssd_ms, 1), "avg_bpm": _r(m.avg_bpm, 1), "channel": m.channel,
            "sqi": {k: (_r(v, 3) if isinstance(v, float) else v) for k, v in s.__dict__.items()},
            "acquisition": m.acquisition, "warnings": m.warnings, "processing_ms": round(proc_ms, 1),
            "capture_status": (m.acquisition or {}).get("status"),
            "final_status": dsp.combine_status((m.acquisition or {}).get("status"), s.passed),
            "template": m.template, "comparison": comparison, "disclaimer": DISCLAIMER}

    @app.get("/api/v1/scans/{scan_id}")
    def get_scan(scan_id: uuid.UUID, uid: str = Depends(current_user)):
        s = store.get_scan(uid, str(scan_id))
        if not s:
            raise HTTPException(404, "scan not found")
        return s

    @app.post("/api/v1/scan/compare")
    def compare(req: CompareRequest, uid: str = Depends(current_user)):
        if req.baseline_scan_id == req.test_scan_id:
            raise HTTPException(400, "choose two different scans")
        base, test = store.get_scan(uid, str(req.baseline_scan_id)), store.get_scan(uid, str(req.test_scan_id))
        if not base or not test:
            raise HTTPException(404, "scan not found")
        comp, iv = _compare(uid, base, test, req.intervention_type)
        return {**comp, "intervention": iv}

    @app.get("/api/v1/reports/{user_id}")
    def report(user_id: uuid.UUID, uid: str = Depends(current_user)):
        if str(user_id) != uid:
            raise HTTPException(403, "you can only read your own report")
        scans = store.list_scans(uid)
        base = [s for s in scans if s["tag_event"] == "Baseline" and s["sqi_passed"]]
        return {"user": store.get_user(uid), "baseline_scan_id": base[-1]["scan_id"] if base else None,
                "scans": scans, "comparisons": store.list_comparisons(uid),
                "interventions": store.list_interventions(uid), "disclaimer": DISCLAIMER}

    # ---------------------------------------------------------------- meals / diary
    @app.post("/api/v1/meals")
    def add_meal(req: MealRequest, uid: str = Depends(current_user)):
        return store.create_meal(uid, req.name.strip(), req.perceived_load)

    @app.get("/api/v1/diary")
    def diary(uid: str = Depends(current_user)):
        rows = store.diary(uid)
        scored = sorted([r for r in rows if r.get("compatibility_pct") is not None],
                        key=lambda r: r["compatibility_pct"], reverse=True)
        return {"ranked": scored, "pending": [r for r in rows if r.get("compatibility_pct") is None],
                "disclaimer": DISCLAIMER}

    return app


app = create_app()
