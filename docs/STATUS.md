# Verification status (v1.0.0)

What was actually executed, per component. "Compiled" means built by a real toolchain; "device-tested" means run on a
phone. Nothing is claimed beyond what is listed.

| Component | Implemented | Verified how | Compiled | Device-tested |
|---|---|---|---|---|
| Backend API: accounts, sessions, recovery (code + optional e-mail), profile/onboarding, scans, history, delete, meals, comparisons, analytics, export | Yes | **165 automated tests pass** on both storage back ends (in-memory and a real PostgreSQL 16 server), incl. auth flows, lockout, per-user isolation, account deletion, migrations, 100/120 fps DSP | n/a (Python) | n/a |
| Backend as deployed (Docker command, production mode, real PostgreSQL) | Yes | `scripts/smoke_remote.py` against a live uvicorn started exactly like the Docker `CMD` (migrate → uvicorn `$PORT`, proxy headers), `AGNI_ENV=production`: **20/20 live HTTP checks passed** (sign-up → onboarding → scans → meal → intervention → history → analytics → 2nd device → isolation → logout → recovery → export → delete) | n/a | n/a |
| Migration 003 on an existing database | Yes | applied on top of 001/002 in the test cluster; existing 125 v0.5 tests still pass; checksums enforced | n/a | n/a |
| Docker image / Render blueprint | Yes | Dockerfile and `render.yaml` written; the image was **not built** here and nothing was deployed (needs your Render and Supabase accounts) | No | n/a |
| Analytics engine (`analytics.py`) | Yes | 10 unit/integration tests with known answers (baseline stats, SD-based significance with noise floor, trends vs noise, meal grouping, descriptor effects, intervention pairing, contexts, window/fallback, streaks, quality) | n/a | n/a |
| Flutter app 1.0 (auth, onboarding, home, insights + charts, history, scan detail, compare, diary, profile, server settings) | Yes | Built and run by the team on an Android phone (realme P3 5G) against the Supabase back end; scans recorded on 16, 18 and 19 Nov 2026 (see `docs/media/screens/` and `docs/media/evidence/supabase-scans-table.jpg`). Dart unit tests: run them with `flutter test` | **Yes** (Android) | **Yes** (Android) |
| Capture validation, Dart port | Yes | Golden vectors shared with the Python tests; on the device every recorded scan reported PASS at 59.0–59.1 fps with 0.0–0.1 % dropped frames | Yes (Android) | Yes (Android) |
| Android plugin: Camera2 YUV path, camera selection, high-speed path (`HsSession.kt`) | Yes | **YUV path device-tested** on a realme P3 5G (≈59 fps, torch, locked exposure/white balance). Camera-selection JVM tests written; high-speed GPU path not yet tried on a 30-fps-limited phone | Yes | YUV path: **Yes**; high-speed path: not yet |
| iOS plugin (Swift AVFoundation) | Yes | Written without a Mac | No | No |

Device testing (Nov 2026): the Android app was built and used on a realme P3 5G with the cloud database. Baseline, after-meal and after-intervention scans, their comparisons and quality panels are shown in `docs/media/screens/`.

Nothing here has been clinically validated. All fps/timing/SQI/analytics thresholds are engineering parameters
(several marked ASSUMPTION in the code).
