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
| Flutter app 1.0 (auth, onboarding, home, insights + charts, history, scan detail, compare, diary, profile, server settings) | Yes | Static checks only: bracket balance, every project symbol imported where used, no unused project imports, manual type review. New Dart unit tests (`prakriti_test`, `format_test`) **not run** | **No** | **No** |
| Capture validation, Dart port | Yes | Golden vectors shared with the Python tests; Dart side not run | No | No |
| Android plugin: Camera2 YUV path, camera selection, high-speed path (`HsSession.kt`) | Yes | JVM unit tests for camera choice written, **not run**; high-speed GPU path untested on hardware (torch/AE-lock in high-speed mode are device-dependent; it logs every step) | No | No |
| iOS plugin (Swift AVFoundation) | Yes | Written without a Mac | No | No |

Why the app is not compiled: no Flutter/Android SDK in the environment where it was written, and running a downloaded
Dart SDK was not permitted there. On your PC: `flutter pub get && flutter analyze && flutter test && flutter run`.
Paste any error output and it will be fixed.

Nothing here has been clinically validated. All fps/timing/SQI/analytics thresholds are engineering parameters
(several marked ASSUMPTION in the code).
