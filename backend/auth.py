"""Per-user authentication.

token mode (default): POST /api/v1/auth/register issues a random 256-bit bearer token ONCE; only its
  SHA-256 hash is stored. user_id always comes from the token, never from the request body.
supabase mode: verifies a Supabase Auth JWT (HS256 secret or JWKS) and uses its `sub` as user_id.
none mode: dev/test only - requires header X-Dev-User.
"""
from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from collections import defaultdict, deque
from typing import Optional

from fastapi import Header, HTTPException, Request

from config import Settings


def new_token() -> str:
    return "agp_" + secrets.token_urlsafe(32)


def hash_token(t: str) -> str:
    return hashlib.sha256(t.encode()).hexdigest()


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


def make_current_user(settings: Settings, get_store):
    def current_user(request: Request, authorization: Optional[str] = Header(None),
                     x_dev_user: Optional[str] = Header(None)) -> str:
        store = get_store()
        if settings.auth_mode == "none":
            if not x_dev_user:
                raise HTTPException(401, "X-Dev-User header required (auth disabled, dev only)")
            if store.get_user(x_dev_user) is None:
                store.create_user(None, None, x_dev_user)
            return x_dev_user
        if not authorization or not authorization.lower().startswith("bearer "):
            raise HTTPException(401, "missing bearer token", headers={"WWW-Authenticate": "Bearer"})
        token = authorization[7:].strip()
        if settings.auth_mode == "supabase":
            uid = _verify_supabase_jwt(token, settings)
            if store.get_user(uid) is None:
                store.create_user(None, None, uid)
            return uid
        u = store.get_user_by_token_hash(hash_token(token))
        if not u:
            raise HTTPException(401, "invalid token", headers={"WWW-Authenticate": "Bearer"})
        return u["user_id"]
    return current_user


def check_registration_key(settings: Settings, supplied: Optional[str]) -> None:
    if settings.registration_key and not (supplied and hmac.compare_digest(supplied, settings.registration_key)):
        raise HTTPException(401, "registration key required")
