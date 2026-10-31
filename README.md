# Agni-Pulse MVP (v0.3.0)

Smartphone PPG/APG vascular-health analyzer: Flutter + native Android Camera2 capture → FastAPI DSP service →
PostgreSQL/Supabase. **Wellness tool, not a medical device.**

```
agni-pulse/
  backend/   FastAPI + DSP (dsp_engine.py), storage, auth, migrate.py, tests/
  db/migrations/  001_init.sql (PRD schema) · 002_hardening.sql
  app/       Flutter app + packages/ppg_camera (Kotlin Camera2 plugin)
  scripts/   run_dev.ps1 (Windows) · e2e_check.py · restart_proof.py · windows_firewall.ps1
  docs/PRD_GAP_ANALYSIS.md   what is done / unverified / missing, with root causes
```

## 1. Backend (Windows PowerShell)
```powershell
# a) with a real database (Supabase or any PostgreSQL) - see section 2
$env:DATABASE_URL = "postgresql://...."          # never commit this
.\scripts\run_dev.ps1                            # venv, deps, migrations, adb reverse, uvicorn on 127.0.0.1:8000
# b) throw-away (data lost on exit):  .\scripts\run_dev.ps1 -Memory
```
Linux/macOS: `cd backend && pip install -r requirements.txt && DATABASE_URL=... python migrate.py && uvicorn main:app --host 0.0.0.0`.
Docker: `docker compose up --build` (PostgreSQL + API, migrations applied on start).

Without `DATABASE_URL` the server **refuses to start** (no silent in-memory fallback). `/health` = process alive,
`/ready` = database reachable **and** migrated.

## 2. Supabase
1. Create a project. *Project Settings → Database → Connection string → URI* (use the pooler string on IPv4-only
   networks; keep `sslmode=require`).
2. `DATABASE_URL=<that string>` in your shell (server-side secret; never in the Flutter app).
3. `python backend/migrate.py` (applies `db/migrations/*.sql` once each; checksummed; RLS enabled on all tables).
4. `python scripts/e2e_check.py http://127.0.0.1:8000` → registers a user, uploads two synthetic scans, compares, reads the
   report. Restart the server and run the printed `--verify …` line to confirm persistence.
Status: verified on local PostgreSQL 16 only; **not yet run against your Supabase project**.

## 3. Phone setup (physical Samsung + Windows PC)
**USB (recommended, no Wi-Fi/firewall involved):** enable USB debugging, plug in, run `run_dev.ps1` (it executes
`adb reverse tcp:8000 tcp:8000`). The app's default URL on a real phone is `http://127.0.0.1:8000`.
**Wi-Fi:** run the server with `-Lan`, run `scripts\windows_firewall.ps1` once as Administrator (Private profile only),
set the app's *Settings → API base URL* to `http://<PC-IP>:8000`. If it still times out: Wi-Fi marked "Public", router
client/AP isolation, or a VPN.
**Never** use `10.0.2.2` on a real phone - that is the emulator-only alias (the cause of your timeouts).
The URL is editable in-app (gear icon → *Save & test connection*) or at build time: `--dart-define=API_BASE_URL=https://api.example.com`.
Android's cleartext-HTTP policy does not apply to Dart's `http` package, so plain `http://` works in dev; use HTTPS in production.

## 4. Flutter / Android build
See `app/README.md` (generate android/ with `flutter create .`, set minSdk 24, then `flutter pub get && flutter run`).
**This code has not been compiled** (no Flutter SDK in the build environment): expect small first-build fixes.

## 5. Tests
```
cd backend && pip install -r requirements-dev.txt && python -m pytest -q
```
51 tests: DSP, API on memory **and** real PostgreSQL, restart survival, outage → 503, transactions, migrations, RLS,
token hashing, JWT auth, rate limit, config guards. Real-PostgreSQL tests start a throw-away cluster from system
PostgreSQL binaries, or use `DATABASE_URL_TEST`; they skip (not fail) if neither exists.
`python scripts/restart_proof.py` kills and restarts a real uvicorn process over a real PostgreSQL.

## 6. Security model
Per-user bearer tokens (SHA-256 hash stored) or Supabase JWT; identity from the token, every query owner-scoped; 403/404 on
other users' data; body-size limit; generic errors; no signal/token logging; RLS on; secrets only in env. Optional
`AGNI_REGISTRATION_KEY` gates sign-up. Production needs: HTTPS, Supabase Auth login in the app, rate limiting at the edge.

## 7. Known limits
See `docs/PRD_GAP_ANALYSIS.md`. Highlights: Android only; never run on a device; 60 fps is enforced, so phones that
cannot deliver it are refused; ML sugar-spike classifier, LF/HF and reminders not built; thresholds marked ASSUMPTION need real data.
