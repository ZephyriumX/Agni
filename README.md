# Agni-Pulse (v0.4.0)

Smartphone PPG/APG vascular-health analyzer. **Wellness tool, not a medical device.**
Flutter app → native camera plugin (Android Camera2 / iOS AVFoundation) → FastAPI DSP service → PostgreSQL/Supabase.

```
agni-pulse/
  backend/        FastAPI + DSP (dsp_engine.py), capture_validation.py, storage, auth, migrate.py, tests/
  db/migrations/  001_init.sql (PRD schema) · 002_hardening.sql
  app/            Flutter app (lib/), tools/setup_ios.sh
    packages/ppg_camera/   android/ (Kotlin Camera2)  ·  ios/ (Swift AVFoundation)
  scripts/        run_dev.ps1 (Windows) · e2e_check.py · restart_proof.py · windows_firewall.ps1
  docs/           ANDROID_SETUP · IOS_SETUP · CAMERA_SELECTION · CAPTURE_VALIDATION · STATUS · PRD_GAP_ANALYSIS
```

**Read `docs/STATUS.md` first.** It states, per component, what is implemented, compiled, simulator-tested and
device-tested. At this version the backend is tested; the Flutter, Kotlin and Swift code is **written but has never
been compiled or run on a phone** (no Flutter/Android SDK/macOS where it was written). Expect small first-build fixes.

## What changed in 0.4.0
* **Camera selection.** The app now lists every *back* camera, including physical lenses hidden behind a phone's
  combined camera, shows each one's real frame rate, picks the best automatically, and lets you choose (scan screen →
  Camera → Change). See `docs/CAMERA_SELECTION.md`.
* **FPS tolerance.** 58 fps phones are no longer refused outright; timing is judged from real sensor timestamps as
  PASS / WARNING / FAIL (`docs/CAPTURE_VALIDATION.md`). Signal-quality (SQI) thresholds are unchanged.
* **New UI.** Material 3 theme (light/dark), bottom navigation, home dashboard, guided scan screen, status pills.
* **iOS plugin** (Swift/AVFoundation) behind the same API. **Not compiled.**

## 1. Backend (identical on every platform)
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
flutter run -d <your-iphone> --dart-define=API_BASE_URL=http://<mac-wifi-ip>:8000
```
## 4. Tests
```bash
cd backend && pip install -r requirements-dev.txt && python -m pytest -q      # 119 tests
cd app && dart format lib test packages && flutter analyze && flutter test    # NOT yet run by anyone
cd app/android && ./gradlew :ppg_camera:testDebugUnitTest                     # Kotlin selection tests, NOT yet run
```
Real-PostgreSQL tests start a throw-away cluster from system PostgreSQL binaries, or use `DATABASE_URL_TEST`; they skip
(not fail) if neither exists.

## 5. Security model
Per-user bearer tokens (SHA-256 hash stored) or Supabase JWT; identity from the token; every query owner-scoped;
body-size limit; generic errors; no signal/token logging; RLS enabled; secrets only in the environment. Production needs
HTTPS, Supabase Auth login in the app, and edge rate limiting. `.env`, tokens and connection strings are never committed.

## 6. Known limits
See `docs/STATUS.md` and `docs/PRD_GAP_ANALYSIS.md`. Highlights: nothing has run on a phone; a phone whose OS caps
third-party apps at 30 fps is refused (the diagnostics say so; the scan is never run at a lower rate); the ML
sugar-spike classifier, LF/HF and reminders are not built; thresholds marked *assumption* need real data.
