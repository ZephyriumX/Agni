# Agni-Pulse Flutter app

Source only. Depends on the local plugin `packages/ppg_camera` (Android Camera2 in Kotlin, iOS AVFoundation in Swift).

* Android: `../docs/ANDROID_SETUP.md`
* iOS (needs a Mac): `../docs/IOS_SETUP.md`, then `./tools/setup_ios.sh`
* Camera choice and fps evidence: `../docs/CAMERA_SELECTION.md`
* Timing rules: `../docs/CAPTURE_VALIDATION.md`
* What is verified and what is not: `../docs/STATUS.md`

```bash
flutter create --platforms=android --org com.agnipulse --project-name agni_pulse .   # first time (Android)
flutter pub get && dart format lib test packages && flutter analyze && flutter test
flutter run
```

## Screens
* **Welcome / sign-up / sign-in / reset password** (recovery code, or e-mail code when the server has SMTP), server settings
  before sign-in, upgrade of v0.x device profiles.
* **Onboarding**: about you → goals → 12-question Prakriti → result. Editable later in Profile.
* **Home**: greeting, baseline progress, quick actions (after meal, after practice, guided Vajrasana, compare), latest
  insights, last scan vs baseline, pending uploads.
* **Scan**: camera card with selector (incl. high-speed mode), guided steps, finger detection, live PPG/APG, 35 s
  recording with sensor timestamps, on-device timing verdict, scan type / meal / practice / context / note, upload,
  result with comparison. Unsent scans are kept on the phone and retried (idempotent).
* **Insights**: period selector, overview, insights with confidence, normal range, trend chart with normal band, scans
  vs baseline, meal ranking and descriptors, interventions, situations, time of day, signal quality, Prakriti
  guidance, "How to read this".
* **History** (filters, grouped by day) → **Scan details** (metrics, average beat, comparisons, quality, delete) →
  **Compare** any two scans.
* **Diary**: log meals, ranked meals, scan after a meal.
* **Profile**: personalisation, security (password, recovery code, devices, sign out everywhere), server & camera,
  how it works, delete account.

Wireless use: build with `--dart-define=API_BASE_URL=https://<your-api>` (see `../docs/REMOTE_ACCESS.md`).
