"""Environment-driven configuration. Nothing here has secrets baked in."""
from __future__ import annotations

import os
from dataclasses import dataclass, field

from capture_validation import DEFAULT_CAPTURE_CONFIG, CaptureConfig


def _csv(name: str) -> list[str]:
    return [x.strip() for x in os.getenv(name, "").split(",") if x.strip()]


@dataclass
class Settings:
    env: str = "development"                 # development | test | production
    storage: str = "postgres"                # postgres | memory (memory only outside production)
    database_url: str = ""
    auth_mode: str = "token"                 # token | supabase | none (none only outside production)
    registration_key: str = ""               # optional: required header X-Registration-Key on /auth/register
    supabase_url: str = ""
    supabase_jwt_secret: str = ""
    cors_origins: list = field(default_factory=list)
    max_body_bytes: int = 2_000_000          # ~35 s @ 60 Hz x3 channels is ~150 kB
    max_samples: int = 120 * 130             # 130 s @ 120 fps hard cap (high-speed capture path)
    register_per_hour: int = 30
    signup_open: bool = True                  # AGNI_SIGNUP_OPEN=0 closes self-service sign-up
    login_per_10min: int = 30                 # per client IP
    max_failed_logins: int = 8                # then the account is locked for lockout_minutes
    lockout_minutes: int = 15
    # optional SMTP for e-mailed password-reset codes (recovery codes work without it)
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_from: str = ""
    capture: CaptureConfig = DEFAULT_CAPTURE_CONFIG   # FPS/timing policy; AGNI_CAPTURE_* env overrides

    @staticmethod
    def load() -> "Settings":
        s = Settings(
            env=os.getenv("AGNI_ENV", "development"),
            storage=os.getenv("AGNI_STORAGE", "postgres"),
            database_url=os.getenv("DATABASE_URL", ""),
            auth_mode=os.getenv("AGNI_AUTH_MODE", "token"),
            registration_key=os.getenv("AGNI_REGISTRATION_KEY", ""),
            supabase_url=os.getenv("SUPABASE_URL", "").rstrip("/"),
            supabase_jwt_secret=os.getenv("SUPABASE_JWT_SECRET", ""),
            cors_origins=_csv("AGNI_CORS_ORIGINS"),
            max_body_bytes=int(os.getenv("AGNI_MAX_BODY_BYTES", 2_000_000)),
            capture=CaptureConfig.from_env(),
            signup_open=os.getenv("AGNI_SIGNUP_OPEN", "1").lower() not in ("0", "false", "no"),
            smtp_host=os.getenv("AGNI_SMTP_HOST", ""),
            smtp_port=int(os.getenv("AGNI_SMTP_PORT", 587)),
            smtp_user=os.getenv("AGNI_SMTP_USER", ""),
            smtp_password=os.getenv("AGNI_SMTP_PASSWORD", ""),
            smtp_from=os.getenv("AGNI_SMTP_FROM", ""),
        )
        s.validate()
        return s

    @property
    def email_enabled(self) -> bool:
        return bool(self.smtp_host)

    def validate(self) -> None:
        if self.storage == "memory" and self.env == "production":
            raise RuntimeError("AGNI_STORAGE=memory is not allowed when AGNI_ENV=production")
        if self.storage == "postgres" and not self.database_url:
            raise RuntimeError(
                "DATABASE_URL is not set. Set it to your Supabase Postgres connection string, or for "
                "throw-away local testing set AGNI_STORAGE=memory (data is lost on restart).")
        if self.auth_mode == "none" and self.env == "production":
            raise RuntimeError("AGNI_AUTH_MODE=none is not allowed in production")
        if self.auth_mode == "supabase" and not (self.supabase_jwt_secret or self.supabase_url):
            raise RuntimeError("supabase auth needs SUPABASE_JWT_SECRET (HS256) or SUPABASE_URL (JWKS)")
