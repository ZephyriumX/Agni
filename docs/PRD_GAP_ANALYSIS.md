# Agni-Pulse – PRD-to-code gap analysis (v0.3.0)

Sources: the PRD `.docx` (Project Proposal + PRD v2.0 + technical deep-dive, read in full). The Google-Doc link only
returned a summary, so the `.docx` text was treated as authoritative.
**Verified** = covered by an automated test or a real run in the build environment (51 backend tests, incl. a real
PostgreSQL 16 cluster). **Unverified** = written but never compiled/run (no Flutter/Android SDK or phone available here).

## 0. Original defects (v0.2) and root causes

| # | Symptom (your screenshots) | Root cause | Evidence | Fix |
|---|---|---|---|---|
| B1 P0 | `Connection timed out … address = 10.0.2.2` on report and scan upload | `10.0.2.2` is the Android **emulator's** alias for the host PC. On a physical Samsung phone it is not routable, so packets vanish → *timeout* (a refused or blocked connection reads differently). v0.2 hard-wired it as the default. | errno 110, `address = 10.0.2.2`, physical device | Default depends on device type (physical → `127.0.0.1` + `adb reverse`); URL editable in-app, no rebuild; saved `10.0.2.2` ignored on real phones; diagnostics screen tests /health, /ready and auth separately. |
| B2 P0 | "delivered only 16 fps" then "48 fps" | v0.2 used Flutter's generic `camera` image stream: no control of exposure/frame duration, YUV→RGB loops on the Dart UI isolate, arrival-time timestamps. Auto-exposure on a dark red finger image lengthens exposure (lower fps). The value **changed between runs on the same phone (16 → 48)**, which points to software/exposure load rather than a fixed sensor limit. *Not proven without device logs.* | two values, same phone | Native Camera2 module: fixed frame duration, manual exposure + ISO controller, native ROI means, sensor timestamps, live exposure/ISO/fps readout. Hard 60 fps gate on phone and server. **Not relaxed.** |
| B3 P0 | "No finger detected" | Fixed thresholds on Dart-side means; auto-exposure shifts/saturates finger frames. | – | Native means, exposure controller (R kept in 140–205), looser colour-dominance rule with hysteresis, live R/G/B shown for tuning. |
| B4 P0 | Records lost on restart | `make_store()` silently fell back to in-memory without `SUPABASE_*`; REST path never tested. | code review | Real PostgreSQL store, pooled, transactional. Memory store only via explicit `AGNI_STORAGE=memory`, refused in production; startup fails loudly without `DATABASE_URL`. |
| B5 P0 | Any caller could read any `user_id` | `user_id` was a request field; one shared API key. | code review | Per-user bearer tokens (hash stored) or Supabase JWT; identity from token; every query owner-scoped. |
| B6 P1 | A failed upload lost the scan | No client persistence. | code review | Disk queue + idempotent `client_scan_id`. |
| B7 P1 | `-Infinity` SNR broke JSON/DB insert | Found by the real-PostgreSQL tests. | `invalid input syntax for type json` | Non-finite values sanitised. |
| B8 P2 | Possible info leaks; unbounded bodies | – | code review | Generic 500 + request-id, 413 body limit, 503 on DB outage, no body/token logging. |

## 1. Requirements matrix

