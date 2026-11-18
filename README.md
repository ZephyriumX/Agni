# Agni-Pulse 1.0

Smartphone PPG/APG vascular-wellness app. **Wellness tool, not a medical device.**
Flutter app → native camera plugin (Android Camera2 incl. high-speed mode / iOS AVFoundation) → FastAPI DSP + analytics
service → PostgreSQL (Supabase). Deployable to the cloud so the phone works anywhere, without USB.

```
agni-pulse/
  backend/        FastAPI: auth (accounts, sessions, recovery), DSP (dsp_engine.py), capture_validation.py,
                  analytics.py (baseline, trends, meal/intervention/context responses, insights), storage, tests/
  db/migrations/  001_init · 002_hardening · 003_accounts_analytics
  app/            Flutter app (lib/), tests (test/), tools/setup_ios.sh
    packages/ppg_camera/   android/ (Kotlin Camera2 + high-speed GPU reader) · ios/ (Swift AVFoundation)
  scripts/        smoke_remote.py (live end-to-end check) · tunnel.ps1/.sh · run_dev.ps1 · e2e_check.py
  render.yaml     one-click cloud deployment (Render Blueprint)
  docs/           REMOTE_ACCESS · ANDROID_SETUP · IOS_SETUP · CAMERA_SELECTION · CAPTURE_VALIDATION · STATUS
```

**Read `docs/STATUS.md` first**: per component, what has been tested and how. The backend is tested end to end
(165 automated tests on in-memory and real PostgreSQL storage, plus a 20-step live HTTP check against a running
production-mode server). The Flutter, Kotlin and Swift code has been statically checked but **not compiled** where it
was written (no Flutter/Android SDK there): the first `flutter analyze` / build on your machine may need small fixes.

## Product
* **Accounts**: e-mail + password sign-up and sign-in, one session per device, sign out / sign out everywhere,
  change password, one-time **recovery code** (plus optional e-mailed reset codes), delete account with all data.
  Data belongs to the account, so it is the same on every phone. Profiles from v0.x upgrade without losing scans.
* **Onboarding & personalisation**: profile (year of birth, sex, diet, activity), goals, 12-question Prakriti
  self-assessment with dosha scores; editable later; used in insights and guidance.
* **Scans**: baseline, after meal (pick a logged meal or log a new one with type and descriptors), after an intervention
  (Vajrasana, Sitali, breathing, meditation, walk, yoga…), after exercise, plus contexts (caffeine, stress, poor sleep,
  fasting, alcohol, unwell…) and notes. Guided Vajrasana: scan → 10-min timer → scan, compared as a pair.
* **Insights**: personal normal range from baselines (mean ± SD, reliability), trend charts with the normal band,
  every scan vs baseline with "clear / possible / normal" significance, meal ranking, meal-descriptor effects,
  intervention effects (paired with the scan just before), context effects, time-of-day pattern, signal-quality
  summary, Prakriti guidance, and plain-language insights with confidence levels. Explained in-app ("How to read this").
* **History** (filter, details, delete), **compare any two scans**, **food diary** (log, rank, scan after).
* **Remote access**: Docker image + `render.yaml` for a free cloud deployment with Supabase; the app wakes a sleeping
  server and builds can carry the server address (`--dart-define=API_BASE_URL=...`). See `docs/REMOTE_ACCESS.md`.

## 1. Backend
**For use anywhere (no cable, any network): deploy it to the cloud with `docs/REMOTE_ACCESS.md` (Render + Supabase,
free tiers, ~20 minutes).** Running it on your own computer:
```bash
# macOS / Linux
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export DATABASE_URL="postgresql://..."      # your Supabase/PostgreSQL URI. Never commit it.
python migrate.py                            # applies db/migrations/*.sql once each (checksummed)
uvicorn main:app --host 0.0.0.0 --port 8000
curl http://127.0.0.1:8000/health            # process alive
curl http://127.0.0.1:8000/ready             # database reachable AND migrated
curl http://127.0.0.1:8000/api/v1/capture-config   # the fps/timing thresholds the app will be judged by
```
```powershell
# Windows PowerShell (from the repo root): venv, deps, migrations, adb reverse, uvicorn
$env:DATABASE_URL = "postgresql://...."
.\scripts\run_dev.ps1                 # real database
.\scripts\run_dev.ps1 -Memory         # throw-away (data lost on exit)
.\scripts\run_dev.ps1 -Lan            # also listen on Wi-Fi (needs scripts\windows_firewall.ps1 once)
```
Docker: `docker compose up --build`. Without `DATABASE_URL` the server refuses to start (no silent in-memory fallback).
Environment variables are listed in `.env.example` (copy to `.env`, which is git-ignored; never commit secrets).

### Supabase / PostgreSQL
1. Supabase: *Project Settings → Database → Connection string → URI* (pooler string on IPv4-only networks, keep `sslmode=require`).
2. `export DATABASE_URL=<that string>` (a server-side secret; never put it in the app).
3. `python backend/migrate.py`, then `python scripts/e2e_check.py http://127.0.0.1:8000`.
Verified on local PostgreSQL 16 only. **Not yet run against your Supabase project.**

## 2. Android phone → `docs/ANDROID_SETUP.md`
```powershell
cd app
flutter create --platforms=android --org com.agnipulse --project-name agni_pulse .   # first time only
flutter pub get
adb reverse tcp:8000 tcp:8000
flutter run
```
## 3. iPhone (needs a Mac with Xcode) → `docs/IOS_SETUP.md`
```bash
cd app && ./tools/setup_ios.sh        # first time only: generates ios/, camera permission, iOS 13, pod install
open ios/Runner.xcworkspace            # pick your Team under Signing & Capabilities
flutter run -d <your-iphone> --dart-define=API_BASE_URL=https://<your-api>.onrender.com
```
## 4. Tests
```bash
cd backend && pip install -r requirements-dev.txt && python -m pytest -q      # 165 tests
python scripts/smoke_remote.py https://<your-server>                           # live end-to-end check (20 steps)
cd app && dart format lib test packages && flutter analyze && flutter test    # NOT yet run by anyone
cd app/android && ./gradlew :ppg_camera:testDebugUnitTest                     # Kotlin selection tests, NOT yet run
```
Real-PostgreSQL tests start a throw-away cluster from system PostgreSQL binaries, or use `DATABASE_URL_TEST`; they skip
(not fail) if neither exists.

## 5. Security model
* Passwords: scrypt (stdlib, per-user salt). Session tokens, recovery codes and reset codes are random and stored only as
  SHA-256 hashes. Identity always comes from the token; every query is scoped to the owner (tested for isolation).
* Login rate limit per IP and account lockout after repeated failures; generic "wrong e-mail or password".
* Optional invitation key (`AGNI_REGISTRATION_KEY`) for public servers; sign-up can be closed (`AGNI_SIGNUP_OPEN=0`).
* Body-size limit, no logging of bodies/tokens/signals, row-level security enabled on all tables, secrets only in
  environment variables. Use HTTPS outside your own network (the cloud and tunnel options provide it).
* `.env`, tokens, keystores and connection strings are git-ignored and never committed.

## 6. Known limits
See `docs/STATUS.md` and `docs/PRD_GAP_ANALYSIS.md`. Highlights: the app has not been compiled or run on a phone by
the author; the high-speed camera path for 30-fps-limited phones is untested on hardware; all thresholds are engineering
parameters (several marked *assumption*) and nothing is clinically validated; the ML sugar-spike classifier, LF/HF and
reminders are not built.
