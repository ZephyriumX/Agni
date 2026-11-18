"""Agni-Pulse FastAPI service.   Run:  uvicorn main:app --host 0.0.0.0 --port 8000"""
from __future__ import annotations

import logging
import time
import uuid
from typing import Literal, Optional

from datetime import datetime, timezone

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

import analytics
import auth
import dsp_engine as dsp
from biofeedback import DISCLAIMER, compatibility, interpret
from config import Settings
from storage import EmailTaken, StorageUnavailable, make_store

log = logging.getLogger("agni.api")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

Tag = Literal["Baseline", "Post-Meal", "Post-Vajrasana", "Post-Intervention", "Post-Exercise",
              "Caffeine", "Stress", "Poor-Sleep", "Pre-Yoga"]
ContextTag = Literal["Caffeine", "Stress", "Poor-Sleep", "Fasting", "Alcohol", "Unwell", "Menstruation"]
InterventionType = Literal["Vajrasana", "Sitali Pranayama", "Ginger Water / Pawanmuktasana", "Deep Breathing",
                           "Meditation", "Walk", "Yoga", "Other"]
MealType = Literal["breakfast", "lunch", "dinner", "snack", "drink"]
MealDescriptor = Literal["spicy", "fried", "sweet", "heavy", "light", "dairy", "caffeinated", "home-cooked",
                         "outside", "raw", "late"]
INTERVENTION_SCAN_TAGS = {"Post-Intervention", "Post-Vajrasana"}
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


