"""Per-user authentication.

token mode (default):
  * Accounts: e-mail + password (scrypt). /auth/signup and /auth/login create a SESSION: a random 256-bit
    bearer token, of which only the SHA-256 is stored. One session per signed-in device; logout revokes it.
  * Recovery: a one-time recovery code shown at signup (stored hashed) and, when SMTP is configured,
    an e-mailed 6-digit reset code.
  * Legacy: /auth/register still issues an anonymous device token (v0.2-v0.5 apps); such an account can be
    upgraded to e-mail + password without losing data (/auth/upgrade).
  user_id always comes from the token, never from the request body.
supabase mode: verifies a Supabase Auth JWT (HS256 secret or JWKS) and uses its `sub` as user_id.
none mode: dev/test only - requires header X-Dev-User.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import secrets
import smtplib
import time
from email.message import EmailMessage
from collections import defaultdict, deque
from typing import Optional

from fastapi import Header, HTTPException, Request

from config import Settings


log = logging.getLogger("agni.auth")

SESSION_DAYS = 180


def new_token() -> str:
    """Legacy anonymous device token (prefix agp_)."""
    return "agp_" + secrets.token_urlsafe(32)


def new_session_token() -> str:
    """Account session token (prefix ags_)."""
    return "ags_" + secrets.token_urlsafe(32)


def hash_token(t: str) -> str:
    return hashlib.sha256(t.encode()).hexdigest()


# ---------------------------------------------------------------- passwords (stdlib scrypt, no extra deps)
_SCRYPT = (2 ** 14, 8, 1)      # N, r, p  (~16 MB, ~50 ms)


def hash_password(pw: str) -> str:
    n, r, p = _SCRYPT
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(pw.encode(), salt=salt, n=n, r=r, p=p, dklen=32)
    b = lambda x: base64.b64encode(x).decode()   # noqa: E731
    return f"scrypt${n}${r}${p}${b(salt)}${b(dk)}"


def verify_password(pw: str, stored: str | None) -> bool:
    if not stored:
        hashlib.scrypt(b"x", salt=b"0" * 16, n=_SCRYPT[0], r=_SCRYPT[1], p=_SCRYPT[2], dklen=32)  # equal timing
        return False
    try:
        algo, n, r, p, salt, dk = stored.split("$")
        if algo != "scrypt":
            return False
        got = hashlib.scrypt(pw.encode(), salt=base64.b64decode(salt), n=int(n), r=int(r), p=int(p),
                             dklen=len(base64.b64decode(dk)))
        return hmac.compare_digest(got, base64.b64decode(dk))
    except Exception:
        return False


def password_problem(pw: str, email: str = "") -> str | None:
    """Minimal, explainable policy: >= 8 chars, not all one character class of digits, not the e-mail."""
    if len(pw) < 8:
        return "Password must be at least 8 characters."
    if len(pw) > 128:
        return "Password must be at most 128 characters."
    if pw.isdigit():
        return "Password cannot be only digits."
    if email and pw.lower() == email.lower():
        return "Password cannot be your e-mail address."
    if pw.lower() in {"password", "password1", "12345678", "qwertyui", "agnipulse"}:
        return "That password is too common."
    return None


# ---------------------------------------------------------------- recovery codes
_RC_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no 0/O/1/I


def new_recovery_code() -> str:
    raw = "".join(secrets.choice(_RC_ALPHABET) for _ in range(16))
    return "-".join(raw[i:i + 4] for i in range(0, 16, 4))


def normalize_recovery_code(c: str) -> str:
    c = "".join(ch for ch in c.upper() if ch.isalnum())
    return "-".join(c[i:i + 4] for i in range(0, len(c), 4))


def hash_recovery_code(c: str) -> str:
    return hashlib.sha256(("rc:" + normalize_recovery_code(c)).encode()).hexdigest()


def new_reset_code() -> str:
    return f"{secrets.randbelow(10 ** 6):06d}"


def hash_reset_code(user_id: str, code: str) -> str:
    return hashlib.sha256(f"reset:{user_id}:{code.strip()}".encode()).hexdigest()


def send_email(settings: Settings, to: str, subject: str, body: str) -> None:
    """Plain SMTP (STARTTLS on 587, implicit TLS on 465). Raises on failure."""
    msg = EmailMessage()
    msg["From"], msg["To"], msg["Subject"] = settings.smtp_from or settings.smtp_user, to, subject
    msg.set_content(body)
    if settings.smtp_port == 465:
        with smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, timeout=15) as s:
            if settings.smtp_user:
                s.login(settings.smtp_user, settings.smtp_password)
            s.send_message(msg)
    else:
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=15) as s:
            s.starttls()
            if settings.smtp_user:
                s.login(settings.smtp_user, settings.smtp_password)
            s.send_message(msg)


class RateLimiter:
    def __init__(self, n: int, per_s: float):
        self.n, self.per_s, self.hits = n, per_s, defaultdict(deque)

    def check(self, key: str) -> None:
        now, q = time.monotonic(), self.hits[key]
        while q and now - q[0] > self.per_s:
            q.popleft()
        if len(q) >= self.n:
            raise HTTPException(429, "too many requests")
        q.append(now)


_jwks_client = None


def _verify_supabase_jwt(token: str, s: Settings) -> str:
    import jwt
    global _jwks_client
    try:
        hdr = jwt.get_unverified_header(token)
        if hdr.get("alg", "").startswith("HS") and s.supabase_jwt_secret:
            claims = jwt.decode(token, s.supabase_jwt_secret, algorithms=["HS256"], audience="authenticated")
        else:
            if _jwks_client is None:
                _jwks_client = jwt.PyJWKClient(f"{s.supabase_url}/auth/v1/.well-known/jwks.json")
            key = _jwks_client.get_signing_key_from_jwt(token).key
            claims = jwt.decode(token, key, algorithms=["RS256", "ES256"], audience="authenticated")
        return str(claims["sub"])
    except Exception:
        raise HTTPException(401, "invalid or expired token")


def make_current_auth(settings: Settings, get_store):
    """Dependency returning {"user_id", "session_id" (None for legacy/supabase/dev)}."""
    def current_auth(request: Request, authorization: Optional[str] = Header(None),
                     x_dev_user: Optional[str] = Header(None)) -> dict:
        store = get_store()
        if settings.auth_mode == "none":
            if not x_dev_user:
                raise HTTPException(401, "X-Dev-User header required (auth disabled, dev only)")
            if store.get_user(x_dev_user) is None:
                store.create_user(None, None, x_dev_user)
            return {"user_id": x_dev_user, "session_id": None}
        if not authorization or not authorization.lower().startswith("bearer "):
            raise HTTPException(401, "missing bearer token", headers={"WWW-Authenticate": "Bearer"})
        token = authorization[7:].strip()
        if settings.auth_mode == "supabase":
            uid = _verify_supabase_jwt(token, settings)
            if store.get_user(uid) is None:
                store.create_user(None, None, uid)
            return {"user_id": uid, "session_id": None}
        h = hash_token(token)
        if token.startswith("ags_"):
            sess = store.get_session(h)
            if not sess:
                raise HTTPException(401, "session expired or signed out", headers={"WWW-Authenticate": "Bearer"})
            return {"user_id": sess["user_id"], "session_id": sess["session_id"]}
        u = store.get_user_by_token_hash(h)
        if not u:
            raise HTTPException(401, "invalid token", headers={"WWW-Authenticate": "Bearer"})
        return {"user_id": u["user_id"], "session_id": None}
    return current_auth


def make_current_user(settings: Settings, get_store):
    current_auth = make_current_auth(settings, get_store)

    def current_user(request: Request, authorization: Optional[str] = Header(None),
                     x_dev_user: Optional[str] = Header(None)) -> str:
        return current_auth(request, authorization, x_dev_user)["user_id"]
    return current_user


def check_registration_key(settings: Settings, supplied: Optional[str]) -> None:
    if settings.registration_key and not (supplied and hmac.compare_digest(supplied, settings.registration_key)):
        raise HTTPException(401, "registration key required")