| ID | PRD requirement | Implementation | Status | Evidence | Gap / limitation | Pri |
|---|---|---|---|---|---|---|
| F1 | Raw R/G capture ≥60 fps via native Camera2 | `app/packages/ppg_camera` (Kotlin); `dsp_engine.acquisition_check` rejects <60 fps, >5 % drops, >150 ms gaps | Server side **Verified**; Android module **Unverified**; iOS **Missing** | `test_acquisition_check_*`, `test_rejects_slow_camera_and_bad_input` | Never compiled/run here. Phone may genuinely lack 60 fps YUV (app then shows Camera2 evidence and refuses). | P0 |
| F2 | Live filtered PPG + APG | `signal_monitor.dart`, `waveform.dart` | Unverified | `app/test/signal_monitor_test.dart` (not run) | Display filter is a simple high-pass/smoother, not the server Butterworth | P2 |
| F3 | b/a ratio | `extract_apg_features` (+ d/a, aging index) | Verified on synthetic | `test_metrics_accuracy`, `test_cde_features_resolved` | No real recordings tested | P1 |
| F4 | RMSSD | `rmssd`, sub-sample peaks, ectopic rejection | Verified on synthetic | within 20 % of truth | <30 s recordings warn | P1 |
| F5 | Vajrasana before/after | `timer_screen.dart`, `compare_to`, `interventions`, template overlay | Backend **Verified**, UI Unverified | `test_vajrasana_before_after` | "8/10 subjects improve" needs a human study | P1 |
| F6 | ML glycemic classifier | – | **Missing by design** | – | No labelled data (PRD Phase 2 needs glucometer ground truth). Only an experimental heuristic gate. | P3 |
| F7 | Context tags / gate | `context` tags, `biofeedback.interpret` (PRD §2.D) | Verified (logic) | `test_full_flow` | 10 % stiffness threshold is an **assumption** | P2 |
| F8 | Food compatibility diary | `meals`, `/meals`, `/diary`, `diary_screen.dart` | Backend **Verified**, UI Unverified | `test_full_flow` | Score `100×RMSSD ratio` is an **assumption** (PRD gives only the 0.7 cut-off) | P2 |
| F9 | Ayurvedic intervention engine | `biofeedback.interpret` (Sitali, Vajrasana, Ginger/Pawanmuktasana) | Verified (rules) | tests | Traditional guidance, not clinically validated | P2 |
| SM1 | SQI rejects >90 % of motion-artifact scans | `assess_quality` | Verified on synthetic proxy | `test_sqi_rejects_artifacts` (100 % on 5 classes × 20) | Real motion differs | P1 |
| SM2 | Result < 2 s | DSP ≈ 12 ms; request ≈ 40 ms | Verified (server) | `test_latency_under_2s` | Mobile network time excluded | P2 |
| API1 | `POST /scan/process` | `main.process_scan` (sync endpoint → worker thread) | Verified | `test_full_flow` | `user_id` no longer in body (token identity) | P0 |
| API2 | `POST /scan/compare` | `main.compare` + persisted `comparisons` | Verified | tests | PRD divides by baseline b/a; b/a < 0, so \|baseline\| is used: **+ = stiffer** | P1 |
| API3 | `GET /reports/{user_id}` | owner-only (403 otherwise), no raw signal | Verified | `test_authorization_isolation` | – | P1 |
| DB1 | Supabase schema | `db/migrations/001` (PRD verbatim) + `002` + `migrate.py` | Verified on PostgreSQL 16 | `test_migrations_*`, `test_rls_enabled_*` | **Not run against a real Supabase project** (no credentials) | P0 |
| DB2 | Persistence across restart | `PostgresStore` | Verified on local PG | `test_data_survives_api_restart`; `scripts/restart_proof.py` kills/restarts uvicorn | same Supabase caveat | P0 |
| DB3 | Transactions / outage | single-transaction writes; 503 | Verified | `test_transaction_rolls_back_*`, `test_db_outage_returns_503_*` | – | P1 |
| SEC1 | Auth (PRD: Supabase Auth) | token mode + Supabase JWT verify (HS256/JWKS) | Backend Verified (HS256); **no Supabase login UI in Flutter** | `test_supabase_jwt_mode_hs256` | JWKS path untested; production should add `supabase_flutter` sign-in | P1 |
| V1 | Prakriti quiz | `quiz_screen.dart` → `PATCH /me` | Unverified | – | Generic questions, not clinically reviewed | P3 |
| V2 | Baseline calibration view | Baseline tag + `users.baseline_*` | Partial | tests | No forced calm-state gating UI | P3 |
| V5 | Reaction Report (3 dials) | `ComparisonCard` | Unverified | – | – | P2 |
| V8 | Before/after graph | `BeforeAfterCard` | Unverified | template tests | – | P2 |
| V4 | Educational wait screen | – | Missing | – | – | P3 |
| LF/HF | Frequency-domain stream | – | **Missing** | – | LF/HF is unreliable on a 35 s scan | P3 |
| AIx | PPG reflected-wave index | aging index + d/a only | Partial | – | – | P3 |
| – | 30-min meal reminder; iOS capture | – | Missing | – | – | P2/P3 |

## 2. Not verified (explicit)
- Flutter compile/analyze/build, Kotlin compile, anything on a phone (no Flutter/Android SDK reachable here).
- Real camera acquisition: fps, finger thresholds, exposure controller.
- A real Supabase project (no credentials). Local PostgreSQL 16 was used; the code speaks plain Postgres.
- Real human PPG: all DSP accuracy figures are synthetic.

## 3. If the phone truly cannot do 60 fps
The app will say so with Camera2 evidence and refuse to scan. A scientifically defensible fallback (not implemented, would
need your decision): ≥30 fps with sub-sample peak interpolation is commonly used for pulse-rate variability (RMSSD) but is
**not** adequate for the second derivative (APG, b/a). That would mean an HRV-only mode with b/a disabled.