Email = Field(..., min_length=3, max_length=254, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class SignupRequest(_Strict):
    email: str = Email
    password: str = Field(..., min_length=1, max_length=128)
    display_name: Optional[str] = Field(None, max_length=80)
    device_name: Optional[str] = Field(None, max_length=80)


class LoginRequest(_Strict):
    email: str = Field(..., max_length=254)
    password: str = Field(..., max_length=128)
    device_name: Optional[str] = Field(None, max_length=80)


class UpgradeRequest(SignupRequest):
    pass


class RecoverRequest(_Strict):
    email: str = Field(..., max_length=254)
    recovery_code: str = Field(..., max_length=40)
    new_password: str = Field(..., max_length=128)
    device_name: Optional[str] = Field(None, max_length=80)


class ForgotRequest(_Strict):
    email: str = Field(..., max_length=254)


class ResetRequest(_Strict):
    email: str = Field(..., max_length=254)
    code: str = Field(..., max_length=12)
    new_password: str = Field(..., max_length=128)
    device_name: Optional[str] = Field(None, max_length=80)


class ChangePasswordRequest(_Strict):
    current_password: str = Field(..., max_length=128)
    new_password: str = Field(..., max_length=128)


class PasswordConfirm(_Strict):
    password: Optional[str] = Field(None, max_length=128)
    confirm: Optional[str] = Field(None, max_length=20, description="'DELETE' for accounts without a password")


class PrakritiScores(_Strict):
    vata: int = Field(..., ge=0, le=100)
    pitta: int = Field(..., ge=0, le=100)
    kapha: int = Field(..., ge=0, le=100)


class Profile(_Strict):
    birth_year: Optional[int] = Field(None, ge=1900, le=2025)
    sex: Optional[Literal["female", "male", "other", "prefer_not"]] = None
    height_cm: Optional[float] = Field(None, ge=80, le=250)
    weight_kg: Optional[float] = Field(None, ge=20, le=350)
    diet: Optional[Literal["vegetarian", "vegan", "eggetarian", "non_vegetarian", "jain", "other"]] = None
    activity: Optional[Literal["sedentary", "light", "moderate", "active"]] = None
    usual_wake_time: Optional[str] = Field(None, pattern=r"^\d{2}:\d{2}$")
    goals: list[Literal["digestion", "stress", "energy", "sleep", "heart_health", "weight", "fitness", "curiosity"]] \
        = Field(default_factory=list, max_length=8)


class ProfileUpdate(_Strict):
    display_name: Optional[str] = Field(None, max_length=80)
    prakriti_type: Optional[Prakriti] = None
    prakriti_scores: Optional[PrakritiScores] = None
    profile: Optional[Profile] = None
    onboarding_complete: Optional[bool] = None


class ScanRequest(_Strict):
    tag: Tag
    context: list[ContextTag] = Field(default_factory=list, max_length=3)
    client_scan_id: Optional[uuid.UUID] = Field(None, description="Idempotency key: retrying the same upload never duplicates")
    meal_id: Optional[uuid.UUID] = None
    intervention: Optional[InterventionType] = None
    notes: Optional[str] = Field(None, max_length=500)
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
    meal_type: Optional[MealType] = None
    notes: Optional[str] = Field(None, max_length=500)
    descriptors: list[MealDescriptor] = Field(default_factory=list, max_length=8)


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
    app = FastAPI(title="Agni-Pulse API", version="1.0.0", description=DISCLAIMER)
    app.state.settings, app.state.store = settings, store
    current_user = auth.make_current_user(settings, lambda: store)
    current_auth = auth.make_current_auth(settings, lambda: store)
    reg_limiter = auth.RateLimiter(settings.register_per_hour, 3600)
    login_limiter = auth.RateLimiter(settings.login_per_10min, 600)
    recover_limiter = auth.RateLimiter(10, 3600)

    app.add_middleware(BodyLimit, limit=settings.max_body_bytes)
    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["GET", "POST", "PATCH", "DELETE"],
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

    # ---------------------------------------------------------------- accounts (e-mail + password)
    def _ip(request: Request) -> str:
        return request.client.host if request.client else "?"

    def _token_mode():
        if settings.auth_mode != "token":
            raise HTTPException(404, "accounts are only available in token auth mode")

    def _norm_email(e: str) -> str:
        return e.strip().lower()

    def _check_pw(pw: str, email: str = ""):
        problem = auth.password_problem(pw, email)
        if problem:
            raise HTTPException(422, problem)

    def _session(uid: str, device: Optional[str]) -> str:
        tok = auth.new_session_token()
        store.create_session(uid, auth.hash_token(tok), (device or "")[:80] or None, auth.SESSION_DAYS)
        return tok

    def _locked(a: dict) -> bool:
        lu = a.get("locked_until")
        if not lu:
            return False
        t = datetime.fromisoformat(str(lu))
        return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)) > datetime.now(timezone.utc)

    @app.get("/api/v1/auth/options")
    def auth_options():
        """What the sign-in screens should offer (public, secret-free)."""
        return {"auth_mode": settings.auth_mode, "signup_open": settings.signup_open,
                "registration_key_required": bool(settings.registration_key),
                "email_reset": settings.email_enabled, "recovery_code": True,
                "password_min_length": 8}

    @app.post("/api/v1/auth/signup")
    def signup(req: SignupRequest, request: Request, x_registration_key: Optional[str] = Header(None)):
        _token_mode()
        if not settings.signup_open:
            raise HTTPException(403, "sign-up is closed on this server")
        auth.check_registration_key(settings, x_registration_key)
        reg_limiter.check(_ip(request))
        email = _norm_email(req.email)
        _check_pw(req.password, email)
        code = auth.new_recovery_code()
        try:
            u = store.create_account(email, auth.hash_password(req.password), auth.hash_recovery_code(code),
                                     (req.display_name or "").strip() or None)
        except EmailTaken:
            raise HTTPException(409, "an account with this e-mail already exists; sign in instead")
        return {"user_id": u["user_id"], "token": _session(u["user_id"], req.device_name),
                "recovery_code": code, "user": u}

    @app.post("/api/v1/auth/login")
    def login(req: LoginRequest, request: Request):
        _token_mode()
        login_limiter.check(_ip(request))
        a = store.get_auth_by_email(_norm_email(req.email))
        if a and _locked(a):
            raise HTTPException(429, "too many failed attempts; try again in a few minutes or reset your password")
        if not a or not auth.verify_password(req.password, a.get("password_hash")):
            if a:
                store.record_login_failure(a["user_id"], settings.max_failed_logins, settings.lockout_minutes)
            raise HTTPException(401, "wrong e-mail or password")
        store.reset_login_failures(a["user_id"])
        return {"user_id": a["user_id"], "token": _session(a["user_id"], req.device_name),
                "user": store.get_user(a["user_id"])}

    @app.post("/api/v1/auth/upgrade")
    def upgrade(req: UpgradeRequest, who: dict = Depends(current_auth)):
        """Give an existing anonymous (device-token) profile an e-mail + password, keeping all its data."""
        _token_mode()
        uid = who["user_id"]
        if (store.get_auth(uid) or {}).get("password_hash"):
            raise HTTPException(409, "this account already has a password")
        email = _norm_email(req.email)
        _check_pw(req.password, email)
        code = auth.new_recovery_code()
        try:
            store.set_credentials(uid, email=email, password_hash=auth.hash_password(req.password),
                                  recovery_hash=auth.hash_recovery_code(code))
        except EmailTaken:
            raise HTTPException(409, "an account with this e-mail already exists")
        if req.display_name:
            store.update_profile(uid, {"display_name": req.display_name.strip()})
        return {"user_id": uid, "token": _session(uid, req.device_name), "recovery_code": code,
                "user": store.get_user(uid)}

    @app.post("/api/v1/auth/logout")
    def logout(who: dict = Depends(current_auth)):
        if who["session_id"]:
            store.revoke_session(who["user_id"], who["session_id"])
        return {"ok": True}

    @app.post("/api/v1/auth/logout-all")
    def logout_all(who: dict = Depends(current_auth)):
        n = store.revoke_all_sessions(who["user_id"])
        return {"ok": True, "revoked": n}

    @app.get("/api/v1/auth/sessions")
    def sessions(who: dict = Depends(current_auth)):
        return [{**s, "current": s["session_id"] == who["session_id"]} for s in store.list_sessions(who["user_id"])]

    @app.post("/api/v1/auth/recover")
    def recover(req: RecoverRequest, request: Request):
        """Reset the password with the one-time recovery code; all devices are signed out."""
        _token_mode()
        recover_limiter.check(_ip(request))
        a = store.get_auth_by_email(_norm_email(req.email))
        ok = bool(a and a.get("recovery_hash")) and auth.hmac.compare_digest(
            a["recovery_hash"], auth.hash_recovery_code(req.recovery_code))
        if not ok:
            raise HTTPException(401, "e-mail or recovery code is wrong")
        _check_pw(req.new_password, a["email"] or "")
        code = auth.new_recovery_code()
        store.set_credentials(a["user_id"], password_hash=auth.hash_password(req.new_password),
                              recovery_hash=auth.hash_recovery_code(code))
        store.revoke_all_sessions(a["user_id"])
        return {"user_id": a["user_id"], "token": _session(a["user_id"], req.device_name), "recovery_code": code,
                "user": store.get_user(a["user_id"])}

    @app.post("/api/v1/auth/forgot")
    def forgot(req: ForgotRequest, request: Request):
        """E-mail a 6-digit reset code (only when SMTP is configured). Same answer whether or not the e-mail exists."""
        _token_mode()
        if not settings.email_enabled:
            raise HTTPException(501, "e-mail reset is not configured on this server; use your recovery code")
        recover_limiter.check(_ip(request))
        a = store.get_auth_by_email(_norm_email(req.email))
        if a and a.get("password_hash"):
            code = auth.new_reset_code()
            store.create_reset(a["user_id"], auth.hash_reset_code(a["user_id"], code), 15)
            try:
                auth.send_email(settings, a["email"], "Agni-Pulse password reset code",
                                f"Your Agni-Pulse reset code is {code}. It expires in 15 minutes.\n"
                                "If you did not ask for it, ignore this e-mail.")
            except Exception:
                log.exception("reset e-mail could not be sent")
                raise HTTPException(503, "the reset e-mail could not be sent; try again or use your recovery code")
        return {"ok": True, "detail": "If an account exists for this e-mail, a code has been sent."}

    @app.post("/api/v1/auth/reset")
    def reset(req: ResetRequest, request: Request):
        _token_mode()
        recover_limiter.check(_ip(request))
        a = store.get_auth_by_email(_norm_email(req.email))
        if not a or not store.consume_reset(a["user_id"], auth.hash_reset_code(a["user_id"], req.code)):
            raise HTTPException(401, "the code is wrong or has expired")
        _check_pw(req.new_password, a["email"] or "")
        store.set_credentials(a["user_id"], password_hash=auth.hash_password(req.new_password))
        store.revoke_all_sessions(a["user_id"])
        return {"user_id": a["user_id"], "token": _session(a["user_id"], req.device_name),
                "user": store.get_user(a["user_id"])}

    @app.post("/api/v1/auth/change-password")
    def change_password(req: ChangePasswordRequest, who: dict = Depends(current_auth)):
        a = store.get_auth(who["user_id"]) or {}
        if not auth.verify_password(req.current_password, a.get("password_hash")):
            raise HTTPException(401, "current password is wrong")
        _check_pw(req.new_password, a.get("email") or "")
        store.set_credentials(who["user_id"], password_hash=auth.hash_password(req.new_password))
        n = store.revoke_all_sessions(who["user_id"], except_session=who["session_id"])
        return {"ok": True, "other_sessions_signed_out": n}

    @app.post("/api/v1/auth/recovery-code")
    def new_recovery_code(req: PasswordConfirm, who: dict = Depends(current_auth)):
        a = store.get_auth(who["user_id"]) or {}
        if not auth.verify_password(req.password or "", a.get("password_hash")):
            raise HTTPException(401, "password is wrong")
        code = auth.new_recovery_code()
        store.set_credentials(who["user_id"], recovery_hash=auth.hash_recovery_code(code))
        return {"recovery_code": code}

    # ---------------------------------------------------------------- profile
    @app.get("/api/v1/me")
    def me(uid: str = Depends(current_user)):
        return store.get_user(uid)

    @app.patch("/api/v1/me")
    def update_me(req: ProfileUpdate, uid: str = Depends(current_user)):
        fields = req.model_dump(exclude_unset=True)
        complete = bool(fields.pop("onboarding_complete", False))
        if "display_name" in fields and fields["display_name"] is not None:
            fields["display_name"] = fields["display_name"].strip() or None
        return store.update_profile(uid, fields, complete_onboarding=complete)

    @app.post("/api/v1/me/delete")
    def delete_me(req: PasswordConfirm, who: dict = Depends(current_auth)):
        """Permanently delete the account and every scan, meal and comparison."""
        a = store.get_auth(who["user_id"]) or {}
        if a.get("password_hash"):
            if not auth.verify_password(req.password or "", a["password_hash"]):
                raise HTTPException(401, "password is wrong")
        elif req.confirm != "DELETE":
            raise HTTPException(400, "send confirm='DELETE' to delete this account")
        store.delete_user(who["user_id"])
        return {"ok": True}

    @app.get("/api/v1/export")
    def export(uid: str = Depends(current_user)):
        """All of the user's data as JSON (raw signals excluded; fetch a scan for its template)."""
        return {"exported_at": datetime.now(timezone.utc).isoformat(), "user": store.get_user(uid),
                "scans": store.list_scans(uid), "meals": store.list_meals(uid),
                "comparisons": store.list_comparisons(uid), "interventions": store.list_interventions(uid)}

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
        itype = intervention_type or test.get("intervention") or \
            ("Vajrasana" if test["tag_event"] == "Post-Vajrasana" else None)
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
            "intervention": req.intervention or ("Vajrasana" if req.tag == "Post-Vajrasana" else None),
            "notes": (req.notes or "").strip() or None,
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
                    comp, iv = _compare(uid, base, store.get_scan(uid, stored["scan_id"]),
                                        req.intervention if req.tag in INTERVENTION_SCAN_TAGS else None)
                    comparison = {**comp, "intervention": iv}
            except (HTTPException, ZeroDivisionError) as e:
                log.warning("auto-comparison skipped: %s", getattr(e, "detail", e))

        return {
            "scan_id": stored["scan_id"], "duplicate": not created, "tag": req.tag,
            "ba_ratio": _r(m.ba_ratio, 3), "da_ratio": _r(m.da_ratio, 3), "aging_index": _r(m.aging_index, 3),
            "rmssd_ms": _r(m.rmssd_ms, 1), "avg_bpm": _r(m.avg_bpm, 1), "channel": m.channel,
            "intervention": row["intervention"], "timestamp": stored.get("timestamp"),
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

    @app.get("/api/v1/scans")
    def list_scans(uid: str = Depends(current_user), tag: Optional[str] = None,
                   limit: int = Query(200, ge=1, le=2000), good_only: bool = False):
        """Scan history, newest first, with meal names attached."""
        meals = {m["meal_id"]: m for m in store.list_meals(uid)}
        rows = [s for s in reversed(store.list_scans(uid))
                if (tag is None or s["tag_event"] == tag) and (not good_only or s["sqi_passed"])][:limit]
        for r in rows:
            m = meals.get(r.get("meal_id")) if r.get("meal_id") else None
            r["meal_name"] = m["name"] if m else None
        return rows

    @app.delete("/api/v1/scans/{scan_id}")
    def delete_scan(scan_id: uuid.UUID, uid: str = Depends(current_user)):
        if not store.delete_scan(uid, str(scan_id)):
            raise HTTPException(404, "scan not found")
        return {"ok": True}

    @app.post("/api/v1/scan/compare")
    def compare(req: CompareRequest, uid: str = Depends(current_user)):
        if req.baseline_scan_id == req.test_scan_id:
            raise HTTPException(400, "choose two different scans")
        base, test = store.get_scan(uid, str(req.baseline_scan_id)), store.get_scan(uid, str(req.test_scan_id))
        if not base or not test:
            raise HTTPException(404, "scan not found")
        comp, iv = _compare(uid, base, test, req.intervention_type)
        return {**comp, "intervention": iv}

    @app.get("/api/v1/analytics")
    def get_analytics(uid: str = Depends(current_user), days: int = Query(90, ge=1, le=3650),
                      tz_offset_min: int = Query(0, ge=-840, le=840)):
        """Personal analytics and insights computed from this user's own history only."""
        return analytics.build(store.get_user(uid), store.list_scans(uid), store.list_meals(uid),
                               store.list_interventions(uid), days=days, tz_offset_min=tz_offset_min)

    @app.get("/api/v1/report")
    def my_report(uid: str = Depends(current_user)):
        return _report(uid)

    @app.get("/api/v1/reports/{user_id}")
    def report(user_id: uuid.UUID, uid: str = Depends(current_user)):
        if str(user_id) != uid:
            raise HTTPException(403, "you can only read your own report")
        return _report(uid)

    def _report(uid: str):
        scans = store.list_scans(uid)
        base = [s for s in scans if s["tag_event"] == "Baseline" and s["sqi_passed"]]
        return {"user": store.get_user(uid), "baseline_scan_id": base[-1]["scan_id"] if base else None,
                "scans": scans, "comparisons": store.list_comparisons(uid),
                "interventions": store.list_interventions(uid), "disclaimer": DISCLAIMER}

    # ---------------------------------------------------------------- meals / diary
    @app.post("/api/v1/meals")
    def add_meal(req: MealRequest, uid: str = Depends(current_user)):
        return store.create_meal(uid, req.name.strip(), req.perceived_load, req.meal_type,
                                 (req.notes or "").strip() or None, list(dict.fromkeys(req.descriptors)))

    @app.get("/api/v1/meals")
    def list_meals(uid: str = Depends(current_user)):
        return list(reversed(store.list_meals(uid)))

    @app.delete("/api/v1/meals/{meal_id}")
    def delete_meal(meal_id: uuid.UUID, uid: str = Depends(current_user)):
        if not store.delete_meal(uid, str(meal_id)):
            raise HTTPException(404, "meal not found")
        return {"ok": True}

    @app.get("/api/v1/diary")
    def diary(uid: str = Depends(current_user)):
        rows = store.diary(uid)
        scored = sorted([r for r in rows if r.get("compatibility_pct") is not None],
                        key=lambda r: r["compatibility_pct"], reverse=True)
        return {"ranked": scored, "pending": [r for r in rows if r.get("compatibility_pct") is None],
                "disclaimer": DISCLAIMER}

    return app


app = create_app()
