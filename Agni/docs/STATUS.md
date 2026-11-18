# Verification status (v0.4.0)

| Component | Implemented | Compiled | Simulator-tested | Device-tested | Notes |
|---|---|---|---|---|---|
| Backend (FastAPI, DSP, capture validation, auth, storage) | Yes | n/a (Python) | n/a | n/a | **119 automated tests pass**, incl. real PostgreSQL 16. Synthetic signals only. Not run against your Supabase. |
| Capture validation, Dart port (`capture_validation.dart`) | Yes | **No** | n/a | No | Shares golden vectors (`docs/capture_validation_vectors.json`) with the Python tests; the Dart side has not been run. |
| Flutter UI (theme, shell, home, scan, results, settings) | Yes | **No** | No | No | Bracket-balance and read-through only. |
| Android plugin (Kotlin Camera2, camera enumeration/selection) | Yes | **No** | n/a | **No** | Never built or run on a phone. |
| iOS plugin (Swift AVFoundation) | Yes | **No** | **No** | **No** | Written without a Mac. Simulator has no camera. |
| `flutter format / analyze / test`, Android APK, iOS build | – | **Not run** | – | – | No Flutter SDK / Android SDK / macOS where this was written. Commands are in the setup guides. |

Nothing here has been clinically validated. All fps/timing/SQI thresholds are engineering parameters.
